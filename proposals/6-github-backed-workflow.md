# Proposal: GitHub-backed design + PR review workflow for AAR scaffold changes (#6)

> Design-of-the-change + ADR + PR description. Reviewed by `--scaffold` before build.

## Problem

AAR scaffold/product changes coordinate via *local* markdown today: proposals in `proposals/`, the backlog in
`AAR_BACKLOG.md`, and design-review outputs (`*.SCAFFOLD_AUDIT.md`) that are **gitignored** — so the review
record is *thrown away*. There's no durable audit trail, no first-class backlog, and the lifecycle is split
across two tools (a local `--scaffold` design review + a separate `ship-change` that opens the PR). We want
**GitHub as the durable coordination layer** for scaffold changes — the standard SWE shape — while keeping
research-experiment artifacts in experiment dirs (this is for the SWE pipeline, not research runs).

## Approach

One GitHub-backed lifecycle per scaffold change:

```
GitHub Issue                      # the actionable backlog item (replaces ad-hoc AAR_BACKLOG entries)
 → branch                         # isolates the work — created/committed in a WORKTREE, never the shared checkout
 → proposals/<issue>-<slug>.md    # the canonical design doc (namespaced, lands on main — survives branch deletion)
 → draft PR opened                # links the Issue; the coordination thread
 → DESIGN REVIEW                  # the OPPOSITE-family engineer runs `--scaffold` on design.md → posts findings on the PR
 → revise → PM Approves design    # architectural changes ONLY: the human's design approval, carried by a `design-gate` check
 → implementation committed       # built on the same branch; draft → ready-for-review
 → CODE REVIEW                    # the OPPOSITE-family engineer runs `--code` → posts findings AND formally Approves (clean) / Requests-changes (findings)
 → deterministic checks + smoke   # the repo's tracked `.aar-ci/` checks + fake-HOME behavior smoke → required status CHECKS
 → MERGE                          # branch protection: opposite-family Approval + checks green (EVERY change) + the design-gate (architectural). Mechanical changes merge on the agent review + checks — no human.
```

