# Proposal: Two-track skill-staleness fix — decomposition (#66)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> **This is a design-only PR.** Its deliverable is an *approved decomposition*, not implementation. No
> scaffold behavior changes here; the follow-up issues listed below are filed only after this is accepted.

## Problem

Long-running AAR sessions silently run **stale** skills after edits to the `aar-skills` source — no error,
just old behavior. The mechanism differs by substrate, but the root cause is a single thing: **every
consumer runs a *copy* of the source, and copies go stale silently.**

- **Claude Code AARs** read skills from a version-keyed plugin **cache** (`~/.claude/plugins/cache/`). The
  cache key is the `plugin.json` `version`; pushing commits without bumping it is a no-op (per the Claude
  Code plugin docs, cited in #42). Refresh requires bump → `plugin update` → `/reload-plugins`.
- **Codex AARs** read skills from `~/.codex/skills/`. Verified 2026-06-18: these are **real copied files,
  not symlinks** (`run-experiment`, `design-experiment`, `gpu-job`, `verify-claims` all COPY). The README
  *prescribes* symlinks (`ln -s ~/aar-skills/... ~/.codex/skills/...`) which would be always-live, but
  reality drifted to copies. Same failure class, no version number involved.

**Live evidence the problem is real right now:** `installed_plugins.json` pins `aar-engineering` to commit
`349a8e7`, while `origin/main` is `179eb6f` — the very next commit, which is the #60 author-identity fix.
So this fleet's *cached* `ship-change` is one commit stale and missing that fix. (We sidestep it for this
PR by running `wf.sh` from the live source tree.)

#42 captured only the Claude half. This decomposition generalizes it to both substrates and splits the
work along the boundary that actually matters.

## Approach

**Unifying principle: on-box consumers should *reference* the live source; only off-box consumers should
run *versioned copies*.** Everything on this box sits next to `~/aar-skills`, so the fix for the entire
current fleet is to stop copying and point at source. The version-bump/cache machinery is only needed
where there is no local source tree to point at.

This yields two tracks, divided by **where the consumer runs**:

### Track 1 — point on-box sessions at the live source *(do now)*
The current fleet (all `claude-N` and Codex AARs on this box) reads source directly; "update everyone"
collapses to `git pull` in `~/aar-skills` (+ a reload for already-running Claude sessions).
- **Claude:** launch with `--plugin-dir ~/aar-skills/plugins/<plugin>` for each of the four aar-skills
  plugins (`gpu-job`, `verify-claims`, `experiment-lifecycle`, `aar-engineering`) — reads source in-place,
  bypasses the cache; `/reload-plugins` then picks up SKILL.md edits live.
- **Codex:** restore the README-prescribed symlinks so `~/.codex/skills/X` → live source.
- **Caveat (does not fall out of `--plugin-dir`):** `--plugin-dir` fixes how a session resolves a plugin's
  own *SKILL.md*, but **cross-plugin helper composition has a separate resolution order.** `wf.sh` resolves
  the `verify-claims` helper from installed plugin-cache / skill-installs *first*, with the in-tree source
  only as a fallback (`wf.sh` ~L84–90). So `ship-change → verify-claims` can still execute a stale installed
  copy even in a source-referencing session. Closing the staleness loop for the on-box fleet therefore
  requires making helper discovery source-first too — pulled out as **FU-1b**.

### Track 2 — versioned-copy currency for off-box consumers *(later)*
Remote GPU pods, Codex-on-web, and eventual external marketplace installs have **no local source tree** to
reference, so they must consume a published, versioned copy. The discipline there is: auto-bump the plugin
version on merge (the cache key that forces a refresh) + a defined way for an off-box AAR to pull current
skills at provision time.

### The boundary between the tracks
**On-box vs off-box** — equivalently, *reference-the-source* vs *consume-a-versioned-copy*. Track 1 is
correct **iff** the consumer has `~/aar-skills` on local disk; Track 2 covers every consumer that does not.
A session is never in both: it either references source or pulls a copy.

