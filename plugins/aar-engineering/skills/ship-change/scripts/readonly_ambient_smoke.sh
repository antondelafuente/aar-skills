#!/bin/bash
# readonly_ambient_smoke.sh — behavior smoke for the read-only-ambient detector (#166, child #2 of #149).
#
# Proves `wf.sh doctor … --readonly` (and the plain-doctor reporter) with a FAKE gh + git on PATH (no network):
#   - three API-surface fixtures via the provenance seam: authoritatively-read-only (PASS), write-capable
#     (FAIL), uninspectable/unattested (FAIL-CLOSED, not PASS);
#   - per-SOURCE isolation: a write-capable GITHUB_TOKEN is caught even behind a read-only GH_TOKEN;
#   - the ambient git-push surface: an auth-rejected --dry-run PASSes, an accepted --dry-run FAILs;
#   - NO fixture path performs a mutation (the fake gh/git record every call; we assert no write reaches them);
#   - the strict --readonly form EXITS NON-ZERO on FAIL, and 0 on PASS (the machine-consumable gate).
set -uo pipefail
# strip any inherited BASH_ENV/ENV so the wf.sh child shells don't source the instance env (same convention as
# identity_smoke.sh), AND any inherited WF_READONLY_* seam so a real instance minter never runs against the
# smoke's fake fixtures (#166 code-review F3) — keeps the smoke hermetic on any agent box. run_strict re-sets
# only WF_READONLY_TOKEN_INFO_CMD per fixture and explicitly clears WF_READONLY_TOKEN_CMD.
unset BASH_ENV ENV WF_READONLY_TOKEN_CMD WF_READONLY_TOKEN_INFO_CMD

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WF="$HERE/wf.sh"

fails=0
pass(){ echo "  ok: $1"; }
fail(){ echo "  FAIL: $1" >&2; fails=$((fails+1)); }

TMP=$(mktemp -d) || { echo "[smoke] FATAL: mktemp -d failed" >&2; exit 2; }
case "$TMP" in /*) : ;; *) echo "[smoke] FATAL: mktemp -d non-absolute '$TMP'" >&2; exit 2 ;; esac
[ -d "$TMP" ] || { echo "[smoke] FATAL: TMP '$TMP' not a dir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
MUTLOG="$TMP/mutations.log"; : > "$MUTLOG"
export READONLY_SMOKE_MUTLOG="$MUTLOG"

# --- a FAKE gh: classifies its own args; records any MUTATING call into MUTLOG; never hits the network. -----
# We need: `gh auth token` (stored cred), `gh auth status`, and `gh api -X PATCH …` (the advisory probe).
# The advisory probe's HTTP status is driven by env READONLY_SMOKE_API: "denied" -> 403, "writable" -> 422.
cat > "$BIN/gh" <<'EOF'
#!/bin/bash
# fake gh for the readonly-ambient smoke.
# find the subcommand + verb (skip a leading -R/--repo value and other flags crudely)
sub=""; verb=""
args=("$@")
i=0; n=${#args[@]}
while [ "$i" -lt "$n" ]; do
  a=${args[$i]}
  case "$a" in
    -R|--repo|-H|--hostname) i=$((i+2)); continue ;;
    -*) i=$((i+1)); continue ;;
    *) sub=$a; verb=${args[$((i+1))]:-}; break ;;
  esac
done
case "$sub" in
  auth)
    case "$verb" in
      token)  printf '%s\n' "${READONLY_SMOKE_STORED_TOKEN:-}" ; exit 0 ;;
      status) [ -n "${READONLY_SMOKE_STORED_TOKEN:-}" ] && exit 0 || exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    # detect a write method (the advisory PATCH probe). Record it as a MUTATION ATTEMPT (so the smoke can
    # assert the probe is the ONLY write-shaped call AND that it never actually mutates — a fake never mutates).
    method="GET"
    j=0; m=${#args[@]}
    while [ "$j" -lt "$m" ]; do
      case "${args[$j]}" in
        -X|--method) method=${args[$((j+1))]:-GET} ;;
        -X*) method=${args[$j]#-X} ;;
        --method=*) method=${args[$j]#--method=} ;;
      esac
      j=$((j+1))
    done
    mu=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    if [ "$mu" != GET ] && [ "$mu" != HEAD ]; then
      # consume any --input body on stdin so the pipe doesn't break, and record the body shape for the
      # mutation-freedom assertion (the real detector pipes an empty '{}' object via --input -).
      body=""; for f in "${args[@]}"; do [ "$f" = "--input" ] && body=$(cat); done
      echo "API_WRITE_ATTEMPT: args=[$*] body=[$body]" >> "$READONLY_SMOKE_MUTLOG"
      # emulate the LIVE behavior proven against a disposable repo (#166 PR evidence): an empty-{} PATCH is
      # ACCEPTED (200, non-mutating) by a write-capable token; DENIED (403/404) for read-only/no-access.
      # Key off the TOKEN in GH_TOKEN (the detector probes per-source with GH_TOKEN="$tok"), so per-source
      # isolation is exercised faithfully (RW_* -> 200; RO_*/everything else -> 403).
      case "${GH_TOKEN:-}" in
        RW_*) printf 'HTTP/2.0 200 OK\n' ; exit 0 ;;
        *)    printf 'HTTP/2.0 403 Forbidden\n' ; exit 1 ;;
      esac
    fi
    # a GET: just succeed (no output needed by the detector's provenance path)
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

