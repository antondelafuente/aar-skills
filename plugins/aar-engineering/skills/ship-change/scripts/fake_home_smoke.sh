#!/bin/bash
# fake_home_smoke.sh — behavior test: a plugin must INSTALL into a virgin HOME and its skills must RESOLVE.
# Deterministic checks (JSON/syntax) can't catch an install/discovery break; this can. Gates auto-merge.
# Args: <marketplace-source-repo> <plugin-name>.  Exit non-zero on any failure. Destroys the fake HOME after.
set -uo pipefail
REPO=${1:?marketplace source repo}; PLUG=${2:?plugin name}
V="${TMPDIR:-/tmp}/smoke-$PLUG-$$"
cleanup(){ rm -rf "$V"; }
trap cleanup EXIT
fail=0; err(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }

mkdir -p "$V/.claude" "$V/proj"
# seed the minimum to run `claude plugin` headlessly (creds only; everything else virgin)
cp "$HOME/.claude/.credentials.json" "$V/.claude/.credentials.json" 2>/dev/null || err "no credentials to seed"
cp "$HOME/.git-credentials" "$V/.git-credentials" 2>/dev/null || true
python3 -c "import json,os;s=json.load(open(os.path.expanduser('~/.claude.json')));json.dump({k:s[k] for k in ('oauthAccount','userID','hasCompletedOnboarding','firstStartTime') if k in s},open('$V/.claude.json','w'))" 2>/dev/null || err "could not seed .claude.json"

cd "$V/proj"
HOME="$V" claude plugin marketplace add "$REPO" >/dev/null 2>&1 || err "marketplace add failed"
HOME="$V" claude plugin install "$PLUG@$(basename "$REPO")" >/dev/null 2>&1 || err "plugin install failed: $PLUG"

# installed cache for this plugin (highest version)
PDIR=$(find "$V/.claude/plugins/cache" -maxdepth 3 -type d -path "*/$PLUG/*" 2>/dev/null | sort -V | tail -1)
[ -n "$PDIR" ] && [ -d "$PDIR" ] || err "plugin did not land in the install cache: $PLUG"

if [ -n "${PDIR:-}" ]; then
  # plugin.json valid + every skill resolves (SKILL.md present) + no instance-leak in installed skill files
  python3 -c "import json;json.load(open('$PDIR/.claude-plugin/plugin.json'))" 2>/dev/null || err "installed plugin.json invalid"
  found=0
  for sk in "$PDIR"/skills/*/SKILL.md; do
    [ -f "$sk" ] || continue; found=1
    grep -qiE '^name:' "$sk" || err "skill missing 'name:' frontmatter: $sk"
    grep -qiE '^description:' "$sk" || err "skill missing 'description:' frontmatter: $sk"
  done
  [ "$found" = 1 ] || err "no resolvable skills (skills/*/SKILL.md) in installed $PLUG"
fi
# (leak-scanning is NOT a behavior test — it lives in the deterministic checks on the diff, and the
#  cross-family --code review is the judgment-based catch. A blunt grep over-flags doc-examples.)

[ "$fail" = 0 ] && { echo "  smoke ok: $PLUG installs + resolves in a virgin HOME" >&2; exit 0; } || exit 1
