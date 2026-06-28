#!/bin/bash
# teardown.sh <pod-id> [lease-nonce] — DELETE a pod (the default the moment a run completes) and list
# anything still RUNNING so nothing bills silently. RULES this encodes: tear down only
# AFTER artifacts are verified in your store (before that, DELETE loses data — that gate
# is the whole ballgame); never use the provider's "stop" expecting keep-warm (container
# disk is wiped on restart — same loss as delete, still billing storage); pod-id-scoped,
# never blanket-delete (parallel runs own their own pods).
#
# If a [lease-nonce] (the #54 child-2 pod lease) is passed, the lease is CLOSED only AFTER the pod's
# deletion is VERIFIED on the control plane — closing it on an unverified delete would turn a failed
# teardown into an UNKNOWN pod the reaper only reports (a billing orphan). An unverified delete leaves
# the lease expired for the standing reaper to retry. Without a nonce, behavior is unchanged.
set -euo pipefail
PID=${1:?pod id}
NONCE=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
# Back-compat (round-9 Finding 2): if no nonce was passed but acquire wrote a lease for this pod, find
# it by pod id so the old `teardown.sh <pod-id>` call still closes/marks the lease (no stale lease the
# reaper would keep retrying). A non-unique/absent match leaves NONCE empty (unchanged behavior).
if [ -z "$NONCE" ] && [ -f "$HERE/pod_lease.sh" ]; then
  NONCE=$(bash "$HERE/pod_lease.sh" find-by-pod "$PID" 2>/dev/null || true)
  [ -n "$NONCE" ] && echo "teardown: located lease $NONCE for pod $PID (no nonce supplied)"
fi
KEY_NAME=$(grep -E "^API_KEY_ENV=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2-); KEY_NAME="${API_KEY_ENV:-${KEY_NAME:-RUNPOD_API_KEY}}"
KEY=$(grep -E "^$KEY_NAME=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || eval echo "\${$KEY_NAME:?}")
# Capture the DELETE's HTTP status — a non-2xx (wrong key, auth/network error) must NOT be trusted as a
# deletion even if a follow-up GET 404s (a wrong-key GET also 404s). round-5 Finding 1.
del_http=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 60 \
  -X DELETE -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
  "https://rest.runpod.io/v1/pods/$PID" 2>/dev/null) || del_http=000
case "$del_http" in 200|201|202|204) del_ok=1; echo "deleted $PID (HTTP $del_http)";; *) del_ok=0; echo "DELETE $PID returned HTTP $del_http (not accepted)" >&2;; esac

# Close the lease ONLY after the DELETE was ACCEPTED (2xx) AND the pod is verified gone on the control
# plane. FAIL-CLOSED: an unaccepted DELETE, or a transient curl/HTTP/JSON failure on the verify, is
# INCONCLUSIVE and leaves the lease IMMEDIATELY reapable for the standing reaper to retry (never closes
# a still-billing pod).
if [ -n "$NONCE" ] && [ -f "$HERE/pod_lease.sh" ]; then
  # SAFETY: only mutate the lease if it actually OWNS this pod (round-7 Finding 1). A mistyped nonce
  # must not close/expire another live pod's lease (which would orphan that pod from the reaper).
  lease_pod=$(bash "$HERE/pod_lease.sh" show "$NONCE" 2>/dev/null \
              | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pod_id") or "")' 2>/dev/null || true)
  if [ "$lease_pod" != "$PID" ]; then
    echo "WARNING: lease $NONCE pod_id ('$lease_pod') != deleted pod '$PID' — NOT mutating it (wrong nonce?)" >&2
    NONCE=""
  fi
fi
if [ -n "$NONCE" ] && [ -f "$HERE/pod_lease.sh" ]; then
  body=$(curl -s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 \
           -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
           "https://rest.runpod.io/v1/pods/$PID" 2>/dev/null) || body=""
  verdict=$(printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("inconclusive"); sys.exit(0)
lines = raw.splitlines()
http = lines[-1].strip() if lines else ""
payload = "\n".join(lines[:-1])
if http == "404":
    print("gone"); sys.exit(0)
if http in ("200", "201"):
    try:
        d = json.loads(payload)
    except Exception:
        print("inconclusive"); sys.exit(0)
    print("present" if (isinstance(d, dict) and d.get("desiredStatus") == "RUNNING") else "gone")
else:
    print("inconclusive")
' 2>/dev/null || echo inconclusive)
  # If the DELETE was ACCEPTED, persist the marker BEFORE deciding close-vs-expire (round-8 Finding 1):
  # an accepted-but-not-yet-verified teardown that then expires the lease must still let the reaper close
  # it later when the pod is confirmed gone (the reaper's fresh DELETE would 404 — gone — and without
  # this marker it would refuse to close forever).
  [ "$del_ok" = 1 ] && bash "$HERE/pod_lease.sh" mark-deleted "$NONCE" >/dev/null 2>&1 || true
  if [ "$del_ok" = 1 ] && [ "$verdict" = gone ]; then
    bash "$HERE/pod_lease.sh" close "$NONCE" >/dev/null && echo "lease $NONCE closed (delete accepted + verified gone)"
  else
    # Unverified delete: mark the lease IMMEDIATELY reapable so the standing reaper retries it on the
    # NEXT sweep, not hours from now when the run's expiry would have lapsed (round-4 Finding 3).
    bash "$HERE/pod_lease.sh" expire "$NONCE" >/dev/null 2>&1 || true
    echo "WARNING: pod $PID delete not confirmed (accepted=$del_ok, verify=$verdict) — lease $NONCE expired for the reaper to retry promptly (NOT closed)" >&2
  fi
fi

echo "still RUNNING (verify these are yours and intended):"
curl -s -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
  | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
print([f\"{p['id']} {p.get('name')} \${p.get('costPerHr')}/hr\" for p in d if p.get('desiredStatus')=='RUNNING'] or 'none')"
