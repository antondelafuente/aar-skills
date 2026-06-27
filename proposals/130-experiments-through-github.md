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
**closed** experiments — successful *or* terminal (blocked / invalid / abandoned / null-conclusion). A failed
or abandoned run is still a first-class record that merges with "no valid conclusion" recorded, never a
record stranded in a perpetually-open PR (the terminal-state contract is a spawned `needs-design` child —
see Decomposition).

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

**Canonical merged record path.** The branch/PR are the *process*; the durable home on `main` is a stable
per-experiment directory — `experiments/<exp>/` (`DESIGN.md`, `START.md`, `RESULTS.md`, the four gate
outputs + their triage responses, and artifact-store pointers) — mirroring the existing per-experiment dir
convention (`~/orchestrator/<exp>/` today). Records are committed to that path so they survive branch
deletion and never collide across experiments; the PR and its reviews are *pointers* to that path, not the
only place the record lives.

### 2. The three-way gate model: design gates the run; teardown is immediate; close gates the merge

The constitution already requires the design be **cleared before the run** ("clear the design with Anton
before running it"; the design-audit is the last step of DESIGN-together). #130 does not add a new gate — it
**relocates that existing clearance onto the PR**. The cross-family `audit_experiment --design` is posted to
the PR, the design-approver arbitrates the survivors, and only then is the zero-context executor handed
`START.md` and spawned. **Design approval blocks the run.**

**The design review is NOT merge-satisfying.** It gates the *run*, never the PR merge. Only the **close**
gate posts the final merge-satisfying native APPROVE, bound to the reviewed head SHA, after the run +
records + close audit + triage. Otherwise a design APPROVE could satisfy branch protection and merge an
*un-run* experiment — defeating the close gate and the "main only receives closed experiments" promise. So
the experiment PR carries at most one merge-satisfying review, and it is the close one.

**Clearance binds to the reviewed commit.** The full brief (`DESIGN.md` + `START.md` + `CHECKLIST.md`) is
committed *before* the design audit (see decision 3), so approval records the brief **commit** SHA — one
commit containing all three files — as the clearance artifact. The design audit reviews `DESIGN.md`, but the
executor verifies that whole brief commit before any spend, and **any later change to the design or the
executor brief forces re-clearance** before the run. (So the audit interface need only name `DESIGN.md`;
clearance binds the commit that carries the full brief.) This is the same integrity property
ship-change's merge gate already has (re-review the final diff) — the reviewed design must be the *run*
design, not whatever the branch drifted to after approval.

At the other end, separate **compute teardown** from **validity closure** — they are not the same event:

- **Teardown is immediate** after the artifacts are verified-uploaded. Nothing blocks releasing the pod;
  stranding billing compute on a pending review would be the worse failure.
- **The merge / done-state still gates on the close audit.** The close `audit_experiment` is posted as the
  PR review, and the experiment PR merges only with **zero unresolved HIGH** and an explicit triage response
  to every HIGH/MED finding — mirroring ship-change's own fail-closed merge gate. An unresolved
  validity defect must not silently become a finished experiment. (This corrects an earlier framing that
  made the close review "non-blocking"; only *teardown* is non-blocking, not validity closure.)
  - **"Unresolved" is machine-readable, not a raw count.** The research close protocol already permits a
    HIGH to be *fixed OR explicitly justified*, so the gate cannot simply parse `high=0` (that would block a
    legitimately-justified HIGH). The merge gate parses a **triage artifact** (one response per HIGH/MED:
    fixed | justified-with-reason | deferred-with-issue) and fail-closes: a HIGH passes only with an explicit
    justified/fixed response recorded; a HIGH with no response BLOCKS. Defining that schema is part of the
    `run-experiment` child issue.

So the principled asymmetry is **teardown (immediate) vs. validity closure (gated)** — not "close doesn't
gate." The close audit keeps the output-side gate that `run-experiment` already enforces; it just moves it
onto the PR.

### 3. Skill placement — the seam maps onto the branch, unchanged in spirit

- **`design-experiment`** gains: write the **full brief** (`DESIGN.md` + `START.md` + `CHECKLIST.md`) and
  commit it to `run/<exp>` *before* the design audit, open the draft PR, request and post the
  `audit_experiment --design` review (and link the `verify_claim` fact record); **clearance then binds all
  three brief SHAs**, and only after clearance is the executor handed off. (Writing the whole brief before the
  audit is precisely what lets clearance bind the brief the executor will run — resolving the SHA/ordering
  contradiction; any post-clearance brief change forces re-clearance.)
- **`run-experiment`** gains: the executor pushes records (`RESULTS.md`, the `--data` audit outputs, ledger/
  artifact-store pointers) to the branch as commits; tears down compute on verified upload; at close, requests
  and posts the `audit_experiment` close review, resolves HIGH/MED, and merges on the triage gate.

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
research audits + the zero-HIGH close gate — but neither re-implements the GitHub plumbing.

**The helper's home is a runtime layer, not the build plugin.** `aar-engineering` is the *build-the-product*
plugin (installed only by scaffold developers), so the helper cannot live there or the research runtime would
take a build-layer dependency. Its home is a **neutral GitHub-lifecycle runtime helper** that both
flows consume — *not* the build plugin, and *not* `verify-claims` either: verify-claims is the **read-only**
adversarial-audit plugin, so giving it draft-PR creation, identity, and merge authority would be the wrong
seam (it would own mutation it has no business owning). The helper owns the GitHub *mutation/posting*
plumbing; `verify-claims` keeps producing audit *outputs*. The exact host (a small dedicated plugin vs.
another existing runtime home) is the helper child's first decision — which is why that child is
`needs-design`, not `ready`.

**The helper enforces the cross-family contract mechanically**, inheriting the discipline #134 just
established for `wf.sh`: design/close reviews take an **explicit** runner/designer family — no silent
`AAR_SUBSTRATE` default — and **fail closed unless the verifier is the opposite family**. This is what stops
a Codex-run experiment from being reviewed by Codex (same-family), the exact failure the cross-family
guarantee exists to prevent. The explicit-family, fail-closed requirement applies to **all four
model-judged rungs** (`verify_claim`, `--design`, `--data`, close) — a same-family judgment on *any* would
taint the record — but it is **enforced in the right place**: the read-only audit rungs (`verify_claim`,
`--data`) enforce family in `verify-claims` / the audit-runner contract where they actually run; the GitHub
helper enforces it on the rungs it runs (`--design`, close) and otherwise only **posts/merges** already-
produced audit outputs. The helper does not own the read-only audit contract — it must not become a second
home for cross-family enforcement. Making `verify_claim`/`--data` actually require explicit family and fail
closed (today they default to a substrate family with no check) is the **audit-runner cross-family contract**
prerequisite child below; the four-rung promise is `blocked-by` it.

**Merge-authority code loads from a trusted source, never the branch under review.** Because the helper now
carries *write/merge* authority, an experiment PR that edited the helper could otherwise run its own
branch-modified mutation code as its own merge gate — the same trust hole `locate_audit` already closes for
the reviewer ("a PR that edits the reviewer cannot run its own modified reviewer as its merge gate"). The
helper must resolve merge-authority code from the trusted base/install (mirroring `locate_audit`'s
trusted-but-current resolution) and ship a poisoned-helper smoke matching `locate_audit_smoke`. Working out
*which* primitives are merge-authority (trusted-base) vs. plain posting (runtime) is the substance of the
helper's `needs-design` child — so the extraction is **not** a `ready` task.

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

Today the execution profile is a **narrative** seam (prose in `run-experiment`), not a machine-discoverable
config. This flow needs it as a **concrete discovery/init interface** the executor can read without guessing —
delivered as a prerequisite child issue. The `START.md` brief then snapshots the resolved values, so the run
is reproducible even if instance config later changes.

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
  branch/PR/review-posting steps and the four-gate record contract. The `verify-claims` audit *engine* is
  reused, but its current `AAR_SUBSTRATE=claude` default is **legacy for direct local invocation only** —
  the experiment-PR path goes through the helper, which **requires** an explicit runner/designer family and
  fails closed; only that path carries the cross-family guarantee. (Folding explicit-family selection into the
  engine's own contract is an option for the helper child.)
- **Shared helper (decision 5):** the GitHub-identity + review-posting + mutation primitives are extracted
  into a neutral GitHub-lifecycle runtime helper (not the build plugin, not read-only `verify-claims`), and
  `aar-engineering`/`wf.sh` is refactored to consume it. This is the one cross-cutting edit; its exact host is
  the helper `needs-design` child.
- **Canonical record path:** establishes `experiments/<exp>/` on the research repo's `main` as the durable
  per-experiment home.
- **Builds on** Step 1 (per-experiment worktrees; the `run/<exp>` branch) — a separate `needs-design` issue.
- **Product/instance boundary:** the skill change is *product*; the experiment PRs it produces land in the
  **instance research repo** (e.g. `research-lab`), resolved via the instance-profile contract above —
  never hardcoded.

## Decomposition (spawned issues)

This is the **umbrella/shape** design: it fixes the lifecycle shape and the genuinely-settled decisions
(decisions 1–5, the gate model, the canonical path), and decomposes the rest honestly. The novel pieces each
carry an open sub-decision, so they are `needs-design` — only the work that carries *no* open design is
`ready`, and dependent work is filed `blocked-by` its parents (per the two-phase contract).

**`needs-design` children (each carries an open sub-decision):**
- **Shared-helper extraction** — into a neutral GitHub-lifecycle runtime helper (host TBD: a small dedicated
  plugin vs. an existing runtime home; *not* read-only `verify-claims`, *not* the build plugin), *with* the
  merge-authority trust/source-selection contract (which primitives load from trusted-base vs runtime) + the
  poisoned-helper smoke. Both the host and the trust split are open design.
- **Triage-artifact schema** — path, finding identifiers, allowed statuses {fixed | justified-with-reason |
  deferred}, pass/fail rules. None exists in the lifecycle yet.
- **Terminal experiment states** — blocked / invalid / abandoned / null-conclusion: which states exist, what
  evidence each requires, when such a record merges as "no valid conclusion."
- **Instance-profile discovery/init interface** — the concrete config path, schema, init owner, and brief
  snapshot rules. Today it is only a narrative seam.
- **Audit-runner cross-family contract** — make `verify_claim` and experiment `--design`/`--data`/close *all*
  require an explicit runner/designer family and **fail closed on same-family**. Today only `--scaffold`/
  `--code` require explicit `AAR_SUBSTRATE`; the read-only rungs default to a substrate family with no check,
  so the four-rung cross-family promise is unbacked until this lands.
- **Design-clearance artifact schema** — the design gate (decision 2) blocks the run on a human-arbitrated
  design approval bound to the reviewed brief commit, but the umbrella only fixes that *model*; the concrete
  **machine-readable clearance artifact** a zero-context executor reads before any spend is open design: its
  path, the fields it must carry (approver, reviewed brief SHA, a response per surviving HIGH/MED finding),
  the runner block/proceed condition, and the re-clearance trigger on any post-approval brief change. The
  design-gate analogue of the close-gate's **Triage-artifact schema** child — neither exists in the lifecycle
  yet, and the executor cannot verify clearance without it.
- **Record sensitivity / visibility contract** — posting design/records/reviews to GitHub by default raises a
  visibility question the status-quo local-file gates never had: experiment content can be sensitive
  (unreleased data, private model behavior, block-prone rollout text). The umbrella already keeps raw
  artifacts *out* of the trail (artifact-store **pointers**, not payloads; "pointers only, never trigger
  text") and lets the instance research repo be **private**, but the explicit contract is open design:
  private-repo requirements, the pointer-only/redaction rules for each record type, and what a PR review may
  **quote** from a record. The GitHub-posting, canonical-path record-layout, and close-review implementation
  pieces are **`blocked-by`** this — the experiment-PR path must not be authorized until the visibility
  contract lands.

**`ready` (no open design):** none stands fully independent. The record layout below *looked* ready but
depends on where `experiments/<exp>/` lives (the worktree/profile contract), so it is `blocked-by`. Honest
result at umbrella altitude: every piece is a `needs-design` child or `blocked-by` a parent.

**`blocked-by` (file once parents land):**
- **Canonical-path record layout:** `design-experiment` snapshots the *locked brief* (`DESIGN.md`/`START.md`/
  `CHECKLIST.md`) into the experiment's canonical working dir `experiments/<exp>/` at clearance; `run-experiment`
  appends only execution records, audit outputs, `RESULTS.md`, and artifact-store pointers — never the brief
  ("your brief is your world"). `experiments/<exp>/` is the *actual* working dir, not a second copy. Blocked-by
  the worktree/profile contract (which defines where `experiments/<exp>/` lives) and the triage-schema child
  (for the triage record).
- `design-experiment` PR-open + `--design` review posting + fact-record linking — blocked-by the helper, the
  per-experiment worktree/branch contract (Step 1), the instance-profile interface (repo / base
  branch / identity resolution it needs to open the PR), **and the record sensitivity/visibility contract**.
- `run-experiment` push-to-PR + close-review + merge gate — blocked-by the helper, the worktree/branch
  contract, the instance-profile interface, the triage schema, terminal states, **and the record
  sensitivity/visibility contract**.

## Rollout + rollback

Doc-only design PR; lands the shape on `main` via the `--scaffold` gate, then the children above are filed:
the `needs-design` sub-designs first (they unblock the rest), and the `blocked-by` wiring once its parent
contracts land. There is **no** independent `ready` child — the decomposition concluded every piece is either
a `needs-design` sub-design or `blocked-by` a parent (the record-layout work that once looked `ready` is
`blocked-by` the worktree/profile contract). Each is implemented as a normal `ship-change` run. Staged: pilot the flow on a single real experiment before making
the branch/PR path the default in `run-experiment`. Rollback is a normal revert of the spawned skill edits —
the lifecycle falls back to the status-quo local-file gates with no data loss, since the audits themselves
are unchanged.
