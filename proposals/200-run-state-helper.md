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
agent-facing facade over the existing **run-supervision** helper, not a new state store:

- `start <run-id> --handoff TEMP.md [--session-handle H]` creates the run-supervision record.
- `checkpoint <run-id> [--handoff TEMP.md] [--session-handle H] [--lease-pod ID]...` refreshes the run record.
- `pod <run-id> <pod-id>` links a pod id to the run-supervision record. It does **not** refresh or mutate the
  pod lease; deletion/TTL policy remains in `gpu-job`.
- `request-relaunch <run-id> [--reason TEXT]` exposes the existing positive recovery signal.
- `status <run-id>` prints a compact run-state summary for checklist evidence.
- `close <run-id>` / `stop <run-id>` finalize the run-supervision record, preserving the existing
  post-audit-finalizer ordering.

This does not replace the underlying record or change its state machine. It hides the common run-supervision
operations behind run-lifecycle words so the visible protocol is "start / checkpoint / pod / status / close"
rather than "remember the exact lower-level `create/update/show/close` calls." The helper must preserve the
underlying fail-closed exit semantics: if `run_supervision_record.sh` would reject a terminal/corrupt/missing
record, the wrapper rejects it too.

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
- **Have `run_state.sh` call `gpu-job`'s `pod_lease.sh`.** Rejected after scaffold review. Cross-plugin helper
  discovery is not defined, and deletion policy belongs to `gpu-job`. The wrapper may link pod ids into
  run-supervision, but pod lease creation/refresh remains the `gpu-job` interface.

## Blast radius

Product layer only, inside `experiment-lifecycle`. The wrapper reads only the sibling
`run_supervision_record.sh` helper. It does not call `gpu-job`, does not change provider deletion behavior, does
not change pod lease TTL policy, and does not change the model-free relaunch supervisor contract.

The change also updates both halves of the experiment-lifecycle plugin: `run-experiment` skill prose and the
`design-experiment/templates/` files that seed `START.md` and `CHECKLIST.md`. The wrapper is additive: existing
lower-level helpers remain callable for debugging and migration.

## Rollout + rollback

Roll out with a smoke test that uses a temporary run-supervision root, verifying that the wrapper creates,
checkpoints, links pod ids, exposes status, refuses invalid/terminal operations through the underlying
fail-closed behavior, and finalizes records. The existing run-supervision and gpu-job smokes remain the
lower-level coverage.

Rollback is a normal revert of this PR. Because the underlying helpers remain unchanged, reverting only removes
the facade and restores the previous explicit protocol.
