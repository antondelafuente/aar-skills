# Proposal: make the AAR product self-contained (#111)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> **Two-phase design** — output is this doc + product child issues, plus routed instance flip work.

## Problem

A fresh Claude Code or Codex pointed at this repo cannot yet reconstruct the AAR scaffold from product source
alone. The core research plugins are here, but several point-of-need skills and a large share of the
agent-neutral operating constitution still live only under `/home/anton`:

- product feedback machinery: `file-feedback` and `triage-feedback`;
- cross-family second-opinion machinery: Claude-side `ask-codex` and Codex-side `ask-claude`;
- agent-neutral constitution: the durable product/instance split, customer journey, AAR role, and scaffold
  maintenance rules are split between `/home/anton/AGENTS.md` and `aar-skills/AGENTS.md`;
- borderline local-fleet machinery: `message-aar`, `manage-aar`, `update-fleet`, `new-claude.sh`, and
  `dispatch-claude.sh`.

The result is the same failure #112 is retiring: reusable product facts keep landing in the home checkout, so
agents treat `/home/anton` as a shippable repo. #111 drains the reusable product content and explicitly marks
the remainder as instance-owned; de-gitting `/home/anton` only requires the product content to drain, not every
controller-specific helper to become product.

## Approach

Drain only reusable product content into `aar-skills`; keep deployment operations in the consuming instance.
The design settles the boundary so implementation can happen as normal `ready` issues.

### 1. Productize the feedback loop as `feedback-loop`

Create a new plugin, `feedback-loop`, with two skills:

- `file-feedback`: how an AAR user files scaffold feedback at incident time;
- `triage-feedback`: the researcher-triggered maintainer pass that turns feedback into fixes.

The shipped source should be generic but still usable for this upstream product repo. It must not preserve hidden
fallbacks to Anton's instance. The implementation child must audit the live `file-feedback`/`triage-feedback`
coupling set and genericize at least:

- local feedback files such as `/home/anton/orchestrator`, `experiment_gotchas.md`, `AAR_BACKLOG.md`, and their
  closed archives;
- peer-coordination and ownership references such as `CLAIMED_BY` and `message-aar`;
- local product-scaffold paths such as `~/orchestrator/pipelines/` and `~/orchestrator/CHANGELOG.md`;
- harness/config homes such as `~/.claude/` and `~/.codex/`.

Resolve those surfaces without product-to-instance references:

- product/user-facing feedback defaults to the configured upstream product issue tracker;
- instance-only gotcha/backlog destinations come from a named local config profile, not hardcoded paths;
- peer coordination is phrased as "use your consuming instance's ownership marker or peer-coordination channel,"
  not as a named dependency on `message-aar`;
- local pipeline, changelog, and harness paths are examples in an instance profile, not product defaults;
- issue creation has two modes:
  - if `aar-engineering` is installed and engineer identities are configured, use the shipped
    `wf.sh issue <family> ...` path for agent-authored product issues in this repo;
  - otherwise, use a configured issue command or draft the exact issue body for the researcher to submit; do not
    assume Anton's owner token or the old local `gh-as-engineer` helper;
- disposition labels and the `design: #<n>` convention remain editorially canonical in the product constitution
  (`AGENTS.md`), because `aar-engineering`, `experiment-lifecycle`, and `feedback-loop` all consume the same
  cross-cutting issue contract. Plugin-only installs still need a resolvable contract, so #121 must define the
  packaging mechanism: dependent plugins ship a generated/synced `references/DISPOSITIONS.md` fragment sourced
  verbatim from the canonical AGENTS section, with a CI/fake-HOME check that fails if the packaged fragment drifts.
  Do not hand-maintain a second vocabulary or make an optional plugin the canonical home;
- the product skill owns the routing principle and product-tracker disposition convention. The generic residue of
  `triage-feedback` is issue/PR triage for product feedback: classify product vs instance feedback, link to a
  design issue when needed, open or update product issues, and close/archive only by product-tracker state.
  Instance-file bookkeeping procedure such as symptom-cause-fix notes, local emoji markers, or `*_closed.md`
  archive filenames belongs to the consuming instance's guidance. Checklist promotion splits by genericity:
  recurring generic validity gates promote into the product `experiment-lifecycle` checklist through
  `ship-change`; deployment-specific gates stay in the consuming instance's checklist/guidance.

