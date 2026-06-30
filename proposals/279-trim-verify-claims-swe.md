# Trim `--scaffold`/`--code` out of automated-researcher's verify-claims (#279)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

automated-researcher's verify-claims still carries the two SWE-review modes — `--scaffold` (review a
change proposal) and `--code` (review a diff) — but those belong to the engineering team, not the research
product. Phase 3 moved the engineering tooling (ship-change) into agentic-engineering; Phase 3b PR1
(agentic-engineering #7, merged) made ship-change resolve its `--scaffold`/`--code` reviewer **from
agentic-engineering itself**, regardless of which repo it is reviewing. So the product's own copy of those
modes is now dead weight: nothing calls it. Leaving it in keeps a second live copy of the SWE-review engine
inside the product — exactly the instance↔product / one-canonical-home boundary this whole phase exists to
fix.

## Approach

Trim `plugins/verify-claims/skills/verify-claims/scripts/audit_experiment.sh` down to the
experiment-audit modes only — `--design`, `--data`, close (default), plus the untouched `verify_claim.sh`
and `audit_data.py`. Concretely, remove the `--scaffold`/`--code` pieces: their mode-parse branches, the
scaffold/code input-handling block, the scaffold/code-only strict `AAR_SUBSTRATE` enforcement, the
scaffold/code constitution branch, and the two `--code` and `--scaffold` PROMPT blocks. Update `SKILL.md`
to drop the SWE-pipeline sections and stop advertising those modes, and bump the plugin version.

The load-bearing point: this is safe **only because PR1 already landed** — ship-change now sources the SWE
reviewer from agentic-engineering, so removing the product's copy leaves no orphaned caller.

## Alternatives considered

- **Keep verify-claims full (do nothing).** Rejected: leaves a duplicate SWE-review engine in the product —
  the boundary violation Phase 3 is closing — and a second copy that can silently drift from
  agentic-engineering's authoritative one.
- **Replace the modes with a stub pointing at agentic-engineering.** Rejected: over-engineered; the product
  has no caller to redirect, and a runtime cross-repo pointer is the kind of hidden instance fallback the
  review dimensions warn against.

## Blast radius

- **Callers:** only ship-change ever invoked `--scaffold`/`--code` (confirmed by grep across both repos),
  and after PR1 it sources them from agentic-engineering. experiment-lifecycle (design-experiment /
  run-experiment / log-experiment) uses only the kept modes. So no product caller loses anything.
- **Fail-closed on a stray flag:** after the trim, `audit_experiment.sh --scaffold <f>` leaves `MODE=close`
  with `EXP=--scaffold`, which the existing `[ -d "$EXP" ]` guard rejects (`BLOCKED: context/experiment dir
  missing`). It does not silently run close-mode on a wrong target.
- **Reviewer for THIS PR:** ship-change reviews this change using **agentic-engineering's** verify-claims
  (PR1), so trimming the product's copy does not break the PR's own `--scaffold`/`--code` review — the live
  proof that PR1 works.
- **Unchanged:** `verify_claim.sh`, `audit_data.py`, and agentic-engineering's verify-claims (the SWE
  reviewer, which keeps all modes).

## Rollout + rollback

PR1 already landed, so the reviewer-source is in place. Merge this; verify-claims is then
experiment-audit-only in the product. Reversible by a plain revert (re-adds the modes). No data/runtime
migration; experiments are unaffected.
