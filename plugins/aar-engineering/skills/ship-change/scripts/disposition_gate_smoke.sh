#!/usr/bin/env bash
# Smoke for disposition_gate.sh (#138): exercises the PASS path + every fail-closed BLOCK path.
# Self-contained: builds fixtures in a tempdir; uses a real reachable commit for the `fixed` check.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GATE="$HERE/disposition_gate.sh"
[ -x "$GATE" ] || { echo "FAIL: disposition_gate.sh not executable at $GATE"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

# A real commit reachable from HEAD (the `fixed` check verifies reachability).
COMMIT=$(git rev-parse --verify HEAD 2>/dev/null) || { echo "FAIL: smoke must run inside a git repo"; exit 1; }

disp() { printf '%s' "$1" > "$TMP/d.json"; echo "$TMP/d.json"; }
find_() { printf '%s\n' "$1" > "$TMP/f.txt"; echo "$TMP/f.txt"; }

expect() { # expect <PASS|BLOCK> <name> <disp-path-or-MISSING> <findings-path>
  local want=$1 name=$2 d=$3 f=$4 out rc got
  out=$("$GATE" "$d" "$f" 2>&1); rc=$?
  got=PASS; [ "$rc" -ne 0 ] && got=BLOCK
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want $want got $got :: $out"; fails=1
  fi
}

# 1. No HIGH findings -> PASS (dispositions file irrelevant / may be absent).
expect PASS no-high-no-file "$TMP/absent.json" "$(find_ 'F1 MED')"

# 2. HIGH fixed with a real reachable commit -> PASS.
d=$(disp "{\"altitude\":\"implementation\",\"findings\":[{\"id\":\"F1\",\"severity\":\"HIGH\",\"status\":\"fixed\",\"commit\":\"$COMMIT\"}]}")
expect PASS high-fixed-ok "$d" "$(find_ 'F1 HIGH')"

# 3. HIGH deferred_to_child_design at umbrella with child_issue -> PASS.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"deferred_to_child_design","child_issue":"#139"}]}')
expect PASS high-defer-child-ok "$d" "$(find_ 'F1 HIGH')"

# 4. HIGH refuted -> PASS (structurally complete).
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"refuted","reason":"reviewer wrong"}]}')
expect PASS high-refuted-ok "$d" "$(find_ 'F1 HIGH')"

# 5. HIGH with no disposition entry -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F2","severity":"HIGH","status":"fixed","commit":"'"$COMMIT"'"}]}')
expect BLOCK high-no-entry "$d" "$(find_ 'F1 HIGH')"

# 6. HIGH unresolved -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"unresolved"}]}')
expect BLOCK high-unresolved "$d" "$(find_ 'F1 HIGH')"

# 7. deferred_to_child_design at implementation altitude -> BLOCK.
d=$(disp '{"altitude":"implementation","findings":[{"id":"F1","severity":"HIGH","status":"deferred_to_child_design","child_issue":"#139"}]}')
expect BLOCK defer-child-impl-altitude "$d" "$(find_ 'F1 HIGH')"

# 8. deferred_to_child_design missing child_issue -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"deferred_to_child_design"}]}')
expect BLOCK defer-child-no-link "$d" "$(find_ 'F1 HIGH')"

# 9. deferred_out_of_scope missing followup_issue -> BLOCK.
d=$(disp '{"altitude":"implementation","findings":[{"id":"F1","severity":"HIGH","status":"deferred_out_of_scope"}]}')
expect BLOCK defer-oos-no-link "$d" "$(find_ 'F1 HIGH')"

# 10. fixed with a bogus commit -> BLOCK.
d=$(disp '{"altitude":"implementation","findings":[{"id":"F1","severity":"HIGH","status":"fixed","commit":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}]}')
expect BLOCK fixed-bogus-commit "$d" "$(find_ 'F1 HIGH')"

# 11. invalid status -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"wontfix"}]}')
expect BLOCK invalid-status "$d" "$(find_ 'F1 HIGH')"

# 12. HIGH present but dispositions file missing -> BLOCK (fail-closed).
expect BLOCK high-no-file "$TMP/absent.json" "$(find_ 'F1 HIGH')"

# 13. malformed JSON -> BLOCK.
d=$(disp '{not valid json')
expect BLOCK malformed-json "$d" "$(find_ 'F1 HIGH')"

# 14. invalid altitude -> BLOCK.
d=$(disp '{"altitude":"whatever","findings":[{"id":"F1","severity":"HIGH","status":"unresolved"}]}')
expect BLOCK invalid-altitude "$d" "$(find_ 'F1 HIGH')"

# 15. `fixed` commit that EXISTS but is NOT an ancestor of HEAD (e.g. an unrelated branch) -> BLOCK.
ORPHAN=$(printf 'orphan' | git commit-tree "$(git rev-parse 'HEAD^{tree}')")
d=$(disp "{\"altitude\":\"implementation\",\"findings\":[{\"id\":\"F1\",\"severity\":\"HIGH\",\"status\":\"fixed\",\"commit\":\"$ORPHAN\"}]}")
expect BLOCK fixed-non-ancestor "$d" "$(find_ 'F1 HIGH')"

# 16. malformed findings line (missing severity) -> BLOCK (fail-closed, never fail-open to zero HIGHs).
d=$(disp '{"altitude":"implementation","findings":[{"id":"F1","severity":"HIGH","status":"unresolved"}]}')
expect BLOCK malformed-findings-line "$d" "$(find_ 'F1')"

if [ "$fails" -eq 0 ]; then echo "disposition_gate_smoke: ALL PASS"; else echo "disposition_gate_smoke: FAILURES"; fi
exit "$fails"
