# Proposal: Remove the #122 bounded-wait polling overlay from run-experiment (#224)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

PR #160 / issue #122 added a "bounded-wait" overlay to the run-experiment self-wake: each tick must
verify a **liveness** + **positive-progress** signal ("silence is not progress"), and the operational
guidance said to "watch with a background until-loop." On a substrate that **can't** arm a
`CronCreate`-style recurring wake (Codex), the only way to satisfy "continuously verify liveness" is a
**blocking watcher that keeps the executor turn alive** — i.e. polling every 1–3 min, in-turn. Each
poll re-reads the whole cached experiment context, which Codex bills, so a detached Codex run drained
the 5-hour quota. The pre-#122 model was a ~12-min self-wake that **sleeps** between done-marker checks.

## Approach

Remove the polling overlay; keep the real guarantee. Specifically:

- **Removed:** the per-tick "liveness + positive-progress" verify requirement; the "silence is not
  progress" bounded-wait emphasis; the "a blocking watcher that keeps the executor turn alive" framing;
  and the "background until-loop SSH-checking the done-marker" instruction.
- **Kept:** the self-wake itself; the per-tick **done-marker** + driver-log check; the **look-again
  deadline** (a deadline + a failure path *is* the bounded-wait guarantee); the don't-silently-park /
  mark-`CHECKLIST`-gate-`FAIL` discipline; the idle-cost teardown backstop.

So the executor returns to: arm the self-wake, end the turn, **sleep** between done-marker checks, wake
on the deadline / done / failure. A genuine hang is still caught — at the look-again deadline rather
than within 1–3 min, which at experiment scale is a few dollars of recoverable GPU (the trade #122
overpaid for). `experiment-lifecycle` patch-bumped 0.3.4 → 0.3.5.

## Alternatives considered

- **Also add a Codex cheap-sleep mechanism here** — no. Codex has no `CronCreate` wake; defining its
  equivalent is a real design task, split into **#223** (needs-design) so this PR stays a clean
  subtraction.
- **Pure delete of the whole paragraph** — would drop the legitimate "self-wake is a capability
  requirement / don't silently park" discipline, which is not part of the overlay. Kept.

## Blast radius

run-experiment skill (the executor's monitoring discipline) — no script change. The anti-hang
guarantee (deadline + failure path) is preserved; only the continuous-verify *pressure* is removed.
Interim Codex behavior: less polling pressure now, full Codex wait designed in #223.

## Rollout + rollback

Reversible — revert the lines + the bump. Behavior reverts to the pre-#122 ~12-min sleep cadence.
