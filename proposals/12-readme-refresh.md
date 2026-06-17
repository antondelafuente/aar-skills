# Proposal: bring the README up to date (#12)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The top-level `README.md` is stale and undersells the repo. Its module table lists only **gpu-job** and
**verify-claims**, both at "v0.1" — but the repo now ships **four** plugins at very different versions
(gpu-job 0.1.6, verify-claims 0.7.0, experiment-lifecycle 0.2.0, aar-engineering 0.3.0). `experiment-lifecycle`
and `aar-engineering` aren't mentioned at all, the install examples only install two modules, and there's no
hint of the **two-layer** structure (the shipped research plugins + the `aar-engineering` SWE pipeline that
builds them, with agents reviewing each other's PRs). A reader gets an out-of-date and much smaller picture
than what's actually here.

## Approach

A documentation-only refresh of `README.md`, in the existing voice (the thesis, "if you are a coding agent",
the modules table, install/update/feedback):

- **Modules table:** all four plugins with **current versions** and one-line "what your agent learns"
  descriptions — gpu-job, verify-claims, experiment-lifecycle, aar-engineering. Drop or re-tag the stale
  "planned" rows that are now subsumed (e.g. watch-run is covered by experiment-lifecycle's self-wake).
- **Two-layer framing:** one short paragraph naming the split — the research plugins (what an agent uses to
  do the research) vs the `aar-engineering` SWE pipeline (how the product builds/reviews/ships itself, agents
  as the engineers). Keep it brief; the detail lives in AGENTS.md.
- **Install/update examples:** include all the currently-shipped modules a new user would want.

No code, no behavior, no new dependency — prose only.

## Alternatives considered

- **Leave it** — rejected: a stale front-page README misrepresents the product and the install steps omit
  half the modules.
- **Full rewrite** — rejected: the voice + structure are good; this is a freshness pass, not a redesign.

## Blast radius

`README.md` only — documentation, human-facing. No product code, no SWE-pipeline code, no instance config.
Purely additive/corrective prose.

## Rollout + rollback

Trivial + reversible: one squash commit; `git revert` if ever needed. No state, no migration. Ships through
the normal lifecycle — and is the **first PR through the fully-enforced pipeline** (codex-engineer[bot] native
approval required before merge).
