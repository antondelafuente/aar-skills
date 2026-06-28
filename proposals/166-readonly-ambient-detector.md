# Proposal: provenance-gated read-only-ambient detector (#166)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

The #149 design makes the ambient agent GitHub credential read-only so a bare `gh` write fails closed.
But an instance can forget to demote its ambient token, and then the footgun persists *silently* — a
write-capable owner token stays reachable in every agent shell and nothing complains. There is no way to
ask an install "is your ambient credential actually read-only?" and get a trustworthy yes/no.

`wf.sh doctor` today only reports engineer-identity readiness (are the bot tokens mintable, is the git
author set, is the model reviewer wired). It says nothing about whether the *ambient* credential — the
one a reflexive bare `gh` or `git push` would use — can write. So the load-bearing capability change from
#149 has no detector, which is exactly why child #2 exists: a check an install can run routinely that
fails loudly when the ambient credential is still write-capable, covering BOTH the `gh`/API surface and
the ambient `git push` surface, and NEVER performing a real mutation on either while it checks.

## Approach

Add a `wf.sh doctor` read-only-ambient section plus a `.aar-ci` smoke. The detector reports, per
credential source and per surface, whether the *ambient* credential is read-only — and certifies a PASS
only by PROVENANCE, never by enumerating probes.

**Why provenance, not probing.** You cannot prove "this opaque token holds no reachable write permission"
by hitting a finite set of endpoints — a fine-grained PAT could carry some *other* write scope
(`workflow`, `actions`, `deployments`, `pages`, …) an issues/PRs/contents probe never touches, and it
would false-pass. So the detector does not try to enumerate every write surface. It instead:

- **PASSES only on authoritative read-only confirmation.** Either (a) the credential is a GitHub App
  **installation token** whose `installation/permissions` JSON `doctor` fetches and finds contains **no**
  `write`/`admin` permission value; or (b) it comes from the instance's read-only minter seam
  (`WF_READONLY_TOKEN_CMD`) paired with a machine-verifiable token-info command
  (`WF_READONLY_TOKEN_INFO_CMD`) that emits the token's canonical permissions, which `doctor` parses and
  finds free of any `write`/`admin` category. No local-assertion pass.
- **FAILS CLOSED on any uninspectable/unattested token.** An opaque PAT with no exposed granted-set and no
  read-only-minter provenance is a FAIL, not a pass — the detector never certifies safety it cannot prove.
  This is what closes the "a finite probe set can't cover every write scope" gap.
- **Treats the empirical 403/422 denial probe as ADVISORY ONLY.** As an extra alarm (not the gate),
  `doctor` may send a write-method request GitHub rejects at validation *before* it mutates (an
  invalid/empty `PATCH` over the `issues`/`pull_requests`/`contents` floor: 403 ⇒ looks read-only, 422 ⇒
  definitely write-capable; neither mutates). A 422 is a loud "write-capable" signal that can turn a PASS
  into a FAIL; a 403 floor never *upgrades* an unattested token to PASS. `x-accepted-github-permissions` /
  rate-limit hints are not used as proof (they describe endpoint requirements, not granted scope).

**Per credential SOURCE.** `doctor` probes `GH_TOKEN`, `GITHUB_TOKEN`, and the stored `gh auth` credential
**independently** — isolating the others for each check (a per-source `GH_CONFIG_DIR` + cleared env) — so
it proves *no* reachable source is write-capable, not just whichever one `gh` resolves first. It invokes
the real `gh` directly (the `WF_GH_INTERNAL` marker) so the ergonomic guard can never mask a write-capable
source and falsely certify safety.

**Ambient `git push` surface.** A separate probe runs `git push --dry-run` to a disposable ref with **all
credential prompts disabled** (`GIT_TERMINAL_PROMPT=0`, a no-op `GIT_ASKPASS`, empty `core.askPass`, SSH
`BatchMode=yes`) and the engineer credential explicitly absent, so it exercises only the *ambient* Git
credential. `--dry-run` performs the auth/negotiation but does not update the remote: accepted ⇒ an owner
credential can push ⇒ FAIL; auth-rejected ⇒ ambient Git surface is read-only ⇒ PASS.

**Non-mutating by construction.** No probe uses a guessed/provisioned resource id (targets are
self-discovered from what the token can already GET); the contents probe never carries a real `sha` +
content (so it cannot create a commit); the git probe is `--dry-run` only. The detector is safe to run
routinely against the live repo even when the ambient token *is* write-capable.

**Smoke (`.aar-ci`).** Three fixtures — an authoritatively-read-only token (PASS), a write-capable token
(FAIL), and an uninspectable/unattested token (FAIL CLOSED, not PASS) — exercised across the API and Git
surfaces with a fake `gh`/`git` on PATH (no network), asserting `doctor`'s verdict per source and per
surface and that no fixture path performs a mutation. Registered in `.aar-ci/checks.sh` next to the
existing wf.sh smokes (runs when wf.sh or the new smoke changes).

## Alternatives considered

- **Enumerate every write endpoint and probe each.** Rejected as the gate: a finite probe set can never
  cover every fine-grained write scope, so an uncovered scope false-passes. Provenance is categorical;
  probing is at best an advisory alarm (kept as exactly that).
- **Trust a local assertion ("the instance says this token is read-only").** Rejected — a misconfigured
  install would assert wrongly and the detector would certify the very footgun it exists to catch. PASS
  requires a machine-verifiable granted-permissions set tied to the emitted token.
- **Probe only the source `gh` resolves first.** Rejected — leaves a write-capable `GITHUB_TOKEN` or
  stored `gh auth` credential undetected behind a read-only `GH_TOKEN`. Per-source isolation is required.
- **Let the detector actually attempt a write and roll it back.** Rejected — a safety check cannot have a
  window where a write-capable token lands a real mutation before the verdict. Mutation-freedom is a hard
  property, verified in the smoke.

## Blast radius

- **Product (this repo):** a new read-only-ambient section in `wf.sh doctor` + helper functions; a new
  `.aar-ci` smoke (`readonly_ambient_smoke.sh`) registered in `checks.sh`; the `WF_READONLY_TOKEN_CMD` /
  `WF_READONLY_TOKEN_INFO_CMD` seam *consumption* in `doctor` (the seam's canonical contract docs are
  child #3; this child consumes the seam and documents it in the wf.sh header + RUNBOOK doctor note).
- **No change to the engineer-token path, the guard wrapper, or the merge gate.** `doctor` stays a
  read-only reporter; the new section adds no new write capability.
- **Instance:** none in this child. The instance rollout (demoting the ambient token + wiring
  `WF_READONLY_TOKEN_CMD`) is a separate non-product task gated on this detector being available.
- **Failure mode if mis-rolled-out:** the detector reports FAIL/CLOSED loudly — that *is* the intended
  signal that the instance hasn't demoted its ambient credential yet.

## Rollout + rollback

- **Additive.** The new `doctor` section reports; it does not gate any existing command. An install that
  has not wired `WF_READONLY_TOKEN_CMD` and uses an opaque ambient token simply sees the read-only section
  report FAIL-CLOSED, while the existing engineer-identity READY/BLOCKED verdict is unchanged. (The
  read-only verdict is reported alongside but does not flip the existing identity-readiness exit code in
  this child — keeping the detector purely a reporter; wiring it into a gate is a later instance step.)
- **Rollback:** revert the squash commit; `doctor` returns to identity-only reporting and the smoke is
  removed. No data migration, no GPU/API cost.
