# Proposal: `aar-profile-init` / `aar-profile-validate` — the module init owner (#194)

Closes #194.

## Problem

The merged #153 design replaced the narrative "execution profile" seam with one declarative, versioned
config file (`aar-profile.{toml,json}`) at the experiment-lifecycle module's config path, and #193 landed the
canonical `SCHEMA.md` reference (the v1 field list, the `schema_version` constant, the closed value sets, the
discovery order). But the schema doc is **declaration only** — nothing in the shipped product yet *writes* an
instance's profile from that schema or *checks* a profile against it. #153 decision 1 named that missing piece
the **init owner**: "the profile is written and validated by the experiment-lifecycle module's init/validate
script (`aar-profile-init` / `aar-profile-validate`), not hand-authored ad hoc." Without it, every instance
would hand-author its profile and discover a typo (a wrong-typed field, an unknown MAJOR, an unresolvable
identity seam, a `branch_prefix` that disagrees with #129) only when a downstream gate fails mid-run — exactly
the silent-failure mode #153 exists to prevent.

This child ships that init owner: a script that scaffolds a profile at the module config path from the schema
with an instance's values, and validates a profile against the v1 schema (required fields present + typed,
`schema_version` known with refuse-unknown-MAJOR, each identity `token_cmd_env` resolving to a runnable
command, `branch_prefix` matching #129's `run/`, each `[recipes.*]` pointer resolving by kind, and a warning
on a `.json` shadowed by a `.toml`).

## Approach

Ship one packaged helper — `aar_profile.py` — exposing two subcommands, `init` and `validate`, plus the two
**named wrapper scripts the contract promises** — `aar-profile-init` and `aar-profile-validate` (thin
`exec`-to-`aar_profile.py <sub>` shims) so the #153 / #194 named interface is discoverable on `PATH`-style
invocation, not just as a python subcommand (design-review FINDING 2). The helper extracts the `SCHEMA_VERSION`
constant from the **already-shipped** `SCHEMA.md` marker rather than hardcoding `1` (the same way #153 child 3
will — keeping the version constant in one home). The **typed field checks themselves** (the field table, the
required/optional split, the closed value sets) live as the **executable canonical home in the Python**, with
`SCHEMA.md` the human-readable contract beside it (design-review FINDING 3): SCHEMA.md is not machine-consumed
for the field *layout* (it has no machine-readable schema block, and adding one would re-edit the #193-landed
doc and re-litigate it), so the Python is authoritative for the checks and SCHEMA.md is authoritative for the
version constant + the human spec. A `SCHEMA.md`-changed dispatch in `.aar-ci/checks.sh` already re-runs the
unit smoke, so a field change to the doc that the code must mirror is caught by the smoke's fixtures. Both run
on the Python stdlib only (`tomllib` + `json`), matching #153's "no non-stdlib parser dependency" rule.

- **`init`** scaffolds `${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.toml` from the schema
  with an instance's values, taken from env (non-interactive) or prompts (interactive) — the same
  pattern `feedback_loop_init.sh` already uses for the feedback-loop module config. It refuses to clobber an
  existing profile unless `--force`, writes atomically (tmp + `mv`), and runs `validate --no-resolve` on the
  result so a scaffolded profile is never structurally invalid. It is **non-secret by construction**: it
  writes only the env-var *names* for the identity seams (#153 decision 7), never a token.
- **`validate`** resolves a profile by the #153 discovery lookup (`$AAR_PROFILE` override → module config
  path, `.toml`-wins) or a path argument, parses it, and runs the schema checks below — failing closed (exit
  non-zero) on any error, with a clear per-error message. It is what the init/skill callers run before relying
  on the file.

