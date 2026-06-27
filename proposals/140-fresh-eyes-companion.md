# Proposal: fresh-eyes companion sweep (#140)

> Implements **#137** slice 3 of 3 (after #138 structural gate + #139 disposition-aware integration). The
> mandatory backstop that keeps the now-live disposition-aware gate from trusting a *pre-existing* hole past.

## Problem

The disposition-aware gate (#139) makes review **stateful**: it suppresses findings the author has validly
dispositioned. That is what gives convergence — but it has a known blind spot, demonstrated on PR #132: the
disposition-aware reviewer checks dispositions + newly-introduced defects; it does **not** do a fresh
holistic read for a defect that was **present from the start and never surfaced**. On #132, two fresh
*stateless* sweeps after the disposition-aware gate passed still found a genuine shape-level HIGH. So a
stateful gate alone can silently trust past a pre-existing hole.

## Approach

At **`finish`**, for a disposition-aware PR, run ONE **fresh stateless sweep** *before* the structural gate,
and fold its findings into the canonical state. Concretely:

1. **Force-stateless review.** `run_review` gains `WF_STATELESS_REVIEW=1`, which skips the disposition
   injection so the reviewer does a full, amnesiac dimensional read (it re-raises *everything*, including
   already-dispositioned findings). Run it with an empty PR arg so it produces findings without posting.
2. **Seed the gaps.** `fd_seed` folds the sweep's findings into the state — and by construction only *new*
   ids (findings never seen before = the pre-existing holes) are added, as `unresolved`; already-dispositioned
   findings keep their disposition (same content → same id → not re-added).
3. **The sweep's findings become the structural gate's trusted list.** The existing #139 structural gate then
   runs over the **complete** reviewer-derived HIGH set (the fresh sweep), so a pre-existing HIGH that is now
   `unresolved` BLOCKS — the author must disposition it. This also *strengthens* #139: the trusted list is now
   the full current findings, not just the last code-review round's.
4. The disposition-aware merge review (the model gate) then runs as today and blocks on residual HIGH.

So the pair is: **stateful gate for convergence + a mandatory fresh stateless sweep at the merge checkpoint
for completeness.** No state on a PR → no sweep (today's stateless behavior is already "all fresh").

### Cadence

"Once before merge" (in `finish`) is the enforced checkpoint — mandatory and automatic, so it can't be
skipped. First-submission is already fresh (the first `code-review` has no state yet). This is one extra
review per `finish` attempt — acceptable at the merge gate, and it is what makes the structural backstop
sound rather than self-referential.

## Alternatives considered

- **A `wf.sh fresh-sweep` subcommand the author runs manually.** Rejected: the #137 design calls this a
  *mandatory* backstop; an opt-in step gets skipped exactly when convergence pressure is highest. Auto-in-
  `finish` is enforceable.
- **Block directly on the stateless sweep's raw HIGH count.** Rejected: stateless re-raises dispositioned
  findings, so its raw count is meaningless as a gate. The sweep *feeds the state* (only new ids become
  `unresolved`); the existing structural + model gates do the blocking.
- **Run the sweep every round (code-review), not just finish.** Deferred: more cost for less leverage; the
  merge checkpoint is where a trusted-past hole would actually escape. `finish` is the load-bearing moment.

## Blast radius

- **`aar-engineering`** (`wf.sh`): `run_review` honors `WF_STATELESS_REVIEW`; `finish` runs the fresh sweep +
  seed before the structural gate for disposition-aware PRs. No-state path unchanged. Version bump + a smoke.
- No change to `verify-claims` (reuses the existing review engine, just invoked stateless).
- Strengthens #139's structural gate (complete trusted list) — no behavior change for non-disposition PRs.

## Rollout + rollback

Only affects PRs that opted into disposition-aware state; everything else is byte-identical. Rollback is a
normal revert. With #138 + #139 + #140 landed, the disposition-aware gate is complete: convergent *and*
sharp.
