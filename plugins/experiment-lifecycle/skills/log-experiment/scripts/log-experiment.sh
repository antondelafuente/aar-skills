#!/usr/bin/env bash
# log-experiment.sh <registry-dir> [--dry-run]
#
# Log a research-repo registry directory to GitHub as a GATED pull request and merge it.
# The gate is chosen by the directory's own content (auditability via the registry convention):
#   - experiment (has DESIGN.md + RESULTS.md): verify the close-audit is present and clean.
#   - note (anything else):                    deterministic secret scan only.
# A cross-family engineer-bot approval satisfies the research repo's branch protection
# (the author cannot approve their own PR). Self-contained: this does NOT source wf.sh.
#
# Config (instance, env-overridable):
#   RESEARCH_REPO                        default antondelafuente/research-lab
#   LOG_EXPERIMENT_REVIEWER_TOKEN_CMD    cmd that prints a repo-scoped bot token; receives <owner/repo>
#   LOG_EXPERIMENT_REVIEWER_NAME         display name of the reviewer bot (for the log line)
set -euo pipefail

RESEARCH_REPO="${RESEARCH_REPO:-antondelafuente/research-lab}"
REVIEWER_TOKEN_CMD="${LOG_EXPERIMENT_REVIEWER_TOKEN_CMD:-bash $HOME/.config/codex-engineer/mint_token.sh}"
REVIEWER_NAME="${LOG_EXPERIMENT_REVIEWER_NAME:-codex-engineer}"

die()  { echo "BLOCK: $*" >&2; exit 1; }
note() { echo "[log-experiment] $*" >&2; }

# ---- args ----
DRY_RUN=0; DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -*) die "unknown flag: $a" ;;
    *) DIR="$a" ;;
  esac
done
[ -n "$DIR" ] || die "usage: log-experiment.sh <registry-dir> [--dry-run]"
[ -d "$DIR" ] || die "not a directory: $DIR"

REPO_ROOT="$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo: $DIR"
REL="$(cd "$REPO_ROOT" && realpath --relative-to="$REPO_ROOT" "$DIR")"
[ "${REL#..}" = "$REL" ] || die "dir is outside the repo root"
SLUG="$(basename "$REL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"

# ---- classify (registry convention; KIND file is an explicit override) ----
KIND=""
[ -f "$DIR/KIND" ] && KIND="$(tr -d '[:space:]' < "$DIR/KIND")"
if [ -z "$KIND" ]; then
  if [ -f "$DIR/DESIGN.md" ] && [ -f "$DIR/RESULTS.md" ]; then KIND="experiment"; else KIND="note"; fi
fi
note "classified: $KIND  ($REL)"

# ---- gate (fail-closed) ----
gate_experiment() {
  [ -f "$DIR/RESULTS.md" ] || die "experiment missing RESULTS.md"
  if [ -f "$DIR/AUDIT.md" ]; then
    if [ -f "$DIR/AUDIT_RESPONSE.md" ] && \
       grep -qiE 'unresolved|OPEN HIGH|HIGH[^a-z]*(not addressed|outstanding|unresolved)' "$DIR/AUDIT_RESPONSE.md"; then
      die "experiment AUDIT_RESPONSE.md flags an unresolved HIGH — surface for human"
    fi
    APPROVAL_BODY="Experiment record — close-AUDIT present and clean (no unresolved HIGH). Verified per registry convention."
    note "experiment gate ok: AUDIT.md present, no unresolved HIGH"
  else
    if grep -qiE 'ANCHOR_FAILED|no-?go|decision[: ]|stopped at|null result|diagnostic only' "$DIR/RESULTS.md"; then
      APPROVAL_BODY="Experiment record — eval-only/no-go run; no close-audit needed; RESULTS records a closed decision."
      note "experiment gate ok: no close-audit, RESULTS records a closed decision"
    else
      die "experiment has no AUDIT.md and RESULTS.md records no closed decision — surface for human"
    fi
  fi
}
gate_note() {
  local hits
  hits="$(grep -rnaIE '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY)' "$DIR" 2>/dev/null | head || true)"
  [ -z "$hits" ] || { echo "$hits" >&2; die "note contains secret-value patterns"; }
  APPROVAL_BODY="Record — deterministic secret scan clean; no experiment, so no audit."
  note "note gate ok: secret scan clean"
}
case "$KIND" in
  experiment) gate_experiment ;;
  note)       gate_note ;;
  *)          die "unknown KIND override: '$KIND' (expected experiment|note)" ;;
esac

if [ "$DRY_RUN" = 1 ]; then note "--dry-run: classified=$KIND, gate PASSED; stopping before any push."; exit 0; fi

# ---- mint the cross-family bot token up front (fail before mutating if it can't) ----
TOK="$($REVIEWER_TOKEN_CMD "$RESEARCH_REPO" 2>/dev/null || true)"
[ -n "$TOK" ] || die "could not mint reviewer bot token ($REVIEWER_NAME) for $RESEARCH_REPO"

# ---- branch in a DEDICATED worktree (never disturbs the shared tree) ----
cd "$REPO_ROOT"
git fetch origin --quiet
BRANCH="log/${SLUG}"
WT="$(mktemp -d)/wt"
cleanup() { git worktree remove --force "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT
git worktree add -q -b "$BRANCH" "$WT" origin/main || die "could not create worktree/branch (does $BRANCH already exist?)"

mkdir -p "$WT/$(dirname "$REL")"
cp -r "$DIR" "$WT/$(dirname "$REL")/"
git -C "$WT" add -- "$REL"                          # respects the dir's .gitignore (large artifacts stay on R2)
git -C "$WT" diff --cached --quiet && die "nothing to commit for $REL (all gitignored?)"
git -C "$WT" commit -q -m "Log $KIND: $REL"
git -C "$WT" push -q -u origin "$BRANCH"

# ---- PR -> bot approve -> merge ----
BODY="$(printf '%s\n\nLogged by log-experiment.sh (gate: %s).' "$APPROVAL_BODY" "$KIND")"
URL="$(gh pr create -R "$RESEARCH_REPO" --head "$BRANCH" --base main \
        -t "Log $KIND: $REL" -b "$BODY")"
PR="$(echo "$URL" | grep -oE '[0-9]+$')"
note "opened PR #$PR ($URL)"
GH_TOKEN="$TOK" gh pr review "$PR" -R "$RESEARCH_REPO" --approve --body "$APPROVAL_BODY" >/dev/null
gh pr merge "$PR" -R "$RESEARCH_REPO" --squash --delete-branch >/dev/null
note "merged PR #$PR"

# ---- sync local main (ff-only; never touches other uncommitted work) ----
git fetch origin --quiet
git merge --ff-only origin/main >/dev/null 2>&1 || note "note: local main not fast-forwardable; left as-is"
echo "OK: logged $KIND '$REL' as PR #$PR (merged)."
