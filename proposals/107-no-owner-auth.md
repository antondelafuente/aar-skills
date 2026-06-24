# Proposal: fail closed on missing ship-change engineer auth (#107)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` has the right bot-vs-bot model, but the driver still treats missing engineer-token
configuration as a warning unless instance-specific strictness variables are present. If an agent runs
`wf.sh open`, `wf.sh issue`, or review/comment/classify steps from a shell that has not sourced the
engineer-token env, the same missing env removes the token commands and the strictness flags. The command can
then fall back to ambient `gh` auth, which may be the owner account, and the failure only becomes obvious near
branch protection or self-approval.

The mistake is not that agents can use GitHub. Ambient `gh` is useful for inspection (`gh pr view`,
`gh issue list`, maintenance, and owner/admin tasks). The mistake is using ambient owner identity for protected
workflow writes that need the author/reviewer engineer bots. The product invariant should be: convenience
`gh` may exist, but protected `wf.sh` workflow actions never silently use it when a bot identity was intended.

## Approach

Separate the two lanes in `wf.sh`: ambient `gh` can remain available for ordinary inspection, but protected
workflow mutations require the named engineer identities by default. Ambient auth remains available to workflow
mutations only through an explicit escape hatch, `WF_ALLOW_AMBIENT_IDENTITY=1`, for local/bootstrap installs
that deliberately do not have engineer Apps.

Load-bearing details:

1. **One strictness policy.** Both existing strictness switches fold into the new default. Author-side
   operations no longer need `WF_REQUIRE_ENGINEER_IDENTITY=1` to block on a missing author token/git author,
   and reviewer-side merge-gate approval no longer needs `WF_REQUIRE_NATIVE_REVIEW=1` to block on a missing
   opposite-family token. Those variables can remain as harmless legacy config, but they should no longer be
   the condition that prevents owner fallback. The one permissive override is `WF_ALLOW_AMBIENT_IDENTITY=1`;
   the docs should say the old `WF_REQUIRE_*` vars are legacy/no longer necessary under the strict default.
2. **Strict protected workflow actions.** `open <worktree> <author>`, `comment`, `issue`, `design-review`,
   `code-review`, `finish`, and `classify <worktree> <author>` must resolve the relevant author or reviewer
   engineer token before doing GitHub PR/Issue mutations. `open` also requires the configured engineer git
   author for the design-doc commit. If the config is missing, the driver exits before pushing, creating a PR,
   posting a comment/review, approving, or merging. The reviewer-token requirement is not limited to the final
   native approval: interim `design-review`, interim `code-review`, and `classify` comments are protected
   workflow writes too.
3. **No silent author omission.** `open <worktree>` and `classify <worktree>` without an author should block by
   default with a message telling the agent to pass `claude` or `codex`. The old ambient mode is still possible
   only with `WF_ALLOW_AMBIENT_IDENTITY=1`, making owner-auth workflow writes opt-in and visible.
4. **Visible ambient override.** When `WF_ALLOW_AMBIENT_IDENTITY=1` is used for a protected mutation, the driver
   must emit a clear terminal warning, and when there is a natural GitHub target, leave a best-effort durable
   trail. For PR commands with a PR number, post a short PR comment; for issue/comment authoring, include or
   append a visible override note in the created comment/body where practical. This mirrors the
   `WF_ALLOW_NONREADY_CLOSE=1` convention: an override may exist, but it must not look like normal bot-authored
   workflow traffic.
5. **Self-contained failure messages.** Every new fail-closed path must name the missing seam
   (`WF_ENGINEER_TOKEN_CMD_*`, `WF_ENGINEER_GIT_AUTHOR_*`, or `AUDIT_VERIFIER_CMD`) and the explicit escape
   hatch (`WF_ALLOW_AMBIENT_IDENTITY=1`) where that hatch applies. A zero-context agent should not need to read
   RUNBOOK.md to recover from the error.
6. **Diagnostic command.** Add `wf.sh doctor <author> [repo-or-worktree]`, because Anton explicitly wants the
   preflight surface to distinguish "ambient gh works" from "workflow bot identities work." It reports whether
   ambient gh works and which login it uses; whether the author and opposite-family token commands are
   configured and mint usable GitHub tokens; whether the author git identity is configured; whether
   `AUDIT_VERIFIER_CMD` is present for Codex-authored reviews; and whether the ambient escape hatch is enabled.
   It must call the same helper predicates the workflow uses (`engineer_token`, `engineer_git_author`,
   `reviewer_token`, `require_model_reviewer`, ambient-auth probing) so its verdict cannot drift from the
   actual gates. It prints logins/statuses, never token values, and exits 0 iff the protected workflow path
   would be able to proceed under the current configuration, including an explicit
   `WF_ALLOW_AMBIENT_IDENTITY=1` permissive run; missing bot config without that hatch exits non-zero.
7. **Docs at the point of use.** Update `ship-change` SKILL.md, RUNBOOK.md, and `wf.sh help` to say the driver
   sources no env file, named workflow actions are strict by default, and an instance wrapper or shell must
   supply the engineer-token/git-author seams before running the workflow. Also note that an instance can keep a
   small `gh.env`/ambient `GH_TOKEN` path for ordinary `gh` convenience; that does not satisfy protected
   workflow identity.

This deliberately does not add a first-class rescue/approve command in the same implementation child. Rescue is
useful for already-bad PRs, but it is not the invariant. Once the default path fails closed, new owner-auth PRs
stop being created silently; a rescue command can be filed separately if we still see human-authored PRs from
legacy/manual paths.

## Alternatives considered

- **Keep `WF_REQUIRE_ENGINEER_IDENTITY=1` / `WF_REQUIRE_NATIVE_REVIEW=1` as the strictness switches.** Rejected:
  the observed incident happened because the env was unsourced. Guards supplied by that env disappear with the
  guarded config, and the reviewer-side flag would still fail late at branch protection if left as opt-in.
- **Only add a `doctor` command.** Rejected: diagnostics help, but they still rely on the agent choosing to run
  them before a bad PR operation. The PR operation itself needs to fail closed.
- **Defer `doctor` like rescue.** Rejected after Anton's clarification: the product should support ambient `gh`
  for convenience while making workflow identity explicit, and `doctor` is the preflight surface that shows both
  lanes (`ambient gh = antondelafuente`, bot tokens ok, native review ok) without exposing secrets.
- **Hardcode this instance's `/home/anton/.env` in the driver.** Rejected: instance leak. The product should
  expose seams and diagnostics; wrappers may source local env or a smaller `gh.env` outside the repo.
- **Add a rescue/approve command first.** Deferred: useful for cleanup, but it does not prevent the recurrence.

## Blast radius

`aar-engineering` SWE-pipeline layer only: `wf.sh`, `ship-change` SKILL.md/RUNBOOK.md, and the plugin version.
The behavior change is intentionally broad across protected `ship-change` PR/Issue operations that name an
author family: missing engineer identity blocks instead of falling back to owner auth. Ordinary bare `gh`
outside `wf.sh` is unaffected. Installs without engineer Apps can opt into the old permissive workflow behavior
with `WF_ALLOW_AMBIENT_IDENTITY=1`.

## Rollout + rollback

The design PR closes #107 and spawns one `ready` child to implement the strict-auth policy, doctor command, docs,
and version bump. Rollback is reverting that implementation PR; the immediate operational escape hatch is
`WF_ALLOW_AMBIENT_IDENTITY=1` for a run that must proceed without engineer identities.
