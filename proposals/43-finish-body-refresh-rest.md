# Proposal: finish PR-body refresh via REST API (drop the read:org dependency) (#43)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The finish-time PR-body refresh added in #24 (re-render the design doc into the PR body before merge, so the
merged record matches a doc revised during review — the F1 drift fix) uses `gh pr edit <PR> --body-file -`.
`gh pr edit` issues a **GraphQL** query that reads `login`/`name`/`slug` fields requiring the **`read:org`**
scope. A minimal `repo`-scoped token — what we recommend to adopters, and what this instance's `GH_TOKEN`
has — lacks it, so the refresh fails. It's best-effort/non-blocking (`WARN: could not refresh PR #N body`),
so the merge still proceeds, but the drift fix **silently no-ops**: a doc revised during review keeps its
open-time body on the merged PR. (First observed live on PR #41's finish.)

The open-time render (`gh pr create` in `open`) is unaffected — it doesn't hit the org GraphQL path — so the
headline #24 behavior works; only the finish refresh is broken.

## Approach

Swap the refresh's `gh pr edit ... --body-file -` for the **REST API**, which needs only `repo` scope:

```sh
render_pr_body "$WT" "$FDOC" "$FISSUE" > "$TMP"
gh api --method PATCH "repos/$REPO/pulls/$PR" -F body=@"$TMP"
```

`gh api` PATCH on `pulls/{n}` with a `body` field is a plain REST call (no org/team GraphQL), verified working
on a `repo`-scoped token. Render to a temp file and `-F body=@file` (proven) rather than piping, so
backticks/code-fences/`$`/`#` in the doc survive. **Best-effort/non-blocking:** the render *and* the PATCH go
inside a single `if` condition (`render … && gh api …`), so under the script's `set -euo pipefail` a failure
on *either* the render/write or the API logs WARN and proceeds — a cosmetic refresh can never abort an
otherwise-clean `finish` (design-review F1).

This is also the right fix for adopters: it drops the `read:org` requirement entirely rather than asking every
user to broaden their token scope.

## Alternatives considered

- **Broaden `GH_TOKEN` to include `read:org`.** Rejected — pushes a wider scope onto every adopter for a
  cosmetic refresh, when the REST path needs nothing beyond the `repo` scope already required. (Same
  `read:org` friction we hit on `gh auth login`; avoiding it is the pattern.)
- **`gh pr edit --body "$var"`** (no GraphQL?) — `gh pr edit` resolves the PR via GraphQL regardless of how
  the body is passed, so it still trips `read:org`. The tool, not the flag, is the problem.
- **Drop the finish refresh, rely on open-time only.** Rejected — that's exactly the drift #24 F1 fixed
  (a doc revised during review would keep a stale body on the permanent record).

## Blast radius

- **One file:** `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`, the `finish` 0c refresh block
  only. No change to open (already works), the review/merge gates, or branch protection. Still best-effort.
- Version bump on the `aar-engineering` plugin manifest.
- Fixes the refresh for any `repo`-scoped token (this box + adopters).

## Rollout + rollback

- **Rollout:** ships through ship-change; `.aar-ci` checks (bash syntax) + smoke run in `finish`. First real
  exercise is this PR's own finish — the refresh should now succeed (no WARN) and the merged PR body should
  match the final doc.
- **Rollback:** single squash commit — `git revert <sha>`; the refresh reverts to the (non-functional on this
  token, but harmless/non-blocking) `gh pr edit` form. Confined to one best-effort block.
