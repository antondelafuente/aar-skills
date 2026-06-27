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
leave it running — but stop short of self-deletion. Concretely, once a run reaches any terminal state and the
executor has already verified GPU teardown, pushed its `RESULTS.md`, and cleared its self-wake, it performs
one final host-close: it records a **host-lifecycle** status where the dispatcher can read it, confirms its
branch is committed and pushed (so nothing in the launch dir is the only copy), and then stops its own idle
tmux session via a dedicated **non-destructive** dispatcher path. The marker is deliberately scoped to the
*host* lifecycle only — `host_state=closing|closed` — and carries **no experiment-outcome semantics**:
*whether the experiment concluded / was blocked / was abandoned* is the canonical-terminal-experiment-state
question owned by the #130 design (`blocked` / `invalid` / `abandoned` / `null-conclusion`), and the host
marker neither duplicates nor pre-empts it. A host can be `closed` regardless of how the science turned out;
the experiment outcome lives in `RESULTS.md` and #130's state, not in this marker. This is deliberately
**not** `--reap`: the existing `--reap`/`--reap-all` *delete* the worktree (`git worktree remove`), which is
the operator/TTL deletion step and must never be what a finishing executor calls. The design adds a separate
`dispatch-claude.sh --host-close <exp>` (a.k.a. `--mark-terminal`) that **writes the host-state marker and
hands the session kill to a detached closer, but leaves the worktree and its pushed branch on disk**. So the dispatcher ends up
owning two distinct verbs: the new non-destructive host-close (executor-invoked, on completion) and the
existing destructive reap (operator/TTL-invoked, after review). This design supplies the missing *trigger*
(the completion event) and a small machine-readable **host-state marker** (`closing` → `closed`) the
dispatcher and an operator can both read to know a host is finished and safe to remove.

**Who kills the session — a detached controller-side closer, not the executor itself.** The executor runs
*inside* the very tmux session that must be killed, so it cannot be the thing that kills it and then verifies
the result: the moment it `tmux kill-session`s its own session, its own process (and any post-kill verify it
was running) dies with it. So `--host-close` is not a synchronous in-session kill; it is a **handoff to a
detached controller-side closer** — the same pattern the scaffold already uses for the self-wake / idle-cost
backstop (a non-LLM controller-side supervisor that outlives the agent). Mechanically: the executor's
`--host-close` writes a `host_state=closing` marker (so the intent survives even if the executor's last turn
is cut short), then **spawns a detached closer process outside its own session and returns**; that closer —
not the executor — does the bounded wait, kills the tmux session, prunes, and writes the final
`host_state=closed` marker. The kill thus happens from a process that survives it.

This makes the attestation split clean and honest. The executor attests only the **pre-kill** half it can —
the `closing` marker is written and the detached closer was launched as the last Close action — never "I
watched my own session die." The **post-kill** confirmation (session actually gone, `closed` marker written)
belongs to the detached closer and to any operator/dispatcher read of the marker afterward. The executor's
CHECKLIST evidence is therefore "`closing` marker present + closer launched," which matches the close
self-audit rule (verify state by inspection, not memory) without asking the executor to inspect a process it
just terminated.

