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
