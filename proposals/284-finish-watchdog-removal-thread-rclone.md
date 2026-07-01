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
- **Default multi-threaded rclone** in the pod bootstrap (`bootstrap_pod.sh`): `export` the defaults
  (`RCLONE_MULTI_THREAD_STREAMS=16`, `RCLONE_MULTI_THREAD_CUTOFF=100M`) at the top so the bootstrap's OWN
  pulls use them, AND append them to `/etc/environment` so later PAM ssh sessions inherit them on standard
  pod images — which covers the registry `confirm_eval.sh` eval-drivers, since they run via `ssh pod '…'`.
  Overridable (respects a pre-set value); the `/etc/environment` write needs a root pod (RunPod default),
  skipped gracefully otherwise. NOT claimed universal — a job launched with an explicit `env` allowlist
  would need the var passed; it's the common eval-driver ssh path that's covered, which is the #284 pain.

## Alternatives
- Edit each `rclone` call to add flags — rejected: the `/etc/environment` default is universal (covers the
  registry eval-drivers we don't own here) and overridable, without touching every call site.
- Keep the shim — rejected: dead code that only invites confusion now that consumers are migrated.

## Blast radius
- Removing the shim: verified only intentional retirement notes remain (`gpu-job/SKILL.md`,
  `run-experiment/SKILL.md`). `run-experiment` "stepping away" now relies on the lease reaper — the
  intended result of #266 (no fast idle-teardown; the lease at expiry is the backstop).
- **CHECKLIST rewritten:** the `design-experiment/CHECKLIST_TEMPLATE.md` "idle-teardown watchdog" refs now
  name the actual mechanism — the `gpu-job` pod lease (the settled sole backstop, #266) — so no generated
  executor checklist points at a retired term. `grep -ri watchdog` across both plugins is now only the two
  retirement notes.
- The rclone env default is pod-wide + overridable; worst case a per-call `--multi-thread-streams 1`
  restores single-stream.

## Rollout
#266 was already closed by #288; this completes it. Closes #284 — the pod-env default is the universal
fix (registry eval-drivers inherit it), so no separate registry change is needed.
