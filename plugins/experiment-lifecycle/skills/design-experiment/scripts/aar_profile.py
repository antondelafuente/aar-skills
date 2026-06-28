#!/usr/bin/env python3
"""aar-profile init/validate — the experiment-lifecycle module's init owner (#153 child 2 / #194).

Two subcommands:

  init      Scaffold ~/.config/experiment-lifecycle/aar-profile.toml from the v1 schema with an
            instance's values (env-driven, interactive fallback). Refuse-to-clobber without --force,
            atomic write, runs a structural validate on its own output. Writes only seam env-var
            NAMES, never a secret (#153 decision 7).

  validate  Resolve a profile by the #153 discovery lookup (or a path arg), parse it, and check it
            against the v1 schema: schema_version known (refuse-unknown-MAJOR), required fields
            present + typed, branch_prefix == #129's run/, recipe pointers kind-typed, identity seams
            well-formed. STRUCTURAL by default; --resolve adds the network/env liveness layer (git
            ls-remote for repo pointers, seam-env-is-wired for identities). Fail-closed (exit !=0) on
            any error; warn on a .json shadowed by a .toml.

The product schema_version constant is extracted from the sibling references/SCHEMA.md marker
(<!-- SCHEMA_VERSION: N -->), never hardcoded (#193 decision 1). The typed FIELD checks are the
executable canonical home here in Python; SCHEMA.md is the human contract beside it, with the
SCHEMA.md-changed smoke dispatch in .aar-ci/checks.sh as the drift guard.

Stdlib only (tomllib + json) — no non-stdlib parser dependency (#153 / SCHEMA.md).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

# --- discovery (SCHEMA.md "Discovery — the lookup order", #153 decision 1) ---------------------

MODULE = "experiment-lifecycle"
PROFILE_BASENAME = "aar-profile"
REQUIRED_BRANCH_PREFIX = "run/"  # #129 convention; the two contracts meet here.
SUPPORTED_RECIPE_KINDS = ("repo", "uri")
SUPPORTED_URI_SCHEMES = ("r2://", "s3://", "https://")
OWNER_REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
GIT_AUTHOR_RE = re.compile(r"^.+ <[^<>@\s]+@[^<>@\s]+>$")


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(base) / MODULE


def discover_profile() -> tuple[Path | None, list[str]]:
    """Return (resolved_path_or_None, paths_looked). First that exists wins; .toml beats .json."""
    looked: list[str] = []
    override = os.environ.get("AAR_PROFILE")
    if override:
        looked.append(f"$AAR_PROFILE={override}")
        return (Path(override) if Path(override).exists() else None), looked
    d = config_dir()
    toml_p = d / f"{PROFILE_BASENAME}.toml"
    json_p = d / f"{PROFILE_BASENAME}.json"
    looked.append(str(toml_p))
    looked.append(str(json_p))
    if toml_p.exists():
        return toml_p, looked
    if json_p.exists():
        return json_p, looked
    return None, looked


def schema_version_constant() -> int:
    """Extract the product schema_version from the sibling references/SCHEMA.md marker (one home)."""
    schema_md = Path(__file__).resolve().parent.parent / "references" / "SCHEMA.md"
    if not schema_md.exists():
        die(f"SCHEMA.md not found beside the helper (looked: {schema_md})")
    markers = re.findall(r"^<!-- SCHEMA_VERSION: (\d+) -->$", schema_md.read_text(), flags=re.M)
    if len(markers) != 1:
        die(f"SCHEMA.md must carry exactly one integer SCHEMA_VERSION marker (found {len(markers)})")
    return int(markers[0])


# --- small helpers ------------------------------------------------------------------------------

def die(msg: str, code: int = 1) -> None:
    print(f"BLOCKED: {msg}", file=sys.stderr)
    sys.exit(code)


def load_profile(path: Path) -> dict:
    raw = path.read_bytes()
    try:
        if path.suffix == ".json":
            return json.loads(raw.decode("utf-8"))
        return tomllib.loads(raw.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — surface any parse error as a fail-closed validate error
        die(f"could not parse profile {path}: {exc}")
    return {}  # unreachable; satisfies type checkers


# --- validate -----------------------------------------------------------------------------------

class Errors:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def err(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def _require(d: dict, key: str, typ, label: str, e: Errors):
    if key not in d:
        e.err(f"missing required field: {label}")
        return None
    val = d[key]
    # bool is a subclass of int — guard so a bool never satisfies an int field and vice-versa
    if typ is bool and not isinstance(val, bool):
        e.err(f"{label} must be a bool (got {type(val).__name__})")
        return None
    if typ is int and (isinstance(val, bool) or not isinstance(val, int)):
        e.err(f"{label} must be an int (got {type(val).__name__})")
        return None
    if typ is str and not isinstance(val, str):
        e.err(f"{label} must be a string (got {type(val).__name__})")
        return None
    return val


def _check_identity(github: dict, fam: str, e: Errors, resolve: bool):
    identity = github.get("identity")
    if not isinstance(identity, dict) or fam not in identity:
        e.err(f"missing required table: [github.identity.{fam}]")
        return
    fam_tbl = identity[fam]
    if not isinstance(fam_tbl, dict):
        e.err(f"[github.identity.{fam}] must be a table")
        return
    for field in ("token_cmd_env", "git_author_env"):
        name = _require(fam_tbl, field, str, f"[github.identity.{fam}].{field}", e)
        if name is None:
            continue
        if not ENV_NAME_RE.match(name):
            e.err(f"[github.identity.{fam}].{field} = {name!r} is not a valid env-var name")
            continue
        if resolve:
            _resolve_seam(fam, field, name, e)


def _resolve_seam(fam: str, field: str, env_name: str, e: Errors):
    """--resolve layer: confirm the seam env var is wired in THIS environment. Never mints a token."""
    val = os.environ.get(env_name)
    if val is None or val.strip() == "":
        e.err(f"[github.identity.{fam}].{field} names env var {env_name} which is unset/empty "
              f"(--resolve: the seam is not wired in this environment)")
        return
    if field == "token_cmd_env":
        first = val.split()[0]
        if shutil.which(first) is None and not (os.path.isfile(first) and os.access(first, os.X_OK)):
            e.err(f"[github.identity.{fam}].token_cmd_env ({env_name}) value's command {first!r} "
                  f"is not a runnable command on PATH")
    elif field == "git_author_env":
        if not GIT_AUTHOR_RE.match(val.strip()):
            e.err(f"[github.identity.{fam}].git_author_env ({env_name}) = {val!r} "
                  f"does not look like 'Name <email>'")


def _check_recipe(name: str, tbl, e: Errors, resolve: bool):
    if not isinstance(tbl, dict):
        e.err(f"[recipes.{name}] must be a table")
        return
    kind = tbl.get("kind")
    if kind not in SUPPORTED_RECIPE_KINDS:
        e.err(f"[recipes.{name}].kind must be one of {SUPPORTED_RECIPE_KINDS} (got {kind!r})")
        return
    if kind == "repo":
        repo = _require(tbl, "repo", str, f"[recipes.{name}].repo", e)
        path = _require(tbl, "path", str, f"[recipes.{name}].path", e)
        git_ref = _require(tbl, "git_ref", str, f"[recipes.{name}].git_ref", e)
        if repo is not None and not OWNER_REPO_RE.match(repo):
            e.err(f"[recipes.{name}].repo = {repo!r} is not an owner/repo string")
        if resolve and repo and OWNER_REPO_RE.match(repo) and git_ref:
            _resolve_repo(name, repo, git_ref, e)
    elif kind == "uri":
        uri = _require(tbl, "uri", str, f"[recipes.{name}].uri", e)
        sha = _require(tbl, "sha256", str, f"[recipes.{name}].sha256", e)
        if uri is not None and not any(uri.startswith(s) for s in SUPPORTED_URI_SCHEMES):
            e.err(f"[recipes.{name}].uri scheme not in supported set {SUPPORTED_URI_SCHEMES}: {uri!r}")
        if sha is not None and not re.match(r"^[0-9a-fA-F]{64}$", sha):
            e.err(f"[recipes.{name}].sha256 = {sha!r} is not a 64-char hex digest")
        if resolve and uri is not None:
            # No product-owned resolver seam for r2://,s3://,https:// pointers yet (owned by #150/#157);
            # report rather than fail a structurally-valid pointer.
            e.warn(f"[recipes.{name}] uri-kind liveness probe skipped: no resolver available for "
                   f"scheme (owned by #150/#157)")


def _resolve_repo(name: str, repo: str, git_ref: str, e: Errors):
    """--resolve repo-kind liveness: confirm the ref exists via git ls-remote (ambient git auth)."""
    url = repo if repo.startswith(("http://", "https://", "git@")) else f"https://github.com/{repo}.git"
    try:
        out = subprocess.run(
            ["git", "ls-remote", url, git_ref, f"{git_ref}^{{}}"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        e.err(f"[recipes.{name}] --resolve: git ls-remote {url} failed: {exc}")
        return
    if out.returncode != 0:
        e.err(f"[recipes.{name}] --resolve: git ls-remote {url} rc={out.returncode}: "
              f"{out.stderr.strip()}")
        return
    if not out.stdout.strip():
        # ls-remote with a sha narrows to nothing if the sha isn't an advertised ref; fall back to a
        # full listing and substring-match the sha (a commit sha is not advertised but may exist).
        full = subprocess.run(["git", "ls-remote", url], capture_output=True, text=True, timeout=30)
        if full.returncode == 0 and git_ref in full.stdout:
            return
        e.err(f"[recipes.{name}] --resolve: ref {git_ref!r} not found at {url}")


def validate_profile(path: Path, resolve: bool) -> Errors:
    e = Errors()
    known_major = schema_version_constant()

    # shadowed-file warning (only meaningful for the module config path, not an explicit/override path)
    d = config_dir()
    if path.parent == d and path.suffix == ".toml" and (d / f"{PROFILE_BASENAME}.json").exists():
        e.warn(f"{PROFILE_BASENAME}.json is shadowed by {PROFILE_BASENAME}.toml (.toml wins)")

    prof = load_profile(path)
    if not isinstance(prof, dict):
        e.err("profile root must be a table/object")
        return e

    # 1. schema_version — present, int, known MAJOR (refuse-unknown-MAJOR, #153 decision 5)
    sv = _require(prof, "schema_version", int, "schema_version", e)
    if sv is not None and sv != known_major:
        e.err(f"unknown schema_version MAJOR: profile declares {sv}, product understands {known_major} "
              f"(refuse-unknown-MAJOR)")

    # 2. [github] required block
    github = prof.get("github")
    if not isinstance(github, dict):
        e.err("missing required table: [github]")
        github = {}
    research_repo = _require(github, "research_repo", str, "[github].research_repo", e)
    if research_repo is not None and not OWNER_REPO_RE.match(research_repo):
        e.err(f"[github].research_repo = {research_repo!r} is not an owner/repo string")
    _require(github, "base_branch", str, "[github].base_branch", e)
    branch_prefix = _require(github, "branch_prefix", str, "[github].branch_prefix", e)
    _require(github, "private", bool, "[github].private", e)
    # issue_repo optional, but typed when present
    if "issue_repo" in github:
        ir = github["issue_repo"]
        if not isinstance(ir, str) or not OWNER_REPO_RE.match(ir):
            e.err(f"[github].issue_repo = {ir!r} is not an owner/repo string")

    # 3. branch_prefix matches #129's run/
    if branch_prefix is not None and branch_prefix != REQUIRED_BRANCH_PREFIX:
        e.err(f"[github].branch_prefix = {branch_prefix!r} must equal #129's {REQUIRED_BRANCH_PREFIX!r}")

    # 4. identity seams (structural; --resolve adds wiring)
    _check_identity(github, "claude", e, resolve)
    _check_identity(github, "codex", e, resolve)

    # protection: optional bools when present
    prot = github.get("protection")
    if prot is not None:
        if not isinstance(prot, dict):
            e.err("[github.protection] must be a table")
        else:
            for k in ("require_pr_review", "enforce_admins"):
                if k in prot and not isinstance(prot[k], bool):
                    e.err(f"[github.protection].{k} must be a bool")

    # 5. recipes (structural; --resolve adds liveness)
    recipes = prof.get("recipes")
    if recipes is not None:
        if not isinstance(recipes, dict):
            e.err("[recipes] must be a table")
        else:
            for rname, rtbl in recipes.items():
                _check_recipe(rname, rtbl, e, resolve)

    return e


def cmd_validate(args: argparse.Namespace) -> int:
    if args.path:
        path = Path(args.path)
        if not path.exists():
            die(f"no profile at {path}")
    else:
        path, looked = discover_profile()
        if path is None:
            die(f"no instance profile found (looked: {', '.join(looked)})")
    e = validate_profile(path, resolve=args.resolve)
    for w in e.warnings:
        print(f"WARN: {w}", file=sys.stderr)
    if e.errors:
        for er in e.errors:
            print(f"INVALID: {er}", file=sys.stderr)
        print(f"BLOCKED: profile {path} failed validation ({len(e.errors)} error(s))", file=sys.stderr)
        return 1
    print(f"OK: profile {path} valid"
          f"{' (structural only; pass --resolve for liveness)' if not args.resolve else ' (with --resolve)'}")
    return 0


# --- init ---------------------------------------------------------------------------------------

INIT_FIELDS = [
    ("AAR_RESEARCH_REPO", "research_repo", "Research repo (OWNER/REPO)", True),
    ("AAR_BASE_BRANCH", "base_branch", "Base branch", True),
    ("AAR_ISSUE_REPO", "issue_repo", "Issue repo (OWNER/REPO, optional; defaults to research_repo)", False),
]


def _ask(env_name: str, prompt: str, required: bool, default: str = "") -> str:
    val = os.environ.get(env_name, "").strip()
    if not val and sys.stdin.isatty():
        suffix = f" [{default}]" if default else ""
        entered = input(f"{prompt}{suffix}: ").strip()
        val = entered or default
    elif not val:
        val = default
    if required and not val:
        die(f"{env_name} required (set {env_name}=... or run interactively)")
    return val


def _toml_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def cmd_init(args: argparse.Namespace) -> int:
    d = config_dir()
    out = d / f"{PROFILE_BASENAME}.toml"
    if out.exists() and not args.force:
        die(f"profile already exists at {out} (pass --force to overwrite)")

    research_repo = _ask("AAR_RESEARCH_REPO", "Research repo (OWNER/REPO)", True)
    if not OWNER_REPO_RE.match(research_repo):
        die(f"AAR_RESEARCH_REPO must look like OWNER/REPO (got {research_repo!r})")
    base_branch = _ask("AAR_BASE_BRANCH", "Base branch", True, default="main")
    issue_repo = _ask("AAR_ISSUE_REPO", "Issue repo (OWNER/REPO, optional)", False)
    if issue_repo and not OWNER_REPO_RE.match(issue_repo):
        die(f"AAR_ISSUE_REPO must look like OWNER/REPO (got {issue_repo!r})")
    private = os.environ.get("AAR_PRIVATE", "true").strip().lower() not in ("false", "0", "no")

    # identity seam NAMES (env-var names, never secrets — #153 decision 7); sensible defaults match the
    # SCHEMA.md authoring example so an instance can override only what differs.
    claude_tok = os.environ.get("AAR_IDENT_CLAUDE_TOKEN_CMD_ENV", "AAR_RESEARCH_TOKEN_CMD_CLAUDE")
    claude_auth = os.environ.get("AAR_IDENT_CLAUDE_GIT_AUTHOR_ENV", "AAR_RESEARCH_GIT_AUTHOR_CLAUDE")
    codex_tok = os.environ.get("AAR_IDENT_CODEX_TOKEN_CMD_ENV", "AAR_RESEARCH_TOKEN_CMD_CODEX")
    codex_auth = os.environ.get("AAR_IDENT_CODEX_GIT_AUTHOR_ENV", "AAR_RESEARCH_GIT_AUTHOR_CODEX")

    lines = [
        "# aar-profile — instance execution profile. Generated by aar-profile-init.",
        "# Schema: experiment-lifecycle references/SCHEMA.md (v1). NON-SECRET: identity values are env-var",
        "# NAMES, never tokens (#153 decision 7). Edit by hand or re-run init --force.",
        f"schema_version = {schema_version_constant()}",
        "",
        "[github]",
        f"research_repo = {_toml_str(research_repo)}",
        f"base_branch   = {_toml_str(base_branch)}",
        f"branch_prefix = {_toml_str(REQUIRED_BRANCH_PREFIX)}",
    ]
    if issue_repo:
        lines.append(f"issue_repo    = {_toml_str(issue_repo)}")
    lines += [
        f"private       = {'true' if private else 'false'}",
        "",
        "[github.identity.claude]",
        f"token_cmd_env  = {_toml_str(claude_tok)}",
        f"git_author_env = {_toml_str(claude_auth)}",
        "[github.identity.codex]",
        f"token_cmd_env  = {_toml_str(codex_tok)}",
        f"git_author_env = {_toml_str(codex_auth)}",
        "",
    ]
    content = "\n".join(lines)

    d.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=f"{PROFILE_BASENAME}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, out)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    # validate our own output (structural; init never depends on a live network/env)
    e = validate_profile(out, resolve=False)
    if e.errors:
        for er in e.errors:
            print(f"INVALID: {er}", file=sys.stderr)
        die(f"scaffolded profile {out} failed its own structural validate (this is a bug)")
    print(f"== aar-profile written to {out} ==")
    print("   (non-secret: identity values are env-var NAMES; validate with: aar-profile-validate --resolve)")
    return 0


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="aar_profile", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("init", help="scaffold a profile from the v1 schema")
    pi.add_argument("--force", action="store_true", help="overwrite an existing profile")
    pi.set_defaults(func=cmd_init)

    pv = sub.add_parser("validate", help="validate a profile against the v1 schema")
    pv.add_argument("path", nargs="?", help="profile path (default: discover by the lookup order)")
    pv.add_argument("--resolve", action="store_true",
                    help="also probe liveness/wiring (git ls-remote for repo pointers, seam env wired)")
    pv.set_defaults(func=cmd_validate)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
