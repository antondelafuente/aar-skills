#!/bin/bash
# gh-guard.sh — the ship-change `gh` write-guard wrapper (#165, child of #149).
#
# An ERGONOMIC REDIRECT, not the security boundary. The structural guarantee is a read-only ambient `gh`
# credential (the instance rollout): a bare `gh` write fails closed at GitHub even if this guard is missing,
# bypassed, or PATH-shadowed. This wrapper exists only to turn that raw 403 into a DIRECTED message — "GitHub
# writes go through `wf.sh issue|comment <family>`" — so an agent under reflex is told what to do instead.
#
# Install it AHEAD of the real `gh` on PATH (`wf.sh install-gh-guard`). It classifies the `gh` subcommand:
#   - reads (view/list/status, `gh api` GETs, …) pass straight through to the real gh;
#   - mutating subcommands (issue/pr create, *comment, pr review/merge, issue edit/close/delete,
#     `gh api` with a non-GET method or a body) are BLOCKED with the directed message;
#   - credential-MUTATING `gh auth` (login/refresh/setup-git/logout) is BLOCKED (it would re-open the stored-
#     credential hole the capability layer closes), while the non-mutating helper forms the workflow needs
#     (`gh auth git-credential`, `gh auth status`, `gh auth token`) pass through.
#
# Two bypasses pass a call straight to the real gh:
#   - WF_GH_INTERNAL=1 — wf.sh's marker on its OWN engineer-token gh calls (a GH_TOKEN swap is invisible to a
#     PATH wrapper, so this explicit marker — set by wf.sh's real_gh helper — is the only robust bypass signal).
#   - WF_GH_ALLOW_OWNER_WRITE=1 — the explicit, logged owner-maintenance override. It only SUPPRESSES the
#     redirect; it does NOT grant write capability (that still requires the operator to have sourced an
#     elevated owner token — the read-only ambient token can never write regardless of this flag).
#
# The wrapper resolves the REAL gh (the next `gh` on PATH after this shim, or $WF_REAL_GH) and never recurses.
set -euo pipefail

