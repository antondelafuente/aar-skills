# Proposal: reconcile the product constitution instance language (#121)

> Implementation note for a `ready` issue spawned by #112 and expanded by #111.

## Problem

`AGENTS.md` still describes the product/instance split using Anton's deployment as the literal instance:
"the lab's orchestrator repo" and `orchestrator/PRODUCT_TRANSITION.md`. That keeps a reusable product
constitution pointing at a private deployment surface.

#111 also made the disposition vocabulary a cross-plugin contract: `aar-engineering`, `experiment-lifecycle`,
and the future `feedback-loop` plugin all consume the same issue disposition semantics. The vocabulary belongs
editorially in the product constitution, but plugin-only installs need a packaged reference they can read without
falling back to repo-root context.

## Approach

- Reword the product/instance paragraphs in `AGENTS.md` to describe generic consuming instances rather than
  Anton's current deployment.
- Reconcile the disposition preface so reusable feedback machinery can live in product skills while
  deployment-only file bookkeeping remains instance guidance.
- Mark the disposition section with stable sync markers.
- Add `ship-change/references/DISPOSITIONS.md` as a packaged reference generated from that AGENTS section.
- Add a deterministic check that every packaged `DISPOSITIONS.md` exactly matches the canonical AGENTS section.
- Point the `ship-change` close-gate docs at its packaged reference and bump `aar-engineering` for the plugin
  behavior/docs change.

## Alternatives considered

- **Make `feedback-loop` the canonical disposition home.** Rejected by #111 review: dispositions are consumed by
  the SWE pipeline and experiment lifecycle too, so an optional feedback plugin is the wrong source of truth.
- **Leave plugin-only installs to read repo-root `AGENTS.md`.** Rejected: plugin-only installs may not have that
  file. Packaged references are the concrete install surface.
- **Hand-copy the vocabulary into each plugin.** Rejected: that recreates drift. The check makes packaged copies
  generated/synced artifacts of the AGENTS section.

## Blast radius

- Product constitution text in `AGENTS.md`.
- `aar-engineering` packaged reference/docs and plugin version.
- `.aar-ci/checks.sh` adds a drift check for future packaged disposition references.

## Rollout + rollback

Rollout is normal product merge via `ship-change`: checks, cross-family code review, classifier, and protected
merge. Rollback is a normal revert of this PR; the change is doc/check-only plus a plugin version bump.
