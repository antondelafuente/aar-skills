# Proposal: Design-clearance artifact schema — the pre-run gate's machine-readable record (#145)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (two-phase, Step 1 of 2); spawns `ready` issues for the implementation.
> Child of #130 (experiments through GitHub). Sibling foundation designs: #150 (shared GitHub-lifecycle
> helper), #153 (instance-profile interface), #154 (audit-runner cross-family contract).

## Problem

When an experiment runs through GitHub (#130), the human clears the design *before* the run, and only then
is the brief handed to a fresh zero-context executor that spends real compute and API budget. The executor
is, by construction, brand new: it did not watch the design conversation, it did not see the human say
"cleared," and it cannot read intent. So before it touches a pod or an API key it must answer one question
from files alone — *is this design actually cleared to run, and is the brief in front of me the one that was
cleared?* — and it must answer it **fail-closed** (no clearance found = do not run).

#130 settles the *model* for this (decision 2, "design approval blocks the run" + "clearance binds to the
reviewed commit"): clearance is recorded against the one commit that carries the full brief
(`DESIGN.md` + `START.md` + `CHECKLIST.md`), and any later change to that brief forces re-clearance. But the
umbrella deliberately leaves the concrete artifact open. Today there is **no file** the executor can read,
no defined fields, and no proceed/block rule — so "the executor verifies the brief commit before any spend"
is an unbacked promise. This design defines that artifact: what it is called, where it lives, what it
contains, who writes it, and the exact rule the executor evaluates to decide proceed-vs-block.

This is the design-gate analogue of the close-gate's triage-artifact (the sibling `needs-design` child of
#130, not yet filed). The two gate **different events** — clearance gates the *run*, triage gates the
*merge* — but they share a per-finding response vocabulary, and this design keeps them consistent so an
executor and a reader learn one finding-response shape, not two.

## Approach

Define a single committed file, `CLEARANCE.json`, that lives in the experiment's canonical working directory
(`experiments/<exp>/`, the durable per-experiment home #130 decision 1 establishes). It is written once by
the **designer** side (`design-experiment`) at the moment the human arbitrates the design audit, and it is
read by the **executor** side (`run-experiment`) as the very first thing it does, before acquiring any
compute. It records *who* cleared the run, *which brief commit* they cleared, and *a response to every
surviving HIGH/MED design-audit finding* — and the executor recomputes the current brief commit and refuses
to run unless it matches the cleared one with a clean, complete set of finding responses.

The artifact is **plain JSON** (machine-read by the executor; trivially human-read in the PR), schema-
versioned, and committed to the branch as part of the clearance commit so it lands on `main` in
`experiments/<exp>/` exactly like the rest of the record. It is not a new source of truth about the design —
the `DESIGN.md` + the posted `--design` audit are that — it is the **decision record on top of them**: the
human's verdict, frozen against a SHA.

### The schema

`experiments/<exp>/CLEARANCE.json`:

```json
{
  "schema_version": 1,
  "experiment": "exp-slug",
  "decision": "cleared",
  "approver": "anton",
  "approver_role": "design-approver",
  "cleared_at": "2026-06-28T19:04:00Z",
  "brief_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
  "brief_files": ["DESIGN.md", "START.md", "CHECKLIST.md"],
  "design_audit": {
    "audit_ref": "https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-<id>",
    "audit_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
    "summary": { "high": 1, "med": 2, "low": 4 }
  },
  "finding_responses": [
    {
      "id": "H1",
      "severity": "high",
      "status": "fixed",
      "evidence": "Added held-out control arm in DESIGN.md §3 (this commit)."
    },
    {
      "id": "M1",
      "severity": "med",
      "status": "justified",
      "evidence": "Single-seed accepted: effect size >> documented run-to-run variance; see DESIGN.md §5."
    },
    {
      "id": "M2",
      "severity": "med",
      "status": "deferred",
      "followup_issue": "<owner>/<repo>#161",
      "evidence": "Cross-model generalization is a separate experiment; out of scope for this run."
    }
  ]
}
```

**Field contract:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | int | yes | Schema generation; executor rejects an unknown major it cannot parse (fail-closed). |
| `experiment` | string | yes | Experiment slug; must equal the `experiments/<exp>/` dir name (cross-check against path). |
| `decision` | enum `cleared` \| `blocked` | yes | The verdict. Only `cleared` permits a run; `blocked` is a terminal record (see Terminal states). |
| `approver` | string | yes | Identity of the human (or delegated authority) who arbitrated. Free-form instance identity. |
| `approver_role` | string | yes | Fixed `"design-approver"` today; a field, not a literal, so a future delegated-approver policy needs no schema bump. |
| `cleared_at` | RFC-3339 UTC | yes | When the verdict was recorded. |
| `brief_commit` | 40-hex SHA | yes | The **one** commit carrying the full brief; the binding target (#130 decision 2). |
| `brief_files` | string[] | yes | The brief files that commit must contain; fixed `["DESIGN.md","START.md","CHECKLIST.md"]` today. Listed (not assumed) so the verifier can assert presence. |
| `design_audit.audit_ref` | string (URL) | yes | Pointer to the posted `--design` PR review the verdict arbitrates. Pointer only — never the audit payload (#130 record-sensitivity). |
| `design_audit.audit_commit` | 40-hex SHA | yes | The commit the `--design` audit reviewed. Normally `== brief_commit`; if they differ the executor blocks (the audited design is not the cleared brief). |
| `design_audit.summary` | `{high,med,low}` ints | yes | The audit's `SUMMARY` counts — the denominator the response set is checked complete against. |
| `finding_responses` | object[] | yes (may be empty only if `summary.high==0 && summary.med==0`) | One entry per surviving HIGH and MED finding. |
| `finding_responses[].id` | string | yes | The finding identifier from the audit output (stable per audit run). |
| `finding_responses[].severity` | enum `high` \| `med` | yes | Echoes the finding's severity (LOW findings need no response). |
| `finding_responses[].status` | enum `fixed` \| `justified` \| `deferred` | yes | The response vocabulary — shared with the close-gate triage-artifact. |
| `finding_responses[].evidence` | string | yes | Why: the fix location, the justification, or the deferral rationale. Non-empty. |
| `finding_responses[].followup_issue` | string | required iff `status=="deferred"` | The issue the deferral is tracked in. |

The status vocabulary is intentionally the **same three** the #130 umbrella names for the close-gate triage
artifact (`fixed | justified-with-reason | deferred-with-issue`), collapsed to the lexical tokens
`fixed | justified | deferred` with `evidence`/`followup_issue` carrying the "-with-reason"/"-with-issue"
obligation as required sub-fields. Keeping one vocabulary across the two gates is the explicit consistency
ask in #145 and #130.

### Path and produce/consume contract

- **Path / home.** `experiments/<exp>/CLEARANCE.json` — the canonical per-experiment dir on the research
  repo's `main` (#130 decision 1). Clearance is **its own commit on top of the brief commit**, not co-located
  in the brief commit: it is recorded *after* the audit and arbitration, and what binds it to the brief is the
  `brief_commit` field, not physical co-location. (Co-committing clearance with the brief would make the
  binding circular — you cannot name a commit's own SHA from inside that same commit — and would itself change
  the brief tree, re-triggering re-clearance.)
- **Producer = `design-experiment`** (the designer side). After the human arbitrates the posted `--design`
  audit, the designer writes `CLEARANCE.json` with `decision:"cleared"`, the arbitrated finding responses,
  and `brief_commit` = the current tip-of-brief SHA, commits it, and only then hands off to the executor.
  A `decision:"blocked"` verdict is written instead when the human declines to clear — a terminal record,
  no executor handoff (the precise blocked-state semantics are owned by #130's terminal-states child; this
  schema only reserves the enum value so the file shape is forward-compatible).
- **Consumer = `run-experiment`** (the executor side). Step 0, before any compute/API spend: read
  `experiments/<exp>/CLEARANCE.json`, evaluate the proceed condition (below), and **block** (do not acquire a
  pod, do not call an API) on any failure, emitting the precise reason.

### Validation + fail-closed proceed rule

The executor proceeds **iff all** hold; **any** failure blocks (fail-closed — a missing/malformed file is a
block, never a pass):

1. **File exists and parses** as JSON with a `schema_version` the executor supports. Missing file, parse
   error, or unknown major version → BLOCK.
2. **`decision == "cleared"`.** Any other value (`blocked`, or absent) → BLOCK.
3. **`experiment`** equals the `experiments/<exp>/` directory name → else BLOCK (mis-filed artifact).
4. **Brief integrity.** `brief_commit` is an ancestor of (or equal to) the branch tip, every file in
   `brief_files` exists at that commit, and — the re-clearance trigger — the **current** content of the brief
   files matches their content at `brief_commit`. Concretely: the executor recomputes the brief commit
   (`git rev-parse HEAD` of the path / the tree-hash of `brief_files`) and requires it to equal
   `brief_commit`. If the brief was touched after clearance, the recomputed identity diverges → BLOCK with
   "brief changed since clearance — re-clear before running." This is the #130 "any later change forces
   re-clearance" property, made mechanical.
5. **Audit binds the cleared brief.** `design_audit.audit_commit == brief_commit` → else BLOCK (the audited
   design is not the brief being run).
6. **Finding-response completeness.** The count of `finding_responses` with `severity=="high"` equals
   `design_audit.summary.high`, and likewise for `med`; every response has a non-empty `evidence`; every
   `deferred` has a `followup_issue`; no HIGH or MED finding is left without a response. A short HIGH/MED
   count, an empty evidence, or a deferral with no issue → BLOCK.

The executor records the verdict (proceed or the block reason) to its run log / ledger, so the
proceed-decision is itself auditable. The block reason is a single precise line (which rule failed), never a
generic "not cleared."

### What this does NOT own (seams to siblings)

- **Who may approve / delegation policy** — `approver_role` is a field so a future delegated-approver policy
  is a value change, not a schema change; the policy itself is out of scope here.
- **Where the file is committed and the cross-family guarantee on the `--design` audit it points at** —
  owned by the shared GitHub-lifecycle helper (#150) and the audit-runner cross-family contract (#154). This
  schema only *records the result*; it does not run or post the audit, and it must not become a second home
  for cross-family enforcement (the #130 decision-5 boundary).
- **How `experiments/<exp>/` is located** (repo / base branch / branch prefix) — the instance-profile
  interface (#153). This schema names the path *relative to* that dir; it does not resolve the dir.
- **The blocked/terminal-state semantics** beyond reserving the `decision:"blocked"` enum value — #130's
  terminal-experiment-states child.
- **The close-gate triage artifact** — the sibling design; this one shares its vocabulary but gates a
  different event.

## Alternatives considered

- **No artifact — clearance is implicit in a posted PR review.** Rejected: a zero-context executor cannot
  reliably parse an arbitrary human review body into a proceed/block decision, and a PR review is not bound
  to the brief SHA the way a recorded `brief_commit` is. The whole point is a file the executor reads
  fail-closed; an implicit signal fails open.
- **Encode clearance as a Git signed tag / trailer instead of a file.** Rejected: a tag carries no
  per-finding response set and no audit binding; the finding-response completeness rule is the substance of
  the gate, and a tag has nowhere to put it. A committed JSON file lands in `experiments/<exp>/` with the
  rest of the record and is the same shape the reader/close gate already expect.
- **YAML / front-matter inside `DESIGN.md`.** Rejected: putting clearance *inside* the brief makes the
  binding circular (the clearance would change the brief it claims to clear, re-triggering re-clearance), and
  couples a machine-gate to prose parsing. A separate file binds cleanly by SHA.
- **Reuse the close-gate triage artifact verbatim (one schema, both gates).** Rejected as over-coupling: the
  two gate different events with different required fields (clearance needs `approver` + `brief_commit` +
  audit binding; triage needs the merge-head SHA + per-finding merge disposition). Sharing the **status
  vocabulary** captures the real overlap without forcing one file to serve two gates — and lets each evolve.
- **Parse `high=0` from the audit summary as the proceed rule (no per-finding responses).** Rejected for the
  same reason #130 rejects it for the close gate: the research protocol permits a HIGH to be *justified*, not
  only *fixed*, so a raw count would block a legitimately-justified design. The per-finding response set is
  what lets a justified HIGH proceed while an unanswered HIGH blocks.

## Blast radius

- **Product skills** (`automated-researcher`): `design-experiment` gains "write `CLEARANCE.json` at
  clearance"; `run-experiment` gains "read + evaluate `CLEARANCE.json` as run step 0, fail-closed." Both are
  the implementation `ready` children spawned from this design.
- **Canonical record path:** adds `CLEARANCE.json` to the `experiments/<exp>/` layout #130 establishes — one
  more committed record, pointer-only (audit URL, not payload), consistent with #130's record-sensitivity
  contract.
- **No change** to the audit engine (`verify-claims`), the GitHub helper (#150), or the instance-profile
  (#153): this design consumes their outputs/seams and records a decision on top. It is purely additive — a
  new file + two read/write steps.
- **Product, not instance.** The schema is product (it ships in the skills); the `CLEARANCE.json` files it
  produces land in the instance research repo, like every other experiment record.

## Rollout + rollback

Doc-only design PR: lands the schema on `main` via the `--scaffold` gate, then spawns the implementation
`ready` child(ren):

1. **`design-experiment`: write `CLEARANCE.json` at clearance** — the producer step + a writer helper/check
   that asserts the schema before commit. `blocked-by` the GitHub-lifecycle helper (#150) and the
   instance-profile interface (#153) for *where* it commits, but the artifact *shape + writer* is
   implementable against this schema now.
2. **`run-experiment`: read + evaluate `CLEARANCE.json` as the pre-spend gate** — the consumer step + the
   fail-closed proceed rule above, with a smoke that a missing/malformed/brief-drifted artifact BLOCKS.
   `blocked-by` the same two parents for path resolution.

Both implementation children are filed `blocked-by` the helper (#150) and instance-profile (#153) parents
(they need the resolved `experiments/<exp>/` location and the branch/commit identity to write/read against);
they are filed at design-merge so the dependency graph is explicit, and become actionable when those parents
land.

Rollback is a normal revert of the spawned skill edits: the lifecycle falls back to the status-quo
(clearance lives only in the design conversation, executor trusts the handoff) with no data loss — the schema
file is additive and unread by anything until the consumer step ships.
