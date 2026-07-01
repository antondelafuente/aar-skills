# Proposal: Substrate-derived cross-family auditor selection (#262, #239) + defer #231

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

Grouped change in `plugins/verify-claims`. Fixes **#262** (BASH_ENV re-injects a same-family
`AUDIT_VERIFIER_CMD`, defeating cross-family audits) and **#239** (custom `claude -p` verifier needs
`> "$OUT_TMP"` redirection). **#231** (re-add a disposition-injection smoke) is DEFERRED — its target
no longer lives in this repo (see Blast radius / Deferred).

## Problem

`audit_experiment.sh` is the product's cross-family experiment-audit engine. The auditor MUST be a
different model family than the one that ran the experiment. Two footguns break that today:

**#262 (bug, HIGH):** The instance sets `BASH_ENV=/home/anton/.bash_env_aar`, which (via `~/.env`)
re-exports `AUDIT_VERIFIER_CMD='claude -p …'` into *every* non-interactive shell. Bash sources `BASH_ENV`
at startup *after* applying an inline var prefix, so on a Claude AAR (runner=claude) both
`export AUDIT_VERIFIER_CMD='codex …'` and `AUDIT_VERIFIER_CMD='codex …' bash audit_experiment.sh` get
clobbered back to `claude` before the script reads them. The script then infers auditor family=claude ==
runner family=claude and dead-ends on `BLOCKED: cross-family audit required` — a block the caller cannot
clear from a Claude session without knowing the `env -u BASH_ENV` incantation. The gate is "on" but the
cross-family override is un-settable: it fails closed on the legitimate case and there is no clean path to
the correct codex auditor. (~15 min diagnosis during the reasons-filler-control close.)

**#239 (bug):** On a Codex AAR the auditor must be Claude, so the docs tell you to set
`AUDIT_VERIFIER_CMD='claude -p …'`. But `claude -p` writes its answer to **stdout**, which the harness
redirects to `$OUT.run.log`; the harness expects the answer in the internal `$OUT_TMP`. So the documented
form completes but the harness fails closed with `auditor produced no findings file`. The working form is
`AUDIT_VERIFIER_CMD='claude -p > "$OUT_TMP"'`, but that `$OUT_TMP` contract is undocumented and easy to miss.

Both reduce to the same root cause: the auditor command is supplied *by hand / by env* and the script only
**validates** it (fail-closed), instead of the script **owning** a correct cross-family default keyed off
the one thing it can trust — the substrate that ran the experiment.

## Approach

