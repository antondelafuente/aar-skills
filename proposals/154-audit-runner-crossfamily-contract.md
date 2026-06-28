# Proposal: audit-runner cross-family contract — explicit family + fail-closed on all four model-judged rungs (#154)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (two-phase, Step 2 of the #130 cluster); spawns `ready` issues for the code edits.
> Parent umbrella: #130. Sibling design children: #150 (shared helper), #145, #146, #151, #152;
> implementation children blocked on this: #156, #157.

## Problem

The whole point of the research audits is that a model cannot reliably catch its own mistakes, so each
audit is run by a **different model family** than the one that did the work. #130 promises that
cross-family guarantee on **all four** model-judged rungs of the experiment lifecycle: the `verify_claim`
fact check and the `audit_experiment --design` check before a run, the `audit_experiment --data` check
mid-run, and the `audit_experiment` close check at the end. Today that promise is only actually *enforced*
on the two rungs that ship-change uses (`--scaffold` and `--code`), which demand you explicitly name the
author's family. The other rungs silently fall back to a default family with **no check that it differs
from who ran the work** — and `verify_claim` does not look at family at all. So a Codex-run experiment could
have its facts verified by Codex and its design reviewed as if it were Claude-run, and nothing would stop
it. The four-rung cross-family promise is unbacked until this is fixed, and the #130 PR flow cannot honestly
claim a cross-family record on the read-only rungs.

This is the **same class of bug** #134 just fixed for `wf.sh`: a same-family review slipping through because
the runner family was inferred from an ambient default instead of being stated and checked. #134 fixed the
*caller* (`wf.sh`) for the two ship-change rungs; this fixes the *audit runner itself* for the remaining
four, so the guarantee holds no matter who calls it.

## Approach

