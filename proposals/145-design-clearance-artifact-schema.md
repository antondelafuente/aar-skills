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
versioned, and committed to the branch in its own clearance commit so it lands on `main` in
`experiments/<exp>/` exactly like the rest of the record. It is not a new source of truth about the design —
the `DESIGN.md` + the posted `--design` audit are that — it is the **decision record on top of them**: the
human's verdict, frozen against a SHA.

**The artifact is not self-attesting.** A designer-written file that merely *says* "anton cleared this" is
forgeable and unverifiable — the executor would be trusting a string. So the clearance binds to **two
independently-verifiable external facts**, neither of which the designer can fabricate in the JSON: (a) a real
**clearance event** authored on the experiment PR by an authorized actor and bound to the cleared SHA, which
the executor re-fetches from GitHub via the shared helper (#150) and verifies (below); and (b) the
**structured `--design` audit record** the responses are checked against (below), not a hand-copied count. The
JSON records *pointers and the human's per-finding verdict*; the two facts it points at are verified at the
source, so the gate cannot be passed by editing the file alone.

**The clearance event is NOT a merge-satisfying GitHub `APPROVED` review.** #130 decision 2 is explicit: the
design review gates the *run*, never the merge — only the *close* gate posts the final merge-satisfying native
APPROVE. If clearance were a native `APPROVED` review it would satisfy branch protection and could merge an
*un-run* experiment, defeating the close gate and the "main only receives closed experiments" promise. So the
clearance event is a **non-merge-satisfying signal**: a structured **clearance comment** (a canonical PR
comment carrying a machine-readable marker — `clearance: cleared`, the cleared SHA, the actor) posted by the
authorized actor. The executor re-fetches it via the helper and verifies author + SHA + marker; it never reads
as a GitHub approval, so it cannot satisfy the merge gate. (A GitHub *review thread* could also carry it if the
helper guarantees it is posted as a COMMENT/REQUEST_CHANGES event, never APPROVE — but the canonical-comment
form is the safe default precisely because it is structurally incapable of satisfying branch protection.)
`approval.event_kind` records which form was used so the executor checks the right surface; the field is named
`approval` for continuity but the event is a clearance signal, not a merge approval.

### The schema

`experiments/<exp>/CLEARANCE.json`:

```json
{
  "schema_version": 1,
  "experiment": "exp-slug",
  "decision": "cleared",
  "cleared_at": "2026-06-28T19:04:00Z",
  "approval": {
    "approver": "anton",
    "approver_role": "design-approver",
    "event_kind": "pr_comment",
    "event_ref": "https://github.com/<owner>/<repo>/pull/<n>#issuecomment-<id>",
    "event_id": "IC_kwDO...abc123",
    "actor": "anton",
    "cleared_sha": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a"
  },
  "brief_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
  "brief_files": ["DESIGN.md", "START.md"],
  "brief_blobs": {
    "DESIGN.md": "b1946ac92492d2347c6235b4d2611184",
    "START.md": "591785b794601e212b260e25925636fd"
  },
  "design_audit": {
    "audit_ref": "https://github.com/<owner>/<repo>/pull/<n>#pullrequestreview-<id>",
    "audit_commit": "9f3a1c4e8b2d6a0f5c7e9b1d3f5a7c9e1b3d5f7a",
    "findings_record": "experiments/<exp>/audits/design-audit.json",
    "findings_sha256": "9b74c9897bac770ffc029102a200c5de...",
    "summary": { "high": 0, "med": 2, "low": 4 }
  },
  "finding_responses": [
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

`brief_blobs` are illustrative short digests; the implementation uses Git's own per-file blob OIDs (or a
sha256 per file), captured at clearance — see the brief-integrity rule. The `--design` audit is persisted as
a **structured `findings_record`** (a machine-readable finding list: stable id, severity, text per finding)
committed alongside the brief, and `findings_sha256` pins its content so the response set is validated against
the *actual* findings, not a copied integer. **The findings record is the one from the audit on the cleared
brief** (the final audit, after any fixes) — see "The fix loop" below; that is why the example shows `high: 0`
and the surviving responses are `justified`/`deferred`, never `fixed`.

**Field contract:**

| Field | Type | Required | Meaning |
|---|---|---|---|
| `schema_version` | int | yes | Schema generation; executor rejects an unknown major it cannot parse (fail-closed). |
| `experiment` | string | yes | Experiment slug; must equal the `experiments/<exp>/` dir name (cross-check against path). |
| `decision` | enum `cleared` \| `blocked` | yes | The verdict. Only `cleared` permits a run; `blocked` is a terminal record (see Terminal states). |
| `cleared_at` | RFC-3339 UTC | yes | When the verdict was recorded. |
| `approval.approver` | string | yes | Identity recorded as having arbitrated (human-readable). |
| `approval.approver_role` | string | yes | Fixed `"design-approver"` today; a field, not a literal, so a future delegated-approver policy needs no schema bump. |
| `approval.event_kind` | enum `pr_comment` \| `non_approve_review` | yes | Which **non-merge-satisfying** surface carries the clearance signal, so the executor fetches the right one. Never a GitHub `APPROVED` review (#130 decision 2). |
| `approval.event_ref` | string (URL) | yes | Human pointer to the clearance event. Pointer only — never a payload (#130 record-sensitivity). |
| `approval.event_id` | string | yes | The GitHub node-id of the clearance comment/review the executor **re-fetches** to verify; not trusted from the JSON. |
| `approval.actor` | string | yes | The GitHub login that authored the clearance event. Must be an **authorized approver** (instance-profile policy, #153) — the executor checks the fetched event's author equals this and is authorized; a designer cannot self-clear by writing a string. |
| `approval.cleared_sha` | 40-hex SHA | yes | The commit the clearance event names (carried in the comment marker / review SHA). Must equal `brief_commit`. |
| `brief_commit` | 40-hex SHA | yes | The commit carrying the cleared brief — the **final** audited brief (the binding target, #130 decision 2). |
| `brief_files` | string[] | yes | The immutable brief inputs whose content is integrity-checked; `["DESIGN.md","START.md"]`. **`CHECKLIST.md` is deliberately excluded** — the executor mutates it as run evidence (see "Checklist is run-mutable" below), so it is not a drift-checked input. Listed (not assumed) so the verifier can assert presence. |
| `brief_blobs` | object (path→digest) | yes | Per-file content digest (Git blob OID or sha256) of each `brief_files` entry **at `brief_commit`**, captured at clearance — the integrity anchor the executor compares current content against (see brief-integrity rule). |
| `design_audit.audit_ref` | string (URL) | yes | Pointer to the posted `--design` PR review the verdict arbitrates. Pointer only — never the audit payload (#130 record-sensitivity). |
| `design_audit.audit_commit` | 40-hex SHA | yes | The commit the `--design` audit reviewed. Must equal `brief_commit`; if they differ the executor blocks (the audited design is not the cleared brief). |
| `design_audit.findings_record` | string (path) | yes | Committed path of the **structured** machine-readable audit finding list (id, severity, text per finding) the responses are validated against — not a copied count. |
| `design_audit.findings_sha256` | hex | yes | Content hash of `findings_record`, pinning the exact finding set the responses answer (so an edited file is detected). |
| `design_audit.summary` | `{high,med,low}` ints | yes | The audit's `SUMMARY` counts; a fast cross-check, but completeness is validated against `findings_record`, not this number. |
| `finding_responses` | object[] | yes (may be empty only if the findings record has zero HIGH and zero MED) | One entry per HIGH/MED finding in `findings_record`. |
| `finding_responses[].id` | string | yes | The finding identifier; **must match an id present in `findings_record`** (validated, not trusted). |
| `finding_responses[].severity` | enum `high` \| `med` | yes | Echoes the finding's severity (LOW findings need no response). |
| `finding_responses[].status` | enum `justified` \| `deferred` | yes | The verdict on a finding that **survives** into the cleared brief. |
| `finding_responses[].evidence` | string | yes | Why: the justification or the deferral rationale. Non-empty. |
| `finding_responses[].followup_issue` | string | required iff `status=="deferred"` | The issue the deferral is tracked in. |

The status vocabulary is the close-gate triage artifact's `{fixed | justified | deferred}` **minus `fixed`**.
The reason is structural, not a divergence (see "The fix loop"): a `fixed` finding required a post-audit brief
change, so it cannot survive into a clearance bound to the *same* commit the final audit reviewed — a fix is
represented by the finding being **absent** from the cleared findings record, not by a `fixed` status. The
close gate keeps `fixed` because its fixes happen in-PR against the merge head; clearance's fixes happen by
re-auditing the corrected brief. So the two gates share the *surviving-finding* vocabulary
(`justified`/`deferred`) exactly — the consistency ask in #145/#130 — and differ only where the lifecycle
genuinely differs.

### The fix loop (why `audit_commit == brief_commit` is consistent with fixing findings)

The design audit can return HIGH/MED findings the designer wants to *fix*, not justify. Fixing a finding
changes the brief — which would break the invariant that the cleared brief is the *audited* brief. The loop
that resolves this, and the reason the proceed rule can safely require `audit_commit == brief_commit`:

1. Audit runs on brief commit *A*. Designer triages: fix some findings (edit `DESIGN.md`/`START.md`), justify
   or defer the rest.
2. If anything was **fixed**, the brief changed → the designer **re-runs `--design`** on the new brief commit
   *B*. (This is the same "any change forces re-clearance/re-review" property #130 already requires; a fix is a
   change.) Repeat until an audit run reviews the *current* brief with no findings the designer still intends
   to fix.
3. **Clearance binds that final commit**: `brief_commit` = the commit the *final* audit reviewed,
   `audit_commit == brief_commit`, and `findings_record` is that final audit's output. The only findings left
   in it are the ones the designer chose to **justify or defer** — never `fixed`, because a fixed finding is
   gone from the final audit. That is why `fixed` is not in the clearance vocabulary and why rule 5
   (`audit_commit == brief_commit`) is not in tension with fixing: fixes happen *before* the binding audit, not
   recorded against it.

So "fix a finding" is fully supported — it just resolves to *re-audit then bind the clean commit*, the
re-clearance loop, rather than a `fixed` annotation on a stale audit.

### Checklist is run-mutable (excluded from the drift check)

The executor *works* `CHECKLIST.md` during the run (ticking gates, recording evidence) — it is intentionally
mutated and committed as the run's evidence record (`run-experiment`'s "work the checklist as you go"). So it
**cannot** be a drift-checked immutable input: a content-equality rule over it would block the executor on its
own expected edits. Therefore `brief_files` is `["DESIGN.md", "START.md"]` only — the two inputs that *define*
the experiment and must not drift after clearance. `CHECKLIST.md` is still part of the brief commit and still
handed off; it is simply governed by the run-evidence contract, not the clearance integrity check. (If a future
need arises to pin the checklist's *instruction* content while leaving its *evidence* mutable, that is a split
of the file — out of scope here; this schema takes the simpler correct stance of not drift-checking it.)

### Path and produce/consume contract

- **Path / home.** `experiments/<exp>/CLEARANCE.json` — the canonical per-experiment dir on the research
  repo's `main` (#130 decision 1). Clearance is **its own commit on top of the brief commit**, not co-located
  in the brief commit: it is recorded *after* the audit and arbitration, and what binds it to the brief is the
  `brief_commit` field, not physical co-location. (Co-committing clearance with the brief would make the
  binding circular — you cannot name a commit's own SHA from inside that same commit — and would itself change
  the brief tree, re-triggering re-clearance.)
- **Producer = `design-experiment`** (the designer side). The clearance event itself is the authorized actor's
  **non-merge-satisfying clearance signal** on the experiment PR (the structured clearance comment / non-APPROVE
  review above) — that is what the executor verifies, so it must be authored by an authorized actor, not
  synthesized by the designer agent. After that event exists (against the *final*, post-fix-loop brief commit),
  `design-experiment` *records* it: it writes `CLEARANCE.json` with `decision:"cleared"`, the `approval` block
  fetched from the clearance event (`event_kind`, `event_id`, `actor`, `cleared_sha`), the arbitrated finding
  responses, `brief_commit` = the cleared SHA, and the `brief_blobs` digests; commits it; and only then hands
  off to the executor. A `decision:"blocked"` verdict is written instead when the authority declines to clear —
  a terminal record, no executor handoff (the precise blocked-state semantics are owned by #130's terminal-states
  child; this schema only reserves the enum value so the file shape is forward-compatible).
- **Consumer = `run-experiment`** (the executor side). Step 0, before any compute/API spend: read
  `experiments/<exp>/CLEARANCE.json`, **re-fetch and verify the clearance event** and the structured findings
  record (not trusting the JSON's copies), evaluate the proceed condition (below), and **block** (do not
  acquire a pod, do not call an API) on any failure, emitting the precise reason.

### Validation + fail-closed proceed rule

The executor proceeds **iff all** hold; **any** failure blocks (fail-closed — a missing/malformed file is a
block, never a pass). Crucially, rules 4, 6, and 7 verify against **external sources** (Git content, the
GitHub clearance event, the committed findings record), so the gate cannot be passed by editing the JSON alone:

1. **File exists and parses** as JSON with a `schema_version` the executor supports. Missing file, parse
   error, or unknown major version → BLOCK.
2. **`decision == "cleared"`.** Any other value (`blocked`, or absent) → BLOCK.
3. **`experiment`** equals the `experiments/<exp>/` directory name → else BLOCK (mis-filed artifact).
4. **Brief integrity (the re-clearance trigger).** Every file in `brief_files` (`DESIGN.md`, `START.md` —
   *not* the run-mutable `CHECKLIST.md`) exists at `brief_commit`, and the **current working-tree content** of
   each is byte-identical to its content at `brief_commit`. Concretely the executor compares content, not commit
   identity — `git diff --quiet <brief_commit> -- DESIGN.md START.md` must be clean, AND each file's current
   digest must equal its `brief_blobs` entry. (Commit-identity equality would be wrong: clearance is its own
   commit on top, so `HEAD != brief_commit` always — comparing SHAs directly would block every run. Content
   equality over the immutable inputs is the correct test.) Any drift-checked brief file touched after clearance
   → BLOCK with "brief changed since clearance — re-clear before running." This is #130's "any later change
   forces re-clearance," made mechanical.
5. **Audit binds the cleared brief.** `design_audit.audit_commit == brief_commit` → else BLOCK (the audited
   design is not the brief being run). Consistent with fixing findings via the fix loop above — the binding
   audit is the *final* one.
6. **Clearance event is real, non-merge-satisfying, and authorized.** The executor **re-fetches** the event
   named by `approval.event_id`/`event_kind` (via the shared helper, #150) and requires: it exists and is the
   declared kind; it is **not** a GitHub `APPROVED` review (a clearance event must be structurally
   non-merge-satisfying — #130 decision 2); its author equals `approval.actor`; `actor` is an **authorized
   approver** per the instance-profile policy (#153); and the SHA it names equals `approval.cleared_sha ==
   brief_commit`. A missing event, an APPROVE-typed event, an unauthorized actor, or a SHA mismatch → BLOCK.
   (This is what makes the artifact non-self-attesting: a designer-written `actor:"anton"` is worthless unless
   GitHub confirms anton posted the clearance event for that SHA.)
7. **Finding-response completeness, validated against the findings record.** The executor loads
   `design_audit.findings_record`, verifies its content hash equals `findings_sha256` (else BLOCK — tampered
   findings), then requires: every HIGH and every MED finding **id present in the findings record** has
   exactly one `finding_responses` entry with matching `id` and `severity`; every response `id` exists in the
   record (no phantom responses); every response has non-empty `evidence`; every `deferred` has a
   `followup_issue`. A HIGH/MED with no response, a phantom/mismatched id, an empty evidence, or a deferral
   with no issue → BLOCK. (`summary` is a fast cross-check only; the *record* is the denominator, so a
   hand-shrunk count can't hide an unanswered finding.)

The executor records the verdict (proceed or the block reason) to its run log / ledger, so the
proceed-decision is itself auditable. The block reason is a single precise line (which rule failed), never a
generic "not cleared."

### What this does NOT own (seams to siblings)

- **Who may approve / the authorized-approver policy** — `approval.approver_role` is a field so a future
  delegated-approver policy is a value change, not a schema change; *which* actors count as authorized is the
  instance-profile's call (#153). This schema requires the executor to check `actor` against that policy, but
  it does not define the policy.
- **Fetching/verifying the GitHub clearance event** — the read is performed via the shared GitHub-lifecycle
  helper (#150). This schema names what to fetch (`event_id`/`event_kind`) and the proceed condition (including
  the "must not be APPROVE" check); the helper owns the GitHub read. And the cross-family guarantee on the
  `--design` audit the responses answer is owned by the audit-runner cross-family contract (#154). This schema
  only *records results*; it must not become a second home for cross-family enforcement (the #130 decision-5
  boundary).
- **Emitting the structured `findings_record`** — `findings_sha256`/`findings_record` require a machine-readable
  audit finding list with **stable ids** (id, severity, text per finding). The audit engine
  (`verify-claims`/`audit_experiment`) currently emits markdown `FINDING:`/`SUMMARY:` text, not canonical JSON
  with ids, so this schema **depends on** a structured-audit-output capability (a thin parser of the existing
  markdown into a stable-id JSON record, or a small `verify-claims` emit-JSON mode). That capability is a named
  **prerequisite** of the consumer child (Rollout), not owned here — this schema only *consumes* the record.
- **How `experiments/<exp>/` is located** (repo / base branch / branch prefix) — the instance-profile
  interface (#153). This schema names the path *relative to* that dir; it does not resolve the dir.
- **Whether/how committed clearance content is sensitive** — the audit-derived content this artifact commits
  (`summary`, per-finding `evidence`, the `findings_record`) is governed by #130's **record-sensitivity /
  visibility contract**, which the umbrella makes a hard blocker for any committed audit-derived evidence. This
  schema constrains itself to **pointers** for the approval/audit *events* (`pr_ref`, `audit_ref` — URLs, never
  payloads), but the finding evidence text and the findings record are committed content, so the implementation
  children are **`blocked-by` the record-sensitivity contract** (see Rollout).
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
  two gate different events with different required fields (clearance needs the `approval` block + `brief_commit`
  + audit binding; triage needs the merge-head SHA + per-finding merge disposition). Sharing the **status
  vocabulary** captures the real overlap without forcing one file to serve two gates — and lets each evolve.
- **Parse `high=0` from the audit summary as the proceed rule (no per-finding responses).** Rejected for the
  same reason #130 rejects it for the close gate: the research protocol permits a HIGH to be *justified*, not
  only *fixed*, so a raw count would block a legitimately-justified design. The per-finding response set is
  what lets a justified HIGH proceed while an unanswered HIGH blocks.
- **Use a native GitHub `APPROVED` review as the clearance event.** Rejected: #130 decision 2 forbids it — a
  native APPROVE would satisfy branch protection and could merge an *un-run* experiment, defeating the close
  gate. Clearance must be structurally non-merge-satisfying (a structured comment / non-APPROVE event), and the
  proceed rule explicitly BLOCKs on an APPROVE-typed clearance event.
- **Record `fixed` findings in the clearance responses (one vocabulary with the close gate).** Rejected: a
  `fixed` finding implies a post-audit brief change, contradicting the `audit_commit == brief_commit` binding.
  Fixes resolve via the re-audit loop (the finding disappears from the final record), so clearance carries only
  `justified`/`deferred` — sharing the close gate's *surviving-finding* vocabulary without the structurally
  inapplicable `fixed`.

## Blast radius

- **Product skills** (`automated-researcher`): `design-experiment` gains "write `CLEARANCE.json` at
  clearance"; `run-experiment` gains "read + evaluate `CLEARANCE.json` as the pre-spend gate." These are the
  implementation `ready` children spawned from this design.
- **Scoped to the GitHub experiment-lifecycle path — NOT a global `run-experiment` change.** The fail-closed
  CLEARANCE step applies only on the #130 GitHub-PR experiment path (an experiment that has an
  `experiments/<exp>/` dir on a `run/<exp>` branch). Today's local brief handoff — a `run-experiment` that
  reads `DESIGN.md` + `START.md` + `CHECKLIST.md` from a working tree with no `experiments/<exp>/` / no
  experiment PR — is **unaffected**: the gate is the new GitHub path's contract, not a retrofit onto every
  existing/in-flight run. So no in-flight local run breaks for lack of a `CLEARANCE.json`. (Making the GitHub
  path the *default* is #130's own staged rollout, not this schema's.)
- **Canonical record path:** adds `CLEARANCE.json` + a committed structured `findings_record` to the
  `experiments/<exp>/` layout #130 establishes — event references are pointer-only (`event_ref`/`audit_ref`
  URLs), but the per-finding evidence + findings record are committed content governed by #130's
  record-sensitivity contract (see Rollout `blocked-by`).
- **Touches the shared GitHub-lifecycle helper (#150) as a consumer:** the executor needs a helper primitive
  to *fetch + verify a non-approve clearance event* (`event_id`/`event_kind` → actor/SHA/marker, and assert it
  is not an APPROVE). This is a read, not new mutation authority; it is in the helper's posting/read surface,
  not its merge-authority/trusted-base surface. Named here so #150 knows this consumer exists.
- **Depends on a structured-audit-output capability** (correcting the prior draft's "no `verify-claims`
  change"): the `findings_record` needs stable-id JSON findings, which the audit engine does not emit today.
  This is a named prerequisite of the consumer child (a thin markdown→JSON parser with id generation + a parser
  smoke, or a small `verify-claims` emit-JSON mode) — see Rollout.
- **Product, not instance.** The schema is product (it ships in the skills); the `CLEARANCE.json` files it
  produces land in the instance research repo, like every other experiment record. The authorized-approver
  *policy* is instance config (#153).

## Rollout + rollback

Doc-only design PR: lands the schema on `main` via the `--scaffold` gate, then spawns the implementation
`ready` child(ren):

0. **Prerequisite: structured `--design` audit output with stable ids** — a thin markdown→JSON parser of the
   existing audit `FINDING:`/`SUMMARY:` output (id generation + a parser smoke), or a small `verify-claims`
   emit-JSON mode. The `findings_record`/`findings_sha256` rules depend on it, so it lands before (or with) the
   consumer child.
1. **`design-experiment`: write `CLEARANCE.json` at clearance** — the producer step: after the authorized
   non-merge-satisfying clearance event exists against the final brief commit, record the `approval` block,
   finding responses, `brief_commit`, and `brief_blobs`; commit + a writer-side schema assert.
2. **`run-experiment`: read + evaluate `CLEARANCE.json` as the pre-spend gate (GitHub path only)** — the
   consumer step + the 7-rule fail-closed proceed rule, with smokes that a missing/malformed file, a
   brief-drifted file, a forged/absent clearance event, an APPROVE-typed event (must BLOCK — clearance is not
   merge-satisfying), and a tampered findings record each BLOCK, and that a local-handoff run with no
   `experiments/<exp>/` is untouched.

Both implementation children are filed **`blocked-by`**: the GitHub-lifecycle helper (#150, for the
clearance-event fetch/verify primitive + the resolved commit/branch identity), the instance-profile interface
(#153, for *where* `experiments/<exp>/` lives and the authorized-approver policy), the structured-audit-output
prerequisite (step 0), **and #130's record-sensitivity / visibility contract** (for what finding-evidence
content may be committed vs redacted vs pointer-only — the umbrella makes this a hard blocker for committed
audit-derived evidence). They are filed at design-merge so the dependency graph is explicit, and become
actionable when those parents land.

Rollback is a normal revert of the spawned skill edits: the lifecycle falls back to the status-quo
(clearance lives only in the design conversation, executor trusts the handoff) with no data loss — the schema
file is additive and unread by anything until the consumer step ships.
