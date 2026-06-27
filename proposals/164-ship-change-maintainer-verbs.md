# Proposal: Narrow engineer maintainer verbs for `wf.sh issue` (#164)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The #149 design hardens agent GitHub writes by making the ambient `gh` credential read-only, so a bare
`gh issue close` / label-edit / body-edit fails closed. But two existing workflows legitimately need those
exact operations under the *engineer* identity, not the owner: `triage-feedback` closes duplicate Issues and
edits disposition labels, and the `blocked` disposition carries a `blocked-by: #N` **body** line. Today the
only engineer-identity Issue path — `wf.sh issue` — exposes just `create` and `comment` (deliberately
narrowed by #91, which rejected arbitrary-arg passthrough because it "permits destructive/interactive
operations"). So once the #149 guard lands, those maintenance operations would be stranded: no bare `gh`
(blocked), and no engineer-path replacement.

This child is the **blocking predecessor** of the guard. It must merge first, so the guard never blocks an
operation that has no engineer-identity replacement yet.

## Approach

Add three narrow, per-verb-allowlisted maintainer verbs to `wf.sh issue`, each authored through the existing
engineer-token path (`gh_author`), each with a **fixed validated argument set and no arbitrary-arg
passthrough** — preserving the #91 hardening model exactly so the destructive/interactive surface stays
closed:

- **`wf.sh issue <fam> close <N> -R <repo> [-c <comment>] [-r <reason>]`** — closes an Issue as the engineer.
  Allowlisted flags only (`-R/--repo`, `-c/--comment`, `-r/--reason`); `-r` validated against gh's fixed
  reason set (`completed`/`not planned`). gh exposes **no native `duplicate` close reason**, so a duplicate
  close is represented the way `triage-feedback` already does it — a `-c` comment that points at the canonical
  Issue plus a `not planned` close — not a separate reason value. (The structured duplicate signal is the
  comment, which is durable and human-readable, not a reason enum gh doesn't have.)
- **`wf.sh issue <fam> label <N> -R <repo> [--add-label L]… [--remove-label L]…`** — edits labels as the
  engineer. Only `-R`, `--add-label`, `--remove-label` are accepted (repeatable); each takes a value. No
  `--milestone`, `--add-assignee`, `--add-project`, or other `gh issue edit` mutations leak in.
- **`wf.sh issue <fam> dispose <N> -R <repo> --label L --body-line "blocked-by: #M"`** — the atomic
  disposition path the `blocked` vocab needs: it sets exactly one disposition label *and* appends/updates a
  single body line in one engineer-authored call. `--label` takes one disposition label; `--body-line` takes
  one line of text that is **appended** to the Issue body (idempotently — re-running with the same key
  replaces rather than duplicates), never an arbitrary full-body overwrite. This is the required body-set
  path: a `blocked` Issue carries `blocked-by: #N` in its body, so the engineer path must set a body line, not
  just labels.

All three reuse the same allowlist discipline already in the `create`/`comment` path: a stateful flag scan
that permits only the named flags (each consuming its value) and fails closed on every other `-`-prefixed
token, so short forms, `=`-forms, bundled flags, and future interactive flags are all rejected at once. The
verb allowlist is extended from `create|comment` to `create|comment|close|label|dispose`; anything else still
dies. There is **no** `gh issue edit --body` (full-body overwrite) and **no** generic passthrough — only the
three structured mutations above.

`pr review` / `pr merge` already run through the engineer token inside `finish` and the review path (verified
in `wf.sh`: the merge does `gh_author "$ATOK" … pr merge`; the review-post and PR-comment paths use the
engineer token directly via `GH_TOKEN="$rtok" gh …` rather than the `gh_author` wrapper, but they are still
engineer-authored). This child **confirms** that — it adds nothing there. Funnelling *every* internal `gh`
call site through one marked helper (so a PATH guard can recognize them) is explicitly the #149 guard child's
(child #1) job, not this one's.

**Degradation when `aar-engineering` is absent.** `triage-feedback` is designed to maintain Issues even
without the engineer path. The docs define the degradation explicitly: with no engineer maintainer verb
available, `triage-feedback` **degrades to drafting the mutation** (the human/owner applies it), never a bare
owner `gh` write. It never re-opens the owner-write path the #149 guard closes.

**Per-verb `.aar-ci` smoke.** A self-contained `issue_verbs_smoke.sh` (fake `gh`, throwaway repo, no network /
real tokens — the established smoke pattern) asserts each verb routes through the engineer token, that the
allowlist rejects a disallowed flag (e.g. `--web`, `--milestone`) and a disallowed subcommand, and that
`dispose` sets both a label and a body line. It is wired into `.aar-ci/checks.sh` on a `wf.sh` change like the
existing identity / fd_state smokes.

## Alternatives considered

- **A single generic `wf.sh issue edit` with full `gh issue edit` passthrough.** Rejected — that is exactly
  what #91 closed (arbitrary args permit destructive/interactive ops). Narrow per-verb allowlists keep the
  hardened surface.
- **A generic `--body-line` on a free-form `edit` verb instead of a dedicated `dispose`.** A standalone
  `edit --body-line` would also satisfy the contract, but coupling label + body into one atomic `dispose`
  matches the actual `blocked` workflow (set label and `blocked-by:` together, no half-applied state) and
  keeps the body-mutation surface to a single appended line rather than a general body editor.
- **Let `triage-feedback` keep using bare `gh` under an owner token when the engineer path is absent.**
  Rejected — that re-opens the owner-write path #149 closes. The defined degradation is *drafting*, not an
  owner write.

## Blast radius

- **Product surface:** `wf.sh`'s `issue` subcommand gains three verbs + their arg-allowlist logic; one new
  `issue_verbs_smoke.sh`; a wiring line in `.aar-ci/checks.sh`; `aar-engineering` plugin version bump.
  `triage-feedback` / `file-feedback` SKILL docs updated to call the engineer verbs and state the degradation;
  `feedback-loop` plugin version bump.
- **No change** to the engineer-token implementation (`gh_author` / `WF_ENGINEER_TOKEN_CMD_*`) — reused as-is.
  No change to `pr review`/`pr merge` (already engineer-pathed).
- **Not the guard.** This child adds only the engineer-identity *replacements*; the #149 guard that blocks
  bare `gh` writes is child #1 and lands after this.

## Rollout + rollback

- Merges as a normal single-phase ship-change run. It is purely additive (new verbs, new smoke, doc edits);
  no existing `wf.sh issue create|comment` behavior changes, so nothing regresses for current callers.
- Rollback is a one-commit revert (the squash merge), reversible with no data/credential migration.
- This is the **blocking predecessor**: the #149 guard child (child #1) must not merge until this is on main.
