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
   PATH-shadowed, the read-only capability layer still fails the write closed. The guard must (a) pass
   reads through untouched, (b) never intercept `wf.sh`'s own `gh` calls — those run with the engineer
   token injected, so the guard keys off "is the ambient owner/read-only token in use" (i.e. no engineer
   token in the call's environment) and must not recurse when `wf.sh` shells out to `gh`, and (c) honor an
   explicit, logged escape hatch for genuine owner/admin maintenance, mirroring the existing
   `WF_ALLOW_AMBIENT_IDENTITY` override (an env flag that, when set, lets a write through and emits a
   terminal note + best-effort trail).

**Escape hatch (owner/admin maintenance).** Real owner work still exists (editing branch protection,
repo settings, an emergency merge-rule relax). That path is explicit and logged, not ambient: the
operator sources a separate elevated owner token for the duration of the maintenance, or sets the
override flag. The default agent shell never holds write capability. This *improves* the audit story —
elevation becomes a visible, deliberate act instead of the silent default.

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

### Decomposition into `ready` children (what this design spawns)

1. **Demote the ambient agent credential to read-only + add the elevated-owner escape path** (instance
   config: the auth-env loader / `~/.config`). The structural guarantee. Includes minting/scoping the
   read-only token and a separate, explicitly-sourced elevated owner token for maintenance.
2. **Product `gh` write-guard wrapper + its instance install** (the ergonomic redirect): a small wrapper
   that classifies read-vs-write `gh` subcommands, passes reads through, and on a write emits the directed
   "use `wf.sh`" error unless an engineer token is present (the `wf.sh` path) or the logged override is
   set. Includes the non-recursion guarantee for `wf.sh`'s own `gh` calls and a `.aar-ci` behavior smoke.
3. **`wf.sh doctor` + instance-init assertion that the ambient credential is read-only** (product): a
   check that fails loudly if an install still hands agents a write-capable ambient token, so a
   regression/rollback is caught instead of silently re-opening the footgun.
4. **Codify the contract in `AGENTS.md`** (product): "the ambient agent GitHub credential MUST be
   read-only; all writes go through the engineer token path," promoting #149's principle from
   ship-change-skill prose into the constitution next to the existing engineer-identity rule. (Small,
   doc-only `ready` child.)

The children are sequenced so the **capability layer (1)** can land first and independently delivers the
structural fix; (2)/(3)/(4) harden ergonomics, detection, and the written contract. Each ships as a normal
single-phase ship-change run referencing #149.

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
- **Product surface touched (this lands product code in the children):** a new `gh` write-guard wrapper +
  its `.aar-ci` behavior smoke, a `wf.sh doctor` assertion, and an `AGENTS.md` contract line. No change to
  the existing engineer-token implementation — it is reused as-is.
- **Instance surface touched:** the auth-env loader stops exporting a write-capable ambient token and
  instead exports a read-only one; a separate elevated owner token is wired for explicit maintenance; the
  wrapper is installed on PATH ahead of the real `gh`. These are `~/.config`/instance-level, never product
  code.
- **Failure mode if mis-rolled-out:** if an install forgets to demote the ambient token, the footgun
  persists silently — which is exactly why child #3 (the doctor/init assertion) exists, to fail loudly on
  a still-write-capable ambient credential.

## Rollout + rollback

- **Staged.** Land child #1 (capability) first on this instance; confirm reads still work and a bare
  `gh issue create` now 403s while `wf.sh issue …` still authors as the bot. Then land #2 (wrapper, with
  its smoke), #3 (doctor assertion), #4 (AGENTS.md contract).
- **Escape hatch / rollback for a wedged state.** If the read-only demotion ever blocks legitimate
  owner/admin work, the operator sources the elevated owner token (explicit, logged) for that action; the
  override flag (mirroring `WF_ALLOW_AMBIENT_IDENTITY`) lets a single guarded write through with a
  terminal note. Full rollback is a one-line instance revert: re-export the write-capable token in the
  auth-env loader (restores the prior, footgun-bearing behavior) — reversible, instance-local, no product
  change needed. The product wrapper is removable from PATH independently of the capability layer.
- **No data migration; no GPU cost; no API/data-gen cost.** This is a credentials-scope + small-wrapper
  change. The only operational cost is minting the read-only and elevated tokens on the instance.
