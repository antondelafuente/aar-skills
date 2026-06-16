#!/bin/bash
# ship_change.sh — the SWE-pipeline engine: gated PR → cross-family code review → auto-merge-when-clean.
#
# This is the autonomous back-half of a scaffold change (the design half is --scaffold + the human's
# clearance, done upstream). It NEVER ships "the working tree" — it takes an EXPLICIT changed-path list,
# refuses if anything else is dirty (per the repo's policy), runs the repo's deterministic checks +
# behavior smoke, opens a PR, runs verify-claims --code on the EXACT diff, and auto-merges ONLY on a
# fully-clean review (zero findings + checks pass). Any finding → it stops and hands back to the agent.
#
# Usage:
#   SHIP_MSG="<commit msg>" SHIP_TITLE="<pr title>" ship_change.sh <repo> <author:claude|codex> <path>...
#   ship_change.sh remerge <repo> <branch> <pr-number>     # re-check + re-review (after fixing findings) + merge
#
# Env: AUDIT_EXPERIMENT=<path to verify-claims audit_experiment.sh> (else auto-located from installed plugin)
#      GH_TOKEN must be set (source ~/.env on this instance). gh must be on PATH.
# Per-repo profile (TRACKED, not hidden config): <repo>/.aar-ci/checks.sh (required) + <repo>/.aar-ci/config
#   (optional: DIRTY_POLICY=strict|quiescence  default strict; the checks script owns smoke/version/etc).
set -euo pipefail

die(){ echo "BLOCKED: $*" >&2; exit 1; }
note(){ echo "[ship-change] $*" >&2; }

# --- locate the cross-family code reviewer (verify-claims) ---------------------------------------
locate_audit(){
  if [ -n "${AUDIT_EXPERIMENT:-}" ] && [ -f "$AUDIT_EXPERIMENT" ]; then echo "$AUDIT_EXPERIMENT"; return; fi
  local hit; hit=$(find "$HOME/.claude/plugins/cache" -path '*verify-claims*scripts/audit_experiment.sh' 2>/dev/null \
    | sort -V | tail -1)
  [ -n "$hit" ] || die "cannot locate verify-claims audit_experiment.sh (install verify-claims, or set AUDIT_EXPERIMENT)"
  echo "$hit"
}

# --- the cleanliness guard: explicit paths only, fail on unrelated dirt (per policy) -------------
guard_clean(){   # guard_clean <repo> <policy> <path>...
  local repo=$1 policy=$2; shift 2; local paths=("$@")
  [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = main ] || die "repo $repo is not on 'main' (base must be clean main)"
  # every named path must actually be changed
  local p; for p in "${paths[@]}"; do
    git -C "$repo" status --porcelain -- "$p" | grep -q . || die "named path is not changed: $p"
  done
  # no UNRELATED dirty files (strict). Build the set of dirty paths, subtract ours.
  local dirty; dirty=$(git -C "$repo" status --porcelain | sed 's/^...//' | sort -u)
  local ours; ours=$(printf '%s\n' "${paths[@]}" | sort -u)
  local extra; extra=$(comm -23 <(printf '%s\n' "$dirty") <(printf '%s\n' "$ours") || true)
  if [ -n "$extra" ]; then
    if [ "$policy" = quiescence ]; then
      die "repo not quiescent — unrelated dirty files present (policy=quiescence requires a clean tree except your paths):\n$extra"
    else
      die "unrelated dirty files present (policy=strict — name every changed path, nothing else dirty):\n$extra"
    fi
  fi
}

# --- parse findings from a CODE_REVIEW.md --------------------------------------------------------
count_high(){ grep -cE '^FINDING [0-9]+: HIGH' "$1" 2>/dev/null || true; }
count_all(){ grep -cE '^FINDING [0-9]+:' "$1" 2>/dev/null || true; }

# --- run the repo's deterministic checks + behavior smoke ---------------------------------------
run_checks(){   # run_checks <repo> <path>...
  local repo=$1; shift
  [ -f "$repo/.aar-ci/checks.sh" ] || die "repo has no tracked check profile ($repo/.aar-ci/checks.sh) — every repo shipped through this pipeline must define one"
  note "running deterministic checks + smoke ($repo/.aar-ci/checks.sh)…"
  ( cd "$repo" && bash .aar-ci/checks.sh "$@" ) || die "deterministic checks/behavior-smoke FAILED — fix before shipping"
}

# --- the code review on a diff (cross-family) ---------------------------------------------------
code_review(){  # code_review <repo> <author> <branch> -> writes REVIEW_FILE, echoes its path
  local repo=$1 author=$2 br=$3
  local diff="${TMPDIR:-/tmp}/ship_${br//\//_}.diff" rev="${TMPDIR:-/tmp}/ship_${br//\//_}.CODE_REVIEW.md"
  git -C "$repo" diff main..."$br" > "$diff"
  [ -s "$diff" ] || die "empty diff main...$br — nothing to review"
  local audit; audit=$(locate_audit)
  note "cross-family code review (author=$author, auditor=opposite family)…"
  AAR_SUBSTRATE="$author" AUDIT_CONSTITUTION="${AUDIT_CONSTITUTION:-$repo/AGENTS.md}" \
    bash "$audit" --code "$diff" "$repo" "$rev" >/dev/null 2>"$rev.run.log" \
    || { echo "BLOCKED: code reviewer failed — tail of log:" >&2; tail -5 "$rev.run.log" >&2; exit 1; }
  echo "$rev"
}

