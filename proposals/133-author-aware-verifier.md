# Proposal: Author-aware verifier env for ship-change (#133)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`ship-change` currently passes ambient `AUDIT_VERIFIER_CMD` through to the `verify-claims`
audit subprocess for both author families. This works for Codex-authored changes on this
box, where the ambient verifier is `claude -p ...`, but it breaks Claude-authored changes:
`wf.sh` sets `AAR_SUBSTRATE=claude`, the inherited verifier is also Claude, and
`verify-claims` correctly blocks same-family review.

The failure is easy to rediscover because the ambient value can come from shell startup or
auth env loading. Telling Claude authors to manually clear `BASH_ENV` or unset a variable is
not a product fix; the workflow driver owns reviewer selection and should pass a coherent
environment into the audit subprocess.

## Approach

Make `wf.sh` author-aware when invoking `verify-claims`:

- For `author=codex`, keep the current requirement: `AUDIT_VERIFIER_CMD` must be set to a
  Claude-family verifier, because the default verifier is Codex and would be same-family.
- For `author=claude`, ignore an inherited Claude-family `AUDIT_VERIFIER_CMD` and let
  `verify-claims` use its default Codex verifier.
- Preserve explicit non-Claude overrides for `author=claude` (for example a future Codex or
  custom verifier command). The driver should only discard the known-wrong inherited value,
  not every override.

Implementation shape:

- Add a small helper in `wf.sh` that builds the environment prefix for audit subprocesses.
  It should inspect `AUDIT_VERIFIER_CMD` with the same coarse family inference used by
  `verify-claims`: `*claude*` = Claude, `*codex*` = Codex, otherwise custom.
- Use that helper in `run_review` instead of blindly inheriting `AUDIT_VERIFIER_CMD`.
- Add smoke coverage to `identity_smoke.sh` with a fake audit script that records whether
  `AUDIT_VERIFIER_CMD` reached the subprocess. The regression case is
  `author=claude` + ambient `AUDIT_VERIFIER_CMD='claude ...'`: the fake audit should see
  `AAR_SUBSTRATE=claude` and no `AUDIT_VERIFIER_CMD`. A companion case should show
  `author=codex` keeps the Claude verifier.
- Update the ship-change guidance to say the driver strips same-family ambient verifier
  overrides for Claude authors; users should not clear `BASH_ENV` by hand.

## Alternatives considered

- Remove `AUDIT_VERIFIER_CMD` from the box environment. Rejected because Codex-authored
  changes still need a Claude verifier; requiring every Codex run to remember the override
  recreates the original footgun in the opposite direction.
- Tell Claude authors to run `BASH_ENV= AUDIT_VERIFIER_CMD= wf.sh ...`. Rejected because the
  whole point of `wf.sh` is to encode the workflow guardrails, not make authors debug shell
  inheritance.
- Teach `verify-claims` to reinterpret same-family overrides. Rejected for this fix because
  `verify-claims` is correctly fail-closed when asked to run same-family. The bug is in the
  caller passing the wrong environment.

## Blast radius

This touches only the `aar-engineering` workflow driver and its smoke/docs. It does not
change GitHub token identity, branch protection, review posting, verifier resolution, or
the `verify-claims` fail-closed cross-family check.

## Rollout + rollback

Rollout is the normal `ship-change` merge. After merge, Claude-authored product changes on
this box should no longer need shell-level `AUDIT_VERIFIER_CMD` workarounds; Codex-authored
changes should continue to pass `doctor` and review with the Claude verifier.

Rollback is a normal revert of the merged PR. The pre-fix workaround remains available:
Claude authors can invoke `wf.sh` with `BASH_ENV= AUDIT_VERIFIER_CMD=` if a regression is
found.

Closes #133.
