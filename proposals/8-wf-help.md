# Proposal: wf.sh help subcommand + usage on bare invocation (#8)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

`wf.sh` is the workflow driver, but a user who runs it with no arguments (or the conventional `-h` /
`--help`) gets `BLOCKED: unknown subcommand ''` — the discovery-at-point-of-need promise fails at the most
basic touch. The full lifecycle is documented in SKILL.md, but a user already in a shell expects the tool
itself to tell them what it does. A zero-context agent or a new researcher shouldn't have to open SKILL.md
to learn the subcommand names.

## Approach

Add a `help` subcommand that prints the lifecycle usage (the same subcommand list already in the script
header), and route bare invocation, `-h`, `--help`, and an unknown subcommand to it:

- `wf.sh help` / `wf.sh -h` / `wf.sh --help` / `wf.sh` (no args) → print usage, exit 0.
- An unknown subcommand → print "unknown subcommand 'X'" to stderr THEN the usage, exit non-zero (so a
  typo still fails loudly for scripts, but a human sees the options).

The usage text is a single here-doc listing the seven lifecycle steps with one-line descriptions, plus a
pointer to SKILL.md for the full runbook and to RUNBOOK.md for Phase-2/rollback. No behavior change to any
existing subcommand — this is purely additive surface.

## Alternatives considered

- **Leave it (status quo)** — rejected: a bare invocation erroring is a small but real product defect; the
  tool should be self-describing.
- **Print full SKILL.md content** — rejected: too long for a shell help; a concise subcommand list with a
  pointer is the right altitude. The long-form runbook stays in SKILL.md (one canonical home).

## Blast radius

The SWE pipeline only (`wf.sh`, one script in the `aar-engineering` plugin). No change to the product
research plugins, the instance, or any existing subcommand's behavior. Purely additive help text.

## Rollout + rollback

Trivial + reversible: it's one squash commit; revert if ever needed. No state, no migration, no new
dependency. Ships through the normal lifecycle (this is its first dogfood).
