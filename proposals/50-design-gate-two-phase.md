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
1. **Determine the PR's closing issues** via `gh pr view <pr> --json closingIssuesReferences` (or the GraphQL
   field) — GitHub's own resolution of `Closes/Fixes #N` keywords + manually-linked closing issues
   (authoritative, no body-parsing).
2. **Read each closing issue's disposition label** and apply the policy below.
3. `finish --design` is **exempt** (a design PR *should* close its `needs-design` issue — that's how a
   `needs-design` issue closes). The gate lives only in the code (`finish`) path.

The policy (single rule — F2):
- **Every issue a code PR would close must be labelled `ready`.** An allowlist, not a `needs-design`-only
  denylist: this blocks the load-bearing `needs-design` case *and* closes the untriaged bypass (F3) in one
  rule, and matches AGENTS.md's "code PRs close `ready` Issues." A PR that closes **zero** issues is allowed
  (the gate only fires on closing-issue links — not every refactor links an issue; we don't *mandate* a
  linkage, we constrain the ones present). Block message points at the two-phase path: "a `needs-design` issue
  goes through `finish --design`, which spawns `ready` children — close a `ready` child (linked `design: #<n>`),
  not the parent; for any other non-`ready` close, triage it to `ready` first."
- **Hard block + documented escape hatch.** Phase-2 "teeth" (#74) — a real block, not a warning — with
  `WF_ALLOW_NONREADY_CLOSE=1` for the rare legitimate exception (logged loudly), matching the existing
  `WF_OFFLINE` / `WF_REQUIRE_*` convention.

Other decisions:
- **Permissions — verified, no migration needed (F1).** Reading a closing issue's labels was empirically
  confirmed to work under the engineer Apps' *existing* `contents`+`pull_requests` permissions, because
  `aar-skills` is a **public** repo (tested: REST `issues/49` and the GraphQL `closingIssuesReferences`+labels
  on a live PR both returned labels under the engineer token). *Portability note:* a private install would
  need `issues: read` added to the Apps — documented, not required here.
- **Driver-side, no GitHub Action.** Reuses `gh` + the existing `finish` flow; consistent with #74's "no new
  CI infra" Phase-2 stance.
- **Fail closed on lookup failure.** If the closing-issues lookup errors (transient API/auth), block rather
  than merge blind — a gate that silently passes on error isn't a gate. (With permissions verified above, this
  only guards rare transient failures, not a standing permission gap, so it won't brick normal merges.)

## Alternatives considered

- **A GitHub Action / required status check.** Deferred (#74 Phase 3): no Actions infra exists; the
  driver-side check matches the current trajectory and needs none.
- **Block in the classifier (advisory) instead of `finish` (blocking).** Rejected: the classifier records,
  never blocks; the whole point of #50 is a *gate*, so it belongs in `finish`'s fail-closed merge path.
- **Parse `Closes #N` from the PR body ourselves.** Rejected: `closingIssuesReferences` is GitHub's own
  authoritative resolution (handles keywords + manual links); re-parsing would drift.
- **Denylist (block only `needs-design`).** Rejected (F3): leaves an untriaged bypass — a code PR could close
  an unlabeled issue and skip the disposition discipline entirely. The allowlist closes that hole.
- **Mandate that every code PR close ≥1 `ready` issue.** Rejected (too strict): legitimate PRs close zero
  issues (a pure refactor, the design PRs themselves). We constrain the closes that *are* present, not require
  one.

## Blast radius

`aar-engineering` plugin only: a check added to `wf.sh finish`'s code path + the SKILL.md/usage note + a
`plugin.json` version bump. Additive — `finish --design`, and any code PR that closes only `ready` issues (or
closes none), are unaffected; the only new failure is a code PR closing a non-`ready` issue (incl. untriaged).
SWE-pipeline layer.

## Spawned issues (this design's `ready` decomposition)

1. **Implement the `finish` design-gate** (`ready`, `design: #50`): in `finish`'s code path, read the PR's
   `closingIssuesReferences` + their disposition labels; **block unless every closing issue is `ready`** (allow
   zero closes); `WF_ALLOW_NONREADY_CLOSE=1` override (logged); fail-closed on lookup error. Block message
   points at the two-phase path. Plus SKILL.md/usage docs + version bump.

(One unit — the policy is settled, so it's a single stable contract.)

## Rollout + rollback

Second two-phase design — dogfoods `finish --design` again. The spawned `ready` issue implements the gate via
a normal single-phase ship-change run. Rollback = revert that commit; the gate is purely additive (no existing
code PR that closes `ready`/untriaged issues changes behavior).
