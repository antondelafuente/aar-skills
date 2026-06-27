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
#     Guard the setup: a vacuous test (orphan creation failed) must FAIL, not silently "pass".
ORPHAN=$(printf 'orphan' | git commit-tree "$(git rev-parse 'HEAD^{tree}')" 2>/dev/null || true)
if [ -n "$ORPHAN" ] && ! git merge-base --is-ancestor "$ORPHAN" HEAD 2>/dev/null; then
  d=$(disp "{\"altitude\":\"implementation\",\"findings\":[{\"id\":\"F1\",\"severity\":\"HIGH\",\"status\":\"fixed\",\"commit\":\"$ORPHAN\"}]}")
  expect BLOCK fixed-non-ancestor "$d" "$(find_ 'F1 HIGH')"
else
  echo "FAIL fixed-non-ancestor: could not create a genuine non-ancestor commit"; fails=1
fi

# 16. malformed findings line (missing severity) -> BLOCK (fail-closed, never fail-open to zero HIGHs).
d=$(disp '{"altitude":"implementation","findings":[{"id":"F1","severity":"HIGH","status":"unresolved"}]}')
expect BLOCK malformed-findings-line "$d" "$(find_ 'F1')"

# 17. `fixed` commit in the BASE (ancestor of the merge-base with main), not a fix made in this PR -> BLOCK.
BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || true)
if [ -n "$BASE" ]; then
  d=$(disp "{\"altitude\":\"implementation\",\"findings\":[{\"id\":\"F1\",\"severity\":\"HIGH\",\"status\":\"fixed\",\"commit\":\"$BASE\"}]}")
  expect BLOCK fixed-in-base "$d" "$(find_ 'F1 HIGH')"
else
  echo "skip fixed-in-base: no base ref (origin/main or main) available"
fi

# 18. malformed dispositions file with NO HIGH findings -> BLOCK (committed invalid state must not pass).
d=$(disp '{not valid json')
expect BLOCK malformed-file-no-high "$d" "$(find_ 'F1 MED')"

# 19. multi-token / bogus status ("fixed refuted") must NOT slip through to a no-op -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"fixed refuted"}]}')
expect BLOCK status-multi-token "$d" "$(find_ 'F1 HIGH')"

# 20. deferral link that is not an issue ref (JSON true) -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"deferred_to_child_design","child_issue":true}]}')
expect BLOCK defer-child-bad-link "$d" "$(find_ 'F1 HIGH')"

# 21. findings file present but unreadable -> BLOCK (fail-closed, not a silent zero-HIGH pass).
unreadable="$TMP/unreadable.txt"; printf 'F1 HIGH\n' > "$unreadable"; chmod 000 "$unreadable"
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"unresolved"}]}')
if [ -r "$unreadable" ]; then
  echo "skip findings-unreadable: cannot make file unreadable (running as root?)"
else
  expect BLOCK findings-unreadable "$d" "$unreadable"
fi
chmod 644 "$unreadable" 2>/dev/null || true

# 22. invalid DISPOSITION_BASE_REF must FAIL CLOSED for a `fixed` disposition (not fail open) -> BLOCK.
d=$(disp "{\"altitude\":\"implementation\",\"findings\":[{\"id\":\"F1\",\"severity\":\"HIGH\",\"status\":\"fixed\",\"commit\":\"$COMMIT\"}]}")
out=$(DISPOSITION_BASE_REF="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$GATE" "$d" "$(find_ 'F1 HIGH')" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then echo "ok   base-ref-invalid"; else echo "FAIL base-ref-invalid: want BLOCK got PASS :: $out"; fails=1; fi

# 23. .findings as an OBJECT (not an array) must not slip through -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":{"x":{"id":"F1","severity":"HIGH","status":"unresolved"}}}')
expect BLOCK findings-not-array "$d" "$(find_ 'F1 HIGH')"

# 24. deferral link with an invalid GitHub URL (whitespace in owner) -> BLOCK.
d=$(disp '{"altitude":"umbrella","findings":[{"id":"F1","severity":"HIGH","status":"deferred_to_child_design","child_issue":"https://github.com/a b/c/issues/1"}]}')
expect BLOCK defer-child-bad-url "$d" "$(find_ 'F1 HIGH')"

if [ "$fails" -eq 0 ]; then echo "disposition_gate_smoke: ALL PASS"; else echo "disposition_gate_smoke: FAILURES"; fi
exit "$fails"
