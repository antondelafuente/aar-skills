# Proposal: the design-gate — code PRs can't close a `needs-design` issue (#50)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> **Two-phase design** — output is this doc + spawned `ready` issue(s).

## Problem

#74 established the disposition system and the two-phase engine (#75 `finish --design`), and stated the
Phase-2 contract: **code PRs close `ready` issues, never a `needs-design` issue directly** — a `needs-design`
issue is closed when its *design* lands, which spawns `ready` children. But **nothing enforces it.** Today a
`needs-design` issue can still be implemented directly: open a code PR with `Closes #<needs-design>`, and
`finish` merges it, skipping the design phase entirely. The disposition is advisory; the gate doesn't exist.

This is the "design review as a gate before implementation" #50 originally asked for — now reframed around the
two-phase shape #74 chose (the original #50 leaned one-phase; superseded).

## Approach

Add a **driver-side gate to `ship-change finish`** (code mode only — *not* `finish --design`): before
merging, look at which issues the PR would close and refuse if any is `needs-design`.

Mechanism:
1. **Determine the PR's closing issues** via `gh pr view <pr> --json closingIssuesReferences` — GitHub's own
   resolution of `Closes/Fixes #N` keywords + manually-linked closing issues (authoritative, no body-parsing).
2. **Read each closing issue's disposition label.**
3. **Block (fail closed) if any closing issue is `needs-design`**, with guidance: "a `needs-design` issue
   goes through two-phase design first (`finish --design`), which spawns `ready` children — close one of those
   (linked via `design: #<n>`), not the `needs-design` issue itself."
4. `finish --design` is exempt (a design PR *should* close its `needs-design` issue — that's how a
   `needs-design` issue closes). The gate lives only in the code path.

Load-bearing decisions:
- **Which dispositions block a code-PR close?** `needs-design` is the load-bearing one (the engine routes
  around it). Recommend also blocking `needs-shaping` / `blocked` / `parked` / `other` with the same
  "resolve/re-disposition it first" message — a code PR closing any of those is a smell (it should be `ready`
  first). **Allow `ready`** (the intended path) and **allow untriaged** (no disposition — a quick fix to an
  unlabeled issue shouldn't be blocked; the triage pass will catch un-triaged issues separately). Open to
  narrowing to *just* `needs-design` if the broader set proves noisy.
- **Hard block with a documented escape hatch.** This is Phase-2 "teeth" (#74), so it's a real block, not a
  warning — but with an env override (`WF_ALLOW_NONREADY_CLOSE=1`) for the rare legitimate exception, matching
  the existing `WF_OFFLINE` / `WF_REQUIRE_*` escape-hatch convention. The override is logged loudly.
- **Driver-side, no GitHub Action.** Reuses `gh` + the existing `finish` flow; consistent with #74's "no new
  CI infra" Phase-2 stance.
- **Fail closed on lookup failure.** If `closingIssuesReferences` can't be read (auth/API), block rather than
  merge blind — a gate that silently passes on error isn't a gate.

## Alternatives considered

- **A GitHub Action / required status check.** Deferred (#74 Phase 3): no Actions infra exists; the
  driver-side check matches the current trajectory and needs none.
- **Block in the classifier (advisory) instead of `finish` (blocking).** Rejected: the classifier records,
  never blocks; the whole point of #50 is a *gate*, so it belongs in `finish`'s fail-closed merge path.
- **Parse `Closes #N` from the PR body ourselves.** Rejected: `closingIssuesReferences` is GitHub's own
  authoritative resolution (handles keywords + manual links); re-parsing would drift.

## Blast radius

`aar-engineering` plugin only: a check added to `wf.sh finish`'s code path + the SKILL.md/usage note + a
`plugin.json` version bump. Additive — `finish --design` and any code PR that closes only `ready`/untriaged
issues are unaffected; the only new failure is a code PR trying to close a non-`ready` issue. SWE-pipeline
layer.

## Spawned issues (this design's `ready` decomposition)

1. **Implement the `finish` design-gate** (`ready`): the `closingIssuesReferences` lookup + the
   non-`ready`-disposition block + the `WF_ALLOW_NONREADY_CLOSE` override + fail-closed-on-lookup-failure, with
   SKILL.md/usage docs and a version bump. Carries `design: #50`.

(One unit; if review splits the "just needs-design" vs "all non-ready" scope, it may become two.)

## Rollout + rollback

Second two-phase design — dogfoods `finish --design` again. The spawned `ready` issue implements the gate via
a normal single-phase ship-change run. Rollback = revert that commit; the gate is purely additive (no existing
code PR that closes `ready`/untriaged issues changes behavior).
