# log-experiment — log an experiment or note to GitHub as a gated PR

The **research** counterpart to `ship-change`: where `ship-change` ships a code change to the product,
this logs a **research record** (a finished experiment, or a plain note) to the research repo as a
**gated pull request**, and merges it. It exists so that "log this experiment to GitHub" is a written,
runnable workflow — not tribal knowledge an operator carries in their head.

It belongs to the **research product** (`automated-researcher`), owns its own GitHub-lifecycle glue, and
does **not** source `wf.sh`. (Why here: logging/auditing experiments is a research-product feature — see
`~/AGENTS.md` "The vision".)

## When to use

- A `run-experiment` execution finished and its registry dir (`DESIGN.md`/`RESULTS.md`/`AUDIT.md`/…) should
  land in the research repo.
- A note/record (meeting notes, a gotcha, serving infra, a knowledge ingest) should land.
- Anywhere you would otherwise hand-run "branch → PR → mint bot token → approve-as-bot → merge."

## How

```bash
scripts/log-experiment.sh <registry-dir> [--dry-run]
```

That one command does everything: classify → gate → branch (in a dedicated worktree) → PR → cross-family
bot approval → squash-merge → sync local `main`. `--dry-run` classifies and gates, then stops before any push.

The driver **classifies by the registry convention** (no label needed):

| the dir has… | classified as | gate |
|---|---|---|
| `DESIGN.md` **and** `RESULTS.md` | **experiment** | verify the close-audit is present + clean |
| anything else | **note** | deterministic secret scan |

A `KIND` file in the dir (containing `experiment` or `note`) is honored as an explicit override.

## The gates (fail-closed — an unparseable verdict BLOCKS, never passes)

- **Experiment.** The close-audit already ran during `run-experiment`; this **verifies it was triaged**, it
  does not re-run or re-derive the science. BLOCK unless **both** `AUDIT.md` and `AUDIT_RESPONSE.md` are
  present with no unresolved-HIGH marker. (A machine-readable close-triage contract is a future hardening;
  today the gate confirms the audit ran + was triaged, with a backstop scan.) An eval-only / anchor-failed
  run with no close-audit is allowed **only** if `RESULTS.md` records a closed decision (e.g. `ANCHOR_FAILED`,
  no-go); otherwise it BLOCKS and you surface it to the researcher.
- **Note.** A note has nothing to adversarially audit, so there is **no LLM review** — only a deterministic
  scan for secret-value patterns (`ghp_…`, `github_pat_…`, `sk-…`, `AKIA…`, PEM private keys). A hit BLOCKS.

A BLOCK prints the reason; fix the record (add the missing audit, remove the secret) and re-run, or surface
to the researcher if it needs a human call.

## Identity / auth

The author can't approve their own PR, so a **cross-family engineer bot — the family OPPOSITE the author**
(`LOG_EXPERIMENT_AUTHOR_FAMILY`) — posts the approving review that satisfies the research repo's branch
protection, using the same engineer identities `ship-change` uses. Author push/PR/merge use ambient `gh`:
the researcher logging to their *own* lab is the legitimate author; the cross-family bot is the independent
reviewer. The reviewer token is minted just-in-time, fail-closed (no token → BLOCK before any mutation), and
never printed.

## Config (instance, env-overridable — never hardcode an instance; fails closed if unset)

- `RESEARCH_REPO` — the research repo (`owner/repo`). **Required — no default target.**
- `LOG_EXPERIMENT_AUTHOR_FAMILY` — `claude`|`codex` (default `claude`). The reviewer is the **opposite** family.
- `LOG_EXPERIMENT_REVIEWER_TOKEN_CMD` — *optional* override: a command printing a repo-scoped bot token
  (receives `<owner/repo>`). By default the opposite-family token command is derived from the instance
  engineer seam (`WF_ENGINEER_TOKEN_CMD_<family>`), so no new config is required on a box that already runs
  ship-change.

## Composes

- **`run-experiment`** — produces the registry record this logs (and runs the close-audit the experiment
  gate verifies).
- **gh** — PR create / review / merge.
- The research repo's per-dir `.gitignore` keeps large artifacts on R2; `git add` honors it, so only the
  lightweight record lands.

## Worked reference

The by-hand sequence this automates was run on 2026-06-29: records (PRs #21/#22, secret-scan path) and
experiments (PRs #16/#18/#19/#20, verify-audit path) in `antondelafuente/research-lab`.
