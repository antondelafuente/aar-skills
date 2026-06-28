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
directed message "GitHub writes go through `wf.sh issue|comment <family>`". It blocks the
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
`real_gh`. `git_push_author` **forces a one-shot engineer credential** — a scoped `GIT_ASKPASS` that prints
the engineer token — so the push authenticates as the engineer even with no ambient owner Git credential,
and runs with `WF_GH_INTERNAL=1` so that if `git push` invokes `gh` as a credential helper the guard lets it
through. A `.aar-ci` **static check** (`gh_guard_static_check.sh`) fails the build on any unmarked `gh` /
`GH_TOKEN=… gh` call in `wf.sh`, so a future call site cannot silently regress the bypass.

The **install command**: `wf.sh install-gh-guard` symlinks the wrapper into a chosen bin dir (default
`~/.local/bin`) as `gh`, ahead of the real `gh` on PATH, and prints how to undo it; `wf.sh
uninstall-gh-guard` removes it. The product owns the wrapper source + the installer; the instance only runs
the installer and owns its own PATH.

A behavior smoke (`gh_guard_smoke.sh`) exercises **all directions** with a fake `gh` on PATH: a bare `gh`
write is blocked; a credential-mutating `gh auth login` is blocked; a whitelisted `gh auth git-credential`
passes; a read passes; a `WF_GH_INTERNAL=1` (marker) write passes; and `WF_GH_ALLOW_OWNER_WRITE=1` lets an
owner write through. It also asserts the static check passes on the real `wf.sh` and fails on a planted
unmarked call.

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
