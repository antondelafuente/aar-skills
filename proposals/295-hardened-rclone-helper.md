# Proposal: Hardened rclone copy helper — kill the recurring `-L` / symlink-loss footgun as shared code (#295)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Every GPU driver calls `rclone` raw, so the same rclone-usage footguns recur run after run. Because
there is no shared home to fix them once, each fix has only ever been a passive note in
`experiment_gotchas.md` — and notes don't prevent recurrence. The most expensive of these is a
**silent data-loss** class: `rclone copy` of a tree WITHOUT `-L` quietly SKIPS symlinks, logs a
`NOTICE: … Can't follow symlink without -L/--copy-links`, and still exits **0**. Some of those
symlinks (HF-cache snapshot links; cross-run dataset/adapter dedup links) point OUTSIDE the copied
tree, so when the source is deleted the data is genuinely gone — a clean pipeline that produced an
incomplete archive it reported as "done" (Neel-volume migration 2026-06-09; the HF-cache pre-stage
that landed blobs but no usable snapshot 2026-06-06).

The companion footguns in the same family (sourced from `experiment_gotchas.md` lines 43, 65, 66,
112, 115, 116): existence checks written with **single-file `rclone lsf`** (exits 0 with empty
stdout on a missing file, and can *phantom* a just-deleted leaf name → false skip / false pass), and
**"ready" gates keyed off a size threshold** (which race a still-uploading producer → a consumer
pulls a partial tree and misses the last shard).

Notably, the existence-check and ready-gate rules were **already** drained into shared code when the
model-staging + serve helpers landed in `plugins/gpu-job/skills/gpu-job/scripts/job_lib.sh`:
`r2_exists` / `wait_r2` list the **directory** and `grep -qx` the name (never single-file `lsf`);
`r2_done` gates on real object **bytes** via `rclone lsl` (never a size threshold); `pull_model`
verifies an exact object-count/byte manifest (`_STAGED.json`) written LAST. The **one rule with no
shared home yet is the copy rule** — the `-L` + "treat any `Can't follow symlink` NOTICE as an
INCOMPLETE copy" pair — and it is exactly the data-loss one. `stage_model.sh` hand-rolls `rclone copy
-L` inline; `pull_model` uses a raw `rclone copy` with no `-L` and no NOTICE check.

## Approach

Add ONE hardened copy helper, **`r2_copy`**, to `job_lib.sh` — the existing home of the rclone rules
(it already holds `r2_exists`, `r2_done`, `wait_r2`, `pull_model`), so all rclone footgun-fixes stay
in one sourceable library rather than fragmenting across a second file.

**Public API (new):**

```
r2_copy <src> <dst> [extra rclone args…]
```

Semantics — it bakes in the two copy-rule requirements:

1. **Always `-L`.** `-L` is injected unconditionally (a caller cannot omit it), so symlinks are
   FOLLOWED and their target bytes land as real files — no silent skip, no cross-tree data loss.
2. **A `Can't follow symlink` NOTICE ⇒ INCOMPLETE copy ⇒ non-zero return.** The helper captures
   rclone's combined output (streamed live via `tee`, so a long copy still shows progress) and, if
   any `Can't follow symlink` line appears, returns non-zero with a directed message **even when
   rclone itself exited 0** — the exact swallow that made the bare copy read as success. It also
   propagates rclone's own non-zero exit (via `PIPESTATUS`, so it is correct without `pipefail`).

The other three rules already have shared, correct implementations in `job_lib.sh`; this proposal
**strengthens their header docstrings** to state the contract explicitly ("never single-file `lsf`",
"never a size threshold", ".done-sentinel/exact-bytes only") so the rule is discoverable at the call
site, but does not change their behavior.

**Reference call-site (in-tree caller):** route `pull_model`'s pull through `r2_copy`. `pull_model`
pulls a materialized flat tree from R2 (no symlinks), so `-L` is a no-op and the NOTICE never fires —
but it gives `r2_copy` a real caller in the shipped code and adds belt-and-suspenders NOTICE
detection to the pull path at zero behavior cost. (`stage_model.sh` is box-side and does not source
`job_lib.sh`; its inline `-L` copy is correct and left as-is — adoption there follows separately.)

**Self-test:** a new `rclone_helper_smoke.sh` (offline; stubs `rclone` on PATH) asserts the behavior
the JSON/syntax checks can't: `r2_copy` **returns non-zero when a stub emits a `Can't follow symlink`
NOTICE yet exits 0** (the core bug), passes `-L` in its args on a clean copy, and propagates a
stub's non-zero exit; plus `r2_exists` true/false via directory-listing (not single-file `lsf`).
Wired into `.aar-ci/checks.sh` on `job_lib.sh` / smoke change, mirroring the existing
`multi_adapter_smoke.sh` gate. Bump `gpu-job` `plugin.json` 0.2.5 → 0.2.6.

## Alternatives considered

- **A separate `rclone_lib.sh`.** Rejected: `job_lib.sh` already owns the rclone rules
  (`r2_exists`/`r2_done`/`wait_r2`/`pull_model`); a second file would split the copy rule from the
  existence/ready rules it belongs with, and force a move of the existing helpers (bigger blast
  radius) to keep them together. One cohesive "R2" section in the existing lib is simpler.
- **Rewire every driver + `stage_model.sh` now.** Out of scope by ticket ("adoption follows
  separately"). We ship the helper + one reference call-site + a self-test; broad adoption is a
  separate change so this one stays small and reviewable.
- **Detect the NOTICE by parsing rclone's `--stats`/JSON logs.** Overbuilt; a substring match on the
  stable `Can't follow symlink` NOTICE string is what every incident actually keyed on, and it is
  the string rclone has emitted across the versions we run.
- **Only inject `-L`, skip the NOTICE check.** Rejected: `-L` prevents the *common* skip, but a
  dangling/cross-device link can still make rclone emit the NOTICE and skip; failing closed on the
  NOTICE is the guarantee that a "succeeded" copy is actually complete.

## Blast radius

Product SWE-pipeline scaffold, `gpu-job` plugin only:
- `plugins/gpu-job/skills/gpu-job/scripts/job_lib.sh` — one new function (`r2_copy`), strengthened
  docstrings on `r2_exists`/`r2_done`/`wait_r2`, and `pull_model`'s copy line routed through
  `r2_copy` (behavior-preserving on a flat tree).
- `plugins/gpu-job/skills/gpu-job/scripts/rclone_helper_smoke.sh` — new offline self-test.
- `.aar-ci/checks.sh` — one new smoke-gate stanza.
- `plugins/gpu-job/.claude-plugin/plugin.json` — version bump.

No instance drivers change; adoption is opt-in as drivers source the helper. `job_lib.sh` is only
*sourced*, never auto-executed, so the only runtime effect is on code that calls `r2_copy`
(today: `pull_model`, on a symlink-free tree).

## Rollout + rollback

Low risk — additive. The one behavior change (`pull_model` gains `-L` + NOTICE detection) is a no-op
on the materialized flat trees it pulls. Rollback is the standard one-commit revert of the merged
squash (RUNBOOK "One-command revert"); no state or migration. If `r2_copy`'s NOTICE detection ever
false-positived on a legitimate copy, a caller can fall back to raw `rclone copy -L` — the helper is
additive, not a choke point every path must traverse.
