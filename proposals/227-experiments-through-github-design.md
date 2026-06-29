# Proposal: Experiments through GitHub — the design side (#227)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

An experiment's design, its audits, and its data-location live in **invisible local files** — the researcher has to
ask an agent what ran. #130 ("experiments through GitHub") makes every experiment a **PR** so GitHub is the browsable
index. This is the **design half** (#227): get a cleared, audited experiment *design* onto a PR. The execution half is
#228.

## Approach

An experiment design = a **PR in research-lab**, and the **`--design` audit is the merge gate** — a *real* cross-family
approving review (one family's engineer bot authors, the OPPOSITE family's bot reviews + APPROVEs), not an advisory
comment. The researcher arbitrates findings; a confound they **accept with a reason** is an honored disposition that
clears it (the same disposition-aware re-review the engineering merge gate uses) → the adversarial audit **converges**
instead of spiralling into endless ablations → the bot APPROVEs → the **agent merges**. The researcher never manually
merges; research-lab's require-approval protection is satisfied by the cross-family APPROVE (nothing relaxed).

**Reuse over rebuild.** `wf.sh` is already factored into the needed plumbing (`run_review` posts a native cross-family
review from an audit's `SUMMARY`; identity/push/merge helpers; repo derived from the worktree). So:
- **Source-guard `wf.sh`** (wrap the bottom CLI dispatch in `[ "${BASH_SOURCE[0]}" = "$0" ]`) so it doubles as a
  sourceable **function library**. No behavior change when run directly; the smokes still pass.
- **Extend `run_review`** so its native-review + disposition-aware blocks also accept the `--design` audit mode (post
  native APPROVE/REQUEST_CHANGES, honor `DISPOSITION_FILE`, `pk=design` marker). `audit_experiment.sh` is **unchanged**.
- **Thin driver** `experiment-lifecycle/.../design-experiment/scripts/exp_pr.sh` (sources `wf.sh`), two verbs:
  `open-design` (research-lab worktree + commit DESIGN/START/CHECKLIST + draft PR) and `design-gate` (`run_review
  --design`, `approving=1` → merge on HIGH=0). It uses **none** of the engineering machinery (classifier, `.aar-ci` code
  checks, version-bump-of-target, `--code`, the issue close-gate).
- **Wire `design-experiment` Step 2** so the design-audit *is* this PR gate; the merged design PR is the cleared-design
  record handed to the Step-4 executor.

**Stable experiment id** = `basename(exp-dir)`: it names the branch (`exp/<id>`) and PR, and is the shared key for the
ledger run + R2 prefix (so design PR / execution PR / dir / ledger / R2 all line up).

## Alternatives considered

- **Extract a shared `gh_lifecycle.sh` lib** both `wf.sh` and the driver source — cleaner seam, but moves ~30 functions.
  Deferred: the one-line source-guard gets the same reuse with near-zero churn; promote later if sourcing proves awkward.
- **Advisory audit comments + the human merges** — rejected (earlier framing): if the review is worth doing the approval
  is worth gating on; and the cross-family bot (which we already have) can be the approver, so there's no need to make
  the human a manual GitHub approver or to weaken research-lab's protection.
- **A new executor GitHub App** — not needed; the two existing engineer bots (one authors, the other reviews) cover it.

## Blast radius

- **aar-engineering** (`wf.sh`): a source-guard + a `run_review` mode extension. **No behavior change to the ship-change
  flow** (verified: source-guard preserves direct dispatch; smokes pass).
- **experiment-lifecycle**: a new `exp_pr.sh` (design verbs only) + `design-experiment` SKILL prose.
- **research-lab**: no change — it keeps its require-approval branch protection, satisfied by the cross-family APPROVE.
- Both plugins patch-bumped (aar-engineering 0.3.36→0.3.37, experiment-lifecycle 0.3.6→0.3.7).

## Rollout + rollback

Additive; reversible by reverting the PR. **Prerequisite / risk:** the two engineer GitHub Apps must be **installed on
research-lab** for the cross-family author/review/merge to work there — this is *unverified* (App tokens report
`.permissions` as all-false even where they work, so confirm via App settings or a live authoring test before relying on
the flow). The first real `open-design`/`design-gate` run is the integration test; do it on a throwaway experiment.

**Deferred to #228 (execution side):** the execution PR, the `close`-audit gate (needs the same `run_review` extension
**plus** a CLI-signature adapter — the close audit takes `<exp> [out]`, not `<mode> <target> …`), the design→execution
link by exp id, and the mid-run `--data` audit posted as a PR comment.
