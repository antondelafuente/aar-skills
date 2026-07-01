# 266 — Remove the per-pod watchdog; harden deploy against a mid-create kill

Closes #266, #278.

## Problem

Two *opposite* pod-lifecycle failures, both real incidents (2026-06-30):

- **#266 — the watchdog killed a LIVE pod.** `gpu-job/watchdog.sh` is a one-shot reaper an executor arms by hand (`watchdog.sh <pod> <ip> <port> <grace-seconds>`); it `DELETE`s the pod when the grace passes unless a pod-side `/workspace/.keepalive_until_utc` says otherwise. Nothing enforces writing that keepalive, so arming it as a "hard cost cap" is one slow stage away from self-deletion — which is exactly what happened (deleted at 21/26 eval cells). Its *only* real job is fast-reaping a pod whose controlling agent DIED — a failure that has not occurred once in two months of operation. It is pure downside.

- **#278 — an interrupted launch orphaned billing pods.** `deploy_pod.py` create is non-atomic: `POST /pods` starts billing immediately, then it polls ~30–90s for SSH readiness. A kill in that window (a `timeout` wrapper firing, a host time limit, Ctrl-C) left pods RUNNING and billing that the operator never saw (the killed command printed no `POD_ID`).

## Approach

**#266 — retire the watchdog (no-op shim now; full removal in a follow-up).** Replace `scripts/watchdog.sh` with a no-op deprecation shim and remove the "arm the watchdog" step from the gpu-job `SKILL.md`. Deliberately build NO liveness/heartbeat machinery for the agent-death case (Anton's explicit call: that case hasn't happened, so it's not worth standing overhead). The existing **lease-based reaper (`pod_reaper.sh`) stays as the sole backstop** — it is model-free, reaps on lease expiry alone (contract-2), and does NOT depend on the watchdog or any pod-side keepalive.

Why a shim, not a hard delete: installed `run-experiment`/`design-experiment` (experiment-lifecycle) instructions still reference `watchdog.sh`, and a parallel PR is editing that plugin — so removing those refs here would collide. The shim removes the *danger* now (it can no longer reap anything) with zero dangling-reference risk; a follow-up removes the shim + those refs together. (This is the design-review's endorsed "compatibility shim until all consumers stop pointing at it" path.)

**#278 — add a signal trap; keep the existing short-lease machinery.** `deploy_pod.py` already mints a SHORT intent lease pre-deploy, binds the real pod id to it the instant the 201 returns (`provisional`), and promotes to the long run expiry only after SSH is confirmed (`enrich`) — all fail-closed. So the "short unconfirmed lease" and "durable, discoverable pod id" #278 asks for already exist; the reaper already reaps a never-enriched pod at intent expiry. The genuine gap is that a **kill during the readiness poll** isn't cleaned up promptly. Fix: install a `SIGTERM`/`SIGINT` trap that `DELETE`s the just-created pod (and marks its lease reaped) before exiting — so a graceful kill (a `timeout`'s initial `SIGTERM`, Ctrl-C) cleans up in seconds. The untrappable `SIGKILL`/hard-timeout case is already bounded by the short intent lease.

**Testing.** `deploy_pod.py --selftest` gains an offline `_selftest_cleanup` check (stubs the DELETE + lease calls, fires the trap on an in-flight pod and asserts it deletes; fires it on a cleared/confirmed pod and asserts it does not). `.aar-ci/checks.sh` runs `deploy_pod.py --selftest` whenever that file changes — compile-only can't catch a broken billing-safety cleanup.

## Alternatives considered

- *Heartbeat-extended lease / smart progress-aware reaper* (from #266's fix ideas) — rejected: builds liveness machinery for a case that hasn't happened, and a "smart" reaper is exactly the kind of clever component that mis-fires. Keep the reaper dumb and lease-expiry-based.
- *Rebuild deploy_pod's create as fully transactional* — unnecessary; the intent→provisional→enrich lease already provides the short-lease + durable-id guarantees. Only the signal trap is missing.

## Blast radius

- Removing `watchdog.sh` leaves `pod_reaper.sh` as the sole reaper. Verified the reaper's contract-2 (the only contract its `pod_lease.sh` writes) reaps on lease expiry alone — no watchdog dependency. Legacy contract-1's pod-side keepalive check is the reaper's own SSH probe, not `watchdog.sh`.
- The signal trap only fires while a pod is in-flight (created, not yet enriched); it is cleared once the pod is fully leased, so a signal after a successful deploy never deletes a good pod.
- **Out of scope (deliberately left for follow-ups):** the watchdog is also referenced in `run-experiment`'s SKILL.md and `design-experiment`'s CHECKLIST template (the experiment-lifecycle plugin) — a parallel PR is editing that plugin, so those refs are handled separately to avoid a merge collision. `#284` (multi-thread rclone) lives in the run-experiment/eval-driver templates, out of the gpu-job scope of this PR.

## Rollout + rollback

Merge; the fleet loads gpu-job from live source, so the change is live on the next session. No migration: existing leases and the reaper are untouched; only the removed watchdog and the new trap change behavior. Revert = restore `watchdog.sh` + the SKILL.md lines and drop the trap.
