# Proposal: shared GitHub-lifecycle helper — the seam both ship-change and the experiment flow consume (#150)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Doc-only design PR (a `needs-design` child of #130). Spawns `ready`/`blocked` children for the actual extraction.

## Problem

The "experiments through GitHub" epic (#130) decided that a research experiment should run through GitHub the
same way a scaffold change already does: an experiment is a branch, a PR, and two cross-family reviews posted to
that PR. But the GitHub plumbing that makes that work — figuring out *which* engineer bot identity to act as,
opening a draft PR, posting a cross-family review as a native APPROVE or a comment, and merging only after a gate
— already exists, and exists in exactly one place: `wf.sh`, the ship-change driver. If the experiment flow grows
its own copy of that plumbing, the two copies will drift, and a drift in the identity-or-review machinery is the
kind of bug that silently breaks the cross-family guarantee everything else rests on. So #130 decision 5 said:
do not fork `wf.sh` — extract the low-level primitives into a small shared helper that both flows call.

This issue (#150) is the design pass for that extraction. It is deliberately *only* design, because two of the
choices are genuinely open and getting them wrong is expensive: **where the shared helper lives** (it must not
create a dependency from the research runtime onto the build-tooling plugin, and it must not hand merge authority
to the read-only audit plugin), and **which primitives are "merge-authority" code that must load from a trusted
source rather than from the branch being reviewed** (the same trust hole `wf.sh` already closes for its reviewer
via `locate_audit`, now widened because the helper itself can open and merge PRs). This doc fixes the helper's
public contract — its function surface, its trust split, its host, and its rollback — so the consuming children
(#156 `design-experiment` PR-open, #157 `run-experiment` close + merge) and the `wf.sh` refactor can be written
against a stable interface instead of inventing one each.

## Approach

Extract the GitHub-lifecycle primitives out of `wf.sh` into a single shared library, `gh-lifecycle.sh`, that
both `wf.sh` (ship-change) and the experiment flow source. The library is **mechanism only** — it knows how to
resolve an engineer identity, open a draft PR, post a review, and run the merge gate, but it knows *nothing*
about ship-change's disposition close-gate or the experiment flow's research audits. Each consumer keeps its own
gates layered on top and calls down into the shared mechanism for the GitHub parts. After extraction `wf.sh`
becomes a thin consumer of the same library the experiment flow uses, so there is exactly one implementation of
the identity + review-posting machinery and no second copy to drift.

The contract has four parts: **(1)** a stable function surface the library exports; **(2)** a trust split that
marks some of those functions *merge-authority* — they must load their code from a trusted base ref, never from
the branch under review — and ships a poisoned-helper smoke that proves the split holds; **(3)** a host for the
library that is neither the build plugin nor the read-only audit plugin; and **(4)** a rollback path that keeps
`wf.sh` working throughout and lets the extraction be reverted as one unit before any experiment PR depends on
it. The cross-family *enforcement* logic stays where it already lives — the helper carries the identity and
posting mechanics, but it does not become a second home for the "is this reviewer the opposite family" check
(that boundary is owned by #154 and is explicitly out of this helper's scope; see *Blast radius*).

### 1. The function surface — what the library exports (the public contract)

The primitives below are what #156 and #157 will call. Names are the contract; signatures are
shell-function-shaped (positional args, stdout result, non-zero = fail-closed) to match how `wf.sh` already
factors these. The grouping into **runtime** vs **merge-authority** is decision 2; it is shown here so the
surface and the trust split read together. The line is drawn conservatively (per design-review FINDING 1):
**a function is merge-authority if it selects the diff/base/repo/SHA, resolves a privileged identity, posts a
native (merge-satisfying) review, or can merge.** Only *pure text rendering* is runtime. When in doubt, a
function is merge-authority — the cost of base-sourcing a function that didn't strictly need it is nil; the cost
of branch-sourcing one that did is a gate bypass.

**Identity + auth (MERGE-AUTHORITY).** Resolve and mint the engineer-bot identity for a given family, fail
closed when a named identity is required and missing — `engineer_token`, `engineer_token_cmd`,
`engineer_token_seam`, `engineer_git_author`, `family_suffix`, `opposite_family`, `reviewer_token`,
`author_token_optional`, `gh_author`, `git_push_author`. These are merge-authority: they decide *who acts* with
privileged credentials, and a branch that could rewrite "which family is the reviewer" or "mint the author's
own token to self-approve" would subvert the cross-family gate. Base-sourced.

**PR open (MERGE-AUTHORITY) + body rendering (split).** Opening a draft PR for a branch chooses the repo/branch
it targets and acts under a privileged identity, so the *open* path is merge-authority. PR-body generation is
**split** (design-review round 2, FINDING 1): the body emits the `Closes #N` **closing reference** that
`disposition_gate` later enforces (and `wf.sh` refreshes the body immediately before that gate), so **selecting
the closing reference is gate-relevant — merge-authority, base-sourced.** Only the *pure markdown formatting*
that is handed already-resolved content — `section_text`, `first_paragraph`, `markdown_details`,
`markdown_code_details`, and the prose-assembly portion of `render_pr_body` — is runtime. The extraction must
therefore factor `render_pr_body` so the closing-reference selection (which issue number the PR closes) is a
base-sourced merge-authority step distinct from the cosmetic body assembly. A branch that could rewrite the
closing-ref selection could make the PR close a different (e.g. already-`ready`) issue and slip the disposition
gate — exactly the hole this split prevents.

**Review posting — split inside `run_review`.** The *verdict mechanism* (locate the reviewer, run it, parse
`SUMMARY:`) is merge-authority. The act of **posting a native review** (`gh api .../pulls/$pr/reviews` with
`event=APPROVE`, bound to the head SHA) is *also* merge-authority — a branch that rewrote the posting call could
forge the merge-satisfying APPROVE or mis-bind the SHA. The **decision of which event to post** (whether the
verdict clears the gate) is the consumer's merge-policy (raw zero-HIGH vs zero-unresolved-HIGH, FINDING 2), fed
*into* the base-sourced poster — not baked into the shared primitive. Only `review_summary_text` and the
markdown formatting of the comment body are pure rendering (runtime). So in `run_review`, everything except the
human-readable text assembly is base-sourced, and the gate-clears-or-not call is supplied by the consumer.

**Merge MECHANISM (MERGE-AUTHORITY) — but NOT the merge-decision policy (round-2/round-3 FINDING 2).** The
shared library exports the *mechanism*: locate the cross-family reviewer from a trusted base ref
(`locate_audit`), run it under a bounded wait (`run_verifier_bounded`), parse the authoritative `SUMMARY:`
verdict fail-closed (`require_valid_review`, `count_high/med/low`, `count_all`, `sum_line`), SHA-bound native
posting, and the final-SHA re-review **execution**. These are base-sourced. But the **merge-DECISION policy
stays in each consumer**, because the two flows differ: ship-change merges on **raw zero-HIGH**, while #130
decision 2 requires the experiment close gate to merge on **zero-*unresolved*-HIGH** — a triage-aware decision
that "cannot simply parse `high=0`" (a legitimately-justified HIGH must pass). So the shared primitive returns
the parsed verdict + runs the re-review; **ship-change's raw `high=0` check stays in `wf.sh`**, and
`run-experiment` applies its own triage-artifact policy (#151) before requesting the native approval/merge. The
library never bakes in one flow's merge policy. (`audit_from_base_ref` is the *loader* for these, with the
bootstrap subtlety resolved in decision 2 — it is not itself loaded as a branch-suppliable merge-authority
function.)

**Repo/branch + diff/base selection (MERGE-AUTHORITY).** `gh_repo`, `wt_branch`, `base_ref`, `wt_pr`,
`require_clean`, `main_checkout` — these *select the repo, the branch, the integration base, and the reviewed
diff*, the exact inputs a poisoned branch would target to make the gate review the wrong thing. Per FINDING 1
they are merge-authority, base-sourced. Only `need_gh` / `need_ambient_gh` (PATH/auth presence checks with no
selection effect) are runtime.

What stays in `wf.sh` (NOT extracted): the disposition close-gate (`disposition_gate`, the `ready` /
`needs-design` issue contract), the finding-disposition state machine (`fd_*`, #137/#139), the classifier
invocation, the `--design` doc-only diff guard, **and the raw zero-HIGH merge-decision policy** (FINDING 2 —
the shared library runs the re-review and parses the verdict; whether `high=0` clears the gate is ship-change's
own call). These are ship-change policy, not shared mechanism. The
experiment flow has its own analogues (the triage-artifact schema #151, the design-clearance schema #145) and
must not inherit ship-change's. **This is the load-bearing line of the whole extraction: the library is the
GitHub *mechanism*; each flow keeps its own *policy*.**

### 2. The trust split — merge-authority code loads from a trusted source, never the branch under review

`wf.sh` already closes one instance of this hole: a ship-change PR that edits the verify-claims reviewer cannot
run its own branch-modified reviewer as its merge gate, because `locate_audit` resolves the reviewer from the
*base ref* (trusted-but-current, #69), not from the worktree. Extracting the helper *widens* the exposure: the
helper now also carries PR-open and merge-posting authority, so a branch that edited `gh-lifecycle.sh` could, if
the driver sourced the branch copy, run its own modified open/merge logic as its own gate.

The split (the full assignment is in decision 1's function surface; the principle here):

- **Merge-authority functions** — anything that selects the diff/base/repo/SHA, resolves a privileged identity,
  posts a native (merge-satisfying) review, or can merge — must be resolved from the **trusted base ref /
  install**, exactly as `locate_audit` already resolves the reviewer, never from the worktree under review. This
  is the *majority* of the surface (FINDING 1); the conservative default is base-sourced.
- **Runtime functions** — only pure text rendering (`section_text`, `first_paragraph`, `markdown_details`,
  `markdown_code_details`, `review_summary_text`, and the *cosmetic body-assembly* portion of `render_pr_body`
  once the closing-reference selection is split out per FINDING 1) and PATH/auth presence checks (`need_gh`,
  `need_ambient_gh`) — may run from the branch copy. A branch editing its own markdown formatter changes only
  cosmetics and cannot affect what is reviewed, who acts, which issue is closed, or whether it merges.
- **Poisoned-helper smoke.** Ship a smoke test matching `locate_audit_smoke.sh`: construct a branch that edits
  `gh-lifecycle.sh`'s merge-authority code to a known-bad behavior (e.g. force `count_high` to return 0, or
  rewrite `opposite_family` to return the author's own family), run the gate, and assert the gate used the
  trusted-base copy (the poison did NOT take effect). This is the mechanical proof the split holds, and it is a
  deliverable of the extraction child, run by `.aar-ci/checks.sh`.

#### The trusted loader — resolving the bootstrap circularity (FINDING 2)

There is a bootstrap problem: the merge-authority functions must be *loaded* from a trusted base ref, but the
existing base-ref materialization (`audit_from_base_ref`) is itself a function — if it lived in
`gh-lifecycle.sh` and were sourced from the branch, a poisoned branch could rewrite the very loader meant to
keep itself honest. The resolution is a **minimal trusted loader that stays outside branch-controlled code**:

- A tiny, self-contained `gh-lifecycle-load.sh` (a few dozen lines: resolve the base ref, `git archive` the
  trusted `gh-lifecycle.sh` from that ref into the git-common-dir cache keyed by the base commit — the
  mechanism `audit_from_base_ref` already proved — then source the cached copy). This loader is what each
  consuming driver invokes; it is **not** part of the materialized library, so it is never the thing being
  loaded from the branch.
- **Sourcing order + namespacing.** The trusted (base) copy is sourced **last** so a branch copy sourced
  earlier cannot shadow a merge-authority function (last definition wins in bash). Merge-authority functions
  carry a distinct name prefix (e.g. `ghl_*`) in the extracted library so the loader can assert post-source that
  every expected `ghl_*` symbol resolves to the trusted definition (a defensive check the smoke exercises), and
  so a branch-defined function of a different name can never silently stand in for one.

#### The trusted entrypoint — the boundary must terminate in base code, not a branch driver (round-2 FINDING 3)

A loader that base-sources the *library* still leaves a hole: the **driver itself** (`wf.sh`,
`run-experiment`) is branch-controlled when a PR edits *that file* — and ship-change PRs do edit `wf.sh`. A
branch-resident bootstrap, however "inert," is still removable or conditionable by a poisoned PR *before* it
reaches the trusted boundary (round-3 FINDING 1). **So the boundary must not be reached *through* branch code at
all.** The rule:

- **Merge-authority commands enter through an installed/base-materialized launcher OUTSIDE the reviewed
  worktree.** The agent already invokes `wf.sh` from the **skill install**, not from the worktree under review
  (SKILL.md: "`wf.sh` is `scripts/wf.sh` in this skill"; #69's source-first discovery drives reviews "from the
  main checkout's `wf.sh`"). That property is made **load-bearing and explicit**: the merge-authority entrypoint
  is the installed/base launcher, and it *materializes the driver + library from the trusted base ref* itself —
  it never sources or executes the worktree's copy of the driver. The reviewed worktree's `wf.sh` /
  `run-experiment` is treated as **data under review, not the security boundary**: when a branch-local driver is
  invoked for a merge-authority command, it is a **refusing stub** that hands off to (or errors directing the
  caller to) the base launcher — it never runs the gate itself.
- **The launcher carries the only trusted bootstrap, and it lives in base/install — not on the branch.** Because
  the launcher is not part of the reviewed diff, a PR that poisons the worktree's driver cannot remove or
  condition it. The **poisoned-driver smoke proves it**: the smoke poisons the *driver file on the branch* (not
  just the library), invokes a merge-authority command, and asserts the gate ran the trusted base behavior (the
  poison did not take effect, and the branch driver did not become the boundary). Strictly stronger than the
  poisoned-*helper* smoke.
- **Scope/cost note.** The base-launcher entry is needed only for the merge-authority *commands* (those that can
  merge/approve/select-closing-ref/mint a privileged write), not for read-only subcommands (`doctor`, interim
  `design-review` comments), which may run from the worktree copy. The extraction child decides the exact set of
  base-entry commands, but the rule — *no merge-authority command's security boundary is branch-resident; it
  enters through the installed/base launcher* — is settled here.

The chain that terminates **entirely outside the reviewed worktree**: installed/base launcher → base-materialized
driver → base-sourced loader → base-sourced merge-authority library; the worktree driver is data, a refusing
stub for merge-authority commands. The split is drawn at the function level rather than file level so the
boundary survives future edits: a new function lands on one side of the line explicitly. The extraction child
implements the base launcher + the loader + the base-ref materialization for the merge-authority set + **both**
smokes (poisoned helper *and* poisoned driver); the boundary itself is no longer open design (this doc settles
which functions are merge-authority and that the merge-authority entrypoint lives in base/install, never on the
branch).

### 3. Host — a neutral GitHub-lifecycle runtime helper, not the build plugin, not the audit plugin

#130 fixed the two negative constraints; this doc picks the host. The constraints:

- **Not `aar-engineering`.** That is the *build-the-product* plugin (installed only by scaffold developers via
  ship-change). The research runtime — `experiment-lifecycle` / `run-experiment` — must take **no** dependency
  on the build-tooling layer, or every research instance would have to install the build plugin to run an
  experiment. (`AGENTS.md` "Two layers": the SWE pipeline that *builds* the product vs. the research product it
  *ships*.)
- **Not `verify-claims`.** That plugin is the **read-only** adversarial-audit engine — it *produces* audit
  findings and is deliberately given no mutation authority. Handing it draft-PR creation, identity minting, and
  merge authority would make the read-only plugin own write/merge it has no business owning, and would couple
  the audit engine to GitHub plumbing it is correctly ignorant of today.

**Decision: a new dedicated plugin, `aar-github-lifecycle`, shaped as a normal skill plugin** —
`plugins/aar-github-lifecycle/` with `.claude-plugin/plugin.json` + `skills/github-lifecycle/SKILL.md` +
`skills/github-lifecycle/scripts/` holding `gh-lifecycle.sh`, the trusted loader `gh-lifecycle-load.sh`, and the
poisoned-helper smoke. A dedicated plugin (rather than folding the library into an existing runtime plugin like
`experiment-lifecycle`) is chosen because: **(a)** it has exactly one well-scoped job — the GitHub mechanism —
and both consumers (`aar-engineering`/ship-change *and* `experiment-lifecycle`) sit *above* it, so it must not
live *inside* either consumer or it recreates the dependency-direction problem from a different angle; **(b)** a
standalone plugin gives the merge-authority code a clean, independently-versioned home that the trusted-base
materialization (decision 2) can target by name; **(c)** it makes the rollback (decision 4) a single revertible
unit.

**It is skill-shaped to satisfy the module convention and the install gate (design-review FINDING 3).** The repo
convention is `plugins/<name>/` with `.claude-plugin/plugin.json` + `skills/<name>/SKILL.md` +
`skills/<name>/scripts/` (AGENTS.md "Spec layout"), and the fake-HOME behavior smoke fails any installed plugin
with **no resolvable `skills/*/SKILL.md`**. A no-skill plugin would be undiscoverable and fail that gate, so the
helper ships a real (thin) `SKILL.md`. That `SKILL.md` documents the consumed library — what it exports, the
runtime/merge-authority split, and that it is *sourced by drivers, not invoked by an agent directly* — which is
also the right home for the contract this doc establishes. Scripts live **inside** the skill dir
(`skills/github-lifecycle/scripts/`) per the layout rule, so consumers resolve them by the standard
source-first plugin-skill path (#69's discovery convention), with the merge-authority subset re-materialized
from the base ref by the trusted loader (decision 2). The exact `plugin.json` version-bump wiring and the
`.aar-ci` hook are settled here as the contract; the extraction child implements them.

### 4. Install / discovery dependency contract (round-2 FINDING 2)

`aar-github-lifecycle` becomes a **required dependency** of both `aar-engineering` (ship-change) and
`experiment-lifecycle` — but a new required dependency that is not declared, installed, and proven-resolvable on
a fresh machine is a silent install break. The contract:

- **Marketplace + README.** `aar-github-lifecycle` is added to `.claude-plugin/marketplace.json` and to the
  README install list, and the README states it is a dependency the consumers source (installed automatically
  as a dependency where the harness supports plugin deps, or listed as a required companion install otherwise).
- **Resolution path.** Consumers resolve the library by the source-first plugin-skill discovery convention
  (#69): they locate `aar-github-lifecycle`'s skill scripts dir the same way `wf.sh` already locates
  verify-claims, with the merge-authority subset re-materialized from base ref by the trusted loader/entrypoint
  (decision 2). The library's location is therefore not hardcoded to one install layout — it is discovered, with
  a fail-closed error if the dependency is absent (never a silent fallback to a missing/forked copy).
- **Cross-plugin install smoke (a deliverable).** Today `.aar-ci/fake_home_smoke.sh` installs only the single
  plugin under test. The extraction child extends the smoke (or adds a companion) to install **each consumer
  together with its declared `aar-github-lifecycle` dependency** in a virgin HOME and assert the consumer can
  *resolve and source* the helper — the install-path proof that the dependency contract holds, the same role the
  existing fake-HOME smoke plays for a single plugin.
- **Codex skill mirror.** The repo mirrors plugins into Codex skill installs; the extraction child updates that
  mirror so the helper is present on the Codex path too (the same surface #69's discovery already spans).

This contract is settled here; the extraction child implements the marketplace/README/Codex-mirror edits and the
cross-plugin smoke.

### 5. The contract for the #130 consumers

This is the interface #156 and #157 are `blocked-by`. They consume the helper as:

All the functions a consumer calls that resolve identity, open the PR, select the closing reference, post a
native review, or merge are **merge-authority — base-sourced via the trusted loader (decision 2)**; only the
cosmetic markdown formatting of a comment/body is runtime. So "the consumer calls identity + posting" never
means "branch-sourced": those paths run from the trusted base copy. (This corrects the earlier loose phrasing
that called identity/posting "runtime" — they are merge-authority; only the comment text rendering is runtime.)

- **#156 (`design-experiment` PR-open + `--design` posting + fact-record linking):** calls the base-sourced
  identity-resolution + PR-open (incl. closing-ref selection) + review-posting to open the experiment's draft PR
  and post the `audit_experiment --design` review as a COMMENT (the design review is *not* merge-satisfying per
  #130 decision 2 — it gates the run, not the merge). It does NOT call the merge gate. Only the comment's
  markdown body is rendered by runtime formatters.
- **#157 (`run-experiment` push + close-review + merge):** calls the base-sourced identity + push + review-
  posting to push records and post the close `audit_experiment` review, and the base-sourced **merge gate** for
  the final-SHA re-review + zero-unresolved-HIGH decision — the experiment flow's own triage gate (#151) layered
  on top of the shared zero-HIGH mechanism, the same way ship-change layers its disposition gate.

Both call the *same* base-sourced identity + posting + merge code `wf.sh` uses, so the cross-family attribution
and SHA-binding are identical to ship-change's by construction. Neither consumer re-implements GitHub plumbing;
each supplies its own policy gate above the shared mechanism. The cross-family *family check* on the audit rungs
those consumers run is **not** the helper's job — it is #154's (audit-runner cross-family contract); the helper
only carries the identity/posting mechanics and the merge-authority trust split.

## Alternatives considered

- **Fork the GitHub glue into `experiment-lifecycle` (no shared helper).** Rejected by #130 decision 5 and
  re-confirmed here: two copies of the identity + review-posting machinery guarantee drift, and a drift there
  silently breaks the cross-family guarantee. The whole point of #150 is to avoid this.
- **Host the helper in `aar-engineering`.** Rejected: makes the research runtime depend on the build-tooling
  plugin (#130's explicit negative constraint). Every research instance would have to install the build plugin.
- **Host the helper in `verify-claims`.** Rejected: that plugin is read-only by design; giving it draft-PR /
  identity / merge authority is the wrong seam (#130 constraint).
- **Fold the library into `experiment-lifecycle` (a consumer) instead of a dedicated plugin.** Rejected: one of
  the two consumers (ship-change, in `aar-engineering`) would then depend on the *other* consumer's plugin —
  the same dependency-direction problem, just rotated. The shared mechanism belongs below both consumers.
- **Draw the trust split at the file level (whole helper is merge-authority, always base-ref).** Rejected:
  over-broad — it would force the cosmetic PR-body renderer and the identity minter through base-ref
  materialization for no security benefit, and a future runtime-only function would inherit a constraint it
  doesn't need. The function-level split (decision 2) keeps the merge-authority set minimal and explicit.
- **Big-bang refactor (move everything, delete the `wf.sh` copies in one PR with no shim).** Rejected: `wf.sh`
  is the machinery every future scaffold change depends on; a regression there blocks *all* shipping. The
  rollout (below) keeps `wf.sh` behavior-identical behind the extraction and makes the change one revertible
  unit (decision 4 / *Rollout*).

## Blast radius

- **New plugin** `aar-github-lifecycle` — skill-shaped (`skills/github-lifecycle/SKILL.md` +
  `skills/github-lifecycle/scripts/{gh-lifecycle.sh, gh-lifecycle-load.sh, poisoned-helper + poisoned-driver
  smokes}` + `.aar-ci` hook), so it passes the module-shape convention and the fake-HOME install gate. The
  SKILL.md documents the library; the library is *sourced by drivers*, not invoked by an agent.
- **Install surface** (decision 4): `.claude-plugin/marketplace.json` + README install list + the Codex skill
  mirror gain the new plugin; `.aar-ci/fake_home_smoke.sh` gains a cross-plugin install assertion (each consumer
  + its declared helper dependency resolves in a virgin HOME).
- **`aar-engineering` / `wf.sh`** is refactored to source the shared library instead of carrying its own copies
  of the extracted primitives, *and* to route its merge-authority subcommands through the installed/base
  launcher (decision 2 — the worktree driver becomes a refusing stub for those). This is the one cross-cutting
  edit #130 flagged. `wf.sh`'s public subcommand
  surface (`start`/`open`/`design-review`/`code-review`/`classify`/`finish`/`issue`/`comment`/`doctor`/`fdispo`)
  is **unchanged** — the refactor is internal. The disposition gate, `fd_*` state, classifier, and `--design`
  guard stay in `wf.sh` (decision 1); the closing-ref selection is split out of `render_pr_body` as
  merge-authority (decision 2 / round-2 FINDING 1).
- **`experiment-lifecycle`** (`design-experiment` / `run-experiment`) gains a *new* dependency on the shared
  helper — wired by the consumer children #156 / #157, not by this extraction. This doc only fixes the contract
  they consume.
- **Explicitly NOT in scope (owned elsewhere):** the cross-family *family-check* enforcement on the four
  audit rungs is **#154**'s (audit-runner cross-family contract) — the helper carries identity/posting mechanics
  and the merge-authority trust split, not the family check. The experiment triage-artifact schema is **#151**;
  the design-clearance schema is **#145**; the canonical record path is **#155**. The helper touches none of
  their contracts; it sits below them.
- **Product vs instance:** the helper and the `wf.sh` refactor are **product** (scaffold). The experiment PRs
  the consumers eventually produce land in the **instance research repo**, resolved via the instance-profile
  contract (#153) — the helper takes repo/identity as inputs, hardcodes nothing.

## Rollout + rollback

Doc-only design PR (this one): lands the contract on `main` via the `--scaffold` gate, then spawns the
extraction child(ren). Staging of the *implementation*:

1. **Land the new plugin + the `wf.sh` refactor in one PR, behavior-identical.** The extracted library is
   sourced by `wf.sh`; the merge-authority subset is materialized from the trusted base ref and reached only via
   the installed/base launcher (decision 2 — the worktree driver is a refusing stub for merge-authority
   commands); the marketplace/README/Codex-mirror install surface and
   the cross-plugin smoke (decision 4) land in the same PR; the **poisoned-helper smoke, the new poisoned-driver
   smoke, and the existing `locate_audit_smoke`** all pass; `wf.sh`'s subcommand surface and output are
   unchanged. This PR ships through ship-change's *own* `--code` gate — i.e. the machinery refactors itself under
   its current gate, the safest order (the new code is exercised by ship-change *before* any experiment PR
   depends on it). Note the bootstrap subtlety the trust split makes explicit: because this PR edits
   merge-authority code AND the driver entrypoint, its *own* merge gate runs the **base-ref** (pre-change) copy
   of both — the new behavior is only ever exercised by ship-change runs *after* it lands, which is the intended
   trust property, not a gap.
2. **Only after (1) is merged and a ship-change run has exercised the shared library** do the experiment
   consumers (#156 / #157) wire to it. The experiment-PR path is not made default in `run-experiment` until
   it has been piloted on a single real experiment (per #130's staged rollout).

**Rollback.** The extraction is one squash commit on `main` (the plugin add + the `wf.sh` refactor). Revert it
with the standard one-command revert (RUNBOOK "One-command revert"): `wf.sh` falls back to its own in-file
copies of the primitives (the revert restores them) and ship-change keeps working with zero data loss, because
the refactor is behavior-preserving and no experiment PR depends on the helper until step 2. Reverting *after*
step 2 additionally requires reverting the consumer wiring (#156/#157), so the consumers are filed `blocked-by`
this extraction precisely to keep the dependency order — and the rollback order — linear. The standalone-plugin
host (decision 3) is what makes the extraction a single revertible unit.
