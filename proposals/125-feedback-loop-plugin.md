# Proposal: add the feedback-loop plugin (#125)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The reusable feedback loop still lives in Anton's home skills. A fresh user of `automated-researcher`
can install GPU execution, experiment lifecycle, verification, and the engineering workflow, but it cannot
install the two skills that keep the scaffold improving:

- `file-feedback`, used by an AAR as a product user to file operational friction while it is still fresh;
- `triage-feedback`, used by a maintainer AAR to route open feedback into product fixes or instance-only
  follow-ups.

The live home skills are useful, but they are not product-shaped. They hardcode this deployment's tracker,
paths, archives, peer-coordination habits, and wrappers: `antondelafuente/automated-researcher`,
`/home/anton/orchestrator/experiment_gotchas.md`, `AAR_BACKLOG.md`, closed-entry archive filenames,
`message-aar`, `CLAIMED_BY`, local changelog and pipeline paths, and `gh-as-engineer`. Copying that text into
the product would make an outside install appear to work only because it inherited Anton's topology.

At the same time, leaving these skills outside the product keeps the product feedback loop invisible to
zero-context agents. #111 established the boundary: reusable product feedback belongs in product source;
deployment-only file bookkeeping belongs in the consuming instance.

## Approach

Add a new plugin, `feedback-loop`, with two product skills and one initializer.

### Plugin shape

- `plugins/feedback-loop/.claude-plugin/plugin.json`
- `plugins/feedback-loop/skills/file-feedback/SKILL.md`
- `plugins/feedback-loop/skills/triage-feedback/SKILL.md`
- `plugins/feedback-loop/skills/file-feedback/scripts/feedback_loop_init.sh`
- `plugins/feedback-loop/skills/triage-feedback/scripts/feedback_loop_init.sh`
- `plugins/feedback-loop/skills/*/references/DISPOSITIONS.md`

The plugin uses the same Agent Skills layout as the existing modules. README and marketplace docs list it as
optional but recommended: it is how users report product friction and how maintainers process that friction.
Codex installs symlink the two skill dirs independently.

`feedback_loop_init.sh` must be discoverable from either skill. Ship a full copy under both skill dirs and add a
deterministic CI drift check, matching the existing `DISPOSITIONS.md` pattern. The check triggers when either
copy changes and fails unless the two files are byte-identical.

### Local config

`feedback_loop_init.sh` writes `~/.config/feedback-loop/env` with mode `0600`, following `gpu_job_init.sh`'s
local-config convention: no secrets are committed, non-interactive env preseed works, and interactive terminals
are prompted.

The config keys are:

- `FEEDBACK_PRODUCT_REPO`: required `OWNER/REPO` for product issues.
- `FEEDBACK_INSTANCE_GUIDANCE`: optional path or URI to the consuming instance's feedback/coordination
  guidance. This is where an instance names its gotcha/backlog files, archive policy, peer-coordination channel,
  changelog, local helper/pipeline homes, and live-ownership conventions. The product skill surfaces this pointer
  when it needs deployment bookkeeping instead of freezing those slots into the product schema.

The initializer always requires `FEEDBACK_PRODUCT_REPO` through an environment preseed or an interactive prompt.
It does not auto-detect or auto-suggest `antondelafuente/automated-researcher`; that avoids a fork/upstream
ambiguity and removes the hidden "works on Anton's box" class entirely. A non-interactive run without
`FEEDBACK_PRODUCT_REPO` exits with a clear message and leaves no partial config.

When `FEEDBACK_INSTANCE_GUIDANCE` is configured, the product skill expects the target to answer four questions:
where local incident notes go, where local idea/backlog notes go, how local entries are archived/closed, and how
to coordinate before touching live-owned local files or helpers. The product does not prescribe filenames,
markers, or a two-bucket taxonomy; it only requires the guidance to make those local decisions discoverable.

The skills read `~/.config/feedback-loop/env` at point of need. If the config file or `FEEDBACK_PRODUCT_REPO` is
missing, product feedback is not silently sent anywhere: the skill drafts the exact Issue/search/comment text for
the researcher and tells them to run `feedback_loop_init.sh` to enable direct filing. Deployment-only feedback is
not written by product code. The skill drafts the local note in the generic incident/idea shape and tells the
agent to follow `FEEDBACK_INSTANCE_GUIDANCE` when configured; when unset, it reports that the instance guidance
key is missing instead of writing to Anton paths.

