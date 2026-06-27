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

1. **Force-stateless un-anchored sweep, to its OWN artifact.** `run_review` gains `WF_STATELESS_REVIEW=1`,
   which skips the disposition injection. The sweep uses the **dimensional `--code`/`--scaffold` review** —
   which has NO close-mode "prior-round / peer-debate" anchoring (that framing lives only in the research
   `close` audit, never used here) — so combined with the disposition skip it is a genuinely **un-anchored**
   holistic read (re-raises *everything*, anchored to nothing), exactly the read that caught #132's hole. The
   sweep writes a **distinct `wf_fresh_<branch>.md` artifact** (NOT the `wf_code_*`/`wf_scaffold_*` review file
   #139 consumes), and is posted **comment-only, non-gating** (no native `REQUEST_CHANGES`; raw stateless HIGHs
   are not a verdict). Posting makes it durable/recoverable from GitHub (F2/F3).
2. **Candidate-only: the sweep never mutates disposition state or the deterministic gate (F1/F2).** It does NOT
   `fd_seed`, is NOT in `fd_review_high_list`, and is NOT fed to #139's structural gate — feeding its hash-ids
   anywhere deterministic would re-introduce the rephrasing false-block (a reworded dispositioned finding =
   new hash). The structural gate (#139) is **unchanged**.
3. **Semantic adjudication by the merge review, the only place novelty is judged.** The disposition-aware merge
   review is handed the `wf_fresh` findings as *candidates* (via a `FRESH_SWEEP_FILE` env) and asked to surface
   any HIGH **not semantically covered** by a valid disposition — including a pre-existing hole no prior
   finding named. Rephrasings of dispositioned findings are recognized and suppressed by the model; genuinely-
   new holes become **residual HIGH** and block via the existing gate. The author then dispositions the real
   ones (the posted sweep + the residual review are what they triage — F4).

So the pair is: **stateful gate for convergence + a mandatory un-anchored fresh sweep at the merge checkpoint
for completeness, reconciled SEMANTICALLY by the model (never by hash).** No state on a PR → no sweep (today's
stateless behavior is already "all fresh").

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
  findings, so its raw count is meaningless as a gate (it would block every disposition-aware PR). The sweep is
  **candidate input only**; the disposition-aware merge review's *semantic* residual is the gate.
- **Auto-seed the sweep's findings into state by hash.** Rejected (design-review F1): textual novelty ≠
  semantic novelty — a rephrased dispositioned finding would false-block. The model adjudicates novelty.
- **Run the sweep every round (code-review), not just finish.** Deferred: more cost for less leverage; the
  merge checkpoint is where a trusted-past hole would actually escape. `finish` is the load-bearing moment.

## Blast radius

- **`aar-engineering`** (`wf.sh`): `run_review` honors `WF_STATELESS_REVIEW`; `finish` runs the fresh sweep,
  posts it durably, and passes its findings to the disposition-aware merge review for semantic adjudication —
  only for disposition-aware PRs. No-state path byte-identical. Version bump + a smoke.
- **`verify-claims`** (`audit_experiment.sh`): the disposition-aware prompt gains an optional "candidate
  fresh-sweep findings — surface any HIGH not semantically covered by the dispositions" section, fed via an
  env/file when present. Absent → unchanged. **verify-claims version bump** (plugin behavior change — F3).
- **Docs (F2):** `ship-change/SKILL.md` + `wf.sh` help + RUNBOOK state that the fresh sweep is candidate-only,
  must NOT be `fdispo seed`-ed, and that only the residual merge-review findings are dispositioned.
- No behavior change for non-disposition PRs.

## Rollout + rollback

Only affects PRs that opted into disposition-aware state; everything else is byte-identical. Rollback is a
normal revert. With #138 + #139 + #140 landed, the disposition-aware gate is complete: convergent *and*
sharp.
