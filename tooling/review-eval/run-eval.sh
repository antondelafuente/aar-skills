#!/bin/bash
# run-eval.sh <prompt-file> [cases.tsv] — eval a reviewer prompt vs the golden corpus (Codex), measuring tokens/review.
# type=pr cases fetch a diff from this repo (override: REVIEW_EVAL_REPO). Auth: ambient GH_TOKEN, else gh's own login.
REPO="${REVIEW_EVAL_REPO:-antondelafuente/automated-researcher}"
P="$(cat "$1")"; DIR=$(cd "$(dirname "$1")" && pwd)
CASES="${2:-$DIR/cases.tsv}"; ok=0; n=0; tok=0
printf "  %-16s %-9s %-9s %-6s %s\n" CASE GOLDEN GOT "" TOKENS
while IFS='|' read -r id typ ref gold; do [ -z "$id" ] && continue
  case "$typ" in pr) d=$(gh pr diff "$ref" -R "$REPO" 2>/dev/null | head -c 55000);; syn) d=$(cat "$DIR/syn/$ref");; esac
  out=$(timeout 200 codex exec --sandbox read-only --skip-git-repo-check "$P

--- THE CHANGE ---
$d" < /dev/null 2>&1)
  v=$(echo "$out" | grep -oiE 'VERDICT:[[:space:]]*(APPROVE|BLOCK)' | tail -1 | grep -oiE 'APPROVE|BLOCK' | tr a-z A-Z)
  tk=$(echo "$out" | grep -iA1 'tokens used' | tail -1 | tr -dc '0-9'); tk=${tk:-0}
  [ "$v" = "$gold" ] && { r=OK; ok=$((ok+1)); } || r=" X"
  n=$((n+1)); tok=$((tok+tk)); printf "  %-16s %-9s %-9s %-6s %s\n" "$id" "$gold" "${v:-?}" "$r" "$tk"
done < "$CASES"
echo "  -----"; echo "  SCORE: $ok/$n   total tokens: $tok   avg/review: $((tok/n))"
