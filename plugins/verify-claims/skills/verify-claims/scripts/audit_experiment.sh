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
# The cross-family guarantee is MECHANICAL here (not just documented): set AAR_SUBSTRATE to the
# family that RAN the experiment; the script refuses to run if the auditor family would match it.
#
# Validated 2026-06-12: from a cold read of a pre-fix experiment state, Codex independently
# rediscovered all three findings a human had routed to ChatGPT (repro gap, in-sample steering,
# claim overreach) PLUS two more, with zero false findings. Hardened 2026-06-12 (audit-the-auditor):
# stale-output guard, cross-family enforcement, DATA SANITY dimension, durable-vs-committed wording.
#
# Usage: audit_experiment.sh <experiment-dir> [out-file]              # close-side (post-hoc) audit
#        audit_experiment.sh --design <experiment-dir> [design-file] [out-file]   # PRE-LAUNCH design audit
#   experiment-dir: the ~/orchestrator/<exp>/ dir to audit (read-only; the auditor sees its files)
#   out-file:       findings destination (default: <experiment-dir>/AUDIT.md, or DESIGN_AUDIT.md in --design mode)
#   design-file:    (--design mode) the proposal to audit; default = newest DESIGN*.md in the dir
# --design audits the PROPOSAL before any money/GPU moves (third gate alongside verify_claim
# pre-launch and the close audit): confounds & missing controls, comparability traps,
# pre-registration completeness, claim-scope, power, cheaper-decisive alternatives. Motivated by
# midtrain-interp v2, whose two real flaws (in-sample steering eval; no random-direction control)
# were DESIGN flaws only caught at close.
# Env: AAR_SUBSTRATE=claude|codex (family that ran the exp; default claude — set in instance config)
#      AUDIT_VERIFIER_CMD=...      (override the auditor; must be a DIFFERENT family than AAR_SUBSTRATE)
#      AUDIT_CONSTITUTION=path     (the standards file; default ~/AGENTS.md)
set -euo pipefail
MODE=close
if [ "${1:-}" = "--design" ]; then MODE=design; shift; fi
EXP=${1:?usage: audit_experiment.sh [--design] <experiment-dir> [args...]}
if [ "$MODE" = design ]; then
  DESIGN_FILE=${2:-$(ls -t "${EXP%/}"/DESIGN*.md 2>/dev/null | head -1)}
  [ -n "$DESIGN_FILE" ] && [ -f "$DESIGN_FILE" ] || { echo "BLOCKED: no design file found in $EXP (pass one explicitly)" >&2; exit 1; }
  OUT=${3:-${EXP%/}/DESIGN_AUDIT.md}
else
  OUT=${2:-${EXP%/}/AUDIT.md}
fi
[ -d "$EXP" ] || { echo "BLOCKED: experiment dir missing: $EXP" >&2; exit 1; }

# --- cross-family enforcement (FINDING 2) -------------------------------------------------------
# Infer the auditor's family from the verifier command (default = codex).
AUDITOR_FAMILY=codex
if [ -n "${AUDIT_VERIFIER_CMD:-}" ]; then
  case "$AUDIT_VERIFIER_CMD" in
    *claude*) AUDITOR_FAMILY=claude ;; *codex*) AUDITOR_FAMILY=codex ;; *) AUDITOR_FAMILY=custom ;;
  esac
fi
RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}
if [ "$AUDITOR_FAMILY" = "$RUNNER_FAMILY" ]; then
  echo "BLOCKED: cross-family audit required — auditor family ($AUDITOR_FAMILY) == experiment runner" >&2
  echo "  family ($RUNNER_FAMILY). Set AUDIT_VERIFIER_CMD to a DIFFERENT family (e.g. on a Codex AAR:" >&2
  echo "  AUDIT_VERIFIER_CMD='claude -p ...'), or correct AAR_SUBSTRATE if mis-set." >&2
  exit 1
fi

CONSTITUTION=${AUDIT_CONSTITUTION:-$HOME/AGENTS.md}
CONSTI_TEXT=""
[ -f "$CONSTITUTION" ] && CONSTI_TEXT=$(cat "$CONSTITUTION")

