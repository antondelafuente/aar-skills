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
2. **Read each closing issue's disposition labels** and apply the policy below.
3. **Insertion point (review HIGH):** the check runs in `finish`'s code path **after** the PR/body sync +
   closing-issue resolution but **before** the `run_review … approving=1` native APPROVE. This is load-bearing:
   the native APPROVE satisfies branch protection, so a gate placed *after* it would leave a non-`ready` PR
   approved and manually mergeable. The gate must veto *before* any approval is posted.
4. `finish --design` is **exempt** (a design PR *should* close its `needs-design` issue — that's how a
   `needs-design` issue closes). The gate lives only in the code (`finish`) path.

The policy:
- **Exactly-`ready` close set.** For each closing issue, take its disposition labels (intersect with the
  six-label set) and require **`== {ready}`** — exactly the one `ready` label. **Fail closed on zero
  dispositions (untriaged) OR two-or-more** (a naive "contains `ready`" would wrongly pass an invariant-violating
  issue labelled both `ready` and `needs-design`). This blocks `needs-design`, untriaged, and malformed
  multi-label issues in one rule, matching AGENTS.md's "code PRs close `ready` Issues."
- **Require ≥1 closing issue for code-mode `finish`.** The ship-change lifecycle starts from an Issue and
  `open` auto-renders `Closes #N`, so a normal code PR *always* has a closing issue; a **zero-close** code
  finish is the anomaly → block (use the override). (This is stricter than an earlier draft that allowed
  zero-closes; the review correctly noted that allowance was itself a bypass.)
- **Block message** points at the two-phase path: "a `needs-design` issue goes through `finish --design`,
  which spawns `ready` children — close a `ready` child (linked `design: #<n>`), not the parent; for any other
  non-`ready` close, triage it to `ready` first."
- **Escape hatch with a durable trail (review).** `WF_ALLOW_NONREADY_CLOSE=1` allows the rare exception — but
  it must **post a PR comment** (engineer identity) recording that the gate was overridden and the offending
  issue list, *before* the approve/merge. Terminal-only logging is not enough: the durable GitHub trail would
  otherwise show an ordinary approved merge and hide the override.

Other decisions:
- **Permissions — verified, no migration needed.** Reading a closing issue's labels was empirically confirmed
  to work under the engineer Apps' *existing* `contents`+`pull_requests` permissions, because `aar-skills` is a
  **public** repo (tested: REST `issues/49` and the GraphQL `closingIssuesReferences`+labels on a live PR both
  returned labels under the engineer token). *Portability note:* a private install would need `issues: read`
  added to the Apps — documented, not required here.
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
- **Denylist (block only `needs-design`).** Rejected: leaves an untriaged bypass — a code PR could close an
  unlabeled issue and skip the disposition discipline entirely. The exactly-`{ready}` allowlist closes that.
- **Allow zero-close code PRs.** Rejected (review): within ship-change, `open` auto-renders `Closes #N`, so a
  code PR always has a closing issue; allowing zero-closes is itself a bypass. Code-mode `finish` requires ≥1
  closing issue (override for the rare genuine exception).
- **Naive "contains `ready`" check.** Rejected (review): an invariant-violating issue labelled both `ready`
  and `needs-design` would pass. The check is `disposition_labels == {ready}`, fail-closed on zero or multiple.

## Blast radius

`aar-engineering` plugin only: a check added to `wf.sh finish`'s code path + the SKILL.md/usage note + a
`plugin.json` version bump. Additive — `finish --design`, and any code PR that closes ≥1 `ready` issue (the
normal lifecycle path), are unaffected. New failures: a code PR closing a non-`ready` (or untriaged, or
multi-disposition) issue, or closing zero issues. SWE-pipeline layer.

## Spawned issues (this design's `ready` decomposition)

1. **Implement the `finish` design-gate** (`ready`, `design: #50`): in `finish`'s code path,
   **after PR/body sync, before the `run_review … approving=1` native APPROVE**, read the PR's
   `closingIssuesReferences` + each closing issue's disposition labels and enforce:
   - **≥1 closing issue** (zero → block);
   - **each closing issue's `disposition_labels == {ready}`** (fail closed on zero/untriaged or multiple);
   - `WF_ALLOW_NONREADY_CLOSE=1` override that **posts a PR comment** (engineer identity) recording the
     override + offending issues before approve/merge;
   - fail-closed on lookup error.
   Block message points at the two-phase path. Plus SKILL.md/usage docs + version bump.

(One unit — the policy is settled, so it's a single stable contract.)

## Rollout + rollback

Second two-phase design — dogfoods `finish --design` again. The spawned `ready` issue implements the gate via
a normal single-phase ship-change run. Rollback = revert that commit; the gate is purely additive (no existing
code PR that closes `ready`/untriaged issues changes behavior).
