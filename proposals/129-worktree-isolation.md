# Proposal: Per-agent / per-experiment worktrees for the research-lab tree (#129)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> Step 1 of 2. Step 2 (experiments-as-reviewed-PRs, #130) builds on the `run/<exp>` branch this defines.
> Design-only: this PR lands the design; implementation follows as spawned `ready` issues.

## Problem

Every AAR agent on this box works in **one shared `~/research-lab` checkout**. Two failure modes follow, and they bite constantly once several agents run experiments in parallel:

1. **Cross-agent dirt.** Each agent sees every other agent's uncommitted files. The recurring symptom is an agent (or Anton) staring at "19 modified files I don't recognise" with no way to tell which experiment they belong to, whether they're safe to commit, or whose they are. Committing safely requires path-scoped discipline that's easy to get wrong, and a stray `git add -A` sweeps a peer's in-flight work.
2. **Shared-branch collisions.** The checkout can only be on one branch at a time. When one agent switches it to a feature branch, it switches for *everyone* — so work merged to `main` stops appearing on disk for all the other agents (the branch-parking incident: a meeting transcript was merged to `main` but invisible because the shared tree sat on a Codex paper branch). "I pushed it to main" stops matching "agents can see it."

Both reduce to one root cause: **shared mutable working-tree state** — one working directory, one staging index, one current-branch, for all agents.

## Approach

Give every agent its **own git worktree** of research-lab, so no agent shares a working tree or index with another. The shared `~/research-lab` checkout is demoted to a **read-only canonical surface pinned on `main`** (where merges land; never parked on a branch).

- **Persistent fleet workers:** a stable worktree `~/ws/<name>` on branch `agent/<name>`. Reused across restarts (same path → same branch → same conversation history).
- **Experiment executors:** a disposable worktree `~/ws/run/<exp>` on branch `run/<exp>`, created at dispatch and removed at close (the records live on the pushed branch / its PR, so removal loses nothing). This `run/<exp>` branch is the **seam to #130** — it becomes the experiment's PR.

**The worktree doubles as the agent's cwd.** Claude Code keys conversation history off the working directory, which is the *only* reason each agent currently needs a separate `~/claude-N` folder. A per-agent worktree is already a unique directory, so it serves both jobs at once — isolation *and* history separation — and the `~/claude-N` history-folder trick is absorbed.

**Net invariant:** `main` only ever receives merged work, so the shared read surface stays clean; all in-progress churn lives on a branch inside one agent's worktree, invisible to every other agent. "19 unknown dirty files" becomes structurally impossible.

### Load-bearing decisions

1. **Worktrees, not full clones.** Worktrees share one object store (disk-cheap, instant) where N clones would each carry a full copy + their own remote sync. The one constraint worktrees impose: two worktrees cannot both check out `main`. We accept it by putting **each worker on its own `agent/<name>` branch** that fast-forwards to `main` for reading and carries the worker's own commits for writing. (Validated already: a throwaway worktree was created, dirtied, and removed with zero leakage into the shared tree.)
2. **The worker's worktree is its home (recommended).** A persistent worker's whole session lives in the lab, so it gets a durable home worktree that is also its cwd. The alternative — keep the shared tree as the read surface + a separate `~/claude-N` cwd + spin a worktree only per change (the ship-change pattern) — is viable but keeps the history-folder split and is heavier for an agent that's continuously in the lab. We recommend the home-worktree model and note the alternative below.
3. **`~/research-lab` stays the canonical `main` surface.** It is never switched to a branch again; that discipline is what prevents the branch-parking class of bug. Agents read from it (or fast-forward their own worktree to it).
4. **The machinery is product, written generic.** The launchers belong in `automated-researcher` (sourced into `~/` to execute, like skills via `--plugin-dir`), with instance specifics (lab path, worktree root) as config defaulting to this instance — so a different researcher points it at their own lab and it works. The home folder is just where one instance runs.

### What gets built (the spawned `ready` issues, not this PR)

- **Launcher: per-worker worktree.** `new-claude.sh` (or its product successor) ensures `~/ws/<name>` exists on `agent/<name>` (reuse if present) and launches the agent with that as cwd. Restart reuses it.
- **Launcher: per-executor worktree.** `dispatch-claude.sh` creates `~/ws/run/<exp>` on `run/<exp>`, launches the executor there, and reaps the worktree at close (branch/PR preserved).
- **Config seam.** `AAR_LAB` (lab repo), `AAR_WS` (worktree root) with this-instance defaults.
- **manage-aar / restart** updates so a restarted worker re-attaches its existing worktree rather than a `~/claude-N` folder.

## Alternatives considered

- **Full clone per agent.** Simpler mental model (each can sit on `main` directly), but more disk and a separate remote sync per clone. Rejected: worktrees give the same isolation while sharing the object store.
- **One shared tree, "stays on main, edits in per-change worktrees" (ship-change's model).** Already proven for `automated-researcher`. Rejected as the *primary* model for research-lab agents because a worker is continuously in the lab (not making one discrete change), so a stable home worktree is cleaner and it absorbs the history folder — but this is the close runner-up and is exactly what executors effectively do per experiment.
- **Status quo (one shared tree, path-scoped discipline).** This is the problem; the discipline is error-prone and doesn't address shared-branch collisions at all.

## Blast radius

- **SWE-pipeline / instance machinery**, not the shipped research product or experiment science. Touches the agent **launchers** (`new-claude.sh`, `dispatch-claude.sh`) and the **manage-aar** restart path.
- Changes where an agent's **cwd** lives (`~/claude-N` → `~/ws/<name>`), which moves the conversation-history location and the restart re-attach logic. Existing `~/claude-N` histories are not lost (they stay on disk under their slug) but new sessions key off the new path.
- **No change** to research-lab content, the registry schema, or any experiment.
- **Seam with #130:** the `run/<exp>` branch defined here is the unit #130 turns into a reviewed PR. The two designs share only this interface.

## Rollout + rollback

- **Staged.** Apply to NEW launches first so running sessions aren't disrupted; persistent workers migrate to a worktree on their next restart. The shared `~/research-lab` is pinned to `main` as part of the cutover.
- **Smoke first.** Validate end-to-end with one trivial throwaway experiment (dispatch → worktree → records on `run/<exp>` → reap) before the real experiment wave.
- **Rollback is cheap.** Revert the launchers to the cwd-only behavior; worktrees are removable with no data loss (records are committed to pushed branches). No history migration to undo.
