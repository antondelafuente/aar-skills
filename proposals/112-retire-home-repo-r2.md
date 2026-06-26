# Proposal: retire the home/orchestrator repo behind an R2-backed instance backup (#112)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.
> **Two-phase design** — output is this doc + spawned implementation issues.

## Problem

`/home/anton` is a git checkout with remote `antondelafuente/orchestrator`, but it is not a product repo. It is
one live instance's home directory. That mismatch keeps producing bad agent behavior: agents see a Git remote,
treat the home folder like a shippable repository, and then create branch/PR/review work around state that should
never have been product-managed there.

The live state shows why this is dangerous. The home checkout is currently `main...origin/main [ahead 18]`, and
its working tree reflects the research-lab split: `orchestrator/` is now a symlink to
`/home/anton/research-lab/registry`, while the old tracked `orchestrator/*` files show as deleted from the home
repo's point of view. The root checkout is also full of instance-only material: agent memory, local launch
scripts, credentials pointers, shell config, plugin caches, and compatibility symlinks. Git is the wrong
durability mechanism for that shape.

For Anton's current deployment, the desired end state is two real repos plus one unversioned instance:

- `aar-skills` / `automated-researcher` is the reusable product scaffold.
- `research-lab` is Anton's private research workspace.
- `/home/anton` is just the live instance directory, backed up to R2, not a GitHub-backed repo.

