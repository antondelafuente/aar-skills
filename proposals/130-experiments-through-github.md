# Proposal: experiments through GitHub — design + close review as PR reviews (#130)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (Step 2 of 2); spawns `ready` issues for the skill edits.

## Problem

Today an experiment leaves no browsable trail. Anton can't see what was run, the design and reasoning
behind it, the two cross-family audits, or where the data/evals live — he has to ask an agent. The
experiment lifecycle's two gates (the `audit_experiment --design` check before a run, the close audit
after) are produced as **local files** inside a shared working tree: invisible, un-versioned-per-experiment,
and impossible to read like a record. The engineering side already solved exactly this — `ship-change`
makes every scaffold change a branch + PR with both reviews posted to GitHub — but the *research* side,
which is the actual product, has no equivalent.

## Approach

Run experiments **through GitHub**, mirroring `ship-change`: **an experiment = a branch = a PR**, and
GitHub becomes the index ("what did I run, the design, the reviews, the data pointers"). The PR reuses the
existing cross-family research-audit engine (`audit_experiment --design` and the close `audit_experiment`),
posting each as a PR review at its lifecycle point. `main` of the instance's research repo only ever
receives finished, reviewed experiments.

This is **distinct from `ship-change`'s gates** — it borrows the cross-family review *engine* and the
branch/PR/posting *mechanics*, but it is the research lifecycle, not a scaffold change. It is not governed
by ship-change's disposition close-gate; the experiment PR merges on its own contract (below). The two are
siblings over one review engine.

The four load-bearing decisions:

### 1. Shape — one PR per experiment carrying design → records → close

An experiment is a **single unit with no fan-out**: one design, one run, one record. The scaffold's
issue→design-PR→spawned-`ready`-children split exists *because* a design spawns multiple implementation
units; an experiment spawns none, so that split only doubles the bookkeeping (two artifacts, two merges).

So: a single `run/<exp>` PR (the branch from Step 1's per-experiment worktree). The PR opens with
`DESIGN.md`, accumulates records as commits, closes with the close audit, and merging it = "experiment
done and reviewed." A lightweight backlog **issue** still seeds the experiment (the idea in the queue), but
it is the trigger the PR closes, not a second lifecycle artifact. The PR's open-duration equals the
experiment's duration — that long-lived draft PR *is* the in-flight visibility surface, and the
design→execute agent seam (different agents, opposite dispositions) maps cleanly onto "who pushes which
commits to the one branch."

### 2. Design review GATES the run; close review does NOT gate (the principled asymmetry)

The constitution already requires the design be **cleared before the run** ("clear the design with Anton
before running it"; the design-audit is the last step of DESIGN-together). #130 does not add a new gate — it
**relocates that existing clearance onto the PR**. The cross-family `audit_experiment --design` is posted to
the PR, Anton arbitrates the survivors, and only then is the zero-context executor handed `START.md` and
spawned. Design approval blocks the run.

The **close** review is the opposite: posted at the end, **async and non-blocking** — merge-on-clean. The
asymmetry is principled, not incidental: a bad *design* wastes the whole run (and any API/data-gen spend, the
real cost — GPU is cheap), so it must gate; a bad *close* review just needs follow-up, the run already
happened, and blocking teardown on a review would strand pods/cost.

### 3. Skill placement — the seam maps onto the branch, unchanged in spirit

- **`design-experiment`** gains: commit `DESIGN.md` to `run/<exp>`, open the draft PR, request and post the
  `audit_experiment --design` review, drive to Anton's clearance, then write `START.md` and hand off.
  (The design-audit it already runs simply becomes "posted as the PR review.")
- **`run-experiment`** gains: the executor pushes records (`RESULTS.md`, audit notes, ledger/R2/artifact
  pointers) to the branch as commits; at close, request and post the `audit_experiment` close review; mark
  ready and merge-on-clean.

The DESIGN.md + START.md seam is conceptually unchanged; it now lives on a branch instead of in a shared
tree. The mechanical glue (branch/PR/review-posting for the *instance research repo*) is the implementation
work, scoped into the spawned `ready` issues.

### 4. Review depth — full on the headline claim, indexed + spot-checked on the records

The close `audit_experiment` keeps its existing focus: **the headline claim** — pre-registered hypothesis
vs result, reproducibility, overclaim, postdictions, and the validity/comparability surfaces (the
confidently-wrong-number failure mode). The **records** (rollout dumps, training data, judge JSON) are the
*evidence* the claim rests on: indexed and linked, spot-checked against the data-audit's surfaces
(truncation, leakage, mislabeling), but **not** read line-by-line. The rich "read the rollouts next to the
judge scores" behavioral deep-read is the separate, later **viewer** — explicitly out of scope here.

## Alternatives considered

- **Issue → separate run-PR split (closer to the scaffold pattern).** Rejected: an experiment has no
  fan-out, so the design→children decomposition the scaffold split is built for does not apply; it adds a
  second artifact and merge for no benefit. The single PR with two review checkpoints is the smaller shape.
- **Run-then-review (design review does not gate).** Rejected: erodes the most important checkpoint in the
  whole program — the human design clearance — and risks spending real API/data-gen budget on a flawed
  design. The gate is cheap (background cross-family audit, minutes) and already mandated.
- **Keep both audits as local files (status quo).** Rejected — that *is* the problem: invisible,
  un-browsable, no index.
- **Build a bespoke research dashboard instead of using GitHub.** Deferred, not rejected: GitHub gives the
  index + summaries + reviews for free *now*; the rich behavioral viewer is a separate later thing. This
  doc deliberately ships the index layer GitHub already affords and stops there.

## Blast radius

- **Product skills** (`automated-researcher`): `design-experiment` and `run-experiment` gain the
  branch/PR/review-posting steps. No change to the `verify-claims` audit engine — it is reused as-is.
- **Builds on** Step 1 (per-experiment worktrees; the `run/<exp>` branch) — a separate `needs-design` issue.
- **Product/instance boundary:** the skill change is *product*; the experiment PRs it produces land in the
  **instance research repo** (e.g. `research-lab`), not in `automated-researcher`. The skill must therefore
  be **instance-repo-agnostic** — the target research repo is instance config, not hardcoded — keeping the
  flow decoupled and reusable by any consuming instance.
- **No change to `main` of `automated-researcher`** beyond this doc and the spawned skill edits.

## Rollout + rollback

Doc-only design PR; lands the shape on `main` via the `--scaffold` gate, then **spawns `ready` issues** for
the skill edits (design-experiment PR-open + design-review-posting; run-experiment records + close-review +
merge-on-clean; the instance-repo-agnostic branch/PR glue), each implemented as a normal `ship-change` run.

Staged: pilot the flow on a single real experiment before making the branch/PR path the default in
`run-experiment`. Rollback is a normal revert of the spawned skill edits — the experiment lifecycle falls
back to the status-quo local-file gates with no data loss, since the audits themselves are unchanged.
