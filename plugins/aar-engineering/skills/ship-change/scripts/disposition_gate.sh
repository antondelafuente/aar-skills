#!/usr/bin/env bash
# disposition_gate.sh — deterministic STRUCTURAL gate for the disposition-aware merge gate (#137, slice #138).
#
# Validates a committed `.aar-ci/dispositions.json` against the reviewer's finding list. Runs BEFORE the model
# reviewer and is FAIL-CLOSED: any error, malformed file, or missing/!valid entry for a HIGH finding -> BLOCK,
# never PASS. It checks STRUCTURE only (completeness + well-formedness). Whether a disposition is *sound*
# (does the fix fix, does the refutation refute, is the deferral legitimate) is the model reviewer's job (#139).
#
# Usage:  disposition_gate.sh <dispositions.json> <findings-file>
#   <findings-file>: one finding per line, "<ID> <SEVERITY>" (SEVERITY in HIGH|MED|LOW).
# Output: "DISPOSITION-GATE: PASS" (exit 0) or "DISPOSITION-GATE: BLOCK <reason>" (exit 2).
#
# Disposition statuses: fixed | refuted | deferred_to_child_design | deferred_out_of_scope | unresolved
set -uo pipefail

block() { echo "DISPOSITION-GATE: BLOCK $*"; exit 2; }

DISP=${1:-}
FIND=${2:-}

command -v jq >/dev/null 2>&1 || block "jq not available"
[ -n "$FIND" ] && [ -f "$FIND" ] || block "findings file missing: ${FIND:-<none>}"

# Collect HIGH finding ids from the reviewer output. (MED/LOW never block.)
high_ids=()
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  # Strict format: exactly "<ID> <SEVERITY>". A malformed line BLOCKS (fail-closed) — never silently
  # drops to zero HIGHs and passes.
  if [[ ! "$line" =~ ^([^[:space:]]+)[[:space:]]+(HIGH|MED|LOW)$ ]]; then
    block "malformed findings line: '$line' (expected '<ID> <SEVERITY>', SEVERITY in HIGH|MED|LOW)"
  fi
  id=${BASH_REMATCH[1]}
  sev=${BASH_REMATCH[2]}
  [ "$sev" = HIGH ] && high_ids+=("$id")
done < "$FIND"

# A committed dispositions file must be valid JSON even when this round has no HIGHs — a malformed
# committed file is invalid gate state and must not pass silently just because nothing blocks today.
if [ -n "$DISP" ] && [ -f "$DISP" ]; then
  jq -e . "$DISP" >/dev/null 2>&1 || block "dispositions file is not valid JSON: $DISP"
fi

# No HIGH findings -> nothing to gate. A missing dispositions file is acceptable ONLY in this case.
if [ "${#high_ids[@]}" -eq 0 ]; then
  echo "DISPOSITION-GATE: PASS"
  exit 0
fi

# HIGH findings exist -> the dispositions file must be present and valid JSON.
[ -n "$DISP" ] && [ -f "$DISP" ] || block "HIGH findings present but dispositions file missing: ${DISP:-<none>}"
jq -e . "$DISP" >/dev/null 2>&1 || block "dispositions file is not valid JSON: $DISP"

altitude=$(jq -r '.altitude // "implementation"' "$DISP" 2>/dev/null)
case "$altitude" in umbrella | implementation) ;; *) block "invalid altitude '${altitude:-<none>}' (expected umbrella|implementation)" ;; esac

allowed=' fixed refuted deferred_to_child_design deferred_out_of_scope unresolved '

for id in "${high_ids[@]}"; do
  entry=$(jq -c --arg id "$id" '.findings[] | select(.id == $id)' "$DISP" 2>/dev/null)
  [ -n "$entry" ] || block "HIGH finding $id has no disposition entry"

  status=$(printf '%s' "$entry" | jq -r '.status // empty' 2>/dev/null)
  case "$allowed" in *" $status "*) ;; *) block "finding $id: invalid status '${status:-<none>}'" ;; esac

  case "$status" in
    unresolved)
      block "finding $id is unresolved (HIGH)" ;;
    deferred_to_child_design)
      [ "$altitude" = umbrella ] || block "finding $id: deferred_to_child_design only allowed at umbrella altitude (altitude=$altitude)"
      child=$(printf '%s' "$entry" | jq -r '.child_issue // empty' 2>/dev/null)
      [ -n "$child" ] || block "finding $id: deferred_to_child_design requires a child_issue link" ;;
    deferred_out_of_scope)
      followup=$(printf '%s' "$entry" | jq -r '.followup_issue // empty' 2>/dev/null)
      [ -n "$followup" ] || block "finding $id: deferred_out_of_scope requires a followup_issue link" ;;
    fixed)
      commit=$(printf '%s' "$entry" | jq -r '.commit // empty' 2>/dev/null)
      [ -n "$commit" ] || block "finding $id: fixed requires a commit"
      git rev-parse --verify --quiet "${commit}^{commit}" >/dev/null 2>&1 \
        || block "finding $id: fixed commit '$commit' not found in this repo"
      # Must be IN this PR branch — an existing object from an unrelated branch must not satisfy `fixed`.
      git merge-base --is-ancestor "$commit" HEAD 2>/dev/null \
        || block "finding $id: fixed commit '$commit' is not reachable from HEAD"
      # Must be IN THE PR RANGE (<base>..HEAD), not merely any ancestor — an old base/main commit is not a
      # fix made in this PR.
      base=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || true)
      if [ -n "$base" ] && git merge-base --is-ancestor "$commit" "$base" 2>/dev/null; then
        block "finding $id: fixed commit '$commit' is in the base branch, not a fix made in this PR (must be in <base>..HEAD)"
      fi ;;
    refuted)
      : ;; # reason is advisory context for the model reviewer; structurally complete
  esac
done

echo "DISPOSITION-GATE: PASS"
exit 0
