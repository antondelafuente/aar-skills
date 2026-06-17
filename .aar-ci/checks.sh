#!/bin/bash
# aar-skills deterministic checks + behavior smoke. TRACKED check profile (run by ship_change.sh).
# Args: the changed paths being shipped. Runs from the repo root. Exit non-zero on ANY failure.
# The pyramid: cheap deterministic checks first, then the fake-HOME behavior smoke for plugin/skill changes.
set -uo pipefail
PATHS=("$@")
fail=0
err(){ echo "  CHECK-FAIL: $*" >&2; fail=1; }
ok(){ echo "  ok: $*" >&2; }

changed_under(){ local pfx=$1; printf '%s\n' "${PATHS[@]}" | grep -q "^$pfx" ; }

echo "[checks] aar-skills — ${#PATHS[@]} path(s)" >&2

# 1. JSON validity (manifests/marketplace)
for p in "${PATHS[@]}"; do case "$p" in
  *.json) [ -f "$p" ] && { python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$p" 2>/dev/null && ok "json $p" || err "invalid JSON: $p"; } ;;
esac; done

# 2. shell syntax
for p in "${PATHS[@]}"; do case "$p" in
  *.sh) [ -f "$p" ] && { bash -n "$p" 2>/dev/null && ok "bash -n $p" || err "bash syntax: $p"; } ;;
esac; done

# 3. python compiles
for p in "${PATHS[@]}"; do case "$p" in
  *.py) [ -f "$p" ] && { python3 -m py_compile "$p" 2>/dev/null && ok "py_compile $p" || err "py_compile: $p"; } ;;
esac; done

# 4. instance-leak / secrets: NOT re-implemented here. The repo's pre-commit secrets hook
#    (.githooks/pre-commit) is the deterministic backstop for instance specifics + secrets, and the
#    cross-family --code review is the judgment-based catch. Hardcoding instance patterns in a product
#    check would itself be instance-coupling (and trips the secrets hook on its own regex).

# 5. version bump: if a plugin's non-manifest file changed, its plugin.json version must have moved
for plugdir in $(printf '%s\n' "${PATHS[@]}" | grep '^plugins/' | sed -E 's#(plugins/[^/]+)/.*#\1#' | sort -u); do
  nonmanifest=$(printf '%s\n' "${PATHS[@]}" | grep "^$plugdir/" | grep -v '\.claude-plugin/plugin.json' || true)
  [ -n "$nonmanifest" ] || continue
  pj="$plugdir/.claude-plugin/plugin.json"
  # zero-context diff: only an ACTUALLY added/changed "version" line counts (a context line must not satisfy it)
  if git diff -U0 HEAD -- "$pj" 2>/dev/null | grep -qE '^\+[^+].*"version"'; then ok "version bumped: $pj"
  else err "$plugdir changed but $pj version not bumped (consumers would miss the change)"; fi
done

# 6. behavior smoke (fake-HOME install -> skill discovery) for any changed plugin — F3 gate: deterministic
#    checks can't catch an install/discovery break, so this gates auto-merge for plugin/skill changes.
SMOKE="$(git rev-parse --show-toplevel)/.aar-ci/fake_home_smoke.sh"
for plug in $(printf '%s\n' "${PATHS[@]}" | grep '^plugins/' | sed -E 's#plugins/([^/]+)/.*#\1#' | sort -u); do
  if [ -f "$SMOKE" ]; then
    echo "[checks] behavior smoke: $plug" >&2
    bash "$SMOKE" "$(git rev-parse --show-toplevel)" "$plug" && ok "smoke $plug" || err "fake-HOME smoke FAILED for $plug"
  else
    err "behavior smoke required for plugin change ($plug) but fake_home_smoke.sh missing — auto-merge must not proceed without it"
  fi
done

[ "$fail" = 0 ] && { echo "[checks] PASS" >&2; exit 0; } || { echo "[checks] FAIL" >&2; exit 1; }
