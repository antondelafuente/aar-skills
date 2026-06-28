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
is one uniform rule across all six rungs: **no subject family stated → BLOCK; verifier family == the rung's
subject family → BLOCK** (where the "subject" is rung-specific — design author, data producer, executor, or
change author; see the contract below). This is the contract the rest of the #130 cluster consumes; it owns family enforcement for the
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

- **`AAR_SUBSTRATE`** — the family that produced **the artifact this rung audits** (`claude` | `codex`,
  exact match). This is **not** uniformly "the runner" — in the #130 design→execute seam the design author
  and the executor can be *different agents/families*, so each rung names a **rung-specific subject**:
  - `verify_claim` → the family that authored the **claims / the design's facts** (the design author);
  - `audit_experiment --design` → the **design author**;
  - `audit_experiment --data` → the family that **produced the data** (the executor running generation);
  - `audit_experiment` close → the **executor** (who ran the experiment and wrote the records);
  - `--scaffold` / `--code` → the **change author** (unchanged from today).
  The mechanical check is the same everywhere — *the auditor's family must differ from this subject's* — but
  the **caller is responsible for setting `AAR_SUBSTRATE` to the correct rung-specific subject**, not a
  blanket "runner." The #130 cluster (#156 `design-experiment`, #157 `run-experiment`) owns wiring the right
  subject per rung; this contract defines *what subject each rung means* and fails closed if it is unstated.
  Read by `audit_experiment.sh` on **all** modes (today: only `--scaffold`/`--code`); `verify_claim.sh`
  reads the same variable.
- **The verifier command** names the *auditor's* family. `audit_experiment.sh` already infers it from
  `AUDIT_VERIFIER_CMD` (`*claude*` → claude, `*codex*` → codex, else `custom`). `verify_claim.sh` uses a
  *different* variable today (`VERIFIER_CMD`); this doc makes it apply the **same inference** to whatever
  verifier variable it reads (see decision 3 for the naming reconciliation).
