# Proposal: Session self-reap at close — symmetric with pod-teardown (#282)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`run-experiment`'s close protocol tears down the experiment's **pod** but leaves the executor's **session**
(its process) running idle after the run is done. Claude Code is process-per-session — each finished executor
holds its conversation resident (~300–530 MB, verified 2026-07-01) — so on a heavy batch day the finished-but-
unreaped sessions accumulate and can exhaust a small orchestrator box, OOM-killing the cross-family audits that
transiently need memory (a real 2026-07-01 incident: ~4–5 stale sessions ≈ ~2 GB, four consecutive
`audit_experiment --design` OOM-kills, cleared only by manually killing the finished sessions).

Close-time cleanup is **asymmetric**: pod yes, session no. There is a pod-teardown path and a `pod_reaper`
backstop, but no session equivalent. The record survives on disk (transcripts are resumable), so the *process*
is pure waste once a run has closed — nothing is freed because no step frees it.

This is a product gap in the close *protocol* (when to reap), even though the *mechanism* to kill a session is
instance-specific. The product should own the WHEN; the instance supplies the HOW — exactly the split already
used for pod teardown (the product says "tear down per your profile / via `gpu-job`"; the instance supplies the
account key and delete mechanics).

## Approach

Add a **terminal "reap your session" step** to the Step-5 Close protocol, invoked through an **instance seam**,
mirroring pod-teardown. Scope here is **self-reap only**; the periodic **session-janitor** backstop (the
`pod_reaper` analog for a crashed close) is a deliberate fast-follow (see Alternatives).

The product already carries the two things this needs, so the change is *wiring an existing seam*, not new
infrastructure:

- `run_supervision_record.sh` already stores an **opaque, instance-owned `session_handle`** ("a tmux session
  name, a systemd unit, whatever the instance's launcher owns — the product never interprets it") and prints
  it via `session-handle <run-id>`.
- The close finalizer already drives the record to the terminal **`closed`** state (`close <run-id>`).

**The three changes:**

1. **`run_supervision_record.sh`: add `is-closed <run-id>`** — exit 0 iff the record is `closed`; a
   missing/corrupt/`stopped`/still-active record is exit 1 (fail-closed). This is the exact predicate for
   "clean close" and mirrors the existing `is-desired-active`. It is the machine guard that a parked/blocked
   run (which is *desired-active*, never `closed`) can never be reaped.

2. **New product helper `scripts/reap_session.sh <run-id>`** — the substrate-neutral reap, invoked as the
   terminal close action:
   - **Guard (fail-closed):** require `is-closed <run-id>`; otherwise refuse and exit non-zero **without
     reaping** (a parked/blocked/active/unknown run is never reaped).
   - **Resolve the handle:** `session-handle <run-id>`; if unset/empty → nothing to reap, exit 0.
   - **Invoke the instance seam:** if `EXPERIMENT_SESSION_REAP_CMD` is set, exec it with the opaque handle as
     the sole argument (`$EXPERIMENT_SESSION_REAP_CMD "$handle"`) — this is the terminal action, nothing runs
     after it. **No tmux, no session-name convention, nothing instance-specific is hardcoded in the product.**
   - **Unset seam → documented no-op:** if `EXPERIMENT_SESSION_REAP_CMD` is unset, log one line and exit 0.
     This is what makes the product change safe to land before any instance wires the seam, and keeps every
     other instance (and the fake-HOME smoke) working unchanged.

   The seam is an env-var indirection, the same style as `gpu-job`'s `API_KEY_ENV` / the reaper's provider
   command — the instance exports `EXPERIMENT_SESSION_REAP_CMD` (via its execution profile / `~/.config`) to
   point at its own killer (on this box: `tmux kill-session` keyed on the handle). That instance wiring is a
   box change, out of scope for this product PR.

3. **`SKILL.md` Step 5: add the close step** — "**Reap your session (the terminal action).**" Placed *after*
   the self-audit-the-close step, as the very last thing in Close, with the load-bearing guards stated in
   prose: fires ONLY on a clean close (the record is `closed`); a **parked/blocked/errored** run keeps its
   session for resume (it is desired-active, and only its pod is torn down — unchanged); the **transcript
   persists on disk** so this frees the process, not the record. Plus a one-line entry in the Step-5
   quick-reference. The step invokes `reap_session.sh <run-id>`; if the instance has no session-teardown seam,
   it is a no-op.

Version-bump `experiment-lifecycle`'s `plugin.json` (behavior change). The fake-HOME smoke gains coverage for
the two product-side behaviors that don't depend on any instance: `reap_session.sh` **no-ops** when the seam is
unset, and **refuses** (non-zero, no invocation) when the record is not `closed`.

## Alternatives considered

- **Do both self-reap and the janitor backstop in one PR.** Rejected for this PR (deferred, not dropped).
  Self-reap is the actual fix — it frees memory the instant a run closes, which is what prevents the OOM. The
  janitor only catches the rarer *crashed-close* case, is pure instance code (a `pod_reaper` analog reading
  records + experiment-dir state on a timer), and getting its lease-style safety predicate right is most of the
  work. Splitting keeps this change tight and lands the OOM fix now; the janitor is a tracked follow-up.
- **Self-discovery instead of the recorded handle** (walk the process tree for `--remote-control <name>`, as
  `restart-self.sh` does). Rejected as the *product* contract: process-walking is instance-specific and belongs
  behind the seam. The product should pass the opaque `session_handle` it already records; the instance's reap
  command may self-discover if it wants.
- **Hardcode `tmux kill-session` in the close step.** Rejected — it's the exact substrate-coupling the seam
  pattern exists to prevent; it would break any non-tmux instance and the fake-HOME smoke.
- **Pure prose, no helper.** Rejected — the guard (`is-closed`) and the unset-seam no-op are behavior worth
  centralizing in one testable helper rather than re-derived by each executor, matching how `close`,
  `log-experiment`, and `audit_experiment` are already helper-invoked from the prose.

## Blast radius

Product scaffold (`experiment-lifecycle` plugin): one new small helper (`reap_session.sh`), one new subcommand
(`is-closed`) on an existing helper, prose additions to `run-experiment/SKILL.md`, a `plugin.json` version
bump, and fake-HOME smoke coverage. **Behavior is a no-op on every instance that does not set
`EXPERIMENT_SESSION_REAP_CMD`** — including the smoke harness — so nothing existing changes until an instance
opts in. No change to pod teardown, the audit gates, `log-experiment`, or the supervision record's existing
states. The instance-side reap command (tmux) and the periodic janitor are **out of scope** (box change +
tracked fast-follow).

## Rollout + rollback

Roll out by merging through this lifecycle. After merge, the box wires the seam separately
(`EXPERIMENT_SESSION_REAP_CMD` → a `tmux kill-session` script keyed on the handle), reviewed as an instance
change; until then the new step is a logged no-op. Rollback is a plain revert of this docs+helper change — no
migration, no state to unwind (the supervision record's schema gains no persisted field; `is-closed` only
*reads* the existing `closed` flag).
