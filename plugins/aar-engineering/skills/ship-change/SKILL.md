---
name: ship-change
description: >-
  Ship a scaffold/product change through the SWE pipeline as a GitHub-backed lifecycle: Issue → worktree
  branch → namespaced design doc → draft PR → cross-family --scaffold design review (posted to the PR) →
  implement → cross-family --code review (posted) → classifier (records mechanical vs architectural with
  evidence) → tracked .aar-ci checks + fake-HOME behavior smoke → fail-closed merge-when-clean. Use for any
  change to the product scaffold (skills, plugins, CI, the constitution). The agents ARE the engineers: a
  change is authored by one family and reviewed by the OTHER. ENFORCED repos can require the --code review as
  a native opposite-family engineer review before merge. Worktree-from-the-start — never disturbs the shared
  main checkout.
---

# ship-change — the GitHub-backed scaffold-change lifecycle

The **engineering** counterpart to `run-experiment`: where `run-experiment` runs a research experiment,
this ships a change to the *product itself*. It belongs to the **SWE pipeline** layer (see
`aar-skills/AGENTS.md` "Two layers"), not the shipped research product.

**The agents are the engineers** (`AGENTS.md` "The vision"). Every change is **authored by one model
family and reviewed by the OTHER** (Claude-authored → Codex reviews; vice-versa). The human is the
staff-engineer / PM: sets direction (the Issue), gates the **architectural design**, and audits the durable
GitHub trail — but is not a gate on routine merges. This mirrors the research split: design *with* the
human, execution *by* the agents.

