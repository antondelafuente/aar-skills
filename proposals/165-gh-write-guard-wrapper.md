# Proposal: gh write-guard wrapper + wf.sh bypass contract + forced engineer push cred + install command (#165)

> Child of the merged design `proposals/149-gh-write-identity-guard.md` (#149). This is the **ergonomic
> layer** of that design — the fail-*helpful* redirect — and the `wf.sh`↔guard bypass contract that keeps
> the SWE pipeline working under it. The structural guarantee (a read-only ambient credential) is a separate
> instance rollout + detector child; this child merges AFTER #164 (narrow maintainer verbs), which is
> already merged.

## Problem

A read-only ambient `gh` credential makes a bare `gh issue create` fail closed, but it fails with a raw
GitHub `403` that does not tell the agent *what to do instead*. Under reflex an agent reaches for plain
`gh` and gets an opaque error rather than a directed "use `wf.sh`". We want a thin guard around `gh` that
recognizes a mutating subcommand and redirects the agent to the engineer path with a clear message — an
**ergonomic redirect, not the security boundary** (even if the guard is missing or PATH-shadowed, the
read-only capability layer still fails the write closed).

The hard part is that the guard must never break the SWE pipeline itself. `wf.sh` already writes to GitHub
constantly (open the PR, post reviews, comment, classify, merge) and pushes the branch — and it does so by
swapping `GH_TOKEN` to a freshly-minted engineer token. A `GH_TOKEN` swap is **invisible to a PATH
wrapper**: the wrapper cannot tell an engineer-token `gh` call from any other token-backed call. So "no
engineer token in the environment" is not a usable signal. The guard needs an explicit marker that `wf.sh`
sets on its own internal `gh` calls, and `wf.sh` must funnel **every** internal `gh` call site through one
marked helper — not just `gh_author`, but also the review-POST, PR-comment, classify, finish, and doctor
paths, which today each do `GH_TOKEN=… gh …` directly.

## Approach

Three coupled pieces, shipped atomically because the bypass contract ties them together.

The **guard wrapper** (`scripts/gh-guard.sh`, shipped in the ship-change skill's `scripts/` dir) is a thin
shim placed ahead of the real `gh` on PATH. It classifies the `gh` subcommand: reads (`view/list/status`,
`api` GETs, etc.) pass straight through to the real `gh`; a mutating subcommand (`issue/pr create`,
`*comment`, `pr review/merge`, `issue edit/close/delete`, `api -X POST/PATCH/PUT/DELETE`) is blocked with the
directed message "GitHub writes go through `wf.sh issue|comment <family>`". The mixed read/write top-level
families (`repo`, `release`, `secret`, `variable`, `ruleset`, `workflow`, `run`, …) pass their reads through
but redirect the obvious mutating verbs (`create`/`delete`/`edit`/`set`/`rename`/`archive`/`upload`/`enable`/
`disable`/`rerun`/`cancel`/…). A flag/value-skipping tokenizer finds the real subcommand+verb so the
common `gh -R owner/repo …` form is classified, not bypassed; the blocked message names only the recognized
verb shape (e.g. `gh issue create`), never the raw argv or a user flag value. It blocks the
**credential-mutating** `gh auth` forms (`login`/`refresh`/`setup-git`/`logout`) — they would re-open the
stored-credential hole the capability layer closes — while **whitelisting only** the non-mutating helper
forms the workflow needs (`gh auth git-credential`, `gh auth status`, `gh auth token`). Two bypasses let the
pipeline through untouched: `WF_GH_INTERNAL=1` (the `wf.sh` marker) passes the call straight to the real
`gh` and never recurses; `WF_GH_ALLOW_OWNER_WRITE=1` is the explicit, logged owner-maintenance override (it
only suppresses the redirect — it does **not** itself grant write capability; that still requires an
elevated owner token).

The **`wf.sh`↔guard bypass contract**: every internal `gh` call in `wf.sh` is routed through one marked
real-`gh` helper (`real_gh`) that sets `WF_GH_INTERNAL=1` and resolves the real `gh` (so the guard, if on
PATH, passes it through). `gh_author` and the review/comment/classify/finish/doctor paths all call
`real_gh`. `git_push_author` **forces a one-shot engineer credential by rewriting the push to a tokenized
HTTPS URL** (`https://x-access-token:<token>@github.com/<owner>/<repo>.git`) computed from the remote, and
disabling Git's credential helpers for that one push (`-c credential.helper=`) so a **stored owner HTTPS
helper or an SSH remote cannot win** — askpass alone was insufficient because stored helpers / SSH keys
bypass it (design finding). The push also runs with `WF_GH_INTERNAL=1` so a credential-helper `gh`
invocation passes the guard. A `.aar-ci` **static check** (`gh_guard_static_check.sh`) fails the build on
any unmarked `gh` / `GH_TOKEN=… gh` call in `wf.sh`, so a future call site cannot silently regress the
bypass.

**`gh api` is classified default-deny.** It counts as a write (blocked) whenever it carries any non-GET
method (`-X`/`--method` other than GET/HEAD) or any field flag that implies a POST body (`-f`/`-F`/`--field`/
`--raw-field`/`--input`); it passes as a read only when it is clearly a GET with no body. This closes the
`gh api --method PATCH` form already used in `wf.sh`. A `gh api graphql` call carrying **any** body is blocked
by default — a mutation can hide in `--input file` / `-f query=@file` where the literal `mutation` text never
appears in argv, so the guard does not try to prove a graphql body is "only a query".

The **install command**: `wf.sh install-gh-guard` symlinks the wrapper into a chosen bin dir (default
`~/.local/bin`) as `gh`, ahead of the real `gh` on PATH, and prints how to undo it; `wf.sh
uninstall-gh-guard` removes it. The product owns the wrapper source + the installer; the instance only runs
the installer and owns its own PATH.

A behavior smoke (`gh_guard_smoke.sh`) exercises **all directions** with a fake `gh` on PATH: a bare `gh`
write is blocked; a credential-mutating `gh auth login` is blocked; a whitelisted `gh auth git-credential`
passes; a read passes; a mutating `gh api --method PATCH` is blocked; a `WF_GH_INTERNAL=1` (marker) write
passes; and `WF_GH_ALLOW_OWNER_WRITE=1` lets an owner write through. It then drives the **actual `wf.sh`
internal paths** through the guard via the `real_gh` helper and `git_push_author` (review-POST shape,
classify-POST shape, comment shape) to prove they survive the wrapper, and exercises `git_push_author`
against a **fake hostile credential helper + a local bare-repo remote** to prove the forced tokenized URL
wins over a stored ambient helper (the engineer push succeeds; a non-forced push using only the ambient
helper would be authored by the helper). It also asserts the static check passes on the real `wf.sh` and
fails on a planted unmarked call.

## Alternatives considered

- **A shell function instead of a PATH shim.** Rejected as the *only* mechanism: a function is per-shell and
  not inherited by `wf.sh`'s subprocess `gh` calls or by `git`'s credential-helper invocation; the PATH shim
  is process-global and survives subshells.
- **Detect the engineer token by value.** Rejected — the design's load-bearing point: a token swap is
  invisible to the wrapper, so an explicit env marker is the only robust signal.

## Blast radius

Touches every agent's `gh` usage once the wrapper is installed (an instance step). The SWE pipeline is the
surface that must keep working untouched — proven by routing every internal call through the marker and by
the smoke exercising the review/classify/finish/push paths under the wrapper. No change to the engineer token
implementation; it is reused as-is. No GPU/API cost.

## Rollout + rollback

Land here (product). The instance then installs the wrapper (`wf.sh install-gh-guard`) as part of the
read-only-credential rollout. Rollback: `wf.sh uninstall-gh-guard` removes the shim from PATH independently
of the capability layer.
