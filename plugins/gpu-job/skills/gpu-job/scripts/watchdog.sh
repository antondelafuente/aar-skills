#!/bin/bash
# watchdog.sh — RETIRED (automated-researcher #266). NO-OP COMPATIBILITY SHIM.
#
# The per-pod one-shot watchdog reaped a LIVE pod mid-run (deleted a pod at 21/26 eval cells): armed
# by hand as a "hard cost cap", it deleted the pod once its grace passed unless a pod-side keepalive
# said otherwise, and nothing enforced writing that keepalive. Its only real job — fast-reaping a pod
# whose controlling agent DIED — has not been needed once in two months, so it was pure downside.
#
# The box-level, MODEL-FREE lease reaper (pod_reaper.sh, over the pod_lease.sh registry) is now the
# SOLE backstop: every pod deploy_pod.py creates carries a lease with an expiry, and the reaper deletes
# a pod past its lease expiry. There is nothing to arm by hand.
#
# This file is kept only as a no-op shim so any lingering "arm the watchdog" instruction resolves to a
# harmless message instead of a missing-file error; it (and the remaining references in the
# experiment-lifecycle skills) will be removed together in a follow-up.
set -u
echo "[watchdog] RETIRED (#266): the per-pod watchdog no longer reaps anything." >&2
echo "[watchdog] The box-level lease reaper (pod_reaper.sh) is the sole backstop; every deploy_pod.py" >&2
echo "[watchdog] pod is lease-covered. Nothing to arm — this is a no-op (args ignored: $*)." >&2
exit 0
