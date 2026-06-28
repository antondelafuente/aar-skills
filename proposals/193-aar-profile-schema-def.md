# Proposal: aar-profile schema definition doc + product `schema_version` constant (#193)

> The first `ready` implementation child of the merged design #153 (PR #190). Implements exactly decision
> 2 (the schema), decision 5 (versioning / refuse-unknown-MAJOR), and decision 1's discovery lookup order,
> as a **product reference doc** the later #153 children (the init/validate scripts #2, the discovery+snapshot
> helper #3, the skill edits #4) read. No runtime behavior; no skill is rewired here.

## Problem

The merged #153 design replaced the narrative "execution profile" seam with one declarative, versioned
config file (`aar-profile.{toml,json}`) that a zero-context agent discovers, reads, and snapshots into
`START.md`. But #153 is a design doc on `main`; nothing in the shipped product yet **states the schema** in a
form the implementation children can build against. The discovery+snapshot helper (#153 child 3) needs to
compare the file's `schema_version` against a **product constant**, and refuse an unknown MAJOR; the
init/validate script (child 2) needs the **field list, types, required/optional status, and the closed value
sets** (the `recipes.*` kinds and the URI scheme set) to validate against; the skill edits (child 4) need the
**discovery lookup order** to cite. Today those facts live only inside the prose of the #153 proposal — an ADR
that is not a maintained product surface the readers can resolve. Without a single canonical schema reference,
each later child would re-derive the field layout from the proposal and they would drift.

This is the **root** piece of the #153 decomposition (no #153-internal dependencies): it freezes the schema,
the version constant, and the discovery order as one product-owned reference, so every other child reads one
source of truth instead of re-reading the design narrative.

## Approach

Ship a small **product reference doc** — `SCHEMA.md` — that enumerates the v1 `aar-profile` schema exactly as
fixed by #153: the `[github]` block (`research_repo`, `base_branch`, `branch_prefix`, `issue_repo`,
`private`), the family-keyed `[github.identity.<claude|codex>]` seam-name pairs (`token_cmd_env` /
`git_author_env` — env-var NAMES, never secrets, per #153 decision 7), the `[github.protection]`
tightening-only expectations (`require_pr_review`, `enforce_admins`; and the **product invariant** that there
is no cross-family knob — #153 decision 3a), and the typed `[recipes.*]` pointers (`kind="repo"` →
`{repo, path, git_ref}`; `kind="uri"` → `{uri, sha256}` with `uri` in the closed set `{r2://, s3://,
https://}`). It carries the normative **`schema_version` constant** the readers compare against and the
**refuse-unknown-MAJOR** rule (#153 decision 5), and the **discovery lookup order** (#153 decision 1):
`$AAR_PROFILE` (override / test seam only) → `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.{toml,json}`,
with `.toml`-wins precedence and fail-closed if none.

The doc is **declaration only** — it states the schema and the rules; it implements no discovery, validation,
or minting (those are children 2 and 3). It is the contract those children build against.

### The load-bearing decisions

**1. The `schema_version` constant lives in the doc as a single machine-extractable line.**
The readers (child 3's discovery helper) must compare the file's `schema_version` against *a* product value.
Rather than mint a second home (a shell var, a JSON), the constant lives in `SCHEMA.md` itself as one
HTML-comment-delimited normative line — `<!-- SCHEMA_VERSION: 1 -->` — so a reader can extract it
deterministically (a one-line `grep`) and a human reads the prose definition right beside it. This keeps the
doc the single source of truth for both the human and the machine, the same pattern `DISPOSITIONS.md` already
uses (an HTML-comment-delimited block extracted by `.aar-ci/checks.sh`). Children 2/3 read this line; they do
not hardcode `1`.

**2. Packaged per-skill in BOTH skill dirs, byte-identical, with a deterministic drift check — the
feedback-loop precedent.** `experiment-lifecycle` ships two independently-installed skills
(`design-experiment`, `run-experiment`); skills are symlinked per-skill, so a module-level reference has no
single install-resolvable home. #153 decision 1 fixes this packaging contract explicitly: "packaged in both
skill dirs (each skill references it relative to itself), with the deterministic drift check in
`.aar-ci/checks.sh` asserting the two copies are byte-identical" — exactly how `feedback_loop_init.sh` is
already handled. So `SCHEMA.md` ships at both
`plugins/experiment-lifecycle/skills/design-experiment/references/SCHEMA.md` and
`plugins/experiment-lifecycle/skills/run-experiment/references/SCHEMA.md`, and `.aar-ci/checks.sh` gains a
`cmp -s` drift guard (mirroring the existing feedback-loop init-copy guard) so the two can never silently
diverge. The alternative — a single shared file under the plugin root — is not install-resolvable when a skill
is installed alone, which is the situation that precedent exists to solve.

**3. The doc fixes the schema; it does not re-litigate it.** Every field, type, required/optional status,
closed value set, the version rule, and the discovery order are **already decided** by merged #153. This child
transcribes them faithfully into a maintained product surface; it introduces no new field and no new rule. Any
disagreement with the schema is a change to #153, not to this doc.

## Alternatives considered

- **Put `schema_version` in a separate constant file (a shell var / JSON).** Rejected — it splits the schema's
  source of truth across two files that would drift; the doc is already the place a human and a reader both
  look. One HTML-comment line keeps it machine-extractable without a second home (decision 1).
- **One shared `SCHEMA.md` under the plugin root, referenced by both skills.** Rejected — skills install
  per-skill (symlinked), so a plugin-root file is not resolvable when one skill is installed alone. The
  per-skill copy + byte-identical drift check is the established feedback-loop precedent #153 decision 1
  mandates (decision 2).
- **Defer the doc and let each child re-read the #153 proposal.** Rejected — that is the drift this root child
  exists to prevent; the proposal is an ADR, not a maintained reader surface, and four children re-deriving the
  field layout from prose is exactly the failure #153 calls out.
- **Include the START.md snapshot grammar and the init/validate behavior here too.** Out of scope — the
  snapshot block grammar is consumed by child 3 (the discovery+snapshot helper) and child 4 (the skill edits);
  this doc states the *schema* and the *discovery order*. It cross-references the snapshot (#153 decision 4) so
  a reader knows where the resolved values are frozen, but it ships no helper and no template edit.

## Blast radius

- **New product artifact:** `SCHEMA.md`, shipped as two byte-identical per-skill copies under
  `experiment-lifecycle`'s `design-experiment` and `run-experiment` `references/` dirs. Purely additive — no
  existing file's behavior changes.
- **`.aar-ci/checks.sh`:** one added drift guard (a `cmp -s` between the two copies when either changes),
  mirroring the existing feedback-loop init-copy guard. Deterministic; runs only when a `SCHEMA.md` copy
  changes.
- **`experiment-lifecycle/plugin.json`:** version bump (a non-manifest file changed in the plugin), per the
  tracked version-bump check.
- **No skill rewiring, no runtime behavior.** `design-experiment`/`run-experiment` still carry their existing
  narrative seam; child 4 is what swaps the prose for typed reads. Reverting this doc only removes the
  reference the later children would read — it strands no run.
- **Cluster coupling:** this is the **root** of the #153 decomposition. Child 2 (init/validate) and child 3
  (discovery+snapshot helper) are `blocked-by` this doc; child 4 (skill edits) is `blocked-by` 2 and 3. It
  contradicts no sibling — it only *states* what #153 decided.

## Rollout + rollback

Lands `SCHEMA.md` (two copies) + the `.aar-ci/checks.sh` drift guard + the plugin version bump on `main`
through the normal single-phase `ready` ship-change gate (cross-family `--code` review + checks + fake-HOME
smoke). The schema is inert reference text; nothing consumes it until child 3 ships. Rollback is a plain revert
of this PR — additive-only, so the revert removes the doc and the guard with no data loss and no run impact.
