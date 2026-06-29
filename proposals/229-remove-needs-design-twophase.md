# Proposal: Remove `needs-design` + the two-phase design machinery (#229)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The `needs-design` disposition isn't just a label — it **triggers a fragmenting process**: the two-phase
flow where a `needs-design` issue gets a design PR whose entire job is to **decompose it into `ready`
children**. So the disposition *structurally manufactures sub-tickets*. #130 is the proof: a one-sentence
idea ("an experiment = a PR") was put through a `needs-design` pass and shattered into **11 sub-issues**
(schemas, grammars, finding-id contracts), most of which were themselves `needs-design` — design spawning
more design. Nothing shipped.

On top of that the **#137 disposition-aware reviewer** added an `altitude`/`umbrella` axis so the merge
gate would apply a *different* deferral rule to `needs-design`-umbrella PRs — machinery that only exists
*because* of the two-phase, and was itself over-engineering.

The model we've settled on (and used for ~5 PRs this session): **`needs-shaping` → a conversation with
the human → a few `ready` tickets; `ready` tickets carry the design in the implementing PR.** That makes
`needs-design` and its two-phase redundant *and* harmful.

## Approach

A pure-removal simplification (**net −161 lines**). Remove:

- **Taxonomy:** `needs-design` from AGENTS.md, all three `references/DISPOSITIONS.md` (ship-change +
  feedback-loop), and `DISPO_RE`. Re-point `needs-shaping` to scope into `ready` only. Delete the
  "Design → implementation link" two-phase rule.
- **wf.sh:** `finish --design` / `DESIGN_MODE` and every branch it gated — `finish` keeps only the
  `--code` merge gate. `disposition_gate` drops its design branch → **code PRs close `ready` issues**,
  full stop.
- **#137 reviewer:** the `DISPO_ALTITUDE` / umbrella-vs-code `DEFERRAL_RULE` selection in
  `audit_experiment.sh` → one mode-neutral rule (a defect in the merged change is **never** deferrable;
  `deferred_out_of_scope` only for genuine unrelated follow-ups). Delete `disposition_inject_smoke.sh` +
  its `checks.sh` block.
- **Docs:** the ship-change SKILL two-phase section, RUNBOOK, design-experiment / feedback-loop /
  RELAUNCH_SUPERVISOR references.

**Kept (core, unchanged):** the finding-disposition triage + the merge gate — the reviewer judges each
prior finding's disposition *on the merits* and blocks on any unresolved HIGH.

## Alternatives considered

- **Keep `needs-design` for "big" work** — rejected: even big things decompose into a *few* `ready` PRs
  *through conversation* (#130), and the two-phase structurally manufactures sub-tickets regardless.
- **Keep #137** — rejected: its `umbrella` case *is* `needs-design`, so it goes moot here, and it was on
  the over-engineering list.

## Deferred follow-ups (deliberate, not oversights)

1. `disposition_gate.sh` + its 32-case smoke still carry a now-**unreachable** `umbrella` /
   `deferred_to_child_design` branch (nothing sets `umbrella` anymore). Dead-but-harmless; surgically
   re-cutting the 32-case smoke is high-risk, so it's a clean separate follow-up.
2. Deleting `disposition_inject_smoke.sh` drops test coverage of the *retained* merge-gate injection; a
   slimmed replacement smoke is a follow-up.

## Blast radius

4 plugins (aar-engineering, verify-claims, feedback-loop, experiment-lifecycle) + the constitution. Pure
removal; the core triage/gate path is untouched. All `bash -n` clean; `disposition_gate_smoke` +
`fd_state_smoke` pass; `wf.sh dispositions` → `ready needs-shaping blocked parked other`. Plugins
patch-bumped.

## Rollout + rollback

Reversible — revert the PR. No data migration; existing `needs-design`-labelled issues should be
re-triaged to `ready` / `needs-shaping` (the #130 set already was).