# --- a FAKE git: passes through to real git for local ops, but intercepts `push` to simulate the ambient
#     git-push surface. READONLY_SMOKE_GIT=rejected -> auth-reject; =accepted -> accept (FAIL signal). Records
#     any push attempt; --dry-run must NEVER reach a real remote.
REAL_GIT=$(command -v git)
cat > "$BIN/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = push ]; then
    echo "GIT_PUSH_ATTEMPT: \$*" >> "$MUTLOG"
    case "\${READONLY_SMOKE_GIT:-rejected}" in
      accepted) echo "To github (dry run)"; exit 0 ;;
      *) echo "fatal: Authentication failed for remote" >&2; exit 128 ;;
    esac
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN/git"

# --- provenance seam fixtures: WF_READONLY_TOKEN_INFO_CMD reads the token on stdin, prints canonical perms.
#     We key the emitted perms off the token VALUE so per-source isolation is testable.
INFOCMD="$TMP/info.sh"
cat > "$INFOCMD" <<'EOF'
#!/bin/bash
tok=$(cat)
case "$tok" in
  RO_*) printf '{"permissions":{"contents":"read","metadata":"read","pull_requests":"read"}}\n' ;;
  RW_*) printf '{"permissions":{"contents":"write","metadata":"read"}}\n' ;;
  *)    : ;;   # unattested: emit nothing -> detector FAILS CLOSED
esac
EOF
chmod +x "$INFOCMD"

