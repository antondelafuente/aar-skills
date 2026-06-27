---
name: triage-feedback
description: Run an explicit maintainer pass over automated-researcher feedback. Use when asked to triage product feedback, maintain Issue dispositions, group duplicate reports, route fixes through ship-change, or summarize deployment-only feedback from the consuming instance guidance. Never run automatically.
---

# triage-feedback - maintainer pass

You are switching hats from product user to maintainer. Run this only when explicitly asked; a maintainer pass can edit
shared tracker state and route fixes.

## Config

Run `scripts/feedback_loop_init.sh` once per user. It writes `~/.config/feedback-loop/env` with mode `0600`.

Read:

- `~/.config/feedback-loop/env`
- `references/DISPOSITIONS.md`
- `FEEDBACK_INSTANCE_GUIDANCE`, when configured

`FEEDBACK_PRODUCT_REPO` is required for product Issue triage. If it is missing, stop and ask for
`feedback_loop_init.sh` to be run, or draft the maintainer plan without changing tracker state.

Instance guidance should answer four local questions: where incident notes go, where idea/backlog notes go, how local
entries are archived or closed, and how to coordinate before touching live-owned local files or helpers. If the pointer
is absent or incomplete, say what local decision is missing instead of naming this deployment's paths.

## Product Issue Pass

List open Issues:

```bash
gh issue list -R "$FEEDBACK_PRODUCT_REPO" --state open --limit 100
```

Maintain the disposition invariant from `references/DISPOSITIONS.md`: every open Issue is either unlabeled/untriaged or
has exactly one disposition label. Backfill unlabeled Issues only when the disposition is clear; fix Issues with two or
more disposition labels to one.

Classify feedback:

- `ready`: actionable now, no unresolved design.
- `needs-design`: real, but needs a design pass first.
- `needs-shaping`: too vague to start.
- `blocked`: gated on a prerequisite; include `blocked-by: #N`.
- `parked`: real but not now.
- `other`: taxonomy gap.

Group duplicates by commenting on the existing Issue and closing or labeling the duplicate as appropriate. Post Issue
comments through `wf.sh issue <family> comment -R "$FEEDBACK_PRODUCT_REPO"` when that engineer-safe path is available;
otherwise draft the comment body. Label edits are tracker maintenance and require a configured maintainer identity.

## Routing Fixes

For product-scaffold fixes, use `ship-change`. If `aar-engineering` / `ship-change` is absent, maintain Issues and
summarize the plan, but do not invent a merge path. Draft the ready issue/PR plan and state that `aar-engineering` must
be installed or configured to ship the fix.

For deployment-only feedback, follow `FEEDBACK_INSTANCE_GUIDANCE`. The product skill does not prescribe local buckets,
archive markers, file names, or coordination tools.

Checklist promotion is split by genericity:

- recurring generic validity gates become product `experiment-lifecycle` checklist changes through `ship-change`;
- deployment-specific gates stay in the consuming instance's guidance.

## Output

Lead with a short prioritized triage:

- product fixes to ship now;
- items needing design or shaping;
- deployment-only items and where the instance guidance routes them;
- parked or stale items with reasons.

Then implement the approved straightforward product fixes through `ship-change`, or stop with the exact blocker when
the required product workflow is not installed/configured.
