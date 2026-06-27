# Proposal: attribute auto-posted review/classification to the reviewer identity (#16)

> Design PM-cleared (you flagged the misattribution directly). Shipped with a `--code` review. Lands on main.

## Problem

Only the `--code` review posts as the reviewer identity (`codex-engineer[bot]`). The `--scaffold` design
review and the classifier note still post via the driver's default token — which is the **author's** account.
So Codex's *design* review shows up on the PR as if the human wrote it. That's misleading: anything the
workflow auto-generates should read as the agent that produced it, and only the human's *manual* actions
should read as the human.

## Approach

Route the non-`--code` auto-posts through the reviewer identity too, as **comments** (not approvals — the
design gate stays the human's; classification is mechanical workflow output, neither an approval):

- `--scaffold` design review: post the comment as the reviewer identity (`codex-engineer[bot]`) when one is
  configured and the change is `author=claude`; fall back to the default token otherwise (shadow).
- `classify`: same — the classification comment posts under the reviewer identity, falling back to default.
- `--code` is unchanged (native review via the reviewer identity).

Mechanism: reuse the existing `WF_REVIEWER_TOKEN_CMD` seam (a fresh reviewer token). A small helper posts a
PR comment under the reviewer token when available, else the default token — used by both the `--scaffold`
comment path in `run_review` and the `classify` subcommand.

Net: everything the workflow auto-posts (design review, code review, classification) reads as the bot; only
the human's manual `gh`/UI actions read as the human.

## Alternatives considered

- **Leave it** — rejected: it's the misleading thing you flagged; the whole point of a separate reviewer
  identity is that its output reads as *it*, not as you.
- **Post `--scaffold` as a native review too** — rejected: a `--scaffold` review isn't the merge gate (the
  design/architectural gate is the human's), so it should be a comment, not an Approve/Request-changes that
  could entangle with branch protection.

## Blast radius

`scripts/wf.sh` (the comment-posting paths in `run_review` + `classify`) + `plugin.json` version. No change
to the `--code` native-review path, the gate logic, or branch protection. Backward-compatible: with no
reviewer identity configured, everything still posts under the default token (current behavior).

## Rollout + rollback

Land it; subsequent `--scaffold`/`classify` posts read as `codex-engineer[bot]`. Rollback: revert the one
commit. One squash commit; an early change through the fully-enforced pipeline end to end.