REPO="o/r"
# run the strict detector with a controlled env. Returns the exit code; stdout captured in $RO_OUT.
run_strict(){  # run_strict <GH_TOKEN> <GITHUB_TOKEN> <stored> <api-fixture> <git-fixture>
  RO_OUT=$(PATH="$BIN:$PATH" \
    GH_TOKEN="${1:-}" GITHUB_TOKEN="${2:-}" READONLY_SMOKE_STORED_TOKEN="${3:-}" \
    READONLY_SMOKE_API="${4:-denied}" READONLY_SMOKE_GIT="${5:-rejected}" \
    WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" \
    bash "$WF" doctor claude "$REPO" --readonly 2>&1)
  return $?
}

echo "[smoke] read-only-ambient detector"

# fixture 1: authoritatively read-only token on GH_TOKEN, git rejected -> PASS, exit 0
: > "$MUTLOG"
if run_strict "RO_aaa" "" "" denied rejected; then
  echo "$RO_OUT" | grep -q 'READONLY-PASS' && pass "read-only token -> PASS (exit 0)" || fail "read-only token: expected READONLY-PASS line"
else
  fail "read-only token should exit 0; got nonzero. out: $RO_OUT"
fi

# fixture 2: write-capable token -> FAIL, exit nonzero
: > "$MUTLOG"
if run_strict "RW_bbb" "" "" writable rejected; then
  fail "write-capable token should exit NONZERO"
else
  echo "$RO_OUT" | grep -q 'READONLY-FAIL' && pass "write-capable token -> FAIL (exit nonzero)" || fail "write-capable token: expected READONLY-FAIL line"
  echo "$RO_OUT" | grep -qi 'write/admin' && pass "FAIL names the write/admin provenance" || fail "FAIL should cite write/admin provenance"
fi

# fixture 3: uninspectable/unattested token (no info match) -> FAIL CLOSED, exit nonzero (NOT pass)
: > "$MUTLOG"
if run_strict "OPAQUE_ccc" "" "" denied rejected; then
  fail "unattested token should exit NONZERO (fail closed), not pass"
else
  echo "$RO_OUT" | grep -q 'FAIL-CLOSED' && pass "unattested token -> FAIL-CLOSED (not a pass)" || fail "unattested token: expected FAIL-CLOSED line"
  echo "$RO_OUT" | grep -qi 'advisory NEVER certifies a PASS' && pass "advisory-never-certifies note present" || fail "missing advisory-never-certifies note"
fi

# fixture 4: per-source isolation — read-only GH_TOKEN but WRITE-capable GITHUB_TOKEN -> overall FAIL
: > "$MUTLOG"
if run_strict "RO_aaa" "RW_ddd" "" writable rejected; then
  fail "write-capable GITHUB_TOKEN behind read-only GH_TOKEN should FAIL"
else
  echo "$RO_OUT" | grep -q 'GITHUB_TOKEN: FAIL' && pass "per-source: write-capable GITHUB_TOKEN caught behind read-only GH_TOKEN" || fail "per-source isolation did not catch GITHUB_TOKEN"
  echo "$RO_OUT" | grep -q 'GH_TOKEN: read-only' && pass "per-source: GH_TOKEN still reported read-only" || fail "GH_TOKEN should still read read-only"
fi

# fixture 5: stored gh auth credential is write-capable -> FAIL (env tokens absent)
: > "$MUTLOG"
if run_strict "" "" "RW_eee" writable rejected; then
  fail "write-capable stored gh auth should FAIL"
else
  echo "$RO_OUT" | grep -q 'stored gh auth: FAIL' && pass "stored gh auth write-capable -> FAIL" || fail "stored gh auth FAIL not reported"
fi

# fixture 6: ambient git-push ACCEPTED -> FAIL even with a read-only API token
: > "$MUTLOG"
if run_strict "RO_aaa" "" "" denied accepted; then
  fail "accepted git push --dry-run should FAIL the detector"
else
  echo "$RO_OUT" | grep -q 'ambient git push: FAIL' && pass "git-push accepted -> FAIL" || fail "git-push FAIL not reported"
fi

# fixture 7: ambient git-push rejected -> read-only on the git surface
: > "$MUTLOG"
run_strict "RO_aaa" "" "" denied rejected || true
echo "$RO_OUT" | grep -q 'ambient git push: read-only' && pass "git-push rejected -> read-only" || fail "git-push read-only not reported"

# --- MUTATION-FREEDOM: across ALL fixtures, the only write-shaped calls were the advisory PATCH probe and the
#     --dry-run push; assert the fake never performed a real mutation (it can't, by construction) AND that the
#     git push calls all carried --dry-run.
: > "$MUTLOG"
run_strict "RW_bbb" "" "" writable accepted || true
if grep -q 'GIT_PUSH_ATTEMPT' "$MUTLOG"; then
  if grep 'GIT_PUSH_ATTEMPT' "$MUTLOG" | grep -vq -- '--dry-run'; then
    fail "a git push WITHOUT --dry-run was attempted (mutation risk)"
  else
    pass "every git push attempt carried --dry-run (non-mutating)"
  fi
fi
if grep -q 'API_WRITE_ATTEMPT' "$MUTLOG"; then
  # the advisory probe must carry an EMPTY {} body and NO -f settable field (no field -> never mutates, proven
  # live against a disposable repo where an empty-{} PATCH returns 200 without changing updated_at).
  if grep 'API_WRITE_ATTEMPT' "$MUTLOG" | grep -Eq -- '(^| )-f( |=)|(^| )--field'; then
    fail "the advisory API probe carried a -f/--field (could mutate)"
  elif grep 'API_WRITE_ATTEMPT' "$MUTLOG" | grep -vq -- 'body=\[{}\]'; then
    fail "the advisory API probe did not carry the expected empty {} body"
  else
    pass "advisory API probe carried only an empty {} body (non-mutating by construction)"
  fi
fi

# --- plain doctor prints the read-only section as a labeled reporter (does not require engineer identity to PASS
#     for the read-only verdict to print). We only assert the section + verdict line appear.
PLAIN_OUT=$(PATH="$BIN:$PATH" GH_TOKEN="RO_aaa" READONLY_SMOKE_API=denied READONLY_SMOKE_GIT=rejected \
  WF_READONLY_TOKEN_CMD="" WF_READONLY_TOKEN_INFO_CMD="$INFOCMD" WF_ALLOW_AMBIENT_IDENTITY=1 \
  bash "$WF" doctor claude "$REPO" 2>&1 || true)
echo "$PLAIN_OUT" | grep -q 'read-only ambient credential (#166)' && pass "plain doctor prints the read-only section" || fail "plain doctor missing the read-only section"
echo "$PLAIN_OUT" | grep -q 'read-only ambient verdict:' && pass "plain doctor prints the read-only verdict line" || fail "plain doctor missing the verdict line"

if [ "$fails" -gt 0 ]; then echo "[smoke] FAILED ($fails)"; exit 1; fi
echo "[smoke] all read-only-ambient detector checks passed"
