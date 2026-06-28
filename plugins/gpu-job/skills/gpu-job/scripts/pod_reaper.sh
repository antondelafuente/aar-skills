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
# Reject any other/leftover argument — a typo like `--dryrun` must NOT silently run a LIVE destructive
# sweep (round-6 Finding 2).
[ $# -eq 0 ] || { echo "pod_reaper: unexpected argument(s): $* (only optional --dry-run is accepted)" >&2; exit 2; }

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

# list_pods: print "<pod-id> <name>" per RUNNING pod, exit 0 on success. A non-2xx, network timeout, or
# unparseable body is exit nonzero (round-5 Finding 3) so the caller can REPORT the key as unlistable
# instead of silently treating it as zero live pods (which would hide unknown/half-born pods).
list_pods(){ # <key>
  if [ -n "${GPU_JOB_LIST_PODS_CMD:-}" ]; then $GPU_JOB_LIST_PODS_CMD "$1"; return; fi
  local body http
  body=$(curl -s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 \
         -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" https://rest.runpod.io/v1/pods 2>/dev/null) || return 1
  http=$(printf '%s' "$body" | tail -1)
  body=$(printf '%s' "$body" | sed '$d')
  case "$http" in 200|201) : ;; *) return 1 ;; esac
  printf '%s' "$body" | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
d=d if isinstance(d,list) else d.get('data',d)
if not isinstance(d,list): sys.exit(1)
for p in d:
    if isinstance(p,dict) and p.get('desiredStatus')=='RUNNING': print(p['id'], p.get('name',''))"
}

# delete_pod: exit 0 ONLY on an ACCEPTED delete (2xx). A non-2xx (incl. a wrong-key 404, auth failure,
# network error) is exit nonzero — the caller must NOT treat the pod as gone (code-review round-4
# Finding 2: a 404 from the wrong key is not a verified deletion).
delete_pod(){ # <key> <pod-id>
  if [ -n "${GPU_JOB_DELETE_POD_CMD:-}" ]; then $GPU_JOB_DELETE_POD_CMD "$1" "$2"; return; fi
  local http
  http=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 60 -X DELETE \
         -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" \
         "https://rest.runpod.io/v1/pods/$2" 2>/dev/null) || return 1
  case "$http" in 200|201|202|204) return 0 ;; *) return 1 ;; esac
}

# verify_gone: exit 0 = CONFIRMED gone, 1 = still present, 2 = INCONCLUSIVE (network/HTTP/JSON error).
# Finding 3: an unreadable/garbled response must NOT count as gone — a transient GET failure would
# otherwise close a lease while the pod is still billing. Only a successful, parseable response that
# shows the pod absent / no longer RUNNING counts as gone.
verify_gone(){ # <key> <pod-id>
  if [ -n "${GPU_JOB_VERIFY_GONE_CMD:-}" ]; then $GPU_JOB_VERIFY_GONE_CMD "$1" "$2"; return; fi
  local body http
  body=$(curl -s -w '\n%{http_code}' --connect-timeout 15 --max-time 60 \
         -H "Authorization: Bearer $1" -H "User-Agent: gpu-job" \
         "https://rest.runpod.io/v1/pods/$2" 2>/dev/null) || return 2
  http=$(printf '%s' "$body" | tail -1)
  body=$(printf '%s' "$body" | sed '$d')
  case "$http" in
    404) return 0 ;;                       # pod absent -> gone
    200|201)
      # parseable 200 -> gone ONLY on an EXPLICIT terminal/deleted desiredStatus; RUNNING -> present;
      # a MISSING/unknown desiredStatus, a non-dict, or a non-JSON body is INCONCLUSIVE (exit 2), never
      # treated as gone (round-10 Finding 1 — an envelope/error/changed-shape 200 must not close a lease
      # while the pod may still exist).
      printf '%s' "$body" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(2)
if not isinstance(d,dict): sys.exit(2)
ds=d.get("desiredStatus")
if ds=="RUNNING": sys.exit(1)            # present
if ds in ("TERMINATED","EXITED","REMOVED","DELETED"): sys.exit(0)   # explicit terminal -> gone
sys.exit(2)' 2>/dev/null              # missing/unknown -> inconclusive
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
declare -A POD_TO_NONCE POD_ACTIVE_COUNT
while read -r nonce state pod exp; do
  [ -n "${nonce:-}" ] || continue
  LEASE_POD["$nonce"]="$pod"
  LEASE_STATE["$nonce"]="$state"
  # A pod counts as "accounted for" only if its lease is ACTIVE/REAPING (round-7 Finding 2). A pod whose
  # only lease is `closed` (a teardown thought it gone) or `invalid` but is STILL LIVE is effectively an
  # orphan — leaving it out of POD_TO_NONCE makes step 2 REPORT it (an unknown live pod), not skip it.
  case "$state" in
    intent|provisional|enriched|reaping)
      if [ "$pod" != "-" ] && [ -n "$pod" ]; then
        POD_TO_NONCE["$pod"]="$nonce"
        POD_ACTIVE_COUNT["$pod"]=$(( ${POD_ACTIVE_COUNT["$pod"]:-0} + 1 ))
      fi ;;
  esac
