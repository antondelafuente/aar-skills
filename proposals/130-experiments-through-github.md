# Proposal: experiments through GitHub — design + close review as PR reviews (#130)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (Step 2 of 2); spawns `ready` issues for the skill edits.

## Problem

Today an experiment leaves no browsable trail. Anton can't see what was run, the design and reasoning
behind it, the cross-family audits, or where the data/evals live — he has to ask an agent. The experiment
lifecycle's **four gates** (the `verify_claim` fact check and `audit_experiment --design` before a run; the
deterministic + semantic `--data` audits mid-run; the close `audit_experiment` after) are produced as
**local files** inside a shared working tree: invisible, un-versioned-per-experiment, and impossible to
read like a record. The engineering side already solved exactly this — `ship-change` makes every scaffold
change a branch + PR with its reviews posted to GitHub — but the *research* side, which is the actual
product, has no equivalent.

## Approach

Run experiments **through GitHub**, mirroring `ship-change`: **an experiment = a branch = a PR**, and
GitHub becomes the index ("what did I run, the design, the reviews, the data pointers"). All four gate
outputs **and their triage responses** are committed or PR-linked as first-class records; the two that are
genuine human-facing checkpoints — the **design** audit (before the run) and the **close** audit (at the
end) — are additionally posted as **PR reviews**. The PR reuses the existing cross-family research-audit
engine (`audit_experiment --design` / close). `main` of the instance's research repo only ever receives
finished, reviewed experiments.

This is **distinct from `ship-change`'s gates** — it borrows the cross-family review *engine* and the
branch/PR/posting *mechanics*, but it is the research lifecycle, not a scaffold change. It is not governed
by ship-change's disposition close-gate; the experiment PR merges on its own contract (below). The two are
siblings over one review engine and one shared GitHub helper (decision 5).

The load-bearing decisions:

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

### 2. The three-way gate model: design gates the run; teardown is immediate; close gates the merge