### Sequencing & dependencies
- **Track 1 first** — it fixes the staleness biting the fleet today and is small. FU-1 (Claude SKILL.md via
  `--plugin-dir`) and FU-2 (Codex symlinks) are independent and parallel; **FU-1b (source-first helper
  discovery) is required alongside FU-1** — FU-1 alone leaves the `ship-change → verify-claims` composition
  on a stale path. FU-3 (fleet-update command) composes them.
- **Track 2 later** — independent of Track 1, lower urgency (no off-box AAR currently depends on fresh
  skills mid-run). FU-4 and FU-5 can be deferred without blocking Track 1.
- **Independent of this work:** #65 (rename `proposals/`→`designs/`) and #50 (design-PR gate). No ordering
  constraint either way.

### Follow-up issues to create after approval
*(each independently actionable; each links back to this merged design doc + PR)*

**Track 1 (now):**
- **FU-1 — Claude launcher `--plugin-dir` for the on-box fleet.** Extend `new-claude.sh` to pass
  `--plugin-dir` for each aar-skills plugin so launched sessions read source in-place. Verify `/reload-plugins`
  hot-reloads SKILL.md edits without restart. (Caveat: `--plugin-dir` is set at launch, per-session.)
- **FU-1b — Make cross-plugin helper discovery source-first / `--plugin-dir`-aware.** Fix `wf.sh`'s helper
  resolution (~L84–90) so a source-referencing session composes against the *source* `verify-claims`, not a
  stale installed copy. Acceptance test must verify the `ship-change → verify-claims` *composition* runs
  current code — not only that a single SKILL.md hot-reloads. (Closes the gap F1 surfaced; without it FU-1
  leaves a stale path.)
- **FU-2 — Restore + keep Codex skill symlinks.** Replace the copied `~/.codex/skills/*` dirs with symlinks
  into `~/aar-skills/...`; add an idempotent linker (or provision step) so they stay symlinks and new skills
  get linked. Confirm whether Codex hot-reloads a symlinked SKILL.md mid-session or only at session start.
