#!/bin/bash
# exp_pr.sh — experiment-PR lifecycle driver, DESIGN side (#227).
#
# THIN by construction: it sources the ship-change wf.sh as a function LIBRARY (source-guarded) and
# reuses its GitHub plumbing — engineer identity, author-attributed push, the native cross-family
# review (run_review), the squash-merge — to run an EXPERIMENT through a PR in research-lab. It
# deliberately uses NONE of wf.sh's engineering machinery (classifier, .aar-ci code checks,
# version-bump, --code review, the issue close-gate). The experiment merge gate is purely the
# cross-family `--design` audit APPROVE.
#
#   exp_pr.sh open-design <exp-dir> <author>   branch in research-lab + commit DESIGN/START/CHECKLIST + open the DESIGN PR
#   exp_pr.sh design-gate <exp-dir> <author>   run the --design audit as the native merge gate; APPROVE + merge on HIGH=0
#
# Canonical experiment id = basename(exp-dir). It names the branch (exp/<id>) and the PR, and is the
# stable key shared with the ledger run + the R2 prefix (so design PR / execution PR / dir / ledger /
# R2 all line up). <author> = the design agent's family (claude|codex); the OPPOSITE family's engineer
# bot posts the approving review.

# --- source wf.sh as the shared GitHub-lifecycle library (source-guarded: defines helpers, no dispatch) ---
_resolve_wf(){
  if [ -n "${WF_SH:-}" ] && [ -r "${WF_SH:-}" ]; then echo "$WF_SH"; return; fi
  local self; self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local cand="$self/../../../../aar-engineering/skills/ship-change/scripts/wf.sh"   # same plugins/ tree (worktree or live source)
  if [ -r "$cand" ]; then readlink -f "$cand" 2>/dev/null || echo "$cand"; return; fi
  command -v wf.sh 2>/dev/null || true
}
WF_LIB=$(_resolve_wf)
[ -n "${WF_LIB:-}" ] && [ -r "${WF_LIB:-}" ] || { echo "BLOCKED: cannot locate wf.sh to source (set WF_SH=/abs/path/to/wf.sh)" >&2; exit 1; }
# shellcheck source=/dev/null
source "$WF_LIB"

_exp_id(){ basename "${1%/}"; }
_design_wt(){ echo "${TMPDIR:-/tmp}/exp-$1-design-wt"; }   # deterministic worktree path per experiment id

cmd_open_design(){
  local exp=${1:?usage: exp_pr.sh open-design <exp-dir> <author>}; local author=${2:?author: claude|codex}
  [ -d "$exp" ] || die "no such experiment dir: $exp"
  check_author "$author"
  local id repo rel wt br
  id=$(_exp_id "$exp")
  repo=$(git -C "$exp" rev-parse --show-toplevel 2>/dev/null) || die "$exp is not inside a git repo (expected a research-lab checkout)"
  rel=$(realpath --relative-to="$repo" "$exp")
  br="exp/$id"; wt=$(_design_wt "$id")
  # fresh worktree of research-lab on the experiment branch (no shared-checkout races; mirrors wf.sh start)
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  git -C "$repo" fetch -q origin main 2>/dev/null || true
  git -C "$repo" worktree add -q "$wt" -b "$br" origin/main 2>/dev/null \
    || git -C "$repo" worktree add -q "$wt" "$br" 2>/dev/null \
    || die "could not create research-lab worktree $wt on $br"
  # bring the design artifacts onto the branch (from the produced exp dir)
  mkdir -p "$wt/$rel"
  local f had=0
  for f in DESIGN.md START.md CHECKLIST.md data_audit_manifest.md; do
    [ -f "$exp/$f" ] && { cp "$exp/$f" "$wt/$rel/$f"; had=1; }
  done
  [ "$had" = 1 ] || die "no DESIGN.md/START.md/CHECKLIST.md found in $exp"
  # commit as the engineer identity, push, open the draft PR
  local atok ga gname gemail
  atok=$(author_token_optional "$author"); [ -n "$atok" ] || need_ambient_gh
  ga=$(engineer_git_author "$author" 0); gname=$(git_author_name "$ga"); gemail=$(git_author_email "$ga")
  ( cd "$wt" && git add -- "$rel" && \
    git -c user.name="${gname:-$author-engineer}" -c user.email="${gemail:-noreply@local}" \
      commit -q -m "experiment design: $id" -- "$rel" ) || die "commit failed"
  git_push_author "$atok" "$wt" -q -u origin "$br" || die "push failed"
  local title body prurl
  title="Experiment $id — design"
  body=$( { printf 'Experiment **%s** — design PR. The merge gate is the cross-family `--design` audit (an approving review from the opposite-family engineer bot); the researcher arbitrates findings.\n\n---\n\n' "$id"; sed -n '1,250p' "$exp/DESIGN.md" 2>/dev/null; } )
  prurl=$(printf '%s' "$body" | gh_author "$atok" -R "$(gh_repo "$wt")" pr create --draft --base main --head "$br" --title "$title" --body-file -) \
    || die "gh pr create failed"
  echo "PR=$(basename "$prurl")"; echo "WT=$wt"
  note "design PR opened for experiment $id: $prurl"
  note "next: exp_pr.sh design-gate $exp $author"
}

cmd_design_gate(){
  local exp=${1:?usage: exp_pr.sh design-gate <exp-dir> <author>}; local author=${2:?author: claude|codex}
  [ -d "$exp" ] || die "no such experiment dir: $exp"
  check_author "$author"
  local id wt repo pr atok sha
  id=$(_exp_id "$exp"); wt=$(_design_wt "$id")
  [ -d "$wt" ] || die "no design worktree at $wt — run 'exp_pr.sh open-design $exp $author' first"
  repo=$(gh_repo "$wt")
  pr=$(gh_author "" -R "$repo" pr list --head "exp/$id" --state open --json number -q '.[0].number' 2>/dev/null)
  [ -n "$pr" ] || die "no open PR for branch exp/$id"
  # The --design audit IS the merge gate: native APPROVE on HIGH=0, REQUEST_CHANGES otherwise. Disposition-aware
  # re-review (run_review handles DISPOSITION_FILE): a finding the researcher accepted (with a reason) clears.
  REVIEW_HIGH=1
  run_review --design "$wt" "$author" "$exp" "$pr" "Design audit (cross-family merge gate)" 1
  if [ "${REVIEW_HIGH:-1}" != 0 ]; then
    die "design gate: $REVIEW_HIGH HIGH finding(s) — NOT merging. Researcher arbitrates via 'wf.sh fdispo $wt $author edit' (fix / refute / accept-with-reason), then re-run: exp_pr.sh design-gate $exp $author"
  fi
  atok=$(author_token_optional "$author"); [ -n "$atok" ] || need_ambient_gh
  sha=$(git -C "$wt" rev-parse HEAD)
  note "design audit clean (no HIGH) -> merging design PR #$pr @ ${sha:0:8} (the cleared-design record)"
  gh_author "$atok" -R "$repo" pr merge "$pr" --squash --delete-branch --match-head-commit "$sha" \
    || die "merge failed (head moved since review — re-run design-gate)"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
  echo "CLEARED: experiment $id design merged (PR #$pr) — ready for handoff to the executor."
}

case "${1:-}" in
  open-design) shift; cmd_open_design "$@" ;;
  design-gate) shift; cmd_design_gate "$@" ;;
  help|-h|--help|"") echo "usage: exp_pr.sh {open-design|design-gate} <exp-dir> <author>" ;;
  *) echo "exp_pr.sh: unknown verb '${1:-}' (open-design|design-gate)" >&2; exit 1 ;;
esac
