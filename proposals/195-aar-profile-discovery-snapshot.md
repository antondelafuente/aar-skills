# Proposal: aar-profile discovery + START.md snapshot helper (#195)

> A `ready` implementation child of merged design #153 (PR #190), depends-on the schema doc #193 (PR #199,
> landed). Implements decision 1's **discovery resolution** and decision 4's **START.md snapshot** as a small
> stdlib-only helper the experiment-lifecycle skills call. Validation logic stays with the init/validate owner
> (#194); enforcement stays with the gates. No skill is rewired here — that's child #4.

## Problem

The merged #153 design and its schema doc (#193) define *what* the instance execution profile is — its fields,
its discovery lookup order, its `schema_version` constant + refuse-unknown-MAJOR rule, and the fenced-TOML
`START.md` snapshot block that freezes the resolved values. But both are **reference docs**: nothing in the
shipped product yet *executes* the contract. A zero-context designer (`design-experiment`) still has no callable
way to resolve the live profile by the fixed lookup order, fail closed when none exists, refuse an unknown MAJOR,
and emit the snapshot block in the exact grammar the executor will later consume. Without a single helper, child
#4's skill edits would each re-implement the discovery walk and the snapshot serialization in prose, and the two
copies would drift from the schema — the precise failure the SCHEMA.md single-source-of-truth was meant to
prevent.

This child ships that helper: the **discovery resolution** step (decision 1) and the **snapshot build** step
(decision 4), plus the **one narrow live step** the executor needs (mint a fresh token from the env-var name the
snapshot carries). It is the executable seam children #4's skill edits call; it adds no validation (that is
#194's `aar-profile-validate`) and no enforcement (those are the gates #146/#150/#154/#156/#157).

## Approach

Ship one stdlib-only Python helper — `aar_profile.py` — packaged **byte-identical in both skill dirs**
(`design-experiment/scripts/`, `run-experiment/scripts/`), the same per-skill-copy + `.aar-ci` drift-check
contract #193's SCHEMA.md and feedback-loop's init helper already use. It exposes the three callable steps the
#153 role split needs, and nothing else:

- **`resolve`** (the designer step): walk the fixed discovery lookup order, read the **product `schema_version`
  constant** out of the packaged `SCHEMA.md` (the `<!-- SCHEMA_VERSION: N -->` marker — never a hardcoded `1`),
  refuse an unknown MAJOR, fail closed with `BLOCKED: no instance profile found (looked: <paths>)` if none, and
  print the resolved profile path + `profile_sha256` of the file's bytes.
- **`snapshot`** (the designer step): build the fenced-TOML `## Instance profile (snapshot)` block — every
  NON-SECRET execution field (the `[github]` facts, the family-keyed identity env-var **names**, the protection
  expectations, the typed recipe pointers) plus `profile_sha256` — in the exact grammar #153 decision 4 fixes,
  ready to write into `START.md`.
- **`mint-token`** (the executor's one narrow live step): given the snapshot's `token_cmd_env` value (an env-var
  *name*), read that env var, run the command it holds, and print the fresh token. This is the *only* live step
  the executor takes; all config comes from the frozen snapshot.

The helper is **read-only on config** and writes no instance state — it resolves, serializes, and (for the token
step) shells out to the seam the instance configured. It is the thin executable glue between the SCHEMA.md
contract and the skill prose; the heavy validation (`aar-profile-validate`) and the gates own everything else.

### The load-bearing decisions

**1. Resolution reads the product `schema_version` from SCHEMA.md, never a hardcoded literal.** #193 fixed the
constant as a single machine-extractable `<!-- SCHEMA_VERSION: N -->` line *so that* later readers extract it
rather than duplicate it. This helper does exactly that: `resolve` greps the marker out of its sibling
`references/SCHEMA.md` and compares the profile's declared `schema_version` against it. A profile whose MAJOR
exceeds the product constant is **refused** (fail closed, the same disposition as a missing file); an equal or
older known MAJOR is accepted (adding optional fields is backward-compatible, #153 decision 5). Because the
helper and SCHEMA.md ship in the same skill dir, the constant the helper enforces is always the one that shipped
with it.

**2. The discovery lookup order is exactly #153 decision 1 — `$AAR_PROFILE` (override/test only), then the
module config home, `.toml`-wins.** `resolve` uses the **first that exists**: `$AAR_PROFILE` if set (the manual
escape hatch and the test seam), else `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.toml`,
else `.json`. If both `.toml` and `.json` exist at the module path, **`.toml` wins** (deterministic precedence)
and the shadowed `.json` is noted on stderr. No profile anywhere ⇒ a single `BLOCKED: no instance profile found
(looked: <paths>)` line on stdout and a non-zero exit, before any GitHub mutation or compute spend — the same
fail-closed disposition `wf.sh start` takes on a stale base.

**3. The snapshot carries every NON-SECRET execution field, in TOML, under the fixed heading.** Per #153
decision 4 / FINDING 1, the executor reads only the snapshot, so the snapshot must contain everything non-secret
it later needs: the `[github]` scalars, **both** family-keyed `[identity.<family>]` seam-name pairs (env-var
NAMES — `token_cmd_env` / `git_author_env` — never the token), the `[protection]` expectations, and the typed
`[recipes.*]` pointers (each pinned by its kind-appropriate field — `git_ref` for `repo`, `sha256` for `uri`).
The block is emitted as a fenced ```toml block under the exact heading `## Instance profile (snapshot)` so the
grammar matches the profile format and a parser smoke can prove it machine-readable. The helper serializes the
parsed profile back to canonical TOML rather than copying file bytes, so the snapshot is normalized and the
secret-by-reference invariant is structural (it only ever emits the seam *names* it read, never resolves a
token).

**4. The one narrow live step is `mint-token`, and it is the only thing resolved at use.** The executor never
re-reads the live profile; its world is the snapshot. The single exception #153 decision 4 carves out is the
credential, because a token must never be frozen into a record. `mint-token <env-var-name>` reads the named env
var (the snapshot's `token_cmd_env` *value*), runs the command it holds, and prints the fresh token to stdout —
fail closed (non-zero, clear message) if the env var is unset or the command fails. It prints **only** the
token, so a caller can `TOKEN=$(aar_profile.py mint-token "$(...token_cmd_env...)")` without scrubbing noise.

**5. Packaged per-skill, byte-identical, drift-checked — the SCHEMA.md / feedback-loop precedent.**
`experiment-lifecycle` ships two independently-installed skills and symlinks per-skill, so a module-level helper
has no single install-resolvable home. The helper ships at both
`plugins/experiment-lifecycle/skills/design-experiment/scripts/aar_profile.py` and
`plugins/experiment-lifecycle/skills/run-experiment/scripts/aar_profile.py`, byte-identical, with a `cmp -s`
drift guard added to `.aar-ci/checks.sh` mirroring the existing SCHEMA.md and feedback-loop init guards. Each
skill resolves the helper relative to itself. (Both copies of SCHEMA.md are already identical, so the helper
reading its sibling SCHEMA.md sees the same constant from either skill dir.)

**6. Stdlib only — `tomllib`, `json`, `hashlib`, `subprocess`.** #153 decision argues against any non-stdlib
parser dependency (the reason YAML is rejected). The helper parses `.toml` with `tomllib` (Python 3.11+) and
`.json` with `json`, hashes file bytes with `hashlib.sha256`, and serializes the snapshot TOML by hand (a small,
deterministic emitter — no `tomli_w` dependency). This keeps the helper installable anywhere the product runs
with zero extra packages.

### Scope boundary (what this child does NOT do)

- **No schema validation.** `resolve` checks only what discovery itself requires: the file parses, and its
  `schema_version` MAJOR is known. Full field/type/requiredness validation, identity-command runnability, the
  `branch_prefix == run/` check, and recipe-pointer resolution are **#194's `aar-profile-validate`**. (`resolve`
  will surface a parse error or a missing `schema_version` as a fail-closed BLOCK, since it cannot snapshot
  without them — but it is not the validator.)
- **No enforcement.** It mints a token on request but never posts a review, opens a PR, or checks protection —
  those are the gates (#146/#150/#154/#156/#157).
- **No skill rewiring.** The `design-experiment`/`run-experiment` prose edits that *call* this helper are
  child #4; this child ships the callable + its smoke so #4 builds against a proven seam.

## Smoke

`aar_profile_smoke.sh` (packaged in the run-experiment skill dir, run by `.aar-ci/checks.sh` when the helper or
its smoke changes) covers the behavior the JSON/syntax checks can't:

- **resolve via `$AAR_PROFILE`** on a fixture `.toml` → prints the path + a correct `profile_sha256` (compared
  against an independent `sha256sum`).
- **fail-closed on a missing profile** → `BLOCKED: no instance profile found (looked: …)`, non-zero exit, with
  `$AAR_PROFILE` unset and the module config home pointed at an empty dir.
- **refuse an unknown MAJOR** → a fixture with `schema_version` above the SCHEMA.md constant fails closed.
- **`.toml`-wins precedence** → both files present at the module home, the `.toml` resolves and the `.json` is
  noted shadowed.
- **mint via the seam name** → an env var holding `echo FRESH-TOKEN` is minted to exactly `FRESH-TOKEN`;
  fail-closed when the named env var is unset.
- **snapshot round-trips through a parser** — the load-bearing one (#153 rollout): the emitted fenced-TOML
  `## Instance profile (snapshot)` block is extracted from the fence and re-parsed with `tomllib`, asserting
  every non-secret field (github scalars, both identity seam-name pairs, protection, a repo- and a uri-kind
  recipe pointer, `profile_sha256`) survives the round-trip — proving the consumed grammar is machine-readable.

## Alternatives considered

- **Bash helper instead of Python.** Rejected — TOML parsing in bash is exactly the ambiguity #153 rejects YAML
  for; `tomllib` is stdlib and gives an unambiguous parse. The token step shells out either way; the parse/hash/
  serialize steps want a real parser.
- **One combined "resolve+snapshot" subcommand.** Rejected — `design-experiment` resolves once and writes the
  snapshot into the pre-audit brief commit; keeping `resolve` (path + hash + version check) and `snapshot`
  (the block) as separate verbs lets the skill report the resolved path to the human before serializing, and
  keeps the smoke able to assert each independently. They share one parse internally.
- **Copy the profile file bytes verbatim into the snapshot.** Rejected — re-serializing the parsed structure
  normalizes the block (so the smoke's round-trip is meaningful) and makes the secret-by-reference invariant
  structural: the emitter only ever has the seam names, never a resolved token, so it *cannot* leak one even if
  the source file were malformed.
- **Add validation here.** Rejected as scope creep / duplication — #194 is the named init/validate owner;
  `resolve` does only the discovery-minimal parse+version check it cannot skip.
- **Depend on `tomli_w` for serialization.** Rejected — a non-stdlib dependency for a handful of flat tables; a
  small hand-rolled emitter (strings quoted, bools lowercased, tables headed) is deterministic and dependency-
  free, and the round-trip smoke guards it.

## Blast radius

- **New product files:** `aar_profile.py` (×2, byte-identical) + `aar_profile_smoke.sh` (×1) under
  `experiment-lifecycle`, plus a `.aar-ci/checks.sh` clause (drift guard + run the smoke) and the
  `experiment-lifecycle` plugin version bump.
- **No behavior change to any existing skill** — the helper is callable but not yet called; child #4 wires it.
  Nothing that runs today changes.
- **Cluster coupling:** consumes #193's SCHEMA.md (the constant + field layout) and the #153 snapshot grammar;
  is consumed by child #4 (skill edits) and, transitively, by #156/#157 (which read the snapshot the skills
  write). Adjacent to #194 (sibling init/validate — shares the schema, not code).

## Rollout + rollback

Lands the helper + smoke + the `.aar-ci` clause on `main` via the normal single-phase `--code` gate. The
helper is inert until child #4 calls it, so landing it changes no running behavior — it is validated in
isolation by its own smoke first (the #153 rollout's "ship and unit-smoke before any skill consumes them"
staging). Rollback is a plain revert of these files; nothing depends on the helper until #4 lands, so a revert
before then is a clean no-op.
