# Proposal: product doc fixes — instance-leak auth, stale enforcement + dispatch text (#47)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

A batch of small, independent **documentation-accuracy** bugs in product-facing files (no behavior change):

1. **Instance leak (#47):** ship-change's `SKILL.md` and `wf.sh` tell consumers to `source ~/.env` for
   `GH_TOKEN` — an instance-specific path an external adopter doesn't have. The product seam was meant to be
   generic auth (the caller supplies `GH_TOKEN`); `~/.env` is this lab's mechanic, not the product's.
   (`SKILL.md` ×2, `wf.sh` ×3 — some already hedge "this instance:", `SKILL.md:57` leads with the path.)
2. **Stale enforcement text (#48):** the root `marketplace.json` description for `aar-engineering` says
   "Phase 1 runs in shadow mode," but branch protection on `main` is **active** (RUNBOOK + SKILL). A
   zero-context installer reading the marketplace sees a weaker contract than the skill describes.
3. **Stale dispatch line:** `design-experiment`'s `SKILL.md` says the Claude dispatch runs "a new
   zero-context session in the experiment dir" — but per #30 dispatched executors run in a *dedicated
   ephemeral launch dir* (one Claude per workdir; the experiment dir is the shared records home, not a cwd).

## Approach

Pure text edits, product-clean:

1. **Genericize auth:** product docs say to ensure `GH_TOKEN` is set (`gh auth login`, or
   `export GH_TOKEN=…`) — no instance path. Where a per-instance hint is genuinely useful in shipped code
   comments, keep it explicitly marked as an *example for this instance*, not the instruction.
2. **Fix marketplace text:** replace "Phase 1 runs in shadow mode" with the as-built enforcement line
   (the cross-family `codex-engineer[bot]` review is a native review that branch protection requires before
   merge) — matching the `aar-engineering` `plugin.json` description.
3. **Fix dispatch line:** "in the experiment dir" → "in a dedicated ephemeral launch dir (unique cwd per
   dispatch; the experiment dir stays the records home)" — staying substrate-neutral (no instance script
   name).

Version bumps: `aar-engineering` (SKILL.md + wf.sh changed) and `experiment-lifecycle` (design-experiment
SKILL.md changed). Closes #47 and #48; the dispatch line is a #30 follow-up folded in.

## Alternatives considered

- **Three separate PRs.** Rejected — they're all one-line doc-accuracy fixes; one cohesive "doc fixes" PR is
  one review cycle instead of three, and the reviewer can triage them independently.
- **Strip the `~/.env` hint entirely from shipped code comments.** Kept a clearly-marked instance *example*
  instead — it's useful operational context as long as it doesn't read as the product instruction.
- **Also rewrite the #6 ADR's "opposite-family" enforcement wording** (design-review F1 nuance). Deferred —
  the ADR is a point-in-time record and the authoritative as-built doc (RUNBOOK) is already accurate; not a
  doc-bug worth editing the historical record for.

## Blast radius

- **Docs only**, three files + two manifest version bumps: `plugins/aar-engineering/skills/ship-change/`
  (`SKILL.md`, `scripts/wf.sh`), `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`, and
  `.claude-plugin/marketplace.json`. No code-path / behavior / enforcement change. The marketplace edit
  re-smokes every declared plugin (discovery unaffected — description-only).

## Rollout + rollback

- **Rollout:** ships through ship-change; `.aar-ci` checks (JSON validity, version bumps) + fake-HOME smoke
  run in `finish`. No runtime effect — purely what a reader sees.
- **Rollback:** single squash commit — `git revert <sha>`. Text-only; zero risk.
