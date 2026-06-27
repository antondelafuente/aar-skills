#!/usr/bin/env bash
# Smoke for pod_reaper.sh — the #54 child-2 box-level reaper. Runs OFFLINE: the provider seams
# (list/delete/verify/keepalive/resolve-key) are stubbed via env so no RunPod call is made. Covers the
# four design-review fixtures + the locked-reap race:
#   - reap an expired registered lease; keep a fresh one
#   - report-only an UNKNOWN pod (never deleted) — gpu-job's "never blanket-delete" rule
#   - report-only a lease whose key_ref does NOT resolve (Finding 2)
#   - pending-intent nonce match is report-only (not deleted)
#   - legacy contract-1: keepalive future -> keep; inconclusive -> retry (NOT delete, Finding 3); past -> reap
#   - the locked reap: a refresh that extends expiry between classify and delete SAVES the pod (Finding 1)
#   - --dry-run deletes nothing
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LEASE="$HERE/pod_lease.sh"
REAPER="$HERE/pod_reaper.sh"
[ -f "$LEASE" ] && [ -f "$REAPER" ] || { echo "FAIL: missing scripts"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export GPU_JOB_LEASE_DIR="$TMP/leases"
DEL_LOG="$TMP/deletes.log"; : > "$DEL_LOG"
GONE="$TMP/gone"; mkdir -p "$GONE"        # a pod-id file here means "verify says gone"
mkdir -p "$GPU_JOB_LEASE_DIR"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }
lease(){ bash "$LEASE" "$@"; }
deleted(){ grep -qx "$1" "$DEL_LOG"; }    # was pod $1 deleted?

# --- provider stubs (exported so pod_reaper.sh's seams pick them up) ---
cat > "$TMP/list.sh"   <<EOF
#!/bin/bash
# emit "<pod-id> <name>" for the "live" pods of key \$1. A per-key file pods_<secret>.txt partitions
# pods by account (realistic — a pod belongs to ONE key); else the shared pods.txt (any key).
if [ -f "$TMP/pods_\$1.txt" ]; then cat "$TMP/pods_\$1.txt"; else cat "$TMP/pods.txt" 2>/dev/null || true; fi
EOF
cat > "$TMP/del.sh"    <<EOF
#!/bin/bash
echo "\$2" >> "$DEL_LOG"      # record the deleted pod id
# mark it gone so verify passes — UNLESS the pod id is in $TMP/nogone (simulates an unverified delete)
grep -qx "\$2" "$TMP/nogone" 2>/dev/null || touch "$GONE/\$2"
EOF
: > "$TMP/nogone"
cat > "$TMP/verify.sh" <<EOF
#!/bin/bash
[ -f "$GONE/\$2" ]            # exit 0 iff gone
EOF
cat > "$TMP/resolve.sh" <<'EOF'
#!/bin/bash
# Mirror the real resolve_key contract: UNRESOLVABLE and any non-identifier key_ref -> empty (the real
# resolve_key validates the ref is a shell identifier before indirect expansion; a malformed ref is
# unresolvable, never fatal/injected). A valid identifier resolves to a fake secret.
[ "$1" = UNRESOLVABLE ] && exit 0
# valid shell identifier only (explicit negative test — a case glob's trailing * over-matches)
if [ -n "$1" ] && [ -z "${1//[A-Za-z0-9_]/}" ] && [[ "$1" != [0-9]* ]]; then
  echo "secret-for-$1"
