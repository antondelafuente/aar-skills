# Proposal: symmetric engineer identities for Codex authors (#20)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` has the product shape we want for Claude-authored scaffold changes, but not for
Codex-authored ones:

- PR creation, pushes, comments, and merges still use the caller's ambient `GH_TOKEN`, so GitHub shows Anton
  as the author even when an agent did the work.
- Native review attribution is single-direction: `author=claude` can post as `codex-engineer[bot]`, while
  `author=codex` falls back to the ambient token after requiring only `AUDIT_VERIFIER_CMD`.
- The docs describe the reverse path as a future follow-up, which means Codex cannot yet be a first-class AAR
  contributor on this repo without lying about the author family or bypassing the workflow.

Issue #20 asks for both directions to be explicit: Claude work is authored by `claude-engineer[bot]` and
reviewed by `codex-engineer[bot]`; Codex work is authored by `codex-engineer[bot]` and reviewed by
`claude-engineer[bot]`.

## Approach

Add one identity-keyed product seam to `wf.sh`, then route GitHub operations through the right identity for the
declared author family.

1. **Engineer identity token seam.** Add `WF_ENGINEER_TOKEN_CMD_CLAUDE` and `WF_ENGINEER_TOKEN_CMD_CODEX`. Each
   command prints a fresh GitHub token for that family's bot identity. The same family identity is used for both
   roles: Claude identity authors Claude work and reviews Codex work; Codex identity authors Codex work and
   reviews Claude work. Backward compatibility: the existing `WF_REVIEWER_TOKEN_CMD` aliases
   `WF_ENGINEER_TOKEN_CMD_CODEX`, because that is the currently configured `codex-engineer` token command.
2. **Git commit identity seam.** Add `WF_ENGINEER_GIT_AUTHOR_CLAUDE` and `WF_ENGINEER_GIT_AUTHOR_CODEX`, each in
   `Name <email>` form. A strict agent-owned `open` uses this for `GIT_AUTHOR_*` and `GIT_COMMITTER_*` on the
   design-doc commit. Token routing alone does not and cannot change commit metadata, so missing git-author
   config blocks before mutation on the strict path.
3. **Strict identity path plus explicit legacy path.** Add `wf.sh open <worktree> <author>` as the strict
   agent-owned path. It uses the author family's engineer token for push and PR creation, and the author family's
   git identity for the commit. Missing, failing, or empty token/git-author config blocks before mutation. Keep
   bootstrap available only through an explicit `wf.sh open <worktree> --legacy` form that uses ambient auth and
   prints a warning. A missing author arg blocks with usage, not silently falling back to Anton. Once both
   identities are configured, a later hardening change can remove or gate the legacy path.
4. **Author-side GitHub routing.** For commands that already require `<author>` (`design-review`, `code-review`,
   `finish`) use the author token for author-side mutations: pushing the branch, refreshing the PR body, marking
   ready, and merging. `classify` should require `<author>` too, so automated comments can be attributed to the
   opposite-family reviewer identity.
5. **Reviewer routing by opposite family.** Native reviews and reviewer-owned comments use the opposite-family
   engineer token. Preserve the existing product fallback for unenforced installs: if no reviewer token command is
   configured, review output can still post as an ambient comment and merge only if the repo permits it. If a
   reviewer token command is configured but fails/returns empty, block. Add `WF_REQUIRE_NATIVE_REVIEW=1` for this
   repo's enforced mode: with it set, missing reviewer identity blocks before posting fallback comments.
6. **Codex author support.** Remove the hard block in `check_author`. Codex-authored work still needs a
   different-family verifier command (`AUDIT_VERIFIER_CMD`, usually `claude -p ...`) because `audit_experiment.sh`
   enforces model-family independence. The GitHub identity path is independent of that model-reviewer command.
7. **PR body correctness.** Stop hardcoding `codex-engineer[bot]` in generated PR prose. Use generic wording by
   default ("the opposite-family reviewer identity") and allow optional labels
   `WF_ENGINEER_LABEL_CLAUDE` / `WF_ENGINEER_LABEL_CODEX` for instances that want concrete bot names in PR text.