if [ "$MODE" = design ]; then
PROMPT="You are an INDEPENDENT ADVERSARIAL REVIEWER from a different model family than the agent that
wrote this experiment PROPOSAL. Nothing has been run yet; your job is to find the flaws BEFORE money
and GPU time move. The proposal under review is: $(basename "$DESIGN_FILE") (in the current directory).
Read it in full; read other files in the dir tree for context (prior RESULTS*.md, AUDIT.md, code)
— prior experiments' flaws often reveal what the new design must control for. IGNORE operational/state
files (LOOK_AGAIN.md, *.log, driver logs, CLAIMED_BY, .done markers): they describe the RUN's status, not
the design — never raise a finding from them (e.g. 'the run already launched' is not a design flaw).

Review against the program's constitution (below). The most load-bearing standards: validity and
comparability are the main failure mode ('are these two numbers even on the same scale?'); success
criteria and falsifiers must be pre-registered BEFORE the run; conclusions must be distinguishable
from postdictions by design; the silent failure mode is a clean pipeline producing a
confidently-wrong number.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. CONFOUNDS / MISSING CONTROLS — are the planned comparisons matched; are the baselines and
   negative controls (random/orthogonal/shuffled class, placebo arms) IN THE PLAN, not deferred?
2. VALIDITY / COMPARABILITY — will any two numbers being compared be on the same scale, same metric,
   same data distribution? Any train/eval leakage, probe contamination, or selection effect built
   into the construction?
3. PRE-REGISTRATION COMPLETENESS — are success criteria AND falsifiers stated with thresholds? Is
   every plausible outcome interpretable (no 'heads I win, tails ambiguous' designs)? Are
   hyperparameter/selection steps confined to fit data?
4. CLAIM-SCOPE — will the planned evidence actually license the claim the design says it is after
   (causal strength, generality, storage-vs-routing, in-sample-vs-held-out)? Quote the claim and the
   evidence that falls short.
5. POWER / SENSITIVITY — n, seeds, effect sizes: can the design distinguish its hypotheses at the
   planned sample sizes, or will results land inside the noise band?
6. EXECUTION UNDER-SPECIFICATION — steps a zero-context executor would have to guess (datasets,
   composition of checkpoints, prompt formats, thresholds), where a wrong guess silently changes
   the result.
7. CHEAPER / MORE DECISIVE ALTERNATIVE — is there a materially cheaper design answering the same
   question, or a small addition that turns a suggestive result into a decisive one?

PRIOR-ROUND DEBATE (when this is a RE-RUN on a revised proposal): if the proposal contains the author's
RESPONSES to earlier findings (e.g. a 'Design-audit responses' / pass-N section), this is a PEER DEBATE,
not a fresh scan. You and the author are two minds converging on the BIG, OBVIOUS design flaws —
confounds, missing controls, comparability traps that change what the result MEANS — NOT maximizing a
finding count. For each prior finding: CONCEDE the ones the response adequately resolves (do NOT
re-raise them); ESCALATE only when the response is wrong or insufficient (quote it, say why it still
fails); otherwise raise only GENUINELY NEW flaws. On a re-run, polish / wording / threshold-calibration
are NOT findings unless they change a conclusion. Reporting 'no new material finding' is a GOOD,
expected outcome once the big flaws are addressed — that is how the debate converges.

VERIFY DATA-BACKED ASSUMPTIONS: where the design leans on a property of the ACTUAL data (number of
classes/biases/strata, available n, label balance) and that data is accessible (a file in the dir, or
the cited HF/source you can inspect), CHECK it rather than trusting the prose — a design that assumes
many strata when the data has few is a power flaw the document alone won't reveal.

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
else
PROMPT="You are an INDEPENDENT ADVERSARIAL AUDITOR from a different model family than the agent that
ran this experiment. You are auditing a COMPLETED autonomous-research experiment before it is treated
as 'done'. Read any file in the current directory tree (grep/head as needed; some logs are large).

