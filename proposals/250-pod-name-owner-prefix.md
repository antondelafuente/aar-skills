# 250 — gpu-job: configurable owner prefix on pod names

## Problem

Pods are rented on a **shared** RunPod account. Other people on the account looking at the dashboard can't tell which pods are whose. We want pod names prefixed with a configurable owner tag (e.g. `anton-`) so ownership is obvious at a glance.

The catch: when leasing is on, the pod **name IS the lease nonce** (`gpujob-<hex>`), and the teardown reaper maps a live pod back to its lease by that name. A naive prefix would break that mapping and **orphan billing pods** — the failure mode this design must prevent.

## Approach

- **`deploy_pod.py`** — prepend `POD_NAME_PREFIX` (env, **empty default**) to the pod name, for both the lease-nonce name and the `POD_NAME` fallback.
- **`pod_lease.sh`** — `cmd_intent` records the **exact expected RunPod name** (`prefix + nonce`) in the lease as `expected_name`. `deploy_pod` **resolves the prefix once** (from `~/.config/gpu-job/env` + env, the same value it uses for the pod name) and **passes it explicitly** to the intent via `--name-prefix`, so the recorded expected name always matches the actual pod name — never dependent on the prefix being in the subprocess's inherited environment. `find-nonce` then **exact-matches** the live pod name against the stored `expected_name`; legacy leases without it fall back to the bare nonce.

The key safety property: the match stays **exact whole-string** (the recorded `expected_name`), preserving the reaper's invariant that deletion authority is never granted by a partial/substring match (#169). The reaper reads the expected name *from the lease*, so it needs **no prefix config at reap time** — a missing/misconfigured prefix env in the detached reaper cannot cause a wrong-pod match (worst case: no match → report-only, never a wrong deletion).

## Alternatives considered

- **Recover the nonce structurally from the name** (`gpujob-${name##*gpujob-}`) — rejected: it turns an exact match into a *substring* match, so a peer/unknown pod whose name embeds a pending nonce could move from report-only to bind-and-reap — a deletion-authority loosening the reaper explicitly forbids (#169).
- **Strip a configured `POD_NAME_PREFIX` inside `find-nonce`** — rejected: correctness would depend on the prefix env reaching the detached reaper; a missing config would orphan billing pods.
- **Only prefix non-leased (`POD_NAME`) pods** — rejected: Anton wants *all* his pods identifiable, including leased ones.

## Blast radius

gpu-job plugin: `deploy_pod.py` (naming), `pod_lease.sh` (`cmd_intent` records `expected_name`; `find-nonce` exact-matches it). Note `find-nonce` **is** the reaper's pod→lease deletion mapping, so this is a reaper *behavior* change — covered by `pod_lease_smoke.sh` (extended with a prefixed-pod find-nonce case). **Empty default = zero behavior change** for unprefixed instances; legacy leases resolve via the bare-nonce fallback. Reversible (revert the PR).

## Rollout + rollback

ship-change PR. This instance sets `POD_NAME_PREFIX=anton-` in `~/.config/gpu-job/env`. **Tested before merge:** an intent created with `POD_NAME_PREFIX=anton-` stores `expected_name=anton-gpujob-<nonce>`; `find-nonce anton-gpujob-<nonce>` resolves it, while the bare nonce and a substring (`evil-anton-…`) do NOT (exact-match safety), and a legacy lease still resolves via the nonce fallback. Rollback: revert; pods go back to bare nonce names.
