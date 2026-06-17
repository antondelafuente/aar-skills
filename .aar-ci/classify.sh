#!/bin/bash
# classify.sh — record whether a scaffold change is MECHANICAL or ARCHITECTURAL, WITH EVIDENCE.
#
# Architectural = needs the human (PM)'s design approval; mechanical = the agents merge it on the cross-family
# review + checks alone. FAIL-CLOSED: a change defaults to ARCHITECTURAL unless it is explicitly marked
# mechanical — a mislabel can never silently skip the human gate. Policy lives in the adjustable .aar-ci/classifier.conf.
#
# Usage: classify.sh [--mechanical "<reason>"] <changed-path>...
#   (no flag)               -> architectural unless every path is clearly low-risk AND nothing hits a hard rule;
#                              with the fail-closed default that means: architectural unless explicitly downgraded.
#   --mechanical "<reason>" -> the reviewer/human DOWNGRADES to mechanical, recorded with the reason — only honored
#                              if NO always-architectural hard rule fired (you can't downgrade a constitution change).
# Output: "CLASSIFICATION: architectural|mechanical" + "EVIDENCE: ..." lines. Always exit 0 — it RECORDS, never blocks
# (shadow mode and beyond: the gate that acts on this lives in the workflow / branch protection, not here).
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if ! source "$ROOT/.aar-ci/classifier.conf" 2>/dev/null || [ "${#ALWAYS_ARCHITECTURAL[@]}" -eq 0 ]; then
  echo "CLASSIFICATION: architectural"
  echo "EVIDENCE: no usable .aar-ci/classifier.conf -> fail-closed to architectural"
  exit 0
fi

MECH_REASON=""
if [ "${1:-}" = "--mechanical" ]; then MECH_REASON=${2:?--mechanical needs a reason}; shift 2; fi
PATHS=("$@")
if [ ${#PATHS[@]} -eq 0 ]; then
  echo "CLASSIFICATION: architectural"
  echo "EVIDENCE: no changed paths given -> fail-closed to architectural"
  exit 0
fi

# Hard rules: any changed path matching an ALWAYS_ARCHITECTURAL glob => architectural (cannot be downgraded).
hits=()
for p in "${PATHS[@]}"; do
  for g in "${ALWAYS_ARCHITECTURAL[@]}"; do
    # shellcheck disable=SC2254
    case "$p" in $g) hits+=("$p matches '$g'");; esac
  done
done

if [ ${#hits[@]} -gt 0 ]; then
  echo "CLASSIFICATION: architectural"
  printf 'EVIDENCE: always-architectural — %s\n' "${hits[@]}"
  [ -n "$MECH_REASON" ] && echo "EVIDENCE: --mechanical override IGNORED — a hard-rule path can't be downgraded"
  exit 0
fi

# No hard rule fired.
if [ -n "$MECH_REASON" ]; then
  echo "CLASSIFICATION: mechanical"
  echo "EVIDENCE: no always-architectural path; explicitly downgraded by reviewer — $MECH_REASON"
else
  echo "CLASSIFICATION: architectural"
  echo "EVIDENCE: no always-architectural path matched, and not explicitly marked mechanical -> fail-closed default (architectural)"
fi
exit 0
