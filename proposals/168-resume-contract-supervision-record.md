# Proposal: resume contract + run-supervision record + executor template gates (#168)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Implements child 1 of the merged #54 design (`proposals/54-crash-resilience-supervisor.md`).

## Problem

When an autonomous research run dies mid-flight — the agent process crashes, the API blips long
enough to kill the session, or a usage-policy block ends the thread — a model-free supervisor on the
always-on box is supposed to relaunch it and pick the run back up. But a blind relaunch only recovers
*useful* work if the run held up its end of a contract: the state a successor needs (which pods are
live, what's been collected, the decision rules) has to be on disk, not only in the dead conversation;
there has to be an always-current handoff a fresh successor can read; and there has to be a
machine-readable record telling the supervisor whether this run is even *supposed* to be alive — so it
relaunches a genuine crash but never resurrects a run that was deliberately stopped. None of that is
written down today, and the one piece that is genuinely stateful (the desired-active / stop signal the
supervisor reads) has no implementation, so every consumer would re-derive its atomic-write semantics
from prose and drift.

This child closes that gap on the executor side: the **resume contract** (the prose discipline the
agent follows), a small **run-supervision-record helper** (the real machine-consumed state the
supervisor and instance wrappers read/write through one implementation), and the **executor's
point-of-need template gates** (the open + close checklist items where the executor actually reads its
obligations — not buried SKILL prose). It does not build the supervisor, the pod lease, or the reaper
(those are children 2 and 3); it builds the contract and the record they consume.

## Approach

Three deliverables, split by where the executor reads them.

### 1. The resume-contract prose (`run-experiment` + `design-experiment` SKILL.md)

Write down, as a product expectation, what makes a run *resumable by a model-free supervisor*:

- **Checkpoint to disk, not only to conversation.** Run state a successor needs — what's launched, pod
  ids, what's been collected, the pre-registered decision rules — lives in the run's artifact dir /
  `START.md` / ledger, not only in the conversation. `--continue` replays the conversation, but a
  *fresh* successor only has the disk.
- **The standing successor handoff.** Promote `TEMP.md` from a block-only artifact to an
  **always-current** successor handoff, refreshed at checkpoints — pointers only (pod ids, artifact
  paths, the active look-again deadline, next action), never trigger-prone prose. This is the input the
  supervisor's fresh-successor branch feeds to the launch-successor path when same-session resume is
  impossible.
- **Never leave a pod behind an in-conversation-only note.** A pod's existence and its cost-cap
  deadline must be on disk (the keepalive contract + the standing handoff), so a reaper can find it
  without the agent.

This prose is docs/protocol — it mirrors how #52 pinned the executor substrate without building a
detector. It is added to `run-experiment` (the executor's runbook) and pointed at from
`design-experiment` (so the designer writes the brief to support it).

### 2. The run-supervision-record helper + path/schema (`run-experiment/scripts/`)

The record is **machine-consumed state, NOT docs-only** — so it ships as one product implementation
rather than prose every consumer re-derives. A small POSIX-shell helper
(`run_supervision_record.sh`) implemented as a **serialized, monotonic state machine** (fail-closed,
atomic-write):

- `create <run-id> [--handoff PATH]` — mark the run **desired-active** at run start.
- `update <run-id> [--handoff PATH] [--lease-pod ID]...` — refresh the `handoff_path` and the linked
  lease pod-ids at checkpoints (additive on pod-ids). **`update` can never clear `stopped` or
  re-activate a closed record** — once a run is stopped or closed, that state is terminal; `update`
  fails closed on it rather than resurrecting a deliberately-stopped run.
- `stop <run-id>` — write the **deliberate-stop marker** (a `/quit` or manual kill: the supervisor must
  NOT resurrect this). Terminal.
- `close <run-id>` — mark the record **inactive** (run finished). Terminal.
- `is-desired-active <run-id>` — exit 0 iff the run is desired-active AND has no stop marker AND is not
  closed (the single predicate the supervisor branches on); exit 1 otherwise, including a missing record
  (fail-closed: an unknown run is never resurrected).

**Concurrency (Finding-driven).** Atomic file replacement alone is not enough: a concurrent `update`
racing a `stop`/`close` could otherwise read-modify-write over the terminal state and re-activate a
stopped run. So every mutation takes a **per-record `flock`** for the read-modify-write window, and the
terminal-state guard runs *inside* that lock — `update` re-reads under the lock and refuses if the record
is already `stopped`/`closed`. The race (`update` vs `stop`/`close`) is covered by the behavior smoke.

The record is a small JSON file under an instance-overridable root
(`${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}/<run-id>.json`). It carries
**relaunch-scoped** fields only — `desired_active`, `stopped`, `closed`, `handoff_path`,
`lease_pod_ids`, timestamps — and **links to** the `gpu-job` pod lease(s) (child 2) by pod id. It never
holds pod-deletion policy (that's the lease's domain). Writes go through a temp-file + `mv` under the
lock so a crash mid-write never leaves a half-written record. The product helper has **no instance
specifics** — session names, the concrete relaunch commands, the systemd wiring are all instance,
consumed via the API.

### 3. The executor's point-of-need template gates (`design-experiment/templates/`)

The templates are where the executor actually reads its obligations — not the SKILL prose. So:

- **`CHECKLIST_TEMPLATE.md` — an OPEN gate** (blocking): "standing successor handoff current;
  run-supervision record written (desired-active); each live pod registered for reaping." Beside the
  existing self-wake-armed open gate. **Pod registration is capability-gated (Finding-driven):** the
  `gpu-job` pod-lease API is child 2 and not yet built, so the gate's pod-registration clause is
  satisfied **either** by a registered lease (once child 2 lands) **or** by the existing per-pod
  idle-teardown watchdog (`gpu-job`'s `watchdog.sh`, scoped to the pod id). So child 1 lands with a
  gate the current machinery can already pass, and child 2 tightens it to the lease.
- **`CHECKLIST_TEMPLATE.md` — a CLOSE gate** (blocking) that verifies **close readiness**, NOT an early
  clear. This adopts the **readiness-vs-finalizer split** the in-tree #30 resolution fixed for exactly
  this gate (`proposals/30-ephemeral-dispatch-dirs.md`): the audited checklist gate verifies the
  run-supervision record exists and the close path is armed; the actual `desired-active`-clear / `close`
  is the **post-audit finalizer** (for a dispatched run, the same closer that kills the session; for a
  non-dispatched run, the executor's own post-audit close step). The ordering is load-bearing and the
  reason the clear is NOT an early audited gate: if the executor cleared `desired-active` at the top of
  Close and then crashed before the closer was durably in charge, the supervisor would (correctly)
  refuse to relaunch a not-desired-active run while no closer exists to tear down the pod — an orphaned,
  un-closed session. So the record stays desired-active until the close path is durably in charge; the
  gate beside the existing "self-wake/watchdog cleared" teardown gate verifies that readiness, and the
  `close` call is the finalizer after the audit.
- **`START_TEMPLATE.md` wording** telling the executor where to maintain the standing handoff and the
  run-supervision record.

## Alternatives considered

- **Docs-only (no helper).** Rejected by the parent design: the record is genuinely stateful and is the
  *precondition that makes the supervisor's blind relaunch safe*. Prose alone means every consumer
  (`claude-pane-loop.sh`, the stop helpers, child 3) re-derives atomic-write semantics and drifts — the
  exact silent-degradation shape #52 warned about. The resume-contract *prose* stays docs-only; the
  record does not.
- **Put the record in `gpu-job` next to the pod lease.** Rejected: the parent design fixes a hard seam —
  pod **deletion** is `gpu-job`'s domain, run/session **relaunch policy** is `experiment-lifecycle`'s.
  Folding desired-active/stop/handoff into the lease would put relaunch policy in a tool that doesn't own
  it. The two records link by pod id; neither owns the other's policy.
- **One combined open+close checklist item.** Rejected: the close gate has a distinct load-bearing
  property (the readiness-vs-finalizer split — the audited gate verifies the close path is armed; the
  `desired-active`-clear is the post-audit finalizer). It earns its own gate beside the existing teardown
  gate, not a sub-bullet of the open one.
- **An audited close gate that clears `desired-active` directly.** Rejected (Finding-driven): it
  conflicts with the in-tree #30 resolution, which fixed exactly this gate to verify *readiness* and make
  the clear a post-audit finalizer — clearing early then crashing before the closer is durably in charge
  leaves an un-closed, unsupervised session the supervisor will (correctly) refuse to relaunch. This
  child adopts #30's readiness-gate wording.

## Blast radius

**Product (this repo):**
- `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` — resume-contract prose + the record's
  create/update/stop/close lifecycle pointers in the open/drive/close steps.
- `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md` — a pointer so the designer writes the
  brief to support the contract.
- `plugins/experiment-lifecycle/skills/run-experiment/scripts/run_supervision_record.sh` (NEW) — the
  helper, atomic-write, fail-closed.
- `plugins/experiment-lifecycle/skills/design-experiment/templates/{CHECKLIST_TEMPLATE.md,START_TEMPLATE.md}`
  — the open + close gates + the START wording.
- `plugins/experiment-lifecycle/.claude-plugin/plugin.json` — version bump.

**Instance (NOT this repo):** the systemd/bash supervisor that *consumes* `is-desired-active`, the
session/path wiring, `claude-pane-loop.sh`'s desired-state check, the stop helpers that call
`stop`/`close`. These ship in the consuming instance per the parent design's product/instance seam,
with same-day pointers back to this spec.

No change to the SWE pipeline (`aar-engineering`) or to `gpu-job` (child 2 owns the lease).

## Rollout + rollback

Independent — can land first (the parent design lists children 1 and 2 as independent; child 3 depends
on this child's record + standing-handoff contract). The product-side contract is **inert without the
instance supervisor consuming it**: shipping the helper + prose + gates changes nothing operational
until an instance wires a supervisor to read `is-desired-active`. So the rollout risk is near-zero — a
run that writes a record nobody reads is harmless. Rollback is the standard one-commit revert. A
behavior smoke for the helper's lifecycle + atomicity ships in `.aar-ci` so the deterministic gate covers
the new code path.
