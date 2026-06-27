#!/bin/bash
# run_supervision_record.sh — the run-supervision record: machine-consumed desired-state for a
# model-free relaunch supervisor (the #54 crash-resilience design, child 1). PRODUCT helper — no
# instance specifics (session names, relaunch commands, systemd wiring are all instance, consumed
# via this API).
#
# WHAT IT IS: a tiny per-run JSON record carrying RELAUNCH-scoped state only —
#   desired_active / stopped / closed / handoff_path / lease_pod_ids / timestamps. It LINKS to the
#   gpu-job pod lease(s) (the #54 child-2 record) by pod id; it never holds pod-DELETION policy
#   (that is the lease's domain). The model-free supervisor reads `is-desired-active` to decide
#   whether a gone session should be relaunched (desired-active, not stopped, not closed) or left
#   alone (a deliberate /quit or a finished run).
#
# WHY A HELPER, NOT PROSE: the record is genuinely stateful, so one product implementation owns the
#   atomic-write + monotonic-state semantics rather than every consumer (claude-pane-loop.sh, the
#   instance stop helpers, the supervisor) re-deriving them and drifting.
#
# STATE MACHINE (monotonic; stop/close are TERMINAL):
#   create  -> desired_active=true, stopped=false, closed=false
#   update  -> refresh handoff_path / add lease_pod_ids; FAILS CLOSED if already stopped or closed
#              (never resurrects a deliberately-stopped or finished run)
#   stop    -> stopped=true (a /quit or manual kill: do NOT resurrect). Terminal.
#   close   -> closed=true (run finished). Terminal.
#   is-desired-active -> exit 0 iff desired_active && !stopped && !closed; else exit 1 (a MISSING
#              record is exit 1 — fail-closed, an unknown run is never resurrected).
#
# CONCURRENCY: every mutation takes a per-record flock for the whole read-modify-write window, and
#   the terminal-state guard runs INSIDE that lock — so a concurrent `update` cannot read-modify-write
#   over a `stop`/`close` and re-activate a stopped run. Writes go through a temp file + mv under the
#   lock, so a crash mid-write never leaves a half-written record.
#
# USAGE:
#   run_supervision_record.sh create <run-id> [--handoff PATH]
#   run_supervision_record.sh update <run-id> [--handoff PATH] [--lease-pod ID]...
#   run_supervision_record.sh stop   <run-id>
#   run_supervision_record.sh close  <run-id>
#   run_supervision_record.sh is-desired-active <run-id>     # exit 0/1, no output
#   run_supervision_record.sh show   <run-id>                # print the JSON (debug)
#
# Record root is instance-overridable: ${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}.
set -euo pipefail

ROOT="${AAR_RUN_SUPERVISION_DIR:-$HOME/.config/run-supervision}"

die(){ echo "run_supervision_record: $*" >&2; exit 2; }

# run-id is used as a filename — keep it path-safe (no traversal / separators).
validate_id(){
  [ -n "${1:-}" ] || die "missing <run-id>"
  case "$1" in
    *[!A-Za-z0-9._-]*) die "invalid run-id '$1' (allowed: A-Za-z0-9._-)";;
    .|..) die "invalid run-id '$1'";;
  esac
}

record_path(){ printf '%s/%s.json' "$ROOT" "$1"; }
lock_path(){ printf '%s/%s.lock' "$ROOT" "$1"; }

# Read a top-level field from the record JSON ("" if record or field absent). python3 is already a
# hard dependency of the .aar-ci checks + the rest of the plugin scaffold.
get_field(){ # <file> <field>
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if v is None:
    sys.exit(0)
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, list):
    print("\n".join(str(x) for x in v))
else:
    print(v)
PY
}

