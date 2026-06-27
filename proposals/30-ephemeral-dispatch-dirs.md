# Proposal: Dispatch-host lifecycle — the executor self-marks reapable on completion (#30)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

When the designer hands a locked brief to a fresh zero-context executor (the `design-experiment` →
`run-experiment` handoff), that executor runs **inside its own dispatch host**: a tmux session in a dedicated
working directory, so its conversation transcript stays isolated and the shared tree stays clean. When the
experiment finishes, the executor tears down the *GPU compute* and clears its *self-wake* — but it does
**nothing about the host it ran in**. The tmux session keeps running idle and the launch directory persists
until a human notices and reaps it by hand. So every dispatched run leaves a stray idle session plus a
launch dir behind, and an operator has to remember to clean each one up — exactly the litter issue #30 was
filed to stop.

Two things have changed since #30 was filed (2026-06-17) that reshape the fix. First, the launch-dir
*mechanism* #30 proposed — a plain throwaway folder under `~/.aar-dispatch/<exp>-<runid>/` — has effectively
been built, and built *better*: the instance dispatcher gives each one-shot executor its **own git worktree**
on a `run/<exp>` branch instead of a bare folder. That keeps the same transcript-isolation property #30
wanted (a unique cwd → a unique transcript slug → no history mixing) **and** adds two things a plain folder
can't: the executor commits and pushes its records to the branch (so the launch dir is no longer the only
copy of anything), and the shared checkout stays clean on `main`. Second, the close discipline that should
own host teardown — `run-experiment`'s Close step — was written for the GPU era and never grew a clause for
the dispatch host. So the real, un-built residual of #30 is *not* "create ephemeral launch dirs"; it is
**"close the dispatch host's lifecycle on completion."** This proposal is the design pass that records the
supersession and specifies that residual.

## Approach

Make the executor, at the very end of its own Close, **self-mark its dispatch host reapable** rather than
leave it running — but stop short of self-deletion. Concretely, once a run reaches a terminal state (DONE,
BLOCKED, or errored) and the executor has already verified GPU teardown, pushed its `RESULTS.md`, and cleared
its self-wake, it performs one final host-close: it records its terminal status where the dispatcher can read
it, confirms its branch is committed and pushed (so nothing in the launch dir is the only copy), and then
stops its own idle tmux session via a dedicated **non-destructive** dispatcher path. This is deliberately
**not** `--reap`: the existing `--reap`/`--reap-all` *delete* the worktree (`git worktree remove`), which is
the operator/TTL deletion step and must never be what a finishing executor calls. The design adds a separate
`dispatch-claude.sh --host-close <exp>` (a.k.a. `--mark-terminal`) that **kills the session and writes the
terminal-status marker but leaves the worktree and its pushed branch on disk**. So the dispatcher ends up
owning two distinct verbs: the new non-destructive host-close (executor-invoked, on completion) and the
existing destructive reap (operator/TTL-invoked, after review). This design supplies the missing *trigger*
(the completion event) and a small machine-readable **terminal-status marker** the dispatcher and an operator
can both read to know a host is finished and safe to remove.

For this to work for a *zero-context* executor — which reads ONLY the brief + scaffold — the host-close
handle must be **surfaced on the brief / execution-profile surface, not buried instance-side**. The same way
the self-wake contract requires the waker/backstop id be recorded in `CHECKLIST.md`, the dispatch contract
requires `START.md` (or the substrate's execution profile) to snapshot a `dispatch_host_close` handle: the
exact command to run at Close, the terminal-status marker's path and schema, the evidence that proves the host
was closed, and explicit **N.A. semantics** for substrates that have no persistent dispatch host (a Codex
thread/watcher that simply exits). The *contract* (an obligation + a discoverable handle) lives in the product;
the *values* of the handle (the concrete `--host-close` command, the marker path) are filled in by the
instance/substrate. And because the CHECKLIST template is the scaffold's canonical forcing function for Close
gates, the contract is anchored there: a universal `[BLOCK]` checklist gate requiring terminal
host-marker / host-closed evidence (or an explicit N.A. for no-persistent-host substrates), so the host-close
can't be silently skipped the way buried prose gets skipped.

The load-bearing decision is **"auto-mark reapable, not auto-`rm -rf` on completion."** A finished executor is
not a *reviewed* executor: the worktree may hold the failed logs, partial artifacts, or exact debug state a
human needs to understand a bad run, and "the run exited" is not "the result was seen." So deletion stays
operator-triggered (the existing `--reap`), or at most TTL-gated behind the dispatcher's existing strong
guards (clean tree, branch pushed at HEAD). What the completion event *does* do is stop the bleeding: kill the
idle tmux session and write the terminal-status marker, so the host stops consuming a session slot and
announces itself as reap-eligible, while its evidence stays on disk and on the branch until a human clears it.
This is strictly safer than #30's original "kill tmux + `rm -rf`," which would nuke an unreviewed worktree the
moment the executor stopped.

The split between the **product** and the **instance** is the second load-bearing decision. The product repo
(`automated-researcher`) gets the **substrate-neutral dispatch-host lifecycle contract** — a clause in
`run-experiment`'s Close step, a matching line in the `design-experiment` dispatch contract, a `[BLOCK]` gate
in the `CHECKLIST` template, and the `dispatch_host_close` handle on the `START` template surface — stating
that the dispatch host (the session/launch dir the executor ran in), like the GPU and the self-wake, must be
brought to a terminal state at Close: the executor runs its profile's host-close command, which writes a
terminal-status marker and stops the host's idle session; *deletion* is a separate operator/TTL step that
never fires on unreviewed work; and durable results live in the committed/pushed record, never only in the
launch dir. The concrete Claude/tmux/worktree machinery — the `--host-close` verb, the marker's exact path and
format, the `~/ws/run/<slug>` worktree layout — stays **instance-side** in `dispatch-claude.sh` /
`new-claude.sh`, because Codex's dispatch host is a different shape (a fresh thread/watcher, no tmux, no
worktree, so the gate resolves N.A.) and must satisfy the same contract its own way. The product prescribes the
*obligation* and the *discoverable handle*; each substrate supplies the *mechanism* and the handle's *values*.

