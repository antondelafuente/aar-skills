#!/usr/bin/env bash
# disposition_gate.sh — deterministic STRUCTURAL gate for the disposition-aware merge gate (#137, slice #138).
#
# Validates the PR-local disposition state (a JSON file `wf.sh` manages OUTSIDE the committed tree — canonical
# copy is the PR comment, cache via `git rev-parse --git-path`; NOT a committed `.aar-ci/` file) against the
# reviewer's finding list. Runs BEFORE the model reviewer and is FAIL-CLOSED: any error, malformed file, or
# missing/!valid entry for a HIGH finding -> BLOCK, never PASS. It checks STRUCTURE only (completeness +
# well-formedness, incl. a required non-empty `description`). Whether a disposition is *sound* (does the fix
# fix, does the refutation refute, is the deferral legitimate) is the model reviewer's job (#139).
#
# Usage:  disposition_gate.sh <dispositions.json> <findings-file>
#   <findings-file>: one finding per line, "<ID> <SEVERITY>" (SEVERITY in HIGH|MED|LOW).
# Output: "DISPOSITION-GATE: PASS" (exit 0) or "DISPOSITION-GATE: BLOCK <reason>" (exit 2).
#
# Disposition statuses: fixed | refuted | deferred_to_child_design | deferred_out_of_scope | unresolved
set -uo pipefail

block() { echo "DISPOSITION-GATE: BLOCK $*"; exit 2; }

# A valid issue link is "#123" or a GitHub issue URL — guards against child_issue:true / whitespace.
issue_link_ok() {
  [[ "$1" =~ ^#[0-9]+$ ]] && return 0
  [[ "$1" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+$ ]] && return 0
  return 1
}

DISP=${1:-}
FIND=${2:-}

command -v jq >/dev/null 2>&1 || block "jq not available"
[ -n "$FIND" ] && [ -f "$FIND" ] && [ -r "$FIND" ] || block "findings file missing or unreadable: ${FIND:-<none>}"

# Collect HIGH finding ids from the reviewer output. (MED/LOW never block.)
high_ids=()
all_ids=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  # Strict format: exactly "<ID> <SEVERITY>". A malformed line BLOCKS (fail-closed) — never silently
  # drops to zero HIGHs and passes.
  if [[ ! "$line" =~ ^([^[:space:]]+)[[:space:]]+(HIGH|MED|LOW)$ ]]; then
    block "malformed findings line: '$line' (expected '<ID> <SEVERITY>', SEVERITY in HIGH|MED|LOW)"
  fi
  id=${BASH_REMATCH[1]}
  sev=${BASH_REMATCH[2]}
  all_ids+=("$id")
  [ "$sev" = HIGH ] && high_ids+=("$id")
done < "$FIND"

# Reject duplicate finding ids in the current review — an ambiguous id would let one disposition cover two
# findings. (Stable finding IDENTITY ACROSS rounds is the packet/reviewer contract in #139; #138 only
# guarantees the current invocation is self-consistent.)
if [ "${#all_ids[@]}" -gt 0 ]; then
  dups=$(printf '%s\n' "${all_ids[@]}" | sort | uniq -d)
  [ -z "$dups" ] || block "duplicate finding id(s) in findings list: $(printf '%s ' "$dups" | tr -d '\n')"
fi

# A committed dispositions file must be STRUCTURALLY valid even when this round has no HIGHs — a malformed
# committed file is invalid gate state and must not pass silently just because nothing blocks today.
if [ -n "$DISP" ] && [ -f "$DISP" ]; then
  jq -e . "$DISP" >/dev/null 2>&1 || block "dispositions file is not valid JSON: $DISP"
  jq -e '.findings | type == "array"' "$DISP" >/dev/null 2>&1 || block "dispositions .findings must be an array"
fi

# No HIGH findings -> nothing to gate. A missing dispositions file is acceptable ONLY in this case.
if [ "${#high_ids[@]}" -eq 0 ]; then
  echo "DISPOSITION-GATE: PASS"
  exit 0
fi

# HIGH findings exist -> a dispositions file must be present (its JSON validity + findings-array are
# already enforced above for any present file).
[ -n "$DISP" ] && [ -f "$DISP" ] || block "HIGH findings present but dispositions file missing: ${DISP:-<none>}"

altitude=$(jq -r '.altitude // "implementation"' "$DISP" 2>/dev/null)
case "$altitude" in umbrella | implementation) ;; *) block "invalid altitude '${altitude:-<none>}' (expected umbrella|implementation)" ;; esac

