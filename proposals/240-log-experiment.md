# 240 — log-experiment: log research-lab experiments/notes to GitHub as gated PRs

## Problem

Logging a finished experiment to GitHub — as a gated PR in the research repo — is currently undocumented tribal knowledge. The steps (branch the registry dir, push, open a PR, mint a cross-family engineer-bot token, approve as the bot because the author can't approve their own PR, merge, sync local main) live only in an operator's head. A zero-context agent handed "log this experiment" cannot do it, and a researcher's finished experiments pile up unmerged behind a review nobody runs. This breaks the product's core promise: the workflow must live in the scaffold so any agent can run it.

The same gap forces every research-lab merge through one generic, hollow review (a bot rubber-stamp) — friction for notes, and not the real audit for experiments.

## Approach

Add a `log-experiment` skill + driver to the `experiment-lifecycle` plugin. Given a registry directory, it logs the dir to the research repo as a PR and merges it, choosing the gate by the directory's own content:

- **experiment** (the dir has `DESIGN.md` + `RESULTS.md`) → verify the registry record is present and its close-audit is clean (`AUDIT.md` exists and `AUDIT_RESPONSE.md` carries no unresolved HIGH). The close-audit already ran during `run-experiment`; the gate VERIFIES it, it does not re-run the science.
- **note** (anything else) → a deterministic secret scan (key/token VALUE patterns), then merge. No LLM review — there is nothing to adversarially audit in a note.

Classification follows the registry convention the records already use, so no author label is required (a `KIND:` line in the dir is honored as an explicit override). Cross-family engineer-bot approval satisfies the research repo's branch protection; the author can't approve their own PR, the bot does.

## Why here / self-contained (the boundary)

Per `~/AGENTS.md` "The vision", logging-and-auditing experiments is a **research-product feature** (the video-game test: a non-research product wouldn't have it). So the tool lives in `automated-researcher`, owns its own GitHub-lifecycle glue, and does **not** source the engineering layer's `wf.sh`. `ship-change` (engineering / code review) and `log-experiment` (research / experiment audit) are siblings that share a PR-lifecycle *shape* but are independently owned — per the settled boundary. The only cross-cutting invariant: every gate is fail-closed (an unparseable verdict blocks).

This **supersedes** the earlier #130/#150 "neutral shared GitHub-lifecycle helper" direction. That proposal called for extracting a shared lib so the research flow wouldn't fork the plumbing; the settled product boundary (self-contained products — `~/AGENTS.md`) replaces it. The small duplication of PR-lifecycle *shape* is the deliberate, accepted cost of self-containment (a stranger can clone the research product and run it without the engineering layer), not an oversight. To bound that cost, the only thing kept canonical is the fail-closed invariant — not a shared implementation.

## Interface

`log-experiment.sh <registry-dir> [--dry-run]` — classify → gate → branch → PR → approve (opposite-family bot) → merge → sync. Config via env (instance, **fail-closed — no instance defaults**): `RESEARCH_REPO` is **required**; `LOG_EXPERIMENT_AUTHOR_FAMILY` (`claude`|`codex`, default `claude`) selects the **opposite-family** reviewer, whose token command is derived from the instance engineer seam (`WF_ENGINEER_TOKEN_CMD_<family>`) or an explicit `LOG_EXPERIMENT_REVIEWER_TOKEN_CMD` override. Author push/PR/merge use ambient `gh` — the researcher logging to their own lab is the legitimate author; the cross-family bot is the independent reviewer. `--dry-run` classifies + gates and stops before any push.

## Gate detail (fail-closed)

- **experiment:** BLOCK unless **both** `AUDIT.md` and `AUDIT_RESPONSE.md` are present with no unresolved-HIGH marker. This **verifies the close-audit ran and was triaged** (during `run-experiment`, with the human in the loop); it does not re-derive triage. Today that is presence + a backstop scan; a **machine-readable close-triage contract** (so the gate can *prove* rather than scan) is a deliberate future hardening, tracked separately. An eval-only / anchor-failed run that legitimately has no close-audit is allowed only if `RESULTS.md` records a closed decision (e.g. `ANCHOR_FAILED`, no-go) — otherwise BLOCK and surface.
- **note:** BLOCK on any secret-value pattern hit (`ghp_…`, `github_pat_…`, `sk-…`, `AKIA…`, PEM private keys).
- Any parse failure / missing record → BLOCK (never a silent pass).

## Alternatives considered

- **Source `wf.sh`'s lifecycle** — rejected: research depending on the engineering layer (the #150 swamp); breaks `wf.sh` single-file relocatability.
- **Classify by path** (`registry/` = experiment) — rejected: notes legitimately live under `registry/` (e.g. `openwebui-*` serving infra), so path mislabels them.
- **Re-run the audit at merge** — rejected: redundant + expensive; the close-audit already ran in `run-experiment`.

## Blast radius

New skill + script only; no change to existing skills. Operates on the research repo (research-lab), not on automated-researcher itself. Reversible (revert the PR; the tool only adds a skill). Main risk: misclassification — mitigated by the explicit `KIND:` override and fail-closed gates.

## Rollout + rollback

Ship via ship-change. It then becomes the documented way to log an experiment. The by-hand sequence merged 2026-06-29 (records #21/#22; experiments #16/#18/#19/#20) is the worked reference the driver automates. Rollback: revert the PR — no existing flow depends on it yet.
