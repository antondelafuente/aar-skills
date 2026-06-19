# Proposal: Delete local workflow branches after successful finish (#97)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh finish` deletes the remote PR branch via `gh pr merge --delete-branch` and removes the temporary worktree, but it leaves the corresponding local `change/<issue>-<slug>` branch behind in the main checkout. After squash merges those branches show as `origin/...: gone`, which creates visual noise and can make future agents think work is still active.

This just happened in `research-lab`: three finished workflow branches remained locally after their PRs merged. Manual deletion is safe but should not be routine operator work.

## Approach

After `gh pr merge` succeeds and `git worktree remove --force "$WT"` runs, have `wf.sh finish` attempt to delete the local branch it just finished.

Safety rules:

- Only consider branches matching `change/*`; never auto-delete arbitrary branch names.
- Only delete after a successful merge. A blocked or failed `finish` must leave the branch and worktree alone for repair.
- Verify no worktree is still using the branch before deleting it.
- Use `git branch -D "$BR"` because the PR is squash-merged, so `git branch -d` can refuse even though GitHub already merged the reviewed diff.
- Treat cleanup as best-effort. If local branch deletion fails, log a warning but still report the PR as shipped.

Keep cleanup in `wf.sh`, not in GitHub settings. GitHub can delete the remote PR branch, but only the local workflow driver can remove local branches on the controller.

## Alternatives considered

- Do nothing and let agents run `git branch -D` manually. Rejected because it is repetitive local hygiene and leaves stale state in every repo using `wf.sh`.
- Use `git branch -d`. Rejected because these PRs squash merge; the branch tip is not necessarily an ancestor of `main`.
- Delete all local branches with gone upstreams. Rejected as too broad; old or intentionally retained branches may need human review. `finish` should only clean up the branch it just created and merged.

## Blast radius

This changes only the `ship-change` workflow driver and the `aar-engineering` plugin version. It affects successful `wf.sh finish` cleanup after a PR has already merged. It does not change review, checks, issue close-gates, merge semantics, or failure behavior before merge.

## Rollout + rollback

Rollout is normal `ship-change`: this PR itself exercises the path, although this current run may still leave its local branch depending on whether the merged version is the one running `finish`. Future runs should delete their local `change/*` branch automatically.

Rollback is a normal revert PR restoring the previous cleanup behavior. If branch deletion warns unexpectedly, the merged PR is still valid; the operator can inspect and delete the branch manually.