# --- post-merge: sync main + refresh installed plugins if a plugin.json changed -----------------
post_merge(){   # post_merge <repo> <path>...
  local repo=$1; shift
  git -C "$repo" checkout main -q 2>/dev/null || true
  git -C "$repo" pull --ff-only -q 2>/dev/null || note "WARN: could not ff-only pull main — reconcile manually"
  local p changed=0
  for p in "$@"; do case "$p" in */plugin.json|*marketplace.json) changed=1;; esac; done
  if [ "$changed" = 1 ]; then
    note "a plugin manifest changed — refresh installed plugins with: claude plugin marketplace update <mkt> && claude plugin update <name>@<mkt>"
  fi
}

# =================================================================================================
if [ "${1:-}" = "remerge" ]; then
  REPO=${2:?repo}; BR=${3:?branch}; PR=${4:?pr-number}
  run_checks "$REPO"   # re-run deterministic checks
  REV=$(code_review "$REPO" "${SHIP_AUTHOR:-claude}" "$BR")
  H=$(count_high "$REV"); T=$(count_all "$REV")
  note "re-review: $T finding(s), $H HIGH -> $REV"
  [ "$H" = 0 ] || die "re-review still has $H HIGH finding(s) — not merging. See $REV"
  if [ "$T" != 0 ]; then note "NOTE: $T non-HIGH finding(s) remain — merging assumes you responded on the PR (no unresolved HIGH)."; fi
  ( cd "$REPO" && source ~/.env 2>/dev/null; gh pr merge "$PR" --squash --delete-branch ) || die "merge failed"
  post_merge "$REPO"; note "MERGED PR #$PR"; exit 0
fi

REPO=${1:?usage: SHIP_MSG=.. SHIP_TITLE=.. ship_change.sh <repo> <author> <path>...}
AUTHOR=${2:?author: claude|codex}; shift 2; PATHS=("$@")
[ ${#PATHS[@]} -gt 0 ] || die "no changed paths given — this pipeline never ships 'the working tree'; name every path"
case "$AUTHOR" in claude|codex) ;; *) die "author must be 'claude' or 'codex' (got '$AUTHOR')";; esac
[ -n "${SHIP_MSG:-}" ] || die "set SHIP_MSG to the commit message"
[ -n "${SHIP_TITLE:-}" ] || die "set SHIP_TITLE to the PR title"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
command -v gh >/dev/null || die "gh not on PATH"
DIRTY_POLICY=strict; [ -f "$REPO/.aar-ci/config" ] && source "$REPO/.aar-ci/config"

guard_clean "$REPO" "$DIRTY_POLICY" "${PATHS[@]}"
run_checks "$REPO" "${PATHS[@]}"

BR="ship/$(date +%Y%m%d-%H%M%S)"
note "branch $BR — committing exactly: ${PATHS[*]}"
git -C "$REPO" checkout -q -b "$BR"
git -C "$REPO" add -- "${PATHS[@]}"
git -C "$REPO" commit -q -m "$SHIP_MSG

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git -C "$REPO" checkout -q main      # restore the shared checkout to main; change lives on the branch
( cd "$REPO" && source ~/.env 2>/dev/null; git push -u origin "$BR" -q ) || die "push failed"
PRURL=$( cd "$REPO" && source ~/.env 2>/dev/null; gh pr create --base main --head "$BR" --title "$SHIP_TITLE" --body "$SHIP_MSG

🤖 ship-change pipeline" ) || die "gh pr create failed"
PR=$(basename "$PRURL"); note "PR #$PR: $PRURL"

REV=$(code_review "$REPO" "$AUTHOR" "$BR")
H=$(count_high "$REV"); T=$(count_all "$REV")
note "review: $T finding(s), $H HIGH -> $REV"
if [ "$T" = 0 ]; then
  note "REVIEW CLEAN + checks passed -> auto-merging PR #$PR"
  ( cd "$REPO" && source ~/.env 2>/dev/null; gh pr merge "$PR" --squash --delete-branch ) || die "auto-merge failed"
  post_merge "$REPO" "${PATHS[@]}"
  echo "SHIPPED: PR #$PR auto-merged (clean review)."
else
  echo "STOP: PR #$PR has $T finding(s) ($H HIGH) — NOT auto-merged. Review: $REV" >&2
  echo "  Agent: triage each (fix in branch $BR via a worktree, or respond on the PR for non-HIGH)," >&2
  echo "  then: ship_change.sh remerge $REPO $BR $PR  (re-checks + re-reviews the updated diff + merges if no HIGH)." >&2
  exit 3
fi