done < <(bash "$LEASE" list)

reaped=0; reported=0; kept=0; retried=0

# Reap one lease (by nonce), DELETE+verify. The expiry re-check + the `reaping` mark happen in ONE
# locked claim (claim-reaping) so a concurrent refresh can't race between them (Finding 1).
reap_lease(){ # <nonce> <key> <pod-id>
  local nonce=$1 key=$2 pod=$3
  if [ "$DRY" = 1 ]; then
    # dry-run uses the read-only would-claim predicate (mirrors claim-reaping incl. STALE reaping
    # leases) so the would-reap log matches what a real sweep would actually do (round-8 Finding 2).
    if bash "$LEASE" would-claim "$nonce"; then
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
  # Was THIS lease's delete accepted on a PRIOR sweep? (round-7 Finding 3) — if so, a fresh DELETE that
  # now 404s because the pod is already gone must still let us close on verified-gone, instead of looping
  # forever (the pod IS gone; only the fresh DELETE is no longer "accepted").
  local prior_accepted
  prior_accepted=$(bash "$LEASE" show "$nonce" 2>/dev/null | python3 -c 'import json,sys;print("yes" if json.load(sys.stdin).get("delete_accepted") is True else "no")' 2>/dev/null || echo no)
  local accepted=no
  if delete_pod "$key" "$pod"; then
    accepted=yes
    bash "$LEASE" mark-deleted "$nonce" >/dev/null 2>&1 || true   # persist the accepted-delete marker
  fi
  # Close ONLY when the delete was accepted (now OR on a prior sweep) AND the pod is verified gone. A
  # delete never accepted at all (wrong key, auth error) is NOT trusted even if a GET 404s.
  if { [ "$accepted" = yes ] || [ "$prior_accepted" = yes ]; } && verify_gone "$key" "$pod"; then
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
  # We consider non-terminal leases AND `reaping` leases (a `reaping` lease may be a STALE claim left by
  # a crashed reaper — round-6 Finding 1; claim-reaping reclaims it only if stale). A `closed` lease is
  # done; an `invalid` (malformed) record is REPORTED, never silently skipped (round-9 Finding 3) — a
  # corrupt registry entry is exactly the bad state the sweep should surface.
  case "$state" in
    intent|provisional|enriched|reaping) : ;;
    invalid) log "report-only (MALFORMED lease record — inspect): nonce=$nonce"; reported=$((reported+1)); return ;;
    *) return ;;
  esac
  # A lease with no bound pod id (a pending INTENT) is handled in step 2 by matching its nonce against
  # the LIVE pod list — we never DELETE a placeholder id here.
  [ -n "$pod" ] && [ "$pod" != "-" ] || return
  # FAIL CLOSED on a duplicated pod id (round-10 Finding 2): if >1 ACTIVE/REAPING lease binds this pod,
  # an expired duplicate must NOT delete a pod a fresh sibling lease still protects. Report, don't reap.
  if [ "${POD_ACTIVE_COUNT[$pod]:-0}" -gt 1 ]; then
    log "report-only (DUPLICATE active leases on pod $pod — registry ambiguity, NOT reaping): nonce=$nonce"; reported=$((reported+1)); return
  fi
  # A `reaping` lease skips the is-reapable gate (its expiry was already past when claimed); reap_lease's
  # claim-reaping decides whether it's a reclaimable STALE claim or a live reaper's fresh claim.
  if [ "$state" != reaping ]; then
    bash "$LEASE" is-reapable "$nonce" || { kept=$((kept+1)); return; }   # not expired -> keep
  fi
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
  if [ -n "$key" ]; then
    KEY_FOR_REF["$kr"]="$key"
  else
    # Report an UNRESOLVED key_ref here, in the key-collection pass (round-10 Finding 3): consider_lease
    # only reaches its unresolved-key report for leases that HAVE a pod, so a no-pod PENDING INTENT (the
    # created-but-id-never-returned case) under a missing key config would otherwise be silently hidden.
    log "report (unresolved key_ref '$kr' — pods under this key can't be swept; check key config)"; reported=$((reported+1))
  fi
done

