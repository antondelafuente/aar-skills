#!/bin/bash
# pod_reaper.sh — the BOX-LEVEL, MODEL-FREE pod reaper (the #54 crash-resilience design, child 2 /
# #169 B.1). PRODUCT helper: it owns the whole reap DECISION + the DELETE-and-verify, resolving keys
# through the same API_KEY_ENV seam deploy_pod.py/teardown.sh use. The INSTANCE supplies only the
# secret values (~/.config/gpu-job/env, as today) and the SCHEDULE (the systemd timer / loop that
# invokes this). No decision logic, key resolution, listing, or DELETE lives in instance wiring — so
# no instance wiring can blanket-delete.
#
# THE CONTRACT (over the pod_lease.sh registry + the provider's live pod list):
#   reap        — a lease that is REGISTERED and PAST EXPIRY. Deleted, under the lease's lock.
#   keep        — a lease registered and NOT expired. Left alone.
#   report-only — an UNKNOWN pod (no lease, no matching pending-intent nonce), an AMBIGUOUS nonce
#                 match, or a lease whose key_ref can't be resolved. REPORTED, NEVER deleted —
#                 preserving gpu-job's "never blanket-delete idle pods" rule.
#
# THE LOCKED REAP (design review Finding 1): a reap is NOT a stale classification followed by a
#   detached DELETE. For each candidate lease, this re-checks `is-reapable` and marks `reaping`
#   INSIDE that lease's per-record lock (via pod_lease.sh, which takes the same lock `refresh` takes),
#   so a concurrent long-run `refresh` that extended expiry can never be raced into a wrongful delete.
#   Only after the in-lock claim succeeds does it DELETE + verify.
#
# KEY RESOLUTION + LISTING IN THE PRODUCT (Finding 2): each lease records a key_ref (the API_KEY_ENV
#   reference). This resolves it to a secret value through the gpu-job config seam, lists pods PER
#   RESOLVED KEY, and does the matched-key DELETE+verify. A lease whose key_ref does not resolve is
#   report-only (never deleted with the wrong account's key).
#
# MIGRATION / BACK-COMPAT (Finding 3): a lease carries refresh_contract. Contract 2 (controller-side,
#   the only contract this helper's pod_lease.sh writes) reaps on LEASE EXPIRY ALONE. A legacy
#   contract-1 lease additionally requires a pod-side keepalive check over its SSH endpoint, and an
#   INCONCLUSIVE read (transient SSH failure) REPORTS-AND-RETRIES — it is never a license to delete a
#   healthy old-style long job.
#
# --dry-run: log every DELETE it WOULD issue (and every report-only pod), reconcilable against the
#   ledger + lease registry, WITHOUT deleting or marking anything. Roll the sweep out dry-run first.
#
# Provider seams (overridable so the smoke can run offline without RunPod):
#   GPU_JOB_LIST_PODS_CMD   "<cmd> <key>"  -> prints one `<pod-id> <name>` line per live pod for <key>
#   GPU_JOB_DELETE_POD_CMD  "<cmd> <key> <pod-id>" -> deletes; exit 0 on accepted delete
#   GPU_JOB_VERIFY_GONE_CMD "<cmd> <key> <pod-id>" -> exit 0 iff the pod is confirmed GONE
#   GPU_JOB_KEEPALIVE_CMD   "<cmd> <ssh> <pod-id>" -> prints future|past|"" (""=inconclusive read)
#   GPU_JOB_RESOLVE_KEY_CMD "<cmd> <key-ref>"      -> prints the resolved secret (empty = unresolved)
# Defaults use curl/ssh against RunPod + ~/.config/gpu-job/env.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LEASE="$HERE/pod_lease.sh"
CFG="$HOME/.config/gpu-job/env"

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

log(){ echo "[reaper $(date -u +%H:%M:%S)] $*"; }

# --- provider seams (real defaults; smoke overrides via env) -------------------------------------

