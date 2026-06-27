#!/bin/bash
# issue_verbs_smoke.sh — unit-style smoke for the narrow engineer MAINTAINER verbs (#164):
#   wf.sh issue <fam> close|label|dispose
# Self-contained: fake gh, no network and no real tokens. Asserts each verb (a) routes through the ENGINEER
# token (not the ambient owner token), (b) refuses any flag/subcommand outside its allowlist (the #91 model),
# and (c) for dispose, sets BOTH a label and an idempotent body line.
set -uo pipefail
unset BASH_ENV ENV
unset GH_TOKEN
unset WF_ENGINEER_TOKEN_CMD_CLAUDE WF_ENGINEER_TOKEN_CMD_CODEX WF_REVIEWER_TOKEN_CMD
unset WF_ENGINEER_GIT_AUTHOR_CLAUDE WF_ENGINEER_GIT_AUTHOR_CODEX
unset WF_ALLOW_AMBIENT_IDENTITY AUDIT_VERIFIER_CMD
WF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wf.sh
[ -f "$WF" ] || { echo "FAIL: wf.sh not found next to smoke" >&2; exit 1; }

fail=0
check(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1" >&2; fail=1; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/issue-verbs-smoke.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME" "$TMP/bin"

# Fake gh: logs every invocation (with the resolved GH_TOKEN) and emulates the issue surface the verbs use.
# The issue body for `view --json body` is read from $GH_FAKE_BODY so dispose's idempotency can be exercised.
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
set -u
printf 'TOKEN=%s ARGS=%s\n' "${GH_TOKEN:-<none>}" "$*" >> "${GH_FAKE_LOG:-/dev/null}"
sub=${1:-}; shift || true
# strip a leading "issue"
[ "$sub" = issue ] && { sub=${1:-}; shift || true; }
case "$sub" in
  close) exit 0 ;;
  view)
    # emit the stored body for --json body, or the stored labels (one per line) for --json labels
    want_json=""
    for a in "$@"; do
      if [ "$want_json" = 1 ]; then
        case "$a" in
          body)   cat "${GH_FAKE_BODY:-/dev/null}" 2>/dev/null || echo "" ;;
          labels) cat "${GH_FAKE_LABELS:-/dev/null}" 2>/dev/null || echo "" ;;
        esac
        exit 0
      fi
      case "$a" in --json) want_json=1 ;; esac
    done
    exit 0 ;;
  edit)
    # if a body-file is "-" capture stdin to $GH_FAKE_NEWBODY so the test can inspect the resulting body
    want=0
    for a in "$@"; do
      if [ "$want" = 1 ]; then
        if [ "$a" = "-" ]; then cat > "${GH_FAKE_NEWBODY:-/dev/null}"; fi
        want=0; continue
      fi
      case "$a" in -F|--body-file) want=1 ;; esac
    done
    exit 0 ;;
  *) echo "fake gh: unsupported issue $sub $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FAKE_LOG="$TMP/gh.log"
export GH_FAKE_BODY="$TMP/body.txt"
export GH_FAKE_NEWBODY="$TMP/newbody.txt"
export GH_FAKE_LABELS="$TMP/labels.txt"
: > "$GH_FAKE_LABELS"

# Engineer-token env so the verbs run on the ENGINEER path; the fake gh records the token it saw.
ENGENV=(WF_ENGINEER_TOKEN_CMD_CLAUDE='printf claude-token'
        WF_ENGINEER_TOKEN_CMD_CODEX='printf codex-token')

echo "=== close: routes through the engineer token ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue claude close 42 -R example/repo -c "dup of #10" -r "not planned" 2>&1); rc=$?
echo "$out"
check "close exits zero" "[ $rc -eq 0 ]"
check "close used the claude engineer token" "grep -q 'TOKEN=claude-token ARGS=issue close 42' \"\$GH_FAKE_LOG\""
check "close carried the comment + reason" "grep -q -- '-c dup of #10 -r not planned' \"\$GH_FAKE_LOG\""

echo "=== close: rejects an invalid --reason ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude close 42 -R example/repo -r bogus 2>&1); rc=$?
echo "$out"
check "close with bad reason exits nonzero" "[ $rc -ne 0 ]"
check "close with bad reason explains the allowed set" "grep -qi \"reason must be\" <<<\"\$out\""

echo "=== label: add/remove route through the engineer token ==="
: > "$GH_FAKE_LOG"
out=$(env "${ENGENV[@]}" bash "$WF" issue codex label 42 -R example/repo --add-label ready --remove-label blocked 2>&1); rc=$?
echo "$out"
check "label exits zero" "[ $rc -eq 0 ]"
check "label used the codex engineer token" "grep -q 'TOKEN=codex-token ARGS=issue edit 42' \"\$GH_FAKE_LOG\""
check "label passed add+remove" "grep -q -- '--add-label ready --remove-label blocked' \"\$GH_FAKE_LOG\""

echo "=== label: requires at least one add/remove ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue codex label 42 -R example/repo 2>&1); rc=$?
echo "$out"
check "bare label exits nonzero" "[ $rc -ne 0 ]"

