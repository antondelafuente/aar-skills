# Proposal: Relocate the review-eval harness into automated-researcher (#219)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The review-prompt eval harness (a golden-labeled corpus of PR cases + `run-eval.sh`) was built in
`research-lab/registry/review-eval` — i.e. the **experiment registry**. That's the wrong layer: it is
engineering tooling for the ship-change reviewer (the aar-engineering / SWE-pipeline layer), not an
experiment. Tooling living in the experiment registry is the same layer-blur that makes the tree hard
to reason about.

## Approach

Move it into automated-researcher under a new top-level **`tooling/review-eval/`**:

- `tooling/` (non-plugin) signals "engineering tooling, not shipped product" and avoids coupling the
  harness to any plugin's version (a change under `plugins/verify-claims/` would force a verify-claims
  version bump on every corpus edit).
- Cleaned in the move: dropped the transient run-subset files (`cases-new.tsv`, `cases-guard.tsv`);
  kept the master corpus (`cases.tsv`), the runner, both prompts (`prompt-v1` = the shipped-spirit
  calibration; `prompt-v2` = a documented negative result), and `syn/`. Added a `README.md`.

The harness is instance-coupled (it sources the box's engineer-auth env and calls `codex` locally).
That is acceptable at the engineering-tooling layer — the same reason "~10 agents" is fine in the
reviewer prompt (#217): this layer is the team's own tooling, not the instance-neutral product.

## Alternatives considered

- **`plugins/verify-claims/.../eval/`** (next to the prompt it tests) — rejected: couples the tool to
  the plugin's version and treats a dev tool as plugin content.
- **`plugins/aar-engineering/...`** — plausible (it's ship-change tooling), but the harness exercises
  the verify-claims reviewer specifically, and a neutral top-level `tooling/` avoids picking one plugin
  over the other.
- **Leave it in research-lab** — rejected: that's the layer-blur this fixes.

## Blast radius

Additive. Introduces one new top-level dir (`tooling/`); no plugin/product behavior changes, no
version bumps. The `.aar-ci` checks see a new bash + tsv (syntax-checked); nothing depends on it. The
source copy in `research-lab/registry/review-eval` is removed in the same change (it was untracked
there).

## Rollout + rollback

Additive and fully reversible — delete `tooling/review-eval/`. No consumers, no migration.