Use the existing product config convention from `gpu-job`: ship a `feedback_loop_init.sh` that writes
`~/.config/feedback-loop/env` with `0600` permissions, supports non-interactive preseed via env vars, and prompts
interactively when stdin is a TTY. The minimum keys are:

- `FEEDBACK_PRODUCT_REPO`: `OWNER/REPO` for product issues. Init may suggest the upstream product tracker when it
  can identify that the plugin source checkout is this upstream product repo, but it must prompt/require the key
  otherwise; do not derive it from the caller's current working directory and do not silently default outside
  installs to Anton's upstream tracker;
- `FEEDBACK_INSTANCE_GOTCHAS_FILE`: optional local gotcha destination for deployment-only incidents;
- `FEEDBACK_INSTANCE_BACKLOG_FILE`: optional local backlog destination for deployment-only improvement ideas;
- `FEEDBACK_INSTANCE_GOTCHAS_ARCHIVE` and `FEEDBACK_INSTANCE_BACKLOG_ARCHIVE`: optional closed-entry archives if
  the consuming instance uses file/archive bookkeeping;
- `FEEDBACK_PEER_COORDINATION`: optional free-text command or pointer for the instance's peer-coordination
  channel;
- `FEEDBACK_INSTANCE_CHANGELOG` and `FEEDBACK_INSTANCE_PIPELINES_DIR`: optional instance-local context pointers
  used only when configured.

If an instance destination is unset, the skill must not fall back to Anton's files; it should file/draft a product
tracker issue when the feedback is product-relevant, or tell the researcher which `feedback_loop_init.sh` key is
missing for deployment-only feedback.

Keep the public product judgment: feedback that an outside researcher would hit belongs in the product tracker;
deployment-specific friction belongs in the instance's private feedback surfaces.

This is why `triage-feedback` productizes now while `update-fleet` and `message-aar` do not: product feedback
triage has a reusable product-tracker core, while fleet reloads and sibling-session messaging are controller
runtime operations with no generic issue-tracker residue in this pass. For Anton's deployment, the current
instance-overlay home for the file-bookkeeping procedure is `/home/anton/AGENTS.md` plus
`/home/anton/orchestrator/PRODUCT_TRANSITION.md`; implementation children must not delete or hollow out the old
home skill until that overlay contains the remaining instance procedure.

### 2. Productize cross-family second opinions as `model-second-opinion`

Create a new plugin, `model-second-opinion`, with two skills:

- `ask-codex`: for Claude-family sessions to ask a fresh read-only Codex/Codex-CLI process for an opinion;
- `ask-claude`: for Codex-family sessions to ask a fresh Claude CLI process for an opinion.

This should remain opinion/review machinery, not delegation. Both skills must require self-contained prompts,
honest relay of agreement/disagreement, and bounded waits. The `ask-codex` implementation details from the live
incident are load-bearing and should ship here now as the single home for this second-opinion behavior: redirect
stdin (`< /dev/null`) and watch for liveness, not just the success string. #122 may later extract a shared
background-wait helper if one materializes, but this migration should not block on that unlanded refactor.
The `ask-claude` side should receive the same audit for Claude CLI stdin/liveness failure modes before shipping;
do not assume `claude -p` is safe just because the original incident happened on the Codex direction.
For CLI invocation, the child should mirror `verify-claims`' explicit-env-override style without depending on
`verify-claims` internals: use per-direction override variables such as `ASK_CODEX_CMD` and `ASK_CLAUDE_CMD`, each
with a sensible opposite-family default for the asking host. #122 may later extract a shared helper, but the
plugin must work when `verify-claims` is not installed.

Expose the directional skill in the asking-family harness: `ask-codex` for Claude-family hosts and `ask-claude`
for Codex-family hosts. A host that lacks the opposite-family CLI simply cannot use that skill until configured;
the skill should say that plainly rather than assuming Anton's box.

### 3. Reconcile the constitution into product plus instance overlay

Update `aar-skills/AGENTS.md` to be the reusable product constitution, not Anton's deployment map. It should
carry the product-owned rules:

- what the product is and who it serves;
- product vs instance vs SWE-pipeline layers;
- agents as product users and maintainers, separated in time;
- issue disposition definitions and design-child link conventions;
- the current dispositions paragraph that calls `file-feedback`/`triage-feedback` instance-specific wiring, so it
  reflects the new product `feedback-loop` home without losing the product-vs-instance distinction;
