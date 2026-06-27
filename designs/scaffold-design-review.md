# Proposal: cross-family DESIGN REVIEW for scaffold/product changes (`audit_experiment --scaffold`)

> This doc is three things at once: the **design-of-the-change** (reviewed by `--scaffold` before build),
> the **ADR** (the durable record of why), and the **PR description**. The convention this proposal
> establishes is: an architectural scaffold change gets a short proposal doc like this one, reviewed by a
> foreign model family, before it lands.

## Problem

Scaffold/product changes (skills, CLAUDE.md/AGENTS.md, migration plans, new conventions) have been
design-reviewed by a human manually routing the proposal to ChatGPT and relaying findings back. That
manual routing is overhead; the *cross-family review* it provides is the keeper. Meanwhile experiments
already have a formal cross-family design review (`audit_experiment --design`) — scaffold changes don't.
The gap: no formalized, low-friction design review for the high-blast-radius product changes, so the
human is the router and the review is judgment-dependent.

## Approach

**Same machinery, different rubric.** Add a `--scaffold` mode to `audit_experiment.sh` (which already has
`--design` / `--data` / close — adding a mode is the established extension). It reuses the entire harness:
the cross-family enforcement, the constitution (`AGENTS.md`), the FINDING/SUMMARY output, the prior-round
peer-debate clause, the read-only sandboxed foreign-family runner (Codex by default — the *scriptable*
same-family-as-ChatGPT reviewer, so the human stops being the relay). Only two things change vs `--design`:

1. **The rubric** — architecture dimensions instead of experiment-validity ones: right seam/abstraction;
   DRY / does a canonical home already exist; blast radius / dependents; reversibility; instance↔product
   leak; interface/contract clarity for a zero-context consumer; simplest-thing / scope; convention-match.
2. **The input** — a *proposal doc* (this file's shape) instead of a `DESIGN.md`, plus a context dir the
   auditor reads to verify claims like "no home exists" / "this is the convention" against the real tree.

The loop is identical to experiments and unchanged: foreign family → findings → author triages as a PEER
(ACCEPT/DISPUTE/DEFER) → surface survivors to the human → human arbitrates (convergence stop). It is a
DESIGN review (the approach, before/at build), complementary to the CODE review (`/code-review`) on the
resulting diff at PR time. Architectural changes get both; implementation-only changes get just the PR.

Usage: `AAR_SUBSTRATE=<author-family> audit_experiment.sh --scaffold <proposal.md> [context-dir] [out]` →
`<proposal>.SCAFFOLD_AUDIT.md` (a proposal-specific sidecar; context defaults to the git root).

## Alternatives considered

- **A brand-new skill** for scaffold review — rejected: it duplicates the cross-family harness + the
  triage→surface→arbitrate loop we already have. Reinvention.
- **PR review as the only review** (let `/code-review` on the diff double as the design review) — rejected
  for *architectural* changes: a reviewer anchored on a finished, polished diff nitpicks lines instead of
  questioning the seam. Design review on prose, before the diff exists, keeps the altitude right. (Kept as
  the sole review for implementation-only changes.)
- **Hidden `~/.config` for the review rubric / a separate config** — N/A here; the rubric lives in the
  script like the other modes' rubrics.

## Blast radius

Additive: a new mode in one script (`audit_experiment.sh`, verify-claims plugin). The other three modes
are untouched (same arg-parse, same runner). No existing caller changes. Consumers: any AAR proposing a
scaffold change — they gain a mode, lose nothing. The proposal-doc convention is opt-in per change.

## Rollback

Delete the `--scaffold` branch from the mode parse + the PROMPT block; the script reverts to 3 modes. The
`proposals/` dir and any SCAFFOLD_AUDIT.md are inert records. Fully reversible.

## Bootstrap note

This is the one change that can't be reviewed by `--scaffold` *before* it's built (chicken-and-egg), so for
THIS change only: build it, then run `--scaffold` on this very proposal as the first dogfood, triage,
surface to the human, and land via PR + `/code-review`. Every future architectural change reviews its
proposal before the build.

## Design-review response (round 1 — the dogfood)

`--scaffold` was run on this proposal (Codex, foreign family). 4 findings (2 HIGH, 2 MED); author triage:

- **F1 (HIGH, seam — cross-family gate keys on runner not author):** ACCEPT gap / DISPUTE fix. The gate
  already enforces auditor != author (`RUNNER_FAMILY = AAR_SUBSTRATE = the AAR running --scaffold = the
  proposal author`). Fix = clarify the comment for scaffold; NOT a new `SCAFFOLD_AUTHOR_FAMILY` var (would
  duplicate `AAR_SUBSTRATE` — a DRY violation).
- **F2 (HIGH, contract — default context = proposal dir blinds the auditor):** ACCEPT. Default context to the
  **git/worktree root**, not the proposal's dir.
- **F3 (MED, blast radius — a mode ships hidden without skill/plugin surface):** ACCEPT. This change also
  touches SKILL.md (mode doc), plugin.json (version bump), CHANGELOG — corrected blast radius.
- **F4 (MED, instance leak — empty `$HOME/AGENTS.md` → toothless review off-box):** ACCEPT. Load the context
  repo's `AGENTS.md` by default / fail loud on empty constitution for `--scaffold`.

### Round 2 (the loop caught my round-1 error)

Re-run with my responses visible. It **conceded F4** (and the proposal-quality check), and **correctly escalated F1**
— my round-1 dispute was wrong: `AAR_SUBSTRATE` *defaults* to `claude`, so a Codex author who doesn't set it gets a
Codex auditor = same family, not cross-family. Fixes applied:
- **F1 (HIGH):** `--scaffold` now REQUIRES `AAR_SUBSTRATE` explicitly (no `claude` default) — it blocks otherwise, so the
  cross-family gate can't be silently bypassed.
- **F2 (MED):** output is a proposal-specific sidecar (no root collision); the prompt now uses the proposal's path
  relative to the context root, not bare basename.
- **F3 (MED):** `--scaffold` added to the SKILL **frontmatter** + marketplace description (the discovery surfaces),
  not just the body.
