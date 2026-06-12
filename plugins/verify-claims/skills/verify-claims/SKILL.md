---
name: verify-claims
description: Adversarially fact-check load-bearing claims against primary records using an independent model (read-only). Use BEFORE acting on claims that would redefine success/failure if wrong — "X is the baseline", "the original numbers are in file Y", "no checkpoint survives", a methods section's lineage claims — or when the user says "verify these claims", "fact-check this against the records", "is this brief right". Catches the confidently-wrong-number failure mode before money or conclusions move.
---

# verify-claims — don't check your own claims

An agent cannot reliably catch its own wrong claims: whoever wrote a claim believes it, and
whoever received it was told it's true. This skill routes claims to a FRESH adversarial verifier that sees ONLY the primary records —
a different model family when your main agent isn't Codex (the default verifier). If your main
agent IS Codex, set VERIFIER_CMD to a different-family CLI for family independence; a fresh
zero-context instance still gives you context independence either way.

## When to invoke

- Before spending money or drawing conclusions that depend on factual claims about artifacts:
  identity of a baseline, location of original results, existence/provenance of a checkpoint,
  lineage of a derived model.
- On pre-registration documents and their amendments.
- On your own draft writeups: do the methods-section claims survive contact with the records?
  (Every UNKNOWN = a detail your readers won't be able to verify either.)

## How

1. Write the claims as a numbered list in a file — one atomic, record-checkable claim per line.
   Don't editorialize; state each claim exactly as strongly as it's being relied upon.
2. Collect the primary records into one directory (copies/symlinks fine). The verifier sees
   ONLY this directory — if the claim needs evidence that isn't there, that's a finding.
3. Run: `scripts/verify_claim.sh <claims-file> <evidence-dir>`
4. Read the verdict file it writes:
   - **DISPUTE** → stop; resolve before proceeding (the verifier cites the contradicting line).
   - **UNKNOWN** → the records are too thin to support the claim; treat as a record gap.
   - **CONFIRM** → proceed; the citation is your receipt.

## Requirements / configuration

- Default verifier: OpenAI Codex CLI (`codex` on PATH, authed). Runs `--sandbox read-only`
  (mechanically cannot write; needs unprivileged userns for bubblewrap — see script header).
- Any other CLI model runner: set `VERIFIER_CMD` (receives the prompt on stdin, cwd = evidence
  dir, writes its final answer to the out-file).
- Calibration provenance: see `references/CALIBRATION.md` — replayed three real research-ops
  incidents as planted errors; 3/3 caught with correct citations, 0 false disputes on 7 controls.


## Audit mode — the output-side gate (`audit_experiment.sh`)

The sibling script audits a *finished experiment* rather than checking a given claim list. Where
`verify_claim.sh` is the INPUT gate (pre-launch: are the brief's load-bearing claims supported?),
`audit_experiment.sh` is the OUTPUT gate (at close: does the finished work meet the AAR's own
standards?). Same principle — a foreign model family reads the records you're too invested to judge.

```
scripts/audit_experiment.sh ~/orchestrator/<exp>          # -> <exp>/AUDIT.md
```

It hands the auditor the experiment dir + the AAR constitution (`~/AGENTS.md`) and a six-dimension
rubric — reproducibility (did committed code make the headline numbers?), claim-vs-evidence
(overreach?), confounds/validity (matched comparisons, missing controls?), conclusions-vs-postdictions,
records self-sufficiency (reproducible *from this dir alone*?), honest bounds. Output: severity-rated
FINDINGs with record citations, plus the dimensions where it found nothing material. "No material
finding" is allowed and common — it does not cry wolf (same calibration discipline as the claim
checker; validated 2026-06-12 catching a repro gap + in-sample steering + overclaim from a cold read,
zero false findings).

**Cross-family selection.** Default verifier = Codex (read-only). On a Codex AAR, set
`AUDIT_VERIFIER_CMD='claude -p …'` so the auditor is always the OTHER family from whoever ran the work.

**This is wired into the run-experiment close** — run it before clearing the self-wake and respond
to every finding (fix, or a one-line `RESPONSE:` accepting/deferring with a reason). HIGH findings
get fixed or explicitly justified.
