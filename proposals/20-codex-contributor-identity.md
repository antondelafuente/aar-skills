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
2. **Strict identity path plus explicit legacy path.** Add `wf.sh open <worktree> <author>` as the strict
   agent-owned path. It uses the author family's engineer token for commit, push, and PR creation; missing,
   failing, or empty token command blocks before mutation. Keep the current `wf.sh open <worktree>` as a
   named legacy/bootstrap path that uses ambient auth and prints a warning. This prevents the workflow from
   bricking before `claude-engineer` exists, while making agent-owned authorship discoverable and non-silent.
   Once both identities are configured, a later hardening change can remove or gate the legacy path.
3. **Author-side GitHub routing.** For commands that already require `<author>` (`design-review`, `code-review`,
   `finish`) use the author token for author-side mutations: pushing the branch, refreshing the PR body, marking
   ready, and merging. `classify` should require `<author>` too, so automated comments can be attributed to the
   opposite-family reviewer identity.
4. **Reviewer routing by opposite family.** Native reviews and reviewer-owned comments use the opposite-family
   engineer token. Missing reviewer config blocks native review/comment posting for commands that know the
   author. There is no default-token fallback on the strict path.
5. **Codex author support.** Remove the hard block in `check_author`. Codex-authored work still needs a
   different-family verifier command (`AUDIT_VERIFIER_CMD`, usually `claude -p ...`) because `audit_experiment.sh`
   enforces model-family independence. The GitHub identity path is independent of that model-reviewer command.
6. **PR body correctness.** Parameterize `render_pr_body` by author family so it names the actual
   opposite-family reviewer identity (`codex-engineer[bot]` for Claude authors, `claude-engineer[bot]` for Codex
   authors, generic wording for the legacy path).
7. **Docs/runbook.** Update `SKILL.md`, `RUNBOOK.md`, and `wf.sh help` to show the new lifecycle signature:
   `open <worktree> <author>`, `classify <worktree> <author>`, the legacy bootstrap form, and the two
   identity-keyed env vars. Keep the note that actual GitHub App creation/key storage is instance config, not
   product code.

The first implementation can be product-complete while instance-config incomplete: on this box today only
`codex-engineer` is configured. That means a strict Codex-authored run can open as Codex, but should fail at a
clear "missing `claude-engineer` reviewer token command" boundary until the app/key is installed; it should not
post the enforced review under Anton. Existing Claude-authored changes can still use the explicit legacy open
path until `claude-engineer` is configured.

## Alternatives considered

- **Keep using the ambient author token, only add a Claude reviewer.** Rejected: it fixes branch-protection
  mechanics but not the misleading GitHub trail that issue #20 is about.
- **One author-token command plus one reviewer-token command.** Rejected: role-keying duplicates the real
  identity model. Each family has one engineer identity; role is derived from `author` and opposite-family review.
- **Make strict author identity mandatory for every `open` immediately.** Rejected for this first rollout:
  without `claude-engineer` config it bricks the shipping path needed to land the remaining setup/hardening
  changes. The no-author `open` remains only as a loud legacy/bootstrap path.
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
compatible through the legacy no-author `open` path and the `WF_REVIEWER_TOKEN_CMD` -> Codex-token alias, but
the strict path blocks missing identity config instead of silently falling back to Anton.

## Rollout + rollback

Rollout:

- Ship the product seam and docs through `ship-change`.
- Configure this instance with `WF_ENGINEER_TOKEN_CMD_CLAUDE` and `WF_ENGINEER_TOKEN_CMD_CODEX` once the
  `claude-engineer` app/key exists (or keep `WF_REVIEWER_TOKEN_CMD` as the temporary Codex-token alias).
- Smoke-test both directions with a doc-only change: Claude author -> Codex reviewer, then Codex author ->
  Claude reviewer.

Rollback:

- Revert the squash commit through the normal lifecycle.
- Emergency: temporarily relax branch protection per `RUNBOOK.md` if a token/app misconfiguration traps merges.

The likely first-run block is configuration, not code: no local `~/.config/claude-engineer` exists yet. The
desired product behavior in that state is a clear block before PR mutation or native review, not fallback.