guard_die(){
  # $1 = the classified command SHAPE (e.g. "issue create") — NEVER the raw argv, which can carry issue/
  # comment bodies, headers, or tokens we must not echo into terminal logs (#165 review F3).
  local shape=${1:-write}
  cat >&2 <<EOF
BLOCKED (gh write-guard): refusing a GitHub WRITE — \`gh $shape\`.
GitHub writes go through the engineer identity path:
  wf.sh issue <claude|codex> create|comment|close|label|dispose …   (Issues / maintainer verbs)
  wf.sh open|comment|...|finish <worktree> <family>                  (the ship-change lifecycle)
See the ship-change skill. For deliberate owner/admin maintenance, source an elevated owner token AND set
WF_GH_ALLOW_OWNER_WRITE=1 (both are required; the override alone does not grant write capability).
EOF
  exit 13
}

# --- resolve the real gh (skip this shim itself) ---------------------------------------------------------
resolve_real_gh(){
  if [ -n "${WF_REAL_GH:-}" ] && [ -x "${WF_REAL_GH}" ]; then printf '%s' "$WF_REAL_GH"; return 0; fi
  local self me cand
  self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || d=.
    cand="$d/gh"
    [ -x "$cand" ] || continue
    me=$(readlink -f "$cand" 2>/dev/null || echo "$cand")
    [ "$me" = "$self" ] && continue   # don't recurse into ourselves
    printf '%s' "$cand"; return 0
  done
  return 1
}

exec_real_gh(){
  local real; real=$(resolve_real_gh) || { echo "BLOCKED (gh write-guard): could not locate the real gh on PATH (set WF_REAL_GH)" >&2; exit 13; }
  exec "$real" "$@"
}

# --- bypasses: pass straight through to the real gh ------------------------------------------------------
if [ "${WF_GH_INTERNAL:-0}" = 1 ]; then exec_real_gh "$@"; fi
if [ "${WF_GH_ALLOW_OWNER_WRITE:-0}" = 1 ]; then
  # NOTE: do not echo the raw argv (it can carry bodies/tokens, #165 review F3) — name only the override.
  echo "[gh-guard] WF_GH_ALLOW_OWNER_WRITE=1 — owner-maintenance override; redirect suppressed for this gh call" >&2
  exec_real_gh "$@"
fi

# next_word: from the args array starting at index $1, return the first token that is a positional WORD —
# skipping flags AND the VALUE of a value-taking flag (-R/--repo o/r would otherwise be mis-read as the
# subcommand, bypassing the guard — #165 review F1). Value-taking top-level/subcommand flags we must step
# over: -R/--repo, -H/--hostname, --jq, -t/--template, -F/-f/--field/--raw-field, -X/--method, --input,
# --cache. We err toward skipping a value for any KNOWN value-flag; bare `--foo=val` carries its own value.
declare -a ARGV=("$@")
is_value_flag(){
  case "$1" in
    -R|--repo|-H|--hostname|--jq|-q|-t|--template|-F|-f|--field|--raw-field|-X|--method|--input|--cache) return 0 ;;
    *) return 1 ;;
  esac
}
NEXT_WORD=""; NEXT_WORD_IDX=-1
next_word(){  # next_word <start-index> -> sets NEXT_WORD to the first positional word at/after start ("" if
              # none) and NEXT_WORD_IDX to its index (or -1). Sets GLOBALS (not stdout) so the index survives
              # — a `$(...)` command-substitution call would run in a subshell and lose the index.
  local i=$1 n=${#ARGV[@]} tok
  NEXT_WORD=""; NEXT_WORD_IDX=-1
  while [ "$i" -lt "$n" ]; do
    tok=${ARGV[$i]}
    if [ "${tok#-}" != "$tok" ]; then
      # a flag. If it's a known value-taking flag in separate-arg form (no '='), also skip its value.
      if is_value_flag "$tok"; then i=$((i+2)); continue; fi
      i=$((i+1)); continue
    fi
    NEXT_WORD=$tok; NEXT_WORD_IDX=$i; return 0
  done
  return 0
}

# the SUBCOMMAND (issue|pr|api|auth|…), skipping any leading top-level flags + their values.
next_word 0; sub=$NEXT_WORD; sub_idx=$NEXT_WORD_IDX
# the VERB after the subcommand (also flag/value-skipping) for the families we classify.
verb=""
if [ "$sub_idx" -ge 0 ]; then next_word $((sub_idx+1)); verb=$NEXT_WORD; fi

case "$sub" in
  # ---- always-read top-levels ----
  ""|help|version|--version|--help|status|search|browse|alias|completion|config|extension|label|gist|release|run|workflow|cache|ruleset|secret|variable|environment|codespace|org|repo)
    # NOTE: several of these (repo/release/run/secret/…) HAVE write subcommands; we deliberately do NOT try to
    # cover every nested write here — the capability layer is the security boundary. The guard targets the
    # high-frequency reflex writes (issue/pr/api). Pass these through.
    exec_real_gh "$@"
    ;;

  # ---- the read-vs-write families we DO classify ----
  issue|pr)
    case "$verb" in
      view|list|status|diff|checks|""|develop) exec_real_gh "$@" ;;   # reads (develop is a no-op lister here)
      *) guard_die "$sub $verb" ;;                                    # create/comment/edit/close/merge/review/delete/reopen/… = writes
    esac
    ;;

  auth)
    case "$verb" in
      # non-mutating helper forms the workflow needs (git push credential helper, status, token printing)
      git-credential|status|token) exec_real_gh "$@" ;;
      # login/refresh/setup-git/logout MUTATE the stored credential -> reopen the stored-cred hole -> block
      *) guard_die "auth $verb" ;;
    esac
    ;;

  api)
    # default-DENY: a `gh api` is a read ONLY when it is clearly a GET with no body. Block on any non-GET
    # method, any body-implying field flag, --input, or a GraphQL mutation. Scan ALL args (a flag's value
    # that happens to look like another flag is harmless to re-scan; we only OR in write signals).
    method="GET"; has_body=0; is_graphql=0; want_method=0
    for a in "$@"; do
      if [ "$want_method" = 1 ]; then method=$a; want_method=0; continue; fi
      case "$a" in
        -X|--method) want_method=1 ;;
        -X*) method=${a#-X} ;;
        --method=*) method=${a#--method=} ;;
        -f|-F|--field|--raw-field|--input) has_body=1 ;;
        -f*|-F*) has_body=1 ;;
        --field=*|--raw-field=*|--input=*) has_body=1 ;;
        graphql) is_graphql=1 ;;
      esac
    done
    # GraphQL is a write iff it carries a `mutation` (in a -f query=… or --input). Be conservative: if it's
    # graphql AND carries a body, inspect the args for the literal `mutation` keyword.
    mut=0
    if [ "$is_graphql" = 1 ] && [ "$has_body" = 1 ]; then
      for a in "$@"; do case "$a" in *mutation*) mut=1;; esac; done
    fi
    mu=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
    case "$mu" in
      GET|HEAD)
        # a body on a GET/HEAD api call still implies gh upgrades it to POST -> treat as write.
        if [ "$has_body" = 1 ] && [ "$is_graphql" = 0 ]; then guard_die "api (write: body on GET)"; fi
        if [ "$mut" = 1 ]; then guard_die "api graphql (mutation)"; fi
        exec_real_gh "$@"
        ;;
      *) guard_die "api -X $mu" ;;   # POST/PATCH/PUT/DELETE/… = write
    esac
    ;;

  *)
    # unknown subcommand: fail SAFE toward the redirect only for the obvious write verbs; otherwise pass
    # through (the capability layer remains the boundary). Conservative default: pass through.
    exec_real_gh "$@"
    ;;
esac
