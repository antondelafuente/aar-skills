#!/bin/bash
# checks_marketplace_smoke.sh — regression smoke for step 6's missing-plugin cross-check in checks.sh (#274).
#
# The check decides whether an absent `plugins/<x>` dir is a benign deletion or a broken marketplace by
# cross-checking the CURRENT `.claude-plugin/marketplace.json` declarations. That logic regressed once
# (#280 had to re-close the marketplace-CHANGED path) and #274 widened it to the marketplace-UNCHANGED
# path, so it earns a deterministic self-test. We drive the real checks.sh over throwaway git repos with
# a crafted marketplace + changed-path set, and assert its exit code per case:
#
#   A. declared-but-missing plugin, marketplace.json NOT in the changeset  -> FAIL (the #274 hole)
#   B. declared-but-missing plugin, marketplace.json IN the changeset      -> FAIL (the #280 path, still guarded)
#   C. undeclared deleted plugin (not in marketplace)                      -> PASS (benign deletion)
#   D. present-but-unparsable marketplace + a missing plugin               -> FAIL (fail-closed, can't verify)
#   E. missing marketplace.json file + a deleted plugin                    -> PASS (no marketplace to declare it)
#
# Each case names ONLY the deleted plugin's path as changed, so no present plugin is smoked and
# fake_home_smoke.sh never runs — the test stays hermetic and fast. Exit 0 iff every case matches.
set -uo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS="$SMOKE_DIR/checks.sh"
[ -f "$CHECKS" ] || { echo "SMOKE-FAIL: checks.sh not found next to the smoke ($CHECKS)" >&2; exit 1; }

fail=0
sfail(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }
sok(){ echo "  smoke-ok: $*" >&2; }

# build a throwaway git repo; $1=marketplace.json content (literal, or the token __NONE__ to omit the file)
mkrepo(){
  local content=$1 d
  d=$(mktemp -d)
  ( cd "$d" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && mkdir -p .claude-plugin )
  if [ "$content" != "__NONE__" ]; then
    printf '%s' "$content" > "$d/.claude-plugin/marketplace.json"
  fi
  ( cd "$d" && git add -A && git commit -qm init >/dev/null 2>&1 )
  printf '%s' "$d"
}

# run checks.sh in a repo with given changed paths; assert exit code. $1=label $2=want(0|1) $3=repo; rest=paths
expect(){
  local label=$1 want=$2 repo=$3; shift 3
  local out rc
  out=$( cd "$repo" && bash "$CHECKS" "$@" 2>&1 ); rc=$?
  if [ "$rc" = "$want" ]; then
    sok "$label (exit $rc as expected)"
  else
    sfail "$label: expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/      | /' >&2
  fi
  rm -rf "$repo"
}

DECLARES_FOO='{"name":"aar","plugins":[{"name":"foo","source":"./plugins/foo"}]}'
DECLARES_BAR='{"name":"aar","plugins":[{"name":"bar","source":"./plugins/bar"}]}'
BROKEN='{ this is not valid json'

# A: marketplace still declares foo, foo dir absent, marketplace.json NOT changed -> must FAIL (the #274 hole)
expect "A declared-but-missing, marketplace unchanged -> FAIL" 1 "$(mkrepo "$DECLARES_FOO")" "plugins/foo/skills/x/SKILL.md"

# B: same but marketplace.json IS in the changeset -> must still FAIL (the #280-guarded path)
expect "B declared-but-missing, marketplace changed -> FAIL" 1 "$(mkrepo "$DECLARES_FOO")" "plugins/foo/skills/x/SKILL.md" ".claude-plugin/marketplace.json"

# C: foo deleted and NOT declared (marketplace declares only bar) -> benign, must PASS
expect "C undeclared deleted plugin -> PASS" 0 "$(mkrepo "$DECLARES_BAR")" "plugins/foo/skills/x/SKILL.md"

# D: marketplace present but unparsable, foo dir absent, marketplace.json NOT changed -> fail-closed FAIL
expect "D unparsable marketplace + missing plugin -> FAIL" 1 "$(mkrepo "$BROKEN")" "plugins/foo/skills/x/SKILL.md"

# E: no marketplace.json at all, foo deleted -> nothing declares it, must PASS
expect "E no marketplace.json + deleted plugin -> PASS" 0 "$(mkrepo "__NONE__")" "plugins/foo/skills/x/SKILL.md"

[ "$fail" = 0 ] && { echo "[checks_marketplace_smoke] PASS" >&2; exit 0; } || { echo "[checks_marketplace_smoke] FAIL" >&2; exit 1; }
