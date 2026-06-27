# Proposal: pod lease at acquire (3-phase, deletion-scoped) + box-level model-free reaper (#169)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

A GPU pod starts billing the instant it is created and keeps billing until something deletes it. Today the only thing that reliably deletes an abandoned pod is the per-pod `watchdog.sh`, which the agent arms *by hand, after the run is underway*. If the agent dies before arming it — or a subagent's brief never armed it (the #52 failure), or the box-level wrapper itself dies — there is no standing process that will ever reap that pod. It bills until a human notices (the 2026-06-13 incident: a `$8.78/hr` pod stranded for ~3 hours). The general fix is a dumb, always-on, model-free sweep on the box that can delete an abandoned pod without any live agent. But a box-level sweep cannot simply "list all pods and delete the idle-looking ones" — that would kill a live peer's compute, and `gpu-job`'s standing rule is "teardown is pod-id-scoped; never blanket-delete idle pods." A safe sweep needs a *trusted ownership record* it can read: a record, written when the pod is acquired, that says "this pod is reapable after time T." There is no such record today.

This issue (the #54 design's child 2) closes that gap in two linked pieces. First, a **pod lease** written by `gpu-job` at acquire time — a tiny, deletion-scoped record carrying only what *deletion* needs: the pod id (or, before the id exists, a unique deploy nonce), a durable key reference the standing sweep can authenticate with on its own, an expiry, and — once known — the SSH endpoint. Second, a **box-level, model-free reaper** that lists pods, deletes only leases that are both *registered and past expiry*, and *reports but never deletes* any pod with no lease. The lease is the load-bearing half: it is what gives the sweep the authority to delete safely.

## Approach

Two deliverables, split along the product/instance seam. The **generic lease schema + its fail-closed lifecycle API + the reaper's decision logic** are product (`gpu-job`). The concrete sweep wiring (systemd/bash loop, the RunPod key, the instance registry path) is instance and ships in the consuming box — this PR ships only the reusable parts plus the reaper decision logic as a runnable reference.

### B.0 — The pod lease + its fail-closed lifecycle API (`gpu-job`, the load-bearing piece)

A new `pod_lease.sh` helper in `plugins/gpu-job/skills/gpu-job/scripts/`, mirroring the atomic-write + per-record-lock discipline of the sibling `run_supervision_record.sh` (#168). The lease registry lives at an instance-overridable root (`${GPU_JOB_LEASE_DIR:-$HOME/.config/gpu-job/leases}`). The lease is **deletion-scoped only**: pod id (or pre-deploy nonce), the durable reaper-resolvable key reference, expiry, cost cap, and — once enriched — the SSH endpoint. Anything run-shaped (owner, artifact path, handoff) belongs in the run-supervision record, not here, so a standalone `gpu-job` caller still gets a valid, reapable lease with no run context.

**Three-phase create, so there is no un-leased billing window.** The window between RunPod returning a pod id and the lease being written is a real (if tiny) hole: a crash there leaves a billing pod the sweep can only *report*. So creation is three phases:

1. **intent** (pre-deploy): write a record with a unique nonce, the key reference, and a short default expiry *before* `deploy()` is called, and pass that nonce as the pod's name/tag. The sweep can now match an otherwise-unknown pod to a pending intent **by nonce** and reap it on the intent's expiry — even a pod that was created but whose id never came back.
2. **provisional** (after `deploy()` returns the id): bind the real pod id to the intent.
3. **enriched** (after `wait_ssh`): add the SSH endpoint and the run's real expiry.

If the flow dies at any phase, the record is already near its short default expiry, so the sweep reaps the half-born pod rather than letting it bill forever.

**Write-failure path — fail closed, not just loud.** If the provisional-lease write fails *after* the pod is REST-created, the pod is already billing with no lease. So the helper exposes the failure path explicitly: the acquire wrapper must **synchronously attempt `DELETE` with the deploying key** and exit with evidence — either the pod was deleted, or an **emergency unreaped-pod record** is written (the one place the sweep/human looks) — never a silent orphan.

**The other three operations:**

- **enrich / refresh** — enrich fills the SSH endpoint and the real expiry; a long run extends `expiry` (the controller-side generalization of today's pod-side `keepalive_until_utc`, lifted off the pod so it survives the pod and the agent).
- **close — only after verified provider-side deletion.** Closing the lease before the pod is confirmed gone would turn a failed teardown into an *unknown* pod the sweep only reports (a billing orphan). So `close` is the *consequence* of a verified delete, never a substitute; a teardown whose delete didn't verify leaves the lease expired for the sweep to retry.
- **expiry is the only deletion trigger** — never "looks idle." A live run keeps its lease fresh; a dead run's lease lapses and the pod is reaped.

The lifecycle is wired into the existing scripts: `deploy_pod.py` writes intent → provisional → enriched across its deploy/`wait_ssh` flow (with the write-failure DELETE path), and `teardown.sh` closes the lease only after it verifies the pod is gone on the control plane.

### B.1 — Box-level reaper decision logic (`gpu-job` reference) + the instance sweep contract

A `reaper_decide.sh` reference helper in `gpu-job` carries the *pure decision logic*: given the live pod list and the lease registry, classify each pod as **reap** (registered AND past expiry), **keep** (registered, not expired), or **report-only** (unknown — no lease), and match an unknown pod to a pending intent by nonce before calling it unknown. This is the testable core; the instance sweep loops it, issues the `curl -X DELETE` for the `reap` set, and logs the `report-only` set — but the *decision* never blanket-deletes, because the report-unknown-never-delete rule lives in the shared logic, not the instance wiring.

**Migration / back-compat.** During the transition off the pod-side `keepalive_until_utc`, a pod is reaped only when **both** the controller lease is past expiry **and** no future-dated pod-side keepalive is present (read over the enriched SSH endpoint, the existing `watchdog.sh` contract). **Fail-safe** when the keepalive can't be read (still provisional / no SSH endpoint yet, or the read fails): fall back to lease-expiry as the sole authority — an unreadable pod-side file never *protects* a pod past its lease expiry. Equivalently the lease carries a refresh-contract version and the strict controller-only rule applies only to new-version leases.

The reaper rolls out **dry-run first** (log the DELETEs it *would* issue, reconciled against the lease registry + ledger) before it deletes for real — a buggy reaper that kills a live run is the one new failure mode this introduces. The report-unknown-never-delete rule means an un-leased peer pod is never at risk even out of dry-run.

## Alternatives considered

- **One-phase lease (write it only after `deploy()` returns the id).** Rejected: leaves the un-leased billing window the three-phase intent closes. A pod created-but-id-never-returned would be invisible to the sweep.
- **Put owner / run-artifact / handoff fields on the lease too (one fat record).** Rejected: that is the run-supervision record's domain (#168). Fattening the lease with run-shaped fields would force experiment context onto a generic tool and re-home relaunch policy into `gpu-job`, which it must not own. The two records link by pod id; neither owns the other's policy.
- **Reaper deletes any pod with no recent activity ("idle sweep").** Rejected at the root: it would kill a live peer's compute and violates `gpu-job`'s pod-id-scoped rule. Expiry-on-a-registered-lease is the only safe deletion trigger; an unknown pod is reported, never deleted.
- **Lease records only the key *name* present in the launching shell.** Rejected: the standing sweep runs in its own environment and must resolve the key on its own. The lease records a *reaper-resolvable* key reference, validated at creation — a lease the sweep can't authenticate is a lease it can't act on.
- **`close` clears the lease optimistically at teardown.** Rejected: a teardown whose delete silently failed would then read as an *unknown* (un-leased) pod the sweep only reports — a billing orphan. `close` must follow a *verified* deletion.

## Blast radius

- **Product (`gpu-job`):** new `scripts/pod_lease.sh` (lifecycle API) + `scripts/reaper_decide.sh` (reaper decision reference) + dedicated smokes (`pod_lease_smoke.sh`, `reaper_decide_smoke.sh`); lease writes wired into `deploy_pod.py` (intent/provisional/enriched + write-failure DELETE) and the close into `teardown.sh` (only after verified deletion); `SKILL.md` gains a lease-lifecycle + standalone-refresh section; a `.aar-ci/checks.sh` stanza runs the two new smokes; `plugin.json` version bump + `CHANGELOG` entry.
- **Instance (NOT this repo):** the systemd unit / bash sweep loop that loops `reaper_decide.sh`, the RunPod key, the registry path under `~/.config/`. These ship in the consuming instance with same-day pointers back to this spec.
- **No change** to the run-supervision record (#168), the relaunch supervisor (child 3), or the SWE pipeline. This child links to the run-supervision record by pod id but does not modify it.

## Rollout + rollback

The lease (B.0) lands and is exercised by acquire/teardown first; the reaper (B.1) consumes it. Roll the instance sweep out **dry-run first** (log would-be DELETEs, reconcile against the ledger + lease registry) before it deletes for real. The reaper's report-unknown-never-delete rule protects un-leased peer pods even out of dry-run. Rollback is the standard one-commit revert; disabling the instance sweep is a `systemctl disable` with no product change — the lease schema is inert without a sweep consuming it, and acquire/teardown continue to write/close leases harmlessly.