cfg_get(){ grep -E "^$1=" "$CFG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"; }

# Resolve a key_ref (an API_KEY_ENV var NAME) to its secret: process env wins, else the gpu-job config
# (the same indirection deploy_pod.py uses). Empty output = unresolved -> the caller reports the lease.
# A malformed key_ref (not a valid shell identifier) must NOT abort the reaper via a fatal indirect
# expansion (code-review Finding 3): it's just unresolvable -> empty -> report-only.
resolve_key(){ # <key-ref>
  if [ -n "${GPU_JOB_RESOLVE_KEY_CMD:-}" ]; then $GPU_JOB_RESOLVE_KEY_CMD "$1"; return; fi
  local ref=$1 v=""
  # Valid shell identifier ONLY (reject anything with a non-[A-Za-z0-9_] char or a leading digit). A
  # `case` glob like [A-Za-z_][A-Za-z0-9_]* does NOT do this (its trailing * matches ANY chars), so use
  # an explicit negative test: a ref that still contains a disallowed char after stripping the allowed
  # set, or starts with a digit, is malformed -> unresolvable, NEVER indirect-expanded.
  if [ -n "$ref" ] && [ -z "${ref//[A-Za-z0-9_]/}" ] && [[ "$ref" != [0-9]* ]]; then
    v=${!ref:-}
    [ -n "$v" ] || v=$(cfg_get "$ref")
  fi
  printf '%s' "$v"
}

list_pods(){ # <key> -> "<pod-id> <name>" lines
  if [ -n "${GPU_JOB_LIST_PODS_CMD:-}" ]; then $GPU_JOB_LIST_PODS_CMD "$1"; return; fi
  curl -s -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods \
    | python3 -c "import json,sys
d=json.load(sys.stdin); d=d if isinstance(d,list) else d.get('data',d)
for p in d:
    if p.get('desiredStatus')=='RUNNING': print(p['id'], p.get('name',''))" 2>/dev/null
}

# delete_pod: exit 0 ONLY on an ACCEPTED delete (2xx). A non-2xx (incl. a wrong-key 404, auth failure,
# network error) is exit nonzero — the caller must NOT treat the pod as gone (code-review round-4
# Finding 2: a 404 from the wrong key is not a verified deletion).
delete_pod(){ # <key> <pod-id>
  if [ -n "${GPU_JOB_DELETE_POD_CMD:-}" ]; then $GPU_JOB_DELETE_POD_CMD "$1" "$2"; return; fi
  local http
  http=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $1" \
         -H "User-Agent: gpu-job" "https://rest.runpod.io/v1/pods/$2" 2>/dev/null) || return 1
  case "$http" in 200|201|202|204) return 0 ;; *) return 1 ;; esac
}

# verify_gone: exit 0 = CONFIRMED gone, 1 = still present, 2 = INCONCLUSIVE (network/HTTP/JSON error).
# Finding 3: an unreadable/garbled response must NOT count as gone — a transient GET failure would
# otherwise close a lease while the pod is still billing. Only a successful, parseable response that
# shows the pod absent / no longer RUNNING counts as gone.
verify_gone(){ # <key> <pod-id>
  if [ -n "${GPU_JOB_VERIFY_GONE_CMD:-}" ]; then $GPU_JOB_VERIFY_GONE_CMD "$1" "$2"; return; fi
  local body http
  body=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" \
         "https://rest.runpod.io/v1/pods/$2" 2>/dev/null) || return 2
  http=$(printf '%s' "$body" | tail -1)
  body=$(printf '%s' "$body" | sed '$d')
  case "$http" in
    404) return 0 ;;                       # pod absent -> gone
    200|201)
      # parseable 200 -> gone iff NOT RUNNING; a non-JSON 200 (error page) is inconclusive
      printf '%s' "$body" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
ds=(d.get("desiredStatus") if isinstance(d,dict) else None)
sys.exit(1 if ds=="RUNNING" else 0)' 2>/dev/null
      return $? ;;
    *) return 2 ;;                         # any other HTTP status -> inconclusive
  esac
}