## Alternatives considered

- **Build #30 verbatim — a plain `~/.aar-dispatch/<exp>-<runid>/` folder with kill+`rm -rf` on completion.**
  Rejected: the worktree dispatcher already supersedes the folder (same isolation, plus pushed-backup and a
  clean shared tree), so re-introducing a bare folder is a regression; and immediate `rm -rf` on exit deletes
  unreviewed evidence. The right design keeps the worktree and replaces "delete on exit" with "mark reapable
  on exit."
- **Auto-`rm -rf` (or auto-`--reap`) the instant the executor exits.** Rejected as the default — it conflates
  "finished" with "reviewed" and can destroy the exact failed-run state a human needs. Auto-deletion is only
  acceptable TTL-gated behind the clean+pushed guards, as a later optional convenience, never the on-exit
  default.
- **Leave host teardown fully manual (status quo).** Rejected: it litters an idle tmux session + a launch dir
  per run and depends on a human remembering to reap each one — the original #30 complaint. The cheap, safe
  half (kill the idle session + write the marker) should be automatic; only the destructive half stays manual.
- **Put the tmux/worktree mechanics in the product repo.** Rejected: it would hard-code a Claude-specific,
  tmux-specific, `~/ws/run`-specific shape into a substrate-neutral product and break the Codex dispatch host,
  which has no tmux or worktree. The product owns the contract; the instance owns the machinery.

## Blast radius

- **Product (`automated-researcher`), docs at the implementation stage — but a runtime-protocol behavior
  change:** a Close-step clause in `run-experiment`'s SKILL.md, a matching line in the `design-experiment`
  dispatch contract, a `[BLOCK]` host-close gate in the `CHECKLIST` template, and the `dispatch_host_close`
  handle on the `START` template. Because this changes the `experiment-lifecycle` runtime protocol (a new
  Close obligation + a new required checklist gate), the product child **bumps
  `plugins/experiment-lifecycle/.claude-plugin/plugin.json` and adds a `CHANGELOG.md` entry** per the AGENTS.md
  "version bump on every behavior change" rule — it is not a no-op doc edit. No CI logic moves; the
  install/discovery surface is unchanged beyond the manifest version. This design PR itself is
  `proposals/*.md` only.
- **Instance (this box), where the mechanism lives:** `dispatch-claude.sh` gains a completion path
  (kill-session + write terminal-status marker; reuse the existing clean+pushed guards) and `new-claude.sh`
  is unaffected beyond what the executor calls at Close. `run-experiment`'s executor gains a final host-close
  action. These land as the `ready` children, not in this design PR.
- **Risk profile:** low. The destructive operation (`--reap`/`rm -rf`) is unchanged and stays behind its
  existing guards and an explicit operator/TTL trigger; the new automatic behavior is only *killing an idle
  session* and *writing a status file*, both reversible and non-destructive (the worktree and its pushed
  branch survive). The persistent `~/claude-N` fleet workers are explicitly out of scope — they are
  long-lived and never reaped by this path.

## Rollout + rollback

- **Sequencing:** this is a two-phase design PR (doc-only). On merge it spawns `ready` children: (1) the
  product contract — the `run-experiment` Close clause, the `design-experiment` dispatch-contract line, the
  `CHECKLIST`-template `[BLOCK]` gate, the `START`-template `dispatch_host_close` handle, **plus the
  experiment-lifecycle version bump + CHANGELOG entry**; (2) the instance non-destructive
  `dispatch-claude.sh --host-close <exp>` verb (kill-session + write terminal-status marker, reusing the
  existing clean+pushed guards, never deleting the worktree); (3) the `run-experiment` executor's final
  host-close action that invokes (2) at Close. The product contract (1) can land independently; the instance
  pieces (2)/(3) depend on the contract wording from (1) but are otherwise self-contained.
- **Rollback:** the product change is a doc clause — revert the squash commit through the normal lifecycle.
  The instance completion path is opt-in by construction: if it misbehaves, the executor simply stops calling
  the host-close at Close and the world reverts to today's manual-reap behavior, with no data at risk because
  deletion was never automatic. The standing escape hatch is unchanged: `dispatch-claude.sh --reap <exp>` /
  `--reap-all` for manual cleanup, `--list` to see what's outstanding.
