# Proposal: human-friendly PR descriptions from the design doc (#24)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh open` creates PR bodies that are mechanically useful but terse — a `Closes #N`, a pointer to the
design doc, and the lifecycle metadata. They do **not** say, in plain language, *what changed*, *why it
matters*, or *what review attention is wanted*. Now that `aar-skills` is public and `main` is protected,
**PRs are the durable product-change trail** — Anton and any outside maintainer should be able to read a
PR and understand it without reconstructing context from the issue, the proposal file, comments, and the
commit list.

The irony: the design doc the PR points at *already contains* exactly that plain-language description
(Problem = why, Approach = what, Blast radius = review focus, Rollout = risk/rollback). The `open` step
just doesn't surface it — it links to it.

## Approach

**Render the design doc body into the PR description** instead of only linking to it. The doc is the single
source of truth (its own header already calls it "ADR + PR description"); surfacing it means a
self-describing PR with **zero duplicate authoring** — the author writes the doc once.

The PR body is a **generated view of the committed doc**, composed by a reusable `render_pr_body` helper:

1. `Closes #N.`
2. The design doc body from its first `## ` section (drops the H1 title — already the PR title — and the
   boilerplate blockquote): Problem / Approach / Alternatives / Blast radius / Rollout-rollback as plain prose.
3. A `---` separator + a compact **formal footer**: the design-doc path (lands on main at merge), the
   issue link, and the one-line lifecycle/enforcement note that the body carries today.

This maps cleanly onto the sections the issue asked for — *What changed* (Approach), *Why* (Problem),
*Review focus* (Blast radius), *Risk / rollback* (Rollout) — without forcing the author to re-summarize.

**Drift (design-review F1):** because the design-review loop *revises the doc for findings* (exactly this
PR), a body rendered only at `open` would go stale. So the helper is also called at **`finish`**, which
re-renders from the now-final committed doc and `gh pr edit`s the body **before merge** — guaranteeing the
durable record (the merged PR) matches the doc that actually lands. (The draft body between open and finish
may lag a mid-review doc edit; that's low-harm — the `--scaffold`/`--code` reviewers read the committed doc
file, not the PR body — and `finish` reconciles it before it becomes the permanent record.)

Implementation: `render_pr_body <WT> <DOC> <ISSUE>` prints the body (doc from first `## `, footer); both
`open` (create) and `finish` (edit before merge) pipe it via `--body-file -` (stdin) so the doc's
backticks, code fences, and `$`/`#` survive untouched. Robustness: if the doc has no `## ` section the
whole-doc-minus-H1 form is emitted (never a failed `open`/`finish`).

## Alternatives considered

- **Add a fill-in `## What changed / ## Why / ## Review focus` template to the PR body for the author to
  complete.** Rejected — it duplicates the design doc, drifts from it, and adds authoring work the doc
  already did. The doc's sections *are* those sections.
- **Extract only selected sections (Problem + Approach + Blast radius) via section-parsing.** Rejected for
  v1 — fiddly, brittle `sed`/`awk` section-slicing for marginal benefit; the full doc is already concise
  prose and standalone-readable. Can revisit if docs ever grow long enough to warrant a summary slice.
- **Leave `open` terse, write the human summary at `finish`.** Rejected — the draft PR is where humans
  first read it (design review happens on the draft); the description should be readable from the start.

## Blast radius

- **SWE pipeline only:** `plugins/aar-engineering/skills/ship-change/scripts/wf.sh` — a new `render_pr_body`
  helper, the `open)` branch (create with it), and one `gh pr edit --body-file -` line in `finish)` (refresh
  before merge). No change to the review-posting paths, the merge gate, the classifier, or branch protection.
  Behavior change is **cosmetic** — richer, drift-free PR descriptions; the gate is identical.
- Version bump on the `aar-engineering` plugin manifest.
- Every future scaffold-change PR gets the fuller description; existing merged PRs are unaffected.

## Rollout + rollback

- **Rollout:** ships through the normal lifecycle; `.aar-ci` checks (syntax/version-bump) + smoke run in
  `finish`. First observable on this very PR's description if re-opened, and on the next scaffold change.
- **Rollback:** single squash commit — `git revert <sha>` and re-ship. The change is confined to one
  shell branch building a string; worst case degrades to today's terse body.
