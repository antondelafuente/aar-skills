# Proposal: Calibrate the ship-change reviewer — drop the "find a problem" push, add scale (#217)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The cross-family SWE-pipeline reviewers (`audit_experiment.sh` `--code` and `--scaffold`) open with:

> "Audit these dimensions. For each, **try HARD to find a real problem** …"

— and carry **no scale context**. Two consequences, both observed:

1. **The instruction manufactures findings.** Telling a capable reviewer to "try HARD to find a real problem" in *every* dimension pushes it to surface something each time, which inflates MED/LOW noise and, on re-review, ratchets toward more machinery (the reviewer only ever adds).
2. **No scale → public-product standards.** With nothing telling it the consumer is ~10 cooperative, capable agents, the reviewer applies the robustness/edge-case bar of a public product with many adversarial users — flagging recoverable edge cases and absent hardening as blockers. That is a primary driver of the over-engineering this pipeline has been accreting.

## Approach

A **minimal, two-line calibration** — no structural change. In both the `--code` and `--scaffold` prompt blocks, replace the opener:

- **Remove** the "try HARD to find a real problem" push.
- **Add** one scale sentence: *"You are reviewing a product used by ~10 agents."*

Result (both blocks):

> "**You are reviewing a product used by ~10 agents.** Audit these dimensions. For each, if there's a real problem, say so; if there genuinely is none, say 'no material finding' — do NOT invent issues. False findings destroy this tool's value."

The dimensions, the `FINDING <n>: <HIGH|MED|LOW>` format, and the `SUMMARY: high=/med=/low=` line the merge gate parses are **unchanged**. The bet: a capable model given the scale and *not* told to hunt will calibrate appropriately on its own — so we add the context and remove the push rather than piling on instructions (which itself would be the over-engineering we're fixing). How it actually performs is then observed on real reviews from here forward.

## Alternatives considered

- **A heavily-specified disposition** (threat-model framing, explicit "demote rare edge cases", "don't nitpick", "looks-good is a fine answer"). Drafted and rejected: it over-specifies what a capable model infers from the scale line alone, and a longer-prompt variant tested *worse* (it over-blocked a simple change). Less is more here.
- **Restructuring into one less-formal "second opinion" pass / dropping HIGH/MED/LOW.** A real simplification, but a *pipeline* change (it rewires the two review steps and the gate). Deferred — do it deliberately later, informed by how the calibrated reviews go, not bundled into a prompt tweak.

## Blast radius

SWE pipeline only. Touches the `--code` and `--scaffold` review prompts in `audit_experiment.sh` (one copy; no byte-identical duplicate). **Out of scope, deliberately unchanged:** the experiment-audit prompts (`--design`, `--data`, close) keep their wording — they review research validity, a different concern with its own audit-once-then-human-triage convergence. `verify-claims` patch-bumped 0.7.4 → 0.7.5.

## Rollout + rollback

Lands on main; effective on the next plugin pull. Fully reversible — revert the two prompt lines + the version bump. No data migration, no consumer contract change (output format identical).
