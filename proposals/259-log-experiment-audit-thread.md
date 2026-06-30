# 259 — log-experiment: post the audit as a native PR review + author responses

## Problem

log-experiment gates an experiment PR (design or close) by verifying the audit files are present + clean, then posts a single **silent** bot APPROVE. So an experiment PR shows just an approval — not the visible reviewer↔author exchange a *code-review* PR shows (reviewer posts findings, author responds, browsable as a thread). The audit interaction (the findings + the author's triage) already ran during design-experiment / run-experiment and sits in committed files (`DESIGN_AUDIT.md` / `AUDIT.md` + their `*_RESPONSE.md`), browsable only by digging into the diff. The researcher wants experiment PRs to read like code-review PRs — the bots talking on GitHub.

## Approach

Before the gate's approve, **surface the already-run audit onto the PR as a conversation** (additive — the gate, classification, note path, and merge are all unchanged):

- The **reviewer** (opposite-family engineer bot) posts the audit **findings** as a native PR review COMMENT — close: `AUDIT.md`; design: `DESIGN_AUDIT.md` plus any re-audit chain (`DESIGN_AUDIT2.md`, …).
- The **author** (author-family engineer bot) posts the **triage responses** as a PR comment — close: `AUDIT_RESPONSE.md`; design: `DESIGN_AUDIT_RESPONSE.md`.
- Then the existing reviewer **APPROVE** clears the gate and the author bot merges.

Order on the PR: findings (reviewer) → responses (author) → approve (reviewer) → merge — a browsable reconstruction of the cross-family audit. Content comes verbatim from the already-run files; the audit is **not** re-run (it already ran, with the human in the loop). Notes (the secret-scan path) get no thread. Self-contained — uses `gh pr review` / `gh pr comment` with the family-keyed reviewer/author tokens already resolved by the driver (no wf.sh dependency).

## Body-size guard

A PR review/comment body caps around 65k characters. Truncate a large audit/response body to ~60k with a `…truncated; full file in the PR diff` marker — the file is committed in the PR, so nothing is lost. Skip a thread part whose source file is absent (e.g. a no-go run that legitimately has no AUDIT.md falls back to the existing approve-only behavior).

## Alternatives considered

- **Fold the findings into the approve body** — rejected: a single approval comment is less browsable than a real findings → responses → approve thread; doesn't read like a code review.
- **Re-run the audit at PR time** (like `--code` runs on the diff) — rejected: the audit already ran during the experiment with the human in the loop; re-running is wasteful and would diverge from the cleared record.

## Blast radius

`plugins/experiment-lifecycle/skills/log-experiment/scripts/log-experiment.sh` only (+ its SKILL.md doc). Strictly additive: the experiment/design/note classification, the gates, the secret scan, and the merge are untouched. Operates on the research repo (research-lab), not automated-researcher. Reversible (revert → silent approve).

## Rollout + rollback

ship-change PR; then experiment PRs (design + close) show the cross-family audit as a thread. Rollback: revert the PR → back to the silent approve. No config change.