### `file-feedback`

The product skill keeps the routing judgment from the live skill:

1. Decide whether the feedback would affect an external adopter of the product.
2. Product/user-facing feedback goes to `FEEDBACK_PRODUCT_REPO` as a GitHub Issue with a type label and exactly
   one disposition label when the answer is clear.
3. Deployment-only feedback is drafted in the generic incident/idea shape and routed through the configured
   instance guidance pointer.
4. A small mechanical fix can be applied immediately at the canonical home, but product fixes still go through
   `ship-change`.

The productized skill removes Anton-specific commands. When `aar-engineering` is installed and the current host
has an engineer identity, it prefers:

`wf.sh issue <family> create|comment -R "$FEEDBACK_PRODUCT_REPO" ...`

When that path is missing, it drafts the exact issue/comment body for the researcher to submit. It never tells an
outside user to call `gh-as-engineer`, never assumes Anton's owner token, never runs raw `gh issue create` as a
substitute for engineer identity, and never writes to `/home/anton/...` unless the instance guidance explicitly
points there.

For instance-only targets, the skill owns only the generic shape: symptom -> cause -> fix/cost for incidents,
and what/why/take/next-step for ideas. It does not own local file edits, close-by-move, archive filenames, or
marker vocabulary. Those remain consuming-instance procedure, surfaced through `FEEDBACK_INSTANCE_GUIDANCE`.

### `triage-feedback`

The product skill is the maintainer side of the same loop. It processes:

- open product Issues in `FEEDBACK_PRODUCT_REPO`;
- optional instance feedback only by reading and following `FEEDBACK_INSTANCE_GUIDANCE`; the product skill does
  not pre-name local feedback buckets.

Its reusable core is product issue and PR triage: maintain disposition labels, classify product feedback as
ready/needs-design/needs-shaping/blocked/parked/other, group duplicates, and route product-scaffold fixes through
`ship-change`.

The skill must not run automatically; it is an explicit maintainer pass. It can surface
`FEEDBACK_INSTANCE_GUIDANCE` before touching instance files or helpers, but it cannot require `message-aar`, a
`CLAIMED_BY` convention, or any named local pipeline/changelog path. When the guidance pointer is unset, it
should say the instance guidance key is missing instead of naming Anton paths.

When `aar-engineering` / `ship-change` is absent, `triage-feedback` can still maintain issue dispositions and
summarize the maintainer plan, but it must not pretend to ship product code. For a product-scaffold fix, it
drafts the ready issue/PR plan and stops with "install or configure `aar-engineering` to ship this fix" rather
than inventing an alternate merge path.

Checklist promotion is split by genericity:

- recurring generic validity gates become product `experiment-lifecycle` checklist changes through
  `ship-change`;
- deployment-specific gates stay in the consuming instance's configured checklist/guidance.

### Shared disposition reference

Both skills ship `references/DISPOSITIONS.md`, copied from the marked canonical block in repo-root
`AGENTS.md`. The existing `.aar-ci` drift check from #121 already checks every packaged
`plugins/*/skills/*/references/DISPOSITIONS.md`, so adding these references enrolls `feedback-loop` in the same
single-source contract rather than hand-maintaining a second vocabulary.

### Experiment-lifecycle references

Update the lifecycle skills/templates so feedback has a concrete product pointer while remaining optional:

- reference `feedback-loop`'s `file-feedback` skill by name at retro/checklist points;
- add explicit fallback wording: if `feedback-loop` is not installed or configured, use the consuming instance's
  feedback process and record the note where the instance tells you to;
- replace literal `experiment_gotchas.md`/`AAR_BACKLOG` assumptions with neutral instance-guidance wording;
- keep the design/run retro requirement, but do not require `feedback-loop` to be installed for the rest of
  `experiment-lifecycle` to make sense.

## Alternatives considered

- **Copy the home skills nearly verbatim.** Rejected: that would preserve the hidden coupling to Anton's home
  checkout and make outside installs fail in confusing ways.
