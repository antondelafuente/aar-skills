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

Extend the existing `run_supervision_record.sh` helper in place. Do not add a second facade script. The same
canonical helper gets a small agent-facing vocabulary plus a compact evidence command:

- `start <run-id> --handoff TEMP.md [--session-handle H]` is an alias for `create` at run start.
- `checkpoint <run-id> [--handoff TEMP.md] [--session-handle H] [--lease-pod ID]...` is an alias for `update`
  at each run checkpoint.
- `link-pod <run-id> <pod-id>` links a pod id to the run-supervision record. It does **not** refresh or mutate the
  pod lease; deletion/TTL policy remains in `gpu-job`.
- `status <run-id>` prints a compact run-state summary for checklist evidence.
- Existing `request-relaunch`, `clear-relaunch`, `close`, and `stop` remain the same.

This does not replace the underlying record or change its state machine. It gives executors lifecycle words while
preserving the supervisor/instance API. The helper must preserve the existing fail-closed exit semantics: if
`create`/`update` would reject a terminal/corrupt/missing record, `start`/`checkpoint`/`link-pod` reject it too.
`status` is read-only and must fail closed on missing/corrupt records.

The practical simplification is that generated briefs can say:

```bash
run_supervision_record.sh start "$RUN_ID" --handoff "$TEMP" --session-handle "$SESSION"
run_supervision_record.sh checkpoint "$RUN_ID" --handoff "$TEMP" --lease-pod "$POD_ID"
run_supervision_record.sh status "$RUN_ID"
run_supervision_record.sh close "$RUN_ID"
```

instead of teaching the executor the internal create/update/show vocabulary and separately explaining how to
turn that into checklist evidence.

The lower-level `create`/`update` names stay supported because the supervisor reference and existing instance
callers already use them, but the docs/templates should teach the run-lifecycle aliases to executors. The
`RELAUNCH_SUPERVISOR.md` reference should mention the aliases in the record API table so the two surfaces do
not drift.

Update `run-experiment`, `START_TEMPLATE.md`, and `CHECKLIST_TEMPLATE.md` to name the lifecycle aliases as the
preferred executor interface. The docs should still state the invariant (run state and pod backstops are armed), but the evidence
line becomes `run_supervision_record.sh status <run-id>` instead of a paragraph of internal implementation
details.

## Alternatives considered

- **Remove the new state records.** Rejected for now. The pod lease/reaper and run-supervision record encode real
  failures and already have smoke coverage. Removing them would trade a protocol-load problem for a safety
  regression.
- **Move this into GitHub Actions.** Rejected for live experiment state. GitHub Actions are appropriate for repo
  merge gates, not local/tmux session state or destructive cloud-pod deletion.
- **Only edit prose.** Rejected. More instructions would worsen the problem. The fix needs an executable
  interface.
- **Have `run_state.sh` call `gpu-job`'s `pod_lease.sh`.** Rejected after scaffold review. Cross-plugin helper
  discovery is not defined, and deletion policy belongs to `gpu-job`. The run-supervision helper may link pod ids into
  run-supervision, but pod lease creation/refresh remains the `gpu-job` interface.
- **Add a separate `run_state.sh` facade.** Rejected after scaffold review. It would create a second live
  interface over the same record and increase the vocabulary a debugger has to map. The right canonical home is
  the existing `run_supervision_record.sh` helper.

## Blast radius

Product layer only, inside `experiment-lifecycle`. It changes `run_supervision_record.sh`, its smoke test,
`run-experiment` skill prose, `RELAUNCH_SUPERVISOR.md`, and the `design-experiment/templates/` files that seed
`START.md` and `CHECKLIST.md`. It does not call `gpu-job`, does not change provider deletion behavior, does not
change pod lease TTL policy, and does not change the model-free relaunch supervisor decision tree.

The new aliases are additive: existing lower-level helper commands remain callable for the supervisor, instance
integrations, debugging, and migration.

## Rollout + rollback

Roll out by extending `run_supervision_record_smoke.sh` with temporary run-supervision roots, verifying that
`start`, `checkpoint`, `link-pod`, and `status` behave as the documented aliases, preserve fail-closed behavior,
and leave the existing `create`/`update`/`show`/`close`/`stop` behavior unchanged. The existing gpu-job smokes
remain the pod-lease coverage.

Rollback is a normal revert of this PR. Because the original helper commands remain unchanged, reverting only
removes the aliases/status surface and restores the previous explicit protocol.
