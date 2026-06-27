#!/usr/bin/env bash
# Smoke: audit_experiment.sh disposition-aware prompt injection (#139). Uses AUDIT_DRY_RUN to dump the
# assembled prompt without invoking a model. Asserts:
#   - no DISPOSITION_FILE -> NO disposition framing (backward compatible), dimensional review prompt present;
#   - with DISPOSITION_FILE -> framing + the disposition JSON injected + the code deferral rule, AND the
#     dimensional review prompt is still present (augment, never replace).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
A="$HERE/audit_experiment.sh"
[ -x "$A" ] || { echo "FAIL: audit_experiment.sh not executable at $A"; exit 1; }
ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || { echo "FAIL: not in a git repo"; exit 1; }
[ -f "$ROOT/AGENTS.md" ] || { echo "FAIL: need $ROOT/AGENTS.md as the constitution"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
printf '+ echo hi\n' > "$TMP/x.diff"
cat > "$TMP/d.json" <<'J'
{"altitude":"umbrella","findings":[{"id":"abc","severity":"HIGH","description":"SENTINEL_DESC_139","status":"deferred_to_child_design","child_issue":"#1"}]}
J

run() { # run [disposition-file] -> prints assembled prompt (dry run, no model)
  local df=${1:-}
  if [ -n "$df" ]; then
    BASH_ENV= AUDIT_VERIFIER_CMD= AAR_SUBSTRATE=claude AUDIT_DRY_RUN=1 AUDIT_CONSTITUTION="$ROOT/AGENTS.md" \
      DISPOSITION_FILE="$df" bash "$A" --code "$TMP/x.diff" "$ROOT" "$TMP/out" 2>/dev/null
  else
    BASH_ENV= AUDIT_VERIFIER_CMD= AAR_SUBSTRATE=claude AUDIT_DRY_RUN=1 AUDIT_CONSTITUTION="$ROOT/AGENTS.md" \
      bash "$A" --code "$TMP/x.diff" "$ROOT" "$TMP/out" 2>/dev/null
  fi
}

assert() { # assert <0|1 condition> <name>
  if [ "$1" = 1 ]; then echo "ok   $2"; else echo "FAIL $2"; fails=1; fi
}
has() { grep -q "$2" <<<"$1" && echo 1 || echo 0; }
hasi() { grep -qi "$2" <<<"$1" && echo 1 || echo 0; }

no=$(run "")
yes=$(run "$TMP/d.json")

# backward compatible: no file -> no framing, but the dimensional review is intact
assert "$([ "$(has "$no" 'DISPOSITION-AWARE')" = 0 ] && echo 1 || echo 0)" no-file-has-no-framing
assert "$(has "$no" 'INDEPENDENT CODE REVIEWER')" no-file-dimensional-preserved

# with file -> framing + injected JSON + code deferral rule + dimensional preserved
assert "$(has "$yes" 'DISPOSITION-AWARE')"            with-file-framing
assert "$(has "$yes" 'SENTINEL_DESC_139')"            with-file-json-injected
assert "$(hasi "$yes" 'never deferrable')"            with-file-code-deferral-rule
assert "$(has "$yes" 'INDEPENDENT CODE REVIEWER')"    with-file-dimensional-preserved

if [ "$fails" -eq 0 ]; then echo "disposition_inject_smoke: ALL PASS"; else echo "disposition_inject_smoke: FAILURES"; fi
exit "$fails"
