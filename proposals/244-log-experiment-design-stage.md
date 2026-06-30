# 244 — log-experiment: support the design-stage PR (the two-PR experiment flow)

## Problem

The experiment flow is **two PRs**: a **design PR** pre-launch (gated by the design-audit) and a **results
PR** post-run (gated by the close-audit). `log-experiment` today only handles the results stage. Its
classifier knows exactly two kinds:

- `DESIGN.md` **and** `RESULTS.md` → **experiment** (gate: close-audit present + triaged), and
- anything else → **note** (gate: deterministic secret scan only).

A **design-only** dir — `DESIGN.md` + `DESIGN_AUDIT.md`, no `RESULTS.md` yet — falls through to **note**. So
logging an experiment *at design time* opens a PR gated only by a secret scan: the **design-audit is never
verified**. The pre-launch PR that pre-registration depends on is exactly the one that isn't design-audit-gated.
The two-PR flow isn't fully supported.

## Approach

Add a third classification, **design-stage**, between experiment and note:

| the dir has… | classified as | gate |
|---|---|---|
| `DESIGN.md` **and** `RESULTS.md` | experiment | verify the close-audit is present + triaged |
| `DESIGN.md`, **no** `RESULTS.md` | **design-stage** (NEW) | verify the **design-audit** is present (`DESIGN_AUDIT*.md`) |
| anything else | note | deterministic secret scan |

The gate mirrors the close path's *shape*: it **verifies the design-audit ran** by requiring at least one
`DESIGN_AUDIT*.md` (the numbered chain `DESIGN_AUDIT.md`, `DESIGN_AUDIT2.md`, … is the validity record
`design-experiment` emits). Fail-closed: a `DESIGN.md` with no `DESIGN_AUDIT*.md` BLOCKs and is surfaced to
the researcher, exactly as a results dir with no close-audit does today. No `RESULTS.md` is guaranteed by the
classification, so the design PR's diff is the design files; running `log-experiment` again at close then
classifies the same dir as **experiment** and opens the results PR (diff = the new `RESULTS.md`/`AUDIT.md`,
the design files already on main).

**Why presence, not a separate triage artifact (the one asymmetry with close).** The close gate requires
**two** files — `AUDIT.md` *and* `AUDIT_RESPONSE.md` — because `run-experiment` writes a distinct triaged
response file. The design-audit triage convention is different by design: `design-experiment` surfaces the
audit's *survivors* to the **researcher live**, who arbitrates and clears the design — there is no standard
`DESIGN_AUDIT_RESPONSE.md` artifact to require. The act of the researcher running `log-experiment` at design
time **is** the clearing. So the design-stage gate proves the audit *ran* (the chain exists) and fail-closes
on its absence; it deliberately does not invent a triage-response file the convention doesn't produce. This
is the same posture the experiment gate already takes (it verifies presence, not the science).

The `KIND` override gains the new value: a `KIND` file may contain `experiment`, `design-stage`, or `note`.

## Interface

No new flags or config. Same `log-experiment.sh <registry-dir> [--dry-run]`. The only behavior change: a
`DESIGN.md`-only dir now classifies as `design-stage` (was `note`) and gates on the design-audit. `--dry-run`
classifies + gates and stops, as before. PR title / commit / approval body interpolate `$KIND` and so read
`Log design-stage: <REL>` with no further change.

## Alternatives considered

- **Require a `DESIGN_AUDIT_RESPONSE.md` (exact close mirror)** — rejected: `design-experiment` produces no
  such artifact; the design triage is the live researcher arbitration + the numbered `DESIGN_AUDIT*.md`
  chain. Requiring a file the convention never writes would make the gate un-satisfiable, not stricter.
- **Add a secret scan to the design-stage gate too** — rejected for the default: the experiment gate (which
  this mirrors) does not scan, and a design dir is a pre-registration the researcher just authored and is
  actively reviewing. Keeping the two `DESIGN.md`-bearing kinds consistent (audit-gated, not scanned) is the
  simpler, more predictable rule. (If a design dir ever needs scanning, the `KIND: note` override forces it.)
- **Leave design dirs as `note`** (status quo) — rejected: that is precisely the bug — the design PR escapes
  the design-audit gate.
- **A separate `log-design` driver** — rejected: same branch/PR/approve/merge plumbing; a third classify
  branch is a few lines, a second driver is duplicated lifecycle glue.

## Blast radius

One plugin, two files: the `log-experiment.sh` classify + gate logic and the `log-experiment` SKILL.md table
+ gate prose. Plus the required `experiment-lifecycle` `plugin.json` version bump (0.3.7 → 0.3.8). Operates
on the research repo (research-lab), not on automated-researcher itself. Purely additive: a dir that
classified as `experiment` or `note` before still does (only `DESIGN.md`-without-`RESULTS.md`, which was
mis-bucketed as `note`, moves — and moves to a *stricter* gate). Separate from #242 (who pushes). Reversible
— revert the PR.

## Rollout + rollback

Ship via ship-change. After merge, `log-experiment` supports both legs of the two-PR flow: run it at design
time → design PR (design-audit gate), run it again at close → results PR (close-audit gate). Rollback: revert
the PR; the classifier returns to two kinds and design dirs fall back to the `note` gate. No stored state, so
nothing to migrate either direction.
