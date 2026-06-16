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
   (`aar-engineering` plugin, `tests/`, CI). Quality bar: *does the product's machinery work and not regress.*
   Customer: us (the agents + the lab owner building it).

This is the ordinary product-`src` + `tests`/CI split every software repo has — NOT a separate repo (one product →
one repo; revisit multi-repo only when a piece ships independently). It is **agentic at both levels**: agents *do*
the research (product), and agents *build / test / ship* the thing that lets agents do the research (SWE pipeline).

**Don't conflate the two quality gates.** `verify-claims` is shared infrastructure used by both: its cross-family
review serves the **product** (`--design` / `--data` / close = experiment audits, "is this experiment valid") AND the
**SWE pipeline** (`--scaffold` + the PR code review, "does this change to the product's code work"). Same capability,
wired into both layers. Neither gate substitutes for the other — a scaffold change can pass `--scaffold` and still
break a skill's runtime behavior (only a behavior test catches that), and a valid experiment says nothing about
whether the machinery regressed.

**Two orthogonal cuts to keep straight:**
- *product vs instance* — this repo (the product) vs the lab's `orchestrator` repo (the instance that *uses* the
  product to do research).
- *product vs SWE pipeline* — within THIS repo: the shipped research plugins vs the `aar-engineering` layer that
  builds them.

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
