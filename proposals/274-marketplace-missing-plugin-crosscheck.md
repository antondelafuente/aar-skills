# Proposal: cross-check the CURRENT marketplace declarations on any missing plugin dir (#274)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The behavior-smoke stage of `.aar-ci/checks.sh` (step 6) decides whether an absent `plugins/<x>` dir
is a benign deletion or a broken marketplace. It only knows a plugin is *declared* by parsing
`.claude-plugin/marketplace.json` into `MP_DECLARED` — but today it parses that file **only when
marketplace.json is itself in the PR's changed paths**. So a PR that **deletes a plugin dir without
touching marketplace.json** leaves `MP_DECLARED` empty; the loop then hits the missing-dir branch,
finds the plugin not in the (empty) declared list, and reports `ok: plugin <x> removed (no smoke)` —
green — even though the marketplace **still declares** the now-missing plugin and discovery would break
at install time.

This is the exact hole #280 closed for the *marketplace-changed* path (a declared-but-missing plugin
must FAIL), but left open for the *marketplace-unchanged* path. Issue #274 asks to mirror that guard:
on **any** missing plugin dir, cross-check the **current** marketplace declarations regardless of
whether marketplace.json is in the changeset, and fail loud on a declared-but-missing plugin.

## Approach

Split the two distinct uses of the declared list that were conflated behind one `marketplace.json
changed` condition:

1. **Always** parse the CURRENT `marketplace.json` into `MP_DECLARED` (guarded by file existence),
   independent of the changeset. This is the authority the missing-dir cross-check consults, so the
   guard now fires whether or not the PR touched marketplace.json. Track parse success in
   `MP_PARSE_OK`.
2. **Only when marketplace.json itself changed** do we still fan `MP_DECLARED` into `SMOKE_PLUGS` to
   smoke every declared plugin (a marketplace edit can break discovery for any of them) — unchanged
   behavior. A parse failure on *that* path stays a hard `err` (we cannot know what to smoke).

The missing-dir branch is then fail-closed on three outcomes: (a) the plugin is in the current
declared list → `err` (declared-but-missing, discovery breaks); (b) the current marketplace could not
be parsed → `err` (cannot verify it isn't still declared); (c) otherwise → the benign
`ok: plugin <x> removed (no smoke)`. Note a *missing* marketplace.json file is not a parse failure —
`MP_DECLARED` is empty and `MP_PARSE_OK=1`, so a deletion in a repo with no marketplace stays benign.

The deleted plugin's paths are always in the changeset (deleting a plugin removes its files), so the
plugin name lands in `SMOKE_PLUGS` and the loop reaches the missing-dir branch — the fix needs no new
enumeration source, only the always-current declared list to check against.

## Alternatives considered

- **Re-derive declarations from a diff against the base ref** (what marketplace *used to* declare):
  rejected. The install-time authority is the marketplace as it will be on `main` after merge — the
  CURRENT file — not the historical one. #274 explicitly says "the CURRENT marketplace declarations."
- **Leave the parse gated on the changeset and only widen the loop condition**: rejected — the loop
  cannot cross-check a list it never populated; the parse itself is what must become unconditional.
- **Make a missing/unparsable marketplace.json a hard fail unconditionally**: rejected as scope creep.
  We only fail on a parse failure when it would actually change a missing-dir verdict (outcome b); a
  well-formed repo always parses, and an absent marketplace in a repo with no plugins stays benign.

## Blast radius

One file: `.aar-ci/checks.sh` (the automated-researcher tracked CI profile), step 6 only. It tightens a
green-when-it-should-fail hole; it cannot newly fail a currently-passing legitimate change (a real
plugin deletion also removes its marketplace declaration in the same PR, so the plugin is no longer in
`MP_DECLARED` and the branch stays benign). No skill/plugin/version-bump surface changes (checks.sh is
not inside a `plugins/<x>/` dir, so no plugin.json bump applies). SWE-pipeline CI only; no runtime
product behavior.

## Rollout + rollback

Immediate on merge — it is a CI check. Rollback is a one-file revert of this PR; no state or migration.
