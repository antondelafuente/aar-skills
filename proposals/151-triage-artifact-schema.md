# Proposal: Triage-artifact schema for the experiment close gate (#151)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Part of the #130 "experiments through GitHub" cluster. Doc-only design PR (two-phase, Step 2); spawns
> `ready` implementation children. **No implementation here.**

## Problem

When an experiment finishes, the close `audit_experiment` posts a cross-family review of the headline claim,
and the experiment PR merges **only with zero unresolved HIGH** (#130 decision 2). But "unresolved" cannot be
the raw finding count: the research close protocol already lets a HIGH be **fixed OR explicitly justified**, so
a gate that parsed `high=0` from the audit summary would block a legitimately-justified HIGH and force a
finished, valid experiment to sit in a perpetually-open PR. The gate therefore has to read a **machine-readable
triage artifact** — one structured response per HIGH/MED finding — and decide pass/fail from *that*, not from a
count. No such artifact exists anywhere in the experiment lifecycle yet, so the #130 close gate has nothing to
parse. This issue defines that artifact: where it lives, how a response is keyed to a finding, the closed set
of statuses each response may carry, and the fail-closed pass/fail rules the merge gate evaluates over it.

This is the close-gate analogue of the **design-clearance artifact** (#145), which does the same job at the
pre-run gate. The two artifacts share one per-finding response vocabulary on purpose (decision 6), so an agent
and a reviewer learn one shape, not two.

## Approach

Define a single, machine-readable **close-triage artifact** the executor writes at close and the #130 close
gate parses to decide the merge. It is a typed file living in the experiment's canonical record dir
(`experiments/<exp>/`, owned by #155), carrying **one response object per HIGH/MED finding** from the close
`audit_experiment`. Each response names the finding by a **stable identifier** (so it survives re-review
rounds), carries a **status from a closed set**, and carries the **evidence that status requires** (a commit
SHA for `fixed`, a reason for `justified`, a follow-up issue for `deferred`). The merge gate evaluates a
**deterministic, fail-closed** rule over the artifact — independent of the model — and merges only when every
HIGH/MED finding has a valid response and no HIGH is left unresolved. A malformed or missing artifact, or a
HIGH with no response, **blocks**; it is never read as clean.

The artifact is the close-side twin of two patterns already in the product: it borrows the **per-finding
disposition** shape from ship-change's `fdispo` close-gate state (#138/#139) and the **closed-status +
required-evidence** discipline from the disposition vocabulary (`DISPOSITIONS.md`), but it is the *research*
close gate, not the scaffold one — its statuses, its evidence, and its terminal-state coupling are its own.

This doc **fixes the schema only**. It ships no parser, no gate code, and no template edit; those are the
`ready` children it spawns. It states the file's location, its grammar, the status set, the required evidence
per status, and the pass/fail rule the gate implements — the contract those children build against.

The load-bearing decisions:

### 1. Location — one file per experiment, in the canonical record dir, deterministically named

The artifact lives at **`experiments/<exp>/close_triage.toml`** — one file, in the per-experiment record dir
#155 establishes on the research repo's `main`. It is committed to the `run/<exp>` branch like every other
record and rides into `main` when the PR merges, so the triage of a closed experiment is a first-class,
browsable part of its record (the whole point of #130).

- **One file, not per-finding files.** The gate must read *all* responses to decide pass/fail; a single file is
  one read and one parse, and it diffs cleanly across re-review rounds. (ship-change's `fdispo` keeps its state
  in a single canonical PR comment for the same reason; the research flow puts it in the committed record
  instead of a PR comment, because #155 makes `experiments/<exp>/` the durable home and the comment would not
  survive branch deletion.)
- **TOML, with stdlib JSON accepted** — exactly the format contract #153 fixed for `aar-profile`
  (`close_triage.toml` preferred; `close_triage.json` accepted; **YAML not accepted**, no parser dependency),
  so the lifecycle has one config-file format discipline, not two. `.toml` wins if both exist; the gate warns
  on the shadowed file.
- **Deterministic name**, so the gate resolves it without guessing — the same fail-closed disposition #153's
  discovery rule takes: if neither `close_triage.toml` nor `.json` exists at the path, the gate prints a single
  `BLOCKED: no close-triage artifact found` line and stops, never merges.

### 2. The schema — one response per HIGH/MED finding, keyed by a stable id

A flat, versioned file. The load-bearing part is the `[[finding]]` array: exactly one entry per HIGH/MED
finding the close `audit_experiment` raised, keyed to the finding by a stable id.

```toml
schema_version = 1                       # integer MAJOR; gate refuses an unknown MAJOR (decision 5)

audit_sha       = "<commit sha the close audit reviewed>"   # REQUIRED. binds the triage to the reviewed head
audit_findings_path = "experiments/<exp>/close_audit.md"    # REQUIRED. the audit output these respond to

[[finding]]
id        = "H1"            # REQUIRED. stable finding id (decision 3) — matches the audit's emitted id
severity  = "high"          # REQUIRED. one of: "high" | "med"  (LOW is recorded, never gated — decision 4)
status    = "fixed"         # REQUIRED. one of the closed status set (decision 4)
commit    = "<sha>"         # REQUIRED iff status=fixed — an in-PR commit that resolves the finding
# reason   = "..."          # REQUIRED iff status=justified — why the finding does not invalidate the claim
# issue    = "owner/repo#N" # REQUIRED iff status=deferred — the follow-up issue the deferral is tracked in

[[finding]]
id        = "H2"
severity  = "high"
status    = "justified"
reason    = "Confound is bounded: the held-out split shows the same effect at 0.3pp, within noise."

[[finding]]
id        = "M1"
severity  = "med"
status    = "deferred"
issue     = "owner/research-lab#88"
```

Field semantics, normative:

- **`audit_sha`** — the head commit the close `audit_experiment` reviewed. The gate **re-runs the close audit
  on the final diff** (mirroring ship-change's re-review-on-final-diff integrity property, #130 §2) and
  requires the artifact's `audit_sha` to equal that head; a stale `audit_sha` (the branch moved after the
  triage was written) **blocks** — the triage must respond to the audit of the diff that actually merges, not
  an earlier one.
- **`[[finding]].id`** — the stable identifier (decision 3) that joins a response to its finding across
  re-review rounds. **Every** HIGH/MED id the close audit emitted MUST appear exactly once; a missing id, or a
  response id not in the audit, **blocks** (decision 4).
- **`severity`** — `high` or `med`, mirrored from the audit so the gate applies the right rule without
  re-reading the audit body. LOW findings are **not** carried (decision 4) — the close protocol gates HIGH/MED
  only; LOW is advisory.
- **`status` + its required evidence** — the closed set is decision 4. The evidence field a status requires is
  **mandatory for that status and forbidden for others** (a `fixed` with no `commit`, or a `justified` with a
  `commit` and no `reason`, is malformed and **blocks**) — the same "status determines required evidence"
  discipline `fdispo` enforces.

### 3. Stable finding identifiers — emitted by the audit, not invented by the author

A response must survive re-review: when the author fixes H1 and re-runs the close audit, the still-open
findings must keep the **same ids** so their existing responses still apply and only genuinely-new findings
need a new response. So the **finding id is owned by the audit runner, not the triage author** — `verify-claims`
emits a stable id per finding in its `audit_experiment` output (the same `id` the artifact references), and the
author copies it, never invents it. This is a small **prerequisite on the audit-output format**: the close
`audit_experiment` must emit a per-finding stable id (and the `SUMMARY:` line the gate already parses stays as
the count cross-check). Making the audit emit that id is a dependency this schema declares; it is **filed as
the child that touches the audit-runner contract** (coordinating with #154, which is reworking the
audit-runner cross-family contract — the id-emission lands in the same audit-output surface #154 touches, so
the two are sequenced, not duplicated). Until the audit emits stable ids, the gate falls back to requiring a
response per finding **by position+text-hash**, which is the fragile path this decision exists to retire — so
the stable-id emission is the load-bearing prerequisite, not an optimization.

### 4. The closed status set + the pass/fail rule (fail-closed)

**The closed status set** (a HIGH/MED response carries exactly one):

- **`fixed`** — the finding was resolved by a change on the branch. Requires `commit` (an in-PR SHA). The
  reviewer's re-run on the final diff is what *confirms* it is actually fixed; the status is the author's claim,
  the re-run is the check.
- **`justified`** — the finding is real but does **not** invalidate the headline claim, with a recorded
  reason. Requires `reason`. This is the "explicitly justified HIGH" the close protocol already permits — the
  status that makes a raw `high=0` parse wrong, and the reason the artifact exists.
- **`deferred`** — the finding is real, out of scope for *this* experiment's claim, tracked in a follow-up
  issue. Requires `issue` (a same-repo `#N` or `owner/repo#N`; a bare reason is **not** enough — an unbacked
  deferral is exactly the silent-drop failure the gate prevents). **A `deferred` HIGH does NOT by itself let a
  *valid* experiment merge** (decision 4a) — deferral parks follow-up work, it does not dispose of a HIGH that
  bears on whether the headline claim holds.

**The pass/fail rule the gate evaluates (deterministic, model-independent, fail-closed):**

1. The artifact exists, parses, and `schema_version` is a known MAJOR — else **BLOCK**.
2. `audit_sha` equals the head the gate re-ran the close audit on — else **BLOCK** (stale triage).
3. Every HIGH/MED finding id the (re-run) close audit emitted has **exactly one** response with a valid
   status + its required evidence — a missing response, a duplicate, an unknown id, or malformed evidence
   **BLOCKS**.
4. **Every HIGH** is `fixed` or `justified` (a `deferred` HIGH does **not** pass for a *valid-conclusion*
   experiment — decision 4a). A HIGH that is `deferred`, `unresolved`, or absent **BLOCKS**.
5. **MED** findings may be `fixed`, `justified`, or `deferred` (deferral with a tracking issue is acceptable
   for a MED) — but every MED still needs one of those explicit responses; an unanswered MED **BLOCKS**.

So the merge passes only when the artifact accounts for **every** HIGH/MED finding and **no HIGH is left
unfixed-and-unjustified**. Anything else — including a parse failure or a permission error reading the audit —
**fails closed as BLOCKED**, never clean. (A `WF`-style override hatch is out of scope: this is a research-flow
gate; its escape hatch, if any, is #157's to define alongside the gate code.)

### 4a. Terminal-state coupling — a `deferred` HIGH must not silently close a *valid* experiment

#130 promises `main` receives **closed** experiments — successful *or* terminal (blocked / invalid / abandoned
/ null-conclusion, owned by #152). The triage artifact must not become a back door that merges a *valid*
experiment over a HIGH by deferring it. So the rule is explicit (decision 4 rule 4): for a
**valid-conclusion** experiment, every HIGH must be `fixed` or `justified`. An experiment that genuinely cannot
clear a HIGH does not "defer" it to merge a valid claim — it **declares a terminal state** (#152): the record
merges as *no valid conclusion*, with the unresolved HIGH recorded as the reason. The two artifacts compose:
**#152 decides whether the experiment has a valid conclusion at all; this triage decides whether a
valid-conclusion experiment's findings are all answered.** A HIGH the author can neither fix nor justify is a
#152 terminal-state signal, not a #151 deferral. This doc therefore does **not** invent a "no-valid-conclusion"
status inside the triage status set (an earlier framing in #151's body floated that) — that state is #152's,
and the triage gate reads #152's terminal declaration as the alternative to clearing every HIGH. The seam:
the close gate passes if **either** (the triage clears every HIGH/MED per decision 4) **or** (#152 declares a
terminal state with its own required evidence). The triage artifact owns the former branch only.

### 5. Versioning — `schema_version`, refuse-unknown-MAJOR

`schema_version` is an integer MAJOR version; the product declares the version it understands (one
`SCHEMA_VERSION` marker in the reference doc, the #193 pattern). The gate **refuses an unknown MAJOR** (fails
closed with a clear message) rather than interpreting a field layout it cannot read — the same disposition as a
missing file. Adding an optional field is backward-compatible (no bump for a tolerant reader); removing or
retyping a field is a MAJOR bump. This matches the `aar-profile` versioning rule exactly (#153 decision 5), so
the lifecycle has one versioning discipline across its schemas.

### 6. One per-finding response vocabulary, shared with the design-clearance schema (#145)

The pre-run **design-clearance** artifact (#145) carries a response per surviving HIGH/MED finding of the
`audit_experiment --design` review — structurally the same problem this artifact solves at close. The two MUST
share the **per-finding response vocabulary** — the same status set (`fixed | justified | deferred`), the same
required-evidence-per-status rule, the same stable-id keying — so an agent learns one shape and a reviewer
reads one grammar across both gates. They differ only in **what they bind to** (the clearance binds the
reviewed *brief* commit and gates the *run*; the triage binds the close-audit head and gates the *merge*) and
in their **container fields** (clearance carries an approver + the brief SHA; triage carries `audit_sha` + the
findings path). The shared vocabulary is the load-bearing coherence requirement between #151 and #145; the
implementation children of both should factor the shared per-finding grammar into **one reference section both
reference docs cite**, not two copies that drift. (Concretely: the per-finding `[[finding]]` shape is the
shared part; #151 and #145 each wrap it in their own container.)

### 7. Packaging — a product reference doc, per-skill copies, distinct from `aar-profile`'s `SCHEMA.md`

The schema ships as a **product reference doc** the `run-experiment` close gate (and #145's design gate) read,
following the #193 packaging precedent: packaged **byte-identical in both skill dirs**
(`design-experiment/references/` and `run-experiment/references/`, since the two skills install
independently), with a **`.aar-ci/checks.sh` drift guard** (`cmp -s` the two copies) and a single
`SCHEMA_VERSION` marker per copy that the guard asserts. **It is a DISTINCT file from `aar-profile`'s
`SCHEMA.md`** — that name is already taken by #193 and owns the instance-profile schema; the close-triage
schema is its own doc (working name `CLOSE_TRIAGE.md`) with its own `SCHEMA_VERSION`, its own drift-guard
clause in `checks.sh`, and its own version line. Reusing the `SCHEMA.md` name would collide two unrelated
schemas under one drift guard and one version marker. (If #145 factors out the shared per-finding grammar per
decision 6, that shared section is a third reference doc both cite — also per-skill-copied + drift-guarded.)

## Interface contract (what the rest of #130 consumes)

| Consumer | Reads from this interface |
|---|---|
| **#157** run-experiment close/merge gate | the artifact at `experiments/<exp>/close_triage.{toml,json}`; the status set; the fail-closed pass/fail rule (decision 4); the `audit_sha` re-run binding |
| **#155** canonical-path record layout | the file name `close_triage.toml` + that it lives in `experiments/<exp>/` (so the layout reserves the path) |
| **#152** terminal experiment states | the seam in decision 4a — a HIGH that is neither fixed nor justified is a #152 terminal signal, not a #151 deferral; the gate passes on EITHER a clean triage OR a #152 terminal declaration |
| **#145** design-clearance schema | the **shared per-finding response vocabulary** (decision 6): same status set + required-evidence + stable-id keying; the two artifacts differ only in container + what they bind to |
| **#154** audit-runner cross-family contract | the **stable finding-id emission** (decision 3): the close `audit_experiment` must emit a per-finding stable id the triage references; this lands in the audit-output surface #154 touches |

## Alternatives considered

- **Parse `high=0` from the audit `SUMMARY:` line (status quo for ship-change code reviews).** Rejected — the
  research close protocol permits a *justified* HIGH, so a raw count blocks a legitimately-justified finding
  and strands a valid experiment. The artifact is precisely what lets a HIGH pass on a recorded justification.
- **Keep the triage in a PR comment (ship-change's `fdispo` model).** Rejected for the research flow — #155
  makes `experiments/<exp>/` the durable on-`main` record home; a PR comment does not survive branch deletion,
  and the triage of a *closed* experiment must be a first-class part of its merged record, not a comment.
- **Author-invented finding ids.** Rejected (decision 3) — ids that change across re-review rounds break the
  join between a response and its finding, so every re-run would re-orphan every response. The audit owns the
  stable id.
- **Add a `no-valid-conclusion` status to the triage set.** Rejected (decision 4a) — that state is #152's
  terminal-state contract, not a per-finding triage status; modeling it here would duplicate #152 and let a
  per-finding response decide the experiment's overall validity, which is the wrong altitude. The gate reads
  #152's declaration as the alternative branch.
- **Let a `deferred` HIGH merge a valid experiment.** Rejected (decision 4a) — that is the silent-drop failure
  the gate exists to prevent: a HIGH bearing on the claim either gets fixed/justified, or the experiment is
  terminal. Deferral parks follow-up work; it does not dispose of a claim-bearing HIGH.
- **A separate status set from #145.** Rejected (decision 6) — the design and close gates solve the same
  per-finding problem; two vocabularies would make an agent learn two shapes and would drift. Shared
  vocabulary, different container.
- **Reuse the `aar-profile` `SCHEMA.md` file.** Rejected (decision 7) — that name + drift guard + version
  marker are #193's and own an unrelated schema; the close-triage schema is its own reference doc.

## Blast radius

- **New product artifact (a later `ready` child, not this PR):** the close-triage schema reference doc
  (working name `CLOSE_TRIAGE.md`), shipped as two byte-identical per-skill copies under `experiment-lifecycle`
  with a `.aar-ci/checks.sh` drift guard + `SCHEMA_VERSION` marker — the #193 packaging precedent, a distinct
  file from `aar-profile`'s `SCHEMA.md`.
- **`run-experiment` close gate (a `blocked-by` child, #157's surface):** gains the parse-the-artifact +
  fail-closed pass/fail step (decision 4); replaces the implicit `high=0` reading with the artifact read.
- **Audit-output format (decision 3, coordinated with #154):** the close `audit_experiment` must emit a stable
  per-finding id; lands in the same audit-runner surface #154 reworks.
- **Cluster coupling:** **prerequisite** that unblocks the #157 close-gate wiring (it lists the triage schema
  in its `blocked-by`). **Adjacent** to #155 (reserves the file path), #152 (the terminal-state seam, decision
  4a), #145 (shared per-finding vocabulary, decision 6), and #154 (stable-id emission, decision 3). It
  **contradicts no sibling** — it defines the close gate's input contract and names, but does not implement,
  each neighbor's enforcement.
- **No runtime behavior ships in this PR** — doc-only design. The only thing that "breaks" if mis-specified is
  the children built on it, which is why it is reviewed first.

## Decomposition (spawned `ready` children)

This is a single-schema design with no open sub-decision left after this doc, so its children are `ready`:

1. **Close-triage schema reference doc** — ship `CLOSE_TRIAGE.md` (two byte-identical per-skill copies) stating
   exactly this schema (location, `[[finding]]` grammar, status set + required evidence, version rule), with
   the `.aar-ci/checks.sh` drift guard + `SCHEMA_VERSION` marker (the #193 precedent). The root child the gate
   reads. `ready`.
2. **Stable finding-id emission in the close audit output** — make `audit_experiment` (close) emit a stable
   per-finding id the artifact references (decision 3), in the audit-output surface, **sequenced with #154** so
   the two do not both rewrite that surface. `ready`, but coordinate with #154's status.

The **close-gate wiring itself** (parse the artifact, evaluate the pass/fail rule, the #152 terminal-state OR
branch) is **#157's** `run-experiment` close-gate child, `blocked-by` child 1 here (and #155 for the path, #152
for the terminal branch) — it is not a child this design spawns, it is the consumer #157 already tracks.

## Rollout + rollback

Doc-only design PR; lands the schema on `main` via the `--scaffold` gate, closing exactly #151. Then the
`ready` children above land the reference doc + the audit-id emission as normal single-phase ship-change runs;
the close-gate wiring follows as #157's `blocked-by` child once this and its co-requisites (#155, #152) land.
Rollback is a plain revert of each spawned child — the reference doc is inert text until #157's gate consumes
it, so reverting strands no run; the lifecycle falls back to the status-quo local-file close audit with no data
loss (the audit engine itself is unchanged).
