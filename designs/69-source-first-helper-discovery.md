# Proposal: trusted-but-current cross-plugin helper discovery in wf.sh (#69)

> Canonical design doc. Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh`'s `locate_audit()` resolves the `verify-claims` reviewer **installed-first**: it searches the
Claude plugin cache + Claude/Codex skill installs first (highest version via `sort -V | tail -1`), and only
falls back to the context repo's in-tree copy if nothing is installed.

This is a distinct staleness path from session `SKILL.md` resolution (#68). `--plugin-dir` makes a *session*
read a plugin's skills from source, but `locate_audit()` is a *shell* search run by `wf.sh` — so the
`ship-change → verify-claims` composition executes whatever stale copy sits in the version-keyed cache, even
when ship-change is operating on a source checkout. This is the exact mechanism that left this box's cached
`aar-engineering` a commit behind `main` (the #60 author-identity fix) until source was forced by hand.

The naive fix is "source-first" — search the repo's in-tree copy first. The `--scaffold` review showed that
inversion is **unsafe** (its HIGH): the reviewed branch *is* the in-tree source, so a PR that edits
verify-claims' own `audit_experiment.sh` would run its **own modified reviewer** as the merge gate — code
under review judging itself. The fix has to be current *without* trusting the branch.

## Approach

**Trusted-but-current resolution.** Resolve the reviewer from the context repo's **base ref** —
`origin/main`, then local `main` — materialized into a content cache, never from the branch under review and
never from the stale version-keyed install cache.

New order in `locate_audit()`:

1. `AUDIT_EXPERIMENT=<path>` — unchanged top-priority manual override.
2. **base-ref reviewer** (new `audit_from_base_ref`): find verify-claims in the repo's tree at the base ref,
   `git archive` the whole **skill directory** (`skills/verify-claims/` — `SKILL.md` + `scripts/` +
   `references/…`, the canonical Agent Skill unit, so any relative resource the reviewer reads survives, not
   just `scripts/`) from that ref into a cache under the repo's **git-common-dir** (`aar-ship-verify/<base-sha>/…`),
   and run `scripts/audit_experiment.sh` from there. The cache lives inside `.git` (shared across worktrees,
   never in the worktree's tracked state), is keyed by the base commit so phases/calls reuse one extraction,
   and is built race-tolerantly (`mktemp` + `mv -T`, loser drops its copy). Tried first for the **context
   repo**, then for **wf.sh's own source repo** (`SELF_REPO`) when the context repo carries no verify-claims
   in-tree — so a cross-repo ship-change (e.g. on a repo that has no reviewer of its own) still reviews against
   current *product* source rather than a stale install.
3. **installed reviewer** — the existing plugin-cache / Claude+Codex-skill search, reached only when no trusted
   base-ref source carries verify-claims (a repo-less invocation with no source repo, or repos with none
   in-tree).

**Fail closed, never fail open.** `audit_from_base_ref` distinguishes "this base has *no* verify-claims"
(legitimate fall-through to the next source) from "this base *has* verify-claims but it could not be extracted"
(`git archive`/`tar`/cache-write error). The latter returns a distinct code and `locate_audit` **aborts**
rather than silently downgrading the merge-gate reviewer to a possibly-stale installed copy — the exact
silent-staleness this issue exists to close. `AUDIT_EXPERIMENT` remains the manual override for a genuinely
stuck resolution.

Why this is both properties at once:

- **Current** — the base ref is what merges to `main`; resolving from it picks up source as soon as it lands,
  closing the cache-staleness gap (#69). The smoke proves a new `main` commit is reflected immediately.
- **Trusted** — the base ref is never the branch under review. For any PR that does **not** touch
  verify-claims, the base content is byte-identical to the worktree's, so this differs from plain source-first
  *only* on a PR that edits the reviewer — exactly where it must, by refusing to let that edit review itself.
  A verify-claims improvement is therefore exercised as a gate only on the *next* PR after it lands. This is
  the standard "CI pins its own config to base" tradeoff, and is accepted.

Load-bearing details preserved: the `|| true` after each `find` stays (under `set -euo pipefail` a missing
search dir makes `find` exit non-zero and would abort the assignment before the next candidate is tried);
`audit_from_base_ref` echoes nothing and returns 0 on every failure mode (non-git repo, no `git`/`tar`, no
main ref, no in-tree verify-claims, archive error) so the caller cleanly falls through to the installed copy.

## Alternatives considered

- **Plain source-first (the original commit on this branch).** Rejected: the `--scaffold` HIGH — a
  verify-claims PR would run its own modified reviewer as its merge gate.
- **Source-first, but fail-closed to base only when the diff touches verify-claims.** Functionally identical
  to always-base (for a PR that doesn't touch the reviewer, base == worktree), but needs a "does the diff
  touch the reviewer" predicate. Rejected as strictly more code for the same behavior; always-base gets the
  fail-closed property for free.
- **Point at the local `~/aar-skills` main checkout.** Simple, but instance-coupled — only works for this
  box / this repo, and bakes the exact instance↔product leak the scaffold avoids. Rejected for portability;
  base-ref-via-git-object-store works on any repo.
- **Leave installed-first, document the footgun.** Rejected: leaves the composition silently stale — the
  failure this issue exists to close, and the one that already bit this box.
- **`AUDIT_EXPERIMENT` env override only.** Already exists and stays as the manual top override; it doesn't
  fix the *default* resolution, which is the actual bug.

## Blast radius

- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`: rewrites `locate_audit()` + adds the
  `audit_from_base_ref` helper and a `locate-audit` introspection subcommand. Changes *which* verify-claims
  copy runs during `--design`/`--scaffold`/`--code` reviews; no change to the review interface or any caller.
- New `scripts/locate_audit_smoke.sh` + a step in `.aar-ci/checks.sh` that runs it when `wf.sh` changes
  (the composition smoke the fake-HOME discovery smoke can't provide — it asserts *which* reviewer runs).
- `SKILL.md`: documents the resolution order. `plugin.json`: version bump.
- Residual: the installed-copy fallback is reached only when *neither* the context repo *nor* wf.sh's source
  repo carries verify-claims at base — i.e. wf.sh is itself running from an install with no source checkout
  behind it. The two staleness cases that actually bite — aar-skills self-review, and a cross-repo
  ship-change driven from the aar-skills source — are both now resolved current via base refs. The remaining
  install path is mitigated by the fleet auto-update of installed plugins.
- Self-consistency: this very PR edits the reviewer-resolution code. Driven from the **main checkout's**
  `wf.sh`, whose (old) `locate_audit` resolves the reviewer; and once merged, the new resolver would itself
  pick the *base* (pre-merge) verify-claims for any future verify-claims PR — i.e. it is safe under its own
  rule. The new behavior is proven by `locate_audit_smoke.sh`, not just by this run.

## Rollout + rollback

- Pure resolution change; no state, no migration. The `.git/aar-ship-verify/` cache is regenerable content
  (safe to delete anytime).
- Rollback: revert the commit (restores installed-first). The override `AUDIT_EXPERIMENT` is unchanged
  throughout, so a stuck resolution always has a manual escape hatch.
