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
  id=${line%% *}
  sev=${line#* }
  [ "$sev" = HIGH ] && high_ids+=("$id")
done < "$FIND"

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
        || block "finding $id: fixed commit '$commit' not found in this repo" ;;
    refuted)
      : ;; # reason is advisory context for the model reviewer; structurally complete
  esac
done

echo "DISPOSITION-GATE: PASS"
exit 0