- **`AUDIT_VERIFIER_FAMILY`** (optional) — an explicit auditor-family declaration for an **opaque** verifier
  command (a wrapper / shim, allowlisted to `claude|codex`). It is trusted only when the command is *not*
  self-identifying; if it **conflicts** with a recognizable `*claude*`/`*codex*` command it **fails closed**
  rather than overriding it (so a stale declaration can't pass a same-family verifier). See decision 5.

The two rules, applied uniformly to every model-judged rung:

1. **Explicit family or BLOCK.** `AAR_SUBSTRATE` must be exactly `claude` or `codex`. Unset, empty, or a
   typo (`codx`) BLOCKS with a message naming the rung — never a silent default. (A typo must not slip a
   same-family review past the gate, exactly as the `--scaffold` guard already reasons.)
2. **Different family or BLOCK.** The inferred auditor family must differ from `AAR_SUBSTRATE`. Equal →
   BLOCK. This guard already exists in `audit_experiment.sh` for all modes; the gap is only that rule (1)
   defaults instead of blocking on the four rungs, which lets a mis-set or unset runner family pair with a
   wrong-defaulted auditor and pass.

A consumer (the helper, `design-experiment`, `run-experiment`, or a human running the audit directly)
satisfies the contract by exporting `AAR_SUBSTRATE=<this rung's subject family>` (per the rung table above)
and pointing the verifier command at a different family. If it does neither, the rung fails closed.

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
resolved families (including the `AUDIT_VERIFIER_FAMILY` declaration path from decision 5) or exits
non-zero with a rung-named BLOCK message. Both scripts call it; the `--scaffold`/`--code` path is
refactored onto it too, so there is **one** definition of the contract *within `verify-claims`* (DRY — no
second copy to drift across the three modes, the failure mode the #134 comment already warns about with
"future family-matcher changes update both"). This makes `verify-claims` the canonical family-matcher home,
where the #130 doc says it belongs.

**The `wf.sh` mirror is the one acknowledged exception.** `wf.sh` lives in the **`aar-engineering` build
plugin**, not the `verify-claims` runtime plugin, and its `is_claude_verifier_cmd` preflight runs *before*
it ever invokes the audit (to fail a Codex author fast with a clear message). A runtime build-plugin →
verify-claims source dependency would be the wrong direction (the #130 doc is explicit that the build plugin
must not become a runtime dependency). So this helper is **scoped to `verify-claims`**; the `wf.sh` matcher
stays a deliberate narrow mirror. To keep the two honest, decision 4's helper must expose the matcher in a
form `wf.sh` can assert against, and the caller-sweep child (below) adds a **drift check** (a smoke or
`.aar-ci` assertion that the `wf.sh` mirror and the `verify-claims` matcher agree on the same inputs) so the
mirror can never silently diverge — replacing today's bare "keep this synced" comment with a mechanical
guard.

#### 5. An *unidentifiable* verifier must declare its family or BLOCK (no silent `custom` cross-family pass)

The existing inference yields `custom` for a verifier command that contains neither `claude` nor `codex`,
and `custom` can never equal `claude` or `codex`, so it **passes** the same-family check today. That is a
real hole: a *wrapper* verifier — a script named `verify.sh`, `review`, a venv shim — that actually shells
out to the **same** family as the runner would be inferred `custom` and slip past, so the contract would no
longer prove "genuinely different family." A `custom` pass is only safe when the command really is a
distinct third family; the inference cannot tell a genuine third-family CLI from a same-family wrapper.

**Decision: an unidentifiable verifier (inferred `custom`) BLOCKs unless its family is *explicitly
declared*.** Add an optional `AUDIT_VERIFIER_FAMILY` env var (the auditor's family, allowlisted to `claude|codex`). The resolution is
conflict-safe: if the command matches `*claude*`/`*codex*`, use that inference — and if a declaration is
*also* set and *disagrees*, **BLOCK** on the conflict; if the command is opaque, use the declaration if set,
else BLOCK with "the verifier command does not identify its family — set `AUDIT_VERIFIER_FAMILY`." (The
full ordering is in decision 5's contract above.) Then the same-family check
runs on the resolved family as before: a declared family that equals the subject BLOCKs; a declared distinct
family passes. This preserves genuine third-family / wrapper support **without** letting an opaque command
silently claim cross-family status. The subject family (`AAR_SUBSTRATE`) must still be exactly
`claude|codex` — the same-family comparison is only meaningful against a known subject.

`AUDIT_VERIFIER_FAMILY` is **allowlisted, not free-form** (FINDING 4): accepted values are exactly
`claude|codex` for now, so a typo (`claud`) BLOCKs rather than becoming a passing "distinct family." A real
third-family registry/config is a deliberate future extension, out of scope here — until it exists, a
declared family that is neither `claude` nor `codex` BLOCKs.

**Explicit declaration is for *opaque* commands only — it never overrides an identifiable command, and a
conflict fails closed.** A declaration that could override a self-identifying command would open the inverse
hole: a *stale or wrong* `AUDIT_VERIFIER_FAMILY` (left in the shell, or copied from another run) could mark
a genuinely **same-family** verifier as cross-family and pass — the exact failure this doc exists to
prevent, just from the declaration side. So the resolution is conflict-safe:

1. If the command matches `*claude*`/`*codex*` (identifiable) **and** `AUDIT_VERIFIER_FAMILY` is unset or
   *agrees* → use the inferred family.
2. If the command is identifiable **and** the declaration *disagrees* → **BLOCK** (conflict: "the verifier
   command looks like family X but `AUDIT_VERIFIER_FAMILY=Y` — refusing to trust a declaration that
   contradicts a recognizable command"). Never silently let the declaration win over a recognizable command.
3. If the command is **opaque** (no token match) → the allowlisted `AUDIT_VERIFIER_FAMILY` is authoritative
   (this is the one case it is *needed* and *trusted*); unset → BLOCK (unidentifiable, undeclared).

So declarations only ever *add* information for genuinely-ambiguous commands; they can never *override* a
recognizable one. (Separately, tightening the substring matcher — anchoring it to known direct-CLI
basenames so a misleading *path* token like `/opt/claude-shim/run-codex` can't auto-satisfy — is folded into
the decision-4 helper child as a smoke case; the conflict-fail-closed rule above is what closes the
declaration-side gap regardless of how sharp the inference is.)

**Scope: the `AUDIT_VERIFIER_FAMILY` declaration applies to the rungs whose family `verify-claims`
resolves** — the four read-only/close rungs plus the `--scaffold`/`--code` resolution *inside*
`audit_experiment.sh`. It does **not** loosen `wf.sh`'s separate **preflight** for `--scaffold`/`--code`,
which fast-fails a Codex author whose `AUDIT_VERIFIER_CMD` is not a Claude-*string* (#134). That preflight is
intentionally a string check (it runs before the audit, to give a clear early error), and on this fleet the
ship-change verifier is always a real `claude -p …` command — so the wrapper-declaration path is not needed
there. If a future install genuinely needs a wrapper verifier for ship-change rungs, updating the `wf.sh`
preflight to consult the shared resolver is a scoped follow-up (it rides the decision-4 drift check that
already keeps the two matchers aligned) — not required for the four-rung guarantee this doc backs.

#### 6. Each rung writes a durable cross-family marker into its audit artifact (so #150 can validate, not re-check)

The #130 helper (#150) *posts and merges* already-produced audit outputs for the read-only rungs without
re-running them. For that to be safe, a fresh reader (and the helper's merge gate) must be able to tell an
**enforced cross-family** audit from a stale or family-blind one — but today the resolved families are only
echoed to **stderr**, which does not survive into the committed artifact. **Decision: each rung writes a
small machine-readable marker into (or beside) its output file** — `subject_family`, `auditor_family`, and a
`contract_version` — as a stable header (or sidecar) on the audit artifact. This lets #150 *validate the
marker* (right families, current contract version) without re-implementing family matching — keeping the
enforcement canonical in `verify-claims` while giving the helper a verifiable signal. The marker also makes
a stale/manual family-blind output (no marker, or an old contract version) detectable rather than silently
trusted. The exact serialization (a fenced header block vs a `.family.json` sidecar) is an implementation
detail of the helper child, but the *fields* are fixed here as the contract #150 reads.

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
  (`run-experiment` close) can rely on "set `AAR_SUBSTRATE` to the rung's subject + opposite-family
  verifier, and the audit runner fails closed otherwise" rather than re-implementing the check — and #150
  **validates the durable cross-family marker** (decision 6) on each audit artifact it posts/merges instead
  of re-running or re-matching family itself.
- **`wf.sh` mirror (cross-plugin):** `aar-engineering/scripts/wf.sh` keeps its narrow `is_claude_verifier_cmd`
  preflight (it must not take a runtime dependency on `verify-claims`), now guarded by a **drift check**
  against the `verify-claims` matcher (decision 4 / FINDING 3) instead of a bare comment.
- **Smoke coverage** is part of the implementation: a fake-verifier smoke (mirroring `identity_smoke.sh`'s
  pattern) asserting, for both scripts, (a) unset `AAR_SUBSTRATE` BLOCKs on each rung, (b) same-family
  BLOCKs, (c) cross-family passes, (d) an opaque verifier with no `AUDIT_VERIFIER_FAMILY` BLOCKs and one
  with a declared distinct family passes, (e) a declaration that **conflicts** with an identifiable command
  BLOCKs, (f) the cross-family marker (decision 6) is written with the right fields; plus the
  `wf.sh`↔`verify-claims` matcher drift check and `wf.sh review_audit_env` clearing `AUDIT_VERIFIER_FAMILY`.

## Decomposition (spawned `ready` issues)

This design carries no remaining open sub-decision — the contract, the variable names, the helper seam, the
`AUDIT_VERIFIER_FAMILY` declaration, and the wrapper/`custom` semantics are all fixed above. It decomposes
into implementable units with **no** further `needs-design`. Dependency order: the shared helper lands
first, then each script adopts it **together with the doc/caller updates that teach its new contract**
(FINDING 2 — enforcement and the docs that teach it ship atomically, never enforcement-then-docs). (They
could also be one PR; filed separately so each is a small reviewable diff, with the order noted as
`blocked-by`.)

1. **`ready` — Extract the cross-family enforcement helper** (`cross_family.sh`): one sourced shell function
   `(runner_family, verifier_cmd, rung_label)` → resolved families or rung-named BLOCK, implementing rules
   (1) explicit-family exact-match and (2) different-family, the `*claude*`/`*codex*` inference, **and the
   conflict-safe `AUDIT_VERIFIER_FAMILY` declaration path** (decision 5: authoritative for opaque commands,
   fail-closed when it conflicts with an identifiable command, allowlisted to `claude|codex`). Refactor the
   existing `--scaffold`/`--code` guard in `audit_experiment.sh` onto it (one definition, no drift).
   **Behavior-changing for `--scaffold`/`--code` too:** decision 5 means a previously-passing `custom`
   (unidentifiable) verifier on those rungs now BLOCKs unless `AUDIT_VERIFIER_FAMILY` is declared — so this
   PR is treated as behavior-changing for all three already-enforced modes, with its own smoke coverage,
   doc note, and plugin version bump shipped atomically (not "no caller-visible change"). **Also expose the
   matcher in a form `wf.sh` can assert against, and add the `wf.sh`-mirror drift check** (decision 4).
   **And update `wf.sh`'s `review_audit_env` to clear/set `AUDIT_VERIFIER_FAMILY`** (alongside the vars it
   already clears) so ambient shell state cannot alter or block a ship-change review, with identity-smoke
   coverage for it (the new authoritative env var is otherwise an uncontrolled input to every ship-change
   review).
2. **`ready` (blocked-by #1) — `audit_experiment.sh`: enforce on close/`--design`/`--data`, with docs +
   marker.** Replace `RUNNER_FAMILY=${AAR_SUBSTRATE:-claude}` with the helper call so all modes require an
   explicit family and fail closed on same-family / unidentifiable-verifier / declaration-conflict. **Write
   the durable cross-family marker** (`subject_family`, `auditor_family`, `contract_version` — decision 6)
   into each mode's output artifact. Add smoke cases for the three previously-defaulting modes + the marker.
   **In the same change**, update the `verify-claims` SKILL.md and any `design-experiment`/`run-experiment`
   doc/checklist examples that teach these three rungs to export `AAR_SUBSTRATE` (so no doc teaches a
   now-blocking invocation — FINDING 2).
3. **`ready` (blocked-by #1) — `verify_claim.sh`: adopt the contract, with docs + marker.** Read
   `AAR_SUBSTRATE`, infer the auditor family from its verifier command via the helper, fail closed on
   unset/typo/same-family/unidentifiable/conflict. **Write the same cross-family marker** (decision 6) into
   its verdict artifact. Add smoke cases. **In the same change**, update the SKILL.md and any caller
   examples that teach `verify_claim` to set `AAR_SUBSTRATE` (FINDING 2).
4. **`ready` (blocked-by #2, #3) — residual caller sweep + final SKILL.md pass.** Sweep for any remaining
   in-tree invoker not already updated in #2/#3 (skill checklists, examples), confirm `wf.sh` (#134) is
   unaffected, and finalize the `verify-claims` SKILL.md statement of the uniform contract across all six
   rungs. This is the *catch-all* after the per-script doc updates, not the first place docs change.

## Rollout + rollback

Doc-only design PR; lands the contract on `main` via the `--scaffold` gate, then the four `ready` children
above are filed (each a normal `ship-change` run, in the dependency order noted). Staged so the helper lands
first, then **each enforcing script change ships the docs/examples that teach its new contract in the same
PR** (FINDING 2 — never enforcement-then-docs), with the residual sweep last. No rung starts blocking
before the docs at its point of need stop teaching a now-blocking invocation.

Rollback is a normal revert of the spawned script edits — the rungs fall back to the prior behavior
(`audit_experiment` defaults the runner family to `claude`; `verify_claim` is family-blind). The audits
themselves are unchanged, so a revert loses only the enforcement, not any capability. Escape hatch for a
genuinely-stuck local invocation: set `AAR_SUBSTRATE` explicitly (the contract is satisfied by *stating*
the family, which is always possible) — there is deliberately **no** "skip the check" override, because a
skipped cross-family check is exactly the unbacked guarantee this closes.

Closes #154.
