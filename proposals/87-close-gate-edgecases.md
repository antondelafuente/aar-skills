# Proposal: close-gate edge cases — cross-repo refs + defensive zero-close (#87)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Two residual findings from the #85 close-gate code review (both 0-HIGH, narrow edge cases, no normal-path
impact):

1. **Cross-repo closing references.** `closingIssuesReferences` can include issues in *other* repositories;
   `disposition_gate` reads labels at `repos/<this-repo>/issues/<N>` by number alone, so a cross-repo close
   would have labels checked on the wrong (this-repo) `#N`.
2. **Fragile zero-close handling.** `closing=$(… | grep -v '^MORE:')` exits nonzero when a PR closes zero
   issues (grep matches nothing) — benign today (wf.sh isn't `set -e`) but a latent foot-gun.

## Approach

- **Cross-repo (1):** extend the GraphQL to fetch `repository{nameWithOwner}` per closing node, and emit
  `"<number> <nameWithOwner>"` per line. A closing ref whose repo ≠ the current repo **fails closed** (review
  F1): a PR here must not close an issue in another repo as an *unchecked side effect*; the fix is to drop the
  `Closes/Fixes` keyword for cross-repo refs (a plain mention is fine), or use the override. The slug
  comparison is **case-insensitive** (review F2 — `gh_repo`'s URL-derived slug vs GitHub's canonical
  `nameWithOwner` can differ in casing; both are lowercased before comparing).
- **Zero-close (2):** drop the separate `grep -v '^MORE:'` line entirely; the loop now skips the `MORE:`
  marker line inline (`case "$n" in MORE:*) continue`). No fragile grep, so nothing to fail on zero closes —
  the existing `count=0` block message fires.

No policy change — same exactly-`{ready}` / exactly-one-`{needs-design}` contract, same override, same
fail-closed-on-lookup-error. This only hardens *which* issues the gate inspects.

## Alternatives considered

- **Silently skip cross-repo refs** (the first draft). Rejected (review F1): skipping lets a PR close an
  external issue as an unchecked side effect. Fail closed instead — the gate's guarantee is "every issue this
  PR closes is valid for this workflow," not "only the same-repo ones are checked."
- **Read labels from the referenced issue's actual repo.** Rejected: the contract is about *this* tracker's
  dispositions; reaching into another repo's labels widens scope + permissions for no benefit.
- **Add `|| true` to the existing grep.** Works, but removing the grep (skip `MORE:` in-loop) is simpler and
  eliminates the fragile construct rather than patching it.

## Blast radius

`aar-engineering` `wf.sh` (`disposition_gate` only) + `plugin.json` bump. No behavior change on the normal
path (same-repo single-issue closes); the only differences are cross-repo closes now correctly ignored and
zero-close handled cleanly. SWE-pipeline layer.

## Rollout + rollback

Single-phase ship-change; **the first PR to pass through the now-live close-gate** (it closes #87, a `ready`
issue → satisfies the code-mode gate). Re-validated against real PRs before merge. Rollback = revert the
additive commit.