echo "=== dispose: sets a label AND appends a new body line ==="
: > "$GH_FAKE_LOG"; printf 'Original body.\nSome detail.\n' > "$GH_FAKE_BODY"; : > "$GH_FAKE_NEWBODY"
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label blocked --body-line "blocked-by: #99" 2>&1); rc=$?
echo "$out"
check "dispose exits zero" "[ $rc -eq 0 ]"
check "dispose used the claude engineer token" "grep -q 'TOKEN=claude-token ARGS=issue edit 42' \"\$GH_FAKE_LOG\""
check "dispose set the disposition label" "grep -q -- '--add-label blocked' \"\$GH_FAKE_LOG\""
check "dispose preserved the original body" "grep -q 'Original body.' \"\$GH_FAKE_NEWBODY\""
check "dispose appended the body line" "grep -q 'blocked-by: #99' \"\$GH_FAKE_NEWBODY\""

echo "=== dispose: idempotent — re-running replaces the same-key line, no duplicate ==="
: > "$GH_FAKE_NEWBODY"; printf 'Original body.\nblocked-by: #99\n' > "$GH_FAKE_BODY"
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label blocked --body-line "blocked-by: #123" 2>&1); rc=$?
echo "$out"
check "re-dispose exits zero" "[ $rc -eq 0 ]"
check "re-dispose updated the line" "grep -q 'blocked-by: #123' \"\$GH_FAKE_NEWBODY\""
check "re-dispose left no stale #99 line" "! grep -q 'blocked-by: #99' \"\$GH_FAKE_NEWBODY\""
check "re-dispose did not duplicate the key" "[ \$(grep -c 'blocked-by:' \"\$GH_FAKE_NEWBODY\") -eq 1 ]"

echo "=== dispose: rejects a body line with no key ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label blocked --body-line "no colon here" 2>&1); rc=$?
echo "$out"
check "keyless body-line exits nonzero" "[ $rc -ne 0 ]"

echo "=== dispose: rejects a non-disposition --label ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label bug --body-line "blocked-by: #9" 2>&1); rc=$?
echo "$out"
check "non-disposition label exits nonzero" "[ $rc -ne 0 ]"
check "non-disposition label explains the set" "grep -qi 'must be a disposition' <<<\"\$out\""

echo "=== dispose: rejects a body-line key with regex metacharacters ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label blocked --body-line ".*: boom" 2>&1); rc=$?
echo "$out"
check "regex-metachar key exits nonzero" "[ $rc -ne 0 ]"

echo "=== dispose: enforces single disposition (removes the OTHER disposition label) ==="
: > "$GH_FAKE_LOG"; printf 'Original body.\n' > "$GH_FAKE_BODY"; : > "$GH_FAKE_NEWBODY"
printf 'ready\nbug\nblocked\n' > "$GH_FAKE_LABELS"   # issue currently has TWO disposition labels (ready, blocked) + a type label
out=$(env "${ENGENV[@]}" bash "$WF" issue claude dispose 42 -R example/repo --label parked --body-line "parked-reason: later" 2>&1); rc=$?
echo "$out"
check "dispose-with-conflicts exits zero" "[ $rc -eq 0 ]"
check "dispose adds the new disposition" "grep -q -- '--add-label parked' \"\$GH_FAKE_LOG\""
check "dispose removes the stale 'ready' disposition" "grep -q -- '--remove-label ready' \"\$GH_FAKE_LOG\""
check "dispose removes the stale 'blocked' disposition" "grep -q -- '--remove-label blocked' \"\$GH_FAKE_LOG\""
check "dispose does NOT remove the non-disposition 'bug' type label" "! grep -q -- '--remove-label bug' \"\$GH_FAKE_LOG\""
: > "$GH_FAKE_LABELS"   # reset for any later cases

echo "=== dispose: 'parked-reason' is a valid key (only the LABEL is restricted to dispositions) ==="
check "parked-reason key was accepted above" "[ $rc -eq 0 ]"

echo "=== allowlist: a disallowed flag fails closed (no arbitrary passthrough) ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude close 42 -R example/repo --web 2>&1); rc=$?
echo "$out"
check "close --web exits nonzero" "[ $rc -ne 0 ]"
check "close --web names the #91 model" "grep -qi 'not allowed' <<<\"\$out\""

echo "=== allowlist: a flag from the wrong verb is rejected ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude label 42 -R example/repo --body-line "x: y" 2>&1); rc=$?
echo "$out"
check "label --body-line (dispose-only) exits nonzero" "[ $rc -ne 0 ]"

echo "=== allowlist: cross-pollinated flags (close flag on label) rejected ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude label 42 -R example/repo --add-label ready -r completed 2>&1); rc=$?
echo "$out"
check "label with close's -r exits nonzero" "[ $rc -ne 0 ]"

echo "=== a missing issue number fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude close -R example/repo 2>&1); rc=$?
echo "$out"
check "close without a number exits nonzero" "[ $rc -ne 0 ]"

echo "=== an unknown subcommand still fails closed ==="
out=$(env "${ENGENV[@]}" bash "$WF" issue claude delete 42 -R example/repo 2>&1); rc=$?
echo "$out"
check "issue delete exits nonzero" "[ $rc -ne 0 ]"
check "issue delete names the allowed verbs" "grep -q \"'create', 'comment', 'close', 'label', 'dispose'\" <<<\"\$out\""

[ "$fail" = 0 ] && echo "issue_verbs_smoke: PASS" || { echo "issue_verbs_smoke: FAIL" >&2; exit 1; }
