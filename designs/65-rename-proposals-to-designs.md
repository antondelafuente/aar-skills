# Design: rename the design-doc convention `proposals/` → `designs/` (#65)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Ship-change design docs live under `proposals/<issue>-<slug>.md`, but they are not proposals in
the gated-bid sense — they are the design record (ADR) for a change, written and then implemented.
"Designs" reads more accurately, and #50 (design-review-as-a-gate) already calls the location "a
designs folder," so the code and the language already disagree. This renames the directory to
`designs/` and updates every load-bearing reference so the convention and the words match.

## Approach

A mechanical rename with history preserved:

- `git mv proposals/ designs/` — moves all ~51 existing design docs plus this doc, preserving git
  history via rename detection.
- `wf.sh` — update every functional path: the `start` `DOC=proposals/...` it prints and creates, the
  doc-discovery globs in `open`/`design-review`/`classify`, the `--design` doc-only merge gate's
  `proposals/*.md` allow-pattern (so a doc-only design PR still passes), and the header comment. New
  docs are created under `designs/`; doc-discovery and the `--design` gate **also accept a legacy
  `proposals/*.md`** path so an in-flight sibling worktree (a concurrent ship-change run that started
  before this merges) can still finish without manual surgery — a bounded back-compat read, not a
  parallel write path.
- `identity_smoke.sh` — the self-contained smoke test builds throwaway repos with a `proposals/`
  doc; rename those fixtures to `designs/` so the smoke exercises the new convention end to end.
- `SKILL.md` — the three `proposals/` references (the `start` example, the write-the-doc line, the
  `--design` fail-closed rule).
- `.aar-ci/classifier.conf` — the architectural-path glob `proposals/*` → `designs/*` (a design doc
  is still an architectural artifact).
- `.gitignore` — `proposals/*SCAFFOLD_AUDIT*.md` → `designs/*SCAFFOLD_AUDIT*.md`.
- `plugins/aar-engineering/.claude-plugin/plugin.json` — version bump (a documented-interface
  change to the ship-change workflow), per AGENTS.md "Version bump on every behavior change."

Explicitly NOT changed: prose uses of the English word "proposal" in `CHANGELOG.md` and
`marketplace.json` ("design review of product/scaffold change proposals") — those are not the path
and stay as written.

## Alternatives considered

- **Keep `proposals/`, change only the docs that call it "designs."** Rejected: it leaves the
  inaccurate name in the load-bearing path and perpetuates the code/language mismatch the issue flags.
- **Symlink `proposals/` → `designs/` for back-compat.** Rejected as overkill: all references are
  in-repo and updated atomically in this PR. The one real consumer of the old path is an in-flight
  sibling worktree mid-ship-change; that is handled by the bounded legacy-`proposals/` read in
  doc-discovery and the `--design` gate above, which is lighter than a filesystem symlink and
  expires naturally once those branches drain.

## Blast radius

The SWE pipeline only — the ship-change lifecycle. No research-product skill or instance state is
touched. The one runtime-visible effect: `wf.sh start` now prints/creates `designs/<N>-<slug>.md`,
and the `--design` doc-only gate now matches `designs/*.md`. Both are changed in the same diff, so
there is no window where the path the gate expects and the path `start` creates disagree.

## Rollout + rollback

Single squash merge; no staged rollout needed. Rollback is the standard one-command revert of the
merge commit (RUNBOOK "One-command revert"), which restores both the directory name and every
reference together.
