# Proposal: experiment-lifecycle — accept inline audit responses, bridge the instance profile, and add three lifecycle gates/rules (#263, #258, #238, #233, #232)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

This is a grouped fix over `plugins/experiment-lifecycle` (the `log-experiment` + `run-experiment` +
`design-experiment` skills). Five clearly-implementable issues; the two `needs-design` siblings in the same
area (#106 base-model pinning, #105 existing-run reuse) are **deferred** — they need a genuine design call on
how a run is identified/pinned, out of scope for this mechanical batch.

## Problem

Five independent footguns, all surfaced from real experiment closes:

- **#263 — `log-experiment` rejects an inline close-audit response.** `log-experiment.sh`'s experiment gate
  blocks with `experiment has AUDIT.md but no AUDIT_RESPONSE.md` even when the close-audit findings were
  triaged in a `## Executor responses` section appended *inside* `AUDIT.md`. Neither the run-experiment close
  steps nor the CHECKLIST template ever name `AUDIT_RESPONSE.md`, so the executor naturally writes the response
  inline and then gets blocked. Cost: one wasted cycle splitting the file and re-running.
- **#258 — `log-experiment` fails closed on a correctly-configured instance.** `#245` made
  `~/.config/experiment-lifecycle/aar-profile.toml` `[github]` the config home (it declares `research_repo`,
  `base_branch`, and the identity env-var names), but nothing bridges those values into the variables
  `log-experiment.sh` reads. The script reads `RESEARCH_REPO` from the **env only** (`:24` / `:130`, no
  default), so a manual/scripted `log-experiment.sh <dir>` dies with *"RESEARCH_REPO is required"* even though
  the profile names the repo. A model executor can work around it by exporting `RESEARCH_REPO` itself, but that
  is implicit and fragile.
- **#238 — no CLAIMED_BY gate before GPU spend.** `AGENTS.md` requires claiming an experiment (write
  `CLAIMED_BY`, commit it path-scoped) as the first action, but the run-experiment CHECKLIST/gates never forced
  it before compute spend. A zero-context executor works the listed gates and misses the separate global
  convention; a `medical-japanese-trigger` close audit caught the dir un-claimed and untracked *after* the run.
- **#233 — rollout artifacts omit the decoding config.** Semantic rollout audits have to verify shared decoding
  settings (temperature/top_p/max_new_tokens/seed/sampling mode) from driver source because rollout rows and
  summaries don't persist them. During `japanese-fitness-trigger` cross-arm decoding comparability was real but
  only source-verifiable — the artifact set should be self-contained.
- **#232 — the close-audit record rule is ambiguous for R2-backed artifacts.** The close protocol says "commit
  the record and verify every unique artifact in R2," but gives no crisp self-sufficiency standard for
  R2-backed runs. During `japanese-fitness-trigger` close a cross-family auditor raised a MED reproducibility
  finding because heavy rollouts/adapters/logs were untracked in git — even though the profile + `.gitignore`
  deliberately keep them in R2. The executor had to improvise an `ARTIFACT_MANIFEST.md`.

## Approach

All five fixes are mechanical (one script edit + skill/template doc edits). No behavior of the GPU/compute path
changes.

**#263 — accept the inline response form (`log-experiment.sh` `gate_experiment`).** The gate's intent is to
verify the close-audit *ran and was triaged*, not to mandate a particular filename. Change the requirement from
"`AUDIT_RESPONSE.md` must exist" to: **pass if `AUDIT_RESPONSE.md` exists OR `AUDIT.md` contains a recognized
triage/response section** (a markdown heading matching `response`/`responses`/`triage`, case-insensitive). The
`post_audit_thread` step already degrades gracefully when `AUDIT_RESPONSE.md` is absent (`_clip` returns
non-zero and the loop skips it), so the inline responses simply travel to the PR inside the `AUDIT.md` findings
body. The run-experiment close step and the CHECKLIST gate are updated to state both forms are accepted (the
CHECKLIST already points its evidence at `AUDIT.md`).

