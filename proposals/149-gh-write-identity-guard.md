# Proposal: Enforce engineer-identity for agent GitHub writes structurally (#149)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> This is a **design-only** deliverable (two-phase). It decides the seam and decomposes the work into
> `ready` child issues; no implementation lands in this PR.

## Problem

When an agent on this box runs a bare `gh issue create` or `gh pr comment`, the write is silently
authored by the **human owner account** (`antondelafuente`) instead of the engineer bot identity
(`claude-code-engineer[bot]` / `codex-engineer[bot]`). The rule that agent writes must carry the bot
identity — "the agents are the engineers" — lives only as prose in the ship-change skill and
`AGENTS.md`. Prose is skippable, so under reflex an agent reaches for plain `gh` and mis-authors. This
already happened: issue #147 was owner-authored by mistake and had to be recreated as #148. #149 is the
same failure class — a convention that is not structurally enforced gets skipped.

The root cause is concrete and was confirmed by the investigation on this issue: the instance auth loader
`~/.aar-github-auth-env.sh` exports an **owner-scoped, write-capable `GH_TOKEN`** into every agent shell.
That owner token is the ambient default for *every* `gh` call. `wf.sh` is the only thing that flips
identity — it injects a freshly-minted engineer installation token into `GH_TOKEN` for the specific call
(`gh_author` does `GH_TOKEN="$tok" gh …`). So anything routed through `wf.sh` is bot-authored, and
anything that bypasses `wf.sh` is owner-authored. Nothing prevents the bypass.

## Approach

**Make the ambient `GH_TOKEN` read-only, so a bare `gh` write fails closed.** Stop exporting a
write-capable owner token into agent shells; export a token that can *read* (issues/PRs/contents/metadata)
but cannot *mutate*. Reads (`gh … view/list`, `gh api` GETs) keep working ambiently. Any bare mutating
`gh` (`issue/pr create`, `*comment`, `pr review/merge`, `issue edit/close`, `api -X POST/PATCH/PUT/DELETE`)
now gets an HTTP 403 from GitHub — a hard, structural failure the agent cannot reflex past. The only path
that can write is the engineer path, because `wf.sh` mints its own write-capable engineer installation
token per call and never relies on the ambient one. This is the seam the product owner leans toward, and
on inspection it is the cleanest: it removes the dangerous capability at the source rather than trying to
intercept every shape of a `gh` invocation after the fact.

This is deliberately a **defense-in-depth pair**, not a single mechanism:

