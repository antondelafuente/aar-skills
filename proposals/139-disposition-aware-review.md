# Proposal: turn on the disposition-aware merge-gate review (#139)

> Implements **#137** slice 2 of 3 (after #138 landed the file format + structural gate). This wires the
> disposition-aware review into ship-change's `--scaffold`/`--code` merge gate — the slice that makes the
> gate actually *stateful*. #140 (fresh-eyes companion) is separate.

## Problem

#138 shipped the disposition file format + `disposition_gate.sh` (the deterministic structural gate), but
**nothing calls them** — the live ship-change gate is still stateless and raw-HIGH-count, so it re-litigates
already-fixed/refuted/deferred findings and never converges on a broad change (the #132 saga). #139 turns the
gate on: the merge-gate reviewer becomes **disposition-aware** — it sees the prior findings + the author's
dispositions and surfaces a HIGH only when it is genuinely new or a prior disposition is invalid.

## Approach

### Disposition state is PR-LOCAL, never committed (F1)

A committed repo-root file would **merge to `main`** and then presence-gate every future PR into stale
disposition-mode. So disposition state is **PR-scoped state that `wf.sh` manages, not a tracked file**: it
lives at a wf.sh-owned path keyed to the branch (under the worktree's `.git/`, e.g.
`.git/wf-dispositions.json`), is passed to the reviewer via `DISPOSITION_FILE`, and is **mirrored into a PR
comment** for human visibility. It is never added to the git tree, so it cannot reach `main` or leak into a
sibling PR. **Activation = presence of this PR-local state**; absent → today's stateless review. The research
audits (`--design`/`--data`/close) never set it and are **untouched**.

### Two decoupled mechanisms (F2): the structural gate validates the FILE; the reviewer suppresses

The earlier draft conflated them. They are independent:

- **Structural gate (#138), deterministic.** `wf.sh` feeds the gate the disposition file's **own HIGH-severity
  entries** as the findings list (`<entry-id> HIGH`). The gate then validates each such entry is structurally
  sound (allowed status; `deferred_*` has its link; `fixed` cites an in-PR SHA; non-empty `description`) and
  **blocks on any `unresolved`**. This needs no cross-round or ephemeral-reviewer IDs — the ids are internal
  to the file and consistent within it. It is the deterministic backstop that the dispositions the model
  trusts are well-formed.
- **Disposition-aware reviewer, semantic.** Shown the file (each entry's `description` + disposition) the
  reviewer **suppresses any finding that substantively matches a validly-dispositioned prior one** and
  surfaces only genuinely-new or invalid-disposition HIGHs (the prototype-validated approach; models match by
  substance, which is what they are good at). The merge gate blocks on this residual HIGH count.

So `description` is **load-bearing and required** (F3): the gate validates it is present and non-empty; the
reviewer matches on it. The disposition state is **cumulative** across rounds (entries accrue with their
dispositions).

### The pieces

1. **`audit_experiment.sh` (verify-claims) — disposition-aware prompt.** When `DISPOSITION_FILE` is set (and
   readable) for a `--scaffold`/`--code` review, prepend the **validated v2 framing** to the existing
   dimensional prompt: the declared altitude, the per-mode deferral rule (design: defer-to-child legitimate
   iff no ready/authorized dependent; code: a defect in the diff is never deferrable), the instruction to
   judge each disposition on the merits and suppress validly-dispositioned findings (matching on
   `description`), and the prior findings+dispositions themselves. `DISPOSITION_FILE` unset → prompt unchanged
   (research audits and no-file ship-change reviews behave exactly as today). The dimensional review still
   runs underneath — the reviewer stays sharp for *new* issues; it just stops re-raising resolved ones.

2. **`wf.sh` (aar-engineering) — PR-local state + merge-gate wiring.** `wf.sh` owns the PR-local disposition
   state (read/update at the `.git/`-scoped path, mirror to a PR comment). In the merge gate, when that state
   exists: (a) generate the findings list from its HIGH entries and run `disposition_gate.sh` (#138) as the
   deterministic fail-closed backstop; (b) export `DISPOSITION_FILE` for the cross-family review; (c) block on
   the reviewer's residual HIGH. No state → today's behavior.

3. **`disposition_gate.sh` (#138) — require `description` (F3).** Enhance the gate (and its smoke) to BLOCK a
   HIGH entry whose `description` is missing/empty — semantic matching depends on it. Small, additive change
   to the #138 script.

4. **Docs (F4) — the author workflow is discoverable.** Update `ship-change/SKILL.md` + `RUNBOOK.md` + help
   with the disposition author flow: when/how to record a disposition, the schema + statuses, and recovery
   (a malformed file fails closed). A zero-context agent must find the disposition path, not just the old
   fix/comment triage.

### The new triage step

Disposition-aware review adds one author action: during triage, instead of *only* fixing code, the author may
record a disposition (`fixed`/`refuted`/`deferred_*`) in `.aar-ci/dispositions.json`. This is the designed
flow from #137 ("the author records a machine-readable disposition per finding") and the writer side of the
loop the reviewer reads.

## Alternatives considered

- **Stable per-finding IDs / content fingerprints for cross-round identity.** Rejected for the MVP: brittle
  (models don't hash consistently) and unnecessary — the prototype proved semantic matching by the reviewer
  works. The deterministic backstop is the *file* validity (#138), not ID matching.
- **Replace the dimensional prompt entirely with the v2 prompt.** Rejected: augment, don't replace — keeping
  the dimensional review preserves the sharpness that catches *new* issues; the v2 framing rides on top to
  suppress resolved ones. (The fresh-eyes companion #140 further guarantees sharpness.)
- **Put disposition-awareness in `wf.sh` only (post-process the stateless review).** Rejected: the reviewer
  must *see* the dispositions to suppress at source; post-filtering can't judge a disposition's validity.
- **Make it the default for every review (no presence gate).** Rejected: presence-gating is a safe,
  reversible rollout and avoids forcing dispositions onto trivial first-round PRs.
- **Commit `.aar-ci/dispositions.json` to the branch.** Rejected (design review F1): a committed file merges
  to `main` and then stale-activates disposition-mode for every later PR. PR-local wf.sh-managed state (never
  in the tree) is the fix; human visibility comes from mirroring it into a PR comment.

## Blast radius

- **`verify-claims`** (`audit_experiment.sh`): an additive, env-gated prompt branch for `--scaffold`/`--code`.
  Unset `DISPOSITION_FILE` → byte-identical behavior. Version bump.
- **`aar-engineering`** (`wf.sh` + `disposition_gate.sh`): wf.sh manages the PR-local state, mirrors it to a
  PR comment, feeds the gate the file's HIGH entries, exports the env, blocks on residual HIGH; the gate gains
  a required-`description` check. No-state path unchanged. Version bump + a smoke for the wired path + the new
  gate case.
- **Docs**: `ship-change/SKILL.md` + `RUNBOOK.md` gain the disposition author workflow.
- **No change to the research-audit path** (`--design`/`--data`/close) — it never sets `DISPOSITION_FILE`.
- **PR-local state never enters the git tree** — no `main` pollution, no sibling-PR leakage.

## Rollout + rollback

Presence-gated, so **inert until a PR creates PR-local disposition state** — landing it changes nothing for
existing flows (no state = today's stateless review). Pilot on one real broad PR (the natural first user is #130's experiment-design PR, or a
future scaffold change that hits the convergence wall). Rollback is a normal revert of this PR; the no-file
path is the current behavior, so reverting is safe at any time. The fresh-eyes companion (#140) lands next to
guarantee the stateful gate never trusts a pre-existing hole past.
