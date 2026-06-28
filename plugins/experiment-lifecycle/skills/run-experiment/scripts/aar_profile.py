#!/usr/bin/env python3
"""aar-profile discovery + START.md snapshot helper (#153 child #195).

Executes the #153 contract the SCHEMA.md reference (#193) declares: resolve the live instance execution
profile by the fixed discovery lookup order, refuse an unknown MAJOR / fail closed if none, and emit the
fenced-TOML ``## Instance profile (snapshot)`` block the designer freezes into START.md.

Scope (deliberately narrow):
  * ``resolve``  — designer step: walk the lookup order, check schema_version against the product constant,
                   print the resolved path + profile_sha256. Discovery-minimal parse only.
  * ``snapshot`` — designer step: emit the snapshot block (every NON-SECRET execution field + profile_sha256).

NOT here: schema validation (that is #194 ``aar-profile-validate``), enforcement (the gates), and token
minting (engineer-identity token resolution is #150's shared GitHub-lifecycle helper — this helper carries
the seam *names* through to the snapshot but never runs a minting command, so it runs no external command at
all). stdlib only; Python 3.11+ (``tomllib``) is the runtime floor.

Both verbs resolve the SAME file by the SAME lookup; ``snapshot`` computes profile_sha256 from the very bytes
it parses, so the reported resolution and the frozen snapshot can never diverge.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# --- runtime floor (FINDING 4): tomllib is stdlib only on Python 3.11+ -------------------------------------
try:
    import tomllib
except ModuleNotFoundError:
    sys.stdout.write("BLOCKED: aar_profile needs Python 3.11+ (tomllib)\n")
    sys.exit(2)

SNAPSHOT_HEADING = "## Instance profile (snapshot)"
# The non-secret execution fields the executor reads later (#153 decision 4 / FINDING 1): the snapshot carries
# every one of these, never a token. Recipe tables are typed and pass through whole.
GITHUB_SCALARS = ("research_repo", "base_branch", "branch_prefix", "issue_repo", "private")
IDENTITY_KEYS = ("token_cmd_env", "git_author_env")  # env-var NAMES, never secrets
PROTECTION_KEYS = ("require_pr_review", "enforce_admins")


def _die(msg, code=2):
    sys.stdout.write(msg if msg.endswith("\n") else msg + "\n")
    sys.exit(code)


def product_schema_version():
    """The product schema_version constant — extracted from the sibling SCHEMA.md marker, never hardcoded.

    #193 fixed the constant as one machine-extractable ``<!-- SCHEMA_VERSION: N -->`` line so readers extract
    it. The helper and SCHEMA.md ship byte-identical in the same skill dir, so the constant is always the one
    that shipped with this helper.
    """
    schema = Path(__file__).resolve().parent.parent / "references" / "SCHEMA.md"
    if not schema.is_file():
        _die(f"BLOCKED: cannot find product SCHEMA.md (looked: {schema})")
    markers = re.findall(r"^<!-- SCHEMA_VERSION: (\d+) -->$", schema.read_text(), flags=re.M)
    if len(markers) != 1:
        _die(f"BLOCKED: SCHEMA.md must carry exactly one integer SCHEMA_VERSION marker (found {len(markers)})")
    return int(markers[0])


def candidate_paths():
    """The fixed discovery lookup order (#153 decision 1), as (label, Path) in precedence order.

    1. ``$AAR_PROFILE`` — explicit override / test seam only.
    2. ``${XDG_CONFIG_HOME:-~/.config}/experiment-lifecycle/aar-profile.toml`` then ``.json`` (.toml wins).
    """
    out = []
    override = os.environ.get("AAR_PROFILE")
    if override:
        out.append(("$AAR_PROFILE", Path(override).expanduser()))
    cfg_home = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    base = Path(cfg_home).expanduser() / "experiment-lifecycle"
    out.append(("module-config (.toml)", base / "aar-profile.toml"))
    out.append(("module-config (.json)", base / "aar-profile.json"))
    return out


def resolve_path():
    """Return the first existing profile path by the lookup order, or fail closed.

    Notes a shadowed ``.json`` on stderr when a ``.toml`` wins at the module config home.
    """
    cands = candidate_paths()
    chosen = None
    for _, p in cands:
        if p.is_file():
            chosen = p
            break
    if chosen is None:
        looked = ", ".join(str(p) for _, p in cands)
        _die(f"BLOCKED: no instance profile found (looked: {looked})")
    # warn on a shadowed .json when the .toml at the module home wins
    if chosen.suffix == ".toml":
        sib = chosen.with_suffix(".json")
        if sib.is_file():
            sys.stderr.write(f"note: {sib} is shadowed by {chosen} (.toml wins)\n")
    return chosen


def load_profile(path):
    """Parse + hash the profile. Discovery-minimal: parse the file and read schema_version; refuse an unknown
    MAJOR. Full field/type validation is #194's; this only does what discovery itself cannot skip."""
    raw = path.read_bytes()
    sha = hashlib.sha256(raw).hexdigest()
    try:
        if path.suffix == ".json":
            data = json.loads(raw.decode("utf-8"))
        else:
            data = tomllib.loads(raw.decode("utf-8"))
    except Exception as exc:  # parse error -> fail closed (cannot snapshot an unparseable profile)
        _die(f"BLOCKED: cannot parse profile {path}: {exc}")
    if not isinstance(data, dict) or "schema_version" not in data:
        _die(f"BLOCKED: profile {path} missing required schema_version")
    sv = data["schema_version"]
    if not isinstance(sv, int) or isinstance(sv, bool):
        _die(f"BLOCKED: profile {path} schema_version must be an integer (got {sv!r})")
    product = product_schema_version()
    if sv > product:
        _die(f"BLOCKED: profile {path} schema_version {sv} exceeds product schema_version {product} "
             f"(refuse-unknown-MAJOR)")
    return data, sha


# --- snapshot serialization: a small deterministic TOML emitter (no tomli_w dependency) --------------------

def _emit_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    raise ValueError(f"unsupported snapshot value type: {type(v).__name__}")


def _emit_table(lines, header, table, keys=None):
    """Append a ``[header]`` table with the given keys (or all, sorted) if any present."""
    if not isinstance(table, dict):
        return
    items = [(k, table[k]) for k in (keys or sorted(table)) if k in table]
    if not items:
        return
    lines.append(f"[{header}]")
    for k, v in items:
        lines.append(f"{k} = {_emit_scalar(v)}")
    lines.append("")


def build_snapshot_toml(data, sha, profile_path):
    """Serialize every NON-SECRET execution field into canonical snapshot TOML (the body of the fenced block).

    Re-serializes the parsed structure (never copies file bytes), so the emitter only ever holds seam *names*,
    never a resolved token — the secret-by-reference invariant is structural.
    """
    gh = data.get("github", {}) or {}
    identity = gh.get("identity", {}) or {}
    protection = gh.get("protection", {}) or {}
    recipes = data.get("recipes", {}) or {}

    lines = []
    lines.append(f'profile_path    = {_emit_scalar(str(profile_path))}')
    lines.append(f'profile_sha256  = {_emit_scalar(sha)}')
    lines.append(f'schema_version  = {_emit_scalar(data["schema_version"])}')
    lines.append("")

    _emit_table(lines, "github", gh, GITHUB_SCALARS)
    for fam in sorted(identity):
        _emit_table(lines, f"identity.{fam}", identity[fam], IDENTITY_KEYS)
    _emit_table(lines, "protection", protection, PROTECTION_KEYS)
    # recipe pointers: typed, fully-addressable — pass each table through whole (kind + kind-appropriate keys)
    for name in sorted(recipes):
        _emit_table(lines, f"recipes.{name}", recipes[name])

    # drop a trailing blank line for a clean block
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def build_snapshot_block(data, sha, profile_path):
    body = build_snapshot_toml(data, sha, profile_path)
    return f"{SNAPSHOT_HEADING}\n```toml\n{body}\n```\n"


# --- subcommands ------------------------------------------------------------------------------------------

def cmd_resolve(_args):
    path = resolve_path()
    _, sha = load_profile(path)
    sys.stdout.write(f"profile_path={path}\nprofile_sha256={sha}\n")
    return 0


def cmd_snapshot(args):
    if args.path:
        path = Path(args.path).expanduser()
        if not path.is_file():
            _die(f"BLOCKED: no such profile (--path {path})")
    else:
        path = resolve_path()
    data, sha = load_profile(path)
    sys.stdout.write(build_snapshot_block(data, sha, path))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="aar_profile.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("resolve", help="resolve the live profile; print path + profile_sha256 (fail closed if none)")
    sp = sub.add_parser("snapshot", help="emit the fenced-TOML START.md snapshot block")
    sp.add_argument("--path", help="snapshot this exact profile file (override/test seam); else resolve")
    args = p.parse_args(argv)
    if args.cmd == "resolve":
        return cmd_resolve(args)
    if args.cmd == "snapshot":
        return cmd_snapshot(args)
    p.error(f"unknown command: {args.cmd}")  # unreachable (required=True)


if __name__ == "__main__":
    sys.exit(main())
