#!/bin/bash
# verify_claim.sh — adversarial verification of load-bearing claims by an INDEPENDENT model.
#
# Why: the most dangerous failure of agent-run research isn't a crash — it's a clean pipeline
# producing a confidently-wrong number because a load-bearing claim (the baseline's identity,
# which file holds the original results, whether an artifact exists) was wrong. An agent cannot
# reliably catch its own wrong claims; a reader from a DIFFERENT model family with access to
# only the primary records can. Calibrated on three real incidents: 3/3 caught, 0 false alarms.
#
# Usage: verify_claim.sh <claims-file> <evidence-dir> [out-file]
#   claims-file:  numbered claims (markdown); keep each claim atomic and record-checkable
#   evidence-dir: directory of primary records (the verifier sees ONLY this)
#   out-file:     verdict destination (default: <claims-file>.verdict.md)
# Verdicts: per-claim CONFIRM / DISPUTE / UNKNOWN with file citations. Treat DISPUTE as a
# blocker and UNKNOWN as "your records are too thin to support this claim".
#
# Verifier: OpenAI Codex CLI by default (`codex exec --sandbox read-only` — mechanically unable
# to write; needs unprivileged user namespaces for bubblewrap. If bwrap errors on your kernel,
# either enable userns or override VERIFIER_CMD). Any CLI model runner works via VERIFIER_CMD —
# it receives the prompt on stdin, must run with cwd=$EVIDENCE, and write its final answer to $OUT.
set -euo pipefail
CLAIMS=${1:?usage: verify_claim.sh <claims-file> <evidence-dir> [out-file]}
EVIDENCE=${2:?need evidence dir}
OUT=${3:-${CLAIMS}.verdict.md}
[ -s "$CLAIMS" ] || { echo "BLOCKED: claims file missing/empty: $CLAIMS" >&2; exit 1; }
[ -d "$EVIDENCE" ] || { echo "BLOCKED: evidence dir missing: $EVIDENCE" >&2; exit 1; }

PROMPT="You are an ADVERSARIAL VERIFIER. Below are numbered claims about a past experiment.
Your job is to try to REFUTE each claim using ONLY the files in the current directory (the
primary records). Read whatever files you need (grep/head as needed; some logs are large).

Rules:
- Use ONLY these records. No outside knowledge about what 'should' be true, no guessing.
- For EVERY claim give exactly one verdict:
  CONFIRM  — the records affirmatively support it (cite the decisive file + quote the line)
  DISPUTE  — the records contradict it (cite the decisive file + quote the contradicting line)
  UNKNOWN  — these records cannot settle it (state precisely what evidence is missing)
- UNKNOWN is a respectable answer. Do NOT stretch to CONFIRM: a claim that is merely
  consistent with the records but not evidenced by them is UNKNOWN, not CONFIRM.
- A claim is DISPUTED if any part of it is contradicted, even if other parts hold.

Output format (exactly):
CLAIM <n>: <CONFIRM|DISPUTE|UNKNOWN>
  evidence: <file>: \"<short quote>\"
  reasoning: <1-2 sentences>
...
SUMMARY: confirm=<n> dispute=<n> unknown=<n>

THE CLAIMS:
$(cat "$CLAIMS")"

# stale-output guard: write to a temp file, atomic-mv only on success — never reuse a prior $OUT.
OUT_TMP="$(mktemp "${TMPDIR:-/tmp}/verify.XXXXXX.md")"
VERIFIER_CMD=${VERIFIER_CMD:-"codex exec --sandbox read-only --skip-git-repo-check --cd \"$EVIDENCE\" -o \"$OUT_TMP\""}
echo "[verify_claim] evidence=$EVIDENCE claims=$CLAIMS" >&2
if ! eval "$VERIFIER_CMD" <<< "$PROMPT" >"$OUT.run.log" 2>&1; then
  echo "BLOCKED: verifier run failed — last lines of $OUT.run.log:" >&2
  tail -5 "$OUT.run.log" >&2; rm -f "$OUT_TMP"; exit 1; fi
[ -s "$OUT_TMP" ] || { echo "BLOCKED: verifier produced no verdict (stale $OUT NOT reused)" >&2; rm -f "$OUT_TMP"; exit 1; }
mv "$OUT_TMP" "$OUT"
echo "[verify_claim] verdict -> $OUT" >&2
grep -E "^CLAIM|^SUMMARY" "$OUT" || true
