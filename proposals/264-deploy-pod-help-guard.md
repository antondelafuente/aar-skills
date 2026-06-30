# Proposal: guard deploy_pod.py against `--help`/unknown-arg deploys (#264)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`plugins/gpu-job/skills/gpu-job/scripts/deploy_pod.py` deploys a real (billed) GPU pod when run with `--help`. Its `__main__` block special-cases only `--selftest`; any other argv — `--help`, `-h`, or a typo — falls straight through to mint-lease + `deploy()`. Because the script is entirely env-var-driven (it reads `~/.config/gpu-job/env`), a real deploy takes **no** command-line arguments, so argv beyond the program name is never a legitimate deploy request. This is the confirmed root cause of orphaned `anton-gpujob-*` H200s left idling on a shared RunPod account: an operator ran `deploy_pod.py --help` expecting usage text and got a billing pod instead. A `--help` that costs money — and a typo that does the same — is a serious, money-losing footgun.

## Approach

Classify no-deploy argv **at module level** (alongside the existing `_SELFTEST` flag) and enforce it in `__main__`, in the same lightweight style as `_SELFTEST` (no `argparse` rewrite, deploy logic untouched). The classification (`_HELP`, `_BADARGS`, `_NO_DEPLOY`) sits *before* the module-level required-credential reads (`KEY`/`PUBLIC_KEY`), and those reads are relaxed to `required=not _NO_DEPLOY` — so `--help`/unknown-arg work on a fresh, **unconfigured** install instead of dying at import on missing creds (design-review F1). Recognized argv is the closed set `{--selftest, --help, -h}`:

- `-h` / `--help` → print a concise usage string to **stdout** and exit `0`. The usage makes it unmistakable that a *bare* invocation DEPLOYS a disposable RunPod GPU pod, that the run is configured by env vars in `~/.config/gpu-job/env` (no positional args), and lists the only recognized flags.
- any **unrecognized** arg (anything not in the closed set) → print usage to **stderr** and exit `2`, **without deploying**. This closes the typo-deploys hazard, not just `--help`.
- `--selftest` → unchanged (offline self-check, exit 0).
- bare invocation (no args) → unchanged (still deploys — that is the real entrypoint).

The guard runs before the lease-mint/`deploy()` path, so no money-moving call can be reached on a help/typo invocation. Fail-closed by construction: the default for an unrecognized token is "refuse + exit non-zero," never "proceed to deploy."

## Alternatives considered

- **Full `argparse` migration.** Cleaner long-term, but the script takes no real CLI args (it's env-driven), so argparse would add a parser, auto-`--help`, and surface area for a one-line behavior fix. Rejected as over-scoped for this bug; the env-driven contract stays.
- **Only handle `--help`/`-h` (ignore other unknown args).** Fixes the reported symptom but leaves the typo-deploys hazard (`deploy_pod.py --gpu h200` would still deploy). Rejected — fail-closed on *any* unrecognized arg is the same cost and removes the whole class.
- **Do nothing / document it.** A money-losing default is not acceptable as documentation-only.

## Blast radius

`deploy_pod.py` (`__main__` + the module-level arg classification / cred-read relaxation; `deploy()`, lease, and enrich logic untouched) plus the required **`plugins/gpu-job/.claude-plugin/plugin.json` version bump** (0.2.1 → 0.2.2) for the behavior change (design-review F2). SWE-pipeline/product-scaffold change (the gpu-job skill), no instance-config change. The only behavior change is on argv that previously (wrongly) deployed. Verified by behavior smoke under a **blank HOME with no gpu-job config** (clean env, no RunPod creds — a regression would visibly attempt the API):
- `deploy_pod.py --help` → usage to **stdout**, exit 0, no deploy. ✓
- `deploy_pod.py --bogus` → usage to **stderr**, exit 2, no deploy. ✓
- `deploy_pod.py --selftest` → offline selftest, exit 0 (unchanged). ✓
- bare invocation (no args) → reaches the cred read (`missing RUNPOD_API_KEY`), i.e. still proceeds to deploy — the entrypoint is preserved (negative control). ✓

## Rollout + rollback

Single low-risk commit; ships through the normal cross-family gate. Rollback = revert the one commit (restores prior behavior). No staged rollout or escape hatch needed; no data/state migration.