# keepalive check for a LEGACY (contract-1) lease: future | past | "" (inconclusive)
keepalive_state(){ # <ssh-endpoint> <pod-id>
  if [ -n "${GPU_JOB_KEEPALIVE_CMD:-}" ]; then $GPU_JOB_KEEPALIVE_CMD "$1" "$2"; return; fi
  local ssh=$1 ip port keyfile u now
  ip=${ssh%%:*}; port=${ssh##*:}
  keyfile=$(cfg_get SSH_KEY_FILE); keyfile=${keyfile:-$HOME/.ssh/id_ed25519}
  u=$(ssh -i "$keyfile" -p "$port" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        "root@$ip" 'cat /workspace/.keepalive_until_utc 2>/dev/null' 2>/dev/null) || { echo ""; return; }
  [ -n "$u" ] || { echo "past"; return; }   # no keepalive file -> not protected
  now=$(date -u +%s)
  [ "$(date -u -d "$u" +%s 2>/dev/null || echo 0)" -gt "$now" ] && echo future || echo past
}

# --- the sweep -----------------------------------------------------------------------------------

# Build: nonce -> "<pod_id> <state> <expiry_at>" and pod_id -> nonce, from the lease registry.
declare -A LEASE_POD LEASE_STATE
declare -A POD_TO_NONCE
while read -r nonce state pod exp; do
  [ -n "${nonce:-}" ] || continue
  LEASE_POD["$nonce"]="$pod"
  LEASE_STATE["$nonce"]="$state"
  [ "$pod" != "-" ] && [ -n "$pod" ] && POD_TO_NONCE["$pod"]="$nonce"
done < <(bash "$LEASE" list)

reaped=0; reported=0; kept=0; retried=0

# Reap one lease (by nonce), DELETE+verify. The expiry re-check + the `reaping` mark happen in ONE
# locked claim (claim-reaping) so a concurrent refresh can't race between them (Finding 1).
reap_lease(){ # <nonce> <key> <pod-id>
  local nonce=$1 key=$2 pod=$3
  if [ "$DRY" = 1 ]; then
    # dry-run still re-checks reapability (read-only) so the would-reap log is honest
    if bash "$LEASE" is-reapable "$nonce"; then
      log "DRY-RUN would reap: nonce=$nonce pod=$pod"; reaped=$((reaped+1))
    else
      log "keep (refreshed): nonce=$nonce pod=$pod"; kept=$((kept+1))
    fi
    return
  fi
  # ATOMIC claim: re-check expiry AND mark reaping in one lock. Exit 1 = a refresh moved expiry
  # forward -> keep, no mutation.
  if ! bash "$LEASE" claim-reaping "$nonce" >/dev/null 2>&1; then
    log "keep (refreshed under lock): $nonce pod=$pod"; kept=$((kept+1)); return
  fi
  # Close the lease ONLY on an ACCEPTED delete (2xx) AND a verified-gone confirmation. A delete that
  # was not accepted (wrong key, auth/network error, non-2xx) must NOT be trusted even if a subsequent
  # GET 404s (round-4 Finding 2). Anything short of accepted+verified -> reopen for the next sweep.
  if delete_pod "$key" "$pod" && verify_gone "$key" "$pod"; then
    bash "$LEASE" close "$nonce" >/dev/null || true
    log "REAPED: nonce=$nonce pod=$pod (delete accepted + verified gone)"; reaped=$((reaped+1))
  else
    bash "$LEASE" unclaim-reaping "$nonce" >/dev/null 2>&1 || true
    log "RETRY: nonce=$nonce pod=$pod delete not accepted/verified — lease reopened for next sweep"; retried=$((retried+1))
  fi
}

# Decide for one expired-candidate lease, including the legacy keepalive check.
consider_lease(){ # <nonce>
  local nonce=$1 pod=${LEASE_POD[$nonce]} state=${LEASE_STATE[$nonce]}
  case "$state" in intent|provisional|enriched) : ;; *) return ;; esac   # closed/reaping/invalid: skip
  # A lease with no bound pod id (a pending INTENT) is handled in step 2 by matching its nonce against
  # the LIVE pod list — we never DELETE a placeholder id here.
  [ -n "$pod" ] && [ "$pod" != "-" ] || return
  bash "$LEASE" is-reapable "$nonce" || { kept=$((kept+1)); return; }     # not expired -> keep
  local key_ref key
  key_ref=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
  key=$(resolve_key "$key_ref")
  if [ -z "$key" ]; then
    log "report (unresolved key_ref '$key_ref'): nonce=$nonce pod=$pod"; reported=$((reported+1)); return
  fi
  # MIGRATION: contract-1 (legacy) leases need the pod-side keepalive check; contract-2 reaps on
  # lease expiry alone.
  local contract ssh
  contract=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("refresh_contract",2))' 2>/dev/null)
  if [ "$contract" = 1 ]; then
    ssh=$(bash "$LEASE" show "$nonce" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("ssh") or "")' 2>/dev/null)
    # A legacy lease with NO SSH endpoint can't have its pod-side keepalive checked at all, so deletion
    # is NOT safe (a healthy legacy job could be killed). Empty ssh == inconclusive -> report-retry,
    # never fall through to reap (code-review round-3 Finding 1).
    if [ -z "$ssh" ]; then
      log "report-retry (legacy lease, no SSH endpoint to check keepalive): nonce=$nonce pod=$pod"; retried=$((retried+1)); return
    fi
    local ka; ka=$(keepalive_state "$ssh" "$pod")
    case "$ka" in
      future) log "keep (legacy keepalive future): nonce=$nonce pod=$pod"; kept=$((kept+1)); return;;
      "")     log "report-retry (legacy keepalive inconclusive): nonce=$nonce pod=$pod"; retried=$((retried+1)); return;;
      past)   : ;;   # both controller-expired AND no future keepalive -> reap
    esac
  fi
  reap_lease "$nonce" "$key" "$pod"
}

