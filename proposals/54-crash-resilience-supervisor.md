# Proposal: crash-resilience — model-free supervisor that resumes a dead agent + a standing successor handoff (#54)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

An autonomous research run has three ways to fail, and we cover only two of them. The agent can go *idle* (parked, waiting on nothing) — caught by the self-wake cron `run-experiment` arms. The GPU pod can be *orphaned* (still billing after the run is done or abandoned) — caught by the model-free reaper `gpu-job/watchdog.sh`. The third leg is the agent process **itself dying or wedging mid-run**, and nothing reliably catches it. The honest reason is mechanical: anything that could *notice* the agent is gone and resume it must not need the same Anthropic API that just went down — a heartbeat cron driven by a model is useless during an API outage, and Claude Code's built-in SDK retry is only a few attempts and not configurable, so a longer blip kills the session. When that happens with a 2×H200 pod attached, the pod bills for hours with no brain to collect the result or tear it down (the 2026-06-13 incident: an intermittent Anthropic API error inside Claude Code stranded a `$8.78/hr` pod for ~3h). This is the boundary #52 already named: the cron survives the agent going idle, but not the agent dying.

The fix has to be a **dumb, model-free supervisor** that runs on the always-on box, makes zero model calls (so it survives a total API outage), and does two jobs: relaunch a dead/wedged agent so the run resumes where it left off, and reap any pod past its cost cap. The subtlety this design exists to resolve is that **a non-trivial piece of this already exists and partly works** — so the deliverable is not "build a supervisor from scratch," it's pinning down the *residual* gaps the existing pieces miss, deciding what is product scaffold vs instance machinery, and writing the resume contract the agent must hold up its end of.

## What already exists (and why this is design-first, not build-first)

This box already runs a non-LLM respawn loop per fleet session:

- **`claude-pane-loop.sh`** (instance) runs `claude` in a `while` loop inside its tmux pane. A non-zero exit with no deliberate-restart flag is treated as a crash and **auto-relaunched with `--continue`** (same conversation, from the on-disk session JSONL), rate-limited so a crash-storm can't spin forever (>5 crashes in 120s → give up).
- **`restart-self.sh`** (instance) lets a session restart itself `continue` / `fresh` / `handoff`; the `handoff` mode requires a `TEMP.md` "will" to exist before it drops context.
- **`new-claude.sh`** (instance) already detects a predecessor `TEMP.md` on a fresh launch and seeds the successor to read it.
- **`gpu-job/watchdog.sh`** (product) reaps one pod after a grace period unless a future-dated `/workspace/.keepalive_until_utc` is present.

So three of the issue's four asks are *partly* met already. The design's real content is the gap analysis: what the existing pieces do **not** cover, and which of those gaps are worth closing, in which layer.

### The residual gaps (what the existing pieces miss)

1. **Wedge, not just crash.** `claude-pane-loop.sh` only acts on a process *exit* (a non-zero return code). An agent that is *hung* — process alive, event loop stuck on a wedged API call or a deadlocked tool — never exits, so the loop never relaunches it. There is no liveness probe that distinguishes "working" from "wedged." This is the harder, more common half of "the agent dying."
2. **No box-level pod reaper independent of the run, and no ownership source one could safely use.** `gpu-job/watchdog.sh` is armed *per run, by the agent*, and scoped to one pod id. If the agent dies before arming it (or the run's brief never armed it correctly, as #52 found a subagent doing), no reaper exists. But a box-level reaper can't simply "list all pods and delete the idle ones" — `gpu-job`'s standing rule is **"Teardown is pod-id-scoped. Never blanket-delete 'idle' pods"** (a blanket sweep would kill a live peer's compute). There is no **trusted lease/ownership record** the agent writes *at acquire time* that a model-free sweep could safely act on. Closing this gap is therefore two things, not one: a lease written atomically when a pod is acquired, and a sweep that only ever reaps **expired, registered** leases.
3. **The successor handoff is not standing.** `TEMP.md` today is written only at a deliberate `handoff` restart (and `run-experiment` mentions it only for block-prone content). For the deaths that **cannot resume in place** — a usage-policy block that kills the thread's ability to even write its own will, or a corrupted session JSONL — there is no *always-current* handoff for a fresh successor to pick up. `--continue` recovers the same session; it does not help when the same session is unrecoverable.
4. **No documented resume contract.** The agent has to hold up its end for `--continue` to actually resume *useful* work (checkpoint state to disk, not only in conversation; keep the standing handoff current; never leave a pod un-reaped behind an in-conversation-only note). None of this is written down as a product expectation, so it degrades silently — exactly the #52 failure shape.