- **FU-3 — `update-fleet` command.** One shot: `git pull` in `~/aar-skills` → broadcast `/reload-plugins`
  to **all live AAR sessions, discovered — not assumed.** Per AGENTS.md (#39), session names are not
  guaranteed `claude-N`: there are persistent fleet workers, experiment-named sessions, and ephemeral
  `dispatch-claude.sh` executors (`<exp>-exec-<runid>`). Discover targets via tmux command / remote-control
  metadata (a session running `claude`), with explicit handling for **persistent**, **dispatch**, and
  **in-flight** (mid-turn — queue, don't interrupt) sessions. Makes "propagate to everyone" one action that
  actually reaches everyone.

**Track 2 (later):**
- **FU-4 — Plugin-version currency on merge, reconciled with the `finish` contract.** Off-box consumers
  refresh only when the `plugin.json` `version` (the cache key) increases. This must fit the existing
  contract, not bypass it: `.aar-ci/checks.sh` (~L41–56) **already fails** when a plugin changed but its
  version didn't increase, and `wf.sh finish` (~L497, 546–559) requires a clean committed worktree → runs
  checks → final `--code` → merges the **exact reviewed SHA**. So FU-4 picks one of two reconciled shapes,
  not a naive post-hoc bump:
  (a) **auto-bump as an explicit, committed, pushed step *before* checks + final `--code`** (so the bumped
  version is part of the reviewed SHA that merges); or
  (b) **keep manual bumps** (status quo) and instead **improve the existing check's diagnostic** so a missed
  bump fails loudly and early with the exact remedy.
  The follow-up decides (a) vs (b); the design's requirement is only that auto-bump never lands outside the
  reviewed-SHA/clean-worktree contract.
- **FU-5 — Off-box fleet currency (remote pods / Codex-web).** Define how a consumer with no local source
  tree gets current skills (provision-time pull of a pinned release, or marketplace `plugin update`).
  Likely mostly docs + a provision hook; may be split further or deferred.

### Non-goals
- The `proposals/`→`designs/` rename (#65) — independent change.
- Enforcing design-approval as a blocking gate (#50) — separate.
- A file-watcher / daemon that auto-reloads without an explicit `git pull` + reload — out of scope; we keep
  propagation explicit and operator-triggered.
- Changing what any skill *does* — this is purely propagation/freshness.
- General public-marketplace distribution beyond what the marketplace already provides.

### Risks & open questions
- **`--plugin-dir` semantics need empirical confirmation on the box:** does it fully bypass the cache for
  all skill resolution, and does `/reload-plugins` reliably hot-reload SKILL.md edits without a restart?
  (Docs say yes; verify before relying on it in FU-1.)
- **Cross-plugin helper composition is a distinct staleness path from SKILL.md resolution (F1):** `wf.sh`
  resolves the `verify-claims` helper installed-first/source-fallback, so `--plugin-dir` does not by itself
  make `ship-change`'s review run current code. FU-1b owns this; its acceptance test is composition-level,
  not SKILL.md-level. (This is the exact path that left this session's `aar-engineering` one commit stale.)
- **Per-session nature of `--plugin-dir`:** already-running sessions launched the old way won't benefit
  until recycled — interacts with FU-3 and the fleet-recycle flow.
- **Symlink fragility (FU-2):** the homedir rclone/vault-sync history on this box and in-place file rewrites
  could clobber symlinks. The linker must be idempotent and the sync must not overwrite links.
- **Codex hot-reload unknown:** a symlinked SKILL.md may only be re-read at Codex session start, not
  mid-session — FU-2 must establish this (may still need a session recycle to pick up edits).
- **Track 2 auto-bump churn:** auto-bumping `plugin.json` on merge risks version conflicts and noisy diffs;
  needs a clear bump policy.

### Definition of done (for this decomposition)
This issue is done only when: the design covers both tracks with the on-box/off-box boundary made precise;
the follow-up issue list is agreed; the opposite-family `--scaffold` review **accepts**; the PR **merges**;
and the follow-up issues (FU-1, FU-1b, FU-2, FU-3, FU-4, FU-5) have been **created** from the accepted
design. The first proposal existing is not done.

## Alternatives considered

- **Just bump versions + `plugin update` everywhere (Track 2 only).** Rejected as the *primary* fix: it
  keeps every on-box consumer on a copy and reintroduces the silent-staleness window on every merge. Correct
  only for off-box consumers, where it's unavoidable — hence Track 2, not the whole answer.
- **A file-watcher/daemon that auto-reloads on source change.** Rejected: more moving parts, a background
  process to supervise, and it muddies "what version is the fleet on." Explicit `git pull` + reload keeps a
  single legible currency point.
- **Keep Codex on copies but add a re-copy step on merge.** Rejected: it's strictly worse than the symlinks
  the README already prescribes — more machinery for the same always-live result symlinks give for free.
- **One mega-issue instead of a decomposition.** Rejected: the two tracks have different urgency, different
  blast radius, and different consumers; bundling them would stall the cheap on-box fix behind the optional
  off-box machinery.

## Blast radius

- **Instance (this box):** `new-claude.sh` (FU-1), `~/.codex/skills/*` symlinks + a linker (FU-2), a new
  `update-fleet` helper (FU-3). These are instance tooling, not the shipped product.
- **SWE pipeline / product scaffold:** Track 2's auto-bump (FU-4) touches `wf.sh finish` in the
  `aar-engineering` plugin — a real product-scaffold change, goes through `ship-change` itself.
- **Docs:** README/AGENTS gain the on-box/off-box update model.
- This design PR itself: **docs-only** (adds one `proposals/` file). No code paths change under #66.

## Rollout + rollback

- Each follow-up ships as its own `ship-change` PR; nothing here is big-bang.
- **FU-1 rollback:** drop the `--plugin-dir` args from `new-claude.sh`; sessions fall back to the cache.
- **FU-2 rollback:** the linker is idempotent; reverting is `rm` the symlinks and let the provision restore
  copies (or re-run the linker). Keep a guard so the homedir sync never clobbers a live symlink.
- **FU-4 (Track 2) rollback:** auto-bump is a `wf.sh` step; revert the step and bump manually as today.
- This PR rolls back by reverting the single added doc — zero runtime impact.