DRY_TAG=""; [ "$DRY" = 1 ] && DRY_TAG=" (DRY-RUN)"
log "sweep start${DRY_TAG} root=${GPU_JOB_LEASE_DIR:-$HOME/.config/gpu-job/leases}"

# 1. Reap/keep over the lease registry (the only set we ever DELETE from).
for nonce in "${!LEASE_POD[@]}"; do
  consider_lease "$nonce"
done

# Resolve the DISTINCT set of keys referenced by the registry (so we list each provider key once).
declare -A SEEN_KEY KEY_FOR_REF
for nonce in "${!LEASE_POD[@]}"; do
  kr=$(bash "$LEASE" show "$nonce" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
  [ -n "$kr" ] || continue
  [ -n "${SEEN_KEY[$kr]:-}" ] && continue
  SEEN_KEY["$kr"]=1
  key=$(resolve_key "$kr")
  [ -n "$key" ] && KEY_FOR_REF["$kr"]="$key"
done

# Pre-count live pod-NAME occurrences across all resolved keys (code-review Finding 4): a name carried
# by more than one DISTINCT live pod id is AMBIGUOUS and must be report-only, never reaped — even if it
# matches a pending-intent nonce. Counting first means the iteration order can't let "the first of two
# duplicate names" be deleted. We count DISTINCT pod ids per name (a pod that appears under more than
# one key's listing — e.g. shared creds — is the SAME pod, counted once).
declare -A NAME_COUNT NAME_POD_SEEN
for kr in "${!KEY_FOR_REF[@]}"; do
  while read -r pod name; do
    [ -n "${name:-}" ] && [ -n "${pod:-}" ] || continue
    local_key="$name|$pod"
    [ -n "${NAME_POD_SEEN[$local_key]:-}" ] && continue   # same name+pod already counted
    NAME_POD_SEEN["$local_key"]=1
    NAME_COUNT["$name"]=$(( ${NAME_COUNT["$name"]:-0} + 1 ))
  done < <(list_pods "${KEY_FOR_REF[$kr]}")
done

# 2. report-only over live pods that no lease accounts for. A pod with no lease and no UNIQUE matching
#    pending-intent nonce is REPORTED, never deleted.
declare -A PROCESSED_POD
for kr in "${!KEY_FOR_REF[@]}"; do
  key=${KEY_FOR_REF[$kr]}
  while read -r pod name; do
    [ -n "${pod:-}" ] || continue
    [ -n "${PROCESSED_POD[$pod]:-}" ] && continue          # already handled (same pod under another key listing)
    PROCESSED_POD["$pod"]=1
    [ -n "${POD_TO_NONCE[$pod]:-}" ] && continue          # accounted for by a lease
    # A duplicated live name is ambiguous -> report-only, never reap (Finding 4).
    if [ "${NAME_COUNT[$name]:-0}" -gt 1 ]; then
      log "report-only (AMBIGUOUS — $name on >1 live pod): pod=$pod"; reported=$((reported+1)); continue
    fi
    # match an unknown pod to a UNIQUE PENDING INTENT by nonce (find-nonce returns only intent leases
    # with no pod_id; ambiguous-intent -> empty=report)
    m=$(bash "$LEASE" find-nonce "$name")
    if [ -z "$m" ]; then
      log "report-only (UNKNOWN pod, no lease — NEVER deleted): pod=$pod name=$name"; reported=$((reported+1)); continue
    fi
    # SCOPE the match to THIS key (round-3 Finding 4): the intent's recorded key_ref must equal the key
    # we're currently listing under, or a pod under another account could be rebound + deleted by the
    # wrong lease. Mismatch -> report-only.
    m_kr=$(bash "$LEASE" show "$m" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
    if [ "$m_kr" != "$kr" ]; then
      log "report-only (pending-intent under a different key_ref '$m_kr' != '$kr'): pod=$pod nonce=$m"; reported=$((reported+1)); continue
    fi
    # The created-but-id-never-returned case: a live pod whose NAME is an EXPIRED intent nonce — the
    # half-born pod the intent exists to catch. Bind the discovered id + reap under the locked claim.
    if bash "$LEASE" is-reapable "$m"; then
      if [ "$DRY" = 1 ]; then
        # dry-run NEVER mutates: log the would-bind/would-reap, skip the provisional write (Finding 2)
        log "DRY-RUN would bind+reap half-born pod: pod=$pod nonce=$m"; reaped=$((reaped+1))
      else
        # The bind MUST succeed and the lease's pod_id MUST now equal this pod before we delete it
        # (round-4 Finding 1): otherwise a failed bind would let us DELETE an unknown pod with no
        # registered lease. On any mismatch -> report-only, never reap.
        if bash "$LEASE" provisional "$m" "$pod" >/dev/null 2>&1 \
           && [ "$(bash "$LEASE" show "$m" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("pod_id") or "")' 2>/dev/null)" = "$pod" ]; then
          log "pending-intent EXPIRED — reaping half-born pod: pod=$pod nonce=$m"
          reap_lease "$m" "$key" "$pod"
        else
          log "report-only (pending-intent bind failed/mismatch — NOT reaping): pod=$pod nonce=$m"; reported=$((reported+1))
        fi
      fi
    else
      log "report (pending-intent match, not yet expired): pod=$pod nonce=$m"; reported=$((reported+1))
    fi
  done < <(list_pods "$key")
done

DONE_TAG=""; [ "$DRY" = 1 ] && DONE_TAG=" (DRY-RUN — nothing deleted)"
log "sweep done: reaped=$reaped kept=$kept reported=$reported retried=$retried${DONE_TAG}"
