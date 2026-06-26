# Proposal: Update product docs and marketplace name to automated-researcher (#117)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Design #102 made `automated-researcher` the canonical product name, but the current product-facing
instructions still present `aar-skills` as the repo, clone path, marketplace namespace, and current workflow
name. A fresh outside user would still install `gpu-job@aar-skills` from `~/aar-skills`, which preserves the
old public surface exactly where the rename is supposed to help.

This issue is the product-repo docs/metadata slice only. It does not perform the GitHub repo rename, does not
flip Anton's local checkout, and does not delete compatibility aliases.

## Approach

Update current product-facing surfaces to lead with `automated-researcher`:

- `README.md`: title, clone path, Claude install examples, Codex symlink examples, config path examples, and
  interactive install examples.
- `.claude-plugin/marketplace.json`: root marketplace `name` and description.
- `AGENTS.md`: header and opening product/instance wording.
- `.aar-ci`: check/profile labels that identify this repo to authors.
- `ship-change` current docs/messages: references to the product repo name and plugin refresh command.
- `aar-engineering` plugin version and changelog, because its current docs/script output change.

Keep internal names such as `aar-engineering` and `.aar-ci` unchanged. Keep landed proposals and changelog
history as historical records. Compatibility path deletion remains #115.

## Alternatives considered

### Keep the marketplace namespace `aar-skills`

Rejected by #102. It has lower migration cost but leaves the old name in the first fresh-install command.
This implementation follows the design's chosen end state and relies on smoke testing to catch namespace
breakage.

### Wait until the GitHub repo is renamed

Rejected. The docs/metadata PR is ordinary product code and can be reviewed before the operational repo/path
flip. There will be a short migration window where docs name the next canonical path before #118 performs the
actual flip, but that is preferable to changing GitHub/local paths while the product docs still teach the old
name.

### Rename `aar-engineering` now

Rejected. #116 owns the engineering-layer boundary and replacement name. This issue only updates references
to the product repo/marketplace name.

## Blast radius

This touches product documentation, root marketplace metadata, `.aar-ci` labels, and the `ship-change`
plugin's current docs/script messages. It does not change plugin module names, experiment code, verification
logic, GitHub branch protection, or live controller launch scripts.

The marketplace namespace change affects fresh Claude plugin installs. Existing local `--plugin-dir` sessions
continue to resolve through the filesystem alias until #119 moves controller launch paths.

## Rollout + rollback

Rollout:

1. Merge this product PR.
2. Run product checks and fake-HOME smoke.
3. Proceed to #118 for the GitHub repo/local checkout flip.

Rollback:

- Revert this PR to restore `aar-skills` docs/metadata.
- If marketplace install smoke fails for reasons not worth fixing now, use #102's fallback: keep the
  repo/path/doc rename and defer the marketplace namespace switch.
