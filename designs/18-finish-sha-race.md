# Proposal: race-free SHA verification in finish (#18)

> Design PM-cleared (a known recurring friction). Shipped with a `--code` review. Lands on main.

## Problem

`finish` pushes the worktree HEAD, then confirms the pushed state by reading the PR head SHA via
`gh pr view --json headRefOid`. That value **lags** GitHub's PR-head association after a push — so a
just-pushed commit intermittently reads as a mismatch and `finish` blocks on a phantom "head != local HEAD"
error. Harmless (a re-run succeeds once GitHub catches up) but it has bitten three merges (#15, #13, #17) and
is the one real friction in the loop.

## Approach

Compare local HEAD against the remote **branch ref** via `git ls-remote origin <branch>` instead of the PR's
`headRefOid`. The branch ref updates **atomically** on push, so right after the push it already equals local
HEAD — no lag, no phantom mismatch. The merge step is unchanged: it still passes
`--match-head-commit "$LOCAL_SHA"`, which is the authoritative guard that aborts if the head actually moved
between verification and merge. So this only swaps the *pre-merge check's* data source for a race-free one;
the safety property (merge exactly the reviewed SHA) is untouched.

## Alternatives considered

- **Poll `headRefOid` until it matches / times out** — rejected: adds latency and complexity to paper over a
  value that's simply the wrong source; the branch ref is authoritative and instant.
- **Drop the pre-merge check, rely only on `--match-head-commit`** — rejected: the explicit check gives a
  clear, early, actionable error; `--match-head-commit` alone fails later with a vaguer message.

## Blast radius

One line in `finish` (`scripts/wf.sh`) + `plugin.json` version. No change to the merge guard, the review gate,
or branch protection.

## Rollout + rollback

Land it; `finish` stops phantom-blocking on a fresh push. Rollback: revert the one commit. One squash commit.
