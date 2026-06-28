# Proposal: Hide Experiment Run-State Bookkeeping Behind One Helper (#200)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The crash-resilience work added the right underlying safety mechanisms for long experiment runs, but it
exposed too many separate state surfaces to every executor: `TEMP.md`, the run-supervision JSON record, pod
lease records, wake/look-again markers, checklist evidence, and close-ordering details. Each surface has a real
job, but the agent-facing protocol now asks executors to remember too much bookkeeping while they are supposed
to be running the experiment.

The failure mode is not that pod leases or run-supervision are bad. The failure mode is manual coordination:
an executor can cargo-cult a checklist line, forget one record, or update the handoff without linking the pod.
That recreates the same fragility the crash-resilience work was meant to remove.

## Approach

Add one small `run_state.sh` helper under `experiment-lifecycle/skills/run-experiment/scripts/`. It is an
agent-facing facade over the existing product helpers:

- `start <run-id> --handoff TEMP.md [--session-handle H]` creates the run-supervision record.
- `checkpoint <run-id> [--handoff TEMP.md] [--session-handle H] [--lease-pod ID]...` refreshes the run record.
- `pod <run-id> <lease-id-or-pod-id> [--expiry-min N]` links a pod/lease to the run and, when a lease exists,
  refreshes the pod lease TTL.
- `request-relaunch <run-id> [--reason TEXT]` exposes the existing positive recovery signal.
- `status <run-id>` prints the run record and linked lease summaries for checklist evidence.
- `close <run-id>` / `stop <run-id>` finalize the run-supervision record, preserving the existing
  post-audit-finalizer ordering.

This does not replace the underlying records. It hides them behind a smaller verb set so the visible protocol is
"start / checkpoint / pod / status / close" rather than "remember every internal JSON record and their ordering."

Update `run-experiment`, `START_TEMPLATE.md`, and `CHECKLIST_TEMPLATE.md` to name the wrapper as the preferred
interface. The docs should still state the invariant (run state and pod backstops are armed), but the evidence
line becomes `run_state.sh status <run-id>` instead of a paragraph of internal implementation details.

## Alternatives considered

- **Remove the new state records.** Rejected for now. The pod lease/reaper and run-supervision record encode real
  failures and already have smoke coverage. Removing them would trade a protocol-load problem for a safety
  regression.
- **Move this into GitHub Actions.** Rejected for live experiment state. GitHub Actions are appropriate for repo
  merge gates, not local/tmux session state or destructive cloud-pod deletion.
- **Only edit prose.** Rejected. More instructions would worsen the problem. The fix needs an executable
  interface.

## Blast radius

Product layer only, inside `experiment-lifecycle`. The wrapper reads the sibling `run_supervision_record.sh`
helper and, when available, the `gpu-job` plugin's `pod_lease.sh` helper via the repository layout. It does not
change provider deletion behavior, the model-free relaunch supervisor contract, or the `gpu-job` reaper.

The change also updates experiment-lifecycle templates and skill prose, so generated briefs teach the smaller
interface. The wrapper is additive: existing lower-level helpers remain callable for debugging and migration.

## Rollout + rollback

Roll out with a smoke test that uses temporary record roots and a temporary fake `pod_lease.sh`, verifying that
the wrapper creates, checkpoints, links pods, refreshes lease TTLs, exposes status, and finalizes records. The
existing run-supervision and gpu-job smokes remain the lower-level coverage.

Rollback is a normal revert of this PR. Because the underlying helpers remain unchanged, reverting only removes
the facade and restores the previous explicit protocol.
