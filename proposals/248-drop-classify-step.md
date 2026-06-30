# 248 — drop the classify step + the per-PR design-approval expectation

## Problem

ship-change's `classify` step records mechanical-vs-architectural (advisory), and the skill / AGENTS frame architectural changes as where "the PM's design approval belongs (recorded, advisory)." In practice this is ceremony without value: the real merge gate is the cross-family `--scaffold`/`--code` review (HIGH=0) + checks, which the author triages as a peer. The classification label plus a separate per-architectural-change *personal* approval add noise and never change what merges — the human does not approve each architectural change. The framing also implies a per-PR human gate that doesn't match the disposition model (the human shapes `needs-shaping → ready` tickets, agents execute autonomously).

## Approach

Remove the classifier entirely; architectural and mechanical changes go through the **same** gate (cross-family review + checks, author-triaged).

- Remove the `wf.sh classify` subcommand + the `classification_summary_text` helper + its doc/usage/code-review-hint references.
- Remove `.aar-ci/classify.sh` + `.aar-ci/classifier.conf`. `checks.sh` never invoked them, so the merge gate is unaffected.
- Drop the "architectural → PM design approval" framing from ship-change `SKILL.md`, `RUNBOOK.md`, and `automated-researcher/AGENTS.md`. Reframe: the human gates *which* architectural work happens (the Issue + the `needs-shaping → ready` shaping conversation), **not each PR's merge**; the cross-family review gates the change itself.
- KEEP the cross-family `--scaffold` (design) and `--code` reviews, the `.aar-ci` checks + fake-HOME behavior smoke, and the HIGH=0 merge bar. The gate is exactly as strong.

The instance constitution `~/AGENTS.md` carries the same "human gates the architectural design" line; it lives in the home repo (not automated-researcher), so it is reconciled by a **direct path-scoped commit**, separate from this PR.

## Alternatives considered

- **Keep classify as info-only, drop just the approval expectation** — rejected: the ask is to remove both the classification *and* the personal approval; the label adds noise no one acts on.
- **Wire classify to a blocking `design-gate`** — rejected: the opposite of the ask; the cross-family review already is the gate.

## Blast radius

ship-change docs + driver + the `.aar-ci` profile. **No change to the merge gate's strength** — cross-family review + checks stay. The lifecycle without classify is `start → open → design-review → implement → code-review → finish` (classify was advisory/optional; `finish` and `checks.sh` never required it). The unrelated `classify` mentions in wf.sh / gh-guard.sh / the read-only-credential logic are untouched. Reversible (revert the PR). **Scope: the ENGINEERING side only** — the research design-gate (design-experiment, clearing experiments before GPU spend) is deliberately untouched.

## Rollout + rollback

Ship via ship-change. The reconciling `~/AGENTS.md` edit (instance) is committed directly to the home repo. Rollback: revert the PR (and the `~/AGENTS.md` commit).