fi
exit 0
EOF
cat > "$TMP/keepalive.sh" <<EOF
#!/bin/bash
# echo the keepalive verdict declared per-pod in $TMP/keepalive_<podid>
cat "$TMP/keepalive_\$2" 2>/dev/null || echo ""
EOF
chmod +x "$TMP"/*.sh
export GPU_JOB_LIST_PODS_CMD="bash $TMP/list.sh"
export GPU_JOB_DELETE_POD_CMD="bash $TMP/del.sh"
export GPU_JOB_VERIFY_GONE_CMD="bash $TMP/verify.sh"
export GPU_JOB_RESOLVE_KEY_CMD="bash $TMP/resolve.sh"
export GPU_JOB_KEEPALIVE_CMD="bash $TMP/keepalive.sh"

mk_lease(){ # mk_lease <pod-id> <expiry-min> <key-ref> [contract] [ssh]  -> prints nonce
  local pod=$1 exp=$2 kr=$3 contract=${4:-2} ssh=${5:-}
  local n; n=$(lease intent "$kr" --expiry-min "$exp")
  lease provisional "$n" "$pod" >/dev/null
  if [ "$contract" = 1 ]; then
    # contract-1 legacy lease: enrich with ssh + downgrade refresh_contract to 1 via direct edit
    [ -n "$ssh" ] && lease enrich "$n" --ssh "$ssh" --expiry-min "$exp" >/dev/null
    python3 - "$GPU_JOB_LEASE_DIR/$n.json" <<PY
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["refresh_contract"]=1
json.dump(d, open(p,"w"), indent=2, sort_keys=True)
PY
  fi
  printf '%s\n' "$n"
}

# === fixture 1: expired registered lease is REAPED; fresh one is KEPT ===
EXP=$(mk_lease pod-exp -1 RUNPOD_API_KEY)
FRESH=$(mk_lease pod-fresh 120 RUNPOD_API_KEY)
# === fixture 2: an UNKNOWN live pod (no lease) ===
# === fixture 3: an unresolved-key lease ===
UNRES=$(mk_lease pod-unres -1 UNRESOLVABLE)
# === fixture 4: a pending intent (no pod bound, NOT expired) whose nonce names a live pod -> report ===
PEND=$(lease intent RUNPOD_API_KEY --expiry-min 15)
# === fixture 4b: an EXPIRED pending intent whose nonce names a live pod -> the created-but-id-never-
#     returned case (Finding 4): REAP the half-born pod ===
PEXP=$(lease intent RUNPOD_API_KEY --expiry-min -1)
# === fixture 6: an expired lease whose DELETE can't be verified -> lease REOPENED for retry (Finding 2) ===
NOV=$(mk_lease pod-nov -1 RUNPOD_API_KEY); echo pod-nov >> "$TMP/nogone"
# === fixture 7: a MALFORMED key_ref must NOT abort the reaper (Finding 3) — report-only, not fatal ===
BADK=$(mk_lease pod-badk -1 'bad key$(touch /tmp/PWNED)')
# === fixture 8: an unknown pod whose name == a REGISTERED (provisional) lease nonce must NOT be reaped
#     by name-matching (Finding 4); find-nonce only matches pending intents ===
REGN=$(mk_lease pod-regn 120 RUNPOD_API_KEY)   # provisional, fresh; its nonce is REGN
# a DIFFERENT live pod carrying REGN as its name (a collision/spoof) must be report-only, never reaped
# === fixture 9: a legacy contract-1 lease with NO ssh endpoint -> report-retry, NEVER deleted (Finding 1) ===
LNOSSH=$(lease intent RUNPOD_API_KEY --expiry-min -1); lease provisional "$LNOSSH" pod-lnossh >/dev/null
python3 - "$GPU_JOB_LEASE_DIR/$LNOSSH.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["refresh_contract"]=1   # legacy, and ssh stays null
json.dump(d, open(p,"w"), indent=2, sort_keys=True)
PY
# === fixture 10: an EXPIRED pending intent recorded under a DIFFERENT key_ref, whose nonce names a
#     live pod listed under THIS key -> report-only, never rebound/reaped by the wrong key (Finding 4) ===
XKEY=$(lease intent OTHER_KEY --expiry-min -1)   # pending intent under key_ref OTHER_KEY
# === fixture 5: legacy contract-1 leases, keepalive future / inconclusive / past ===
LF=$(mk_lease pod-lf -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo future       > "$TMP/keepalive_pod-lf"
LI=$(mk_lease pod-li -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo ""           > "$TMP/keepalive_pod-li"
LP=$(mk_lease pod-lp -1 RUNPOD_API_KEY 1 9.9.9.9:22); echo past         > "$TMP/keepalive_pod-lp"

# the "live" pod list the stub returns (pod-id name)
# Two live pods sharing the SAME name (an ambiguous name) -> both report-only, never reaped (Finding 4).
DUPNAME="gpujob-dupedupedupedupedupedupedupe"
# Partition the live pods by account: all fixtures' pods are under the RUNPOD_API_KEY account (key A).
# The XKEY intent is recorded under OTHER_KEY (key B) but its pod (pod-xkey) is listed under key A —
# so the reaper, iterating key A, must NOT reap it (the intent's key_ref != key A). OTHER_KEY's account
# has NO live pods, so the intent is never matched under its own key either.
cat > "$TMP/pods_secret-for-RUNPOD_API_KEY.txt" <<EOF
pod-exp $EXP
pod-fresh $FRESH
pod-unres $UNRES
pod-unknown some-user-name
$PEND $PEND
pod-pexp $PEXP
pod-nov $NOV
pod-badk $BADK
pod-regn-spoof $REGN
pod-dup1 $DUPNAME
pod-dup2 $DUPNAME
pod-lnossh $LNOSSH
pod-xkey $XKEY
pod-lf $LF
pod-li $LI
pod-lp $LP
EOF

OUT=$(bash "$REAPER" 2>&1)

deleted pod-exp           && ok reap-expired || no reap-expired
deleted pod-fresh         && no keep-fresh-deleted || ok keep-fresh-kept
deleted pod-unknown       && no unknown-deleted || ok unknown-report-only
deleted pod-unres         && no unresolved-deleted || ok unresolved-report-only
deleted pod-lf            && no legacy-future-deleted || ok legacy-future-kept
deleted pod-li            && no legacy-inconclusive-deleted || ok legacy-inconclusive-retry
deleted pod-lp            && ok legacy-past-reaped || no legacy-past-reaped
echo "$OUT" | grep -q "not yet expired" && ok pending-intent-not-expired-reported || no pending-intent-not-expired-reported
echo "$OUT" | grep -q "UNKNOWN pod" && ok unknown-logged || no unknown-logged
# a reaped lease is CLOSED after verified delete
[ "$(lease show "$EXP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')" = closed ] \
  && ok reaped-lease-closed || no reaped-lease-closed
# Finding 4: an EXPIRED pending-intent's half-born pod is REAPED (not just reported)
deleted pod-pexp && ok pending-intent-expired-reaped || no pending-intent-expired-reaped
# Finding 2: an unverified delete REOPENS the lease for retry (not stuck in `reaping`, not closed)
deleted pod-nov && ok nov-delete-attempted || no nov-delete-attempted
nov_state=$(lease show "$NOV" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')
case "$nov_state" in
  provisional|enriched|intent) ok nov-reopened-for-retry ;;
  *) no "nov-reopened-for-retry (state=$nov_state)" ;;
esac
if lease is-reapable "$NOV"; then ok nov-reapable-again || true; else no nov-reapable-again; fi
# Finding 3: a malformed key_ref is report-only, NOT fatal, and never executes shell injection
deleted pod-badk && no badk-deleted || ok badk-report-only
[ -e /tmp/PWNED ] && { no badk-no-injection; rm -f /tmp/PWNED; } || ok badk-no-injection
echo "$OUT" | grep -q "unresolved key_ref" && ok badk-unresolved-logged || no badk-unresolved-logged
# Finding 4: an unknown pod spoofing a REGISTERED (provisional) nonce as its name is NOT reaped
deleted pod-regn-spoof && no regn-spoof-deleted || ok regn-spoof-report-only
# Finding 4: two live pods sharing a name are AMBIGUOUS -> both report-only
deleted pod-dup1 && no dup1-deleted || ok dup1-report-only
deleted pod-dup2 && no dup2-deleted || ok dup2-report-only
echo "$OUT" | grep -q "AMBIGUOUS" && ok ambiguous-name-logged || no ambiguous-name-logged
# Finding 1: a legacy contract-1 lease with NO ssh endpoint is report-retry, NEVER deleted
deleted pod-lnossh && no legacy-nossh-deleted || ok legacy-nossh-report-retry
echo "$OUT" | grep -q "no SSH endpoint to check keepalive" && ok legacy-nossh-logged || no legacy-nossh-logged
# Finding 4: an expired pending intent under a DIFFERENT key_ref is report-only, never reaped by this key
deleted pod-xkey && no xkey-cross-key-deleted || ok xkey-cross-key-report-only
echo "$OUT" | grep -q "different key_ref" && ok xkey-logged || no xkey-logged
# the cross-key intent was NOT rebound (still a pending intent, no pod_id)
[ "$(lease show "$XKEY" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pod_id"])')" = None ] \
  && ok xkey-not-rebound || no xkey-not-rebound

# === locked-reap race (Finding 1): a refresh that lands before the reaper's in-lock recheck SAVES
#     the pod. Simulate by refreshing the expired lease to a future expiry, THEN sweeping. ===
RACE=$(mk_lease pod-race -1 RUNPOD_API_KEY)
echo "pod-race $RACE" >> "$TMP/pods_secret-for-RUNPOD_API_KEY.txt"
lease refresh "$RACE" --expiry-min 120 >/dev/null     # the long run refreshed just in time
bash "$REAPER" >/dev/null 2>&1
deleted pod-race && no race-refresh-lost || ok race-refresh-saves-pod

# === --dry-run deletes NOTHING and MUTATES NOTHING even for an expired lease / pending intent ===
: > "$DEL_LOG"
# reset the pods list so prior fixtures (now closed/reaping) don't muddy the dry-run sweep
DRYEXP=$(mk_lease pod-dry -1 RUNPOD_API_KEY)
DRYPEND=$(lease intent RUNPOD_API_KEY --expiry-min -1)   # expired PENDING intent; its nonce names a live pod
rm -f "$TMP"/pods_*.txt
cat > "$TMP/pods_secret-for-RUNPOD_API_KEY.txt" <<EOF
pod-dry $DRYEXP
$DRYPEND $DRYPEND
EOF
DOUT=$(bash "$REAPER" --dry-run 2>&1)
deleted pod-dry && no dryrun-deleted || ok dryrun-deletes-nothing
echo "$DOUT" | grep -q "DRY-RUN would reap" && ok dryrun-logs-would-reap || no dryrun-logs-would-reap
# the dry-run lease is NOT closed/reaping
[ "$(lease show "$DRYEXP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')" = provisional ] \
  && ok dryrun-no-mutation || no dryrun-no-mutation
# Finding 2: dry-run must NOT bind a pending intent provisional — it stays intent, no pod_id
echo "$DOUT" | grep -q "DRY-RUN would bind+reap" && ok dryrun-logs-would-bind || no dryrun-logs-would-bind
[ "$(lease show "$DRYPEND" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')" = intent ] \
  && ok dryrun-pending-not-bound || no dryrun-pending-not-bound

[ "$fails" = 0 ] && { echo "pod_reaper smoke PASS"; exit 0; } || { echo "pod_reaper smoke FAIL"; exit 1; }
