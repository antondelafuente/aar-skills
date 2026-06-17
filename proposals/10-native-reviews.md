# Proposal: native GitHub reviews instead of comments (#10)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The cross-family code review posts its verdict as a **PR comment**. That gives a durable record but it is
NOT a native GitHub review, so it can't carry an `Approve` / `Request changes` state and can't satisfy a
branch-protection "require 1 approval" rule. Without a real approval, "no change merges until the reviewer
approves" stays convention, not enforcement. This is the code half of Phase 2 (the identity + branch
protection are the operator half, in RUNBOOK.md).

The blocker for a native approval is identity: GitHub forbids approving your own PR, and today the author and
the reviewer run under the same token. So native review needs a SECOND, distinct reviewer identity.

## Approach

Add a **reviewer-identity seam**, `WF_REVIEWER_GH_TOKEN` (a token for a different account/App than the
author's `GH_TOKEN`), and make the `--code` review post a native review through it:

- **`--code` review** (the merge-gating one): if `WF_REVIEWER_GH_TOKEN` is set, post a native review as that
  identity — `gh pr review --approve` when the cross-family verdict is clean (`HIGH=0`), `--request-changes`
  when there are blocking findings (`HIGH>0`) — with the full findings as the review BODY (the detail stays).
  If no reviewer token is set, fall back to the current PR **comment** (backward-compatible / shadow mode).
- **`--scaffold` design review and `classify`** stay as posted comments — they're the design dialogue and the
  shadow-mode record, not the branch-protection gate. (The architectural/design gate is the human's, carried
  separately; this PR is only about the cross-family CODE approval.)
- **Self-approval guard:** before approving, resolve the reviewer token's login and the author's login; if
  they're the same account, FAIL CLOSED (an identity can't approve its own PR — better a loud block than a
  silent fallback that looks enforced but isn't).
- The merge bar is unchanged (`HIGH=0`), so an `Approve` means exactly what the existing gate means. `finish`
  already re-runs `--code` on the final synced SHA, so the approval lands on the SHA that merges; pairing this
  with branch-protection "dismiss stale approvals on new commits" keeps an approval bound to its reviewed SHA.

No behavior change when `WF_REVIEWER_GH_TOKEN` is unset — every current invocation keeps posting comments.

## Alternatives considered

- **Keep comments only** — rejected: can't satisfy branch protection, so enforcement is impossible; the whole
  point of Phase 2 is a real, required approval.
- **One identity, "approve via the API anyway"** — impossible: GitHub blocks self-approval by design. A
  distinct reviewer identity is mandatory, not a nicety.
- **GitHub App now vs machine-user PAT** — orthogonal to this code: both reduce to "a token for a different
  identity" that this seam consumes. The identity mechanism is an operator choice (RUNBOOK), not a code one.

## Blast radius

The SWE pipeline only. Touches `scripts/wf.sh` (the posting path + the seam), `.claude-plugin/plugin.json`
(version bump), and docs (SKILL.md notes the seam; RUNBOOK.md gets the activation steps). No change to the
research product or the instance. With the seam unset, zero behavior change — so it's safe to land before the
reviewer identity exists.

## Rollout + rollback

Staged, matching RUNBOOK: (1) land this code (comments still, seam unset); (2) operator creates the reviewer
identity + sets `WF_REVIEWER_GH_TOKEN`; (3) test a throwaway change → confirm a native `Approve` posts;
(4) only then turn on branch protection (require 1 approval + dismiss-stale-approvals). Rollback is trivial:
unset `WF_REVIEWER_GH_TOKEN` (reverts to comments) and/or remove branch protection (back to shadow mode). One
squash commit; revertible.
