---
name: ship-change
description: >-
  Ship a cleared scaffold/product change through the SWE pipeline: a gated PR with a cross-family
  code review and auto-merge-when-clean. Use AFTER the design is cleared (the human has signed off
  on the design, e.g. via a --scaffold review) and the change is built in the working tree. It takes
  an EXPLICIT list of changed paths (never "the whole working tree"), runs the repo's tracked .aar-ci
  checks + a fake-HOME behavior smoke, opens a PR, runs verify-claims --code on the exact diff, and
  auto-merges only on a clean review — otherwise it stops and hands the findings back to you. The
  autonomous back-half of an engineering change; the design half is design review + the human's clear.
---

# ship-change — the SWE-pipeline engine

This is the **engineering** counterpart to `run-experiment`: once a change to the product's code is
designed and cleared, this ships it autonomously through a gated PR. It belongs to the **SWE pipeline**
layer (see `aar-skills/AGENTS.md` "Two layers"), not the shipped research product.

**When to use:** the change is built in the working tree, the *design* is already cleared (for an
architectural change, that means a `--scaffold` review + the human's sign-off; an implementation-only
change skips straight here). Do NOT use this to design — only to ship a cleared change.

**The non-negotiable safety properties** (the engine enforces them; don't work around them):
- **Explicit changed-path list — never "the working tree."** You name every path; the engine refuses if
  anything else is dirty (per the repo's `DIRTY_POLICY`). This protects shared checkouts.
- **Tracked check profile.** Every repo shipped through this defines `<repo>/.aar-ci/checks.sh` (tracked,
  not hidden local config). It runs deterministic checks (JSON/syntax/compile/no-leak/version-bump) AND the
  fake-HOME behavior smoke for plugin/skill changes.
- **No auto-merge for plugin/skill changes without the behavior smoke.** Deterministic checks can't catch
  an install/discovery break; the fake-HOME smoke can, and it gates the merge.
- **Review the EXACT diff; auto-merge only on a clean review.** `verify-claims --code` reviews `main...branch`.
  Auto-merge iff checks pass AND the review has zero findings. Any finding → it STOPS and hands back.
- **Cross-family, both directions.** The reviewer is the OTHER family from the author (`claude` author →
  Codex review; `codex` author → Claude review). You MUST pass the author family.

## How to run

```
source ~/.env   # GH_TOKEN for gh
SHIP_MSG="<commit message>" SHIP_TITLE="<PR title>" \
  scripts/ship_change.sh <repo-dir> <author: claude|codex> <path1> [path2 ...]
```

Outcomes:
- **`SHIPPED: PR #N auto-merged`** — clean review, checks passed, merged + (if a manifest changed) a
  reminder to refresh installed plugins. Done.
- **`STOP: PR #N has <k> finding(s)`** (exit 3) — the engine opened the PR + ran the review but did NOT
  merge. Now YOU triage as a peer:
  1. **HIGH** → fix it. Edit the change on the branch (use a git worktree so the shared `main` checkout
     isn't disturbed: `git worktree add /tmp/wt <branch>`, edit, commit, push, remove the worktree).
  2. **MED/LOW** → fix, or respond on the PR (`gh pr comment`) with an accept/defer + reason.
  3. Then **re-review the UPDATED diff before merging**: `scripts/ship_change.sh remerge <repo> <author> <branch> <pr>`
     — it re-runs the checks, re-runs `--code` on the new diff, and merges iff no HIGH remains.
  Do NOT merge around the engine; the re-review-after-fix is the point.

## The per-repo `.aar-ci/` profile (what each repo supplies)

- `<repo>/.aar-ci/checks.sh` (required, tracked, executable): takes the changed paths, exits non-zero on any
  failure. Owns the repo's deterministic checks + when to run the behavior smoke. See `aar-skills/.aar-ci/checks.sh`.
- `<repo>/.aar-ci/config` (optional): `DIRTY_POLICY=strict` (aar-skills — usually clean, name every path,
  nothing else dirty) or `DIRTY_POLICY=quiescence` (shared lab repos like `orchestrator` — refuse only when
  the tree isn't quiescent; migration PRs should require quiescence so peer dirt doesn't sweep in).

## Composes

- **verify-claims `--code`** — the cross-family code reviewer (located from the installed plugin, or
  `AUDIT_EXPERIMENT=<path>`). The design half (`--scaffold`) + the human's clearance happen upstream.
- **gh** — PR create/merge (auth from `GH_TOKEN`, on this instance `source ~/.env`).