**ENFORCED where configured.** The cross-family `--code` review can be posted as a **native opposite-family
engineer review**, and branch protection on `main` can **require** that approval (plus no force-push/deletion,
and *include administrators* so even an admin author token can't bypass) before any merge. `wf.sh`'s own
fail-closed gate (checks + a final-SHA `--code` review, no HIGH) runs first; on enforced repos, `gh pr merge`
then succeeds only because the required approval is present. **Still advisory:** the classifier's architectural/mechanical
classification is recorded on the PR, not yet wired to a required `design-gate` check — so the design
approval is the human's judgment, recorded, not mechanically blocking. As-built config + escape hatches:
`RUNBOOK.md`.

## The non-negotiable properties (the driver enforces them — don't work around them)

- **Worktree-from-the-start.** All branch work happens in a dedicated git worktree, never by switching the
  shared `main` checkout. This dissolves the three shared-checkout races a prior design kept hitting
  (reviewing stale files; a commit-failure stranding the checkout off main; a remote-vs-local SHA gap).
- **Cross-family review, both gates.** The design (`--scaffold`) and the code (`--code`) are reviewed by the
  OPPOSITE family from the author. Pass the author family to review/finish commands. Codex-authored reviews also
  need `AUDIT_VERIFIER_CMD` to point at a Claude-family CLI so the model review is genuinely cross-family.
- **Engineer identities auto-upgrade when configured.** `WF_ENGINEER_TOKEN_CMD_CLAUDE` /
  `WF_ENGINEER_TOKEN_CMD_CODEX` mint GitHub tokens for the family bot identities; `WF_ENGINEER_GIT_AUTHOR_*`
  gives `Name <email>` for strict `open` commits. If identity config is absent, the driver warns and uses
  ambient GitHub/git identity unless `WF_REQUIRE_ENGINEER_IDENTITY=1`. `WF_REVIEWER_TOKEN_CMD` remains a
  backward-compatible alias for the Codex engineer token when `WF_ENGINEER_TOKEN_CMD_CODEX` is unset.
- **Native review is configurable.** Missing reviewer identity falls back to comments for unenforced installs.
  Set `WF_REQUIRE_NATIVE_REVIEW=1` to make the final merge-gate review block when the opposite-family reviewer
  identity is absent.
- **Fail-closed.** A crashed or malformed review NEVER reads as "clean" — the verdict is parsed from the
  authoritative `SUMMARY: high=.. med=.. low=..` line; missing/garbled → BLOCK. The merge gate **re-runs
  `--code` on the final diff** so the merged diff is the reviewed diff, and merges **only with zero HIGH**.
- **Tracked check profile + behavior smoke.** Every change runs `<repo>/.aar-ci/checks.sh` (deterministic:
  JSON/syntax/compile/version-bump) AND the fake-HOME behavior smoke for plugin/skill changes (an
  install/discovery break that deterministic checks can't catch).
- **The classifier records, never blocks (advisory).** `.aar-ci/classify.sh` records mechanical vs
  architectural WITH EVIDENCE and the driver posts it to the PR. Architectural = needs the PM's design
  approval; mechanical merges on the cross-family review + checks alone. This is recorded for the human to
  read — not yet wired to a required `design-gate` check (a tracked follow-up).

## The lifecycle (the agent drives; `wf.sh` is the mechanical glue)

You do the JUDGMENT steps (write the design doc, implement, triage findings) BETWEEN these subcommands.
Authenticate `gh` first for ambient fallback — `gh auth login`, or export `GH_TOKEN`. Bot-token paths use the
configured `WF_ENGINEER_TOKEN_CMD_*` commands. `wf.sh` is `scripts/wf.sh` in this skill.

```
# 0. An Issue exists (the backlog item). Create it if not: gh issue create …  → note its number <N>.

# 1. START — worktree + branch + design-doc skeleton
wf.sh start <N> <slug>            # prints WORKTREE=… BRANCH=… DOC=proposals/<N>-<slug>.md
#   → WRITE the design doc at <WORKTREE>/proposals/<N>-<slug>.md (problem, approach, alternatives,
#     blast radius, rollout). This is the ADR; it lands on main and survives branch deletion.
#     The PR body is a short reader view derived from the first paragraphs of Problem + Approach;
#     write those first paragraphs as plain English for a human opening the PR cold.

# 2. OPEN — commit the doc, push, open the DRAFT PR (links the Issue)
wf.sh open <WORKTREE> [author]    # prints PR=<n>; author=claude|codex enables bot identity when configured

# 3. DESIGN REVIEW — cross-family --scaffold on the doc, posted to the PR
wf.sh design-review <WORKTREE> <author>
#   → revise the doc for findings. ARCHITECTURAL changes: this is where the PM's design approval belongs
#     (recorded, advisory — the human reads the PR; not yet a required check). Then:

# 4. IMPLEMENT — build the change IN the worktree, commit it (path-scoped) on the branch.

# 5. CODE REVIEW — cross-family --code on the diff, posted to the PR
wf.sh code-review <WORKTREE> <author>
#   → triage every finding as a PEER: fix HIGH/MED in the worktree + commit, or respond on the PR
#     with accept/defer + reason via `wf.sh comment <WORKTREE> <author>` (posts as the AUTHOR engineer
#     identity, NOT your owner token — never a bare `gh pr comment`). Re-run code-review after a HIGH fix.

# 6. CLASSIFY — record mechanical|architectural with evidence, posted (advisory)
wf.sh classify <WORKTREE> [author]

# 7. FINISH — checks + smoke + fail-closed --code merge-gate + mark ready + merge + cleanup worktree
wf.sh finish <WORKTREE> <author>
#   → SHIPPED on a clean gate; or BLOCKED with the reason (fix + re-run finish). Cleans the worktree.
```

**Outcomes of `finish`:** `SHIPPED: PR #N merged` (clean cross-family review + checks; worktree cleaned), or
`BLOCKED: …` — a HIGH remains, a check failed, or the review was malformed (fail-closed). Fix in the
worktree, commit, and re-run `finish`. Never merge around the driver — the re-review-on-the-final-diff is
the point.

## Triage discipline (when a review has findings)

Same as the research audits: triage as a **peer**, not a patcher. **ACCEPT** (real → fix in the worktree +
commit), **DISPUTE** (say why it's wrong / moot — respond on the PR), **DEFER** (real but out of scope →
reason on the PR). Post PR responses via `wf.sh comment <WORKTREE> <author>` so they carry the author
engineer identity, not the human owner's token. A HIGH must be fixed or genuinely refuted before merge; the driver blocks on any HIGH.
(The cross-family reviewer is *told* to find the next thing, so it won't self-converge — don't chase it past
HIGH=0 into endless polish; the merge bar is HIGH=0 + checks green.)

## GitHub reader surface

GitHub is the durable coordination record, but it should read like a handoff to a human who opened the PR cold.

- PR bodies show the first paragraph of `Problem` and the first paragraph of `Approach`, then hide the full design
  record under details.
- Review comments start with the result in plain language. The full audit output stays under details for agents.
- Classification comments say what the classification means first, then hide the classifier evidence under details.
- Long author triage comments keep their first paragraph visible and put the full response under details. Short comments
  stay as written.

## The per-repo `.aar-ci/` profile (what the repo supplies)

- `<repo>/.aar-ci/checks.sh` (required, tracked, executable) — deterministic checks + when to run the
  behavior smoke. See `aar-skills/.aar-ci/checks.sh`.
- `<repo>/.aar-ci/classify.sh` + `classifier.conf` — the mechanical/architectural classifier (fail-closed;
  a non-configurable protected floor + an adjustable glob list). See `aar-skills/.aar-ci/`.
- `<repo>/.aar-ci/fake_home_smoke.sh` — the virgin-HOME install/resolve behavior smoke.

## Composes

- **verify-claims `--scaffold` / `--code`** — the cross-family design + code reviewers (located from the
  installed plugin, or `AUDIT_EXPERIMENT=<path>`). Same engine the research audits use.
- **gh** — Issues, draft PR, PR comments, merge (authenticate `gh`: `gh auth login`, or export `GH_TOKEN`).
- **`RUNBOOK.md`** (this dir) — the as-built branch-protection config + the rollback/escape-hatch + token rotation.

## Bootstrap note

The driver can't ship its own first change through itself (chicken-and-egg), so `aar-engineering` itself is
built + landed via the manual PR + `--code` path one last time. From then on, scaffold changes run through
this lifecycle.