Make every model-judged rung enforce the cross-family contract the same way `--scaffold`/`--code` already
do: the family that ran the work must be **stated explicitly** (no silent default), and the audit
**refuses to run** unless the verifier is a genuinely different family. We add the existing exact-match
guard to the `audit_experiment` close/`--design`/`--data` modes (today only `--scaffold`/`--code` have it),
and we give `verify_claim` — which has no family logic at all today — the same explicit-family-in,
fail-closed-on-same-family contract, including the family inference from its verifier command. The result
is one uniform rule across all six rungs: **no family stated → BLOCK; verifier family == runner family →
BLOCK.** This is the contract the rest of the #130 cluster consumes; it owns family enforcement for the
read-only rungs so the GitHub helper (#150) never has to.

The contract is enforced **where these audits actually run** — in the `verify-claims` plugin
(`verify_claim.sh` and `audit_experiment.sh`). The #130 GitHub helper (#150) only *posts and merges*
already-produced audit outputs for the read-only rungs; per the #130 architecture ("enforced in the right
place … the helper must not become a second home for cross-family enforcement") it must not re-implement
this check. The helper still enforces family on the two rungs it *runs itself* (`--design` and close, when
it invokes the audit) — but it does so by setting the same env contract this doc defines and letting the
audit runner do the blocking, not by carrying its own copy of the rule.

### The contract this defines (the interface the #130 cluster consumes)

Two inputs per rung, with identical semantics across both scripts:

- **`AAR_SUBSTRATE`** — the family that RAN the work being audited (`claude` | `codex`, exact match). Read
  by `audit_experiment.sh` on **all** modes (today: only `--scaffold`/`--code`). For `verify_claim.sh` the
  same variable names the family whose experiment produced the claims.
- **The verifier command** names the *auditor's* family. `audit_experiment.sh` already infers it from
  `AUDIT_VERIFIER_CMD` (`*claude*` → claude, `*codex*` → codex, else `custom`). `verify_claim.sh` uses a
  *different* variable today (`VERIFIER_CMD`); this doc makes it apply the **same inference** to whatever
  verifier variable it reads (see decision 3 for the naming reconciliation).

The two rules, applied uniformly to every model-judged rung:

1. **Explicit family or BLOCK.** `AAR_SUBSTRATE` must be exactly `claude` or `codex`. Unset, empty, or a
   typo (`codx`) BLOCKS with a message naming the rung — never a silent default. (A typo must not slip a
   same-family review past the gate, exactly as the `--scaffold` guard already reasons.)
2. **Different family or BLOCK.** The inferred auditor family must differ from `AAR_SUBSTRATE`. Equal →
   BLOCK. This guard already exists in `audit_experiment.sh` for all modes; the gap is only that rule (1)
   defaults instead of blocking on the four rungs, which lets a mis-set or unset runner family pair with a
   wrong-defaulted auditor and pass.

A consumer (the helper, `design-experiment`, `run-experiment`, or a human running the audit directly)
satisfies the contract by exporting `AAR_SUBSTRATE=<runner family>` and pointing the verifier command at the
opposite family. If it does neither, the rung fails closed.

### The load-bearing decisions

#### 1. Remove the silent default on the four rungs (the core fix)

In `audit_experiment.sh`, the close/`--design`/`--data` modes currently set
`RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}` — a **silent default to `claude`**. The `--scaffold`/`--code`
modes instead require an exact `claude|codex` and BLOCK otherwise. **Decision: apply the exact-match
requirement to all modes** (lift the existing `--scaffold`/`--code` `case` guard so it runs
unconditionally), so `RUNNER_FAMILY` is never defaulted. The downstream same-family check is unchanged; it
simply can no longer be fed a defaulted runner family.

This is a **behavior change for direct local invocation**: a human who today runs a close audit with no
`AAR_SUBSTRATE` set gets a default-claude review; after this they must state the family. That is the point —
the silent default is the bug. The #130 doc already flags the old default as "legacy for direct local
invocation only"; this doc retires it for the model-judged rungs. (Rollback below covers the escape hatch.)

#### 2. Give `verify_claim` the same contract (it has none today)

`verify_claim.sh` today has **no family logic at all**: it defaults its verifier to `codex` and never reads
`AAR_SUBSTRATE` or checks same-family. So on a Codex AAR, `verify_claim` is Codex-checking-Codex —
silently same-family, the exact failure the guarantee exists to prevent. **Decision: add the identical
two-rule contract** — read `AAR_SUBSTRATE` (explicit or BLOCK), infer the auditor family from the verifier
command, BLOCK if they match — reusing the same family-inference logic `audit_experiment.sh` uses, so the
two scripts agree on what "claude-family" vs "codex-family" means.

#### 3. Reconcile the verifier-command variable name across the two scripts

`audit_experiment.sh` reads **`AUDIT_VERIFIER_CMD`**; `verify_claim.sh` reads **`VERIFIER_CMD`**. The
family inference must run against whichever variable each script actually consumes, or the check reads the
wrong (or an unset) value and the inference is wrong. **Decision: keep each script's existing variable as
its primary (no rename that would break #134's `wf.sh` wiring or existing local invocations), and infer the
auditor family from that same variable inside each script.** The factored family-inference helper (decision
4) takes the verifier-command *string* as an argument, so it does not care which variable name supplied it.
The doc records the two names explicitly so the #150 helper and the skills set the right one per rung. (A
later unifying rename is a possible follow-up, but out of scope here — it would touch #134's wiring and is
not required for the guarantee.)

#### 4. Factor the family-inference + enforcement into one shared shell helper

The inference (`*claude*`/`*codex*`/`custom`), the explicit-family exact-match guard, and the same-family
BLOCK now need to be **identical** in two scripts (three, counting the existing `--scaffold`/`--code` path).
**Decision: extract a single small helper** (a sourced shell function, the natural seam for two sibling
scripts in one plugin) that takes `(runner_family, verifier_cmd, rung_label)` and either reports the
resolved families or exits non-zero with a rung-named BLOCK message. Both scripts call it; the
`--scaffold`/`--code` path is refactored onto it too, so there is **one** definition of the contract (DRY —
no second copy to drift, the failure mode the #134 comment already warns about with "future family-matcher
changes update both"). This keeps the canonical family-matcher in `verify-claims`, where the #130 doc says
it belongs.

#### 5. `custom` auditor family is allowed; only an *equal-to-runner* family BLOCKs

The existing inference yields `custom` for a verifier that is neither claude nor codex. A `custom` verifier
can never equal `claude` or `codex`, so it passes the same-family check — preserving today's behavior for
instances that wire a third-family or wrapper verifier. **Decision: keep `custom` permitted** (the contract
is "not the *same* family," not "must be one of two families"). The runner family, by contrast, must be
exactly `claude|codex` — because the same-family comparison is only meaningful against a known runner.

## Alternatives considered

- **Enforce the read-only-rung family in the #130 GitHub helper instead.** Rejected — directly contradicts
  the #130 architecture ("enforced in the right place … the helper must not become a second home for
  cross-family enforcement"). The read-only rungs run in `verify-claims`; the contract belongs there. The
  helper only posts/merges their outputs.
- **Keep the `:-claude` default but rely on the same-family check after defaulting.** Rejected — the
  same-family check already exists *after* the default and is exactly what the default defeats: a Codex
  runner who forgets `AAR_SUBSTRATE` defaults to `claude`, so a Codex auditor reads as cross-family and
  passes. The silent default is the hole; only removing it closes it.
- **Rename `VERIFIER_CMD` → `AUDIT_VERIFIER_CMD` to unify the two scripts.** Rejected for this change —
  it would touch #134's `wf.sh` wiring and every existing direct `verify_claim` invocation for no
  guarantee benefit (decision 3 gets the agreement without a rename). Possible later follow-up, not here.
- **Duplicate the guard inline in `verify_claim.sh` (copy the `audit_experiment.sh` block).** Rejected —
  two copies of the contract drift; the #134 comment already had to add a "update both" pointer. One sourced
  helper (decision 4) is the canonical home.
- **Leave `verify_claim` family-blind (it's "only" a fact check).** Rejected — a same-family fact check is
  exactly the confidently-wrong-claim failure the rung exists to catch; family-blindness there is the same
  unbacked-guarantee bug, just on the input side.

## Blast radius

- **`verify-claims` plugin only** — `verify_claim.sh`, `audit_experiment.sh`, and a new sourced helper
  (e.g. `cross_family.sh`) in the same scripts dir. No change to GitHub identity, branch protection, review
  posting, or the audit *prompts* / rubrics. The audits judge exactly the same thing; only the
  who-may-run-it guard changes.
- **Behavior change for direct local invocation** (decisions 1/2): close/`--design`/`--data`/`verify_claim`
  now BLOCK without an explicit `AAR_SUBSTRATE` instead of defaulting to claude (or being family-blind).
  Every in-tree caller must set it. The known callers to update/verify: `wf.sh` (already sets
  `AAR_SUBSTRATE` per #134 for the two ship-change rungs — unaffected, but its env contract should be
  cross-checked), the `design-experiment` / `run-experiment` skills (which invoke
  `--design`/`--data`/close/`verify_claim` and must export the runner family), and the existing smoke
  scripts. A sweep for callers is part of the implementation child.
- **Contract for the #130 cluster:** this is the prerequisite the umbrella records as `blocked-by` for the
  four-rung promise. After it lands, #150 (helper), #156 (`design-experiment` PR-open), and #157
  (`run-experiment` close) can rely on "set `AAR_SUBSTRATE` + opposite-family verifier, and the audit runner
  fails closed otherwise" rather than re-implementing the check.
- **Smoke coverage** is part of the implementation: a fake-verifier smoke (mirroring `identity_smoke.sh`'s
  pattern) asserting (a) unset `AAR_SUBSTRATE` BLOCKs on each rung, (b) same-family BLOCKs, (c)
  cross-family passes, for both scripts.

## Decomposition (spawned `ready` issues)

This design carries no remaining open sub-decision — the contract, the variable names, the helper seam, and
the `custom` semantics are all fixed above. It decomposes into implementable units with **no** further
`needs-design`. Dependency order: the shared helper lands first, then the two scripts adopt it, then the
caller sweep. (They could also be one PR; filed separately so each is a small reviewable diff, with the
order noted as `blocked-by`.)

1. **`ready` — Extract the cross-family enforcement helper** (`cross_family.sh`): one sourced shell function
   `(runner_family, verifier_cmd, rung_label)` → resolved families or rung-named BLOCK, implementing rules
   (1) explicit-family exact-match and (2) different-family, plus the `*claude*`/`*codex*`/`custom`
   inference. Refactor the existing `--scaffold`/`--code` guard in `audit_experiment.sh` onto it (one
   definition, no drift). No caller-visible behavior change for the two rungs that already enforce.
2. **`ready` (blocked-by #1) — `audit_experiment.sh`: enforce on close/`--design`/`--data`.** Replace
   `RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}` with the helper call so all modes require an explicit family and
   fail closed on same-family. Add smoke cases for the three previously-defaulting modes.
3. **`ready` (blocked-by #1) — `verify_claim.sh`: adopt the contract** (it has none today). Read
   `AAR_SUBSTRATE`, infer the auditor family from its verifier command via the helper, fail closed on
   unset/typo/same-family. Add smoke cases (unset BLOCKs, same-family BLOCKs, cross-family passes).
4. **`ready` (blocked-by #2, #3) — caller sweep + SKILL.md.** Audit every in-tree invoker of the four
   newly-enforcing rungs (the `design-experiment`/`run-experiment` skills, smoke scripts, any
   docs/examples) to export `AAR_SUBSTRATE`; confirm `wf.sh` (#134) is unaffected. Update the
   `verify-claims` SKILL.md to document the uniform contract across all six rungs.

## Rollout + rollback

Doc-only design PR; lands the contract on `main` via the `--scaffold` gate, then the four `ready` children
above are filed (each a normal `ship-change` run, in the dependency order noted). Staged so the helper lands
before the scripts adopt it and the caller sweep lands last, so no rung starts blocking before its callers
set the family.

Rollback is a normal revert of the spawned script edits — the rungs fall back to the prior behavior
(`audit_experiment` defaults the runner family to `claude`; `verify_claim` is family-blind). The audits
themselves are unchanged, so a revert loses only the enforcement, not any capability. Escape hatch for a
genuinely-stuck local invocation: set `AAR_SUBSTRATE` explicitly (the contract is satisfied by *stating*
the family, which is always possible) — there is deliberately **no** "skip the check" override, because a
skipped cross-family check is exactly the unbacked guarantee this closes.

Closes #154.