# List each resolved key's live pods ONCE, capturing success/failure (round-5 Finding 3): a list call
# that fails (auth/HTTP/timeout/unparseable) must be REPORTED as unlistable, never silently treated as
# zero live pods (which would hide unknown / half-born pods from the sweep).
declare -A LISTED LIST_OK
for kr in "${!KEY_FOR_REF[@]}"; do
  if out=$(list_pods "${KEY_FOR_REF[$kr]}"); then
    LISTED["$kr"]="$out"; LIST_OK["$kr"]=1
  else
    LIST_OK["$kr"]=0
    log "report-unlistable (provider pod-list failed for key_ref '$kr' — NOT treating as zero pods): unknown/half-born pods under this key are NOT swept this cycle"
    reported=$((reported+1))
  fi
done

# Pre-count live pod-NAME occurrences across all SUCCESSFULLY-listed keys (code-review Finding 4): a
# name carried by more than one DISTINCT live pod id is AMBIGUOUS -> report-only, never reaped. Count
# DISTINCT pod ids per name (a pod under more than one key's listing — shared creds — is one pod).
declare -A NAME_COUNT NAME_POD_SEEN
for kr in "${!KEY_FOR_REF[@]}"; do
  [ "${LIST_OK[$kr]:-0}" = 1 ] || continue
  while read -r pod name; do
    [ -n "${name:-}" ] && [ -n "${pod:-}" ] || continue
    local_key="$name|$pod"
    [ -n "${NAME_POD_SEEN[$local_key]:-}" ] && continue   # same name+pod already counted
    NAME_POD_SEEN["$local_key"]=1
    NAME_COUNT["$name"]=$(( ${NAME_COUNT["$name"]:-0} + 1 ))
  done <<< "${LISTED[$kr]}"
done

# 2. report-only over live pods that no lease accounts for. A pod with no lease and no UNIQUE matching
#    pending-intent nonce is REPORTED, never deleted.
# HANDLED_POD is set only when a pod is DEFINITIVELY handled (reaped, or reported as unknown/ambiguous/
# accounted-for) — NOT on a key_ref-mismatch (round-6 Finding 4): two key_refs resolving to the same
# account must not let the FIRST key mark a half-born pod processed before the MATCHING key_ref reaps
# it. SEEN_POD_KR dedups the same pod re-listed under the SAME key only.
declare -A HANDLED_POD SEEN_POD_KR
for kr in "${!KEY_FOR_REF[@]}"; do
  [ "${LIST_OK[$kr]:-0}" = 1 ] || continue                 # an unlistable key was already reported
  key=${KEY_FOR_REF[$kr]}
  while read -r pod name; do
    [ -n "${pod:-}" ] || continue
    [ -n "${SEEN_POD_KR[$pod|$kr]:-}" ] && continue        # same pod re-listed under the same key
    SEEN_POD_KR["$pod|$kr"]=1
    [ -n "${HANDLED_POD[$pod]:-}" ] && continue            # already definitively handled under another key
    if [ -n "${POD_TO_NONCE[$pod]:-}" ]; then HANDLED_POD["$pod"]=1; continue; fi   # accounted for by a lease
    # A duplicated live name is ambiguous -> report-only, never reap (Finding 4).
    if [ "${NAME_COUNT[$name]:-0}" -gt 1 ]; then
      log "report-only (AMBIGUOUS — $name on >1 live pod): pod=$pod"; reported=$((reported+1)); HANDLED_POD["$pod"]=1; continue
    fi
    # match an unknown pod to a UNIQUE PENDING INTENT by nonce (find-nonce returns only intent leases
    # with no pod_id; ambiguous-intent -> empty=report)
    m=$(bash "$LEASE" find-nonce "$name")
    if [ -z "$m" ]; then
      log "report-only (UNKNOWN pod, no lease — NEVER deleted): pod=$pod name=$name"; reported=$((reported+1)); HANDLED_POD["$pod"]=1; continue
    fi
    # SCOPE the match to THIS key (round-3 Finding 4): the intent's recorded key_ref must equal the key
    # we're currently listing under, or a pod under another account could be rebound + deleted by the
    # wrong lease. Mismatch -> report-only AND do NOT mark handled, so the MATCHING key_ref (which may be
    # iterated later) still gets to reap this half-born pod (round-6 Finding 4).
    m_kr=$(bash "$LEASE" show "$m" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key_ref",""))' 2>/dev/null)
    if [ "$m_kr" != "$kr" ]; then
      log "report (pending-intent under a different key_ref '$m_kr' != '$kr'; awaiting its own key): pod=$pod nonce=$m"; reported=$((reported+1)); continue
    fi
    HANDLED_POD["$pod"]=1
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
  done <<< "${LISTED[$kr]}"
done

DONE_TAG=""; [ "$DRY" = 1 ] && DONE_TAG=" (DRY-RUN — nothing deleted)"
log "sweep done: reaped=$reaped kept=$kept reported=$reported retried=$retried${DONE_TAG}"
