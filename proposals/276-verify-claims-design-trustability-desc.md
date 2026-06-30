# 276 — verify-claims plugin.json: --design is DATA-TRUSTABILITY, not LOGIC (post-#273)

## Problem

#273 reshaped `audit_experiment --design` from an interpretation/LOGIC audit to a DATA-TRUSTABILITY audit, and updated
the verify-claims SKILL body + the script + the experiment-lifecycle descriptions accordingly. One discovery-surface
string was missed: the `verify-claims` `.claude-plugin/plugin.json` **description** still advertises
`audit_experiment --design (the design's LOGIC)`. Discovery surfaces (the marketplace listing, plugin search) now show a
contract that contradicts the shipped behavior.

## Approach

One-line description fix: `audit_experiment --design (the design's LOGIC)` → `audit_experiment --design (the design's
DATA-TRUSTABILITY)`, plus the required `verify-claims` `plugin.json` version bump (0.7.8 → 0.7.9). Mirrors exactly what
#273 did to the verify-claims SKILL body (which now reads DATA-TRUSTABILITY).

The high-level `facts→logic→data→evidence` mnemonic in the same description is **left intact** — it's the memorable
4-rung ladder used repo-wide (including the verify-claims SKILL.md, unchanged by #273); "logic" loosely names the
design-reasoning rung, while the parenthetical is the precise per-rung description. Changing the mnemonic here but not in
the SKILL would introduce a fresh inconsistency; keeping the fix to the parenthetical matches #273's own choice.

## Alternatives considered

- **Also rewrite the `facts→logic→data→evidence` mnemonic** — rejected: out of scope, and it's consistent with the
  SKILL.md ladder #273 deliberately left; a partial rename would create new drift.

## Blast radius

One file, one plugin: `verify-claims/.claude-plugin/plugin.json` (description string + version bump). No code/behavior
change — metadata only. Reversible (revert the PR).

## Rollout + rollback

Ship via ship-change. Rollback: revert the PR.