# Atomically write the record from a python dict built on stdin-supplied kwargs. Always under the lock.
# Args after <file>: handoff (or "" = leave), add_pods (newline list), set_stopped, set_closed (each
# "true"/"false"/""), create (true/false). Preserves existing fields it doesn't touch.
write_record(){ # <file> <handoff> <add_pods> <set_stopped> <set_closed> <create>
  local file=$1 handoff=$2 add_pods=$3 set_stopped=$4 set_closed=$5 create=$6
  HANDOFF="$handoff" ADD_PODS="$add_pods" SET_STOPPED="$set_stopped" SET_CLOSED="$set_closed" CREATE="$create" \
  python3 - "$file" <<'PY'
import json, os, sys, tempfile, time

path = sys.argv[1]
try:
    rec = json.load(open(path))
    if not isinstance(rec, dict):
        raise ValueError
except Exception:
    rec = {}

now = int(time.time())
if os.environ.get("CREATE") == "true":
    rec = {
        "run_id": os.path.basename(path)[:-5] if path.endswith(".json") else os.path.basename(path),
        "desired_active": True,
        "stopped": False,
        "closed": False,
        "handoff_path": None,
        "lease_pod_ids": [],
        "created_at": now,
    }
rec.setdefault("desired_active", True)
rec.setdefault("stopped", False)
rec.setdefault("closed", False)
rec.setdefault("lease_pod_ids", [])

handoff = os.environ.get("HANDOFF", "")
if handoff:
    rec["handoff_path"] = handoff
add_pods = [p for p in os.environ.get("ADD_PODS", "").splitlines() if p]
if add_pods:
    seen = list(rec.get("lease_pod_ids") or [])
    for p in add_pods:
        if p not in seen:
            seen.append(p)
    rec["lease_pod_ids"] = seen
if os.environ.get("SET_STOPPED") == "true":
    rec["stopped"] = True
    rec["desired_active"] = False
if os.environ.get("SET_CLOSED") == "true":
    rec["closed"] = True
    rec["desired_active"] = False
rec["updated_at"] = now

d = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".rsr.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

# Run <fn> ... while holding the per-record lock (whole read-modify-write window).
with_lock(){ # <run-id> <fn> [args...]
  local id=$1; shift
  mkdir -p "$ROOT"
  local lock; lock=$(lock_path "$id")
  exec 9>"$lock"
  flock 9
  "$@"
}

cmd_create(){
  local id=$1; shift
  local handoff=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff) handoff=${2:-}; shift 2;;
      *) die "create: unknown arg '$1'";;
    esac
  done
  local file; file=$(record_path "$id")
  write_record "$file" "$handoff" "" "" "" "true"
  echo "created run-supervision record: $file (desired-active)"
}

cmd_update(){
  local id=$1; shift
  local handoff="" pods=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff)   handoff=${2:-}; shift 2;;
      --lease-pod) pods="${pods}${2:-}"$'\n'; shift 2;;
      *) die "update: unknown arg '$1'";;
    esac
  done
  local file; file=$(record_path "$id")
  [ -f "$file" ] || die "update: no record for '$id' (create it first)"
  # terminal-state guard INSIDE the lock — never resurrect a stopped/closed run
  if [ "$(get_field "$file" stopped)" = "true" ]; then die "update: run '$id' is stopped (terminal) — refusing to modify"; fi
  if [ "$(get_field "$file" closed)"  = "true" ]; then die "update: run '$id' is closed (terminal) — refusing to modify"; fi
  write_record "$file" "$handoff" "$pods" "" "" "false"
  echo "updated run-supervision record: $file"
}

cmd_stop(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || die "stop: no record for '$id'"
  write_record "$file" "" "" "true" "" "false"
  echo "stopped run-supervision record: $file (will NOT be relaunched)"
}

cmd_close(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || die "close: no record for '$id'"
  write_record "$file" "" "" "" "true" "false"
  echo "closed run-supervision record: $file (inactive)"
}

# is-desired-active: exit 0 iff supervisor should relaunch this run; exit 1 otherwise. No mutation, but
# read under the lock so it never observes a half-applied state. A MISSING record is exit 1 (fail-closed).
cmd_is_desired_active(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || exit 1
  local active stopped closed
  active=$(get_field "$file" desired_active)
  stopped=$(get_field "$file" stopped)
  closed=$(get_field "$file" closed)
  if [ "$active" = "true" ] && [ "$stopped" != "true" ] && [ "$closed" != "true" ]; then
    exit 0
  fi
  exit 1
}

cmd_show(){
  local id=$1; local file; file=$(record_path "$id")
  [ -f "$file" ] || die "show: no record for '$id'"
  cat "$file"
}

main(){
  local sub=${1:-}; shift || true
  local id=${1:-}
  case "$sub" in
    create|update|stop|close|is-desired-active|show) validate_id "$id"; shift;;
    "") die "usage: run_supervision_record.sh <create|update|stop|close|is-desired-active|show> <run-id> [...]";;
    *) die "unknown subcommand '$sub'";;
  esac
  case "$sub" in
    create)            with_lock "$id" cmd_create "$id" "$@";;
    update)            with_lock "$id" cmd_update "$id" "$@";;
    stop)              with_lock "$id" cmd_stop   "$id";;
    close)             with_lock "$id" cmd_close  "$id";;
    # is-desired-active exits 0/1 from inside with_lock; preserve that exit code
    is-desired-active) with_lock "$id" cmd_is_desired_active "$id";;
    show)              with_lock "$id" cmd_show   "$id";;
  esac
}

main "$@"
