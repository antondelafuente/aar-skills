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

`log-experiment.sh <registry-dir> [--dry-run]` — classify → gate → branch → PR → approve (opposite-family bot) → merge → sync. Config via env (instance, **fail-closed — no instance defaults**): `RESEARCH_REPO` is **required** (and the input dir's `origin` must match it); `LOG_EXPERIMENT_AUTHOR_FAMILY` (defaults to `$AAR_SUBSTRATE`, fail-closed if unknown) selects the **opposite-family** reviewer; the reviewer token comes from the family-keyed `LOG_EXPERIMENT_TOKEN_CMD_<family>` (fail-closed if unset). Author push/PR/merge use ambient `gh` — the researcher logging to their own lab is the legitimate author; the cross-family bot is the independent reviewer. `--dry-run` classifies + gates and stops before any push.

## Gate detail (fail-closed)

- **experiment:** BLOCK unless **both** `AUDIT.md` and `AUDIT_RESPONSE.md` are present. This **verifies the close-audit ran and was triaged** (during `run-experiment`, with the human in the loop); it does not re-derive triage and deliberately does **not** prose-grep `AUDIT_RESPONSE.md` for unresolved HIGHs — that heuristic is unreliable (negation/scope games). A **machine-readable close-triage status** (so the gate can *prove* rather than scan) is a deliberate future hardening, tracked separately. An eval-only / anchor-failed run that legitimately has no close-audit is allowed only if `RESULTS.md` records a closed decision **at line start** (e.g. `Decision: ANCHOR_FAILED`, no-go) — otherwise BLOCK and surface.
- **note:** BLOCK on any secret-value pattern hit (`ghp_…`, `github_pat_…`, `sk-…`, `AKIA…`, PEM private keys).
- Any parse failure / missing record → BLOCK (never a silent pass).

## Alternatives considered

- **Source `wf.sh`'s lifecycle** — rejected: research depending on the engineering layer (the #150 swamp); breaks `wf.sh` single-file relocatability.
- **Classify by path** (`registry/` = experiment) — rejected: notes legitimately live under `registry/` (e.g. `openwebui-*` serving infra), so path mislabels them.
- **Re-run the audit at merge** — rejected: redundant + expensive; the close-audit already ran in `run-experiment`.

## Blast radius

New skill + script, plus a one-line handoff added to `run-experiment`'s close (it now lands the record via `log-experiment` after the audit, instead of a raw push). Operates on the research repo (research-lab), not on automated-researcher itself. Reversible (revert the PR). Main risk: misclassification — mitigated by the explicit `KIND:` override and fail-closed gates. Known deferred integration: the direct `gh` writes are not yet composed with a repo's *optional* `gh` write-guard wrapper; on the current instance (no such wrapper) they work as-is, and a guard would be a follow-up.

## Rollout + rollback

Ship via ship-change. It then becomes the documented way to log an experiment. The by-hand sequence merged 2026-06-29 (records #21/#22; experiments #16/#18/#19/#20) is the worked reference the driver automates. Rollback: revert the PR — no existing flow depends on it yet.
