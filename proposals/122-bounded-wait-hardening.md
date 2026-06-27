# Proposal: Harden scaffold background waits against silent forever-hangs (#122)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

An agent using the scaffold can wait on background work **forever** with nothing erroring. The incident
(orchestrator#2): during a `ship-change` merge gate, a `codex exec` review launched via `run_in_background`
blocked on stdin and never completed. Background-task notifications fire only on *completion*, the agent's
watcher grepped only for the *success* string, and there was no deadline and no liveness check — so a hung
run was indistinguishable from "still working." The wait only ended because the human interjected; otherwise
the agent would have idled indefinitely while compute billed.

The discipline that prevents this — *bound the wait, watch for stuck not just done, emit on the failure
path* — **does exist in the scaffold, but only inside the experiment-compute surfaces**: `run-experiment`'s
self-wake section states the full rule (done-marker + liveness + positive-progress + look-again deadline),
and `gpu-job` has a TTL watchdog. The harness-wide failure mode is **not** experiment-specific: it bit a
`ship-change` review wait, a non-compute background task. The two surfaces where the scaffold itself tells an
agent to wait on a background process — the `verify-claims` reviewer-quiet note and the `ship-change` /
RUNBOOK reviewer-latency policy — currently teach only the *"don't kill it too early"* half (an empty
findings file is not a hang) and say nothing about the *"but bound the wait and act on the stuck path"*
half. A fresh agent reading those at point of need learns patience, not a deadline. There is no single
canonical statement that **every** scaffold background wait must be bounded, so the rule lives implicitly in
one skill and is absent exactly where the incident happened.

## Approach

Add the **smallest canonical rule** and wire the existing scoped homes to it — no new helper, no new code
path. The rule is operating discipline (substrate-general, applies to any background wait an agent performs),
so its canonical home is the agent-facing constitution, `AGENTS.md`:

1. **`AGENTS.md` — one canonical "Bounded background waits" rule** under Rules. Any wait on background or
   external work (a `run_in_background` task, a detached driver, a review subprocess, a poll loop) must have:
   a **deadline** (a time bound the wait exits on, not only the success marker); a **liveness / positive-
   progress check** (process alive AND output advancing — "no done-marker yet" can't distinguish working from
   wedged); and a **failure/timeout path that wakes the agent or fails visibly** (silence is not progress —
   the watcher must emit on stuck, not only on done). It names `run-experiment`'s self-wake as the worked,
   substrate-specific instance for autonomous detached runs, so the constitution states the principle once and
   the skill keeps the operational detail.

2. **`verify-claims` SKILL reviewer-quiet note** — keep the "absent/empty findings file is not a hang" half,
   add the missing half: still bound the wait with a deadline + liveness check; an absent file *past the
   deadline with no live process* IS the stuck signal. Point at the canonical rule.

3. **`ship-change` SKILL + RUNBOOK reviewer-latency policy** — the surface the incident hit. The latency
   thresholds already say "inspect at 5 min, suspicious at 10"; make explicit that those thresholds *are* the
   deadline + liveness check the canonical rule requires, and that a stuck reviewer must be acted on (the
   failure path), not waited on forever. Point at the canonical rule.

`run-experiment` already carries the full discipline; it gets a one-line pointer that its self-wake section is
the experiment-surface instance of the canonical rule, so the two don't drift.

This satisfies the acceptance criterion two ways: a fresh agent discovers the bounded-wait discipline **at
point of need** (each waiting surface now states or points at it, not just the experiment skill), and the
changed surfaces are doc/prose in `AGENTS.md` + skills, covered by the repo's existing deterministic checks
(disposition-sync stays green since the `DISPOSITIONS` block is untouched; version bumps on the touched
plugins) and the fake-HOME discovery smoke for any touched plugin.

## Alternatives considered

- **A reusable bounded-wait helper script** (e.g. a `bounded_wait.sh` that wraps a poll with a deadline +
  liveness). Rejected as larger than the problem: the waits are substrate- and tool-specific (CronCreate vs an
  until-loop vs a review subprocess vs a Monitor `timeout_ms`), so a single wrapper would either be too thin
  to add value or too prescriptive to fit them all. The failure is a *missing-discipline* failure, not a
  missing-tool failure — the fix is the rule + point-of-need pointers. A helper can be a tracked follow-up if
  a concrete repeated wait shape emerges.
- **Put the rule only in `run-experiment`** (where the full version already lives). Rejected: the incident
  was a `ship-change` review wait, not an experiment — scoping the rule to the experiment skill is exactly why
  it was absent where it was needed. The rule is harness-wide and belongs in the constitution.
- **Re-fix the proximate codex-stdin hang here.** Out of scope and already done — the `< /dev/null` redirect
  landed in the instance `ask-codex` skill (instance, not product). This issue is the *systemic* layer.

## Blast radius

Product, docs/prose only. `AGENTS.md` (constitution) + three skill SKILL.md files (`verify-claims`,
`ship-change`) and `run-experiment` pointer + the `ship-change` RUNBOOK. No script/behavior change, no new
code path, no manifest schema change beyond version bumps on the touched plugins. SWE pipeline unaffected
(no `wf.sh` change). No instance coupling.

## Rollout + rollback

Ships through the normal `ship-change` lifecycle (this PR). Rollback is the one-command revert of the squash
commit — it's prose, so reverting simply removes the canonical rule and the pointers, restoring the prior
state with no migration. No staged rollout needed.
