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

The mechanism to do it right already exists: `WF_ENGINEER_TOKEN_CMD_CLAUDE/_CODEX` resolve the
engineer-identity GitHub App tokens the SWE pipeline already uses for reviews and triage comments. The gap
is a missing **convention**, not a missing capability.

## Approach

Add a Rule to `aar-skills/AGENTS.md` (the product constitution's "Rules" — where cross-cutting agent
conventions live, and where, per the section's own framing, the Rule *is* the discipline and hooks are only
backstops): **an agent that files a GitHub Issue authors it through the family engineer-identity token, the
same identity the SWE pipeline uses for reviews/comments — never the ambient/human `gh` auth.** State the
one-liner so it's copy-pasteable:

```
GH_TOKEN="$(eval "$WF_ENGINEER_TOKEN_CMD_<FAM>")" gh issue create …
```

and note that the `file-feedback` skill already does this, so the rule generalizes that behavior to every
issue an agent opens. (This issue, #89, was itself filed via the token to dogfood it.)

## Alternatives considered

- **A shared `gh_engineer` helper** (mirroring `ship-change`'s internal `gh_author`) so it's enforced by
  reuse, not memory. Better long-term, but it's a larger surface (where it lives, PATH availability across
  substrates and external adopters) than this gap warrants right now; the existing token seam + a Rule
  closes the actual problem. Left as a noted future enhancement on #89, not blocking.
- **A pre-commit/CI check.** Can't see Issue authorship from a diff; wrong layer. The Rules section already
  says the hook is a backstop, not the discipline — the discipline is the Rule.
- **Route everything through `file-feedback`.** Wrong tool for design-decomposition follow-ups and other
  non-feedback issues; the convention should hold regardless of which path opens the issue.

## Blast radius

- One doc: `aar-skills/AGENTS.md` "Rules". No code, no plugin, no behavior change → no `plugin.json` version
  bump (the version-bump check scopes to `plugins/*`; this is a repo-root doc). Affects agent behavior by
  convention, the same way every other Rule does.

## Rollout + rollback

- Pure documentation Rule; rollback is reverting the one addition. No state, no migration.
- Existing human-authored agent Issues are **not** reauthored (GitHub can't change an Issue's author, and
  re-filing would break cross-reference numbers) — explicit non-goal.