**Make cross-family guaranteed by construction from `AAR_SUBSTRATE`, and own a correct built-in default for
both families.** (This is fix option (a) from #262, blessed `ready`; it also dissolves #239.)

1. **Runner family is the source of truth.** `RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}`. The required auditor
   is *always the opposite* family (`claude→codex`, `codex→claude`); an unknown substrate `die`s (fail-closed,
   unchanged for that genuinely-broken case).

2. **`AUDIT_VERIFIER_CMD` becomes an override that is honored only when it's a *different* family than the
   runner.** If a caller-supplied `AUDIT_VERIFIER_CMD` is the *same* family as the runner — whether a
   misconfig or a `BASH_ENV` re-injection (#262) — it is **ignored with a loud `WARN`** and the script falls
   back to the opposite-family built-in default. A `custom` (neither-`claude`-nor-`codex`) command is still
   trusted as a deliberate third-family escape hatch (it can never equal `claude`/`codex`). This *strengthens*
   the safety property: a same-family audit can no longer run **and** the legitimate case no longer dead-ends —
   the script self-corrects to the correct cross-family auditor instead of only blocking.

3. **Built-in defaults for BOTH families, each writing its final answer to `$OUT_TMP`** (this is the #239 fix):
   - codex default (unchanged): `codex exec --sandbox read-only --skip-git-repo-check --cd "$EXP" -o "$OUT_TMP"`
   - claude default (new): `claude -p > "$OUT_TMP"` — the redirection that #239 needed, now baked in so a
     Codex AAR needs **no** manual `AUDIT_VERIFIER_CMD` at all.

4. **Docs:** the script header + SKILL.md state that the auditor is derived from `AAR_SUBSTRATE` (opposite
   family), that both built-in defaults are correct out of the box, and that a *custom* `AUDIT_VERIFIER_CMD`
   must (a) be a different family than the runner and (b) write its final answer to `$OUT_TMP`.

5. **Regression smoke (`cross_family_verifier_smoke.sh`) + a print seam.** A new `AUDIT_PRINT_VERIFIER=1`
   seam prints `AUDITOR_FAMILY=` / `VERIFIER_CMD=` and exits before invoking any model (mirrors the existing
   `AUDIT_DRY_RUN` prompt-dump seam). The smoke asserts, with no network: (a) runner=claude + a contaminating
   `AUDIT_VERIFIER_CMD=claude …` selects **codex** (does NOT block); (b) runner=codex selects the **claude**
   default and it contains the `> "$OUT_TMP"` redirection (#239); (c) a valid opposite-family override is
   honored; (d) an unknown substrate fails closed. `.aar-ci/checks.sh` runs it when `audit_experiment.sh`
   (or the smoke) changes.

## Alternatives considered

- **Docs-only (#262 option (b): document `env -u BASH_ENV`).** Rejected: leaves the fail-closed dead-end in
  place; every Claude-run close audit still needs an incantation and the footgun recurs for the next AAR.
- **Unset `BASH_ENV` inside the script.** Rejected: `AUDIT_VERIFIER_CMD` is *already* in the environment by
  the time the script runs (bash sourced `BASH_ENV` at startup), so unsetting it can't recover the caller's
  intended value; and the auditor subprocess legitimately relies on `BASH_ENV` to load `~/.env` secrets.
- **Keep fail-closed-only but teach the block message the `env -u BASH_ENV` fix.** Rejected: still blocks the
  legitimate case; substrate-derived selection is strictly safer (same-family can never run) *and* usable.

## Blast radius

- **Product only**, `plugins/verify-claims/skills/verify-claims/`: `scripts/audit_experiment.sh` (selection
  logic + header), `SKILL.md` (docs), a new `scripts/cross_family_verifier_smoke.sh`, and a hook in
  `.aar-ci/checks.sh`. No change to `verify_claim.sh` or `audit_data.py`.
- **Behavior change:** a same-family `AUDIT_VERIFIER_CMD` now *warns + self-corrects* instead of *blocking*.
  Cross-family is still guaranteed (auditor = opposite of `AAR_SUBSTRATE`). No caller passes a same-family
  command deliberately, so no legitimate workflow regresses. `AUDIT_DRY_RUN` behavior is unchanged except it
  now also works under a contaminated env (previously it blocked before reaching the dump).
- **Deferred — #231:** the disposition-injection smoke it asks to re-add tests the *disposition-aware
  merge-gate injection* (`DISPOSITION_FILE`) in `audit_experiment.sh`. PR #279 (verify-claims 0.7.10) trimmed
  the SWE-review modes (`--scaffold`/`--code`) **and their disposition-aware block out of THIS repo**; that
  injection now lives only in agentic-engineering's `verify-claims`. #231's follow-on comment (the
  `disposition_gate` legacy-label scan) likewise targets `ship-change/scripts/disposition_gate.sh`, also in
  agentic-engineering. So a disposition smoke in `plugins/verify-claims` here would test code that no longer
  exists in this repo. Re-homing #231's smoke to agentic-engineering is a cross-repo scoping decision outside
  this group and repo — DEFER, don't guess.

## Rollout + rollback

Low risk, additive + self-contained. Revert = revert the PR (restores the fail-closed-only block). The new
smoke is deterministic and offline; it guards the regression going forward.
