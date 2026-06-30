# 250 — gpu-job: configurable owner prefix on pod names

## Problem

Pods are rented on a **shared** RunPod account. Other people on the account looking at the dashboard can't tell which pods are whose. We want pod names prefixed with a configurable owner tag (e.g. `anton-`) so ownership is obvious at a glance.

The catch: when leasing is on, the pod **name IS the lease nonce** (`gpujob-<hex>`), and the teardown reaper maps a live pod back to its lease by that name. A naive prefix would break that mapping and **orphan billing pods** — the failure mode this design must prevent.

## Approach

- **`deploy_pod.py`** — prepend `POD_NAME_PREFIX` (env, **empty default**) to the pod name, for both the lease-nonce name and the `POD_NAME` fallback. The lease itself still stores the bare nonce.
- **`pod_lease.sh` `find-nonce`** — today it requires the pod name to *be* the nonce (`case $name in gpujob-*`, then an exact whole-string match). Change it to **recover the `gpujob-<hex>` nonce structurally** from the (possibly-prefixed) name: `gpujob-${name##*gpujob-}` (the substring from the last `gpujob-` onward). A name with no `gpujob-` token is still "unknown" → report-only.

The key safety property: the reaper (`pod_reaper.sh`) is a **separate, detached process with its own env**. By recovering the nonce from the *name's structure* instead of stripping a *configured* prefix, reaping stays correct **even if the prefix env never reaches the reaper** — a missing/misconfigured prefix can't silently orphan a pod. The reaper itself is unchanged; it calls `find-nonce`, which now handles prefixed names.

## Alternatives considered

- **Strip a configured `POD_NAME_PREFIX` inside `find-nonce`** — rejected: correctness would depend on the prefix env reaching the detached reaper. A missing config would silently orphan billing pods — the exact failure we must avoid.
- **Match "name ends with the nonce"** — rejected: looser than recovering the canonical `gpujob-<hex>` token; the structural extraction is exact.
- **Only prefix non-leased (`POD_NAME`) pods** — rejected: Anton wants *all* his pods identifiable, including leased ones.

## Blast radius

gpu-job plugin only: `deploy_pod.py` (naming) + `pod_lease.sh` (`find-nonce`). `pod_reaper.sh` is unchanged. **Empty default = zero behavior change** for any instance that doesn't set the prefix; existing unprefixed pods still resolve (`find-nonce` recovers `gpujob-<hex>` from a bare nonce unchanged). Reversible (revert the PR).

## Rollout + rollback

ship-change PR. This instance sets `POD_NAME_PREFIX=anton-` where `deploy_pod` reads its env. **Test before merge:** `find-nonce anton-gpujob-deadbeef` resolves to a pending-intent lease with nonce `gpujob-deadbeef`, and the bare `gpujob-deadbeef` case still resolves. Rollback: revert; pods go back to bare nonce names.
