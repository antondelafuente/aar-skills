# Proposal: Canonical naming for automated-researcher and lab paths (#102)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The reusable product is still named `aar-skills` in the repo, clone path, marketplace examples,
fleet scripts, and docs, even though the product direction has outgrown that name. The current
architecture is easier to explain than the names: the reusable product is the automated researcher
scaffold, Anton's private instance is `research-lab`, and old entry points such as `~/orchestrator`,
`~/MATS`, and `~/antondelafuente.com` are compatibility paths into that private instance.

This creates two kinds of confusion. First, an outside researcher sees "aar-skills" and has to learn
that it means "the product that turns a coding agent into an autonomous researcher", not just a bag of
Anton-specific AAR skills. Second, local agents see both `~/aar-skills` and
`~/automated-researcher`, but the latter is only a symlink to the former, so the clearer name is not
the canonical source of truth.

Investigation found these live surfaces:

- `antondelafuente/aar-skills`: public reusable product repo. It ships the Claude plugin
  marketplace plus Agent Skills modules: `gpu-job`, `verify-claims`, `experiment-lifecycle`, and
  `aar-engineering`.
- `antondelafuente/research-lab`: private lab instance repo. It owns `registry/` for operational
  records, `journal/` for synthesized research memory and prose, and `site/` for visualization.
- `/home/anton`: the controller/home checkout, still remote-named `antondelafuente/orchestrator`.
  It owns local session launchers, fleet update scripts, Claude/Codex wrapper config, and global
  guidance. It is not the reusable product.
- Compatibility paths on this box: `~/orchestrator -> ~/research-lab/registry`,
  `~/MATS -> ~/research-lab/journal`, `~/antondelafuente.com -> ~/research-lab/site`, and currently
  `~/automated-researcher -> ~/aar-skills`.

## Approach

Make `automated-researcher` the canonical product name, repo name, local checkout path, and new
installation name. Keep `aar-skills` as a compatibility alias long enough that current sessions,
existing issue links, installed plugin caches, symlinked Codex skills, and old docs do not fail during
the transition.

The name decision:

- GitHub repo: rename `antondelafuente/aar-skills` to `antondelafuente/automated-researcher`.
- Local canonical path on this controller: make `/home/anton/automated-researcher` the real checkout.
- Local compatibility path: make `/home/anton/aar-skills` a symlink to
  `/home/anton/automated-researcher`.
- Product docs: update human-facing docs to say "automated-researcher" first and mention
  `aar-skills` only as a legacy alias.
- Marketplace identity: new install examples should use `@automated-researcher`.
- Existing compatibility: keep the old `@aar-skills` wording where it is describing already-installed
  local fleet state or rollback, then remove it after the fleet and fake-HOME install path prove clean.
- Lab names: keep `research-lab` as the private instance repo and keep the old lab paths as
  compatibility symlinks. This design does not rename `research-lab`, `registry`, `journal`, or `site`.

The implementation should happen in ordered, small changes rather than one giant rename commit:

1. Land this design.
2. Update tracked product docs and manifests in the product repo: README, root marketplace metadata,
   `AGENTS.md`, relevant proposal references that are normative, and `aar-engineering` docs/help text
   that prints `aar-skills` in user-facing commands. Historical proposals and changelog lines may keep
   old names unless they are used as current instructions.
3. Rename the GitHub repo and update the local product checkout so
   `/home/anton/automated-researcher` is real and `/home/anton/aar-skills` is the symlink.
4. Update controller references that load live source: `update-fleet.sh`, `new-claude.sh`, Claude
   settings/hooks, Codex wrapper symlinks, memory entries, and root `AGENTS.md`/`CLAUDE.md`/`README.md`.
   Keep compatibility checks that recognize both paths during the transition.
5. Update `research-lab` docs that point at the product scaffold. Do not touch experiment records only
   because they mention the old name historically.
6. Run a fake-HOME Claude install smoke and a Codex skill-resolution smoke for the new path/name. Then
   run the local fleet health check and verify existing `--plugin-dir` sessions still resolve through
   the compatibility symlink.
7. After a settling period, file a cleanup issue for deleting stale alias prose that is no longer
   needed. Do not delete the filesystem symlink until there is evidence no live launcher, memory, or
   external install doc still depends on it.

`aar-engineering` stays in this repo for this rename. It is a different architectural question:
whether the SWE pipeline should become a separate reusable product/plugin, remain the in-repo engineering
layer, or be split into a generic workflow engine plus repo-local profiles. Rename work should not move
the tool that ships and protects the rename. File a separate `needs-design` issue for `aar-engineering`
extraction after the canonical product name is in place.

## Alternatives considered

### Keep `aar-skills` as the canonical repo

