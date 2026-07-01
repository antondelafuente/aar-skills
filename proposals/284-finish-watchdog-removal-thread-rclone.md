# Finish the #266 watchdog removal + default multi-threaded rclone (#284)

## Problem
Two small pod-lifecycle leftovers:
1. **Watchdog removal is incomplete.** PR #288 retired the per-pod `watchdog.sh` but — scoped off the
   experiment-lifecycle plugin — left it as a no-op shim plus stale "arm the watchdog" references in
   `run-experiment/SKILL.md`. Dead code + guidance that points at a retired mechanism.
2. **Single-stream R2 pulls throttle to ~1 MB/s** (#284). Eval-driver / provisioning `rclone` pulls of
   multi-GB venvs and 32B adapters run single-stream, turning minutes-long pulls into stalls; multiple
   runs have hand-patched their driver mid-run. Measured on `midtrain-pareto`: ~1 MB/s → ~148 MB/s (~150×)
   with multi-thread streams.

## Approach
- **Delete** `gpu-job/.../watchdog.sh` (the shim) and fix the `run-experiment/SKILL.md` refs: drop
  `watchdog` from the two gpu-job feature lists, and rewrite the "stepping away → arm the idle-teardown
  watchdog" step to reflect the settled model — the unit is lease-covered and `pod_reaper.sh` (the lease
  reaper) is the sole backstop; set a short lease for faster idle teardown. `gpu-job/SKILL.md:66` already
  documents the retirement (kept).
- **Default multi-threaded rclone** in the pod bootstrap: `bootstrap_pod.sh` writes
  `RCLONE_MULTI_THREAD_STREAMS=16` + `RCLONE_MULTI_THREAD_CUTOFF=100M` to `/etc/environment`, so EVERY pod
  shell — including `ssh pod 'rclone …'` used by the registry eval-drivers — inherits it. Universal and
  overridable per-call; needs a root pod (RunPod default), skipped gracefully otherwise. This covers both
  the gpu-job provisioning pulls AND the registry `confirm_eval.sh`-style drivers via env inheritance, so
  no separate research-lab change is required.

## Alternatives
- Edit each `rclone` call to add flags — rejected: the `/etc/environment` default is universal (covers the
  registry eval-drivers we don't own here) and overridable, without touching every call site.
- Keep the shim — rejected: dead code that only invites confusion now that consumers are migrated.

## Blast radius
- Removing the shim: verified only intentional retirement notes remain (`gpu-job/SKILL.md`,
  `run-experiment/SKILL.md`). `run-experiment` "stepping away" now relies on the lease reaper — the
  intended result of #266 (no fast idle-teardown; the lease at expiry is the backstop).
- **Left deliberately:** the `design-experiment/CHECKLIST_TEMPLATE.md` references to a "box-side
  idle-teardown watchdog" — those encode the **Codex run-supervision model** (tied to
  `run_supervision_record.sh`), a broader concern than the retired per-pod script. Rewriting them is a
  design call, not this mechanical cleanup — flagged for a separate pass, not guessed here.
- The rclone env default is pod-wide + overridable; worst case a per-call `--multi-thread-streams 1`
  restores single-stream.

## Rollout
#266 was already closed by #288; this completes it. Closes #284 — the pod-env default is the universal
fix (registry eval-drivers inherit it), so no separate registry change is needed.