This cannot be done by simply deleting `/home/anton/.git`. The root repo still contains product content that must
first be moved or deliberately retired (#111), the product docs still name an instance-specific transition-map
path (`orchestrator/PRODUCT_TRANSITION.md`), live instance state must have a verified backup and restore path, the
retiring git history must be preserved somewhere durable, and the remaining open `orchestrator` issues need to be
triaged before the GitHub repo is archived.

## Approach

This design has two outputs:

1. the **product slice** that belongs in `aar-skills`: genericize product docs away from the current deployment's
   `orchestrator` repo language, and migrate the one product-worthy old `orchestrator` issue;
2. the **instance slice** that does not belong in the product backlog: write and execute the R2 backup/de-git
   retirement plan in the current deployment's transition surface.

The ordering below is the load-bearing part of the design.

**Phase 0: drain product content first (#111) and remove product pointers to instance paths.** Do not de-git
`/home/anton` until #111's design has landed and every product-content child it marks as de-git-blocking is
closed. There is no executor shortcut for deciding that #111 is "instance-only" from inside the de-git task.
Product skills, agent-neutral operating rules, fleet-update/product dispatch machinery, and reusable helper
scripts belong in `aar-skills` in product shape. If something is only this box's deployment config, it stays in
`/home/anton` and is covered by the instance backup instead.

Non-authoritative seed inventory for #111's de-git gate (the #111 design owns the canonical list):

- local product skills currently in the home substrate trees: `ask-codex`, `file-feedback`, and
  `triage-feedback`;
- borderline fleet/session tools that need an explicit product-vs-instance decision before root git retirement:
  `message-aar` and `update-fleet`;
- the agent-neutral constitution reconciliation, including this proposal's requirement that product docs use
  generic "consuming instance" language rather than naming Anton's home/orchestrator repo;
- launcher/dispatch/close machinery or any other durable AAR product behavior that still lives only in the home
  repo history.

`aar-skills/AGENTS.md` must not name any deployment-specific transition-map path. The product should say only the
generic rule: product content lives in `aar-skills`; deployment transition state belongs to the consuming
instance's own guidance. That same product rewrite must remove the broader "the lab's orchestrator repo is the
INSTANCE" framing and use generic "consuming instance" language instead. The current Anton deployment still needs
a concrete successor for its transition map, but that location is an instance decision and must be recorded in the
instance surface, not hardcoded back into the product constitution.

#111's product-content drain should also audit stale product references to the old `~/orchestrator` naming, such
as comments or docs that should be generic or should be explicitly marked as current-deployment examples. The
script-header cleanup called out in this design is product work, not instance retirement work.

Completion check for this phase: a fresh AAR pointed at `aar-skills` plus instance config can discover the
product skills and agent-neutral constitution without reading the home/orchestrator Git history. The home
directory may still have local wrappers and memories, but it must not be the canonical home for reusable product
facts.

**Phase 1: migrate only keeper `orchestrator` issues.** Before archiving the old GitHub repo, review the open
issues in `antondelafuente/orchestrator` and preserve only lasting product/lab value.

- Migrate `orchestrator#2` ("agents can hang forever on unbounded background waits") to `aar-skills`. The
  durable issue should be framed as a product behavior requirement: any scaffold-provided background wait helper
  or skill instruction must have a deadline, liveness check, and failure/timeout path.
- Do not migrate `orchestrator#4` as an implementation request. It is superseded by this retirement plan; leave
  a closing pointer to #112 and the migrated keeper issue.
- If any additional open issue appears before archive, classify it as product, lab, or obsolete. Product goes to
  `aar-skills`; lab goes to `research-lab`; obsolete gets a pointer and closes in `orchestrator`.

**Phase 2: route the R2 backup and de-git work to the instance transition surface.** This is instance work, not
reusable product code by default, and should not spawn product-backlog issues. The exact allowlist, secret
handling, R2 prefix, restore command, de-git checklist, git-history archive method, archive/freeze procedure, and
restore evidence belong in the current deployment's transition surface, not in this product ADR. The product-level
decision is only the gate: the home repo cannot be retired until #111's de-git-blocking product inventory is
drained, the instance has a verified R2 restore path, the retiring git history has been preserved separately from
the recurring backup, and normal boot behavior has been verified after moving `.git` aside.

After the instance retirement completes, agents should not be asked to commit in `/home/anton`; there is no root repo. Changes to
`aar-skills` and `research-lab` keep using their protected PR flows. Instance-only changes are applied directly
and covered by the next R2 backup.

## Alternatives considered

- **Push the 18-commit home divergence to `orchestrator` and keep the repo alive.** Rejected: it treats the
  symptom as the system. Some useful content must be rescued, but the root cause is that the home directory looks
  like a shippable repo at all.
- **Delete `.git` immediately.** Rejected: it would remove the confusion but lose the current backup path before
  an R2 restore path exists, before #111 drains product content, and before the retiring git history is archived.
- **Make the home backup a new reusable `aar-skills` plugin now.** Deferred. The immediate problem is one
  instance's retirement from git. If another installation hits the same need, the local backup script can be
  generalized later behind config seams.
- **Back up the whole home directory with a broad copy.** Rejected: it would sweep separate repos, caches,
  symlink targets, secrets, or large generated artifacts into the instance backup. The concrete backup policy
  belongs in the instance runbook.
- **Keep using old remote homedir backup scripts as-is.** Rejected as a design assumption. The existing remote
  material may be useful historical recovery material, but the retirement should create a fresh manifest and
  verify the restore path from the current instance state.

## Blast radius

Design document in `aar-skills` now; implementation spans three ownership surfaces:

- `aar-skills`: #111 and the migrated keeper issue from `orchestrator#2`.
- the current deployment's instance-owned surface: the successor to `orchestrator/PRODUCT_TRANSITION.md` and the
  detailed backup/de-git runbook.
- `/home/anton`: instance backup scripts/manifests, local docs, one-time git-history archive, and the final
  `.git` retirement.
- `antondelafuente/orchestrator`: final issue comments/closures and repo archive/freeze.

No production scaffold code changes in this design PR. The risky operational de-git step is routed to the
instance transition surface and is explicitly blocked on a verified R2 restore smoke and the #111 product-content
drain.

## Spawned product issues (this design's `aar-skills` decomposition)

1. **Genericize the product constitution's instance language** (`ready`, `design: #112`): update
   `aar-skills/AGENTS.md` so it no longer says "the lab's orchestrator repo is the INSTANCE", no longer names
   `orchestrator/PRODUCT_TRANSITION.md`, and no longer points at any other deployment-specific successor path.
   It should state that each consuming instance owns its own transition map in instance guidance, preserving
   discoverability with generic "look in your instance guidance" language rather than a path. Precondition: the
   current deployment's instance guidance must already say where its transition map lives before this product
   pointer is removed. Include the product script/comment cleanup for stale `~/orchestrator` or "orchestrator
   box" references, either by genericizing them or marking them as current-deployment examples when that is the
   intended meaning.
2. **Migrate `orchestrator#2` into `aar-skills`** (`ready`, `design: #112`): first audit existing bounded-wait
   homes such as run-experiment self-wake behavior and gpu-job timeout helpers, then file the keeper issue as an
   extension/pointer rather than a duplicate rule. Comment on `orchestrator#2` with the new issue pointer. Close
   or otherwise mark `orchestrator#4` obsolete with a pointer to #112. All issue creation, comments, and closure
   comments should use the engineer-identity path (`wf.sh issue <family> ...`) rather than raw ambient `gh`.

## Routed instance work (not `aar-skills` product backlog)

The remaining retirement tasks are real, but they belong to the current deployment's transition surface after
#111 settles the product/instance boundary:

- create the deployment's transition-map successor and detailed R2 backup/de-git runbook;
- build and verify the `/home/anton` R2 instance backup;
- preserve the retiring home git history;
- archive/freeze `antondelafuente/orchestrator`, move `/home/anton/.git` aside, verify normal agent boot behavior
  through the instance checklist, then leave `/home/anton` unversioned and R2-backed.

## Rollout + rollback

This PR lands the design only via `finish --design`. It should close #112, spawn only the two product issues
above in `aar-skills`, and route the instance-only retirement work to the current deployment's transition
surface.

Rollback for the design is a normal revert of this proposal. Rollback for the operational retirement is staged:
before deleting anything, move `.git` aside rather than removing it; if boot or backup checks fail, move it back
and keep `/home/anton` under the old git backup until the failure is fixed. Once the GitHub repo is archived and
the local `.git` is deleted, restore depends on the R2 snapshot plus the independent `aar-skills` and
`research-lab` repos.