8. **Docs/runbook.** Update `SKILL.md`, `RUNBOOK.md`, `plugin.json`, and `wf.sh help` to show the new lifecycle
   signature: `open <worktree> <author>`, `open <worktree> --legacy`, `classify <worktree> <author>`, the
   identity-keyed env vars, the git-author vars, and the native-review-required flag. Keep the note that actual
   GitHub App creation/key storage is instance config, not product code.

The first implementation can be product-complete while instance-config incomplete: on this box today only
`codex-engineer` is configured. That means a strict Codex-authored run can open as Codex once
`WF_ENGINEER_GIT_AUTHOR_CODEX` is configured, but should fail at a clear "missing `claude-engineer` reviewer
token command" boundary when `WF_REQUIRE_NATIVE_REVIEW=1` is set. Existing Claude-authored changes can still use
the explicit legacy open path until `claude-engineer` is configured.

## Alternatives considered

- **Keep using the ambient author token, only add a Claude reviewer.** Rejected: it fixes branch-protection
  mechanics but not the misleading GitHub trail that issue #20 is about.
- **One author-token command plus one reviewer-token command.** Rejected: role-keying duplicates the real
  identity model. Each family has one engineer identity; role is derived from `author` and opposite-family review.
- **Make strict author identity mandatory for every `open` immediately.** Rejected for this first rollout:
  without `claude-engineer` config it bricks the shipping path needed to land the remaining setup/hardening
  changes. `open --legacy` remains only as an explicit bootstrap path.
- **Scope commit authorship out.** Rejected: issue #20 asks for the trail to be attributable to the correct
  engineer. PR actor alone is not enough if commits still carry the ambient user's name/email.
- **Reuse `codex-engineer` as both Codex author and Claude reviewer.** Rejected: GitHub self-approval would fail,
  and it violates the cross-family review invariant.
- **Create the `claude-engineer` GitHub App inside product code.** Rejected: GitHub App creation and private-key
  storage are instance/admin operations. The product should define the seam and fail closed when the seam is not
  configured.

## Blast radius

SWE pipeline only:

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh` identity routing and lifecycle signatures.
- `plugins/aar-engineering/skills/ship-change/SKILL.md` and `RUNBOOK.md`.
- `plugins/aar-engineering/.claude-plugin/plugin.json` version bump.

No research-product behavior changes. No instance secrets are committed. Existing Claude-authored changes remain
compatible through the explicit `open --legacy` path and the `WF_REVIEWER_TOKEN_CMD` -> Codex-token alias, but
the strict path blocks missing author identity config instead of silently falling back to Anton. Unenforced
outside installs keep the comment fallback unless they opt into `WF_REQUIRE_NATIVE_REVIEW=1`.

## Rollout + rollback

Rollout:

- Ship the product seam and docs through `ship-change`.
- Configure this instance with `WF_ENGINEER_TOKEN_CMD_CLAUDE`, `WF_ENGINEER_TOKEN_CMD_CODEX`,
  `WF_ENGINEER_GIT_AUTHOR_CLAUDE`, `WF_ENGINEER_GIT_AUTHOR_CODEX`, and `WF_REQUIRE_NATIVE_REVIEW=1` once the
  `claude-engineer` app/key exists (or keep `WF_REVIEWER_TOKEN_CMD` as the temporary Codex-token alias).
- At merge time, test the available boundary: strict Codex author opens with `codex-engineer`; enforced review
  blocks clearly if `claude-engineer` is missing. The full happy-path Codex author -> Claude reviewer smoke is
  deferred until that app/key is installed.

Rollback:

- Revert the squash commit through the normal lifecycle.
- Emergency: temporarily relax branch protection per `RUNBOOK.md` if a token/app misconfiguration traps merges.

The likely first-run block is configuration, not code: no local `~/.config/claude-engineer` exists yet. The
desired product behavior in enforced mode is a clear block before native review, not a misleading fallback.
