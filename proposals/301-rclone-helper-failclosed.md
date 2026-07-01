# Proposal: Fail closed in `r2_copy` / `pull_model` edge cases (#301)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two MED robustness gaps in the hardened rclone helper shipped in #295 / PR #300 (surfaced by that
PR's final cross-family review — non-blocking, so #300 merged at HIGH=0, but both are real). Each is
an edge case where `r2_copy`'s whole reason for existing — failing closed so an incomplete copy can
never read as success — is silently defeated when the *caller* does not have `errexit` active:

1. **`pull_model` doesn't check `r2_copy`'s return code.** The pull is a bare `r2_copy …` line
   relying on the caller's `set -e`. Under the documented "callers use `set -euo pipefail`" contract
   that propagates, but a caller without active errexit would continue past a failed/INCOMPLETE copy
   into the manifest check — which could pass against already-present matching files.
2. **`r2_copy` doesn't fail closed if `mktemp` fails.** If `log=$(mktemp)` yields an empty path, the
   `Can't follow symlink` grep runs against nothing (always no-match) and `r2_copy` returns rclone's
   status — which is **0** in exactly the NOTICE-but-exit-0 case the helper exists to catch. A
   temp-file failure would thus disable the guarantee rather than surface it.

## Approach

Two ~1-line fixes in `plugins/gpu-job/skills/gpu-job/scripts/job_lib.sh`, each making the fail-closed
behavior independent of the caller's shell options:

1. `pull_model`: `r2_copy "$remote/" "$dest/" --transfers=8 --checkers=8 || return 1` — explicit,
   robust regardless of errexit.
2. `r2_copy`: guard the temp-log creation — `log=$(mktemp) || { echo "r2_copy: mktemp failed" >&2;
   return 1; }` — so a temp-file failure fails closed instead of silently disabling NOTICE detection.

Extend `rclone_helper_smoke.sh` with a case for each: `pull_model` returns non-zero when `r2_copy`
fails even with `set +e` active; and `r2_copy` returns non-zero when `mktemp` is forced to fail (stub
`mktemp` on PATH to exit non-zero). Bump `gpu-job` `plugin.json` 0.2.6 → 0.2.7.

## Alternatives considered

- **Leave as-is (documented contract already requires `set -e`).** Rejected: the helper's value is
  being a guarantee, not a guarded-by-convention hint; both fixes are trivial and remove the "only
  safe if the caller remembered errexit" caveat from safety code.
- **Wrap every helper in an errexit shim.** Overbuilt; these are the two specific call paths the
  review flagged, and per-call explicitness is clearer than a global shim.

## Blast radius

Product SWE-pipeline scaffold, `gpu-job` plugin only: `job_lib.sh` (two lines), its smoke, and the
`plugin.json` version bump. Behavior-preserving on the happy path — the changes only add non-zero
returns on failure paths that previously depended on the caller's errexit.

## Rollout + rollback

Trivial, additive. Standard one-commit revert of the merged squash (RUNBOOK "One-command revert"); no
state, no migration.
