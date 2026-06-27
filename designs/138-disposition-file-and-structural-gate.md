# Proposal: disposition file + deterministic structural gate (#138)

> Implements **#137** (the stateful, disposition-aware merge gate), slice 1 of 3. This is the foundational
> data + deterministic layer; #139 adds the packet generator + disposition-aware reviewer, #140 the
> fresh-eyes companion. The full architecture ADR is #137; this doc is the on-main record for the structural
> layer it lands.

## Problem

ship-change's merge gate blocks on the **raw** HIGH count from the latest reviewer pass, with no notion of a
HIGH that was *fixed*, *refuted*, or *validly deferred*. #137's fix is a **disposition-aware** gate: the
author records a machine-readable disposition per finding, and the gate blocks only on *unresolved* HIGHs.
That requires two new primitives, both delivered here: a **committed disposition file** (the canonical state)
and a **deterministic structural gate** that validates it fail-closed *before* any model judgment runs.

Splitting structure (deterministic) from validity (model judgment) is load-bearing per #137: the script
checks the disposition file is well-formed and complete; the model (slice #139) judges whether each
disposition is *sound*. Keeping structure out of the prompt makes the model's job smaller and ungameable on
the mechanical parts.

## Approach

### The disposition file

One committed JSON file per branch/PR at **`.aar-ci/dispositions.json`** (each branch is one PR, so
per-branch is per-PR). `jq` already underpins `.aar-ci`, so JSON keeps parsing deterministic and tested.

```json
{
  "altitude": "umbrella",
  "findings": [
    { "id": "F1", "round": 1, "severity": "HIGH",
      "status": "fixed", "evidence": "clearance binds the brief commit SHA", "commit": "82e41fa" },
    { "id": "F2", "round": 1, "severity": "HIGH",
      "status": "deferred_to_child_design", "child_issue": "#139", "reason": "open sub-design; dependents blocked-by" },
    { "id": "F3", "round": 2, "severity": "MED",
      "status": "refuted", "reason": "the helper no longer owns mutation authority" }
  ]
}
```

- `altitude` ∈ {`umbrella`, `implementation`} (declared once; #137 puts it in the artifact's front matter,
  mirrored here so the gate reads one place).
- `status` ∈ {`fixed`, `refuted`, `deferred_to_child_design`, `deferred_out_of_scope`, `unresolved`}.

### The deterministic structural gate

A standalone, independently-testable script — **`scripts/disposition_gate.sh <dispositions.json> <findings>`**
— where `<findings>` is the reviewer's finding list (id, severity). It runs **before** the model reviewer
and **fail-closes** (any error / malformed file / missing entry → BLOCK, never PASS). Checks:

1. Every **HIGH** finding has a disposition entry (missing → BLOCK).
2. `status` is in the allowed set (else BLOCK).
3. `deferred_to_child_design` requires a `child_issue` link **and** `altitude == umbrella` (else BLOCK — code
   PRs and non-umbrella designs cannot defer to a design child).
4. `deferred_out_of_scope` requires a `followup_issue` link (else BLOCK).
5. `fixed` requires a `commit` present **and** reachable in this PR's branch (else BLOCK).
6. Any HIGH with `status == unresolved` → BLOCK.
7. A malformed/absent file when HIGHs exist → BLOCK (fail-closed). No HIGHs + no file → PASS (nothing to gate).

Output: `DISPOSITION-GATE: PASS` or `DISPOSITION-GATE: BLOCK <reason>` + non-zero exit on block, so the
caller (the merge gate, wired in #139) fails closed.

### Scope boundary

This slice ships the **file schema + `disposition_gate.sh` + its smoke test**. It does **not** wire the gate
into `finish` or change the reviewer — that is #139 (which produces the findings the gate consumes and
supplies the per-mode deferral judgment). #138 is testable in isolation with synthetic findings + dispositions.

## Alternatives considered

- **YAML disposition file.** Rejected: bash/`jq` parse JSON deterministically and it is already the `.aar-ci`
  idiom; YAML needs an extra dependency and is whitespace-fragile in shell.
- **Structured PR comment as the state.** Rejected per #137: comments are useful *context* for the model, but
  the gate needs a deterministic artifact to parse; a committed file is diffable, reviewable, and versioned.
- **Put the checks in the model prompt.** Rejected: structure must be deterministic and ungameable; the model
  judges only semantic validity (#139).

## Blast radius

- **SWE pipeline only** (`aar-engineering`): one new script + its smoke; a documented file convention. No
  change to `finish`/the live gate yet (that is #139), so landing this is inert until wired — safe to ship
  first.
- New `.aar-ci/dispositions.json` convention (optional until #139 consumes it).
- `aar-engineering` version bump.

## Rollout + rollback

Inert on landing (nothing calls `disposition_gate.sh` until #139), so rollout risk is minimal — it ships the
mechanism and its tests, then #139 turns it on. Rollback is a normal revert of this PR; nothing depends on it
until #139 lands.