**What it reuses vs. what it adapts** (precise — the engine isn't landed yet): genuinely **landed on the fleet** are
`--scaffold` + `--code` (the cross-family review engines, verify-claims 0.7.0), `gh`, and the secrets hook. The
`.aar-ci/` check profile, the fake-HOME behavior smoke, and the merge-rule + fail-closed logic live **only on the
paused `ship-change` branch** — so they are **source material to migrate, redesign, and re-review**, not landed reuse.
It **adds** the GitHub-native front: Issues, the design doc on the branch, the draft PR, and reviews posted to the PR
(a durable trail, vs the gitignored local files).

**Worktree-from-the-start.** All branch/commit/review work happens in a dedicated git worktree, never by switching
the shared `main` checkout. This is the right shape for a shared repo AND it dissolves the shared-checkout races the
standalone `ship-change` review surfaced (reviewing stale files, a commit-failure stranding the checkout, a
remote-vs-local SHA gap) — they were all artifacts of the `checkout -b → commit → checkout main` dance.

## How the gate works: the agents are the engineers, GitHub-enforced

The SWE pipeline is **run by the agent engineers** (see `AGENTS.md` "Two layers"). Each family has a GitHub identity —
a **claude-engineer** and a **codex-engineer** App (per-family to start; per-instance attribution is a later
refinement). A change is **authored by one family and reviewed + formally Approved by the OTHER** — a real
cross-engineer approval, not a bot approving its own work (author ≠ reviewer identity, so GitHub allows it; this is
*why* the multi-engineer framing dissolves the "can't approve your own PR" problem cleanly). **Branch protection** on
`main` enforces the gates; everyone uses the **native Approve / merge buttons**.

**The two gates, GitHub-enforced:**
- **Code review — every change, the agents' gate.** The opposite-family engineer runs `--code`, posts the findings,
  and on a clean valid review (good SUMMARY, no HIGH) **formally Approves**; on findings, **Requests changes**. Branch
  protection requires an approving review *from the opposite family*. A crashed/garbage review can't approve
  (fail-closed: the reviewer Approves only on a valid, clean result). The `.aar-ci` deterministic checks + behavior
  smoke are required **status checks** alongside. Mechanical changes merge on this + green checks — **no human click**.
  *v1 scope (round-3 F3):* enforcement is turned on only for the **productized review direction** (Claude-authored →
  Codex review). Until the Codex→Claude reverse path lands, Codex-authored scaffold changes use the documented fallback
  (the current flow) rather than the enforced gate — so branch protection never blocks a direction with no reviewer.
- **Architectural design — the human's gate, fail-closed.** The PM Approves the **design** earlier, on the draft PR's
  namespaced design doc (the high-taste "together" moment). Branch protection can't natively say "require the human only
  for architectural PRs," so a required **`design-gate` status check** carries it. **It defaults to ARCHITECTURAL**
  (the design-gate is red, needs the human's design approval, verified by actor) — a scaffold change is treated as
  needing design review **unless explicitly recorded mechanical** by the human or the opposite-family reviewer (round-3
  F1). So a mislabel can't silently skip the gate: the safe default is human-design-review, and *mechanical is the
  opt-out, recorded*. Mechanical changes then merge on the agent review + checks alone; architectural ones wait on the
  human. **The classification rules are tracked, ADJUSTABLE config** (not hardcoded) — start with a sensible default
  (always-architectural: constitution + skill-behavior changes; everything else = the reviewer's judgment, defaulting
  to architectural) and tune it as we watch it behave. The starting point is low-stakes *because* it's adjustable.

Routine review → approve → merge is the **agents' loop**; the human is in it only for architectural design — exactly
mirroring the research split (design with the human, execution by the agents). What makes agent self-merge safe: the
foreign-family review, the deterministic checks + behavior smoke, the durable GitHub trail the human audits, and
one-command revert. (This also resolves round-1 F1 — the machine-checkable clearance signal is now native GitHub
approvals, verified by actor, branch-protection-enforced.)

## Relation to `ship-change` (PR #3, paused)

This is `ship-change`'s evolution, not a competitor. It absorbs the engine's good parts (the merge rule, the
fail-closed review gate, the `.aar-ci` checks + smoke integration, the worktree insight) and adds the GitHub-native
front. The standalone `ship-change` is superseded; PR #3 will be closed (or rebuilt under this design). Net: less
total surface, because the worktree-from-the-start flow removes the branch-dance hardening that PR #3 kept failing on.

## Alternatives considered

- **Keep local-files coordination (status quo)** — rejected: the design-review record is gitignored (thrown away),
  no first-class backlog, two-tool split.
- **GitHub-gated bot identity NOW (Design B)** — deferred, not rejected: more setup; the robustness it buys isn't
  needed at single-user scale. Adopt when there's a reason.
- **Finish/merge the standalone `ship-change` first** — rejected: it's superseded; hardening its branch-dance races is
  wasted when this design removes the dance.

## Blast radius

The SWE pipeline (engineering layer), not the shipped research product or the instance lab. Touches: a new/reshaped
`aar-engineering` skill (the lifecycle driver), the `.aar-ci` profile, `gh` usage (Issues + PR comments + merge), and
this `proposals/` convention (which the workflow may relocate to on-branch `design.md`). Reuses the landed review
primitives unchanged. Research-experiment coordination is untouched (stays in experiment dirs).

## Rollout + rollback (the branch-protection fragility — round-2 F3)

Turning on required checks on `main` is a repo-wide gate: if an engineer App or a check breaks, it can block EVERY
merge. So roll it out staged, with an escape hatch:
- **Shadow mode first** — the workflow runs (posts reviews, sets checks) but branch protection is NOT yet *required*;
  watch it work on real PRs before making the checks mandatory.
- **Admin bypass** — the PM stays a repo admin who can always merge (or temporarily lift protections) if the
  automation wedges, so branch protection never traps the team.
- **A runbook** committed alongside the workflow — the exact required-check names, how to relax/remove protections,
  how to rotate an App token.
- The rest is additive + reversible: the current local-files flow still works as a fallback, each change is a
  revertible PR, the skill uninstalls. The new credentials are the engineer App(s); rotating/removing them is the unwind.

## Canonical home for the design fact

So the design isn't duplicated across four places AND the ADR survives branch deletion: the canonical design doc is a
**namespaced file that lands on `main`** — `proposals/<issue#>-<slug>.md` (versioned, durable, not a branch-local
`design.md` that vanishes when the branch is deleted — round-2 F4). The **Issue** is the thin backlog pointer
(title + link + state); the **PR body** is a pointer + discussion; **comments** are the review trail. Everything but
the `proposals/<issue#>-<slug>.md` file is a pointer or conversation, never a second source of truth.

## Design-review response (round 1, --scaffold) — 6 findings folded

- **F1 (HIGH, machine-checkable clearance):** RESOLVED by the GitHub-enforced design (your native Approve, verified by
  actor, branch-protection-enforced, fail-closed) — see the gate section.
- **F2 (HIGH, instance/Claude seams):** adapting the paused engine makes its instance/Claude assumptions **explicit
  product seams**: credential discovery (no `source ~/.env` — the caller/App supplies auth), author attribution (no
  hardcoded `Co-Authored-By: Claude` — the real author), the **reviewer command** (the cross-family verifier as config,
  not a codex hardcode), and the **verify-claims locator** (a seam, not a plugin-cache assumption). Required fixes, not
  silent carryover.
- **F3 (MED, reverse path):** v1 is **explicitly scoped to Claude-authored changes**. The Codex→Claude reverse path
  (the App wiring a Claude reviewer whose output the harness reads) stays the tracked follow-up; the App's reviewer
  command is the config seam where it plugs in.
- **F4 (MED, canonical home):** addressed above — `design.md` is canonical.
- **F5 (MED, unlanded source):** corrected in "What it reuses vs. what it adapts" — the engine/`.aar-ci`/smoke are
  paused-branch source material, and their migration + re-review is in this proposal's scope, not free reuse.
- **F6 (LOW, smoke scope):** v1's fake-HOME smoke gates only the **Claude marketplace install path**; a minimal
  Agent-Skills/symlink smoke for Codex + other consumers is a follow-up (documented, not silently assumed universal).

### Reframe + round 2

**The reframe (the agents ARE the engineers).** The human is the staff-engineer / PM, not the only user. So the
cross-family code review is a **real formal approval by the opposite-family engineer** (a different identity → no
self-approval problem), not the status-check workaround the human-centric draft used. The human gates *architectural
design only*. This is captured in `AGENTS.md` "Two layers" and rewrites the gate section above.

Round-2 `--scaffold` (on the pre-reframe draft) found 4 issues; 3 carry and are folded: **the architectural-vs-mechanical
human gate isn't natively expressible** → a required `design-gate` check (green for mechanical, red-until-PM-approval for
architectural); **branch protection is a repo-wide fragility** → staged rollout + admin bypass + runbook (see Rollout +
rollback); **a branch-local `design.md` is lost on delete** → `proposals/<issue#>-<slug>.md` on `main`. (The 4th was
stale A-vs-B text, removed by the reframe.)

## Bootstrap

This proposal goes through `--scaffold` (dogfood). The workflow can't ship its own first change through itself
(chicken-egg), so it's built + landed via the current manual PR flow one last time; from then on, scaffold changes
run through the GitHub-backed lifecycle.