**#258 — a small profile bridge in `log-experiment.sh`.** Add a self-contained reader (uses stdlib
`python3`/`tomllib`, matching the SCHEMA's parser policy) that resolves the live profile by the SCHEMA
discovery order (`$AAR_PROFILE`, then `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}`,
`.toml` wins) and emits `research_repo`, `base_branch`, and the per-family identity env-var *names* it points
at. These fill the corresponding script variables **only when the env is unset — env stays the override**, so
nothing that works today changes. Specifically: `RESEARCH_REPO` gains a profile fallback; `base_branch` is
wired to a `BASE_BRANCH` (default `main`, so the instance is byte-identical) for the PR base + worktree fork +
local sync; and the reviewer/author token-command and git-author lookups fall back to the profile's
`token_cmd_env`/`git_author_env` indirection when the `LOG_EXPERIMENT_*` env vars are unset. Tolerant reader:
if the profile is absent, unparseable, or missing `python3`, the bridge no-ops and the prior env-only
fail-closed behavior is preserved; a profile carrying a `schema_version` other than `1` is left untouched
(don't interpret an unknown layout). This makes `aar-profile.toml` the single config home #245 intended.

**#238 — a universal CLAIMED_BY gate before spend.** Add a `[BLOCK]` row near the top of the CHECKLIST
template's UNIVERSAL block ("Experiment CLAIMED before any GPU/API spend: `CLAIMED_BY` exists (who/date/scope),
committed path-scoped; checked no peer already owns the dir") and a matching one-line reminder in
run-experiment's Step 1 (Acquire) so the claim is forced *before* the first billable action, not caught at
close.

**#233 — persist + check decoding config.** Add a Step 4 (Collect) requirement in run-experiment that rollout
artifacts stamp the exact decoding config (temperature/top_p/max_new_tokens/seed/sampling mode) into each
rollout row or a companion summary, and a CONDITIONAL CHECKLIST gate that the executor verify presence +
cross-arm consistency of that config. (The deterministic `audit_data.py` automation lives in the `verify-claims`
plugin — out of scope for this batch; the checklist gate carries the check in the meantime.)

**#232 — document the R2-backed close pattern.** Add a canonical close pattern to run-experiment Step 5: commit
the lightweight record (RESULTS, audits + responses, CHECKLIST, small samples) **plus an `ARTIFACT_MANIFEST.md`**
recording the R2 path, object count, and key sizes; keep full JSONL/logs/adapters in R2 unless the brief
explicitly requests git-pinned samples. State that a verified R2 upload + the manifest **satisfies record
self-sufficiency** for heavy artifacts, so a close auditor does not read `.gitignore`'d heavy artifacts as a
reproducibility gap.

## Alternatives considered

- **#263 option (b): document the separate `AUDIT_RESPONSE.md` requirement instead of accepting inline.**
  Rejected — it makes every executor do more work to satisfy a filename the gate never needed; accepting the
  inline form removes the footgun at the source while still verifying triage happened.
- **#258: keep env-only and just teach the executor to export `RESEARCH_REPO`.** Rejected — that is the
  fragile status quo the issue is about (a non-model caller still fails closed on a configured instance).
- **#258: resolve the profile in a shared external helper instead of inline in `log-experiment.sh`.** The
  SCHEMA assigns live profile resolution to `design-experiment` (snapshot into `START.md`) and forbids the
  `run-experiment` executor from re-reading it. `log-experiment.sh` is the manual/scripted logging entrypoint,
  is explicitly self-contained ("does NOT source wf.sh"), and needs the fallback at its own boundary; an inline,
  tolerant, override-preserving reader is the smallest change that fixes the reported failure without adding a
  new shared dependency.
- **#233: modify `audit_data.py` to require the decoding config.** That script is in the `verify-claims`
  plugin — a different install unit, out of scope here. The persist requirement + checklist gate is the
  in-scope fix; the automated check is a clean follow-up against that plugin.

## Blast radius

- **Product scaffold only**, all under `plugins/experiment-lifecycle`:
  - `skills/log-experiment/scripts/log-experiment.sh` — the profile bridge (#258) + the inline-response gate
    (#263). This is the only executable change.
  - `skills/log-experiment/SKILL.md` — doc the profile fallback + inline-response acceptance.
  - `skills/run-experiment/SKILL.md` — the CLAIMED_BY reminder (#238), decoding-config persist (#233), R2 close
    pattern (#232), inline-response note (#263).
  - `skills/design-experiment/templates/CHECKLIST_TEMPLATE.md` — CLAIMED_BY gate (#238) + decoding-config gate
    (#233).
- **No change** to the compute/GPU path, to `verify-claims`, or to the two byte-identical `SCHEMA.md` copies
  (`.aar-ci/checks.sh` asserts those stay identical — untouched).
- **Instance behavior is unchanged by default**: the profile bridge only fills *unset* vars, `BASE_BRANCH`
  defaults to `main`, and the current instance already exports the `LOG_EXPERIMENT_*` identity vars — so the
  live instance's `log-experiment` path is byte-identical except that a manual call no longer needs an explicit
  `RESEARCH_REPO` export.

## Rollout + rollback

Low risk, no staged rollout needed. Each fix is independently revertable (separate hunks; the script change is
additive + fallback-only). Rollback = revert the PR; the env-override path means no instance is left worse off
than today even mid-rollout. Deferred #105/#106 stay open for a dedicated design pass.
