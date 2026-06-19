# Proposal: Codex skill-wrapper coverage and currency (#70)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Codex has real substrate-specific skill needs, but `aar-skills` does not currently own the Codex wrappers that express
those needs. This box has hand-written wrappers for `design-experiment` and `run-experiment` in `~/.codex/skills/`,
while the repo README still tells Codex users to symlink the plugin source skills directly.

That README advice is now wrong for Codex. The source skills are the canonical procedures, but Codex needs a thin native
wrapper layer that points at the live source and records Codex-only deltas such as `apply_patch`, blocking watcher use,
and cross-family verifier commands.

## Approach

Track Codex-native wrappers in this repo under `codex/skills/<skill>/SKILL.md`, and update the README to install those
wrappers into `~/.codex/skills/` instead of symlinking Codex directly to plugin source skills.

Coverage decision:

- `design-experiment` already has a wrapper and should stay wrapped. It composes source procedure with Codex dispatch
  and editing reminders.
- `run-experiment` already has a wrapper and should stay wrapped. Its Codex wake rule is still current: Codex has no
  Claude `CronCreate`, so unresolved experiments need a live blocking watcher or another explicit wake path.
- `ship-change` needs a wrapper. Codex is an author in the SWE pipeline, as this PR demonstrates, and the wrapper must
  remind Codex to pass `author=codex` and use a Claude-family verifier for cross-family reviews.
- `verify-claims` needs a wrapper. The source skill defaults to Codex as verifier, so a Codex author needs a prominent
  reminder to set `VERIFIER_CMD` / `AUDIT_VERIFIER_CMD` to a different-family CLI when independence matters.
- `gpu-job` needs a wrapper. Codex may invoke it directly for GPU work, and direct GPU work has the same Codex-specific
  unresolved-work constraint: do not leave billable work without a watchdog and a way for Codex to keep watching.

The wrappers remain intentionally thin. They do not copy the source procedure. Each one points at the source skill in
`~/aar-skills/plugins/.../SKILL.md`, says to substitute the local checkout path if the repo was cloned elsewhere, and
keeps only Codex deltas.

## Alternatives considered

- Symlink `~/.codex/skills/<skill>` straight to `plugins/*/skills/<skill>`. Rejected because that destroys the
  Codex-native deltas and restores the wrong premise from the old README.
- Leave wrappers untracked in `~/.codex/skills/`. Rejected because the next Codex session has no durable product record
  for coverage, currency, or installation.
- Add wrappers only for `design-experiment` and `run-experiment`. Rejected because Codex also directly authors
  `ship-change`, may directly invoke `gpu-job`, and needs a `verify-claims` cross-family reminder.

## Blast radius

This touches documentation and Codex wrapper files. It does not change any plugin source skill, script, review gate,
merge rule, GPU backend, or verifier behavior.

The new `codex/skills/` tree is product-owned wrapper source. The live instance still consumes wrappers from
`~/.codex/skills/`, ideally as symlinks to this tracked tree so wrapper text updates with `git pull`.

## Rollout + rollback

Roll out by merging the tracked wrappers and README update, then replacing this box's current `~/.codex/skills`
wrappers for the owned AAR skills with symlinks to `~/aar-skills/codex/skills/<skill>`.

Rollback is deleting the tracked `codex/skills` tree and restoring the old README instructions. The plugin source
skills remain untouched either way.
