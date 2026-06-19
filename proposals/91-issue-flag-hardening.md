# Proposal: harden the wf.sh issue flag allowlist (#91)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh issue <fam> create|comment` (#89) allowlists the **subcommand** but forwards the rest of the args to
`gh issue` unchecked. Under the engineer token, that still permits destructive/interactive operations the
wrapper claims to block: `gh issue comment <N> --delete-last --yes` (deletes a comment), `--edit-last`
(edits one), and `create|comment --web` (browser/interactive auth). Flagged MED [security] on the final
`--code` review of PR #90 (landed non-blocking).

## Approach

**Contract:** the authoring path accepts only non-interactive title/body/label inputs; it rejects every
INTERACTIVE form (`--web`/`-w` browser, `--editor`/`-e` editor) and DESTRUCTIVE form (`--delete-last`,
`--edit-last`) that `gh issue create|comment` expose — **both long and short spellings**. A flag denylist
on the full arg vector (after the subcommand allowlist) enforces this, failing closed with a clear message.
A *missing* `-b/-t` makes `gh` prompt interactively, which fails closed on this no-tty exec path — a usage
error, not an action, so it needs no separate guard. Keeping it a targeted denylist (not a full positive
parse of every benign flag) matches the actual risk without making the wrapper brittle to `gh` flag
additions like `-a/--assignee` or `-m/--milestone`.

## Alternatives considered

- **Strict positive parse** — require `-b/--body`/`--body-file` and forbid everything else. Rejected:
  brittle (breaks on every benign `gh` flag, e.g. `-a/--assignee`, `-m/--milestone`, `--body-file -`) for
  no extra safety over denying the known-dangerous flags.
- **Leave it (token scope limits blast radius).** Rejected: the wrapper advertises create/comment-only;
  letting `--delete-last` through under the bot token contradicts that, and a typo shouldn't delete.

## Blast radius

- One hunk in `wf.sh`'s `issue` arm + the `aar-engineering` `plugin.json` version bump. Additive guard; no
  other code path. `gh-as-engineer` (which now delegates here) inherits the protection for free.

## Rollout + rollback

- Pure guard; rollback is deleting the denylist check. No state, no migration.
