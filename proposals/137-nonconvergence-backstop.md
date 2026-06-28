# Proposal: Non-convergence backstop for the disposition-aware merge gate (#137)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The disposition-aware merge gate (#137's shipped core: #138 structural gate, #139 reviewer prompts +
packet, #140 fresh-eyes sweep, #143 durable trusted list) solved the *amnesiac re-litigation* failure: the
cross-family reviewer no longer re-raises a finding the author has validly dispositioned. But it left one
failure mode of #137's original problem statement unhandled — and that mode is now live.

The merge-gate reviewer is deliberately told to "find the next thing", so it never self-converges. The
disposition system stops it re-raising *resolved* findings, but it does nothing about a PR that keeps
producing *genuinely new, adjacent* HIGHs round after round. Each such round is a legitimate finding, validly
dispositioned, and the PR still cannot merge — and there is no agent-side override (`enforce_admins` ON by
design). The lesson #137 itself drew from PR #132 ("HIGH counts 1->1->2->1->1->2, never reaching 0, each
round rediscovering an adjacent objection") is that this signature means the change is **under-scoped**: the
right move is to **re-split it into smaller children**, not to grind the same PR through review credits
forever.

Live evidence (post-#137): **PR #192** (#146's design) sits OPEN with **seven consecutive
CHANGES_REQUESTED** rounds — the exact non-convergence signature, now burning the scarce cross-family review
credits #137 was meant to conserve. The gate has no mechanism to recognize "this has iterated long enough
that the problem is scope, not this fix" and change its guidance accordingly.

## Approach

Add a **non-convergence backstop** to the disposition-aware `finish` merge gate: a deterministic round
counter that, once a PR has gone through N merge-gate review rounds and *still* produces a blocking HIGH,
**changes the gate's guidance from "fix and re-run" to "this PR appears under-scoped — re-split it"**, while
still blocking the merge (it never auto-merges). It is a louder, differently-worded block, not a different
gate: the human/author decides whether to re-split.

**Scope: this bounds the *merge-gate* review loop specifically.** That is the credit sink with no
human-judgment exit — `finish`'s final-SHA review re-runs every attempt, the merge is hard-blocked
(`enforce_admins` ON), and PR #192's seven CHANGES_REQUESTED rounds are exactly merge-gate review rounds.
Interim `code-review`/`design-review` are *author-initiated* and self-limiting (the author chooses whether
to spend another interim pass and can stop at any time), so they are deliberately **not** counted; bounding
them would be a different, larger change with no forcing function behind it. The backstop addresses the loop
that the author *cannot* exit by choice — the one the gate itself drives.

The load-bearing decisions:

1. **What a "round" is, and when it increments.** A round is *one completed merge-gate reviewer pass that
   STILL LEFT A BLOCKING HIGH* — the credit-spending unit that did **not** converge. A clean review (no
   residual HIGH) merges, so it is not a non-convergence round and never increments the counter; this keeps
   `round` an honest count of "rounds with a residual HIGH" (the field's contract). The `finish` merge gate
   already re-seeds the disposition state from its final review (the `fd_seed` + `fd_save` at the end of the
   disposition-aware branch). The counter increments there, and **only there** — not on `start`, not on
   interim `code-review`/`design-review`, not on a `finish` that failed before the merge review ran
   (structural-gate block, fresh-eyes failure, reviewer crash). So the count tracks real *blocking* reviewer
   passes, not `finish` invocations.

2. **Idempotent increment (no inflation, no undercount).** Re-running `finish` without a genuinely new
   reviewer *pass* must not inflate the count — but a real new pass on a changed commit must always count,
   *even when the same blocker survives* (the PR #192 case is precisely "same theme recurs across genuinely
   new commits", so a HIGH-id-set-only fingerprint would wrongly undercount it). The fingerprint is therefore
   **the reviewed SHA combined with the residual-HIGH id set** (`<reviewed-HEAD-sha>:<sorted HIGH ids>`,
   hashed). A new commit advances HEAD → new SHA → new fingerprint → the round increments. A bare `finish`
   re-run with no new commit and the identical review (same SHA, same HIGHs) reproduces the recorded
   fingerprint → no increment. This counts real reviewer passes and never double-counts an identical retry.

3. **The schema field.** A top-level integer `round` (default `0`, back-compatible: a pre-existing state
   with no `round` reads as `0`), a top-level `last_review_fingerprint` string, and a top-level
   `last_reviewed_sha` string (the HEAD the last counted round reviewed — read by the pre-review
   short-circuit in decision 4 to tell a bare retry from a new fix). All live alongside the existing
   `altitude` / `findings`. No per-finding field is added — total completed rounds with a residual HIGH is
   the right key for "under-scoped", and per-finding age would add machinery without changing the decision.

4. **The trip condition (two points).** The backstop fires at the *block*, in two places so it never wastes
   a review past threshold:
   - **Pre-review short-circuit.** Before spending the merge review, if `round >= N` **and** HEAD ==
     `last_reviewed_sha` (nothing committed since the last counted blocking round, i.e. a bare retry of the
     same loop), the gate blocks immediately with the under-scoped guidance and spends **no** review credit.
     A NEW commit since then (HEAD moved = a genuine fix attempt) falls through and is allowed one more
     review.
   - **Post-review trip.** After the merge-gate model review, if `REVIEW_HIGH > 0` **and** `round >= N`
     (default `N=4` — the initial review plus three convergence attempts; env-overridable
     `WF_NONCONVERGENCE_ROUNDS`), the gate emits the same distinct terminal `BLOCKED:` message.

   Both paths post a **one-time** PR comment (guarded by a hidden `<!-- wf:nonconvergence-backstop -->`
   marker so repeated tripped `finish` runs don't duplicate it) naming the backstop and recommending a
   re-split into smaller `ready`/`needs-design` children. Below the threshold, the existing "fix in the
   worktree + commit, re-run finish" block is unchanged.

5. **Still fail-closed, still blocks.** The backstop is purely additive on the *blocking* path — it only
   ever fires *because* HIGH>0 already blocks. It cannot cause a merge; it changes the guidance attached to
   a block. An author who genuinely believes the change is cohesive (a true false-positive loop) can raise
   `WF_NONCONVERGENCE_ROUNDS` for that run, exactly as `WF_REVIEW_TIMEOUT` is tunable — that is the explicit,
   logged escape hatch, not an override of the block.

The counter only exists on a disposition-aware PR (one that opted into the gate by having disposition
state). A stateless PR has no `round` and no backstop — consistent with the rest of #139/#140, which are
opt-in via the presence of disposition state.

## Alternatives considered

- **Hard-gate at N (refuse to ever run review again).** Rejected: the decision to re-split is a human/author
  judgment (a true cohesive change can have a genuine multi-round false-positive run), and a hard refusal
  removes the tunable escape hatch. The block already prevents the merge; the only thing left to decide is
  the *guidance*, so advisory-louder-block is the minimal correct change.

- **Count plain `finish` invocations (or `code-review` calls).** Rejected: inflates on retries that never
  ran a new review (a structural-gate block, a reviewer crash, an identical re-review) and would trip the
  backstop without N real review passes. Counting *completed, incorporated, fingerprint-distinct* merge
  reviews is the credit-accurate unit.

- **Per-finding `first_round` age + "a finding open for K rounds blocks differently".** Rejected as
  machinery without payoff: the under-scoped signal is the *stream of new HIGHs across rounds*, not the age
  of any one finding; total rounds-with-residual-HIGH captures it with one integer.

- **Auto-file the re-split children.** Out of scope: deciding the child decomposition is design work
  (the "together" stage), not something the gate should do mechanically. The backstop *recommends* and
  blocks; the human drives the split.

## Blast radius

SWE pipeline only (`ship-change` / `wf.sh` + the disposition state schema). Touches:

- `wf.sh`: the increment helper (carry `round` + `last_review_fingerprint` through a re-seed idempotently)
  and the `finish` disposition-aware branch to increment on the final review and evaluate the trip condition
  after the merge review.
- The disposition state JSON schema gains two optional top-level fields (`round`, `last_review_fingerprint`),
  fully back-compatible (absent => 0 / unset). The deterministic structural gate (`disposition_gate.sh`) is
  unchanged — it reads only `altitude` + `findings`, so the new fields are inert there.
- SKILL.md's disposition-aware-gate section: a sentence on the backstop. (No separate
  `references/DISPOSITIONS.md` change — that file is the issue-tracker disposition vocabulary, not the
  finding-disposition gate.)
- `plugins/aar-engineering/.claude-plugin/plugin.json`: the plugin **version bump** required by
  `.aar-ci/checks.sh` whenever a non-manifest plugin file changes (SKILL.md / wf.sh are in this plugin).
- No product-research-skill, instance, or GitHub-protection change. No change to the stateless path.
  Existing disposition smoke tests stay green; new behavior gets a focused smoke case.

## Rollout + rollback

- Low risk: additive on the already-blocking path, opt-in (disposition-aware PRs only), back-compatible
  schema. A PR that has never tripped the threshold behaves exactly as today.
- Escape hatch: `WF_NONCONVERGENCE_ROUNDS` (raise it, or set very high to effectively disable the backstop
  for a run that is a genuine false-positive loop). The block itself is unchanged and remains the safety
  property.
- Rollback: revert the one squash commit (standard `ship-change` revert). The schema fields are optional, so
  a rolled-back driver simply ignores any `round`/`last_review_fingerprint` already written to a PR comment.
