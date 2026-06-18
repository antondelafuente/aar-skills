# Proposal: gpu-job stage_model — cache an HF model in the artifact store once (#37)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Every pod that needs a base model pulls it from Hugging Face at job start. That repeated pull is the root
of a cluster of paid, time-wasting gotchas the module otherwise has no answer for:

- **First-touch network-FS stalls** — a large model's first read on a pod's network filesystem can stall
  ~25 min before the job makes progress, all of it billed.
- **Missing-shard producer races** — a job that starts while the model is still arriving (or a partial
  HF cache) feeds the loader a missing `.safetensors` shard and dies deep into setup.
- **rclone `-L` symlink loss** — the HF cache lays a snapshot dir out as symlinks into `blobs/`; an
  `rclone copy` *without* `-L` stores the dangling links, not the bytes, so the staged copy is unusable.

The module's artifact-store story (durability / resume / handoff) is shipped; **model caching is the one
gap.** Models are the largest, most-reused, most-network-sensitive input — exactly what belongs staged in
the store once and pulled from there by every pod (same-provider, parallel, verifiable), not re-pulled
from HF per run.

## Approach

Two pieces, mirroring the module's existing box-side-script / pod-side-helper split:

**1. `scripts/stage_model.sh <hf-repo>[@rev] <remote-path>` (box-side, run once).** Downloads the model
from HF (`huggingface-cli download`, ambient `HF_TOKEN` for gated repos) into a temp dir that materializes
real file bytes, then `rclone copy -L` it to `<remote-path>` (the `-L` is the symlink-loss fix). After the
data lands, write a completeness manifest **last** — `_STAGED.json` recording `{repo, rev, object_count,
total_bytes, staged_at}` — so its presence means the upload finished, and it carries the numbers the pull
side verifies against.

**2. `pull_model <remote-model-path> <local-dir>` (pod-side helper in `job_lib.sh`).** Waits for
`_STAGED.json` to list (the `wait_r2` idiom), reads the expected `object_count` + `total_bytes`, `rclone
copy`s the model down, then **verifies the local object count and byte total match the manifest** — dying
on mismatch rather than feeding the loader a short read. This is what closes the missing-shard race: a pod
that starts before staging finished, or that gets a partial pull, fails a loud gate instead of a confusing
mid-load crash.

Load-bearing decisions:
- **Verify bytes + count, not a bare sentinel.** `job_lib.sh`'s own R2-gate comments already encode the
  lesson: *"done-gates must check the real deliverable's bytes, never a 0-byte sentinel; size-threshold
  ready-gates race the producer."* The manifest records real numbers and the pull side checks them; the
  sentinel's *presence* is necessary (upload-finished) but not sufficient (count/bytes must match).
- **Sentinel written last.** Standard producer-race idiom — the manifest is the upload's final object, so
  a pod that sees it knows every shard preceded it.
- **`pull_model` lives in `job_lib.sh`.** It's a pod-side helper next to `wait_r2` / `r2_done` / `r2_exists`
  and follows their incident-cited-header convention; `stage_model.sh` is a standalone box-side script next
  to `deploy_pod.py` / `teardown.sh`.
- **Host-agnostic staging.** `stage_model.sh` needs only `huggingface-cli` + `rclone` + the store; it runs
  from the orchestrator box (the one-time-copy intent) or any host with HF access.

## Alternatives considered

- **rclone straight from the HF cache dir.** Rejected as the primary path: the cache's symlink layout is
  exactly the `-L` footgun, and `huggingface-cli download --local-dir` gives a clean materialized tree to
  copy from. (`-L` is still set on the copy as a belt-and-suspenders against any residual links.)
- **Pod downloads from HF directly (status quo) but cached on a persistent volume.** Rejected: re-introduces
  the region-locked-volume coupling the program is migrating *off* of; the artifact store is the portable,
  region-free home.
- **Bare done-sentinel (0-byte marker), no manifest.** Rejected: races the producer and can't catch a
  partial pull — the module already learned this (cited above).

## Blast radius

`gpu-job` plugin only: one new box-side script (`scripts/stage_model.sh`), one new pod-side helper
(`pull_model` in `scripts/job_lib.sh`), a short SKILL.md subsection documenting the stage→pull flow, and a
`plugin.json` version bump. **Purely additive** — no existing script, helper, or flow changes, so nothing
that doesn't call the new helper is affected. Product (shipped research plugin) layer.

## Rollout + rollback

Lands on main via this PR. Opt-in: a job uses it by calling `stage_model.sh` once and `pull_model` in its
job script; existing jobs are untouched. **Validation note:** the staging + pull logic is authored and
cross-family code-reviewed here, but **end-to-end pod validation (real HF download → store → pod pull) is
pending its first real use** — flagged on the issue so the first consumer confirms it before relying on it.
Rollback = revert the additive commit; no migration, no consumer depends on it until they opt in.
