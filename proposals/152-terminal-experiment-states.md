# Proposal: Terminal experiment states (blocked / invalid / abandoned / no-conclusion) (#152)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (two-phase, Step 1 of 2); spawns `ready` issues for the implementation.
> Child of #130 (experiments through GitHub). Sibling foundation designs: #151 (triage-artifact schema —
> the close-gate's per-finding responses), #145 (design-clearance artifact schema), #146 (record
> sensitivity/visibility), #150 (shared GitHub-lifecycle helper), #153 (instance-profile interface),
> #155 (canonical-path record layout).

## Problem

When an experiment runs through GitHub (#130), `main` only ever receives **closed** experiments — but
"closed" is not the same as "succeeded." A run can hit a wall a clean pipeline never anticipated: the pod
never came up, the design turned out to be unrunnable, the budget was pulled, or the data came back so
broken that no honest claim can be made. Today such a run leaves no first-class record at all — it is
abandoned in a shared working tree, or stranded in a perpetually-open PR that nobody merges. That is exactly
the failure #130 set out to kill: the experiment that "doesn't count" is the one with no browsable trail.

A failed or abandoned experiment must therefore be a **first-class, mergeable record** that lands on `main`
with "no valid conclusion" explicitly recorded — never a successful-looking record, and never a record that
can't merge. But the close gate (#130 decision 2, #151) merges an experiment PR only on **zero unresolved
HIGH** with an explicit response to every HIGH/MED close-audit finding. A terminal record will typically
have an unresolved HIGH (the very reason it's terminal — the run couldn't produce the evidence to answer it),
so without a defined contract it would block forever. We need: **which terminal states exist, what evidence
each requires, and exactly how such a record merges through the close gate** — as a deliberate, recorded
pass-path for an otherwise-unresolved HIGH, not a silent bypass.

This is the missing half of the close gate. #151 defines the triage artifact for a *valid* experiment's
HIGH/MED findings (`fixed | justified | deferred`); this design defines the **terminal** disposition — the
fourth pass-path #151 names ("a HIGH can pass by fixed/justified, by deferral-with-issue, **or** by an
explicit terminal *no-valid-conclusion* state"). The two must reconcile so ordinary deferral can never
silently close a *valid* experiment as if it concluded something.

## Approach

Define a single committed file, `experiments/<exp>/TERMINAL.json`, that an experiment writes **only when it
is closing without a valid conclusion**. Its presence is what flips the PR from the normal close gate (#151's
"resolve every HIGH/MED on a valid result") to the **terminal close gate** ("this run produced no valid
conclusion; here is the state, the stage it failed at, and the evidence that it genuinely failed rather than
being abandoned to dodge a finding"). A valid experiment never writes this file; the two gates are
mutually exclusive and the close gate selects between them by the file's presence (decision 6).

The states are a small, closed enum of **four** terminal states, each with a distinct evidence requirement
keyed to *why* the run produced no conclusion. The file is JSON, `schema_version`-pinned, and lands in the
same canonical per-experiment dir (#155) as `CLEARANCE.json` (#145) and the triage artifact (#151), using
the same `sha256` digest discipline. The close gate's evaluation is **fail-closed**: a malformed or
incomplete `TERMINAL.json`, or one whose evidence does not match its declared state, BLOCKS — a terminal
record is a deliberate, evidenced act, never the path of least resistance.

The plain shape: a normal experiment merges by resolving its findings; a dead experiment merges by filing a
short, evidenced death certificate. Both land on `main`; the difference is visible at a glance (the state),
and neither can be confused for the other.

The load-bearing decisions:

### 1. The four terminal states (a closed enum)

A terminal state answers "why is there no valid conclusion?" The four are chosen to be **mutually exclusive
and jointly exhaustive over the ways a run dies**, distinguished by the *stage* it died at and *whose* action
ended it — because the evidence that proves "genuinely dead, not dodged" differs per cause:

| `state` | Meaning | Died at | Ended by |
|---|---|---|---|
| `blocked` | An **external** precondition never became available — compute that never came up, a quota/credential/access wall, an upstream dependency (a sibling result, a dataset) that never landed. The design is fine; the world wouldn't cooperate. | provisioning / pre-run | environment |
| `invalid` | The **design itself** is unrunnable or unsound **as discovered during the run** — a confound that voids the comparison, a metric that can't be computed, an organism that doesn't reproduce, an unfixable apples-to-oranges. The cleared design met a fact that invalidates it. | run / data | the result (a validity defect) |
| `abandoned` | A **deliberate human/owner decision** to stop — superseded by a better design, deprioritized, budget pulled, the question answered elsewhere. The run *could* continue; someone chose not to. | any stage | owner decision |
| `no-conclusion` | The run **completed end-to-end** but the headline claim **cannot be answered** from the result — underpowered, a null that is genuinely inconclusive (not an informative negative), noise-dominated, an effect within error bars. The pipeline ran; the evidence doesn't support *any* conclusion. | close (post-run) | the evidence |

The distinctions are operationally load-bearing, not cosmetic: `blocked` (the world failed) needs proof the
precondition was genuinely unavailable; `invalid` (the design failed) needs the validity defect that voids
it — and is the bridge to the close audit (a close-audit HIGH that says "this comparison is confounded" is
exactly an `invalid` cause); `abandoned` (a human stopped it) needs the authorizing decision, because
otherwise "abandoned" is the universal escape hatch for any inconvenient finding; `no-conclusion` (the
evidence failed) needs the run records that show it ran but couldn't answer — and is explicitly **not** an
informative negative result (a clean, pre-registered "X does not help" *is a valid conclusion* and merges
through the normal #151 gate, not here). That last line is the most important boundary: terminal ≠ negative.

**Why exactly these four, and why closed.** Earlier framings floated `null-conclusion` as a fifth; it is the
same thing as `no-conclusion` and is folded in (one name, the run-completed-but-inconclusive case). The enum
is **closed** (the validator rejects any other value, fail-closed) so a new terminal state is a deliberate
schema change with its own evidence rule, never an ad-hoc string an instance invents — the same
refuse-unknown discipline #145/#153 use. (See `needs_anton_decision`: the *set* and the per-state evidence
floor are the genuine owner choice; this is the defensible default.)

### 2. The schema — `experiments/<exp>/TERMINAL.json`

```json
{
  "schema_version": 1,
  "experiment": "exp-slug",
  "state": "invalid",
  "stage": "data",
  "summary": "One-paragraph plain-English death certificate: what was attempted and why no valid conclusion is possible.",
  "decided_by": "result",
  "decided_at": "2026-06-28T19:00:00Z",
  "evidence": [
    {
      "kind": "audit_finding",
      "ref": "experiments/exp-slug/audits/close-audit.json#F2",
      "note": "Close-audit HIGH F2: actor/critic batches drawn from different base checkpoints — the A/B comparison is confounded and cannot be salvaged from the collected rollouts."
    },
    {
      "kind": "record",
      "ref": "experiments/exp-slug/RESULTS.md",
      "note": "Per-arm base-model hashes differ; documented under 'Validity'."
    }
  ],
  "covers_findings": ["F2", "F4"],
  "digest_algorithm": "sha256"
}
```

Field semantics, normative:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | int | yes | Schema generation; the gate rejects an unknown MAJOR it cannot parse (fail-closed), same as #145/#153. |
| `experiment` | string | yes | Experiment slug; MUST equal the `experiments/<exp>/` dir name (cross-checked against path — guards a misfiled record). |
| `state` | enum | yes | One of `blocked` \| `invalid` \| `abandoned` \| `no-conclusion` (decision 1). A value outside the closed set BLOCKS. |
| `stage` | enum | yes | Where the run died: `provision` \| `run` \| `data` \| `close`. Cross-checked against `state` (decision 3) — e.g. `no-conclusion` requires `stage=="close"`. |
| `summary` | string | yes | The plain-English death certificate (non-empty). What was attempted, why no valid conclusion is possible. This is the human-facing line on the merged record. |
| `decided_by` | enum | yes | Who/what ended it: `environment` \| `result` \| `owner` \| `evidence` — MUST be the `state`'s canonical ender (decision 3 table). Guards "abandoned" being claimed for a result-driven `invalid`. |
| `decided_at` | string (RFC 3339 UTC) | yes | When the terminal decision was recorded. |
| `evidence` | array of `{kind, ref, note}` | yes, ≥1 | The proof this state is genuine (decision 4). `kind` ∈ `audit_finding` \| `record` \| `decision_ref` \| `pointer`. `ref` is a committed repo-relative path (optionally `#anchor`), an issue/PR/comment URL, or an artifact-store pointer per #146; `note` is a non-empty one-line gloss. The **kinds required** depend on `state` (decision 4). |
| `covers_findings` | string[] | required iff the close audit ran (`stage` ∈ `data`,`close`) | The close-audit finding ids (matching #151's stable ids / #145's `design_audit.findings_record` id scheme) that this terminal state discharges as the no-valid-conclusion pass-path. Empty/omitted only when no close audit was produced (`blocked`/`abandoned` before close) — and then the gate requires the #151 triage artifact to be **absent**, not unanswered (decision 5). |
| `digest_algorithm` | enum (fixed `"sha256"` in v1) | yes | The one digest algorithm, fixed for determinism — matches #145. A future algorithm is a schema-version bump. |

The file is **non-secret** by construction (it carries pointers + glosses, never raw artifacts — #146); it
is committed to the experiment PR like any other record and survives branch deletion in `experiments/<exp>/`.

### 3. State / stage / decided_by must agree — the consistency floor

The three categorical fields are not free-form; they are cross-validated against decision 1's table so a
record can't claim a state its other fields contradict (the "abandoned is the universal escape hatch"
failure):

| `state` | allowed `stage` | required `decided_by` |
|---|---|---|
| `blocked` | `provision`, `run` | `environment` |
| `invalid` | `run`, `data`, `close` | `result` |
| `abandoned` | `provision`, `run`, `data`, `close` | `owner` |
| `no-conclusion` | `close` | `evidence` |

`no-conclusion` is the strictest (it asserts the run *completed*, so it can only die at `close` by the
evidence); `abandoned` is the most permissive on stage (a human can stop at any point) but the **most
demanding on evidence** (decision 4), precisely because it's the easiest to abuse. A `stage`/`decided_by`
pairing outside this table BLOCKS (fail-closed).

### 4. What evidence each state requires (the anti-dodge rule)

Evidence is the heart of the contract: a terminal record is only credible if it proves the failure was
*genuine* and not a quiet retreat from a finding the experimenter didn't want to answer. The required
`evidence[].kind` per state:

- **`blocked`** — ≥1 `record` or `pointer` showing the precondition was genuinely unavailable: the ledger
  entry / provisioning log of the failed acquisition, the quota/credential error, the unmet upstream
  dependency. The bar is "a reader can see the wall," not a bare assertion. **No compute should be billing**
  (teardown is immediate per #130 §2) — `blocked` is cheap and common (storage roulette, stale seed,
  region scarcity — the live gotchas), so its bar is the lowest, but it is still ≥1 concrete artifact.
- **`invalid`** — ≥1 `audit_finding` referencing the close-audit (or `--data` audit) finding that voids the
  design, **plus** a `record` (the `RESULTS.md`/data evidence the defect rests on). This is the bridge to
  #151: the close-audit HIGH that says "confounded / not comparable" is the citation, and `covers_findings`
  names it. The validity defect must be in the *audit record*, not only in prose — so it's adversarially
  cross-family-checked, not self-declared (the close audit is cross-family per #130 §5 / #154).
- **`abandoned`** — **exactly one** `decision_ref`: an issue/PR/comment URL carrying the authorizing
  decision (the owner's "supersede / deprioritize / stop"), posted by an authorizing identity. This is the
  strictest because `abandoned` is the only state ended by *choice* rather than by the world/result/evidence;
  without a real decision ref it would launder any inconvenient finding into "we just stopped." The
  authorizing identity / how it's attested mirrors #145's clearance-event attestation pattern (a marker
  posted by an authorized actor); the **exact attestation mechanism is deferred to the producer/consumer
  implementation child** so it reuses #150's helper + #145's marker machinery rather than inventing a second
  one. The *contract* fixed here: one decision_ref, authorized, or BLOCK.
- **`no-conclusion`** — ≥1 `record` (the run records / `RESULTS.md`) showing the run completed AND ≥1
  `audit_finding` from the close audit confirming the result is genuinely inconclusive (underpowered /
  within error bars), so "inconclusive" is the cross-family auditor's read too, not the experimenter's
  excuse for a result they dislike. This is the sharpest anti-dodge boundary: it forces the distinction
  between a real null/negative (valid conclusion → #151 gate) and a genuinely uninterpretable result
  (terminal). `covers_findings` names the HIGH(s) discharged.

In all cases `evidence[].ref` to a committed path must resolve at the merge head (the gate checks the path
exists in the PR); a dangling ref BLOCKS. Refs that are URLs/pointers are syntactically validated (the same
issue/URL syntax #145 enforces) but their target is not fetched by the deterministic gate.

### 5. Reconciliation with the #151 triage artifact (mutual exclusion + the HIGH pass-path)

This is the coherence seam #151 explicitly asks to reconcile ("ordinary deferral must not silently close a
*valid* experiment"). The rule:

1. **`TERMINAL.json` present ⇒ the terminal close gate runs; the #151 triage artifact MUST be absent.**
   A run is either valid (triage every finding) or terminal (file a death certificate) — never both. Having
   both present BLOCKS, because it's ambiguous which gate decides the merge (and would let a valid experiment
   smuggle a terminal exit). The two artifacts are **mutually exclusive on one PR**.
2. **The terminal gate discharges HIGHs via `covers_findings`, not via #151 statuses.** When a close audit
   ran (`stage` ∈ `data`,`close`), **every** HIGH in the close-audit findings record MUST appear in
   `covers_findings` — a HIGH that is neither covered nor (impossibly, since triage is absent) responded-to
   BLOCKS. This is the "explicit terminal *no-valid-conclusion* state" pass-path #151 names: the HIGH passes
   because the whole experiment is declared no-valid-conclusion, with evidence — not because it was
   individually `deferred`.
3. **No close audit (terminal before close — `blocked`/`abandoned` at `provision`/`run`) ⇒ no triage
   artifact and no findings record are expected.** `covers_findings` is empty/omitted, and the gate does not
   require a close audit that never had inputs to run. (`abandoned`/`invalid` *after* the close audit ran
   still must cover its HIGHs.)
4. **Vocabulary consistency.** This design deliberately does **not** add a per-finding status; #151 owns the
   `{fixed | justified | deferred}` per-finding vocabulary and #145 owns `{justified | deferred}` for
   surviving design findings. The terminal path is a **whole-experiment** disposition, one level up from
   per-finding — so it adds one experiment-level field (`state`) and reuses #151/#145's finding **ids**
   (via `covers_findings`) rather than a parallel status enum. This keeps the three artifacts consistent:
   per-finding responses live in #151/#145; the experiment-level "no valid conclusion" lives here.

### 6. The terminal close gate (deterministic, fail-closed)

The close gate (#157, the `run-experiment` merge wiring) selects its path by `TERMINAL.json`'s presence:

- **Absent** → the normal #151 valid-experiment gate (resolve every HIGH/MED via the triage artifact).
- **Present** → the **terminal gate**, which passes the merge **iff all** hold (any failure BLOCKS,
  fail-closed; a missing/malformed file is itself a BLOCK):
  1. File exists and parses as JSON with a supported `schema_version` MAJOR.
  2. `experiment` equals the `experiments/<exp>/` dir name.
  3. `state` ∈ the closed enum; `stage`/`decided_by` satisfy decision 3's table.
  4. `summary` non-empty; `decided_at` is valid RFC 3339.
  5. `evidence` has ≥1 entry; the **per-state kind requirements** of decision 4 are met; every committed-path
     `ref` resolves at the merge head; every URL `ref` is syntactically valid.
  6. The #151 triage artifact is **absent** (decision 5.1).
  7. If a close-audit findings record exists, **every HIGH** in it appears in `covers_findings` (decision 5.2);
     each `covers_findings` id exists in that record (no phantom ids).
  8. For `abandoned`, exactly one `decision_ref` evidence entry, authorized per the deferred attestation
     mechanism (decision 4).

The deterministic structural checks (1–8 minus the cross-family-judged content) run in the gate itself,
independent of any model — mirroring ship-change's `disposition_gate.sh` fail-closed structural pass and
#145's executor proceed rule. The *content* judgment (is this evidence actually a genuine wall / confound /
inconclusive result?) is the cross-family close audit's job (#130 §5 / #154) — the gate enforces that the
audit ran and its HIGHs are covered, not that it re-judges them. So: structure deterministic + fail-closed;
validity cross-family. A merged terminal record therefore has both a machine-checked structure and a
cross-family-audited cause.

### 7. What lands on `main`

A terminal experiment merges with `TERMINAL.json` in `experiments/<exp>/` alongside `DESIGN.md`,
`START.md`, `CLEARANCE.json`, `RESULTS.md`, and the audit outputs — the full trail, with the death
certificate as the headline. The PR is **merged**, not closed-unmerged: the record is the point (#130's
"never a record stranded in a perpetually-open PR"). The merged-record index (#155) shows the `state` so
"what did I run" distinguishes succeeded / informative-negative / `blocked` / `invalid` / `abandoned` /
`no-conclusion` at a glance. (Whether the index renders a badge is #155's call; this design only guarantees
the machine-readable `state` field it can read.)

## Alternatives considered

- **Two terminal states only (`failed` / `abandoned`).** Rejected: collapses three operationally-distinct
  causes (external wall vs design defect vs inconclusive evidence) whose *evidence requirements* genuinely
  differ — a single `failed` state can't encode "prove the wall" vs "prove the confound" vs "prove the
  null is uninterpretable," so the anti-dodge bar (decision 4) would be unenforceable.
- **A fifth `superseded` state.** Rejected as a sub-case of `abandoned` (decided_by owner, with the
  superseding design as the decision_ref) — adding it would split one owner-decision state into two with the
  same evidence rule. Folded in via the `summary` + decision_ref.
- **`null-conclusion` as a separate state from `no-conclusion`.** Rejected: identical semantics
  (run-completed-but-inconclusive). One name, folded (decision 1).
- **Reuse #151's per-finding `deferred` status for terminal exits (no separate artifact).** Rejected (this
  is exactly #151's "ordinary deferral must not silently close a valid experiment"): per-finding deferral on
  a valid experiment is a *different act* from declaring the whole experiment no-valid-conclusion. Conflating
  them lets a valid experiment quietly mark its inconvenient HIGH `deferred` and merge as if it concluded.
  The whole-experiment terminal disposition is one level up and mutually exclusive (decision 5).
- **Make the close review fully non-blocking for terminal records (merge-on-presence).** Rejected for the
  same reason #130 rejected a non-blocking close review: a terminal record with an unevidenced `abandoned`
  (or an `invalid` that's really a dodged finding) would land as a clean-looking "no conclusion." The gate
  must enforce evidence, fail-closed (decision 6).
- **A free-form `state` string (instance-extensible).** Rejected: a closed enum with a per-state evidence
  rule is the whole contract; an open string makes the evidence rule unenforceable and lets an instance
  invent an unaudited exit. New states are a deliberate schema bump (decision 1).
- **TOML to match #153's profile.** Rejected: this artifact is machine-produced and machine-consumed (like
  #145's `CLEARANCE.json` and #151's triage artifact), not human-authored config — JSON matches the other
  two record artifacts in `experiments/<exp>/` for one parser and one digest discipline. (#153's TOML is for
  *human-authored instance config*; records are JSON.)

## Blast radius

- **No runtime behavior ships in this PR** — doc-only design. It defines the `TERMINAL.json` schema + the
  terminal close gate's rules; the implementation is spawned `ready`/`blocked-by` children.
- **New product artifact (spawned child):** the `TERMINAL.json` schema reference doc + the deterministic
  terminal-gate check (a sibling of #151's triage check and #145's clearance check), invoked by the close
  gate.
- **Couples to** the close gate (#157, `run-experiment` merge wiring) — `TERMINAL.json` is its terminal
  pass-path; the terminal gate is built **with** / consumed by #157.
- **Reconciles with #151** (triage artifact): mutual exclusion + the `covers_findings` HIGH pass-path
  (decision 5). The two designs share finding ids and must agree on the close-audit findings-record id
  scheme — cross-referenced, not contradicted.
- **Reuses #145's** conventions (canonical-dir path, `sha256` digest, refuse-unknown-MAJOR, fail-closed
  proceed rule, the authorized-marker attestation pattern for `abandoned`) and **#146's** pointer-only/
  non-secret record rule (the file carries pointers + glosses, never raw artifacts).
- **Reads the canonical dir from #155 / #153** — `experiments/<exp>/` is where the file lives; this schema
  names the path *relative to* that dir, it does not resolve the dir.
- **Cross-family invariant (#154):** the *content* judgment behind `invalid`/`no-conclusion` rests on the
  cross-family close audit; this design enforces the audit ran and its HIGHs are covered, never re-judging —
  so it carries no cross-family knob of its own.

## Decomposition (spawned issues)

This is a **schema/contract** design. It fixes the enum, the evidence rules, and the gate's pass/fail logic;
the implementation is small and well-scoped.

**`ready` (no open design) — file on merge:**
- **`TERMINAL.json` schema doc + the deterministic terminal-gate check** — the schema reference (the field
  table + the state/stage/decided_by/evidence rules) and a structural validator (decisions 2–6's
  deterministic checks 1–7), with a producer/consumer test vector (a fixed `TERMINAL.json` → pass; the
  malformed/over-permissive cases → BLOCK), mirroring #145's `CLEARANCE.json` test vector. Independent of
  #157's wiring — the check is a pure function over a `TERMINAL.json` + the close-audit findings record.

**`blocked-by` (file once parents land):**
- **`run-experiment` terminal-close path** — the `run-experiment` step that *writes* `TERMINAL.json` when a
  run dies and routes the close gate to the terminal path. `blocked-by` **#157** (the close-gate/merge
  wiring it plugs into), **#151** (the mutual-exclusion check needs the triage artifact's presence/absence
  contract), **#150** (the helper that posts the `abandoned` authorizing marker, decision 4), and **#145**
  (the authorized-marker attestation pattern reused for `abandoned`).

## Rollout + rollback

Doc-only design PR; lands the schema + the terminal-gate contract on `main` via the `--scaffold` gate. Then
the `ready` schema-doc + validator child ships and is unit-smoked in isolation (the test vector: a valid
record of each of the four states passes; each anti-dodge violation — wrong `decided_by`, missing evidence
kind, uncovered HIGH, both artifacts present, dangling ref — BLOCKs) **before** the `run-experiment`
terminal-close path consumes it. Rollback is a normal revert of the spawned validator/skill edits — with no
terminal records yet written, there is nothing to migrate; the lifecycle falls back to the status quo where a
failed run simply has no first-class record (the problem this design fixes), with no data loss.
