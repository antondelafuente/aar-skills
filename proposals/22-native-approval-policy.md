# Proposal: make native approval block on MED findings (#22)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` currently maps the final native `--code` review to GitHub approval whenever `high=0`. That means
`SUMMARY: high=0 med=1 low=0` can still post `APPROVE`, satisfying branch protection even though the reviewer
found a material MED issue.

That makes the GitHub approval signal too weak: it means "no HIGH findings", not "the reviewed head is ready to
merge without unresolved material findings."

## Approach

Change the deterministic native-review event mapping for `--code`:

- Any HIGH or MED finding -> `REQUEST_CHANGES`.
- Zero HIGH and zero MED -> `APPROVE` on the final `finish` review.
- LOW findings alone remain approvable. They are advisory and can be triaged without blocking merge.
- Interim `code-review` calls still avoid approving clean diffs before checks/final review; clean interim reviews
  stay `COMMENT`.

Keep the workflow simple: MED findings are resolved by fixing, disputing/defering on the PR, and rerunning the
review until the final review has no MED. We are not adding a parser for author triage comments in this change.

## Alternatives considered

- **Keep HIGH-only approval.** Rejected: this is the issue. MED usually means a substantive correctness,
  regression, or edge-case concern, so a native approval should not certify it as ready.
- **Block LOW too.** Rejected: LOW is explicitly non-material; making it block would push the workflow toward
  endless polish instead of safety.
- **Parse author triage comments and allow MED after `DISPUTE` / `DEFER`.** Rejected for now: useful later, but
  brittle and more ceremony than needed. Rerunning the cross-family review after a fix/response is enough for
  this small policy change.

## Blast radius

SWE pipeline only:

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh` event mapping and merge-gate check.
- `plugins/aar-engineering/skills/ship-change/SKILL.md` and `RUNBOOK.md` policy text.
- `plugins/aar-engineering/.claude-plugin/plugin.json` version bump.
- `CHANGELOG.md` entry for `aar-engineering`.

## Rollout + rollback

Roll out through `ship-change` itself. The expected behavior is visible on future PRs: a final `--code` review
with any MED posts `REQUEST_CHANGES`, so branch protection will not accept it as the required approval.

Rollback is a normal revert through `ship-change` if this proves too strict.
