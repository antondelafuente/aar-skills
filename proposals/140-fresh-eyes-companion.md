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

At **`finish`**, for a disposition-aware PR, run ONE **fresh stateless sweep** *before* the disposition-aware
merge review, and let the **model** (not a hash) decide which of its findings are genuinely new. Novelty is
SEMANTIC, not textual — a rephrased version of an already-dispositioned finding must NOT block (design-review
F1). Concretely:

1. **Force-stateless un-anchored sweep.** `run_review` gains `WF_STATELESS_REVIEW=1`, which skips the
   disposition injection so the reviewer does a full, amnesiac holistic read (re-raises *everything*, anchored
   to nothing). This un-anchored read is exactly what caught #132's pre-existing hole that the
   disposition-anchored review trusted past. **Its output is POSTED as a durable PR comment** (design-review
   F2), so a fresh agent can triage it from GitHub, not just a `/tmp` file.
2. **Semantic adjudication by the merge review, not hashing.** The disposition-aware merge review is given the
   sweep's findings as candidate items and asked to surface any HIGH **not semantically covered** by a valid
   disposition — including a pre-existing hole no prior finding named. Rephrasings of dispositioned findings
   are recognized and suppressed by the model; genuinely-new holes become **residual HIGH** and block via the
   existing gate. The author then dispositions the real ones.
3. No hash-based auto-seeding of the sweep into the state (that equated textual novelty with real novelty —
   F1). The author may still `fdispo seed` to record a confirmed-new finding; the *gate* relies on the model's
   semantic judgment, backstopped deterministically by #139's structural gate over whatever the author did
   disposition.

So the pair is: **stateful gate for convergence + a mandatory un-anchored fresh sweep at the merge checkpoint
for completeness, reconciled semantically by the model.** No state on a PR → no sweep (today's stateless
behavior is already "all fresh").

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

- **`aar-engineering`** (`wf.sh`): `run_review` honors `WF_STATELESS_REVIEW`; `finish` runs the fresh sweep,
  posts it durably, and passes its findings to the disposition-aware merge review for semantic adjudication —
  only for disposition-aware PRs. No-state path byte-identical. Version bump + a smoke.
- **`verify-claims`** (`audit_experiment.sh`): the disposition-aware prompt gains an optional "candidate
  fresh-sweep findings — surface any HIGH not semantically covered by the dispositions" section, fed via an
  env/file when present. Absent → unchanged.
- No behavior change for non-disposition PRs.

## Rollout + rollback

Only affects PRs that opted into disposition-aware state; everything else is byte-identical. Rollback is a
normal revert. With #138 + #139 + #140 landed, the disposition-aware gate is complete: convergent *and*
sharp.
