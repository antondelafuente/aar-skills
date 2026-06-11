---
name: gpu-job
description: Run GPU work on disposable cloud pods (RunPod backend) with artifact persistence and verified teardown. Use when the user wants to rent/launch a GPU, run a training/eval/compute job remotely ("get me an H100", "run this on a GPU", "launch a pod"), or when local hardware can't run the job. The contract - acquire, run detached, persist artifacts, VERIFY, tear down - exists so a forgotten pod never bills silently.
---

# gpu-job — disposable GPU compute for coding agents

The machine you're on probably has no GPU; the cloud has plenty by the hour. This skill's
whole contract: **acquire → run detached → persist artifacts → verify → tear down.** A pod
is cattle, not a pet — everything worth keeping leaves the pod before the pod dies.

## One-time setup (per user)

`scripts/gpu_job_init.sh` — writes `~/.config/gpu-job/env` (RunPod key, SSH pubkey, defaults,
optional rclone artifact remote). Nothing is uploaded; config stays local, chmod 600.
Optional: stage an identity bundle at `<remote>/gpu-job/bundle.tar` (e.g. agent auth,
.gitconfig) and pods restore it at bootstrap.

## The loop

1. **Acquire:** `python3 scripts/deploy_pod.py` (env knobs: `GPU_TYPE`, `GPU_COUNT`,
   `DISK_GB`, `POD_NAME`, `DATA_CENTERS`, `VOLUME_ID`). Prints `POD_ID` / `SSH` / cost.
   Big-model jobs need big disks — the 220GB default is deliberate.
2. **Bootstrap:** scp + run `scripts/bootstrap_pod.sh` on the pod (configures rclone from
   your injected config; restores the optional bundle).
3. **Run detached:** `scripts/run_remote.sh <port> root@<ip> <job.sh> /root/job.log [ENV=V…]`
   — survives SSH close, verifies the job actually started (a "launched" echo proves the
   wrapper ran, not the job). Write the job script to be idempotent and to print progress.
4. **Arm the watchdog the moment the job is launched:** `scripts/watchdog.sh <pod-id> <ip>
   <port> [grace]` — if you stop paying attention, the pod still gets deleted. NOTE its
   semantics: it is a **TTL / dead-man timer, not idle detection** — it fires after the grace
   period unless `/workspace/.keepalive_until_utc` holds a future UTC timestamp. A long job
   must REFRESH that file periodically (e.g. each epoch), or set grace ≥ expected runtime +
   margin; otherwise a healthy job gets killed on schedule.
5. **Persist + VERIFY:** the job's last act is `rclone copy <outputs> <remote>/<job>/`;
   before teardown, verify EVERY unique artifact is in the store (`rclone lsf` the
   directory and check the final artifact's bytes — never trust a zero-byte done-marker).
6. **Tear down:** `scripts/teardown.sh <pod-id>`. Default the moment artifacts verify.
   Never use provider "stop" expecting keep-warm — container disk wipes on restart.

## Rules that are not optional

- **The completion boundary is the whole ballgame:** before verified persistence, DELETE
  loses data; after it, DELETE is free. Order everything around that line.
- **Teardown is pod-id-scoped.** Never blanket-delete "idle" pods — parallel runs own theirs.
- **Watch liveness with a positive-progress signal** (artifact growing, stage marker
  advancing) — "no done-marker yet" can't distinguish working from wedged.
- Costs are per-hour from deploy to delete. Check the printed `COST_PER_HR`; a forgotten
  H200 is ~$100/day.
