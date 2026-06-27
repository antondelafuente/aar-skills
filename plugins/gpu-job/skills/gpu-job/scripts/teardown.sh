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
KEY_NAME=$(grep -E "^API_KEY_ENV=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2-); KEY_NAME="${API_KEY_ENV:-${KEY_NAME:-RUNPOD_API_KEY}}"
KEY=$(grep -E "^$KEY_NAME=" ~/.config/gpu-job/env 2>/dev/null | cut -d= -f2- || eval echo "\${$KEY_NAME:?}")
curl -s -X DELETE -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
  "https://rest.runpod.io/v1/pods/$PID" >/dev/null && echo "deleted $PID"

# Close the lease ONLY after verifying the pod is actually gone on the control plane. FAIL-CLOSED:
# close only on a 404 or a parseable 200 showing NOT-RUNNING; a transient curl/HTTP/JSON failure is
# INCONCLUSIVE and leaves the lease open for the standing reaper to retry (never closes a still-billing
# pod on an unreadable response).
if [ -n "$NONCE" ] && [ -f "$HERE/pod_lease.sh" ]; then
  body=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" \
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
  if [ "$verdict" = gone ]; then
    bash "$HERE/pod_lease.sh" close "$NONCE" >/dev/null && echo "lease $NONCE closed (delete verified gone)"
  else
    # Unverified delete: mark the lease IMMEDIATELY reapable so the standing reaper retries it on the
    # NEXT sweep, not hours from now when the run's expiry would have lapsed (round-4 Finding 3).
    bash "$HERE/pod_lease.sh" expire "$NONCE" >/dev/null 2>&1 || true
    echo "WARNING: pod $PID delete NOT verified gone ($verdict) — lease $NONCE expired for the reaper to retry promptly (NOT closed)" >&2
  fi
fi

echo "still RUNNING (verify these are yours and intended):"
curl -s -H "Authorization: Bearer $KEY" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
  | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
print([f\"{p['id']} {p.get('name')} \${p.get('costPerHr')}/hr\" for p in d if p.get('desiredStatus')=='RUNNING'] or 'none')"
