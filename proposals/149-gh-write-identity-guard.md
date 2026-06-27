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

**Make the ambient `gh` credential read-only, so a bare `gh` write fails closed.** The contract is over
the **effective `gh` credential store an agent shell can reach**, not merely the exported `GH_TOKEN`: `gh`
resolves auth from `GH_TOKEN`/`GITHUB_TOKEN` *and* from a stored `gh auth login` credential
(`hosts.yml`/keyring), and `wf.sh`'s own `need_ambient_gh` falls back to `gh auth status`. So the
guarantee is: **no write-capable owner credential is reachable by an agent shell through any of those
paths** — the exported token is read-only *and* no write-capable stored owner `gh auth` credential is
present (or it is isolated out of the agent shell's `GH_CONFIG_DIR`).

**The same closure applies to Git's own credential surface.** A `git push` to the GitHub
remote can authenticate via a stored Git credential helper (an owner HTTPS token in
`~/.git-credentials` / the OS keychain) or an owner SSH key — entirely outside `GH_TOKEN` and `gh auth`.
So the guarantee extends: an agent shell must hold **no write-capable owner Git credential for the GitHub
remote** either (read-only clone/fetch stays fine), and the engineer push path (`git_push_author`) must
**force a one-shot engineer credential** — a tokenized remote URL or an engineer askpass/credential-helper
scoped to that single push — rather than assume `GH_TOKEN` alone governs `git push`. The rollout, the
doctor check, and the smoke all extend to this Git surface, not just the `gh` surface.

Export a token that can *read*
(issues/PRs/contents/metadata) but cannot *mutate*. Reads (`gh … view/list`, `gh api` GETs) keep working
ambiently. Any bare mutating `gh` (`issue/pr create`, `*comment`, `pr review/merge`, `issue edit/close`,
`api -X POST/PATCH/PUT/DELETE`) now gets an HTTP 403 from GitHub — a hard, structural failure the agent
cannot reflex past. The only path that can write is the engineer path, because `wf.sh` mints its own
write-capable engineer installation token per call and never relies on the ambient one. This is the seam
the product owner leans toward, and on inspection it is the cleanest: it removes the dangerous capability
at the source rather than trying to intercept every shape of a `gh` invocation after the fact.

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

   **The `wf.sh`↔guard bypass contract (load-bearing — resolves the original HIGH).** Because a `GH_TOKEN`
   swap is invisible to a PATH wrapper, `wf.sh` must mark its own internal `gh` calls with an explicit
   signal the guard recognizes and lets straight through to the real `gh`. Child #1 owns BOTH halves of
   this contract as one atomic unit: (i) **ALL** of `wf.sh`'s internal `gh` invocations are routed through
   **one** marked real-`gh` helper that sets a scoped marker (e.g. `WF_GH_INTERNAL=1` around the call, or a
   resolved real-`gh` path) — not just `gh_author`. Today `wf.sh` has **tokened `gh` calls outside
   `gh_author`** (the review POST and PR-comment paths, the classify and finish paths all do
   `GH_TOKEN="$tok" gh …` directly); each of those would break under a naive wrapper if left unmarked, so
   the child must funnel **every** internal `gh` call site through the single marked helper. A **static
   check** (a `.aar-ci` lint / grep gate) fails the build on any remaining unmarked `GH_TOKEN=… gh` /
   `gh …` invocation in `wf.sh`, so a future call site can't silently regress the bypass. And (ii) the
   wrapper passes a marked call through untouched and never recurses. The behavior smoke exercises **the
   review / classify / finish paths under the wrapper**, not only `gh issue/comment`, so the full pipeline
   is proven to survive the guard.

   **The contract MUST also cover the authenticated-`git push` credential-helper path.** `wf.sh`'s
   `gh_push`/`git_push_author` runs `GH_TOKEN="$tok" git push …`, and `git push` over HTTPS can invoke
   `gh` itself as a **credential helper** (`gh auth git-credential`). A naive PATH wrapper around `gh`
   would therefore intercept the credential-helper invocation mid-push and break the engineer push. So the
   wrapper must pass through a **narrow whitelist** of the *non-mutating* `gh auth` forms the workflow
   needs — `gh auth git-credential`, `gh auth status`, `gh auth token` — and **must NOT blanket-pass all
   `gh auth …`** (`gh auth login`, `gh auth refresh`, `gh auth setup-git`, `gh auth logout`
   *mutate the stored credential* and would re-open exactly the stored-credential path the capability layer
   removes). Those credential-mutating `gh auth` subcommands are guarded like any other write — blocked
   with the directed message, available only via the elevated maintenance path. The `.aar-ci` behavior
   smoke MUST exercise the **full engineer push path end-to-end** (a `wf.sh`-routed push succeeds through
   the wrapper) and assert that `gh auth login`/`refresh`/`setup-git` are blocked, not only that direct
   `gh issue/comment` writes are. Both directions asserted: a bare mutating `gh` (and a credential-mutating
   `gh auth`) is blocked; a `wf.sh`-routed write **and push** (carrying the marker / using the whitelisted
   credential helper) are allowed.

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

**Don't strand existing engineer writes that aren't `create`/`comment`.**
Blocking bare `issue edit/close`, label edits, and `pr review/merge` would break a workflow that today
*legitimately* needs them under an engineer/maintainer identity: `triage-feedback` does label edits and
issue closes ("tracker maintenance … requires a configured maintainer identity"), and `wf.sh` itself does
`pr review`/`pr merge`/issue-close — but `wf.sh issue` currently exposes only `create` and `comment`. So
the design's guard cannot simply forbid these; it must point at an **engineer-identity replacement**. The
decision (recorded here for the owner): **extend the one engineer path with NARROW, per-verb-allowlisted
maintainer commands** — `wf.sh issue close|label` (and `edit` only if a concrete workflow needs it), each
accepting a **fixed, validated argument set** and NOT forwarding arbitrary `gh` args. This deliberately
mirrors `proposals/91-issue-flag-hardening.md`, which restricted `wf.sh issue` to `create`/`comment`
precisely because forwarding arbitrary args "permits destructive/interactive operations": the new verbs
must stay on that hardened model (allowlisted flags, no passthrough), so we do not reopen what #91 closed.
`pr review/merge` already run through the engineer token inside `finish`/the review path — confirm, don't
re-add. Operations with **no** workflow need (arbitrary owner-only admin) stay on the elevated maintenance
path. `feedback-loop`/`triage-feedback` docs are updated to call the new engineer verbs instead of bare
`gh`. This is its own product child (#4 below) so the guard never lands ahead of the replacement it
requires.

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
NOT product code and must NOT be modeled as a product ship-change child — the instance↔product boundary).
The product cannot ship a consumer's credential; it ships the *contract* + the *detector* + the *guard*,
and the instance applies the capability change to itself.

**Product `ready` children (ship-change runs in this repo, each references #149):**

1. **Product `gh` write-guard wrapper + the `wf.sh`↔guard bypass contract + forced one-shot engineer push
   credential + `.aar-ci` behavior smoke.** The wrapper classifies read-vs-write `gh` subcommands, passes
   reads through, blocks credential-mutating `gh auth` while whitelisting the non-mutating helper forms, and
   on a write emits the directed "use `wf.sh`" error. Bundled (atomically, because the contract ties them
   together): routing **every** internal `gh` call site (not just `gh_author` — also the review POST,
   PR-comment, classify, and finish paths) through one marked real-`gh` helper, plus a `.aar-ci` static
   check that fails on any unmarked `gh` call in `wf.sh`; the `git_push_author` change that **forces a
   one-shot engineer credential** (tokenized remote / scoped askpass) so the push doesn't depend on an
   ambient owner Git credential; and a behavior smoke asserting **all** directions (bare `gh` write
   blocked; credential-mutating `gh auth` blocked; `wf.sh`-routed write, **the review/classify/finish
   paths**, AND full engineer push allowed under the wrapper). Owns the guard-specific override flag.

   **Packaging / install home (so the wrapper isn't a free-floating instance PATH hack).** The wrapper
   ships as **product code inside the ship-change skill's `scripts/` dir** (the Agent Skills layout —
   scripts live in the skill dir, per `AGENTS.md`), with a **canonical product activation command** —
   `wf.sh install-gh-guard` (or an init subcommand) — that an instance invokes to put the wrapper ahead of
   the real `gh` on PATH (and prints how to undo it). The product owns the wrapper source + the installer;
   the instance only *runs* the installer and owns its own PATH. This gives the guard a defined home in the
   packaging model rather than an undocumented per-instance shim.
2. **Read-only-ambient detector: `wf.sh doctor` check + a `.aar-ci` smoke (product), covering BOTH the
   `gh`/API surface AND the ambient `git push` surface — and NEVER performing a real mutation on either
   branch.** The non-negotiable property: a `doctor` probe must be safe to run routinely against the live
   repo, so it must **not complete a write even when the ambient token is write-capable** (otherwise a
   write-capable owner token would edit a live PR/issue or land a commit before `doctor` reports FAIL —
   exactly the failure a safety check cannot have).

   **The guarantee is categorical: the credential must grant NO reachable `gh`/GitHub write permission —
   not merely "the three incident classes are read-only."** `doctor` FAILS on *any* reachable write
   permission category. The classes `issues`/`pull_requests`/`contents` are the **minimum probed floor**
   (the incident's actual write surface) for the empirical fallback below, used when an authoritative
   granted-permission list isn't available — a floor, not a redefinition of the guarantee. Repo
   administration is excluded from the *floor* only because a token can be admin-less yet still write
   issues/PRs (admin alone never certifies safety); but where an authoritative permission set is available
   and shows *any* write category, `doctor` fails on it.

   **(a) API-permission check — non-mutating on BOTH branches, authoritative-first.**
   - **Authoritative granted-permission data first (no write attempted; covers ALL categories).** Where the
     credential exposes its *granted* permissions authoritatively — a GitHub App **installation token's
     permissions object** — `doctor` reads it and FAILS if any category is `write`/`admin`. This is the
     only metadata path trusted, because it states what the token *was granted*. **`x-accepted-github-
     permissions` and rate-limit hints are explicitly NOT used as proof** — they advertise what an *endpoint
     requires*, not what the *token holds*, so they cannot certify read-only (they would false-pass a
     write-capable fine-grained PAT). A fine-grained PAT exposes no authoritative granted-set over the API,
     so it falls through to the empirical probe.
   - **Empirical 403/422 denial probe (still no mutation) for any class lacking an authoritative set.**
     Issue a write-method request **validated by the read-only token's 403**, not by an allowed write:
     a body GitHub rejects at **validation before** it mutates — an invalid/empty `PATCH` body returns
     **422 Unprocessable** for a write-capable token ("you may write but this body is invalid" — nothing
     written) and **403 Forbidden** for a read-only one. Signal: **403 ⇒ read-only (PASS) / 422 ⇒
     write-capable (FAIL)**, and **neither outcome mutates**. This replaces the earlier identity-write
     canary, which completed a real (no-op) write on the writable branch and was unsafe. Run it for each of
     the minimum `issues`/`pull_requests`/`contents` classes.

   No probe uses a guessed/provisioned resource id; targets are self-discovered from what the token can
   already GET, and the contents probe never carries a real `sha`+content (so it cannot create a commit).
   **The child MUST empirically prove, per probed class, that the probe distinguishes a read-only from a
   write-capable token AND mutates nothing on either branch, before it is the rollout gate** — verified
   mutation-freedom is part of the child's acceptance, not assumed.

   **(b) Ambient-`git push` probe — `--dry-run`, never updates the remote.** A `git push --dry-run` to a
   disposable ref with **all credential prompts disabled** (`GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS` to a
   no-op, `core.askPass` empty, SSH `BatchMode=yes`) and the engineer credential explicitly absent, so it
   exercises only the **ambient** Git credential. `--dry-run` performs the auth/negotiation but **does not
   update the remote**. Accepted ⇒ an owner credential can write ⇒ FAIL loud; auth-rejected ⇒ ambient Git
   surface is read-only ⇒ PASS.

   **Doctor probes each credential SOURCE separately and bypasses only the ergonomic guard, not the
   capability layer.** `doctor` checks `GH_TOKEN`, `GITHUB_TOKEN`, and the stored `gh auth` credential
   **independently** (clearing/isolating the others per check), so it proves *no* reachable source is
   write-capable rather than only whichever one `gh` happens to resolve first; and it invokes the real `gh`
   directly (the internal-bypass marker) so the ergonomic wrapper can never mask a write-capable source and
   falsely certify safety. The `.aar-ci` fake-`gh`/fake-`git` smoke supplies stubs for the read-only fixture
   (403 / push-rejected) and the write-capable fixture (422 / push-accepted) and asserts `doctor` reports
   read-only vs write-capable per source and per surface, and that no fixture path performs a mutation.
3. **Codify the contract across ALL its canonical homes — one canonical reference, no duplicate live
   contracts (product, doc-only).** Add the rule to `AGENTS.md` ("the ambient agent GitHub
   credential MUST be read-only; all writes go through the engineer token path"), next to the existing
   engineer-identity rule, AND update every point-of-use surface that currently advertises a write-capable
   ambient `GH_TOKEN` / owner-admin write path so they don't become a second, stale contract:
   ship-change `SKILL.md` ("Auth: … export `GH_TOKEN`"), `RUNBOOK.md` (the `GH_TOKEN` rotation note that
   says "repo: contents + pull_requests"), and any help/plugin metadata. Prefer a single canonical
   statement that the others reference over duplicated prose.
4. **Narrow engineer maintainer verbs so no existing workflow is stranded (product; the blast-radius
   dependency — BLOCKING predecessor of child #1).** The guard forbids bare `issue close`, label edits, and
   PR review/merge under the ambient owner token, but `triage-feedback` (label edits + closes) and `wf.sh`
   itself need them under the engineer/maintainer identity, and `wf.sh issue` currently exposes only
   `create`/`comment`. Add **narrow, per-verb-allowlisted** `wf.sh issue close|label` (and `edit` only if
   needed), each with a fixed validated arg set and **no arbitrary-arg passthrough** — preserving the #91
   hardening model so the destructive/interactive surface stays closed. Confirm `pr review`/`pr merge`
   already run through the engineer token (they do, inside `finish`/the review path). Update
   `feedback-loop`/`triage-feedback` docs to call the engineer verbs instead of bare `gh`, each with a
   per-verb smoke. **This child is an explicit BLOCKING predecessor: it MUST merge before child #1's guard**
   so the guard never blocks an operation that has no engineer-identity replacement yet.

**Instance rollout task (NOT a product ship-change child — applied to this deployment directly):**

- **Demote this instance's ambient agent credential to read-only + wire the separate elevated owner
  token** in the auth-env loader / `~/.config`. This is the load-bearing capability change, but it is
  instance-owned credential config; it is tracked as an instance rollout task (and gated on product
  children 1–2 being available), not as a product `ready` issue. It must close the **full**
  ambient write surface, not just the exported token: (a) the exported `GH_TOKEN`/`GITHUB_TOKEN` becomes
  read-only, AND (b) any write-capable stored owner `gh auth login` credential is removed from or isolated
  out of the agent shell's `GH_CONFIG_DIR` (so a stored-credential fallback can't re-open the hole). The
  product child #2's doctor check — which probes the *effective* resolved credential — is what verifies
  this rollout actually took effect on any given install, covering both paths. The rollout also covers the
  **Git** credential surface: ensure the agent shell holds no write-capable owner Git credential for the
  GitHub remote (read-only fetch/clone is fine), so the only thing that can push is the one-shot engineer
  credential `git_push_author` forces.

Sequencing (a strict dependency, not a preference): **child #4 (the narrow engineer maintenance verbs)
MUST merge before child #1 (the guard)** — the guard cannot block `issue close`/`label` until their
engineer-identity replacements exist, or it strands `triage-feedback`. Order: **#4 → #1 → #2 → #3** (child
#3 the contract docs can land any time after #1; child #2 the detector before the instance rollout). Only
after the product children are available does the instance perform the capability demotion (token + stored
`gh auth` + Git credential) and run `wf.sh doctor` to confirm every probed surface is read-only while a
`wf.sh`-routed write/push still authors as the bot. The capability layer delivers the structural guarantee;
the product children make it enforceable, ergonomic, detectable, non-stranding, and documented.

## Alternatives considered

- **`gh` PATH-shim/wrapper as the *primary* (sole) mechanism.** Rename the real binary, drop a wrapper
  that errors or token-swaps on writes. Rejected as the *security boundary* because a wrapper is an
  interception layer, not a capability removal: it must enumerate every mutating subcommand shape
  (including `gh api -X …`, aliases, future subcommands), it can be PATH-shadowed or bypassed by calling
  the real binary directly, and it risks recursing into `wf.sh`'s own `gh` calls. It remains valuable as
  the **ergonomic layer** (child #1's guard wrapper), but the *guarantee* must come from the read-only
  capability, which no enumeration gap or PATH trick can defeat.

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
- **Product surface touched (in the four `ready` children):** a new `gh` write-guard wrapper (shipped in
  the ship-change skill's `scripts/` + a `wf.sh install-gh-guard` activation command) and its `.aar-ci`
  behavior smoke; a `wf.sh` bypass marker at its internal `gh` call sites + a forced one-shot engineer push
  credential in `git_push_author`; a `wf.sh doctor` read-only check (API + ambient-`git push`,
  per-credential-source, non-mutating) + its fake-`gh`/`git` smoke; narrow `wf.sh issue close|label`
  maintainer verbs (per-verb-allowlisted, #91 model) + their smoke and the `feedback-loop`/`triage-feedback`
  doc updates; and the contract codified across `AGENTS.md` + ship-change `SKILL.md`/`RUNBOOK.md`/metadata.
  No change to the existing engineer-token implementation — it is reused as-is.
- **Instance surface touched (the instance rollout task, not product code):** the auth-env loader stops
  exporting a write-capable ambient token and instead exports a read-only one; a separate elevated owner
  token is wired for explicit maintenance; the wrapper is installed on PATH ahead of the real `gh`. These
  are `~/.config`/instance-level — owned by the consuming instance, never product code.
- **Failure mode if mis-rolled-out:** if an install forgets to demote the ambient token, the footgun
  persists silently — which is exactly why the product detector (child #2, the `wf.sh doctor` read-only
  check) exists, to fail loudly on a still-write-capable ambient credential on any install.

## Rollout + rollback

- **Staged, in dependency order #4 → #1 → #2 → #3.** Land #4 (narrow engineer maintainer verbs) FIRST so
  the guard has replacements to point at; then #1 (guard wrapper + `wf.sh` bypass contract + forced push
  cred + `wf.sh install-gh-guard`); then #2 (non-mutating read-only detector / doctor check); #3 (contract
  across canonical homes) any time after #1. Then perform the instance rollout (demote the ambient token +
  stored `gh auth` + Git credential to read-only, wire the elevated owner token, run `wf.sh
  install-gh-guard`) and confirm via `wf.sh doctor`: reads still work, a bare `gh issue create` now 403s,
  and `wf.sh issue …` still authors as the bot.
- **Escape hatch / rollback for a wedged state.** If the read-only demotion ever blocks legitimate
  owner/admin work, the operator performs the explicit two-step (source the elevated owner token **and**
  set the guard-specific `WF_GH_ALLOW_OWNER_WRITE=1`); the guard emits a terminal note. Full rollback is a
  one-line instance revert: re-export the write-capable token in the auth-env loader (restores the prior,
  footgun-bearing behavior) — reversible, instance-local, no product change needed. The product wrapper is
  removable from PATH independently of the capability layer, and the doctor check will then report the
  ambient token as write-capable (loud), which is the intended signal that rollback happened.
- **No data migration; no GPU cost; no API/data-gen cost.** This is a credentials-scope + small-wrapper
  change. The only operational cost is minting the read-only and elevated tokens on the instance.
