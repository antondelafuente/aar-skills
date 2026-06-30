# 273 — Reshape design-experiment around data-collection, not interpretation

## Problem

The `design-experiment` flow bakes in **confirmatory / pre-registration epistemology**: Step 1 asks for "numeric
decision rules (what counts as the effect / no-effect / inconclusive; falsifiers; per-component reporting)," and
`audit_experiment --design` proactively reviews for "pre-registration completeness, claim-scope, power, decision-rule
soundness." But **most experiments here are measurement/exploratory** — *produce the number, plot it; the researcher
interprets afterward.* For those, the claim-machinery is overhead AND a spurious-finding generator: the auditor
dutifully attacks decision rules the researcher never wanted.

The evidence is two consecutive cases. Experiments #6 `midtrain-pareto` (research-lab design PR #28) and #7
`teacher-dependence` (PR #31) BOTH had design-audits whose **every HIGH finding was about the *verdict*** (power-to-resolve
a gap; a trait-strength confound *of a claim*), and BOTH were reframed by the researcher to **"just plot the data, no
verdict"** — which dissolved exactly those findings. The findings that *survived* the reframe and were genuinely useful
were all **measurement-validity** (comparability, the murder/exfil component split, pinning the variable, the data-audit)
— never claim-rigor.

## Approach

Adopt one principle: **an experiment's job is to produce trustworthy DATA; interpretation ("what does it mean") is a
separate step the researcher does afterward by looking at the data.** So the DESIGN pins **data collection** (reliable +
comparable) and states **what the data is designed to inform** — but NOT a pre-registered verdict on it; and the
`--design` audit checks **data-trustability**, not interpretation-rigor.

**The line:** purpose and lightweight qualitative reads are welcome; pre-registered verdicts and refutation thresholds are
not. Stating *what the data informs* is load-bearing — "trustworthy for what?" is undefined without it, and the
data-audit's "what would invalidate this" is already relative to it. What's removed is the machinery that decides *in
advance* what the number will *mean* (decision rules, falsifiers, pass/fail). This dissolves any exploratory-vs-confirmatory
mode toggle — there is **one job: reliable data for a stated purpose** — and aligns the design stage with the **data-audit
gate, which is already exactly this shape** ("is the data what it claims to be").

The two edits are **coupled and ship atomically** (see "Coupling"). Across three files plus two version bumps:

**Edit 1 — `design-experiment/SKILL.md` (Step 1 + the audit description + frontmatter) and `CHECKLIST_TEMPLATE.md`.**
- **DROP** from required DESIGN content: numeric decision rules, falsifiers, "what counts as effect/no-effect/inconclusive,"
  pass/fail verdicts, claim-scope and power pre-registration.
- **KEEP** the data-collection spine: WHY + **what question the data is designed to inform** (the purpose — explicitly
  retained; NOT a claim), what's measured (canonical metric + EXACT eval definitions), **comparability** (the anchor-gate,
  co-measurement on one scale), confound controls that corrupt *the number*, **pinning the independent variable**, the
  data-audit + manifest, cost / wave-shape. Provenance/anchor verification stays.
- **RESULTS line:** RESULTS *describes* the data (numbers/plot) and **may include a lightweight, clearly-marked qualitative
  read** ("the data looks like X") that stays separable from the numbers. It must NOT make a rigorous pre-registered
  claim/verdict; the rigorous interpretation is the researcher's separate analysis step. (Postdiction hygiene survives in
  the lighter form: a read fitted from the data is unverified — test on fresh data if load-bearing.)
- Reframe Step 1's header/intent from "pre-registration (hypothesis + decision rules)" to **"data-collection spec (what
  reliable, comparable data this produces, and what it's designed to inform)."** Update the frontmatter description and the
  `CHECKLIST` gate that currently reads "judged against the pre-registered DESIGN rules."

**Edit 2 — `audit_experiment.sh` `--design` prompt (surgical).**
- Make the **claim-dimensions CONDITIONAL**: "pre-registration completeness," "decision-rule soundness," "claim-scope,"
  "power" fire **only if the design actually asserts a rigorous interpretation/claim/verdict.** A measurement design that
  states a *purpose* but no decision rule must **NOT** be flagged "incomplete." Backstop preserved: if a design *does* make
  a strong claim, catch it.
- **Lead with data-trustability** dimensions: comparability / co-measurement, confounds-that-corrupt-the-number, honest
  component + parse% reporting, variable-pinning, anchor reproduction, and is-this-the-right/cheapest-data-for-its-purpose.
- Emit a **qualitative "evidence-quality" read** ("this will produce a clean comparable number" / "this confound will muddy
  it" / "cheaper way to get the same data") — the good/bad signal the researcher *does* want — without forcing pass/fail on
  interpretation.

## Coupling (why atomic)

Edit 1 alone leaves the audit demanding decision rules the template no longer provides → every design flagged "incomplete."
Edit 2 alone leaves the template still manufacturing claims for the audit to attack. They must land in one PR.

## Preserve (do NOT weaken)

Measurement-rigor stays **mandatory**: the anchor / comparability gates, the data-audit (both layers, all three surfaces),
pinning the independent variable, honest component / parse% reporting. The failure mode that earns its keep is *"a clean
pipeline producing a confidently-wrong NUMBER"* — that's measurement, and it stays. This change removes only
**interpretation-rigor** (claims / verdicts), the researcher's separate later step. The conditional backstop means a design
that *does* assert a verdict still gets the full claim-audit — nothing is lost, only made non-proactive.

## Alternatives considered

- **An explicit exploratory-vs-confirmatory mode toggle** — rejected by the principle itself: there is one job (reliable
  data for a stated purpose). A toggle re-introduces the confirmatory machinery as a first-class path and the "which mode
  am I in" overhead; the conditional audit backstop already covers the rare design that asserts a verdict.
- **Drop the claim-dimensions outright** (not conditional) — rejected: a design that genuinely makes a strong pre-registered
  claim should still be audited for it. Conditional firing keeps that backstop while removing the proactive spurious
  findings.
- **Edit only the SKILL guidance, leave the auditor** — rejected: that's the non-atomic half that flags every reshaped
  design "incomplete."

## Blast radius

Two plugins: `experiment-lifecycle` (`design-experiment/SKILL.md`, `templates/CHECKLIST_TEMPLATE.md`) and `verify-claims`
(`audit_experiment.sh` `--design` prompt). Both get a `plugin.json` version bump. No code-path/interface change — prompt +
guidance text only; the `--design` invocation, output format, and gate wiring are unchanged. Affects how *future* designs
are written and audited; in-flight experiments are unaffected. Reversible (revert the PR). Does not touch `--data`,
`--scaffold`, `--code`, or `verify_claim`.

## Rollout + rollback

Ship via ship-change (cross-family `--scaffold` + `--code`). After merge, new designs are written as data-collection specs
and the `--design` audit leads with data-trustability, firing claim-dimensions only on designs that assert a verdict.
Rollback: revert the PR — the prior pre-registration guidance and proactive claim-audit return.