Rejected. The current name describes an implementation artifact, not the product. It is also too
instance-coded: "AAR" is meaningful inside Anton's program, but the public surface should be legible as
the automated-researcher scaffold for other alignment researchers.

### Keep the GitHub repo as `aar-skills`, only add `automated-researcher` docs

Rejected. This preserves the main mismatch. New agents would still clone, install, and file issues
against the old name, and `automated-researcher` would remain marketing text rather than the canonical
object.

### Rename everything and remove `aar-skills` immediately

Rejected. The old name is embedded in live-source launcher paths, Claude settings, Codex symlinks, local
hooks, memories, issue references, and install examples. Removing it immediately would trade clarity for
avoidable breakage. A compatibility alias is cheap and keeps the transition reversible.

### Rename the product and extract `aar-engineering` in the same change

Rejected for this issue. `aar-engineering` is cross-cutting, but it is also the workflow used to ship
changes to this repo. Moving it while renaming the repo would mix a reference migration with a release
boundary change and make rollback harder. The extraction question should be decided on its own merits.

### Rename `research-lab` or remove old lab paths now

Rejected. `research-lab` is already the clear private instance name, and the old lab paths are
compatibility entry points for records, scripts, and human habits. They are not blocking the product
rename.

## Blast radius

Product repo surfaces:

- GitHub repo URL and local origin remote.
- Root README and install snippets.
- `.claude-plugin/marketplace.json` name and descriptions.
- `AGENTS.md` product/instance wording.
- `plugins/aar-engineering/skills/ship-change/SKILL.md`, `RUNBOOK.md`, and `wf.sh` messages that print
  repo names or refresh commands.
- `.aar-ci` checks/classifier wording only if user-facing or path-sensitive.

Controller/home surfaces:

- `/home/anton/automated-researcher` and `/home/anton/aar-skills` symlink direction.
- `update-fleet.sh`, `new-claude.sh`, restart/fleet docs, and live `--plugin-dir` detection.
- Claude settings marketplace entries and hooks under `/home/anton/bin/aar-skills-*`.
- Codex skill symlinks and wrapper SKILL files that point at product source.
- Root `AGENTS.md`, `CLAUDE.md`, `README.md`, and relevant durable memories.

Lab instance surfaces:

- `research-lab` README/AGENTS/proposals that describe the product scaffold pointer.
- `registry/PRODUCT_TRANSITION.md`, because it is the transition map agents read before moving generic
  machinery.

Out of scope:

- Historical experiment records and old proposals that mention `aar-skills` as the name at the time.
- Renaming `research-lab`, `registry`, `journal`, `site`, `orchestrator`, `MATS`, or
  `antondelafuente.com`.
- Moving or renaming the `aar-engineering` plugin.
- Changing plugin module names such as `gpu-job`, `verify-claims`, or `experiment-lifecycle`.

## Rollout + rollback

Rollout should be alias-first and test-through-user-path:

1. Before the operational rename, ensure `main` is clean and current for the product repo.
2. Rename the GitHub repo to `automated-researcher`; update local `origin` to the new URL.
3. Move the local checkout from `/home/anton/aar-skills` to `/home/anton/automated-researcher`.
4. Create `/home/anton/aar-skills` as a symlink back to `/home/anton/automated-researcher`.
5. Run product checks, fake-HOME install smoke, Codex symlink resolution, and fleet health.
6. Update references in product, controller/home, and lab docs through their normal review paths.
7. Run `update-fleet.sh --if-changed` or `--reload` only after the product PRs land; existing sessions
   that still point at `/home/anton/aar-skills/plugins` should continue to work through the symlink.

Rollback:

- GitHub repo rename can be reversed to `aar-skills`; GitHub redirects cover most old URLs during the
  window.
- Local rollback is `rm /home/anton/aar-skills`, move the checkout back to `/home/anton/aar-skills`, and
  recreate `/home/anton/automated-researcher` as the symlink.
- Marketplace rollback is to keep or restore the old `name: aar-skills` and old install examples.
- Because the alias remains, rollback should not require changing existing Claude `--plugin-dir` sessions
  before the next restart.

## Follow-up issues to file after this design lands

- Ready: Rename product repo and local canonical checkout to `automated-researcher` with `aar-skills`
  compatibility alias.
- Ready: Update product repo docs, marketplace metadata, and ship-change user-facing text for the new
  canonical name.
- Ready: Update controller/home live-source references and hooks to prefer `automated-researcher` while
  accepting `aar-skills`.
- Ready: Update `research-lab` orientation and transition docs to point at `automated-researcher`.
- Needs-design: Decide whether `aar-engineering` remains the in-repo SWE pipeline, becomes a separate
  plugin/repo, or splits into a generic workflow engine plus repo-local profiles.
