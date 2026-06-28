#!/usr/bin/env bash
# Smoke for aar_profile.py — the #153 child #195 discovery + START.md snapshot helper. Covers behavior the
# deterministic JSON/syntax checks can't: the discovery lookup order + fail-closed, refuse-unknown-MAJOR,
# .toml-wins precedence, the tomllib runtime floor, and the load-bearing round-trip of the emitted fenced-TOML
# snapshot block back through a parser (so the consumed grammar is proven machine-readable).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
H="$HERE/aar_profile.py"
[ -f "$H" ] || { echo "FAIL: missing $H"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# A complete fixture profile exercising every non-secret field family + both recipe kinds.
FIX="$TMP/aar-profile.toml"
cat > "$FIX" <<'TOML'
schema_version = 1

[github]
research_repo = "owner/research-lab"
base_branch   = "main"
branch_prefix = "run/"
issue_repo    = "owner/research-lab"
private       = true

[github.identity.claude]
token_cmd_env  = "AAR_RESEARCH_TOKEN_CMD_CLAUDE"
git_author_env = "AAR_RESEARCH_GIT_AUTHOR_CLAUDE"
[github.identity.codex]
token_cmd_env  = "AAR_RESEARCH_TOKEN_CMD_CODEX"
git_author_env = "AAR_RESEARCH_GIT_AUTHOR_CODEX"

[github.protection]
require_pr_review = true
enforce_admins    = true

[recipes.provisioning]
kind    = "repo"
repo    = "owner/research-lab"
path    = "recipes/provisioning.md"
git_ref = "deadbeef"

[recipes.artifact_store]
kind   = "uri"
uri    = "r2://bucket/recipes/artifact-store.md"
sha256 = "abc123"
TOML

# --- tomllib runtime floor (FINDING 4) ---
if python3 -c "import tomllib" 2>/dev/null; then ok tomllib-floor; else no tomllib-floor; fi

# --- resolve via $AAR_PROFILE -> path + correct sha256 ---
out=$(AAR_PROFILE="$FIX" python3 "$H" resolve 2>/dev/null)
rc=$?
got_sha=$(printf '%s\n' "$out" | sed -n 's/^profile_sha256=//p')
want_sha=$(sha256sum "$FIX" | cut -d' ' -f1)
if [ "$rc" = 0 ] && [ "$got_sha" = "$want_sha" ]; then ok resolve-path-sha
else no "resolve-path-sha (rc=$rc got=$got_sha want=$want_sha)"; fi

# --- fail-closed on a missing profile (no override, empty module home) ---
emptyhome="$TMP/emptycfg"; mkdir -p "$emptyhome"
out=$(env -u AAR_PROFILE XDG_CONFIG_HOME="$emptyhome" python3 "$H" resolve 2>/dev/null)
rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^BLOCKED: no instance profile found (looked: '; then
  ok missing-failclosed
else no "missing-failclosed (rc=$rc out=$out)"; fi

# --- refuse an unknown MAJOR (schema_version above the product constant) ---
PROD=$(grep -oE '^<!-- SCHEMA_VERSION: [0-9]+ -->$' "$HERE/../references/SCHEMA.md" | grep -oE '[0-9]+')
FUT="$TMP/future.toml"
sed "s/^schema_version = 1/schema_version = $((PROD + 1))/" "$FIX" > "$FUT"
out=$(AAR_PROFILE="$FUT" python3 "$H" resolve 2>/dev/null)
rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'refuse-unknown-MAJOR'; then ok refuse-unknown-major
else no "refuse-unknown-major (rc=$rc out=$out)"; fi

# --- .toml-wins precedence at the module config home (+ shadowed-.json note) ---
modhome="$TMP/modcfg"; mkdir -p "$modhome/experiment-lifecycle"
cp "$FIX" "$modhome/experiment-lifecycle/aar-profile.toml"
# a DISTINCT json so a wrong pick would change the sha
python3 - "$modhome/experiment-lifecycle/aar-profile.json" <<'PY'
import json, sys
json.dump({"schema_version": 1, "github": {"research_repo": "owner/OTHER", "base_branch": "main",
          "branch_prefix": "run/", "private": True,
          "identity": {"claude": {"token_cmd_env": "X", "git_author_env": "Y"},
                       "codex": {"token_cmd_env": "X", "git_author_env": "Y"}}}}, open(sys.argv[1], "w"))
PY
out=$(env -u AAR_PROFILE XDG_CONFIG_HOME="$modhome" python3 "$H" resolve 2>"$TMP/err")
chosen=$(printf '%s\n' "$out" | sed -n 's/^profile_path=//p')
if [ "$chosen" = "$modhome/experiment-lifecycle/aar-profile.toml" ] && grep -q 'shadowed' "$TMP/err"; then
  ok toml-wins
else no "toml-wins (chosen=$chosen err=$(cat "$TMP/err"))"; fi

# --- snapshot round-trips through a parser (the load-bearing one) ---
AAR_PROFILE="$FIX" python3 "$H" snapshot > "$TMP/snap.md" 2>/dev/null
rc=$?
if [ "$rc" != 0 ]; then no "snapshot-emit (rc=$rc)"; else
  python3 - "$TMP/snap.md" "$want_sha" <<'PY'
import sys, re, tomllib
text = open(sys.argv[1]).read()
want_sha = sys.argv[2]
# fixed heading present
assert text.startswith("## Instance profile (snapshot)"), "missing fixed heading"
# extract the fenced ```toml block
m = re.search(r"```toml\n(.*?)\n```", text, flags=re.S)
assert m, "no fenced toml block"
data = tomllib.loads(m.group(1))   # re-parse: proves machine-readable
# every non-secret field survives the round-trip
assert data["profile_sha256"] == want_sha, ("sha", data.get("profile_sha256"))
assert data["schema_version"] == 1
g = data["github"]
assert g["research_repo"] == "owner/research-lab"
assert g["base_branch"] == "main"
assert g["branch_prefix"] == "run/"
assert g["issue_repo"] == "owner/research-lab"
assert g["private"] is True
# both identity seam-name pairs (NAMES, never secrets)
idc = data["identity"]["claude"]; idx = data["identity"]["codex"]
assert idc["token_cmd_env"] == "AAR_RESEARCH_TOKEN_CMD_CLAUDE"
assert idc["git_author_env"] == "AAR_RESEARCH_GIT_AUTHOR_CLAUDE"
assert idx["token_cmd_env"] == "AAR_RESEARCH_TOKEN_CMD_CODEX"
# protection expectations
assert data["protection"]["require_pr_review"] is True
assert data["protection"]["enforce_admins"] is True
# a repo-kind and a uri-kind recipe pointer, each pinned by its kind-appropriate field
rp = data["recipes"]["provisioning"]
assert rp["kind"] == "repo" and rp["git_ref"] == "deadbeef" and rp["path"] == "recipes/provisioning.md"
ra = data["recipes"]["artifact_store"]
assert ra["kind"] == "uri" and ra["sha256"] == "abc123" and ra["uri"].startswith("r2://")
# the snapshot must NOT contain any resolved token (secret-by-reference): only seam NAMES
assert "FRESH" not in text and "ghp_" not in text
print("roundtrip-ok")
PY
  if [ $? = 0 ]; then ok snapshot-roundtrip; else no snapshot-roundtrip; fi
fi

# --- snapshot --path pins an explicit file ---
out=$(env -u AAR_PROFILE python3 "$H" snapshot --path "$FIX" 2>/dev/null | head -1)
if [ "$out" = "## Instance profile (snapshot)" ]; then ok snapshot-path-pin
else no "snapshot-path-pin ($out)"; fi

[ "$fails" = 0 ] && { echo "[aar_profile_smoke] PASS"; exit 0; } || { echo "[aar_profile_smoke] FAIL"; exit 1; }
