#!/bin/bash
# checks_marketplace_smoke.sh — regression smoke for step 6's missing-plugin cross-check in checks.sh (#274).
#
# The check decides whether an absent `plugins/<x>` dir is a benign deletion or a broken marketplace by
# cross-checking the CURRENT `.claude-plugin/marketplace.json` declarations. That logic regressed once
# (#280 had to re-close the marketplace-CHANGED path) and #274 widened it to the marketplace-UNCHANGED
# path, so it earns a deterministic self-test. We drive the real checks.sh over throwaway git repos with
# a crafted marketplace + changed-path set, and assert BOTH its exit code AND the specific diagnostic —
# so a case that fails for an unrelated reason (e.g. a missing README namespace) is not mistaken for a
# guarded path. Cases:
#
#   A. declared-but-missing plugin, marketplace.json NOT in the changeset  -> FAIL "but plugins/foo is missing"
#   B. declared-but-missing plugin, marketplace.json IN the changeset      -> FAIL "but plugins/foo is missing"
#   C. undeclared deleted plugin (not in marketplace)                      -> PASS "plugin foo removed (no smoke)"
#   D. present-but-unparsable marketplace + a missing plugin               -> FAIL "cannot verify"
#   E. missing marketplace.json file + a deleted plugin                    -> PASS "plugin foo removed (no smoke)"
#
# Each case names ONLY the deleted plugin's path as changed, so no present plugin is smoked and
# fake_home_smoke.sh never runs — the test stays hermetic and fast. Every fixture also carries a README
# whose install namespace matches the marketplace name, so step 1b (README-namespace) never fires
# incidentally in case B (where marketplace.json IS in the changeset) and mask the branch under test.
# Exit 0 iff every case matches on both dimensions.
set -uo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS="$SMOKE_DIR/checks.sh"
[ -f "$CHECKS" ] || { echo "SMOKE-FAIL: checks.sh not found next to the smoke ($CHECKS)" >&2; exit 1; }

fail=0
sfail(){ echo "  SMOKE-FAIL: $*" >&2; fail=1; }
sok(){ echo "  smoke-ok: $*" >&2; }

# build a throwaway git repo; $1=marketplace.json content (literal, or __NONE__ to omit the file).
# Fail-closed: prints the repo path on success, prints NOTHING and returns nonzero on any setup error, so
# `expect` sees an empty repo arg and reports a fixture failure rather than checking the wrong directory.
mkrepo(){
  local content=$1 d
  d=$(mktemp -d) || return 1
  ( cd "$d" \
    && git init -q \
    && git config user.email t@t \
    && git config user.name t \
    && mkdir -p .claude-plugin ) || { rm -rf "$d"; return 1; }
  if [ "$content" != "__NONE__" ]; then
    printf '%s' "$content" > "$d/.claude-plugin/marketplace.json" || { rm -rf "$d"; return 1; }
  fi
  # README namespace must match the marketplace name ("aar") so step 1b passes when marketplace.json changed.
  printf 'Install with `claude plugin install foo@aar`.\n' > "$d/README.md" || { rm -rf "$d"; return 1; }
  # Disable signing + bypass hooks so the fixture commit can't fail for environment reasons unrelated to
  # the check logic (inherited global commit.gpgsign / pre-commit hooks).
  ( cd "$d" && git add -A && git -c commit.gpgsign=false commit --no-verify -qm init >/dev/null 2>&1 ) \
    || { rm -rf "$d"; return 1; }
  printf '%s' "$d"
}

# run checks.sh in a repo, asserting exit code AND a diagnostic substring.
# $1=label $2=want-exit(0|1) $3=want-substring $4=repo; rest=changed paths
expect(){
  local label=$1 want=$2 wantmsg=$3 repo=$4; shift 4
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    sfail "$label: fixture repo was not created (mkrepo failed)"
    return
  fi
  local out rc okcase=1
  out=$( cd "$repo" && bash "$CHECKS" "$@" 2>&1 ); rc=$?
  [ "$rc" = "$want" ] || { sfail "$label: expected exit $want, got $rc"; okcase=0; }
  if [ -n "$wantmsg" ] && ! printf '%s' "$out" | grep -qF "$wantmsg"; then
    sfail "$label: expected diagnostic not found: '$wantmsg'"; okcase=0
  fi
  if [ "$okcase" = 1 ]; then
    sok "$label (exit $rc, diagnostic matched)"
  else
    printf '%s\n' "$out" | sed 's/^/      | /' >&2
  fi
  rm -rf "$repo"
}

DECLARES_FOO='{"name":"aar","plugins":[{"name":"foo","source":"./plugins/foo"}]}'
DECLARES_BAR='{"name":"aar","plugins":[{"name":"bar","source":"./plugins/bar"}]}'
BROKEN='{ this is not valid json'

# A: marketplace still declares foo, foo dir absent, marketplace.json NOT changed -> FAIL (the #274 hole)
expect "A declared-but-missing, marketplace unchanged -> FAIL" 1 "but plugins/foo is missing" \
  "$(mkrepo "$DECLARES_FOO")" "plugins/foo/skills/x/SKILL.md"

# B: same but marketplace.json IS in the changeset -> FAIL for the SAME reason (the #280-guarded path).
#    The README fixture keeps step 1b green, so the missing-plugin diagnostic is what fails the case.
expect "B declared-but-missing, marketplace changed -> FAIL" 1 "but plugins/foo is missing" \
  "$(mkrepo "$DECLARES_FOO")" "plugins/foo/skills/x/SKILL.md" ".claude-plugin/marketplace.json"

# C: foo deleted and NOT declared (marketplace declares only bar) -> benign, PASS via the removed branch
expect "C undeclared deleted plugin -> PASS" 0 "plugin foo removed (no smoke)" \
  "$(mkrepo "$DECLARES_BAR")" "plugins/foo/skills/x/SKILL.md"

# D: marketplace present but unparsable, foo dir absent, marketplace.json NOT changed -> fail-closed FAIL
expect "D unparsable marketplace + missing plugin -> FAIL" 1 "cannot verify" \
  "$(mkrepo "$BROKEN")" "plugins/foo/skills/x/SKILL.md"

# E: no marketplace.json at all, foo deleted -> nothing declares it, PASS via the removed branch
expect "E no marketplace.json + deleted plugin -> PASS" 0 "plugin foo removed (no smoke)" \
  "$(mkrepo "__NONE__")" "plugins/foo/skills/x/SKILL.md"

[ "$fail" = 0 ] && { echo "[checks_marketplace_smoke] PASS" >&2; exit 0; } || { echo "[checks_marketplace_smoke] FAIL" >&2; exit 1; }
