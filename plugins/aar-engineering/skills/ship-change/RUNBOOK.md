# RUNBOOK — aar-engineering workflow operations

Operational runbook for the GitHub-backed scaffold-change lifecycle (`ship-change` / `wf.sh`). Covers
Phase 2 enablement (turning on enforcement) and — the load-bearing part — how to **escape** if the
automation wedges. Branch protection is a **repo-wide gate**: if an engineer App or a required check
breaks, it can block EVERY merge. So the rule is staged rollout + a standing admin bypass + this runbook.

## Phases at a glance

- **Phase 1 — SHADOW MODE (current).** `wf.sh` runs the whole lifecycle, posts the `--scaffold` / `--code`
  reviews and the classification to the PR, and merges after its own fail-closed gate (`gh pr merge`).
  **Branch protection is NOT enabled.** Nothing GitHub-side blocks a merge; the gate logic lives in the
  driver. This is deliberate: watch it work on real PRs before making anything mandatory.
- **Phase 2 — ENFORCED.** Per-family GitHub App identities + branch protection make the cross-family
  approval and the checks *required*. Native Approve / merge buttons. Needs the one-time setup below.

## Phase 2 enablement (one-time, PM / repo admin — GitHub UI)

1. **Create two GitHub Apps** (or fine-grained PATs to start): `claude-engineer` and `codex-engineer`,
   each with `contents:write`, `pull_requests:write`, `checks:write` on the repo. The point is **distinct
   identities** so a foreign-family review is a *real* approval by a different actor (author ≠ reviewer →
   GitHub allows the approval; this is why the multi-engineer framing dissolves "can't approve your own PR").
2. **Wire each family's reviewer to post its native review** (Approve on a clean valid `--code`; Request
   changes on findings) as its own App identity — not as a PR comment.
3. **Turn on branch protection on `main`**, requiring:
   - **1 approving review from the opposite family** (the cross-family code gate).
   - **Required status checks**: the `.aar-ci` deterministic checks + behavior smoke, AND the **`design-gate`**
     check (carries the human's architectural-design approval — green for mechanical per the classifier,
     red-until-PM-approval for architectural).
   - **Include administrators: NO** — keep the admin bypass below.
4. **Scope (v1):** enable enforcement only for the **productized direction** (Claude-authored → Codex
   review). Until the Codex→Claude reverse reviewer is wired, Codex-authored changes use the documented
   fallback (the current flow) so branch protection never blocks a direction with no reviewer.

## Escape hatches (when the automation wedges)

- **Admin bypass (the standing one).** The PM stays a **repo admin** with "include administrators" OFF on
  branch protection — so an admin can always merge, or temporarily lift protection, if the automation
  jams. Branch protection never traps the team.
- **Disable a required check fast.** Repo → Settings → Branches → branch-protection rule for `main` →
  uncheck the offending required status check (or the required-review) → Save. Merges flow again
  immediately; re-enable once fixed.
- **Remove branch protection entirely (nuclear).** Delete the `main` protection rule. The repo reverts to
  exactly Phase-1 behavior (driver-side gate only). Fully reversible — re-add the rule to restore Phase 2.
- **Full fallback.** The Phase-1 flow still works unchanged: `wf.sh` + the agent's own `gh pr merge` after
  the fail-closed gate. Every change is a revertible PR; the plugin uninstalls. The only new credentials are
  the engineer App(s).

## Token / App rotation

- **Phase-1 `GH_TOKEN`** (this instance: `~/.env`). To rotate: mint a new fine-grained PAT (repo scope:
  contents + pull_requests), replace it in `~/.env`, re-`source`. `wf.sh` sources no env file itself —
  whatever auth is in the caller's environment is what it uses. NEVER print the token; scrub it from any
  captured output (`sed "s/${GH_TOKEN}/***/g"`).
- **Phase-2 App tokens.** Rotate the App's private key / installation token in the App settings; update the
  reviewer wiring's secret. Revoking an engineer App immediately stops that family from approving/merging —
  which, combined with the admin bypass, is the clean unwind for a compromised identity.

## One-command revert of a merged change

A shipped change is one squash commit on `main`. To undo:

```
git -C <repo> checkout main && git -C <repo> pull --ff-only
git -C <repo> revert <merge-commit-sha>        # creates a revert commit
# then ship the revert through the normal lifecycle (it's just another change), or push directly if urgent.
```

If a plugin manifest changed, after a revert/merge refresh installed plugins:
`claude plugin marketplace update aar-skills && claude plugin update <name>@aar-skills`.

## Required-check names (fill in at Phase-2 enablement)

Record the EXACT required status-check names here when you turn on branch protection, so a future operator
knows precisely what to relax:

- `aar-ci / checks` — _(deterministic checks + behavior smoke)_
- `aar-ci / design-gate` — _(architectural-design human gate; green for mechanical)_
- _(cross-family approving review is a branch-protection "require approvals" setting, not a status check)_
