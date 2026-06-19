# Proposal: agent-filed issues use the engineer identity, not the human's (#89)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

#62 fixed the **`file-feedback`** skill to author agent-filed Issues as the engineer bot. But agents open
Issues in **other contexts** too — ad-hoc backlog, `ship-change` design decompositions, follow-ups — via
raw `gh issue create`, which falls back to ambient `gh` auth (= the human owner). So those Issues come out
authored by the human, not `*-engineer[bot]`.

Concrete: the two-track skill-staleness decomposition filed #65, #66, #68–#73 via raw `gh issue create`
during agent work — all authored by the human owner. The #62 fix didn't cover them because it was scoped to
one skill, not the convention.

The canonical interface already exists: **`gh-as-engineer <claude|codex>`** — the issue-side counterpart to
`ship-change`'s `wf.sh comment`, which mints the engineer-identity token (`WF_ENGINEER_TOKEN_CMD_<FAM>`) and
runs `gh` as `*-engineer[bot]`. `file-feedback` already routes through it. The gap is a missing
**convention** plus one un-migrated point-of-need — not a missing capability or a new tool.

## Approach

Two coordinated edits, both pointing at the existing `gh-as-engineer` helper (no new spelling):

1. **Convention — `aar-skills/AGENTS.md` "Rules"** (where cross-cutting agent conventions live, and where
   the Rule *is* the discipline and hooks are only backstops): an agent that opens or comments on a GitHub
   Issue does it through `gh-as-engineer <claude|codex> issue create …`, never ambient/human `gh`.
2. **Point-of-need — `ship-change` SKILL.md step 0**: the "create the Issue if it doesn't exist" line said
   raw `gh issue create …` (the motivating leak — it's what an agent reads right before filing). Change it
   to `gh-as-engineer <claude|codex> issue create …`. This is a plugin file change → `aar-engineering`
   `plugin.json` version bump.

So all three agent issue-authoring sites — `file-feedback`, `ship-change` step 0, and the AGENTS rule that
covers everything else — name the *same* canonical helper. (This issue, #89, was itself filed via
`gh-as-engineer claude` to dogfood it.)

## Alternatives considered

- **A new `GH_TOKEN=$(eval …)` spelling in AGENTS** (the first draft). Rejected on review (DRY): it
  introduced a second way to do what `gh-as-engineer` already does. One canonical interface, named
  everywhere.
- **AGENTS Rule only, leave `ship-change` step 0 as raw `gh`.** Rejected on review (the HIGH): it leaves
  the exact point-of-need that motivated the issue still authoring as the human — a Rule the nearest
  instruction contradicts. The point-of-need must move too.
- **A pre-commit/CI check.** Can't see Issue authorship from a diff; wrong layer. The Rules section already
  says the hook is a backstop, not the discipline.
- **Route everything through `file-feedback`.** Wrong tool for decomposition follow-ups and other
  non-feedback issues; the convention should hold regardless of which path opens the Issue.

## Blast radius

- `aar-skills/AGENTS.md` "Rules" (repo-root convention) + `ship-change` SKILL.md step-0 line + the
  `aar-engineering` `plugin.json` version bump that the SKILL change requires. Documentation/convention
  only — no script logic changes; `gh-as-engineer` already exists and is unchanged. Affects agent behavior
  by convention, the same way every other Rule does.

## Rollout + rollback

- Pure documentation Rule; rollback is reverting the one addition. No state, no migration.
- Existing human-authored agent Issues are **not** reauthored (GitHub can't change an Issue's author, and
  re-filing would break cross-reference numbers) — explicit non-goal.
