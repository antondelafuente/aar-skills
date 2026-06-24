# Proposal: fail closed on missing ship-change engineer auth (#107)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` has the right bot-vs-bot model, but the driver still treats missing engineer-token
configuration as a warning unless an instance-specific strictness variable is present. If an agent runs
`wf.sh open`, `wf.sh issue`, or review/comment/classify steps from a shell that has not sourced the
instance env, the same missing env removes both the token commands and the strictness flag. The command can
then fall back to ambient `gh` auth, which on this box is the owner account, and the failure only becomes
obvious near branch protection or self-approval.

The product invariant should not depend on a variable supplied by the same unsourced env it is meant to
guard. When a caller names an author family, the default should be: use that engineer identity, or stop with a
diagnostic that explains what is missing.

## Approach

Invert the default identity policy in `wf.sh`: a named author/reviewer family now means engineer identity is
required. Ambient auth remains available only through an explicit escape hatch, `WF_ALLOW_AMBIENT_IDENTITY=1`,
for local/bootstrap installs that deliberately do not have engineer Apps.

Load-bearing details:

1. **Strict named author paths.** `open <worktree> <author>`, `comment`, `issue`, `design-review`,
   `code-review`, `finish`, and `classify <worktree> <author>` must resolve the relevant author or reviewer
   engineer token before doing GitHub PR/Issue operations. `open` also requires the configured engineer git
   author for the design-doc commit. If the config is missing, the driver exits before pushing, creating a PR,
   posting a comment/review, approving, or merging.
2. **No silent author omission.** `open <worktree>` and `classify <worktree>` without an author should block by
   default with a message telling the agent to pass `claude` or `codex`. The old ambient mode is still possible
   with `WF_ALLOW_AMBIENT_IDENTITY=1`, making owner-auth use opt-in and visible.
3. **Diagnostic command.** Add `wf.sh doctor <author> [repo-or-worktree]`, which reports whether ambient gh
   works, whether the author and opposite-family token commands are configured and mint usable GitHub tokens,
   whether the author git identity is configured, whether `AUDIT_VERIFIER_CMD` is present for Codex-authored
   reviews, and whether the ambient escape hatch is enabled. It prints logins/statuses, never token values, and
   exits non-zero when the named author path is not ready.
4. **Docs at the point of use.** Update `ship-change` SKILL.md, RUNBOOK.md, and `wf.sh help` to say the driver
   sources no env file, named author paths are strict by default, and the instance wrapper or shell must supply
   `WF_ENGINEER_TOKEN_CMD_*` / git-author seams before running the workflow.

This deliberately does not add a first-class rescue/approve command in the same implementation child. Rescue is
useful for already-bad PRs, but it is not the invariant. Once the default path fails closed, new owner-auth PRs
stop being created silently; a rescue command can be filed separately if we still see human-authored PRs from
legacy/manual paths.

## Alternatives considered

- **Keep `WF_REQUIRE_ENGINEER_IDENTITY=1` as the strictness switch.** Rejected: the observed incident happened
  because the env was unsourced. A guard supplied by that env disappears with the guarded config.
- **Only add a `doctor` command.** Rejected: diagnostics help, but they still rely on the agent choosing to run
  them before a bad PR operation. The PR operation itself needs to fail closed.
- **Hardcode this instance's `/home/anton/.env` in the driver.** Rejected: instance leak. The product should
  expose seams and diagnostics; wrappers may source local env outside the repo.
- **Add a rescue/approve command first.** Deferred: useful for cleanup, but it does not prevent the recurrence.

## Blast radius

`aar-engineering` SWE-pipeline layer only: `wf.sh`, `ship-change` SKILL.md/RUNBOOK.md, and the plugin version.
The behavior change is intentionally broad across `ship-change` PR/Issue operations that name an author family:
missing engineer identity blocks instead of falling back to owner auth. Installs without engineer Apps can opt
into the old permissive behavior with `WF_ALLOW_AMBIENT_IDENTITY=1`.

## Rollout + rollback

The design PR closes #107 and spawns one `ready` child to implement the strict-auth policy, doctor command, docs,
and version bump. Rollback is reverting that implementation PR; the immediate operational escape hatch is
`WF_ALLOW_AMBIENT_IDENTITY=1` for a run that must proceed without engineer identities.
