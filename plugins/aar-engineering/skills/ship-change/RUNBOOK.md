# RUNBOOK — aar-engineering workflow operations

Operational record for the GitHub-backed scaffold-change lifecycle (`ship-change` / `wf.sh`): the **as-built
enforcement config** now in force, the **escape hatches** if the automation wedges (the load-bearing part),
and token rotation. Branch protection is a **repo-wide gate** — if the reviewer identity or a rule breaks it
can block EVERY merge — so the escape hatches matter as much as the config.

## What's enforced (as-built)

The repo is **public**, and branch protection on `main` is **active** with:

- **Require a pull request before merging.**
- **Require 1 approving review** — satisfied by a cross-family native engineer review (author identity ≠
  reviewer identity, so GitHub allows it). The driver posts `--code` as an Approve (clean) / Request-changes
  (findings); only `finish`'s final-SHA review approves.
- **Dismiss stale approvals when new commits are pushed** — an approval is bound to its reviewed SHA.
- **Require conversation resolution** — our reviews post as review *bodies* (not line threads), so nothing
  to resolve in practice; if it ever blocks a clean merge, drop just this rule (see escape hatches).
- **Block force pushes + block deletions** on `main`.
- **Include administrators (`enforce_admins`)** — **ON**. This is load-bearing: any ambient admin token used by
  the driver must still have an opposite-family approval to merge.

NOT enabled (deliberately): **required status checks**. The `.aar-ci` checks + behavior smoke run *driver-side*
in `finish` (before the approval), not as GitHub-reported statuses — so there's nothing for branch protection
to require yet. The classifier's `design-gate` is likewise **advisory** (recorded on the PR, not a required
check). Wiring either as a GitHub-required status is a tracked follow-up (needs a small GitHub Action).

## Engineer identities (as-built)

- **`codex-engineer`** — a GitHub App, installed on `aar-skills`. It can author Codex work and review
  Claude-authored changes. This instance currently exposes its token through the legacy `WF_REVIEWER_TOKEN_CMD`
  seam, which `wf.sh` treats as a fallback alias for `WF_ENGINEER_TOKEN_CMD_CODEX`.
- **`claude-engineer`** — a GitHub App, installed on `aar-skills` (its token seam `WF_ENGINEER_TOKEN_CMD_CLAUDE`
  + `WF_ENGINEER_GIT_AUTHOR_CLAUDE` are wired on this box). It authors Claude work and reviews Codex-authored
  changes — verified live: it posted the cross-family reviews on PR #57 and authored issue #62 (both read as
  `claude-code-engineer[bot]` / `app/claude-code-engineer`).
- **Permissions: `contents: write` + `pull_requests: write`.** ⚠️ **Gotcha (cost a round-trip):** an App's
  approval only **counts** toward "require approvals" if the App has **`contents: write`**. With
  `pull_requests: write` *alone* it can *post* a review, but it reads as `author_association: NONE` and the
  approval does **not** satisfy the gate (`reviewDecision: REVIEW_REQUIRED`). Grant `contents: write` and
  re-accept the installation's permission request.
- **Instance wiring (not product):** each App's id + private key live on the instance under e.g.
  `~/.config/<family>-engineer/`. `WF_ENGINEER_TOKEN_CMD_CLAUDE` / `WF_ENGINEER_TOKEN_CMD_CODEX` mint fresh
  installation tokens per use (they expire ~1h); `WF_ENGINEER_GIT_AUTHOR_CLAUDE` /
  `WF_ENGINEER_GIT_AUTHOR_CODEX` provide `Name <email>` for strict commit attribution. `wf.sh` consumes only these
  seams — no App specifics in product code. `WF_REQUIRE_ENGINEER_IDENTITY=1` makes missing author identity config block;
  `WF_REQUIRE_NATIVE_REVIEW=1` makes the final merge-gate review block when the opposite-family reviewer
  identity is absent.

## Escape hatches (when the automation wedges)

Because `enforce_admins` is ON, there is **no standing admin merge-bypass** — that's intentional (the agent
shouldn't be able to bypass its own gate). Instead the owner edits the rule:

- **Disable a rule fast.** Repo → Settings → Branches → the `main` rule → uncheck the offending requirement
  (e.g. require-approvals, or conversation-resolution) → Save. Or via API:
  `gh api -X PUT repos/<owner>/<repo>/branches/main/protection --input <relaxed.json>`. Merges flow again;
  re-tighten once fixed. (Editing protection settings is available to the repo owner/admin even with
  `enforce_admins` ON — that only gates push/merge to the branch, not the settings API.)
- **Remove branch protection entirely (nuclear).** `gh api -X DELETE repos/<owner>/<repo>/branches/main/protection`.
  The repo reverts to driver-side-gate-only behavior. Fully reversible — re-PUT the rule to restore.
- **Revoke an engineer App.** Uninstalling / revoking an engineer App immediately stops it authoring/reviewing —
  the clean unwind for a compromised identity (combined with relaxing require-approvals so merges aren't trapped).

## Token / identity rotation

- **`GH_TOKEN`** (author/driver auth). Rotate: mint a new fine-grained PAT (repo: contents + pull_requests),
  replace it wherever your environment provides `GH_TOKEN` *(this instance: `~/.env`, re-`source`)*. `wf.sh`
  sources no env file itself. NEVER print it; scrub from captured output (`sed "s/${GH_TOKEN}/***/g"`).
- **Engineer Apps** (author/reviewer identities). Rotate the App's private key in the App settings and replace
  the matching `~/.config/<family>-engineer/key.pem`; the minter picks it up. Revoking an App stops that
  identity immediately.

## One-command revert of a merged change

A shipped change is one squash commit on `main`. To undo:

```
git -C <repo> checkout main && git -C <repo> pull --ff-only
git -C <repo> revert <merge-commit-sha>        # creates a revert commit
# then ship the revert through the normal lifecycle (it's just another change).
```

If a plugin manifest changed, after a revert/merge refresh installed plugins:
`claude plugin marketplace update aar-skills && claude plugin update <name>@aar-skills`.

## Follow-ups (not yet built)

- **`.aar-ci` checks + `design-gate` as GitHub-required status checks** — a GitHub Action that runs the
  checks and reports a status, so branch protection can require them (today they're driver-side only).
