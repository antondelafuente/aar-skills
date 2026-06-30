# 245 — log-experiment: consume the canonical aar-profile.toml [github] config

## Problem

`log-experiment` reads its GitHub config from parallel env vars it invented (`RESEARCH_REPO`, `LOG_EXPERIMENT_TOKEN_CMD_*`, `LOG_EXPERIMENT_GIT_AUTHOR_*` — introduced in #240, extended in #242). But the scaffold already has a **canonical** GitHub-lifecycle config home: `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.toml`, the `[github]` block documented in `run-experiment/references/SCHEMA.md` (`research_repo`, `base_branch`, and per-family `token_cmd_env` / `git_author_env`). The #242 `--scaffold` review flagged this as a DRY / canonical-home violation. Two config systems for the same facts is a divergence trap.

## Approach

Make `aar-profile.toml [github]` the **primary** source; the `LOG_EXPERIMENT_*` / `RESEARCH_REPO` env vars become **overrides** (a short-lived migration aid, taking precedence).

- Parse the TOML with `python3` (`tomllib`, `tomli` fallback) via a small `profile_get <dotted.key>` helper.
- `research_repo` and `base_branch` come from `[github]`.
- Identity uses the schema's **env-NAME indirection**: `[github.identity.<family>].token_cmd_env` / `git_author_env` name the env vars holding the actual mint command / `Name <email>` (so the profile stays non-secret and committable). `resolve_token_cmd` / `resolve_git_author` honor a `LOG_EXPERIMENT_*` override first, else read the profile-named env var.
- **All existing behavior preserved**: classify (DESIGN+RESULTS=experiment, else note, + `KIND`), the gates (experiment audit-presence; note secret scan, fail-closed on grep error), bots-do-writes (token-scoped push with `-c credential.helper=`; opposite-family approves; author can't approve own PR), `--match-head-commit` merge, origin==research_repo github.com check, sync-only-on-base-branch, `--dry-run`, fail-closed everywhere.

Instance setup: create `~/.config/experiment-lifecycle/aar-profile.toml` (research_repo=`antondelafuente/research-lab`, identity pointing at `AAR_RESEARCH_TOKEN_CMD_*` / `AAR_RESEARCH_GIT_AUTHOR_*` env vars set in the instance env).

## Alternatives considered

- **Keep the `LOG_EXPERIMENT_*` env approach** — rejected: it's the divergence the review flagged; the profile is the canonical home `run-experiment` already uses.
- **Drop the env overrides entirely** — rejected: keeping them as overrides makes the migration non-breaking.

## Blast radius

One script (`log-experiment.sh`) config resolution + its config docs (SKILL.md, header). No behavior change for a correctly-configured instance. The instance gains a profile file (instance config, not in the repo). Reversible (revert the PR → env-only). Fail-closed if the profile is missing AND no override is set.

## Rollout + rollback

ship-change PR. Instance preflight: write `aar-profile.toml` + set the `AAR_RESEARCH_*` env it references (done for this instance). The `LOG_EXPERIMENT_*` overrides keep any not-yet-migrated instance working. Rollback: revert the PR.

> Coordination: #244 (design-stage classification) edits the same file's classify/gate section in parallel; this PR edits the config-resolution + writes sections. Whoever merges second rebases (ship-change finish is fail-closed on a stale base).