1. **Capability layer (the structural guarantee, instance-owned).** The ambient credential agent shells
   receive is read-only. This is the load-bearing change — it is what makes the bypass *impossible*, not
   merely discouraged. It is instance configuration (the actual token + the auth-env file are
   `~/.config`/instance-level, never product code), so the product cannot ship the credential itself; the
   product ships the **contract** ("the ambient agent credential MUST be read-only; writes go through the
   engineer token path") plus an instance-init/doctor check that verifies an install satisfies it.

2. **Ergonomic layer (the fail-*helpful*, product-owned).** A read-only token fails with a raw GitHub
   403, which is correct but unhelpful — it doesn't tell the agent *what to do instead*. So we add a thin
   `gh` write-guard (a PATH-shim wrapper, or equivalently a shell function) that recognizes a mutating
   `gh` subcommand and, instead of letting it hit GitHub, exits non-zero with a directed message: "GitHub
   writes go through `wf.sh issue|comment <family>` (engineer identity) — see ship-change." The guard is
   an **ergonomic redirect, not the security boundary**: even if the guard is missing, bypassed, or
   PATH-shadowed, the read-only capability layer still fails the write closed. The guard must:
   (a) pass reads through untouched;
   (b) never intercept `wf.sh`'s own engineer-token `gh` calls — see the explicit bypass contract below,
   because the current engineer path only swaps `GH_TOKEN`, which a wrapper *cannot* distinguish from any
   other token-backed `gh` call, so "no engineer token in the environment" is NOT a usable signal and must
   not be relied on;
   (c) honor an explicit, logged escape hatch for genuine owner/admin maintenance — a **separate
   guard-specific** override flag (e.g. `WF_GH_ALLOW_OWNER_WRITE=1`), NOT a reuse of
   `WF_ALLOW_AMBIENT_IDENTITY` (which already controls a different thing: `wf.sh`'s own engineer-identity
   *fallback* semantics; overloading it would couple two unrelated behaviors). The override only suppresses
   the guard's redirect; it does **not** by itself grant write capability — that still requires the
   operator to have sourced an elevated owner token (see Escape hatch). The two are independent and both
   are required for an owner write.

   **The `wf.sh`↔guard bypass contract (load-bearing — resolves the HIGH).** Because a `GH_TOKEN` swap is
   invisible to a PATH wrapper, `wf.sh` must mark its own internal `gh` calls with an explicit signal the
   guard recognizes and lets straight through to the real `gh`. Child #2 owns BOTH halves of this contract
   as one atomic unit: (i) `wf.sh`'s `gh_author`/`gh_push` (and any other internal `gh` call site) set a
   scoped marker — either an env var like `WF_GH_INTERNAL=1` exported only around the minted-token call, or
   by invoking a resolved real-`gh` path directly — so the call is unambiguously the engineer path; and
   (ii) the wrapper passes a call bearing that marker through untouched and never recurses. The child's
   `.aar-ci` behavior smoke MUST assert both directions: a bare mutating `gh` is blocked, AND a
   `wf.sh`-routed write (carrying the marker) is allowed. This is the explicit guard contract on the
   `wf.sh` call sites the design review flagged.

**Escape hatch (owner/admin maintenance).** Real owner work still exists (editing branch protection,
repo settings, an emergency merge-rule relax). That path is explicit and logged, not ambient, and is the
conjunction of **two independent** acts, neither sufficient alone: (1) the operator **sources a separate
elevated owner token** for the duration of the maintenance — this is what actually grants write capability
(the read-only ambient token can never write, so a guard override alone cannot make it write); and (2) if
the maintenance goes through a path the guard would intercept, the operator sets the **guard-specific
override** (`WF_GH_ALLOW_OWNER_WRITE=1`) so the wrapper emits a terminal note + best-effort trail and lets
the call reach the (now write-capable) `gh`. The default agent shell holds neither, so it never writes as
the owner by reflex. This *improves* the audit story — elevation becomes a visible, deliberate two-step
act instead of the silent default.

**Reuse, don't fork.** The engineer write path already exists and is the one canonical implementation
(`WF_ENGINEER_TOKEN_CMD_*` → `gh_author`/`gh_push` in `wf.sh`, surfaced as `wf.sh issue|comment`). This
design adds **no parallel write mechanism**. It only (a) demotes the ambient credential's scope
[instance], (b) adds a directed-error guard around bare `gh` [product wrapper + instance install], and (c)
adds a `doctor`/init assertion that the ambient credential is in fact read-only so a misconfigured install
is caught loudly [product].

### Why a `needs-design` (not a quick shim)

The change touches **every** agent's `gh` usage (blast radius across all sessions), it must cleanly
separate reads from writes and the engineer path from the owner path *without breaking `wf.sh` itself*,
it must land an audited escape hatch, and it straddles the product/instance boundary (the capability lives
in instance config; the contract + guard + doctor check are product). That is a design + cross-family
review, which is exactly what this PR is.

### Decomposition into children (what this design spawns)

A deliberate split between **product `ready` ship-change children** (land in this repo, generic, reusable
by any consumer) and an **instance rollout task** (mutates this deployment's `~/.config` credentials, is
NOT product code and must NOT be modeled as a product ship-change child — Finding 2). The product cannot
ship a consumer's credential; it ships the *contract* + the *detector* + the *guard*, and the instance
applies the capability change to itself.

**Product `ready` children (ship-change runs in this repo, each references #149):**

1. **Product `gh` write-guard wrapper + the `wf.sh`↔guard bypass contract + `.aar-ci` behavior smoke.**
   The wrapper classifies read-vs-write `gh` subcommands, passes reads through, and on a write emits the
   directed "use `wf.sh`" error. Bundled (atomically, because the HIGH ties them together): the `wf.sh`
   call-site change that marks internal engineer-token `gh` calls with the recognized bypass signal, and a
   behavior smoke asserting **both** directions (bare write blocked; `wf.sh`-routed write allowed). Owns
   the guard-specific override flag.
2. **Read-only-ambient detector: `wf.sh doctor` check + a `.aar-ci` fake-`gh` smoke (product).** Defines
   and implements the *exact* test that an ambient credential is read-only (Finding 3). The detection is a
   **non-destructive permission introspection** — read the token's effective permissions via
   `gh api -i` response headers / the installation or fine-grained-PAT permission surface, or fall back to
   a **controlled, self-targeted canary** that attempts a guaranteed-idempotent no-op write and expects a
   403 (never a mutation that lands). The fake-`gh` smoke supplies a stub `gh` that reports read-only vs
   write-capable and asserts `doctor` distinguishes them. Fails loudly if an install still hands agents a
   write-capable ambient token, so a regression/rollback is caught instead of silently re-opening the
   footgun.
3. **Codify the contract across ALL its canonical homes — one canonical reference, no duplicate live
   contracts (product, doc-only; Finding 5).** Add the rule to `AGENTS.md` ("the ambient agent GitHub
   credential MUST be read-only; all writes go through the engineer token path"), next to the existing
   engineer-identity rule, AND update every point-of-use surface that currently advertises a write-capable
   ambient `GH_TOKEN` / owner-admin write path so they don't become a second, stale contract:
   ship-change `SKILL.md` ("Auth: … export `GH_TOKEN`"), `RUNBOOK.md` (the `GH_TOKEN` rotation note that
   says "repo: contents + pull_requests"), and any help/plugin metadata. Prefer a single canonical
   statement that the others reference over duplicated prose.

**Instance rollout task (NOT a product ship-change child — applied to this deployment directly):**

- **Demote this instance's ambient agent credential to read-only + wire the separate elevated owner
  token** in the auth-env loader / `~/.config`. This is the load-bearing capability change, but it is
  instance-owned credential config; it is tracked as an instance rollout task (and gated on product
  children 1–2 being available), not as a product `ready` issue. The product child #2's doctor check is
  what verifies this rollout actually took effect on any given install.

Sequencing: product children 1–3 land first (the guard, the detector, the contract). The instance then
performs the capability demotion and runs `wf.sh doctor` to confirm the ambient token is read-only and a
`wf.sh`-routed write still authors as the bot. The capability layer is what delivers the structural
guarantee; the product children make it enforceable, detectable, and documented.

## Alternatives considered

- **`gh` PATH-shim/wrapper as the *primary* (sole) mechanism.** Rename the real binary, drop a wrapper
  that errors or token-swaps on writes. Rejected as the *security boundary* because a wrapper is an
  interception layer, not a capability removal: it must enumerate every mutating subcommand shape
  (including `gh api -X …`, aliases, future subcommands), it can be PATH-shadowed or bypassed by calling
  the real binary directly, and it risks recursing into `wf.sh`'s own `gh` calls. It remains valuable as
  the **ergonomic layer** (child #2), but the *guarantee* must come from the read-only capability, which
  no enumeration gap or PATH trick can defeat.

- **Keep it as prose + reviewer vigilance.** Status quo. Rejected — that is exactly the #147/#148/#149
  failure class. The whole point of the issue is that skippable prose gets skipped under reflex.

- **PreToolUse Bash hook that inspects the command string.** A harness hook could regex the `gh …`
  command and block writes centrally. Rejected as primary: it is harness-specific (doesn't protect a
  plain shell, cron job, or a script the agent writes), it parses an unbounded command-string surface
  (quoting, pipelines, `env GH_TOKEN=… gh …`), and it is instance/harness config rather than a portable
  product guarantee. The capability layer protects *every* caller regardless of harness. (A hook could be
  added later as an extra ergonomic layer but is not in this design.)

- **Per-shell `gh` shell function only.** Per-shell and missable (not inherited by scripts/subshells/new
  shells), so it fails the "structural, not skippable" bar on its own. Subsumed by the wrapper child if an
  install prefers the function form, but it is not the guarantee.

## Blast radius

- **Every agent shell's `gh` behavior changes**: bare writes start failing closed (intended). Reads are
  unaffected. `wf.sh`-routed writes are unaffected (they carry the engineer token). The one workflow that
  must keep working untouched is the SWE pipeline itself — verified by the design constraint that the
  guard never intercepts an engineer-token call and that `wf.sh` never depends on the ambient token for a
  write.
- **Product surface touched (in the three `ready` children):** a new `gh` write-guard wrapper + its
  `.aar-ci` behavior smoke, a `wf.sh` bypass marker at its internal `gh` call sites, a `wf.sh doctor`
  read-only-ambient check + its fake-`gh` smoke, and the contract codified across `AGENTS.md` +
  ship-change `SKILL.md`/`RUNBOOK.md`/metadata. No change to the existing engineer-token implementation —
  it is reused as-is.
- **Instance surface touched (the instance rollout task, not product code):** the auth-env loader stops
  exporting a write-capable ambient token and instead exports a read-only one; a separate elevated owner
  token is wired for explicit maintenance; the wrapper is installed on PATH ahead of the real `gh`. These
  are `~/.config`/instance-level — owned by the consuming instance, never product code.
- **Failure mode if mis-rolled-out:** if an install forgets to demote the ambient token, the footgun
  persists silently — which is exactly why the product detector (child #2, the `wf.sh doctor` read-only
  check) exists, to fail loudly on a still-write-capable ambient credential on any install.

## Rollout + rollback

- **Staged.** Land the product children first: #1 (guard wrapper + `wf.sh` bypass contract + smoke), #2
  (read-only detector / doctor check), #3 (contract across canonical homes). Then perform the instance
  rollout (demote the ambient token to read-only + wire the elevated owner token) and confirm via
  `wf.sh doctor`: reads still work, a bare `gh issue create` now 403s, and `wf.sh issue …` still authors
  as the bot.
- **Escape hatch / rollback for a wedged state.** If the read-only demotion ever blocks legitimate
  owner/admin work, the operator performs the explicit two-step (source the elevated owner token **and**
  set the guard-specific `WF_GH_ALLOW_OWNER_WRITE=1`); the guard emits a terminal note. Full rollback is a
  one-line instance revert: re-export the write-capable token in the auth-env loader (restores the prior,
  footgun-bearing behavior) — reversible, instance-local, no product change needed. The product wrapper is
  removable from PATH independently of the capability layer, and the doctor check will then report the
  ambient token as write-capable (loud), which is the intended signal that rollback happened.
- **No data migration; no GPU cost; no API/data-gen cost.** This is a credentials-scope + small-wrapper
  change. The only operational cost is minting the read-only and elevated tokens on the instance.