To make the terminal marker actually *load-bearing* — the signal that a host is safe to remove — the
dispatcher's destructive and listing paths must consult it, not just the existing clean+pushed guard.
`--host-close` makes the marker the single source of "this host is terminal"; in turn `--list` shows
**terminal vs running** (so an operator sees at a glance what is reap-eligible), `--reap-all` and any TTL sweep
target **only terminal-marked** hosts (a still-running executor's worktree is never swept), and `--reap <exp>`
on a host with no terminal marker **warns / refuses unless `--force`** (so an operator can't accidentally reap
a live run, while keeping `--force` as the rescue hatch). The clean+pushed guard stays as the *destructive*
safety floor; the marker is the *liveness* gate layered above it.

For this to work for a *zero-context* executor — which reads ONLY the brief + scaffold — the host-close
handle must be **surfaced on a discoverable launch-metadata surface, not buried instance-side and not passed
as tmux seed text** (seed text isn't part of the brief+scaffold a zero-context executor is contracted to read,
and relying on it reintroduces exactly the implicit-context fragility dispatch exists to kill). The handle
names: the exact command to run at Close, the host-state marker's path and schema, the evidence that proves
the close was initiated, and explicit **N.A. semantics** for substrates with no persistent dispatch host (a
Codex thread/watcher that simply exits).

**Who writes the handle, and when** (Finding-driven, load-bearing): the handle is **launch metadata written
by the dispatch step at spawn time** — it is a property of *how this executor was launched*, known only to the
dispatcher, not part of the science the designer locked. Crucially it must **not mutate the locked `START.md`
after clearance**: the `DESIGN.md` + `START.md` + `CHECKLIST.md` seam is frozen at handoff, and a
post-clearance edit to it would violate the locked-brief contract and reopen the very gap the freeze closes.
So the dispatcher writes the handle to a **separate, committed launch-metadata surface in the worktree**
(e.g. a `DISPATCH.md` / launch-metadata file the executor reads alongside the brief), authored once by the
dispatch step before the executor's first turn — never the executor editing its own brief, never ephemeral
seed text. The `CHECKLIST` template references that surface as the place the host-close handle lives. The
*contract* (an obligation + a discoverable, dispatcher-authored handle) lives in the product; the *values* of
the handle (the concrete `--host-close` command, the marker path) are filled in by the instance/substrate. And because the CHECKLIST template is the scaffold's canonical forcing function for Close
gates, the contract is anchored there: a universal `[BLOCK]` checklist gate requiring terminal
host-marker / host-closed evidence (or an explicit N.A. for no-persistent-host substrates), so the host-close
can't be silently skipped the way buried prose gets skipped.

**The gate is capability-gated, never substrate-blind.** The `[BLOCK]` checklist gate must key off *whether a
`dispatch_host_close` handle is present on the launch-metadata surface*, not fire unconditionally. It blocks
**only when a handle is wired** (then the executor must run it and show the marker evidence); it resolves
**N.A.** when no handle is present — which covers both the permanent no-persistent-host case (a Codex
thread/watcher that just exits) **and** the transitional window where a substrate with a persistent host has
not yet shipped its handle. This is the ordering safety property: the product gate is *blocked-by* the
instance handle, so landing the product contract first can never strand a fresh executor with an obligation it
has no command to satisfy — absent a handle, the gate is N.A., and the day the instance wires `--host-close`
the same gate flips to active for that substrate with no further product change. (Concretely: a Claude
executor between product-land and instance-land sees no handle in its launch metadata → N.A.; once
`dispatch-claude.sh --host-close` ships and the dispatch step writes the handle into the launch-metadata file,
the gate becomes a real `[BLOCK]`.)

The load-bearing decision is **"auto-mark reapable, not auto-`rm -rf` on completion."** A finished executor is
not a *reviewed* executor: the worktree may hold the failed logs, partial artifacts, or exact debug state a
human needs to understand a bad run, and "the run exited" is not "the result was seen." So deletion stays
operator-triggered (the existing `--reap`), or at most TTL-gated behind the dispatcher's existing strong
guards (clean tree, branch pushed at HEAD). What the completion event *does* do is stop the bleeding: hand the
idle-session kill to the detached closer and write the host-state marker, so the host stops consuming a session slot and
announces itself as reap-eligible, while its evidence stays on disk and on the branch until a human clears it.
This is strictly safer than #30's original "kill tmux + `rm -rf`," which would nuke an unreviewed worktree the
moment the executor stopped.

The split between the **product** and the **instance** is the second load-bearing decision. The product repo
(`automated-researcher`) gets the **substrate-neutral dispatch-host lifecycle contract** — a clause in
`run-experiment`'s Close step, a matching line in the `design-experiment` dispatch contract, and a `[BLOCK]`
gate in the `CHECKLIST` template that references the **dispatcher-authored launch-metadata surface** as the
home of the `dispatch_host_close` handle (not a post-clearance edit of the locked `START.md`) — stating that
the dispatch host (the session/launch dir the executor ran in), like the GPU and the self-wake, must be
brought to a terminal state at Close: the executor runs its launch-metadata host-close command, which writes a
host-state marker and hands off the idle-session kill to a detached closer; *deletion* is a separate
operator/TTL step that
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
  dispatch contract, and a `[BLOCK]` host-close gate in the `CHECKLIST` template that points at the
  dispatcher-authored launch-metadata surface for the `dispatch_host_close` handle. Because this changes the
  `experiment-lifecycle` runtime protocol (a new
  Close obligation + a new required checklist gate), the product child **bumps
  `plugins/experiment-lifecycle/.claude-plugin/plugin.json` and adds a `CHANGELOG.md` entry** per the AGENTS.md
  "version bump on every behavior change" rule — it is not a no-op doc edit. No CI logic moves; the
  install/discovery surface is unchanged beyond the manifest version. This design PR itself is
  `proposals/*.md` only.
- **Instance (this box), where the mechanism lives:** `dispatch-claude.sh` gains the non-destructive
  `--host-close` verb (write `closing` marker → spawn detached closer that kills the session, writes `closed`, and prunes, reusing the
  existing clean+pushed guards) **and marker-aware listing/deletion** — `--list` distinguishes terminal vs
  running, `--reap-all`/TTL target only terminal-marked hosts, and `--reap <exp>` warns/refuses without a
  marker unless `--force`. `new-claude.sh` is unaffected beyond what the executor calls at Close.
  `run-experiment`'s executor gains a final host-close action. These land as the `ready` children, not in this
  design PR.
- **Risk profile:** low. The destructive operation (`--reap`/`rm -rf`) is unchanged and stays behind its
  existing guards and an explicit operator/TTL trigger; the new automatic behavior is only *killing an idle
  session* and *writing a status file*, both reversible and non-destructive (the worktree and its pushed
  branch survive). The persistent `~/claude-N` fleet workers are explicitly out of scope — they are
  long-lived and never reaped by this path.

## Rollout + rollback

- **Sequencing:** this is a two-phase design PR (doc-only). On merge it spawns `ready` children: (1) the
  product contract — the `run-experiment` Close clause, the `design-experiment` dispatch-contract line, the
  `CHECKLIST`-template `[BLOCK]` gate referencing the launch-metadata `dispatch_host_close` handle, **plus the
  experiment-lifecycle version bump + CHANGELOG entry**; (2) the instance non-destructive
  `dispatch-claude.sh --host-close <exp>` verb (write `closing` marker → spawn detached closer that kills the
  session + writes `closed` + prunes, reusing the existing clean+pushed guards, never deleting the worktree),
  the dispatch step authoring the launch-metadata handle at spawn, **plus the marker-aware `--list`/`--reap`/`--reap-all`
  semantics**; (3) the `run-experiment` executor's final
  host-close action that invokes (2) at Close. The product contract (1) lands first **safely** precisely
  because its gate is capability-gated (above): with no handle wired yet, every existing executor — Claude
  included — resolves the gate N.A., so (1) never strands a fresh executor with an unsatisfiable `[BLOCK]`. The
  gate only turns active for a substrate once (2)+(3) ship its `--host-close` verb and write the handle into
  that substrate's brief — so the destructive obligation arrives *with* the command that satisfies it, never
  before. The instance pieces (2)/(3) depend on the contract wording from (1) but are otherwise self-contained.
- **Rollback:** the product change is a doc clause — revert the squash commit through the normal lifecycle.
  The instance completion path is opt-in by construction: if it misbehaves, the executor simply stops calling
  the host-close at Close and the world reverts to today's manual-reap behavior, with no data at risk because
  deletion was never automatic. The standing escape hatch is unchanged: `dispatch-claude.sh --reap <exp>` /
  `--reap-all` for manual cleanup, `--list` to see what's outstanding.
