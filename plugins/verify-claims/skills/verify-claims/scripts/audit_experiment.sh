#!/bin/bash
# audit_experiment.sh — independent, cross-family adversarial AUDIT of a completed experiment.
#
# Sibling to verify_claim.sh. Where verify_claim CHECKS a given list of claims (input-side gate,
# pre-launch), this GENERATES findings about a finished experiment (output-side gate, at close).
# It audits the experiment dir AGAINST the AAR's own constitution (AGENTS.md) + a validity rubric,
# run by a DIFFERENT model family than the agent that produced the work — because an agent cannot
# reliably catch its own reproducibility gaps, overclaims, or confounds, but a foreign reader can.
#
# Cross-family is the whole point: on a Claude AAR the auditor is Codex; on a Codex AAR set
# AUDIT_VERIFIER_CMD to `claude -p …`. Always the OTHER family from whoever ran the experiment.
#
# Validated 2026-06-12: from a cold read of a pre-fix experiment state, Codex independently
# rediscovered all three findings a human had routed to ChatGPT (repro gap, in-sample steering,
# claim overreach) PLUS two more (records-self-sufficiency, a missing random-direction control),
# with zero false findings. That probe is why this exists.
#
# Usage: audit_experiment.sh <experiment-dir> [out-file]
#   experiment-dir: the ~/orchestrator/<exp>/ dir to audit (read-only; the auditor sees its files)
#   out-file:       findings destination (default: <experiment-dir>/AUDIT.md)
# Output: severity-rated FINDINGs (HIGH/MED/LOW) per dimension, each with a record citation, plus
#   the dimensions where nothing material was found. "No material finding" is an allowed, common
#   output — inventing issues destroys the tool's value (calibration property inherited from
#   verify_claim).
set -euo pipefail
EXP=${1:?usage: audit_experiment.sh <experiment-dir> [out-file]}
OUT=${2:-${EXP%/}/AUDIT.md}
[ -d "$EXP" ] || { echo "BLOCKED: experiment dir missing: $EXP" >&2; exit 1; }

# The constitution the auditor checks against (the instance's AGENTS.md; overridable for portability).
CONSTITUTION=${AUDIT_CONSTITUTION:-$HOME/AGENTS.md}
CONSTI_TEXT=""
[ -f "$CONSTITUTION" ] && CONSTI_TEXT=$(cat "$CONSTITUTION")

PROMPT="You are an INDEPENDENT ADVERSARIAL AUDITOR from a different model family than the agent that
ran this experiment. You are auditing a COMPLETED autonomous-research experiment before it is treated
as 'done'. Read any file in the current directory tree (grep/head as needed; some logs are large).

You audit the experiment AGAINST the research program's own constitution, included below. The most
load-bearing standards in it: a fresh agent must be able to reproduce the run and know its conclusion
FROM THIS DIR ALONE; conclusions (pre-registered) must be separated from postdictions (fitted after);
validity and comparability are the main failure mode; headline numbers must trace to committed code,
not ad-hoc steps.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. REPRODUCIBILITY — were the HEADLINE numeric artifacts produced by COMMITTED code (the scripts/
   drivers in the dir), or by something not in the records? Does committed code regenerate them? Is
   there evidence of a clean rerun?
2. CLAIM-vs-EVIDENCE — does each CONCLUSION follow from the data shown, or overreach the method
   (causal-strength, generality, storage-vs-correlation, in-sample-vs-general)?
3. CONFOUNDS / VALIDITY — comparisons matched, baselines present, alternative explanations and
   missing controls (e.g. random/orthogonal baselines) ruled out?
4. CONCLUSIONS vs POSTDICTIONS — separated, postdictions flagged untested?
5. RECORDS SELF-SUFFICIENCY — could a fresh agent reproduce the headline results FROM THIS DIR ALONE
   (are the decisive artifacts/probes/logs present, not only referenced on remote storage)?
6. HONEST BOUNDS — are the real limitations (n, single model/organism, in-sample fits, selected
   sweeps) stated?

Output format (exactly), most severe first:
FINDING <n>: <HIGH|MED|LOW> [<dimension>]
  issue: <one sentence>
  evidence: <file>: \"<short quote or precise reference>\"
  recommendation: <one sentence>
...
NO-FINDING DIMENSIONS: <list any dimension where you found nothing material>
SUMMARY: high=<n> med=<n> low=<n>

=== THE PROGRAM CONSTITUTION (audit against this) ===
$CONSTI_TEXT"

# Default verifier = Codex, mechanically read-only (the calibrated runner). On a Codex AAR, override:
#   AUDIT_VERIFIER_CMD='claude -p --output-file "$OUT"'  (or equivalent headless Claude)
VERIFIER_CMD=${AUDIT_VERIFIER_CMD:-"codex exec --sandbox read-only --skip-git-repo-check --cd \"$EXP\" -o \"$OUT\""}
echo "[audit_experiment] exp=$EXP verifier=${AUDIT_VERIFIER_CMD:-codex}" >&2
eval "$VERIFIER_CMD" <<< "$PROMPT" >"$OUT.run.log" 2>&1 || {
  echo "BLOCKED: auditor run failed — last lines of $OUT.run.log:" >&2; tail -5 "$OUT.run.log" >&2; exit 1; }
[ -s "$OUT" ] || { echo "BLOCKED: auditor produced no findings file" >&2; exit 1; }
echo "[audit_experiment] findings -> $OUT" >&2
grep -E "^FINDING|^SUMMARY|^NO-FINDING" "$OUT" || true
