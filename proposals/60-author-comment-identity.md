# Proposal: author triage comments post under the author engineer identity (#60)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

On a ship-change PR, the **reviewer** side is correctly attributed to the opposite-family engineer bot:
`wf.sh` posts `--scaffold`/`--code` reviews and the classification via `engineer_token <opposite-family>`,
so they read as `claude-code-engineer[bot]` / `codex-engineer[bot]`. The **author triage** side is not.

The skill tells the author to respond to findings with a bare `gh pr comment`. Plain `gh` uses the ambient
token, which on this box is the human owner `antondelafuente` — so every author triage comment is
mis-attributed to the human PM instead of the authoring engineer. This breaks the "agents are the engineers"
model: the durable PR trail reads as if the human wrote the engineering responses.

Observed (flagged by Anton):
- **Claude-authored** PRs #58, #59 — "Design-review triage…" / "Code-review triage…" posted as
  `antondelafuente` (should be `claude-code-engineer[bot]`).
- **Codex-authored** PR #57 — reviews + classification correct (`claude-code-engineer[bot]`, opposite
  family), but the author response posted as `antondelafuente` (should be `codex-engineer[bot]`).

Symmetric, both author families. Root cause: there is no author-side equivalent of the reviewer-token
posting path — the author has no way to comment under their own engineer identity.

## Approach

Add a thin `comment` subcommand to `wf.sh`, reusing the machinery the author path already uses for `open`
and the push steps (`author_token_optional <author>` + `gh_author`):

```
wf.sh comment <worktree> <author> [body-file]    # body on stdin if body-file omitted or "-"
```

It resolves the **author family's** engineer token via the existing `author_token_optional` helper
(`WF_ENGINEER_TOKEN_CMD_CLAUDE`/`_CODEX`, the same seam reviews use), posts the PR comment under it, and
inherits that helper's policy exactly: **fail closed when `WF_REQUIRE_ENGINEER_IDENTITY=1`** (this box's
setting — so `comment` here always posts as the bot, never the owner), and on permissive installs warn +
fall back to ambient — identical to what `open`/`push`/`review` already do. (On this box the Claude engineer
identity is installed and wired, verified live: it authored issue #62 and reviewed PR #57. The RUNBOOK's
"claude-engineer not installed yet" line was stale and is corrected in this PR.) Then point the
`ship-change` SKILL.md triage instruction (and the `code-review` next-step note) at it instead of bare
`gh pr comment`.

Load-bearing decisions:
- **Reuse, don't reinvent.** `author_token_optional` already encodes the fail-closed/fallback policy and
  `gh_author` already runs `gh` under a token; the subcommand is a few lines on top, so author and reviewer
  attribution share one identity policy.
- **Body via file/stdin.** Triage comments are multi-line with backticks/`$`/`#`; `--body-file -` (stdin)
  preserves them untouched, same as the review/classify posts.
- **Skill change is the other half.** The bug is partly that the documented path *is* bare `gh pr comment`;
  fixing the tool without redirecting the instruction would leave the footgun in place.

## Alternatives considered

- **Just document "pass `GH_TOKEN=$(mint…) gh pr comment`" in the skill.** Rejected: leaks the token
  plumbing into prose every agent must get right by hand; the whole point of `wf.sh` is to encapsulate the
  identity policy in one place.
- **Auto-post triage from the driver (no manual step).** Rejected as out of scope: triage authoring is a
  judgment step the agent does between subcommands; this issue is only about *attribution* of the comment
  the agent already writes, not automating the triage itself.

## Blast radius

`aar-engineering` plugin only: one new `wf.sh` subcommand (additive — no existing subcommand changes), the
`code-review` next-step note, the `ship-change` SKILL.md triage instruction + the usage/lifecycle text, and a
`plugin.json` version bump. SWE-pipeline layer. No research-product or instance impact; existing PRs
unaffected.

## Rollout + rollback

Lands on main via this PR. Dogfooded immediately: this PR's own author triage responses are posted with the
new `wf.sh comment` (so the fix's own PR is the first to read as `claude-code-engineer[bot]` on the author
side). Unconfigured installs keep working (ambient fallback). Rollback = revert the additive commit; the
skill instruction reverts to `gh pr comment` with no other dependency.
