# Proposal: gpu-job — real region coverage (`DATA_CENTERS=all` = all creatable DCs) (#31)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`deploy_pod.py` searches only a hardcoded `TIERS` list (US-west → central → east → EU, ~17 DC ids)
and **`DATA_CENTERS=all` is a false-all** — it just flattens that same hardcoded list rather than
meaning "every region." Two defects:

1. **The hardcoded list rots.** RunPod's live datacenter set drifts. As of 2026-06-17 the live
   GraphQL `dataCenters` returns **47** DCs, of which **30 are `listed: true`** (the pod-creatable
   set). The hardcoded `TIERS` both *omits* creatable regions (AP-IN-1, AP-JP-1, OC-AU-1, CA-MTL-*,
   EU-SE-1, EUR-NO-*, US-MD-1, US-MO-*, US-NC-2, US-NE-1, …) **and** still *contains stale, now-unlisted
   ids** (US-TX-1, US-KS-3, US-GA-1, US-DE-1). A hand-maintained list is structurally doomed to drift.
2. **`all` doesn't mean all.** `DATA_CENTERS=all` flattens the ~17-id hardcoded list, so it hunts
   ~1/2–2/3 of pod-creatable capacity and concludes "no stock" while blind to Asia-Pacific, Oceania,
   Canada, the Nordics, and several US regions.

**Cost (real incident, from the issue):** an 8-GPU 32B fine-tune reported "no stock" for **hours**
while never looking at the regions that had it. Scarce multi-GPU stock (8×H200 / 8×B200) is exactly
where coverage matters most, and exactly where the blind spot bites hardest.

## Approach

**Derive the creatable-DC set live, with a static fallback** — stop hand-maintaining a list that rots.

- **`creatable_dcs()`** queries GraphQL `dataCenters { id listed }` (the `gql()` helper already exists,
  used by `wait_ssh`) and returns every `listed: true` id. This is RunPod's own "available for
  selection" flag — the right source of truth, and self-maintaining as RunPod adds/retires regions.
  - We deliberately do **not** use the full 47-id set: the ~17 unlisted ids are serverless/community-only
    and the create-pod REST API rejects them with a schema error. `listed: true` is the creatable subset.
  - **Fallback:** if the GraphQL call fails (network, schema change, auth), fall back to a curated static
    list (the `listed: true` set as of 2026-06-17, 30 ids) so deploy never hard-depends on the extra call.
    The static list is the backstop, not the primary path.
- **`DATA_CENTERS=all` → one batch of every creatable DC** (true-all). This matches `all`'s existing
  single-batch semantics — RunPod's `dataCenterPriority: availability` then picks the best-available
  region across the whole set in one call, which is exactly what a scarce-multi-GPU hunt wants.
- **Default tiered retry → geographic buckets derived from the live set**, by id-prefix rules, preserving
  today's preference order (US-west → US-central → US-east → EU) and adding a final **rest-of-world** tier
  (CA / AP / OC / SEA) so the default path also benefits and a *brand-new* prefix never silently drops —
  any id matching no rule lands in a catch-all final tier (rot-proof by construction).
- **Explicit `DATA_CENTERS=<csv>` is unchanged** — the operator's explicit list is honored verbatim
  (still the required path for region-locked `VOLUME_ID`).

Net behavior change: `all` and the default now cover the full creatable set instead of ~half; explicit
csv and volume-locked deploys are byte-for-byte unchanged.

## Alternatives considered

- **Just hardcode the bigger (28–30 id) list.** Rejected — it's the same structurally-rotting design
  that produced this bug; it would be stale again the next time RunPod changes regions. Live-derive +
  static-fallback gets the coverage *and* removes the rot for good.
- **Use the full live 47-id set directly.** Rejected — the unlisted ids are not pod-creatable and a single
  invalid id in a batched `dataCenterIds` request is schema-rejected, poisoning the whole attempt.
  `listed: true` is the validated creatable subset.
- **Per-DC requests instead of batches.** Rejected — more calls, slower, and loses RunPod's cross-region
  availability priority within a tier. Batched-by-tier keeps the blast radius of any one bad id to its tier
  while preserving availability selection.

## Blast radius

- **Product scaffold:** `plugins/gpu-job/skills/gpu-job/scripts/deploy_pod.py` only. One file.
- Touches the **deploy/acquire path** every experiment uses. The change is additive coverage + a true-all;
  the default still tries US-west first (unchanged preference), so existing single-pod deploys behave the
  same except they now also reach rest-of-world if US+EU are dry.
- One extra ~1s GraphQL call per deploy (cached for the run), with a static fallback if it fails — no new
  hard dependency. No change to teardown/list/SSH paths.
- Version bump on the `gpu-job` plugin manifest (per `.aar-ci` version-bump check).

## Rollout + rollback

- **Rollout:** ships through the normal lifecycle; `.aar-ci` checks (syntax/compile/version-bump) +
  fake-HOME smoke run in `finish`. First real use is any subsequent pod deploy — observable in the
  `[deploy] attempt … tier …` log lines (now showing the fuller tier set).
- **Rollback:** single squash commit — `git revert <sha>` and re-ship, or set `DATA_CENTERS=<csv>` to pin
  explicit regions in the meantime. The live query is wrapped in try/except → static fallback, so even a
  RunPod schema change degrades to today's curated-list behavior rather than breaking deploy.
