# Proposal: Fix the stale "told to find the next thing" phrase in ship-change triage (#221)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

PR #217 calibrated the `--code`/`--scaffold` reviewer — it removed the *"try HARD to find a real
problem"* push. But the ship-change triage guidance still describes the old behavior:

> SKILL.md:177 — *"The cross-family reviewer is **told** to find the next thing, so it won't
> self-converge…"*

That premise is no longer true, so the doc misrepresents the reviewer to anyone reading the triage
section. This is the deferred LOW finding from PR #218's code review.

## Approach

One-line wording fix. Replace the stale premise while keeping the operative advice intact:

> *"The cross-family reviewer is adversarial and fresh each round, so it may surface a new angle —
> don't chase it past HIGH=0 into endless polish; the merge bar is HIGH=0 + checks green."*

The reviewer is still adversarial and zero-context per round (so "don't chase past HIGH=0" still
holds); it just no longer *manufactures* the next finding. `aar-engineering` patch-bumped 0.3.33 →
0.3.34.

## Alternatives considered

- **Leave it** — rejected: an inaccurate description of the gate behavior is exactly the kind of stale
  contract reviews are supposed to catch (and one did).
- **Rewrite the whole triage section** — unnecessary; only the one premise went stale.
- **Also touch the design-experiment "told to find the next thing" line** — no: that refers to the
  *experiment* auditor, which #217 did not change and which still pushes for findings.

## Blast radius

Doc-only (one line in ship-change SKILL.md) + a patch version bump. No behavior change, no script
change.

## Rollout + rollback

Trivial and reversible — revert the line + the bump.