- ship-change as the enforced path for product scaffold changes;
- generic consuming-instance language rather than "the lab's orchestrator repo".

It should not carry Anton-only source paths, private lab topology, local fleet commands, MATS-specific record
paths, or RunPod/R2 account details except as examples explicitly marked as current-deployment examples.

The current deployment still needs an instance overlay. That overlay lives outside this product PR in the
deployment's own guidance. Before removing a product pointer to a concrete transition-map path, the deployment
must already say where its transition map and instance guidance live. This is the precondition inherited from
#112/#121.

### 4. Do not productize local-fleet tooling in this pass

`message-aar`, `manage-aar`, `update-fleet`, `new-claude.sh`, and `dispatch-claude.sh` are valuable but are
deployment-controller tooling, not the reusable research product yet:

- `message-aar` and `manage-aar` assume local tmux sibling Claude sessions on this controller.
- `update-fleet` assumes this box's `--plugin-dir` Claude fleet and cron poll.
- `new-claude.sh` and `dispatch-claude.sh` encode this controller's Claude launch and research-lab worktree
  topology.

Leave them in the instance for now. Productize them only through a later controller-fleet design with config seams
and a clear outside-adopter use case. The product constitution can still say that consuming instances own their
own launch/reload/messaging surfaces.

### 5. Same-day instance flip

Each migrated product skill must obey the same-day pointer rule. After a product child lands:

- the canonical source is `aar-skills/plugins/<plugin>/skills/<skill>/SKILL.md`;
- Claude-side personal skill dirs are removed for plugin-served skills, because Claude sessions read product
  skills from `--plugin-dir`/plugin install and a duplicate `~/.claude/skills/<skill>` entry would double-register
  the skill;
- Codex-side `.codex/skills` entries become symlinks or thin wrappers pointing at product source, not copied
  procedures;
- `PRODUCT_TRANSITION.md` and any instance guidance note the flip.

This flip is routed instance work, not part of the product PR's merge gate. The product child should record the
required flip and the expected verification, but the child closes on the product change. The deployment then
performs the same-day pointer update through its own transition surface, or records why it was deferred.

## Alternatives considered

- **Copy all home skills into `aar-skills`.** Rejected. Several local skills are lab-instance procedures
  (`read-post`, `read-arxiv-paper`, `synthesize-progress`, `which-model`, legacy RunPod acquisition) or have not
  proven generic enough (`reproduce-paper` is still marked planned in the README). Moving all of them would
  publish Anton's lab as product.
- **Track Codex wrappers as product source.** Rejected by #70 and still right. Product source lives once under
  plugin skill directories. Local Codex wrappers can stay thin pointers.
- **Make `message-aar`/`update-fleet` product now.** Rejected for this pass. They are useful deployment
  operations, but they are currently controller-specific and tied to local tmux/Claude behavior. A generic
  controller-fleet plugin needs its own design.
- **Home `file-feedback` inside `experiment-lifecycle` and `triage-feedback` inside `aar-engineering`.**
  Rejected. The user-side feedback loop is cross-cutting and should be installable without the SWE-pipeline
  plugin, while the maintainer pass consumes the same routing/disposition model. A separate optional
  `feedback-loop` plugin keeps research installs small and lets `experiment-lifecycle` declare it as a companion
  or degrade gracefully when it is absent.
- **Fold `model-second-opinion` into `verify-claims`.** Rejected. `verify-claims` owns the formal facts/logic/data
  audit ladder and its reviewer CLI conventions. `model-second-opinion` is ad hoc consultation and stress-testing,
  not a validity gate. It should mirror the same explicit-env-override style or adopt a later shared helper
  without making every informal second opinion look like an experiment audit.
- **Only move prose, leave skills in home.** Rejected. The product remains non-self-contained if the point-of-need
  skills still live only in `/home/anton`.
- **Inline the whole home `AGENTS.md` into `aar-skills`.** Rejected. It mixes product constitution with Anton's
  deployment, lab paths, and current research-program state. The split must be product constitution plus instance
  overlay.

## Blast radius

Product surfaces:

