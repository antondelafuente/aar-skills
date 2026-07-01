#!/usr/bin/env bash
# Smoke + reference call-site for job_lib.sh's hardened rclone helpers (#295). Behavior the
# deterministic JSON/syntax checks can't catch:
#   r2_copy  — ALWAYS passes -L; treats a `Can't follow symlink` NOTICE as an INCOMPLETE copy and
#              returns non-zero EVEN WHEN rclone exits 0 (the swallow that made a bare copy read as
#              success → silent data loss); propagates rclone's own non-zero exit; forwards extra args.
#   r2_exists — lists the DIRECTORY + `grep -qx` (never single-file `rclone lsf <file>`, which exits 0
#              on a missing file / phantoms a just-deleted leaf).
# Fully OFFLINE: `rclone` is stubbed on PATH, its behavior driven by env vars per case.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/job_lib.sh" || { echo "FAIL: cannot source job_lib.sh"; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# --- offline rclone stub on PATH ---------------------------------------------------------
# Dispatches on the subcommand. `copy` honors RCLONE_COPY_MODE (ok|notice|fail) and records its full
# argv to $RCLONE_COPY_ARGS. `lsf` records its path arg to $RCLONE_LSF_ARG and emits $RCLONE_LSF_OUT.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/rclone" <<'EOF'
#!/usr/bin/env bash
sub=${1:-}
case "$sub" in
  copy)
    shift
    [ -n "${RCLONE_COPY_ARGS:-}" ] && printf '%s\n' "$*" > "$RCLONE_COPY_ARGS"
    case "${RCLONE_COPY_MODE:-ok}" in
      notice) echo "2026/07/01 NOTICE: snapshots/x/config.json: Can't follow symlink without -L/--copy-links" >&2; exit 0 ;;
      fail)   echo "2026/07/01 ERROR: transfer failed" >&2; exit 3 ;;
      *)      exit 0 ;;
    esac ;;
  lsf)
    [ -n "${RCLONE_LSF_ARG:-}" ] && printf '%s\n' "${2:-}" > "$RCLONE_LSF_ARG"
    printf '%s' "${RCLONE_LSF_OUT:-}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$BIN/rclone"
export PATH="$BIN:$PATH"

fails=0
ok(){ echo "ok   $1"; }
no(){ echo "FAIL $1"; fails=1; }

ARGS="$TMP/copy_args"; export RCLONE_COPY_ARGS="$ARGS"
LSFARG="$TMP/lsf_arg";  export RCLONE_LSF_ARG="$LSFARG"

# --- 1. THE bug: a `Can't follow symlink` NOTICE with rclone exit 0 -> r2_copy returns non-zero ------
if RCLONE_COPY_MODE=notice r2_copy /src /dst >/dev/null 2>&1; then no notice-is-incomplete; else ok notice-is-incomplete; fi

# --- 2. clean copy returns 0 AND always injects -L (a caller can't omit it) --------------------------
if RCLONE_COPY_MODE=ok r2_copy /src /dst >/dev/null 2>&1; then ok clean-copy-succeeds; else no clean-copy-succeeds; fi
if grep -qw -- '-L' "$ARGS"; then ok injects-L; else no "injects-L ($(cat "$ARGS"))"; fi

# --- 3. extra caller args are forwarded to rclone ---------------------------------------------------
RCLONE_COPY_MODE=ok r2_copy /src /dst --transfers=8 --checkers=8 >/dev/null 2>&1
if grep -q -- '--transfers=8' "$ARGS" && grep -q -- '--checkers=8' "$ARGS"; then ok forwards-extra-args; else no "forwards-extra-args ($(cat "$ARGS"))"; fi

# --- 4. rclone's own non-zero exit is propagated (no NOTICE) -----------------------------------------
if RCLONE_COPY_MODE=fail r2_copy /src /dst >/dev/null 2>&1; then no propagates-nonzero-exit; else ok propagates-nonzero-exit; fi

# --- 4b. symlink-defeating flags are REJECTED before rclone runs (they'd silence the NOTICE) ---------
: > "$ARGS"
if RCLONE_COPY_MODE=ok r2_copy /src /dst --skip-links >/dev/null 2>&1; then no rejects-skip-links; else ok rejects-skip-links; fi
[ ! -s "$ARGS" ] && ok reject-precedes-rclone || no "reject-precedes-rclone (rclone ran: $(cat "$ARGS"))"
if RCLONE_COPY_MODE=ok r2_copy /src /dst --copy-links=false >/dev/null 2>&1; then no rejects-copy-links-false; else ok rejects-copy-links-false; fi
if RCLONE_COPY_MODE=ok r2_copy /src /dst -l >/dev/null 2>&1; then no rejects-links-short; else ok rejects-links-short; fi

# --- 5. r2_exists: true when the name is in the DIR listing, false when absent -----------------------
if RCLONE_LSF_OUT=$'model-00001.safetensors\nmodel-00002.safetensors\n' r2_exists r2:bucket/dir model-00002.safetensors; then ok exists-true; else no exists-true; fi
if RCLONE_LSF_OUT=$'model-00001.safetensors\n' r2_exists r2:bucket/dir model-00002.safetensors; then no exists-false-when-absent; else ok exists-false-when-absent; fi

# --- 6. r2_exists lists the DIRECTORY (trailing /), NOT a single-file lsf path -----------------------
#     (a single-file lsf can phantom a deleted leaf → false pass; the dir-listing form is immune).
RCLONE_LSF_OUT='x' r2_exists r2:bucket/dir some-name >/dev/null 2>&1 || true
case "$(cat "$LSFARG")" in */) ok lists-directory-not-file ;; *) no "lists-directory-not-file ($(cat "$LSFARG"))" ;; esac

# --- 7. grep -qx anchors the whole name: a partial/substring match must NOT false-pass --------------
if RCLONE_LSF_OUT=$'model-00002.safetensors.tmp\n' r2_exists r2:bucket/dir model-00002.safetensors; then no exact-name-match; else ok exact-name-match; fi

[ "$fails" = 0 ] && { echo "PASS rclone_helper_smoke"; exit 0; } || { echo "FAIL rclone_helper_smoke"; exit 1; }
