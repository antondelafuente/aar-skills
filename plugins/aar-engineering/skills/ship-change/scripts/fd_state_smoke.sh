#!/usr/bin/env bash
# Smoke for the finding-disposition pure helpers (#139): extracts the fd_* block from wf.sh and tests
# fd_fid (stable id), fd_seed (seed findings as unresolved, idempotent), fd_high_list (HIGH extraction).
# The gh-backed fd_load/fd_save/fd_active are defined but not exercised here (they need a live PR).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/wf.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }

# Load just the fd_* helpers (between the section comment and the extraction sentinel).
eval "$(sed -n '/finding-disposition state (#137\/#139)/,/^# fd-helpers-end/p' "$WF")"

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# fd_fid: stable + case/space-insensitive on the same substance, different for different text.
a=$(fd_fid "The new merge_records path crashes on empty input")
b=$(fd_fid "the   NEW merge_records   path crashes on empty input")
c=$(fd_fid "an unrelated finding about quoting")
[ "$a" = "$b" ] && ok fid-stable-normalized || no "fid-stable-normalized ($a vs $b)"
[ "$a" != "$c" ] && ok fid-distinct || no fid-distinct
[ "${#a}" = 12 ] && ok fid-length || no "fid-length (${#a})"

# fd_seed: seeds findings as unresolved; idempotent (second seed adds nothing).
cache="$TMP/c.json"
cat > "$TMP/rev.md" <<'REV'
FINDING 1: HIGH [correctness]
  issue: empty input crashes merge_records
  recommendation: guard it
FINDING 2: MED [edge-case]
  issue: whitespace not trimmed
  recommendation: trim
REV
: > "$cache"
fd_seed "$cache" "$TMP/rev.md"
[ "$(jq '.findings|length' "$cache")" = 2 ] && ok seed-count || no "seed-count ($(jq '.findings|length' "$cache"))"
[ "$(jq -r '.findings[0].status' "$cache")" = unresolved ] && ok seed-unresolved || no seed-unresolved
[ "$(jq -r '.findings[0].description' "$cache")" = "empty input crashes merge_records" ] && ok seed-description || no seed-description
fd_seed "$cache" "$TMP/rev.md"   # again
[ "$(jq '.findings|length' "$cache")" = 2 ] && ok seed-idempotent || no "seed-idempotent ($(jq '.findings|length' "$cache"))"

# author dispositions one; a NEW finding in a later round is added, the dispositioned one is untouched.
jq '(.findings[]|select(.severity=="HIGH")).status="fixed"' "$cache" > "$cache.t" && mv "$cache.t" "$cache"
cat > "$TMP/rev2.md" <<'REV'
FINDING 1: HIGH [correctness]
  issue: empty input crashes merge_records
FINDING 2: HIGH [security]
  issue: brand new token leak
REV
fd_seed "$cache" "$TMP/rev2.md"
[ "$(jq '.findings|length' "$cache")" = 3 ] && ok seed-adds-new-only || no "seed-adds-new-only ($(jq '.findings|length' "$cache"))"
[ "$(jq -r '.findings[]|select(.description|contains("merge_records")).status' "$cache")" = fixed ] && ok seed-keeps-disposition || no seed-keeps-disposition

# fd_high_list: emits "<id> HIGH" only for HIGH entries.
n=$(fd_high_list "$cache" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok high-list-count || no "high-list-count ($n)"
fd_high_list "$cache" | grep -qE '^[0-9a-f]{12} HIGH$' && ok high-list-format || no high-list-format

if [ "$fails" -eq 0 ]; then echo "fd_state_smoke: ALL PASS"; else echo "fd_state_smoke: FAILURES"; fi
exit "$fails"
