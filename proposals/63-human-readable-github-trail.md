# Proposal: Make ship-change PRs and bot comments easy to skim (#63)

> Internal design record. GitHub should show a shorter reader view.

## Problem

`ship-change` already gives PRs good titles, but its generated bodies and comments are still too dense. The PR body
copies most of the design document into GitHub. Review comments put the raw audit transcript first. Classification
comments expose glob-matching evidence before the human reader knows what it means.

Anton wants the GitHub page to read like a concise handoff: what changed, why it matters, and whether anything needs
attention.

## Approach

Add a reader-facing layer to the workflow output, without adding a second authored summary to the proposal.

- PR bodies should show the first paragraph of `## Problem` and the first paragraph of `## Approach`, then put the full
  design record under a collapsible section. This keeps the old zero-duplicate-authoring rule from #24: authors still
  write one design doc, and the PR body is a view of it.
- Review comments should start with a plain-language result: no problems, minor notes, moderate issues to fix/respond
  to, or serious issues blocking progress.
- Full review output remains in a collapsible details block so agents keep the exact audit record.
- Classification comments should say what the classification means in one sentence and hide the raw classifier evidence
  behind details.
- Author triage comments should post exactly what the author writes, because the accept/defer decisions are closure
  evidence. The skill docs should tell authors to start with a plain-language outcome and use their own details block
  for long evidence.

Use shared formatting helpers in `wf.sh` so PR bodies, reviews, and classification comments do not grow three separate
Markdown implementations.

## Alternatives considered

- Change reviewer prompts to produce friendlier prose. Rejected as the only fix because the workflow should protect the
  GitHub surface even when a reviewer returns dense output.
- Delete the dense evidence from GitHub. Rejected because the PR is the durable audit trail between agents.
- Keep the current PR body and only fix comments. Rejected because Anton explicitly called out PR bodies too.

## Blast radius

This touches `aar-engineering`'s `ship-change` workflow and documentation. It also updates the `start` skeleton only if
needed for comments around the existing sections, not to introduce a new required section.

It changes GitHub presentation only; it does not change the review gate, merge rule, branch protection behavior, token
identity logic, or classifier decision.

It drops the unused `WF_ENGINEER_LABEL_CLAUDE` / `WF_ENGINEER_LABEL_CODEX` text-label seam from the current runbook and
driver because PR bodies no longer spell out the author/reviewer lifecycle line. Proposal #20 still mentions those names
as historical design context, not current configuration.

## Rollout + rollback

Roll out through this PR. The visible proof is this PR's own body and comments: they should be easier to skim.

Rollback is reverting the `ship-change` formatting helpers. Since the raw audit text still exists inside details blocks,
the main risk is presentation, not lost evidence.
