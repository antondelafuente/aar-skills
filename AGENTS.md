# aar-skills — development conventions (agent-facing)

This repo is the PRODUCT: modular agent skills, developed here in their public shape even
while the repo is private. The lab's orchestrator repo is the INSTANCE — it consumes this
repo via symlinks/plugin installs and never the reverse. The instance-side transition map
(what migrates next, gates, current state) lives at the lab's orchestrator/PRODUCT_TRANSITION.md.

## Two layers in this repo: the product and its SWE pipeline

This repo holds **two layers** — same repo, different concerns:

1. **The product** — the shipped research plugins (`gpu-job`, `verify-claims`, `experiment-lifecycle`): the AAR
   scaffold that turns a coding agent into an autonomous researcher. Quality bar: *is the research valid.* Customer:
   the alignment researcher.
2. **The SWE pipeline** — the engineering layer that builds, reviews, tests, and ships the product
   (`aar-engineering`, `tests/`, CI). Quality bar: *does the product's machinery work and not regress.* Customer: us.

This is the ordinary product-`src` + `tests`/CI split every software repo has — NOT a separate repo (one product →
one repo; revisit multi-repo only when a piece ships independently). It is **agentic at both levels**: agents *do*
the research (product), and agents *build / test / ship* the thing that lets agents do the research (SWE pipeline).

**Who runs the SWE pipeline: the agents ARE the engineers.** Every Claude Code / Codex instance is an engineer on
the team (with its own GitHub identity). They author changes, **cross-family-review** each other's PRs (a foreign
family is the safeguard — "AARs are peers" realized in the build), **approve**, and **merge** — the routine
review → approve → merge loop is theirs to run. The human is the **staff-engineer / PM**: sets direction (the Issue
backlog), gates the **architectural design** (the high-taste "together" moment), oversees and can intervene on
anything — but is NOT a gate on routine code merges. This **mirrors the research pipeline exactly**: design *with the
human* (architectural), execution *by the agents* (here: code review → approve → merge). What makes agent self-merge
safe: the foreign-family review (catches blind spots), the deterministic checks + behavior smoke, the human's audit
of the durable trail (GitHub PRs / comments / history), and one-command revert.

**Don't conflate the two quality gates.** `verify-claims` is shared infrastructure used by both: its cross-family
review serves the **product** (`--design` / `--data` / close = experiment audits) AND the **SWE pipeline**
(`--scaffold` design review + `--code` PR review). Same capability, wired into both layers; neither substitutes for
the other.

**Two orthogonal cuts to keep straight:** *product vs instance* (this repo vs the lab's `orchestrator` repo that
*uses* it) and *product vs SWE pipeline* (within this repo: the shipped research plugins vs the `aar-engineering`
layer that builds them).

## Rules

- **Releasability test for inclusion:** would an outside researcher use this unchanged?
  Generic code lives here; instance values (keys, buckets, hostnames, program recipes)
  NEVER appear here — they belong in each user's `~/.config/<module>/` written by the
  module's init. The pre-commit hook (`git config core.hooksPath .githooks`, run once per
  clone) blocks known instance patterns; it is a backstop, not the discipline.
- **Spec layout:** each module = `plugins/<name>/` with `.claude-plugin/plugin.json` +
  `skills/<name>/SKILL.md` + `skills/<name>/scripts/` (scripts INSIDE the skill dir — the
  Agent Skills layout; it makes relative references work for plugin installs AND symlink
  installs identically).
- **Every script header cites the real incidents it encodes.** No best-practice guesses.
- **Version bump on every behavior change** (plugin.json), one CHANGELOG-style line in the
  commit message; tag releases when someone depends on stability.
- **Same-day pointer rule:** when code migrates here from an instance repo, the instance
  copy becomes a symlink/pointer the same day. One canonical home per fact.
- **Test through the user path**, not by inspection: fresh session → plugin install →
  invoke → file friction. Friction reports are the product's most valuable input.
- Multi-agent dev: path-scoped commits; coordinate via the instance's channels before
  editing a module a peer has in flight.
