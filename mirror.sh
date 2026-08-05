# shellcheck shell=bash
# Run mirroring, sourced by run-task.sh / sync-pr.sh / cleanup.sh.
#
# Ghost Shift reads the run dirs of the machine that serves it, so a run
# executed on a crew member's laptop is invisible on the office wall. Set
# HARNESS_MIRROR in the dispatching environment and the run copies its run dir
# to that target for the lifetime of the invocation — the wall then shows work
# happening anywhere, with no hand-rolled rsync loop:
#
#   HARNESS_MIRROR=mini:.claude/harness/runs   an ssh destination (has a colon)
#   HARNESS_MIRROR=/some/dir                   a path on this machine (none)
#
# The copy lands at <target>/<RUN-ID>/ and is refreshed every MIRROR_INTERVAL
# seconds. Only the run dir travels — never the worktree.
#
# The wall is a luxury, so mirroring is best-effort in the strongest sense: an
# unreachable target, a dead tailnet, or a machine without rsync must never
# fail, slow, or block a run. Every error is swallowed; the last one is left in
# mirror.log inside the run dir (rewritten each pass, so it never grows and an
# empty one means the last pass was fine).
#
# With HARNESS_MIRROR unset nothing here runs — no loop, no trap, no output, no
# file in the run dir — and a run behaves exactly as it did before this existed.

MIRROR_INTERVAL=2       # seconds between passes
MIRROR_SYNC_TIMEOUT=2   # hard ceiling for any rsync/ssh process

# The mirror loop has nobody to answer a prompt, and a pass that hangs on a
# half-dead tailnet must still end: BatchMode never asks, ConnectTimeout caps a
# dead host, and the ServerAlive pair caps a connection that dies mid-transfer.
# The target must therefore be an ssh host this machine can already reach
# non-interactively (key auth, known host).
MIRROR_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=2 -o ServerAliveInterval=1 -o ServerAliveCountMax=1)
MIRROR_SSH="ssh ${MIRROR_SSH_ARGS[*]}"

MIRROR_PID=""   # the live loop, empty when mirroring is off or already stopped
MIRROR_CHILD_PID=""   # the loop's current rsync or sleep process
MIRROR_DIR=""
MIRROR_ID=""

mirror_enabled() { [ -n "${HARNESS_MIRROR:-}" ]; }

