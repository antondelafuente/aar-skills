# Proposal: Make ship-change PRs and bot comments easy to skim (#63)

> Internal design record. GitHub should show a shorter reader view.

## PR summary

This PR makes the GitHub trail easier to read. A person opening a ship-change PR should see the outcome and the
needed action before any audit transcript or workflow detail.

The full audit record stays available for agents, but dense details move under collapsible sections.

## Problem

`ship-change` already gives PRs good titles, but its generated bodies and comments are still too dense. The PR body
copies most of the design document into GitHub. Review comments put the raw audit transcript first. Classification
comments expose glob-matching evidence before the human reader knows what it means.

Anton wants the GitHub page to read like a concise handoff: what changed, why it matters, and whether anything needs
attention.

## Approach

Add a reader-facing layer to the workflow output.

- PR bodies should render a short `## PR summary` section when the proposal has one. If a proposal does not have that
  section, the workflow falls back to a compact excerpt instead of dumping the whole design document.
- Review comments should start with a plain-language result: no problems, minor notes, moderate issues to fix/respond
  to, or serious issues blocking progress.
- Full review output remains in a collapsible details block so agents keep the exact audit record.
- Classification comments should say what the classification means in one sentence and hide the raw classifier evidence
  behind details.
- Author triage comments should get a simple wrapper that makes the first paragraph the visible summary and places the
  full response under details.

## Alternatives considered

- Change reviewer prompts to produce friendlier prose. Rejected as the only fix because the workflow should protect the
  GitHub surface even when a reviewer returns dense output.
- Delete the dense evidence from GitHub. Rejected because the PR is the durable audit trail between agents.
- Keep the current PR body and only fix comments. Rejected because Anton explicitly called out PR bodies too.

## Blast radius

This touches `aar-engineering`'s `ship-change` workflow and documentation. It changes GitHub presentation only; it does
not change the review gate, merge rule, branch protection behavior, token identity logic, or classifier decision.

## Rollout + rollback

Roll out through this PR. The visible proof is this PR's own body and comments: they should be easier to skim.

Rollback is reverting the `ship-change` formatting helpers. Since the raw audit text still exists inside details blocks,
the main risk is presentation, not lost evidence.
