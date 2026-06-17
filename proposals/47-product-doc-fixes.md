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

Pure text edits, product-clean (auth wording corrected per design-review):

1. **Genericize auth:** product docs say to **authenticate `gh` (`gh auth login`) or export `GH_TOKEN`** — no
   instance `~/.env` path. `gh auth login` does *not* set `GH_TOKEN`; the driver accepts *either* stored `gh`
   auth or the env var, so the wording says "either" (design-review F3). Covers `SKILL.md`, `wf.sh`, **and
   the `RUNBOOK.md` token-rotation line** (F1 — the RUNBOOK keeps an explicitly instance-marked `~/.env`
   example, not a product instruction).
2. **Fix marketplace text:** replace "Phase 1 runs in shadow mode" with a faithful summary of the
   `aar-engineering` `plugin.json` contract — the cross-family `--code` review posts a native GitHub review
   via a **separate reviewer identity** that branch protection requires before merge (**falls back to
   comments if none configured**); generic seam, not a hardcoded `codex-engineer[bot]` claim (design-review F4).
3. **Fix dispatch line:** keep it **substrate-neutral** — "in the experiment dir" → "in its own dedicated
   working dir" (the spawning mechanics are the instance's implementation, already stated by the line above;
   design-review F2). Resolves the post-#30 staleness without baking a new instance convention into the
   product skill. (#30 was instance-side — no product proposal.)

Version bumps: `aar-engineering` (SKILL.md + wf.sh + RUNBOOK.md changed) and `experiment-lifecycle`
(design-experiment SKILL.md changed). Closes #47 and #48.

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