## Approach

Split the work along the **product vs instance** seam (AGENTS.md "Two orthogonal cuts"), because the supervisor is half generic contract and half this-box wiring. The design PR lands this decomposition; the `ready` children implement each piece.

### A. The resume contract (product — `experiment-lifecycle` + `gpu-job` docs)

Write down, as a product expectation, what makes a run *resumable by a model-free supervisor* — the contract the agent must satisfy so that a blind relaunch actually recovers the run:

- **Checkpoint to disk, not only to conversation.** Run state a successor needs (what's launched, pod ids, what's been collected, the pre-registered decision rules) lives in the run's artifact dir / `START.md` / ledger, not only in the conversation. `--continue` replays the conversation, but a *fresh* successor only has the disk.
- **The standing successor handoff.** Promote `TEMP.md` from a block-only artifact to an **always-current** successor handoff, refreshed at checkpoints (pointers only — pod ids, artifact paths, the active look-again deadline, next action; never trigger-prone prose). This is the input both to `new-claude.sh`'s existing predecessor-seed path and to a supervisor that must launch a *fresh* successor when same-session resume is impossible.
- **Never leave a pod behind an in-conversation-only note.** A pod's existence and its cost-cap deadline must be on disk (the keepalive contract + the standing handoff), so the reaper can find it without the agent.

This layer is **docs/protocol only** — it changes what the skills *require*, mirroring how #52 pinned the executor substrate without building a detector. It is also the precondition that makes the instance supervisor's blind relaunch safe.

### B. The pod-lease + model-free supervisor (canonical homes fixed here)

The reaper's correctness hinges on a **trusted lease**, so this design fixes the lease shape and its home rather than deferring them (the prior draft deferred the module/interface boundary, which contradicts a `ready` child).

**B.0 — The pod lease (product — `gpu-job`, the load-bearing piece).** `gpu-job` acquire writes a **controller-side lease record atomically as part of returning pod-success**, before the agent does anything else. The lease is the single trusted ownership/expiry source the model-free sweep reads. Its fields: **pod id; deploying API-key name; owner/run artifact path; SSH endpoint; expiry / cost cap** (the same future-dated stamp the existing `keepalive_until_utc` already encodes, lifted from pod-side to a controller-side registry so it survives the pod and the agent). Canonical home: a `gpu-job` lease registry — generic schema + read/write helpers in `plugins/gpu-job/skills/gpu-job/scripts/`, instance registry path under `~/.config/gpu-job/`. This both fixes the "agent died before arming the watchdog" hole (the lease is written at acquire, not later by the agent) and gives the sweep something safe to act on.

**B.1 — Box-level pod reap (instance sweep over the product lease).** A standing model-free sweep lists pods via the RunPod REST API and `curl -X DELETE` **only leases that are registered AND expired**; an **unknown** pod (no lease) is **reported, never deleted** — preserving `gpu-job`'s "never blanket-delete idle pods" rule. This is the always-on counterpart to the per-pod `watchdog.sh`: it catches the pod whose run never armed a watchdog, without the blanket-delete hazard. Generic decision logic (reap-expired-registered-only, report-unknown) is a `gpu-job` reference; the systemd/bash wiring + RunPod key are instance.

**B.2 — Liveness + relaunch (instance supervisor over a product-defined stuck contract).** A standing, model-free supervisor on the always-on box (systemd timer or a `setsid` bash loop — **zero model calls**) probes each fleet session and relaunches a dead/wedged one. Because mtime-or-heartbeat alone is **not a safe stuck predicate** (it can restart healthy quiet work), this design fixes the **per-substrate stuck contract** the probe must satisfy, as a product spec:

- **Observed-progress source:** the session's on-disk transcript JSONL advancing (bytes/turns appended), the agreed positive-progress signal — *plus* a foreground-tool guard.
- **Active-foreground-tool detection:** a long-running but *healthy* tool (a multi-minute compile, a background-wait poll, a model still streaming) must read as alive even with a quiet transcript — the probe checks for a live child/tool process before declaring stuck.
- **Stale threshold:** no progress AND no active foreground tool for a bounded window (tuned per substrate; the `run-experiment` self-wake's ~12-min liveness cadence is the reference) before any action.
- **Kill/resume lock + idempotence:** a single-writer lock so the supervisor never double-relaunches or races `claude-pane-loop.sh`'s own respawn; relaunch is idempotent (a second invocation while one is in flight is a no-op).

On a confirmed stuck/dead session: prefer same-session resume (`--continue`, the path `claude-pane-loop.sh` already owns) and fall back to a **fresh successor seeded from the standing `TEMP.md`** when same-session resume is impossible (corrupted JSONL, policy block). Exponential backoff + the loop's existing crash-storm cap.

**Canonical-home decision (fixed here, not deferred).** The **lease schema + reaper decision logic** are `gpu-job` (pod lifecycle is its domain). The **stuck contract + relaunch decision tree** are an `experiment-lifecycle` / `run-experiment` reference (executor liveness is that layer's domain). All *instance values* (session names, paths, RunPod key, systemd unit, `claude-pane-loop.sh`) stay under `~/.config/` / instance scripts per the releasability rule. The children below are `ready` because every product interface boundary is named here; only the instance file-level wiring is theirs.

### C. The cheap quick-wins (instance settings — fold in immediately)

Independent of the supervisor: bump `API_TIMEOUT_MS` and set `API_FORCE_IDLE_TIMEOUT="0"` in the instance settings so a *short* API blip is ridden out in-process rather than killing the session at all. A `StopFailure` hook can *fire* on an API error (kick the supervisor / push-notify) but **cannot itself resume** the session — documented as a notifier, not a fix, so it isn't mistaken for the recovery path.

### Decomposition into `ready` children

This design PR (doc-only) spawns these implementable units, each a normal single-phase ship-change:

1. **Resume contract in the product skills + templates** (A) — `run-experiment` / `design-experiment`: the checkpoint-to-disk requirement + the standing always-current `TEMP.md` handoff (promoting it from block-only). Crucially this includes the **zero-context executor's point-of-need gates**: a blocking `CHECKLIST_TEMPLATE.md` item ("standing successor handoff current; pod lease registered") and `START_TEMPLATE.md` wording telling the executor where to maintain the handoff — the templates are where the executor actually reads its obligations, not only the SKILL prose. Docs/protocol only.
2. **Pod lease at acquire + box-level reaper over it** (B.0 + B.1) — `gpu-job` acquire writes the controller-side lease atomically (pod id, key name, run path, SSH endpoint, expiry/cost-cap) into a `gpu-job` registry; the standing model-free sweep reaps **only expired registered leases** and **reports unknown pods, never deletes them**. Generic lease schema + reaper logic in `gpu-job`; instance registry path + sweep wiring out. Closes the "agent died before arming the per-pod watchdog" hole *without* the blanket-delete hazard. The lease (B.0) lands first; the sweep (B.1) consumes it.
3. **Liveness-probe + relaunch supervisor** (B.2) — the **per-substrate stuck contract** (transcript-progress source + active-foreground-tool guard + stale threshold + kill/resume lock/idempotence) as an `experiment-lifecycle` reference, plus the relaunch decision tree (`--continue` else fresh-from-`TEMP.md`), building on `claude-pane-loop.sh`. Generic stuck-contract + decision logic as a product spec; the systemd/bash wiring is instance.
4. **Settings quick-wins + `StopFailure` notifier** (C) — `API_TIMEOUT_MS` / `API_FORCE_IDLE_TIMEOUT` + the fire-not-resume hook. Mostly instance; the "notifier ≠ recovery" note is a one-line product clarification.

Children 1 and 2 are independent and can land first (2 closes the cost-leak directly; within it the lease precedes the sweep). Child 3 depends on **child 1's standing-handoff contract** (the fresh-successor branch's input) and reads **child 2's lease** to know which pod a relaunched session owns. Child 4 is independent.

## Alternatives considered

- **One monolithic supervisor issue, build directly (skip the design PR).** Rejected: the issue is `needs-design` precisely because it conflates four asks across the product/instance seam and overlaps existing machinery. Building blind would either duplicate `claude-pane-loop.sh` or bury generic logic in instance scripts. The decomposition *is* the deliverable.
- **Make the supervisor itself model-driven (an LLM watchdog).** Rejected at the root: the whole point is surviving an API outage. A model-free probe is non-negotiable; this is why the liveness check is mtime/heartbeat-based, not "ask a model if the agent looks stuck."
- **Lean only on `claude-pane-loop.sh` (it already resumes on crash).** Rejected as incomplete: it acts on process *exit* only, so it misses the wedge (alive-but-hung) case, has no fresh-successor fallback for unrecoverable sessions, and does nothing about orphaned pods. It's the foundation to build on, not the whole answer.
- **Per-run self-destruct backstop only (the current interim).** Rejected as sufficient: the `setsid sleep + curl DELETE` backstop caps *cost* but only *reaps* — it never *resumes* the run. The supervisor's distinguishing value is resume; reaping is the half we already have.
- **Wire the supervisor to a subagent executor.** Rejected per #52: a subagent isn't independently resumable (no `--continue`), which is itself a reason the durable executor must be a `new-claude.sh` session. The supervisor assumes a real session substrate.

## Blast radius

This design PR: **`proposals/54-crash-resilience-supervisor.md` only** (doc-only, `--design` gate). No code.

The spawned children will touch:

- **Product:** `plugins/experiment-lifecycle/skills/{run-experiment,design-experiment}/SKILL.md` (resume contract + standing handoff) and its **templates** (`CHECKLIST_TEMPLATE.md` blocking item + `START_TEMPLATE.md` wording — the executor's point-of-need gates), the stuck-contract reference; `plugins/gpu-job/skills/gpu-job/` (the lease schema + read/write helpers + the reaper decision logic — reap-expired-registered-only, report-unknown); the relevant `plugin.json` version bumps, `CHANGELOG`.
- **Instance (NOT this repo):** the systemd unit / bash supervisor loop, this box's session/path/RunPod wiring under `~/.config/`, the `settings.json` quick-wins, the `claude-pane-loop.sh` liveness extension. These ship in the consuming instance, with same-day pointers back to the product spec per the AGENTS.md pointer rule.

No change to the SWE pipeline (`aar-engineering`) itself.

## Rollout + rollback

Ship each child through `ship-change` independently. Sequence by dependency: children 1, 2, 4 first (independent; 2 closes the cost-leak directly, and within it the **lease (B.0) must land before the sweep (B.1)** — the sweep is unsafe without the trusted lease to read); child 3 after child 1 lands the standing-handoff contract it consumes. Roll the **reaper sweep** out in **dry-run first** (log the DELETEs it *would* issue, reconciled against the ledger + the lease registry) before it deletes for real — a buggy reaper that kills a live run is the one new failure mode this introduces, so it gets a watched dry-run window; the **report-unknown-never-delete** rule means an un-leased peer pod is never at risk even out of dry-run. The **supervisor relaunch** keeps `claude-pane-loop.sh`'s existing crash-storm cap so a relaunch loop can't spin. Each child is a normal one-commit squash on `main`; rollback is the standard revert. Disabling the instance supervisor is a `systemctl disable` (or removing the loop) with no product change required — the product-side contract (lease schema, stuck contract, handoff) is inert without the instance supervisor consuming it.