- **Fold `file-feedback` / `triage-feedback` into `aar-engineering`.** Rejected: `triage-feedback` uses
  `ship-change` when it is maintaining the product, but `file-feedback` is also a user-side research skill for
  people who install `experiment-lifecycle` without the build-the-product SWE layer. Keeping a separate
  `feedback-loop` plugin preserves the install boundary: research users can report friction without installing
  the engineering workflow, while maintainers can optionally integrate with `aar-engineering`.
- **Make feedback-loop the canonical home for disposition definitions.** Rejected by #111/#121: dispositions
  govern the whole product issue lifecycle and are enforced by `aar-engineering`; repo-root `AGENTS.md` remains
  the editorial source, with packaged references for plugin installs.
- **Only document "file an Issue" in README.** Rejected: the live workflow has real routing judgment, duplicate
  handling, disposition assignment, and fix-now discipline. That belongs in a point-of-need skill.
- **Auto-default `FEEDBACK_PRODUCT_REPO` to this upstream repo when the checkout looks like upstream.** Rejected:
  upstream/fork detection is exactly the wrong place to be clever. An explicit prompt/env key is simpler,
  clearer, and cannot misroute an outside install's feedback to Anton's tracker.
- **Require `aar-engineering` for issue filing.** Rejected: the integration is valuable when configured, but a
  product user should still get a safe draft/fallback when engineer Apps are not installed.
- **Allow arbitrary `FEEDBACK_ISSUE_COMMAND`.** Rejected: a free-form command can reintroduce the raw-`gh`
  owner-auth misattribution the product just fixed. The supported direct filing path is `wf.sh issue` with
  `-R "$FEEDBACK_PRODUCT_REPO"`; otherwise the skill drafts the issue/comment text.
- **Move instance file/archive procedure into product config.** Rejected: local buckets, filenames, archive
  history, coordination rules, marker vocabulary, and rich close policy are deployment-owned. The product
  surfaces one guidance pointer and drafts generic notes; the consuming instance decides where and how those
  notes are recorded or closed.

## Blast radius

- Adds one product plugin and two product skills.
- Updates root marketplace and README install/docs.
- Updates `experiment-lifecycle` prose/templates only where they currently assume the home-only feedback skills
  or Anton's feedback filenames.
- Adds packaged disposition references under the new skills; existing CI drift checks cover them.
- Adds a deterministic check that the two packaged `feedback_loop_init.sh` copies stay byte-identical.
- Does not change `ship-change`, GitHub branch protection, GPU execution behavior, or research experiment method.
- The product PR does not edit Anton's home directory, but same-day deployment is part of the release step:
  after merge, flip the local Claude/Codex wrapper skills for `file-feedback` and `triage-feedback` to point at
  the product plugin source, preserving any instance-only overlay guidance in `/home/anton` rather than leaving
  duplicate live skill bodies.

## Rollout + rollback

Roll out through the normal `ship-change` lifecycle: draft PR, scaffold review, implementation, code review,
classification, checks, fake-HOME smoke, final review, protected merge. The new plugin is opt-in, so existing
installs keep working if they do not install it.

After merge, this deployment must flip the local Claude/Codex wrapper skills to the product source in the same
work session and keep instance-only file/archive details in `/home/anton` guidance. The ordered deployment step is:

1. Run `feedback_loop_init.sh` non-interactively with Anton's real values so `~/.config/feedback-loop/env` exists
   before any wrapper points at the new product skill.
2. Flip the local Claude/Codex wrapper skills for `file-feedback` and `triage-feedback` to point at the product
   plugin source, after checking that no in-flight experiment is currently in its close retro.
3. Use the instance's fleet-propagation path (`update-fleet` on this deployment) or an equivalent reload/restart
   for live sessions that need the changed skills, coordinated through the configured instance guidance.

If that instance flip cannot be completed immediately, open a tracked instance follow-up before marking this
shipped; do not leave two independently-editable live copies as the steady state.

Rollback is a normal revert of the merge commit plus reversing any deployment wrapper flip performed after merge
(or temporarily restoring the pre-flip local skill bodies). Because the plugin is otherwise additive and the
lifecycle text degrades to neutral instance-feedback wording, rollback risk is low once the instance wrapper
state is handled.
