# Proposal: Hardened multi-adapter vLLM-serve helper (#296)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Every eval driver that scores several LoRA adapters on one pod hand-rolls the same loop: serve
adapter A, eval it, serve adapter B, eval it, and so on. That hand-rolled loop keeps failing the
*same* way, and the failure is silent — the run finishes clean and produces a confidently-wrong
table where N conditions collapse to N *identical* numbers. It just cost the
`toy-reason-beyond-rerun` experiment ~2.5h.

Two compounding bugs produce it (`experiment_gotchas.md` lines 74 and 87):

1. **A surviving server gets reused.** The loop serves vLLM only `if ! curl /v1/models`, so a
   server left alive from the *previous* adapter keeps answering — every later adapter is scored
   against the FIRST adapter's weights. Killing only the `VLLM::EngineCore` child leaves the
   `vllm.entrypoints.openai.api_server` parent alive; an in-process pooled server
   (`run_pooled_gpqa…`) isn't matched by the api_server pattern at all; and an OOM'd process hangs
   holding its GPU instead of exiting.
2. **A stale per-adapter cache gets reused.** Rollouts are cached in a shared output dir with a
   `skip-if *.eval exists` guard, so adapters 2..N find adapter 1's `.eval` files and skip
   generation entirely.

The tell each time: identical metrics across conditions, and cells finishing far faster than a real
serve+rollout would take. The fix is known and has been re-derived by hand several times; it should
live in ONE shared helper so drivers call it instead of re-implementing (and re-breaking) the
pattern. This drains a cluster of gotcha entries (lines 13, 46, 74, 87).

## Approach

