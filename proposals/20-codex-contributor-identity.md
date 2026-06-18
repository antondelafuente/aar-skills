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

Add two small product seams to `wf.sh`, then route every GitHub operation through the right identity for the
declared author family.

1. **Author token seam.** Add `WF_AUTHOR_TOKEN_CMD_CLAUDE` and `WF_AUTHOR_TOKEN_CMD_CODEX`. Each command prints a
   fresh GitHub token for that family's author identity. `wf.sh open` must take `author` and use this token for
   the design-doc commit, push, and PR creation. Later mutating author-side operations (`push`, PR body refresh,
   ready, merge, branch delete) also run under the author token. If the author token command is missing, fails,
   or returns empty, block loudly. No ambient-Anton fallback for normal lifecycle commands.
2. **Reviewer token seam by family.** Replace the single `WF_REVIEWER_TOKEN_CMD` with
   `WF_REVIEWER_TOKEN_CMD_CLAUDE` and `WF_REVIEWER_TOKEN_CMD_CODEX`, with backward compatibility for the existing
   `WF_REVIEWER_TOKEN_CMD` as the Codex reviewer for Claude-authored changes. Reviewer identity is selected as
   the opposite family from `author`. Missing reviewer config blocks native review posting; it must not silently
   degrade to an ambient-token comment for enforced paths.
3. **Codex author support.** Remove the hard block in `check_author`. Codex-authored work still needs a
   different-family verifier command (`AUDIT_VERIFIER_CMD`, usually `claude -p ...`) because `audit_experiment.sh`
   enforces model-family independence. The GitHub identity path is independent of that model-reviewer command.
4. **Identity wrapper helpers.** Add a `gh_author` helper for author-side `gh` calls and a reviewer-token helper
   keyed by author family. Use environment-scoped `GH_TOKEN=... gh ...` invocations rather than mutating process
   globals.
5. **Docs/runbook.** Update `SKILL.md`, `RUNBOOK.md`, and `wf.sh help` to show the new lifecycle signature:
   `open <worktree> <author>`, `classify <worktree> <author>`, and symmetric author/reviewer env vars. Keep the
   note that actual GitHub App creation/key storage is instance config, not product code.

The first implementation can be product-complete while instance-config incomplete: on this box today only
`codex-engineer` is configured. That means a Codex-authored run should fail at a clear "missing
`claude-engineer` reviewer token command" boundary until the app/key is installed; it should not proceed under
Anton.

## Alternatives considered

- **Keep using the ambient author token, only add a Claude reviewer.** Rejected: it fixes branch-protection
  mechanics but not the misleading GitHub trail that issue #20 is about.
- **One generic author-token command plus one generic reviewer-token command.** Rejected: the driver must know
  which family identity it is using so it can fail closed on unsupported directions and document the exact
  instance config.
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
compatible through the legacy `WF_REVIEWER_TOKEN_CMD` fallback, but the new author-token seam is intentionally
stricter once `open <worktree> <author>` is used.

## Rollout + rollback

Rollout:

- Ship the product seam and docs through `ship-change`.
- Configure this instance with `WF_AUTHOR_TOKEN_CMD_CLAUDE`, `WF_AUTHOR_TOKEN_CMD_CODEX`,
  `WF_REVIEWER_TOKEN_CMD_CLAUDE`, and `WF_REVIEWER_TOKEN_CMD_CODEX` once the `claude-engineer` app/key exists.
- Smoke-test both directions with a doc-only change: Claude author -> Codex reviewer, then Codex author ->
  Claude reviewer.

Rollback:

- Revert the squash commit through the normal lifecycle.
- Emergency: temporarily relax branch protection per `RUNBOOK.md` if a token/app misconfiguration traps merges.

The likely first-run block is configuration, not code: no local `~/.config/claude-engineer` exists yet. The
desired product behavior in that state is a clear block before PR mutation or native review, not fallback.
