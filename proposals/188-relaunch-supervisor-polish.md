# Proposal: relaunch-supervisor first-cut — 3 merge-gate polish findings (#188)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The relaunch-supervisor first cut (#170, merged in #186) shipped the supervisor decision contract and the
record-state extensions it consumes. Its final-diff `--code` merge-gate review surfaced three MED findings (0
HIGH, so they did not block) that were filed as this `ready` follow-up. All three are small, real
asymmetries between what the contract *says* and what the helper / generated brief actually do; left
unfixed they make the relaunch path either non-idempotent or unable to launch the very successor it exists
to launch.

1. **The decision tree's clear-on-relaunch is asymmetric.** In `references/RELAUNCH_SUPERVISOR.md` the
   alive-but-requested branch does `relaunch(run); clear-relaunch(run)`, but the session-gone branch does a
   bare `relaunch(run)`. A crashed run that *also* had a pending `request-relaunch` would have the request
   survive its own relaunch and re-trigger on the next pass. The request is still fail-closed and
   stop/close-cleared (no infinite loop), but the documented contract should be symmetric: a relaunch should
   clear the request that may have driven it, on *every* branch.

2. **`request-relaunch` can set the flag with no `handoff_path` bound.** `cmd_request_relaunch` lets an
   active record through even when `handoff_path` is still null — yet `request-relaunch` is exactly the
   can't-resume-in-place signal, and the supervisor's fallback for that case, `launch_successor`, *needs* a
   bound `handoff_path` to point the fresh successor at. So the one operation whose whole purpose is "I can't
   resume in place, recover me from disk" can leave the supervisor with nothing to recover from.

3. **The generated executor brief doesn't bind `session_handle`.** The resume contract now says
   `create <run-id> --handoff … --session-handle <opaque>`, and the supervisor reads `session-handle` to know
   *which* session a desired-active run maps to (it is how `session_is_alive` and `resume_same_session` find
   their target). But `design-experiment`'s `START_TEMPLATE.md` / `CHECKLIST_TEMPLATE.md` still emit the old
   `create <run-id> --handoff <TEMP.md>` form, so a normally-generated brief binds a run-id with no probeable
   session handle — the supervisor can tell the run is desired-active but not which process it is.

## Approach

Three scoped fixes, each landing in the canonical home the #170 design already established (the reference
owns the contract; the helper owns the record semantics; the design-experiment templates own the generated
brief). No new state, no new subcommands, no behaviour the #170 design didn't already intend — this PR makes
the as-built match the contract.

**Finding 1 — make `relaunch(run)` own the clear (doc-only).** In `RELAUNCH_SUPERVISOR.md`, move the
`clear-relaunch` *into* the `relaunch(run)` expansion (after a successful resume/launch) and drop the
now-redundant `clear-relaunch(run)` from the alive-but-requested branch. The contract then reads "any
relaunch clears the request that may have driven it" symmetrically, with no behaviour left to the two call
sites. This also matches the helper's existing reality: `clear-relaunch` is already idempotent and allowed on
a still-active record, so clearing after a crash-driven relaunch (where no request was set) is a harmless
no-op write — the contract is just made to say so.

**Finding 2 — require a bound `handoff_path` at `request-relaunch`, and let it bind one atomically.** Add an
optional `--handoff PATH` to `request-relaunch` (same `require_val` non-empty guard as `create`/`update`), and
make the command fail closed unless, *after* applying any passed `--handoff`, the record has a non-empty
`handoff_path`. So:
- `request-relaunch <run-id>` succeeds only if the record already carries a handoff (the normal case — the
  agent bound it at `create`/`update`);
- `request-relaunch <run-id> --handoff <PATH>` binds the handoff and sets the request in one atomic
  read-modify-write under the existing per-record lock (the case where a `StopFailure`-style hook wants to set
  both at once);
- `request-relaunch <run-id>` on a record with no handoff yet **fails closed** with a clear message, instead of
  recording a "recover me" request the supervisor can't honour.

The check is done inside the locked python writer (it already has the merged record in hand), so it is atomic
with the request-set and can't race a concurrent `update`. This keeps the same-session `--continue` path
unaffected — that path is the crash branch, which does not depend on `request-relaunch` at all — while
closing the gap for the successor-fallback path that does.

