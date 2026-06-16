# Proposal: `ship-change` — the codified PR → code-review → merge pipeline (SWE engine)

> Design-of-the-change + ADR + PR description. Reviewed by `--scaffold` before build.

## Problem

The PR → code-review → response → merge pipeline was proven once (PR #1) but entirely by hand. Nothing is
codified: no skill does "branch → checks → PR → cross-family code review → respond → auto-merge → refresh."
Every future scaffold change — especially the high-risk home→orchestrator repo restructure — should be gated,
reviewed, and rollback-able *automatically*, not by an agent remembering the steps. We need the reusable
engine before the big migrations, so they ride a safety net instead of bespoke care.

## Approach

Add an **internal engineering plugin** to aar-skills — the SWE-pipeline layer, distinct from the shipped
research product (gpu-job / verify-claims / experiment-lifecycle). Same repo, separate layer:

```
plugins/aar-engineering/
  .claude-plugin/plugin.json
  skills/
    ship-change/    SKILL.md (+ scripts/)   ← this proposal
    propose-change/ SKILL.md                 ← next proposal, built via ship-change
```

**`ship-change`** is the autonomous back-half engine (the SWE counterpart to `run-experiment`). Contract, given
a repo with the intended changes in its working tree and the author family known:

```
1. check git status (changes present; base is clean main)
2. create a branch
3. run DETERMINISTIC CHECKS (the test layer — see below); BLOCK on fail
4. commit (path-scoped) + push the branch
5. open a PR (gh)
6. run a CROSS-FAMILY code review on the diff (Codex if author=Claude, Claude if author=Codex — mechanical)
7. post the review findings + author responses (ACCEPT/fix/DEFER) to the PR
8. apply the MERGE RULE; auto-merge if it passes, else surface to the human
9. pull main; refresh installed plugins if a plugin version changed
```

**Merge rule (auto-merge iff ALL hold):**
```
deterministic checks pass
AND cross-family review completed
AND every finding has a response (fix / accept / defer-with-reason)
AND no unresolved HIGH
AND no explicit human hold
→ auto-merge (squash). Otherwise: surface the blockers to the human, leave the PR open.
```

**Same-family routing is mechanical:** the skill reads the author family and points the reviewer at the OTHER
family (Claude-authored → Codex review; Codex-authored → Claude review), the same `AAR_SUBSTRATE`/`AUDIT_VERIFIER_CMD`
mechanism `--scaffold` already enforces.

**Deterministic checks (the test layer — start here, keep the pyramid sane):**
- JSON validity for every changed `plugin.json` / `marketplace.json`
- `bash -n` on changed shell scripts; `python3 -m py_compile` on changed Python
- no instance-path leak in product plugins (`~/orchestrator`, `/home/anton`, model/recipe names)
- version bump present when a plugin's behavior changed (changed `scripts/` or `SKILL.md` ⇒ `plugin.json` version moved)
These run BEFORE the cross-family review (cheap gate first). Behavior tests (fake-HOME install / agent discovers a
skill / emits expected artifacts) come next; golden GPU tests deferred until cheap CI exists.

## Alternatives considered

- **Keep it manual** — rejected: doesn't scale, and the repo restructure needs an automatic safety net, not bespoke care.
- **One mega-skill for the whole lifecycle** (propose+ship) — rejected: split the together-stage (`propose-change`,
  human-in-loop) from the autonomous ship-stage (`ship-change`), mirroring `design-experiment` / `run-experiment`.
- **Use only the built-in `/code-review`** — rejected as the sole reviewer: keep the cross-family review for
  consistency with the rest of the system and because it caught real bugs on PR #1. (`/code-review` may be added as an
  extra deterministic lens later.)
- **Put the eng skills in their own repo** — rejected for now: one product, one repo; the SWE pipeline is aar-skills'
  engineering layer (revisit only when a piece ships independently).

## Blast radius

Additive: a new plugin (`aar-engineering`) + one skill + a checks script. No existing plugin or caller changes.
Consumers: any AAR shipping a scaffold change — they gain a one-command pipeline. Hard dependency: `gh` (installed)
+ the token in `~/.env`. The behavior change is that scaffold changes now land via gated PRs (auto-merged when clean)
instead of direct pushes — which is the point. It operates on whatever repo it's pointed at (aar-skills, orchestrator,
the home restructure), so it's reusable across all of them.

## Rollback

Fully reversible. The plugin is additive (uninstall / don't invoke). Auto-merge is rollback-able per change (each is a
squash-merged PR → `git revert` or branch-delete). If the merge rule misbehaves, tighten it or fall back to manual
PR/merge. Nothing it does is one-way.

## Bootstrap

`ship-change` can't ship through itself (it doesn't exist yet). So: write this proposal → `--scaffold` it → build
`ship-change` → **manually** PR/review/merge it one last time → then use `ship-change` to ship `propose-change`, and
every change after that (the framing doc, the home→orchestrator restructure, …) rides the pipeline.

## Design-review response (round 1, --scaffold) — all 7 accepted; design amended

- **F1 (HIGH, human-stop):** the human arbitration is UPSTREAM at `propose-change` (the design stage). By the time
  `ship-change` runs, the design is cleared; it auto-merges the IMPLEMENTATION, and any **HIGH code-review finding
  still blocks + surfaces**. Keep auto-merge (Anton's decision); state the stop is at the design stage.
- **F2 (HIGH, shared-tree safety):** `ship-change` takes an **explicit changed-path list**, stages ONLY those paths,
  and **FAILS if any unrelated file is dirty** in the shared tree. No "ship the working tree."
- **F3 (MED, behavior gate):** auto-merge does NOT go live until the **fake-HOME behavior smoke** (plugin install →
  skill discovery → emits expected artifacts) exists and gates plugin/skill changes (Anton chose option (a): build
  the smoke first). Deterministic checks alone can't catch an install/discovery break.
- **F4 (MED, auth seam):** GitHub auth comes from **`gh`'s own auth** (`GH_TOKEN` in the instance env / `gh auth`), not
  a hardcoded `~/.env`. The skill documents the auth requirement; the instance supplies it.
- **F5 (MED, right seam):** split the **generic PR engine** from a **per-repo check profile** (e.g. `<repo>/.aar-ci/`)
  — the same profile-seam as run-experiment's execution profile. aar-skills, orchestrator, and the home restructure
  each supply their own check set.
- **F6 (MED, DRY):** the diff code review is a **new `audit_experiment.sh --code` mode in verify-claims** (canonical
  home for all cross-family review); `ship-change` CALLS it, owns no second review harness.
- **F7 (LOW, discovery):** touched surface includes `.claude-plugin/marketplace.json` (the new `aar-engineering`
  entry) + README + CHANGELOG, or the plugin is undiscoverable.
