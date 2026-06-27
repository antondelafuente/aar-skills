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

### Activation by presence (backward-compatible)

The disposition-aware path activates **only** when `.aar-ci/dispositions.json` is present in the branch.
No file → the current stateless review runs unchanged (a first review, or a small change, needs no
dispositions). The research audits (`--design`/`--data`/close, owned by #130) never set it, so they are
**untouched**. This makes #139 a safe, opt-in rollout.

### The finding-identity protocol — semantic matching (prototype-validated)

The crux of a stateful gate is reconciling "did the reviewer already raise this?" across rounds. #139 does
**not** require stable per-finding IDs or content fingerprints (which #138's round-4 review flagged as the
hard part). Instead it uses **semantic matching by the reviewer**, exactly as the in-session prototype
validated: each disposition entry carries a short `description`, the reviewer is shown the prior
findings-with-descriptions + their dispositions, and it suppresses any finding that *substantively* matches a
validly-dispositioned prior one. The model does the matching it is good at; the deterministic gate (#138)
guarantees the dispositions it trusts are well-formed.

So the disposition file is **cumulative** (findings accrue across rounds with their dispositions), and gains
one field over #138's schema: `description` (the finding's gist, for semantic matching).

### The two pieces

1. **`audit_experiment.sh` (verify-claims) — disposition-aware prompt.** When `DISPOSITION_FILE` is set (and
   readable) for a `--scaffold`/`--code` review, prepend the **validated v2 framing** to the existing
   dimensional prompt: the declared altitude, the per-mode deferral rule (design: defer-to-child legitimate
   iff no ready/authorized dependent; code: a defect in the diff is never deferrable), the instruction to
   judge each disposition on the merits and suppress validly-dispositioned findings, and the prior
   findings+dispositions themselves. `DISPOSITION_FILE` unset → prompt unchanged (research audits and
   no-file ship-change reviews behave exactly as today). The dimensional review still runs underneath — the
   reviewer stays sharp for *new* issues; it just stops re-raising resolved ones.

2. **`wf.sh` (aar-engineering) — merge-gate wiring.** In the merge gate, if `.aar-ci/dispositions.json`
   exists: (a) run `disposition_gate.sh` (the #138 structural gate) as a deterministic, fail-closed backstop
   on the file; (b) export `DISPOSITION_FILE` for the cross-family review; (c) block on the reviewer's
   residual HIGH (which, being disposition-aware, is the count of genuinely-unresolved findings). No file →
   today's behavior.

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

## Blast radius

- **`verify-claims`** (`audit_experiment.sh`): an additive, env-gated prompt branch for `--scaffold`/`--code`.
  Unset `DISPOSITION_FILE` → byte-identical behavior. Version bump.
- **`aar-engineering`** (`wf.sh`): merge-gate detects the file, runs the #138 gate, exports the env, blocks on
  residual HIGH. No-file path unchanged. Version bump + a smoke for the wired path.
- **No change to the research-audit path** (`--design`/`--data`/close) — it never sets `DISPOSITION_FILE`.
- Reuses #138's `disposition_gate.sh` as-is.

## Rollout + rollback

Presence-gated, so **inert until a PR adds `.aar-ci/dispositions.json`** — landing it changes nothing for
existing flows. Pilot on one real broad PR (the natural first user is #130's experiment-design PR, or a
future scaffold change that hits the convergence wall). Rollback is a normal revert of this PR; the no-file
path is the current behavior, so reverting is safe at any time. The fresh-eyes companion (#140) lands next to
guarantee the stateful gate never trusts a pre-existing hole past.
