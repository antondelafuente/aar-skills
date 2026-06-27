# Proposal: pin autonomous executor substrate boundary (#52)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`experiment-lifecycle` says to dispatch a fresh-context executor and requires that executor to arm an
independent recurring self-wake before detached work. It does not say which substrates can actually satisfy that
requirement.

Issue #52 records the verified gap: a tool-spawned subagent does not have `CronCreate` / `ScheduleWakeup`, so it
cannot arm the independent self-wake that `run-experiment` treats as mandatory. If such a subagent is used as an
autonomous detached executor, the run silently degrades to an in-process monitor or controller-held wakeup: the
exact failure mode the skill is trying to prevent.

## Approach

Make the boundary explicit in the existing skill docs and templates:

- In `design-experiment` Step 4, define a valid autonomous detached executor as a fresh full session/process that
  can arm its own independent self-wake. For Claude, that means a detached `claude` session (for example via the
  local launcher), not an Agent-tool subagent.
- State that subagents are fine for short, idempotent, controller-supervised probes, but not for autonomous
  detached runs where the controller expects the executor to own liveness.
- Make the existing checklist self-wake gate the canonical fail-closed mechanism: it requires the independent
  waker/backstop id or handle as evidence, and says an in-process monitor alone is FAIL.
- In `run-experiment`, scope the substrate check to **autonomous detached runs**: if the substrate cannot arm an
  independent recurring wake, mark the checklist gate FAIL and escalate before GPU/API spend instead of silently
  substituting a weaker monitor. Short controller-supervised probes remain allowed.

This is documentation/protocol only. It does not build a detector for subagent tool registries in this change.

## Alternatives considered

- **Let the controller own the wake while the subagent executes.** Rejected: that recouples the run's safety to the
  controller staying alive, which defeats the detached-executor boundary.
- **Ban subagents everywhere.** Rejected: subagents are still useful for short supervised tasks where the
  controller is watching and no detached compute is left running.
- **Add a runtime detector now.** Rejected for this small fix: the product-level rule is the missing piece. A
  detector can follow later if the host agent exposes a reliable capability check.

## Blast radius

Product docs only:

- `plugins/experiment-lifecycle/skills/design-experiment/SKILL.md`
- `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md`
- `plugins/experiment-lifecycle/skills/design-experiment/templates/CHECKLIST_TEMPLATE.md`
- `plugins/experiment-lifecycle/.claude-plugin/plugin.json` version bump
- `CHANGELOG.md`

## Rollout + rollback

Ship through `ship-change`. Rollback is a normal revert if the wording proves too narrow for a supported
substrate.