You audit the experiment AGAINST the research program's own constitution, included below. The most
load-bearing standards in it: a fresh agent must be able to reproduce the run and know its conclusion
FROM THIS DIR ALONE; conclusions (pre-registered) must be separated from postdictions (fitted after);
validity and comparability are the main failure mode; headline numbers must trace to durable,
versioned code in the experiment record, not ad-hoc steps.

Audit these dimensions. For each, try HARD to find a real problem; if there genuinely is none, say
'no material finding' for it — do NOT invent issues. False findings destroy this tool's value.
1. REPRODUCIBILITY — were the HEADLINE numeric artifacts produced by DURABLE, VERSIONED code present
   in the record (the scripts/drivers in the dir), or by something not in the records? Does that code
   regenerate them? Is there evidence of a clean rerun? (If git metadata is available, also check the
   code is committed; if not — e.g. a /tmp or R2 copy — judge durability/presence, not git status.)
2. CLAIM-vs-EVIDENCE — does each CONCLUSION follow from the data shown, or overreach the method
   (causal-strength, generality, storage-vs-correlation, in-sample-vs-general)?
3. CONFOUNDS / VALIDITY — comparisons matched, baselines present, alternative explanations and
   missing controls (e.g. random/orthogonal baselines) ruled out?
4. DATA SANITY — actually SAMPLE the raw generated/training/eval rows (not just the aggregate
   numbers): are labels right, any train/eval or prompt-template leakage, malformed/duplicated rows,
   generator artifacts, or descriptor/format confounds in how the data was constructed? This is the
   'crappy generated data / confounded probe' failure class — inspect the rows, don't trust the JSON.
5. CONCLUSIONS vs POSTDICTIONS — separated, postdictions flagged untested?
6. RECORDS SELF-SUFFICIENCY — could a fresh agent reproduce the headline results FROM THIS DIR ALONE
   (are the decisive artifacts/probes/logs present, not only referenced on remote storage)?
7. HONEST BOUNDS — are the real limitations (n, single model/organism, in-sample fits, selected
   sweeps) stated?

PRIOR-ROUND DEBATE (when this is a RE-RUN on a revised dir): if the dir contains the author's RESPONSES
to earlier findings (`RESPONSE:` lines, an audit-response section, a later AUDIT*.md), this is a PEER
DEBATE, not a fresh scan — converge on the BIG, OBVIOUS validity flaws (a confidently-wrong number, an
overclaim, an unreproducible headline), NOT a maximal finding count. CONCEDE findings the responses
adequately resolve (don't re-raise); ESCALATE only when a response is wrong/insufficient (quote it, say
why); otherwise raise only GENUINELY NEW flaws. Polish/wording are not findings on a re-run unless they
change a conclusion. 'No new material finding' is a GOOD, expected convergence outcome.

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
fi

# --- run, with stale-output guard (FINDING 1): write to a temp file, atomic-mv only on success ----
OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/audit.XXXXXX.md")"
VERIFIER_CMD=${AUDIT_VERIFIER_CMD:-"codex exec --sandbox read-only --skip-git-repo-check --cd \"$EXP\" -o \"$OUT_TMP\""}
echo "[audit_experiment] mode=$MODE exp=$EXP auditor=$AUDITOR_FAMILY runner=$RUNNER_FAMILY" >&2
if ! eval "$VERIFIER_CMD" <<< "$PROMPT" >"$OUT.run.log" 2>&1; then
  echo "BLOCKED: auditor run failed — last lines of $OUT.run.log:" >&2; tail -5 "$OUT.run.log" >&2
  rm -f "$OUT_TMP"; exit 1; fi
[ -s "$OUT_TMP" ] || { echo "BLOCKED: auditor produced no findings file (stale $OUT NOT reused)" >&2; rm -f "$OUT_TMP"; exit 1; }
mv "$OUT_TMP" "$OUT"
echo "[audit_experiment] findings -> $OUT" >&2
grep -E "^FINDING|^SUMMARY|^NO-FINDING" "$OUT" || true
