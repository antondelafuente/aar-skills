# Proposal: Self-identify by lookup, never by assumed naming scheme (#39)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Any peer-coordination channel — an agent messaging a sibling agent session — requires the sender to
**self-identify** so the recipient knows who is speaking and on whose authority. But the convention
documents the `claude-0 / claude-1 / claude-2 …` scheme as if those names are guaranteed, while giving
the agent **no way to determine its OWN session name**. With no self-lookup documented, an agent fills
the gap with the example scheme — and a guessed name silently defeats the entire point of self-identifying.

**Real incident (2026-06-17):** an agent whose tmux session was actually named `washout-curve` messaged a
peer and self-identified as `claude-1` — guessed purely from the naming examples. A separate, real
`claude-1` session existed, so the message was mis-attributed to the wrong session and needed a follow-up
correction. Session names are **not guaranteed**: a session may be named for its experiment
(`washout-curve`, `viz`, …), not `claude-N`.

The instance-side `message-aar` skill has already been fixed locally. This proposal carries the same
self-identify-by-lookup convention into the **product** so any future productized peer-coordination
guidance inherits it. The product currently has no peer-messaging skill; its durable, substrate-neutral
home for cross-session coordination conventions is `AGENTS.md`'s "Multi-agent dev" rule.

## Approach

Extend the existing "Multi-agent dev" bullet in `AGENTS.md` (Rules section) with one substrate-neutral
sentence: when a peer-coordination channel asks an agent to self-identify, resolve your own session
identity **by lookup** (`tmux display-message -p '#S'`, or the substrate's equivalent) rather than
assuming a naming scheme like `claude-N`; names aren't guaranteed, and a guessed name silently defeats
self-identification.

Load-bearing decisions:
- **Home = `AGENTS.md`, not a new skill.** The product has no peer-messaging skill to attach this to;
  `AGENTS.md` is the agent-neutral constitution and already owns the multi-agent-dev coordination rule.
  One canonical home per fact.
- **Substrate-neutral phrasing.** `tmux display-message -p '#S'` is the Claude/tmux mechanism, given as
  the concrete example, but the rule states "or the substrate's equivalent" so it holds for Codex and any
  other multi-session substrate.
- **Convention, not enforcement.** This is a documented discipline (like the rest of the Rules section),
  not a mechanical gate — matching how the surrounding coordination rules are stated.

## Alternatives considered

- **Productize `message-aar` as a skill and fix it there.** Rejected (for now): the instance copy is
  already fixed, and productizing the whole peer-messaging skill is a larger, separate decision. This
  proposal captures only the decided, uncontroversial convention so it isn't lost when/if that happens.
- **Close the issue as instance-only.** Rejected: that loses the reminder. Landing the convention in
  `AGENTS.md` means any future peer-coordination guidance inherits it by construction.

## Blast radius

`aar-skills/AGENTS.md` only — one bullet in the Rules section. Documentation; no code, no skill behavior,
no plugin version bump. Product (SWE-pipeline constitution) layer. No instance or research-product impact.

## Rollout + rollback

Lands on main via this PR. Revert = one-line doc revert; no runtime surface to roll back.
