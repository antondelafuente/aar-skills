# Proposal: Per-agent / per-experiment worktree isolation for research-lab (#129)

> Design-only ADR (lands the design; implementation follows as spawned `ready` issues). Step 1 of 2 — #130 turns `run/<exp>` into reviewed PRs.
>
> **Scope (descoped after design review):** this proposal designs **only the worktree-isolation mechanism.** Everything about *where the launchers live, how they are packaged/tracked, and the implementation/ADR home* is the instance-vs-product boundary and is **deferred to #136**. The experiment **close/review/reap contract** and the **duplicate-launch claim** (the `run/<exp>` branch/PR is the claim) are **#130**. #129 takes no position on either, so it can land without resolving the still-open boundary.

## Problem

Every AAR agent on this box works in **one shared `~/research-lab` checkout**, which causes two failures that worsen with parallel experiments:

1. **Cross-agent dirt.** Each agent sees every other agent's uncommitted files — the recurring "19 modified files I don't recognise," with no way to tell whose they are or whether they're safe to commit; a stray `git add -A` sweeps a peer's work.
2. **Shared-branch collisions.** One checkout = one branch for everyone; when an agent switches it to a feature branch, work merged to `main` stops appearing on disk for all the others (the branch-parking incident).

Root cause: **shared mutable working-tree state** — one working dir, one index, one current-branch, for all agents.

## Approach (the mechanism)

Give every agent its **own git worktree** of research-lab. Demote `~/research-lab` to a read-only canonical surface **pinned on `main`** (never parked on a branch — that is what kills the branch-parking bug).

- **Persistent worker:** its own worktree, which is also its cwd. Its branch is **resettable scratch** (fast-forwarded to `main` for reading), never a durable review unit.
- **Experiment executor:** its own worktree on a short-lived `run/<exp>` branch (the seam to #130).

**The worktree doubles as the agent's cwd**, so conversation history auto-separates (Claude Code keys history off the cwd) and the `~/claude-N` history-folder trick is absorbed.

**Net invariant:** `main` only ever receives merged work, so the shared surface stays clean; all in-progress churn lives on a branch inside one agent's worktree, invisible to others. "19 unknown dirty files" becomes structurally impossible.

### In scope — the mechanism's load-bearing decisions

1. **Worktrees, not full clones** — shared object store (disk-cheap); the one constraint (two worktrees can't share `main`) is met by each worker sitting on its own scratch branch, ff'd to `main` for reading. (Validated: a throwaway worktree was dirtied and removed with zero leakage into the shared tree.)
2. **Durable changes go on short-lived task / `run/<exp>` branches, not the agent-identity branch** — the worktree gives isolation; it does not change the review unit (`research-lab/AGENTS.md`'s issue→branch→PR→review→merge still holds).
3. **`~/research-lab` stays pinned on `main`**, never switched to a branch.
4. **cwd migration is fresh/handoff-only** — a `restart --continue` keeps resuming the old `~/claude-N` cwd (its history slug is unchanged); moving a worker to a worktree happens only via an explicit fresh start or a one-time history shim, never a silent break.
5. **Conservative reap** — a worktree is removed only when **clean AND its branch is pushed at HEAD**, with an explicit `--force` for genuine cleanup. (The richer evidence-gated reap is #130's, once it defines the close contract.)
6. **Slug contract, split from the registry path** *(review F3)* — the registry directory may be nested (e.g. `registry/washout-curve/gapA-gpqa/`), so the safe **branch / tmux / worktree slug** is *derived separately* and validated to reject path separators, `..`, whitespace, and git-ref/tmux-hostile characters. Splitting the two keeps nested experiments dispatchable.

### Out of scope — explicitly deferred (this is the descope)

- **Where the launchers live, how they're packaged/tracked, and the implementation/ADR home, product-vs-instance** → **#136**. (The home folder is *currently* the orchestrator repo, slated for retirement in #112; #129 asserts nothing about that and does not decide which scripts are touched or where they're tracked.)
- **The `run/<exp>` close/review/reap *contract*, and duplicate-launch detection** → **#130**: the pushed `run/<exp>` branch/PR/issue *is* the visible claim (one atomic create-push-or-conflict replaces the old shared-tree peek), but the contract is defined there, not here.
- **`close-experiment.sh`** — a prototype draft in the home folder; not authoritative. #130 removes or absorbs it so there is no competing contract.

## Blast radius

- The worktree **mechanism** only — not the shipped research product, not experiment science. It *will* touch the agent launchers and restart path, but **which** scripts, **where** they are tracked, and **how** the change is reviewed/merged is governed by **#136**, not decided here.
- No change to research-lab content, the registry schema, or any experiment.

## Rollout + rollback

- **Cutover preflight (mechanism-level):** `~/research-lab` is pinned to `main` only after the **existing** dirty/ahead state is attributed, moved to an owner branch, or merged — and the tree is clean at `origin/main`. (Today it is `ahead 4` with modified `journal/writeup/*`; the pin blocks until that is resolved.)
- **Staged:** new launches first; persistent-worker migration is fresh/handoff-only, so no running conversation breaks.
- **Rollback preflight** per `~/ws/<name>` *(review F4)*: clean, or state transferred to a task branch, or explicit owner approval, before any worktree is removed or its cwd rolled back — `agent/<name>` is scratch but may hold unpushed work, so rollback never blind-removes it.
- Cheap once the preflights pass: worktrees are removable with no data loss (durable work is on pushed branches).
