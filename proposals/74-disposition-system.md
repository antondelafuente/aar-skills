# Proposal: a disposition-label system for the issue tracker (#74)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> **This is the first two-phase design** — its output is this doc + a set of spawned `ready` issues.

## Problem

Every incoming issue is hand-judged into "straightforward, just do it" vs "needs a design pass first" vs
"vague wish I'm not sure about." That judgment lives only in someone's head each time. The existing labels
(`bug` / `enhancement` / `documentation` / `onboarding`) are all **type/topic** — none encode an issue's
**disposition** (how it should be handled), which is the axis that decides what happens next.

This is the **substrate for three open issues**: #28 (one-time tracker cleanup) would *apply* the scheme,
#49 (standing triage + auto-handling) would *act* on it, and #50 (design-as-a-gate) is the engine that
*produces* `ready` issues from `needs-design` ones. They each currently presume a classification that doesn't
exist. Define it once, here.

Evidence it's needed: a survey of the old `~/orchestrator/AAR_BACKLOG.md` (16 substantive items) showed the
three obvious buckets capture the main axis but miss two recurring states — `blocked` (decided-but-gated, the
*most common* state there) and `parked` (real-but-not-now) — and that the truly-`ready` (auto-handleable)
slice is small. (Full survey: this issue's comment thread.)

## Approach

### 1. The disposition axis (six labels)

A single **disposition** label per open issue, orthogonal to the existing type labels AND to GitHub's
open/closed lifecycle:

- **`ready`** — straightforward, no design needed, low blast radius. Implement + merge on the cross-family
  review + checks alone. The **only** bucket auto-handling (#49) may act on autonomously.
- **`needs-design`** — real and wanted, but requires a design pass before any code (see the two-phase engine
  below). Implementation is gated until the design lands.
- **`needs-shaping`** — a direction, not yet actionable; too vague to start. Needs scoping into something
  concrete before it can become `ready` or `needs-design`.
- **`blocked`** — decided and ready *in itself* but gated on a prerequisite (another issue, an extraction,
  an upstream). Carries a **`blocked-by: #N`** pointer in the body. Distinct from `needs-design` (the design
  is done) and `needs-shaping` (it's clear).
- **`parked`** — real but deliberately not-now. Distinct from `needs-shaping` (too vague) and from `wontfix`
  (never). Next action: revisit later.
- **`other`** — catch-all / taxonomy-gap signal: this issue's disposition doesn't fit the five above. A
  recurring `other` is the trigger to evolve the vocabulary (the escape hatch that keeps the scheme honest).

Disposition is **mandatory and exactly-one** per open issue — an issue with zero (or two) is what enforcement
flags. **Default for an un-triaged new issue:** no disposition label = "not yet triaged" (visibly distinct
from `needs-shaping`, which is a *judged* "too vague"). Triage's job is to give every un-triaged issue exactly
one disposition.

**Size is a separate axis, not a disposition** — a `needs-design` item can be an afternoon or a multi-week
program. If routing ever needs quick-win-vs-epic, that's a future `large`/`epic` label, out of scope here.

### 2. The two-phase design engine (this supersedes #50's one-phase lean)

A `needs-design` issue is not implemented directly. It goes through a **design phase** (the `finish --design`
tooling, shipped in #75) whose deliverable is a PR that:
1. lands a **design doc** (in `proposals/` today; the `proposals/ → design/` rename is its own tracked
   ticket), and
2. is **approved by the opposite-family engineer** via the `--scaffold` merge gate — same approval model as a
   code PR; the human steers at *authoring* time, not at merge, and
3. **spawns a set of `ready` issues** — the design's decomposition into implementable units.

Implementation = picking off those `ready` issues as normal single-phase ship-change runs (auto-handleable by
#49 because they're `ready`). So the design phase is the forcing function that *converts* one fuzzy
`needs-design` thing into N crisp `ready` things. **This is a change of direction from #50 as written** (which
leaned to *one* PR with a design-gate blocking the implementation commit, architectural-only); #50 gets
rewritten around this two-phase shape.

**The decomposition contract:** a design doc carries a `## Spawned issues` section listing the `ready` issues
its design implies; the design author files them after the design PR merges. Mechanical enforcement (refuse to
call a design "done" until its `ready` issues exist) is **deferred** — it's a forcing-function decision for a
later iteration, recorded here as a known follow-up, not built now (keep this first design's footprint
process-level).

### 3. Enforcement — staged (no new CI infra to start)

The repo has **no GitHub Actions / required-status-checks** today; enforcement is branch protection (1
cross-family review) + the driver-side `wf.sh` gates + process discipline. The classifier and design-gate are
deliberately *recorded, not blocking*. Match that trajectory:

- **Phase 1 (now) — process / advisory.** `file-feedback` assigns a disposition at filing; `triage-feedback`
  maintains it (backfill, the `blocked → ready` transition when a blocker closes, re-disposition). Recorded,
  not mechanically blocking — matches how the classifier already works, zero new infra, immediately useful.
- **Phase 2 (next) — driver-side teeth, reusing `wf.sh`.** (a) `ship-change finish` refuses to merge a PR
  that closes a `needs-design` issue unless its design landed (**this advances #50**); (b) #49's auto-handler
  acts on `ready` only; `blocked`/`needs-shaping`/`parked`/`other` are never auto-handled. No GitHub Actions
  needed — driver-side, like the rest of the pipeline.
- **Phase 3 (later, only if process slips) — a GitHub Action** for the exactly-one-disposition invariant +
  `blocked → needs-triage` auto-flip. Pairs with the already-planned RUNBOOK follow-up to make `.aar-ci` /
  `design-gate` *required status checks*. Explicitly out of scope until earned.

### 4. Canonical home for the rules

The disposition vocabulary + the assign/maintain/enforce rules live in **one** canonical place — a short
section in `AGENTS.md` (the agent-neutral constitution) — referenced by `file-feedback` (assigns) and
`triage-feedback` (maintains). One home per fact; the skills point at it.

## Spawned issues (this design's `ready` decomposition)

On merge, this design spawns these `ready` issues (each a normal single-phase ship-change run):

1. **Create the six disposition labels** (+ colors) via `gh label create`. (Instance/mechanical.)
2. **Document the vocabulary + rules in `AGENTS.md`** (the canonical home) — product.
3. **Wire `file-feedback`** to assign a disposition at filing (instance skill).
4. **Wire `triage-feedback`** to maintain dispositions: backfill, `blocked → ready` transitions, re-disposition
   (instance skill).
5. **Backfill the ~20 open issues** with dispositions (one-time triage) — folds into / coordinates with #28.
6. **#49**: auto-handler acts on `ready` only — update #49's scope to key off this label.
7. **#50**: rewrite around the two-phase engine (this design supersedes its one-phase lean); wire the Phase-2
   `finish` design-gate.

Items 5/6/7 are amendments to existing issues (#28/#49/#50), not new tickets — they get the `ready` (or
`needs-design`, for #50's rewrite) disposition and a pointer back here.

## Alternatives considered

- **Three buckets (`ready`/`needs-design`/`needs-shaping`) only.** Rejected by the backlog survey: `blocked`
  and `parked` recur and are mis-served by folding into the three (a `blocked` item is not `needs-design`; a
  `parked` item is not `needs-shaping` or `wontfix`).
- **A default disposition of `needs-shaping` for new issues.** Rejected: conflates "nobody judged this yet"
  with "judged, and it's vague." No-label = un-triaged is the cleaner default.
- **Big-bang GitHub-Actions enforcement.** Rejected: no Actions infra exists; process + driver-side teeth
  match the current trajectory and need none. The Action is a Phase-3 option only if process slips.
- **Keep #50 one-phase (design-gate blocks the implementation commit in one PR).** Rejected per the user: the
  two-phase shape (separate design PR → spawned `ready` issues) is cleaner and is what the design output should
  be — a doc + a decomposition, not just "approval to proceed."

## Blast radius

This *design* PR is doc-only (lands this doc via `finish --design`). Its **spawned** `ready` issues touch:
`AGENTS.md` (product), `file-feedback` + `triage-feedback` (instance skills), GitHub labels (instance), and
amendments to #28/#49/#50. No code changes in this PR itself. SWE-pipeline + tracker-process layer.

## Rollout + rollback

This is the **first two-phase design** — it dogfoods `finish --design` (#75) end-to-end: doc-only PR, gated on
the cross-family `--scaffold` approval, merged, then the `ready` issues filed. Each spawned issue rolls out
independently via its own ship-change run; Phase 1 (process) is reversible by dropping the labels and the
skill instructions; Phases 2/3 are gated behind their own issues. Rollback of this design = revert the doc and
close the spawned issues.