Add the multi-adapter serve loop as a **shared pod-side helper in `job_lib.sh`** (the gpu-job
plugin's job-helper library, `plugins/gpu-job/skills/gpu-job/scripts/job_lib.sh`). That file is
already the home of the primitives this composes — `gpu_gate`, `serve_wait`, `port_free_wait`,
`kill_tree` — and drivers already `source /root/job_lib.sh`, so adoption is a one-line call with no
new file to ship. It is product tooling shared across every eval driver, exactly the gpu-job
plugin's remit.

The new public function, **`serve_adapters_eval`**, makes the pattern structurally safe by owning
the dangerous envelope and delegating only the two things that legitimately vary (how you serve, how
you eval) to caller callbacks:

```
serve_adapters_eval <out_root> <port> <serve_fn> <eval_fn> -- <adapter1> [adapter2 ...]
  serve_fn <adapter> <port> <serve_log>   # launch vLLM serving THIS adapter, detached; ECHO its PID
  eval_fn  <adapter> <out_dir> <port>     # run the eval, writing results UNDER the isolated <out_dir>
```

**The `serve_fn` PID contract (F2).** `serve_fn` must launch the server detached and **echo the
launched server's PID (a positive integer) to stdout** — that is the machine-checkable contract the
teardown relies on. The helper captures it, **validates it is numeric and fails closed otherwise**
(so a `serve_fn` that forgets to echo a PID dies loud instead of silently skipping the
kill-by-PID). Both the baked-in default serve and a stubbed custom serve are exercised in the smoke.

For each adapter the helper, in order:

1. **Full teardown before serving** — kills the server process by its captured PID (via `kill_tree`,
   never `pkill -f` which self-matches), then `pkill -9` for BOTH
   `vllm.entrypoints.openai.api_server` AND `VLLM::EngineCore` AND every extra pattern in
   `MA_KILL_PATTERNS`. It KILLS rather than waits-for-exit, because an OOM'd server hangs and would
   never exit on its own. `MA_KILL_PATTERNS` **defaults to the two generic vLLM process forms only**;
   a driver that runs an **in-process pooled server** (its process name is the driver's own, e.g. a
   `run_pooled_…` script) sets `MA_KILL_PATTERNS` to add that name — the hook is documented, but the
   default carries **no instance eval-driver name** (F3: those are not product-generic).
2. **Waits until the GPU/port is ACTUALLY free** — blocks until `nvidia-smi memory.used` drops below
   `MA_VRAM_FLOOR_MIB` (default 12000) AND `curl localhost:<port>/v1/models` refuses. Never a
   fixed-timeout "proceed regardless" gate; if VRAM never frees within a generous bound it dies loud.
3. **Gives the adapter its OWN fresh output dir** — `<out_root>/NN-<sanitized-adapter>`, `rm -rf`'d
   then recreated, so there is no cross-adapter `.eval` cache and no skip-if-exists reuse possible.
4. **Serves, waits for readiness** (`serve_wait`), then runs `eval_fn` against the isolated dir.
5. **Tears down again** (step 1) before the next adapter.

After the loop it runs a **distinctness assertion** — the structural catch for the exact "identical
numbers" signature, so even a novel reuse path can't pass silently. To avoid the wrong-unit problems
(F4) — harmless metadata masking a real reuse, or a legitimately-deterministic eval false-failing —
the check is **scoped and mode-configurable**, not a blanket whole-tree hash:

- `MA_DISTINCT_GLOB` (default `*`, always excluding `serve.log`) points the check at the **canonical
  eval artifact** (e.g. `rollouts.jsonl` / `results.json`), so a driver can compare exactly the
  rollout/metric file that matters rather than incidental sidecar metadata.
- `MA_DISTINCT_MODE` = `error` (default, die loud) | `warn` (print a loud WARNING, continue — the
  explicit opt-out for an eval whose outputs are legitimately identical across adapters) | `off`.

(Pairs with the separately-ticketed eval-warning that watches for the identical-numbers signature
downstream; this helper prevents it at the source.)

A thin baked-in default serve, **`vllm_serve_lora <base> <adapter> <port> <serve_log> [extra vllm
args…]`**, is also added so the common case (serve one LoRA against a base on the OpenAI api_server)
needs no custom `serve_fn` — it launches the api_server detached and echoes its PID per the contract,
so a driver wraps it in a one-line `serve_fn`. The eval side stays a callback because eval harnesses
vary too much to bake one in.

**Discoverability (F1).** A concise section is added to the gpu-job **`SKILL.md`** — the
`serve_adapters_eval` contract, the default-serve example, and a reference `serve_fn`/`eval_fn`
callback pair — so a zero-context agent finds the safe helper at the point of need instead of
re-deriving (and re-breaking) the loop.

**Testability / reference call-site.** A new `multi_adapter_smoke.sh` is the reference call-site and
self-test. It sources `job_lib.sh`, shadows the GPU-touching primitives (`gpu_gate`-internals,
`serve_wait`, `nvidia-smi`/`curl` via stub `serve_fn`) with fakes, and asserts the ORCHESTRATION
contract the deterministic checks can't: (a) each adapter gets a distinct fresh dir, (b) teardown
runs between adapters (ordering), (c) no skip-reuse when a stale `.eval` is pre-planted, (d) the
distinctness assertion FAILS loud when two stub evals emit identical output and PASSES when they
differ. `.aar-ci/checks.sh` gains a gate that runs this smoke when `job_lib.sh` or the smoke changes
(same precedent as `pod_lease_smoke.sh` / `pod_reaper_smoke.sh`).

**Scope (conservative).** This PR ships the helper + its default serve + the smoke + the checks gate,
and bumps the gpu-job plugin version. It does NOT rewire existing eval drivers — adoption follows in
separate PRs so each driver's serve/eval wiring is reviewed on its own.

## Alternatives considered

- **A standalone Python module / new script file.** Rejected: drivers already source `job_lib.sh`
  and the primitives this composes live there; a new file adds a second thing to scp and diverges the
  helper family. Bash keeps it in the same sourced library at zero extra adoption cost.
- **Bake in the eval too (fully turnkey `serve_adapters_and_score`).** Rejected: eval harnesses vary
  (inspect vs pooled-gpqa vs custom rollout+judge) far more than the serve does; baking one in would
  fit no driver cleanly. The callback owns eval; the helper owns the unsafe envelope.
- **Extend `gpu_gate` in place instead of a new function.** `gpu_gate` waits-for-exit on runner
  patterns (correct for clean chaining) but that hangs on an OOM'd in-process server, and it does not
  own the per-adapter isolation or the distinctness check. `serve_adapters_eval` composes `gpu_gate`'s
  intent but adds kill-not-wait teardown of the server it owns, isolation, and the distinctness gate —
  a higher-altitude helper, not a change to the primitive.
- **Rely only on the downstream eval-warning ticket.** Rejected as the sole fix: a warning catches
  the signature *after* burning the compute; this helper prevents the reuse structurally. They pair.

## Blast radius

- **Product scaffold, gpu-job plugin only.** New helpers in `job_lib.sh`, a new `SKILL.md` usage
  section, one new smoke script, one new gate in `.aar-ci/checks.sh`, gpu-job `plugin.json` version
  bump (0.2.4 → 0.2.5).
- **Additive.** No existing helper's signature changes; no driver is rewired in this PR, so nothing
  that currently sources `job_lib.sh` changes behavior until it opts in by calling the new function.
- **CI:** the new checks gate runs the offline smoke; it touches no network/GPU/creds by construction.

## Rollout + rollback

- **Rollout:** merge helper + smoke; adopt in eval drivers incrementally in follow-up PRs (each swaps
  its hand-rolled loop for a `serve_adapters_eval` call). File a follow-up to track adoption.
- **Rollback:** additive and unused-until-called — revert the squash commit (one-command revert per
  RUNBOOK) with no consumer impact, since no driver depends on it yet.
