#!/usr/bin/env bash
# Unit smoke for aar_profile.py (#194). Behavior the JSON/syntax checks can't catch: the schema checks,
# refuse-unknown-MAJOR, fail-closed on missing/mistyped, the --resolve wiring layer, init round-trip, and
# the shadowed-.json warning. Offline: the one repo-resolve case uses a LOCAL throwaway git repo, no network.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PY="$HERE/aar_profile.py"
INIT="$HERE/aar-profile-init"
VAL="$HERE/aar-profile-validate"
[ -f "$PY" ] || { echo "FAIL: missing $PY"; exit 1; }
[ -x "$INIT" ] && [ -x "$VAL" ] || { echo "FAIL: named wrappers missing/not executable"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Isolate config home so discovery never touches a real instance profile.
export XDG_CONFIG_HOME="$TMP/cfg"
CFGDIR="$XDG_CONFIG_HOME/experiment-lifecycle"
mkdir -p "$CFGDIR"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

# Extract the product schema_version from the sibling SCHEMA.md so fixtures track the constant.
SV=$(grep -oE '^<!-- SCHEMA_VERSION: [0-9]+ -->$' "$HERE/../references/SCHEMA.md" | grep -oE '[0-9]+')
[ -n "$SV" ] || { echo "FAIL: could not read SCHEMA_VERSION from SCHEMA.md"; exit 1; }

good_profile(){ cat <<EOF
schema_version = $SV
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
EOF
}

vfile(){ AAR_PROFILE="$1" python3 "$PY" validate "${@:2}" >/dev/null 2>&1; }

# 1. good fixture validates (structural)
good_profile > "$TMP/good.toml"
if vfile "$TMP/good.toml"; then ok good-structural; else no good-structural; fi

# 2. missing profile fails closed (no path, empty config home, no $AAR_PROFILE)
if env -u AAR_PROFILE python3 "$PY" validate >/dev/null 2>&1; then no missing-failclosed; else ok missing-failclosed; fi

# 3. unknown MAJOR refused
sed "s/^schema_version = $SV/schema_version = $((SV+9))/" "$TMP/good.toml" > "$TMP/badver.toml"
if vfile "$TMP/badver.toml"; then no refuse-unknown-major; else ok refuse-unknown-major; fi

# 4. missing required field (drop research_repo)
grep -v 'research_repo' "$TMP/good.toml" > "$TMP/missing.toml"
if vfile "$TMP/missing.toml"; then no missing-required; else ok missing-required; fi

# 5. mistyped field (private as string)
sed 's/^private       = true/private       = "yes"/' "$TMP/good.toml" > "$TMP/mistype.toml"
if vfile "$TMP/mistype.toml"; then no mistyped; else ok mistyped; fi

# 6. branch_prefix != run/ fails
sed 's#^branch_prefix = "run/"#branch_prefix = "exp/"#' "$TMP/good.toml" > "$TMP/prefix.toml"
if vfile "$TMP/prefix.toml"; then no branch-prefix; else ok branch-prefix; fi

# 7. --resolve fails on an unwired seam (the seam env vars are not set)
if env -u AAR_RESEARCH_TOKEN_CMD_CLAUDE -u AAR_RESEARCH_GIT_AUTHOR_CLAUDE \
     -u AAR_RESEARCH_TOKEN_CMD_CODEX -u AAR_RESEARCH_GIT_AUTHOR_CODEX \
     AAR_PROFILE="$TMP/good.toml" python3 "$PY" validate --resolve >/dev/null 2>&1; then
  no resolve-unwired; else ok resolve-unwired
fi

# 8. --resolve passes once the seam env is wired (token cmds resolve to a real binary; author looks valid)
if AAR_PROFILE="$TMP/good.toml" \
   AAR_RESEARCH_TOKEN_CMD_CLAUDE="true" AAR_RESEARCH_GIT_AUTHOR_CLAUDE="C <c@x.io>" \
   AAR_RESEARCH_TOKEN_CMD_CODEX="true"  AAR_RESEARCH_GIT_AUTHOR_CODEX="X <x@x.io>" \
   python3 "$PY" validate --resolve >/dev/null 2>&1; then ok resolve-wired; else no resolve-wired; fi

# 9. uri-kind recipe: structural typing passes and its --resolve liveness is a warn (no resolver seam yet,
#    owned by #150/#157). Offline — no network probe is performed for a uri-kind pointer.
cat >> "$TMP/good.toml" <<EOF
[recipes.artifact_store]
kind   = "uri"
uri    = "r2://bucket/recipes/a.md"
sha256 = "$(printf '0%.0s' {1..64})"
EOF
if AAR_PROFILE="$TMP/good.toml" \
   AAR_RESEARCH_TOKEN_CMD_CLAUDE="true" AAR_RESEARCH_GIT_AUTHOR_CLAUDE="C <c@x.io>" \
   AAR_RESEARCH_TOKEN_CMD_CODEX="true"  AAR_RESEARCH_GIT_AUTHOR_CODEX="X <x@x.io>" \
   python3 "$PY" validate --resolve 2>&1 | grep -q "uri-kind liveness probe skipped"; then
  ok uri-resolver-warn; else no uri-resolver-warn
fi
# a mis-scheme uri fails structurally
sed 's#r2://bucket/recipes/a.md#ftp://bad/a.md#' "$TMP/good.toml" > "$TMP/badscheme.toml"
if vfile "$TMP/badscheme.toml"; then no uri-scheme; else ok uri-scheme; fi

# 10. init round-trip: scaffold then validate the result
if AAR_RESEARCH_REPO="owner/lab" AAR_BASE_BRANCH="main" "$INIT" </dev/null >/dev/null 2>&1; then
  ok init-scaffold; else no init-scaffold
fi
[ -f "$CFGDIR/aar-profile.toml" ] && ok init-wrote-file || no init-wrote-file
# discovered validate (no path arg) passes on the scaffolded profile
if env -u AAR_PROFILE "$VAL" >/dev/null 2>&1; then ok init-validates; else no init-validates; fi
# refuse-to-clobber without --force
if AAR_RESEARCH_REPO="owner/lab" AAR_BASE_BRANCH="main" "$INIT" </dev/null >/dev/null 2>&1; then
  no init-no-clobber; else ok init-no-clobber
fi
# --force overwrites
if AAR_RESEARCH_REPO="owner/lab2" AAR_BASE_BRANCH="main" "$INIT" --force </dev/null >/dev/null 2>&1; then
  ok init-force; else no init-force
fi

# 11. shadowed .json warns (both files at the config path; .toml wins)
echo '{}' > "$CFGDIR/aar-profile.json"
if env -u AAR_PROFILE "$VAL" 2>&1 | grep -q "shadowed"; then ok shadow-warn; else no shadow-warn; fi
# and discovery still resolves to the .toml (validate passes despite the empty .json)
if env -u AAR_PROFILE "$VAL" >/dev/null 2>&1; then ok shadow-toml-wins; else no shadow-toml-wins; fi

[ "$fails" = 0 ] && { echo "[aar_profile_smoke] PASS"; exit 0; } || { echo "[aar_profile_smoke] FAIL"; exit 1; }