- new `feedback-loop` plugin;
- new `model-second-opinion` plugin;
- `aar-skills/AGENTS.md` and README install/docs updates;
- plugin marketplace metadata;
- `experiment-lifecycle` docs/templates that currently mention `file-feedback` or hardcode instance filenames
  such as `experiment_gotchas.md`/`AAR_BACKLOG`; `feedback-loop` stays optional, so these references must degrade
  gracefully inside `experiment-lifecycle`'s own contract with neutral language such as "file feedback through
  your consuming instance's feedback channel" when `feedback-loop` is uninstalled or unconfigured, not through an
  env file owned by an absent optional plugin;
- fake-HOME and source-registration smoke coverage as needed.

Instance surfaces:

- Claude plugin registration/removal checks and Codex symlink/wrapper flips on this controller;
- deployment transition map and instance guidance;
- old home-repo copies retired to pointers.

Out of scope:

- de-gitting `/home/anton` itself (#112 routed that to the instance transition surface);
- renaming `aar-skills` to `automated-researcher` (#102/#118-#120);
- controller-fleet tooling productization;
- productizing MATS-specific knowledge ingestion/synthesis skills.

## Rollout + rollback

This design PR lands with `finish --design`, then spawns product children. Each child ships through normal
`ship-change` code mode. Suggested order:

1. Constitution reconciliation first, because it defines the product/instance boundary the other children cite.
2. `feedback-loop` plugin, because `run-experiment` and the issue tracker already point at `file-feedback`.
3. `model-second-opinion` plugin, because it is self-contained and lower blast radius.
4. Instance flips after each product child lands, through the deployment transition surface, with asymmetric
   Claude-plugin/Codex-wrapper verification recorded there.

Rollback for product children is a normal revert of the merged product PR. Rollback for instance flips is moving
the local wrapper/symlink back to the previous home copy. Do not delete old home copies until the product skill
has passed fake-HOME/source-resolution smoke and the live controller is confirmed to use the product source.

## Product follow-up issues

1. **Use existing #121 for `aar-skills/AGENTS.md` constitution reconciliation** (`blocked-by: #111` during this
   design landing; `ready`, `design: #111` after merge): do not spawn a duplicate issue. Before finishing this
   design PR, mark #121 blocked by #111; after #111 lands, add the `design: #111` link/scope and restore its ready
   handling. Then let #121 extract reusable constitution content, genericize instance language, keep
   disposition/ship-change rules editorially canonical in the product constitution, define the generated/synced
   packaged-reference mechanism for plugin-only consumers, and reconcile the existing paragraph that calls
   `file-feedback`/`triage-feedback` instance-specific wiring.
2. **Add `feedback-loop` plugin with `file-feedback` and `triage-feedback`** (`ready`, `design: #111`): package
   the skills in product shape, add `feedback_loop_init.sh` and `~/.config/feedback-loop/env`, audit and
   genericize the full live coupling set (`message-aar`, `CLAIMED_BY`, local pipeline/changelog paths, harness
   homes, and local closed-archive vocabulary), update the `experiment-lifecycle` checklist/template references
   that hardcode local gotcha/backlog names, split generic validity-gate promotion from instance-specific
   checklist promotion, support optional `aar-engineering`/`wf.sh issue` integration plus a non-engineer fallback,
   update docs/marketplace, and record the required controller wrapper flip as instance work.
3. **Add `model-second-opinion` plugin with `ask-codex` and `ask-claude`** (`ready`, `design: #111`): package the
   directional second-opinion skills, preserve the `ask-codex` stdin/liveness/bounded-wait behavior in the plugin
   now, audit `ask-claude` for equivalent stdin/liveness failure modes, document CLI prerequisites, provide
   per-direction override variables with sensible opposite-family defaults, and record the required local
   wrapper/symlink flip as instance work.

## Routed instance work (not product backlog)

- Update the deployment transition map to record that `message-aar`, `manage-aar`, `update-fleet`,
  `new-claude.sh`, and `dispatch-claude.sh` remain instance-owned for now.
- Flip this controller after each migrated product skill lands: remove duplicate Claude personal skill dirs for
  plugin-served skills, point Codex wrappers/symlinks at product source, and record the verification in the
  deployment transition surface.
- If the deployment still wants a reusable controller-fleet product later, file a separate `needs-design` issue
  for that generic plugin after the product/instance boundary in this design has landed.
