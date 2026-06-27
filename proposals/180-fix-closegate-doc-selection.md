# Proposal: close-gate PR-body refresh mis-selects the closing-issue doc on mass-rename PRs (#180)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh finish` runs a best-effort PR-body refresh (step 0c, ~line 1336) so the durable PR body matches the
final committed design doc. It picks the closing-issue doc with `head -1` of the proposals/ diff:

    FDOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)

For an ordinary PR that touches one design doc this is fine. But a PR that MOVES many docs under `proposals/`
breaks it: `git diff --name-only` lists every moved doc, and `head -1` picks the lexically-first unrelated
one. Found in wave 1 on PR #174 (the `proposals/ -> designs/` rename for #65): `head -1` selected
`proposals/10-native-reviews.md`, the refresh rewrote the PR body to "Closes #10", and because #10 is not a
`ready` issue the close-gate then BLOCKED the merge. So a body-refresh meant to be cosmetic and best-effort
silently retargets the PR's closing reference and trips the close-gate — blocking #65 and any future
doc-moving PR.

## Approach

Make the FDOC selection pick the PR's OWN design doc rather than `head -1` of the diff. The branch encodes its
issue number (`change/<issue>-<slug>`); parse it and prefer the changed doc named for that issue
(`<issue>-*.md`). Fall back to the existing `head -1` of the changed docs only when no changed doc matches the
branch issue, so ordinary single-doc PRs keep today's behavior exactly.

    BRISSUE=$(printf '%s\n' "$BR" | sed -nE 's#^change/([0-9]+)-.*#\1#p')
    FDOC=""
    if [ -n "$BRISSUE" ]; then
      FDOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ \
               | grep -E "/${BRISSUE}-[^/]*\.md$" | head -1)
    fi
    [ -n "$FDOC" ] || FDOC=$(cd "$WT" && git diff --name-only "$(base_ref "$WT")"...HEAD -- proposals/ | head -1)

This is the minimal extraction of the corrected selection already present in PR #174 (which additionally
performs the `proposals/ -> designs/` rename, out of scope here). It scopes the directory to `proposals/`
only, since the rename is not yet live; #65 re-runs once this lands.

## Alternatives considered

- **Refresh the body for every changed doc / first-doc-only as today.** Rejected: the bug is precisely that
  the "first doc" is not the PR's doc on a multi-doc PR; any positional choice can mis-target.
- **Skip the body refresh entirely when the diff has >1 doc.** Rejected: a mass-rename PR still has a real
  owning doc worth rendering; skipping loses the (correct) refresh and is a coarser fix than selecting the
  right doc.
- **Derive the issue from the PR's `Closes #N` body instead of the branch.** Rejected: the body is the very
  thing being (re)written here and the close-gate reads GitHub's closing refs; the branch name is the stable,
  author-controlled source of the PR's own issue.

## Blast radius

SWE pipeline only — one selection in the `finish` body-refresh block of
`plugins/aar-engineering/skills/ship-change/scripts/wf.sh`. The refresh stays best-effort (a render/API
failure still only warns). No change to the close-gate, the merge review, checks, or any other path. For a
single-doc PR the selected doc is unchanged; only multi-doc PRs change behavior (from wrong to correct).

## Rollout + rollback

Ships through the normal ship-change lifecycle. Low risk: a pure refinement of a best-effort step. Rollback is
the one-command revert of the squash commit (RUNBOOK "One-command revert"). No data migration, no config, no
version-contract change beyond the plugin version bump the checks require.