# A run id is one directory below the configured target. Refuse path
# components: cleanup must never turn a value such as ../another-run into a
# deletion outside that target, and the same rule keeps rsync destinations
# unambiguous.
mirror_safe_id() {
  case "$1" in ""|.|..|*/*) return 1 ;; *) return 0 ;; esac
}

# A colon means an ssh destination; anything else is a path on this machine.
# That is the whole reason the plain-path form exists: it is what the test
# suite mirrors into, and what a second disk on the same machine would use.
mirror_is_remote() { case "${HARNESS_MIRROR:-}" in *:*) return 0 ;; *) return 1 ;; esac; }

# Quote one value for the remote POSIX shell used by ssh/rsync. In particular,
# a quote in a configured remote path must remain data rather than becoming a
# command boundary.
mirror_shell_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

# Run rsync under an independent alarm. The loop executes this function in a
# subshell, so MIRROR_CHILD_PID lets its TERM trap cancel the current pass
# immediately instead of waiting for a dead mount or tailnet. perl is already a
# harness prerequisite and, by execing rsync, keeps the same pid for the alarm.
mirror_run_rsync() {  # $1 = error log, rest = rsync argv
  local log="$1" rc line last=""
  shift
  perl -e 'alarm shift; exec @ARGV' "$MIRROR_SYNC_TIMEOUT" "$@" 2> "$log" &
  MIRROR_CHILD_PID=$!
  wait "$MIRROR_CHILD_PID" 2>/dev/null
  rc=$?
  MIRROR_CHILD_PID=""
  if [ "$rc" -ne 0 ] && [ ! -s "$log" ]; then
    echo "mirror sync failed or timed out" > "$log"
  elif [ -s "$log" ]; then
    # The contract permits one quiet diagnostic, not an unbounded rsync/ssh
    # transcript. Keep only the final stderr line from this pass.
    while IFS= read -r line || [ -n "$line" ]; do last="$line"; done < "$log"
    printf '%s\n' "$last" > "$log"
  fi
  return "$rc"
}

mirror_cancel_child() {
  [ -n "${MIRROR_CHILD_PID:-}" ] || return 0
  kill "$MIRROR_CHILD_PID" 2>/dev/null || true
  wait "$MIRROR_CHILD_PID" 2>/dev/null || true
  MIRROR_CHILD_PID=""
}

mirror_pause() {
  sleep "$MIRROR_INTERVAL" &
  MIRROR_CHILD_PID=$!
  wait "$MIRROR_CHILD_PID" 2>/dev/null || true
  MIRROR_CHILD_PID=""
}

# One pass. --delete matters as much as the copy does: a QUESTIONS.md the
# orchestrator has answered must disappear from the wall, or the alarm it
# raises there outlives the question.
mirror_sync() {  # $1 = run dir, $2 = run id — always succeeds
  local target="${HARNESS_MIRROR:-}" rsync_bin remote_path remote_dest
  [ -n "$target" ] && mirror_safe_id "$2" && [ -d "$1" ] || return 0
  rsync_bin=$(command -v rsync 2>/dev/null) || {
    echo "rsync not installed — this run is not mirrored to $target" > "$1/mirror.log"
    return 0
  }
  if mirror_is_remote; then
    [ -n "${target%%:*}" ] || return 0
    remote_path="${target#*:}"
    remote_path="${remote_path%/}/$2/"
    remote_dest="${target%%:*}:$(mirror_shell_quote "$remote_path")"
    mirror_run_rsync "$1/mirror.log" "$rsync_bin" -a --delete \
      --exclude=mirror.log -e "$MIRROR_SSH" -- "$1/" "$remote_dest" || true
  else
    # rsync creates the last component of the destination, not its parents, so
    # a first mirror into a directory that does not exist yet needs this.
    mkdir -p "${target%/}" 2>/dev/null || true
    mirror_run_rsync "$1/mirror.log" "$rsync_bin" -a --delete \
      --exclude=mirror.log -- "$1/" "${target%/}/$2/" || true
  fi
  return 0
}

# The loop belongs to ONE invocation. It is killed by mirror_stop on every exit
# path, and independently follows the pid that started it — so even a parent
# killed outright (no trap runs) leaves no loop behind past one interval.
mirror_loop() {  # $1 = run dir, $2 = run id, $3 = pid to follow
  trap 'mirror_cancel_child; exit 0' TERM INT
  while kill -0 "$3" 2>/dev/null; do
    mirror_sync "$1" "$2"
    mirror_pause
  done
  trap - TERM INT
}

mirror_start() {  # $1 = run dir, $2 = run id
  mirror_enabled || return 0
  MIRROR_DIR="$1"; MIRROR_ID="$2"
  mirror_loop "$1" "$2" "$$" &
  MIRROR_PID=$!
  # The sourcing scripts have no EXIT trap of their own. This one never calls
  # exit, so the status they exit with — 0/1 from run-task.sh's final test, 1
  # from fail(), 3 from needs_input — reaches the caller untouched.
  trap mirror_stop EXIT
}

# Last pass, then the loop dies with the invocation.
mirror_stop() {
  local rc=$?
  [ -n "$MIRROR_PID" ] || return "$rc"
  kill "$MIRROR_PID" 2>/dev/null
  wait "$MIRROR_PID" 2>/dev/null
  MIRROR_PID=""
  # The wall needs the terminal state, and `done: <status>` plus result.json are
  # written after the loop's last pass — so the invocation ends with one more.
  mirror_sync "$MIRROR_DIR" "$MIRROR_ID"
  return "$rc"
}

# Drop a run's mirrored copy, so a promoted run leaves the wall's disk too.
mirror_remove() {  # $1 = run id — always succeeds
  local target="${HARNESS_MIRROR:-}" dest host quoted_dest
  [ -n "$target" ] && mirror_safe_id "$1" || return 0
  if mirror_is_remote; then
    host="${target%%:*}"
    case "$host" in ""|-*) return 0 ;; esac
    dest="${target#*:}"
    dest="${dest%/}/$1"
    quoted_dest=$(mirror_shell_quote "$dest")
    perl -e 'alarm shift; exec @ARGV' "$MIRROR_SYNC_TIMEOUT" \
      ssh "${MIRROR_SSH_ARGS[@]}" -- "$host" "rm -rf -- $quoted_dest" \
      >/dev/null 2>&1 || true
  else
    dest="${target%/}/$1"
    rm -rf "${dest:?}" 2>/dev/null || true
  fi
  return 0
}