# Base ref for the `fixed`-in-PR-range check. Explicit override wins; else the merge-base with main.
# Resolve to a concrete commit up front and FAIL CLOSED if a base is present but does not resolve — an
# invalid base must never let the range check pass silently (merge-base would just error to "no block").
BASE_REF=${DISPOSITION_BASE_REF:-}
[ -n "$BASE_REF" ] || BASE_REF=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || true)
if [ -n "$BASE_REF" ]; then
  BASE_REF=$(git rev-parse --verify --quiet "${BASE_REF}^{commit}" 2>/dev/null) \
    || block "base ref does not resolve to a commit: '${DISPOSITION_BASE_REF:-<auto-detected>}'"
fi

for id in "${high_ids[@]}"; do
  count=$(jq --arg id "$id" '[.findings[] | select(.id == $id)] | length' "$DISP" 2>/dev/null)
  [ "$count" = 1 ] || block "finding $id: expected exactly 1 disposition entry, found ${count:-0}"
  entry=$(jq -c --arg id "$id" '.findings[] | select(.id == $id)' "$DISP" 2>/dev/null)

  status=$(printf '%s' "$entry" | jq -r '.status // empty' 2>/dev/null)
  # Exact-match dispatch with a default BLOCK — a malformed / multi-token status can never fall through.
  case "$status" in
    unresolved)
      block "finding $id is unresolved (HIGH)" ;;
    refuted)
      : ;; # reason is advisory context for the model reviewer; structurally complete
    deferred_to_child_design)
      [ "$altitude" = umbrella ] || block "finding $id: deferred_to_child_design only allowed at umbrella altitude (altitude=$altitude)"
      child=$(printf '%s' "$entry" | jq -r '.child_issue // empty' 2>/dev/null)
      issue_link_ok "$child" || block "finding $id: deferred_to_child_design requires a child_issue link (#N or a GitHub issue URL), got '${child:-<none>}'" ;;
    deferred_out_of_scope)
      followup=$(printf '%s' "$entry" | jq -r '.followup_issue // empty' 2>/dev/null)
      issue_link_ok "$followup" || block "finding $id: deferred_out_of_scope requires a followup_issue link (#N or a GitHub issue URL), got '${followup:-<none>}'" ;;
    fixed)
      commit=$(printf '%s' "$entry" | jq -r '.commit // empty' 2>/dev/null)
      [ -n "$commit" ] || block "finding $id: fixed requires a commit"
      # Must be a stable hex object id — a moving ref (HEAD/branch/tag) would not pin the claimed fix.
      [[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || block "finding $id: fixed commit must be a hex SHA, not a symbolic ref (HEAD/branch/tag), got '$commit'"
      git rev-parse --verify --quiet "${commit}^{commit}" >/dev/null 2>&1 \
        || block "finding $id: fixed commit '$commit' not found in this repo"
      git merge-base --is-ancestor "$commit" HEAD 2>/dev/null \
        || block "finding $id: fixed commit '$commit' is not reachable from HEAD"
      # Fail closed: without a base ref we cannot prove the fix is in THIS PR (<base>..HEAD).
      [ -n "$BASE_REF" ] || block "finding $id: cannot verify 'fixed' is in the PR range — no base ref (set DISPOSITION_BASE_REF)"
      if git merge-base --is-ancestor "$commit" "$BASE_REF" 2>/dev/null; then
        block "finding $id: fixed commit '$commit' is in the base, not a fix made in this PR (must be in <base>..HEAD)"
      fi ;;
    *)
      block "finding $id: invalid status '${status:-<none>}'" ;;
  esac

  # A non-empty description is required on every HIGH entry — the disposition-aware reviewer matches prior
  # findings on it (#139). Checked after the status dispatch so a status defect still reports its own reason.
  desc=$(printf '%s' "$entry" | jq -r '.description // empty' 2>/dev/null)
  [ -n "$desc" ] || block "finding $id: a non-empty description is required (semantic matching depends on it)"
done

echo "DISPOSITION-GATE: PASS"
exit 0