**Finding 3 — add an instance-filled `--session-handle` placeholder to the templates.** Update the
`create` invocation in `START_TEMPLATE.md` (the Resilience section) and `CHECKLIST_TEMPLATE.md` (the
resume-contract BLOCK gate) to `create <run-id> --handoff <TEMP.md path> --session-handle <opaque session
handle>`, with a one-line note that the handle is instance-owned and opaque (a tmux session name, a systemd
unit, a pid-file path — whatever the instance launcher owns). These are substrate-neutral skeletons the
instance fills, so the placeholder is the right shape: it makes a generated brief bind a probeable session by
default without putting any instance command into the product.

The helper's smoke (`run_supervision_record_smoke.sh`) gains coverage for the finding-2 behaviour: a
`request-relaunch` on a no-handoff record fails closed; one with `--handoff` succeeds and binds the handoff;
one on a record that already has a handoff succeeds without re-passing it.

## Alternatives considered

- **Finding 2: require an *existing* `handoff_path` only (no `--handoff` flag).** Rejected as the sole fix:
  it forces the caller to do a separate `update --handoff` before `request-relaunch`, which is two writes and
  a race window where the request could be observed before the handoff lands. Accepting `--handoff` lets a
  hook bind both atomically; still requiring a bound handoff after the fact keeps the fail-closed guarantee.
- **Finding 2: silently no-op `request-relaunch` when no handoff is bound.** Rejected: a silent no-op on the
  recover-me path is exactly the dangerous direction — the agent thinks it asked to be recovered and nothing
  happens. Fail closed and loud, consistent with every other guard in this helper.
- **Finding 1: clear the request in *both* call sites instead of folding into `relaunch`.** Rejected: that
  is the asymmetry the finding flagged restated — two call sites that must each remember to clear. Folding it
  into `relaunch(run)` is the single-home fix.
- **Finding 3: make `--session-handle` required by the helper (reject a `create` without it).** Rejected as
  out of scope and too strong: `session_handle` is legitimately optional in the helper (a run may bind it via
  a later `update`, and the field defaults to null by design). The gap is that the *generated brief* didn't
  prompt for it; fixing the template is the right altitude. Making it a hard helper requirement is a separate,
  larger decision the #170 design deliberately did not take.

## Blast radius

**Product (this repo):**
- **Edit:** `plugins/experiment-lifecycle/skills/run-experiment/references/RELAUNCH_SUPERVISOR.md` — move
  `clear-relaunch` into the `relaunch(run)` expansion (finding 1, doc-only).
- **Code:** `plugins/experiment-lifecycle/skills/run-experiment/scripts/run_supervision_record.sh` —
  `cmd_request_relaunch` gains `--handoff`; the locked writer fails closed unless a handoff is bound after the
  request (finding 2). Header usage/state-machine comment updated to match.
- **Edit:** `plugins/experiment-lifecycle/skills/run-experiment/scripts/run_supervision_record_smoke.sh` —
  finding-2 coverage.
- **Edit:** `plugins/experiment-lifecycle/skills/design-experiment/templates/START_TEMPLATE.md` and
  `.../CHECKLIST_TEMPLATE.md` — add the `--session-handle <opaque>` placeholder (finding 3).
- **Bump:** `plugins/experiment-lifecycle/.claude-plugin/plugin.json` version + a `CHANGELOG.md` entry
  (required by `.aar-ci/checks.sh` for any non-manifest change in the plugin).

The `request-relaunch` change is the only behaviour change, and it is strictly more restrictive (it rejects a
previously-accepted call shape — `request-relaunch` with no handoff). No other transition changes; the
fake-HOME behaviour smoke surface is preserved.

**Instance (NOT this repo):** the systemd unit / bash supervisor loop and the concrete command mapping are
unchanged — this PR only tightens the contract and the record the instance consumes, plus the generated brief.

No change to the SWE pipeline (`aar-engineering`) or to `gpu-job`.

## Rollout + rollback

The doc and template changes are inert (docs/skeletons). The one behaviour change tightens `request-relaunch`
to fail closed without a bound handoff — a previously-accepted call shape now errors with guidance, so any
instance hook that called `request-relaunch` without first binding a handoff would surface immediately at the
call (loud, not silent) and is fixed by adding `--handoff`. Rollback is the standard one-commit revert;
reverting restores the looser `request-relaunch` and the old templates with no other runtime effect.