**Validation checks (exactly #153 decision 1 + the SCHEMA.md field table):**
1. **Parse + `schema_version`** — present, integer, and a *known* MAJOR (== the product constant extracted
   from `SCHEMA.md`); an unknown MAJOR fails closed (refuse-unknown-MAJOR, #153 decision 5).
2. **Required fields present + typed** — `[github]` `research_repo` (`owner/repo`), `base_branch` (str),
   `branch_prefix` (str), `private` (bool); both `[github.identity.claude]` and `[github.identity.codex]` with
   `token_cmd_env` + `git_author_env` (env-var-name strings); `issue_repo` optional (`owner/repo` when
   present). Wrong type / missing required → fail.
3. **`branch_prefix` matches #129** — must equal the product's `run/` convention; a divergent prefix fails
   (the two contracts meet at `run/`, SCHEMA.md normative note).
4. **Identity seams — structural by default, wiring with `--resolve`** — structurally, each family's
   `token_cmd_env` / `git_author_env` must be present env-var-*name* strings (well-formed identifiers). With
   `--resolve`, the helper additionally confirms the seam is *wired in this environment*: the env var named by
   `token_cmd_env` is set AND its value's first token is a runnable command (on `PATH` / executable), and
   `git_author_env` is set and looks like `Name <email>`. This is the "*resolve to a runnable command*" check
   #153 decision 1 + the #194 spec call for — it never *runs* the minter (no token is minted at validate time),
   it only confirms the seam is wired.
5. **`[recipes.*]` pointers, kind-typed structurally; liveness only with `--resolve`** — each present recipe
   table is structurally typed: `kind` in `{repo, uri}`; `kind=repo` requires `repo` (`owner/repo`), `path`,
   `git_ref`; `kind=uri` requires `uri` (scheme in the closed set `{r2://, s3://, https://}`) + `sha256`
   (hex). Structural typing **always runs and fails closed**. The *liveness* probe (does the repo/object
   actually exist at the pinned digest) runs **only with `--resolve`** (decision 3, revised per design-review
   FINDING 1) — because there is **no product-owned resolver seam** for `r2://`/`s3://`/private-repo pointers
   today (those resolvers are owned by #150/#157, the GitHub-helper / close-gate children), so a default-on
   probe would either depend on hidden instance tooling or fail for valid profiles. The repo-kind probe uses
   `git ls-remote` (ambient git auth); the `uri`-kind probe is a no-op-with-warning until a resolver seam
   exists (it reports "resolver not available for scheme" rather than failing a structurally-valid pointer).
6. **Shadowed-file warning** — if both `aar-profile.toml` and `aar-profile.json` exist at the module config
   path, warn that `.json` is shadowed (`.toml` wins) — a warning, not a failure.

**Packaging (the #153 FINDING 1 contract, the feedback-loop precedent).** `experiment-lifecycle` exposes two
independently-installed skills, so the helper is shipped as **two byte-identical copies** —
`design-experiment/scripts/aar_profile.py` and `run-experiment/scripts/aar_profile.py` — with a deterministic
`cmp -s` drift guard added to `.aar-ci/checks.sh`, mirroring exactly how `feedback_loop_init.sh` and #193's
`SCHEMA.md` are already guarded. Each copy reads `SCHEMA.md` relative to itself (its sibling `references/`), so
either skill resolves it when installed alone.

**Unit smoke.** A packaged `aar_profile_smoke.sh` (per the established `*_smoke.sh` convention, run from
`.aar-ci/checks.sh` when the helper OR `SCHEMA.md` changes) exercises the #194 acceptance cases on fixtures:
validate a good fixture profile (pass), fail-closed on a missing profile, refuse an unknown MAJOR, fail on a
missing/mistyped required field, mint a profile via `init` and validate it round-trips, warn on a shadowed
`.json`, and — for the `--resolve` layer — fail on an unwired identity seam and pass once the seam env is set
(no token is minted). The structural cases run the bare (structural) validate; the resolve cases set the seam
env explicitly and use `git ls-remote` against a local throwaway repo, so the smoke needs no external network.
Wiring the smoke to also fire on a `SCHEMA.md` change is the drift guard for FINDING 3: if the doc's field list
changes, the smoke's fixtures catch a code that no longer mirrors it.

### The load-bearing decisions

1. **Python, not bash, for the helper.** The validation needs real TOML/JSON parsing and typed structural
   checks — `tomllib` is stdlib in the product's Python 3.12. A bash entry-point shelling out to inline python
   (the `run_supervision_record.sh` style) would just be a thin wrapper around the same python; a single
   `.py` with a `#!/usr/bin/env python3` shebang is the honest shape and is still
   `py-compile`-checked by `checks.sh`. The smoke stays a `.sh` (the convention the checks dispatcher keys on).
2. **The version constant comes from `SCHEMA.md`; the field checks are the Python's own canonical home.**
   The `SCHEMA_VERSION` is a single machine-extractable marker (#193 decision 1) the helper greps — one home,
   the same contract #153 child 3 will use. The *field table* (types, required/optional, closed sets) has no
   machine-readable block in SCHEMA.md (adding one would re-edit the #193-landed doc and re-litigate the
   schema), so the **Python is the executable canonical home for the typed checks** and SCHEMA.md is the human
   contract beside it; the `SCHEMA.md`-changed smoke dispatch is the drift guard so the two cannot silently
   diverge (design-review FINDING 3).
3. **Structural-only by default; liveness/wiring only with `--resolve`.** Structural validation (types, closed
   sets, required fields, well-formed seam *names*) is pure and **always runs**. The recipe-pointer / identity
   *resolution* (a real repo/object lookup, a `PATH`/env check) needs network/credentials/env AND has **no
   product-owned resolver seam** for `r2://`/`s3://`/private repos today (owned by #150/#157) — so it is **off
   by default** and enabled with `--resolve`, never the other way round (design-review FINDING 1: a default-on
   probe would depend on hidden instance tooling or fail valid profiles). The smoke exercises both layers
   offline.
4. **`init` is non-interactive-first and never writes a secret.** Env-driven (with interactive prompts as the
   fallback), atomic, refuse-to-clobber-without-`--force`, and it writes only seam env-var *names* — the
   profile file stays non-secret and browseable (#153 decision 7), exactly the `feedback_loop_init.sh` shape.
   It runs the bare structural validate on its own output so a scaffolded profile is never structurally invalid.
5. **The named contract ships as wrapper scripts.** `aar-profile-init` / `aar-profile-validate` are thin
   `exec python3 "$(dirname)/aar_profile.py" init|validate "$@"` shims so the interface #153 / #194 *names* is
   the interface that exists on disk, discoverable and consistent with the other named init helpers
   (design-review FINDING 2).

## Alternatives considered

- **Hand-author the profile (no init owner).** Rejected — #153 decision 1 explicitly names the init/validate
  script as the owner; ad-hoc authoring is the silent-typo failure this child prevents.
- **A bash helper shelling out to inline python.** Rejected — the logic *is* python parsing; a single `.py`
  is the honest shape and is still syntax/compile-checked. (The smoke stays `.sh` to match the dispatcher.)
- **A single shared helper under the plugin root.** Rejected — skills install per-skill (symlinked), so a
  plugin-root file is not resolvable when one skill is installed alone. The per-skill copy + byte-identical
  drift check is the feedback-loop precedent #153 FINDING 1 mandates.
- **Hardcode `schema_version = 1` in the helper.** Rejected — splits the constant's source of truth from
  `SCHEMA.md`; extract the marker instead (decision 2).
- **Probe recipe/identity liveness on by default.** Rejected (design-review FINDING 1) — there is no
  product-owned resolver seam for `r2://`/`s3://`/private repos (those live in #150/#157), so default-on would
  depend on hidden instance tooling or fail valid profiles. Structural checks always run; the probe is opt-in
  via `--resolve` (decision 3).
- **Expose only `aar_profile.py init|validate`, no named wrappers.** Rejected (design-review FINDING 2) — the
  contract names `aar-profile-init` / `aar-profile-validate`; the named interface should be the one on disk.
- **Add a machine-readable schema block to `SCHEMA.md` for the validator to consume.** Rejected — it would
  re-edit the #193-landed doc and re-litigate the schema mid-decomposition; the Python is the executable home
  for the checks, the `SCHEMA.md`-changed smoke dispatch is the drift guard (decision 2, FINDING 3).

## Blast radius

- **New product artifacts:** `aar_profile.py` + the named wrappers `aar-profile-init` / `aar-profile-validate`
  + `aar_profile_smoke.sh` (each shipped as two byte-identical per-skill copies under
  `design-experiment/scripts/` and `run-experiment/scripts/`). Purely additive — no existing file's behavior
  changes.
- **`.aar-ci/checks.sh`:** two added guards — a `cmp -s` drift guard for the per-skill copies (mirroring the
  feedback-loop and SCHEMA.md guards) and a dispatch of `aar_profile_smoke.sh` when any `aar_profile.*` copy OR
  a `SCHEMA.md` copy changes (mirroring the other `*_smoke.sh` dispatches; the SCHEMA.md trigger is the
  FINDING-3 drift guard). Deterministic; runs only when those paths change.
- **`experiment-lifecycle/.claude-plugin/plugin.json`:** version bump (non-manifest files changed), per the
  tracked version-bump check.
- **No skill rewiring, no runtime behavior in the skills.** `design-experiment`/`run-experiment` still carry
  their existing narrative seam; #153 child 4 is what swaps the prose for typed reads + calls this helper.
  The instance's own `~/.config/experiment-lifecycle/aar-profile.toml` is written by running `aar-profile-init`
  once — instance content, not a product child.
- **Cluster coupling:** this is #153 child 2, `blocked-by` #193 (now merged). Child 4 (skill edits) is
  `blocked-by` this + child 3. It consumes only the merged `SCHEMA.md`; it contradicts no sibling.

## Rollout + rollback

Lands the helper (two copies) + the smoke (two copies) + the `.aar-ci/checks.sh` guards + the plugin version
bump on `main` through the normal single-phase `ready` ship-change gate (cross-family `--code` review +
deterministic checks + fake-HOME smoke + the new unit smoke). The helper is inert until a caller runs it —
nothing in the shipped skills invokes it yet (child 4 does). Rollback is a plain revert of this PR;
additive-only, so the revert removes the helper, the smoke, and the guards with no data loss and no run impact.
The instance profile written by `init` is inert config — deleting it only re-triggers the fail-closed "no
profile found" discovery path, never a wrong-place mutation.