The constitution already requires the design be **cleared before the run** ("clear the design with Anton
before running it"; the design-audit is the last step of DESIGN-together). #130 does not add a new gate — it
**relocates that existing clearance onto the PR**. The cross-family `audit_experiment --design` is posted to
the PR, Anton arbitrates the survivors, and only then is the zero-context executor handed `START.md` and
spawned. **Design approval blocks the run.**

At the other end, separate **compute teardown** from **validity closure** — they are not the same event:

- **Teardown is immediate** after the artifacts are verified-uploaded. Nothing blocks releasing the pod;
  stranding billing compute on a pending review would be the worse failure.
- **The merge / done-state still gates on the close audit.** The close `audit_experiment` is posted as the
  PR review, and the experiment PR merges only with **zero unresolved HIGH** and an explicit triage response
  to every HIGH/MED finding — mirroring ship-change's own fail-closed merge gate. An unresolved
  validity defect must not silently become a finished experiment. (This corrects an earlier framing that
  made the close review "non-blocking"; only *teardown* is non-blocking, not validity closure.)

So the principled asymmetry is **teardown (immediate) vs. validity closure (gated)** — not "close doesn't
gate." The close audit keeps the output-side gate that `run-experiment` already enforces; it just moves it
onto the PR.

### 3. Skill placement — the seam maps onto the branch, unchanged in spirit

- **`design-experiment`** gains: commit `DESIGN.md` to `run/<exp>`, open the draft PR, request and post the
  `audit_experiment --design` review (and link the `verify_claim` fact record), drive to Anton's clearance,
  then write `START.md` and hand off.
- **`run-experiment`** gains: the executor pushes records (`RESULTS.md`, the `--data` audit outputs, ledger/
  R2/artifact pointers) to the branch as commits; tears down compute on verified upload; at close, requests
  and posts the `audit_experiment` close review, resolves HIGH/MED, and merges on the zero-HIGH gate.

The DESIGN.md + START.md seam is conceptually unchanged; it now lives on a branch instead of in a shared
tree.

### 4. Review depth — full on the headline claim, indexed + spot-checked on the records

The close `audit_experiment` keeps its existing focus: **the headline claim** — pre-registered hypothesis
vs result, reproducibility, overclaim, postdictions, and the validity/comparability surfaces (the
confidently-wrong-number failure mode). The **records** (rollout dumps, training data, judge JSON) are the
*evidence* the claim rests on: indexed and linked, spot-checked against the data-audit's surfaces
(truncation, leakage, mislabeling), but **not** read line-by-line. The rich "read the rollouts next to the
judge scores" behavioral deep-read is the separate, later **viewer** — explicitly out of scope here.

### 5. Mechanical seam — one shared GitHub helper, not a fork of `wf.sh`

The experiment flow needs branch/PR creation, engineer-identity token seams, and review-posting — exactly
what `wf.sh` already implements for ship-change. Reimplementing it in `experiment-lifecycle` would fork the
GitHub-identity and review-posting machinery and guarantee drift.

Decision: **extract the low-level primitives** (engineer-identity resolution, draft-PR open, cross-family
review posting) into a small shared helper that *both* `ship-change` and the experiment flow consume. Each
keeps its own gates on top — ship-change its disposition close-gate + classifier; the experiment flow its
research audits + the zero-HIGH close gate — but neither re-implements the GitHub plumbing. This is the one
decision that reaches back into `wf.sh`/`aar-engineering`; it is flagged for the PM's arbitration.

## Instance-profile contract (decoupling)

The target research repo is **instance config, not hardcoded** — so the flow is reusable by any consuming
instance, not just Anton's. A zero-context executor discovers it from the instance's existing **execution
profile** (the same place `run-experiment` already reads provisioning/artifact-store/ledger/teardown/cost
policy). The profile must declare, at minimum:

- **research repo** slug + **base branch** + **branch prefix** (`run/`);
- **issue repo** (where experiment backlog issues live, if separate from the research repo);
- **GitHub identity/token seams** for the open/commit/merge identity;
- **branch-protection expectations** (what the merge gate may require);
- **where the brief snapshots or links** these, so the executor never guesses.

The `START.md` brief snapshots the resolved values so the run is reproducible even if instance config later
changes.

## Alternatives considered

- **Issue → separate run-PR split (closer to the scaffold pattern).** Rejected: an experiment has no
  fan-out, so the design→children decomposition the scaffold split is built for does not apply; it adds a
  second artifact and merge for no benefit.
- **Run-then-review (design review does not gate).** Rejected: erodes the most important checkpoint — the
  human design clearance — and risks spending real API/data-gen budget on a flawed design.
- **Close review fully non-blocking (merge-on-clean regardless).** Rejected per design review (FINDING 1):
  it drops the existing output-side validity gate. Teardown is non-blocking; merge is not.
- **Reimplement GitHub glue inside `experiment-lifecycle`.** Rejected per design review (FINDING 3): forks
  `wf.sh`'s identity/review machinery. Extract a shared helper instead (decision 5).
- **Keep all four gates as local files (status quo).** Rejected — that *is* the problem.
- **Build a bespoke research dashboard instead of using GitHub.** Deferred: GitHub gives the index +
  reviews for free now; the rich behavioral viewer is a separate later thing.

## Blast radius

- **Product skills** (`automated-researcher`): `design-experiment` and `run-experiment` gain the
  branch/PR/review-posting steps and the four-gate record contract. No change to the `verify-claims` audit
  engine — reused as-is.
- **Shared helper (decision 5):** extracting the GitHub-identity + review-posting primitives touches
  `aar-engineering`/`wf.sh` so ship-change consumes the same helper. This is the one cross-cutting edit.
- **Builds on** Step 1 (per-experiment worktrees; the `run/<exp>` branch) — a separate `needs-design` issue.
- **Product/instance boundary:** the skill change is *product*; the experiment PRs it produces land in the
  **instance research repo** (e.g. `research-lab`), resolved via the instance-profile contract above —
  never hardcoded.

## Rollout + rollback

Doc-only design PR; lands the shape on `main` via the `--scaffold` gate, then **spawns `ready` issues** for
the skill edits: (a) extract the shared GitHub helper from `wf.sh`; (b) `design-experiment` PR-open +
design-review-posting + fact-record linking; (c) `run-experiment` records + teardown-on-upload + close-review
+ zero-HIGH merge gate; (d) the instance-profile contract fields. Each is implemented as a normal
`ship-change` run.

Staged: pilot the flow on a single real experiment before making the branch/PR path the default in
`run-experiment`. Rollback is a normal revert of the spawned skill edits — the lifecycle falls back to the
status-quo local-file gates with no data loss, since the audits themselves are unchanged.
