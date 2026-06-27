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

**Productize the engineer issue-authoring interface as a `wf.sh` subcommand**, so the convention can name a
shipped command, not an instance-only script (round-2 HIGH). Chosen over shipping the standalone
`gh-as-engineer` into the plugin after a cross-model check (Claude + two independent `codex exec` passes all
recommended this) — issue authorship is the same product lifecycle as PR review/comment authorship, so it
should reuse the *one* engineer-token path, not a second implementation.

1. **`wf.sh issue <claude|codex> <gh issue args…>`** — new subcommand, the Issue-side counterpart to
   `wf.sh comment`. Reuses the existing `author_token_optional` + `gh_author` helpers (same
   `WF_ENGINEER_TOKEN_CMD_*` policy, same fail-closed/ambient-fallback behavior as reviews). No worktree
   needed. Added to `usage()`.
2. **Point-of-need — `ship-change` SKILL.md step 0**: the "create the Issue if missing" line (the motivating
   leak — what an agent reads right before filing) now says `wf.sh issue <claude|codex> create …`.
3. **Convention — `aar-skills/AGENTS.md` "Rules"**: agent-filed Issues use the engineer identity; canonical
   interface is `wf.sh issue`; an instance may keep a thin `gh-as-engineer` alias that delegates to it.
4. **Identity contract — RUNBOOK**: document that `wf.sh issue` needs the engineer App to have
   **`issues: write`** (public *and* private, unlike the existing read-only `issues: read` close-gate note).

Plugin files change → `aar-engineering` `plugin.json` version bump. (`gh-as-engineer` and `file-feedback`
stay working unchanged: the instance `gh-as-engineer` becomes a thin alias to `wf.sh issue` same-day after
merge, and `file-feedback` keeps calling `gh-as-engineer` — now one token path underneath.)

## Alternatives considered

- **(b) Ship the standalone `gh-as-engineer` into `aar-engineering`.** Rejected (cross-model consensus): a
  second token-handling path alongside `wf.sh`, two audit surfaces, two things to keep in sync. The thin
  alias delegating to `wf.sh issue` gets the familiar name without the duplicate implementation.
- **AGENTS Rule only / reference the instance-only helper from the product.** Rejected (round-2 HIGH): a
  product skill can't reference a command that isn't shipped — instance→product leak on a fresh install.
- **A new `GH_TOKEN=$(eval …)` spelling.** Rejected (round-1 DRY): reinvents what the token helpers already do.
- **A pre-commit/CI check.** Can't see Issue authorship from a diff; wrong layer.

## Blast radius

- `wf.sh` (new `issue` subcommand + `usage()` line) and `ship-change` SKILL.md step-0 + RUNBOOK + the
  `aar-engineering` `plugin.json` bump; plus `aar-skills/AGENTS.md` "Rules" (repo-root convention). The new
  subcommand is additive — it reuses existing token helpers and touches no other code path, so the lifecycle
  (start/open/review/finish) is unaffected. Instance `gh-as-engineer` + `file-feedback` keep working.

## Rollout + rollback

- Pure documentation Rule; rollback is reverting the one addition. No state, no migration.
- Existing human-authored agent Issues are **not** reauthored (GitHub can't change an Issue's author, and
  re-filing would break cross-reference numbers) — explicit non-goal.
