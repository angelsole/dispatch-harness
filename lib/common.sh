# shellcheck shell=bash
# The plumbing every harness script needs, in one place.
#
# Sourced, never executed — like mirror.sh and capacity.sh, and by the same
# rule: each script reads it from beside itself, so it works from the checkout
# and from the install (install.sh ships lib/ into HARNESS_DIR). Safe under
# `set -u`: nothing here reads a variable it has not defaulted first.
#
# What lives here is what was provably copied: the same line in sixteen files,
# the same function body in three, a --help that every script re-implemented
# with a different hardcoded line range. What did NOT come here is fail(): its
# five callers mean five different things by it (a run that must write a
# result, a sync that must move a stage, a plain exit), and one shared fail()
# would have to lie to at least four of them.
#
# HARNESS_DIR and the knob defaults below are outputs read by the sourcing
# script, which shellcheck cannot see from here.
# shellcheck disable=SC2034

# Where runs, config and the installed scripts live. Sixteen scripts declared
# this same line; they now all get it from here.
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"

# The implementer knobs' defaults. Two scripts have to agree on them —
# run-task.sh pins them into the run dir at first dispatch, sync-pr.sh falls
# back to them when it re-runs the implementer on a PR whose run dir predates
# the pin — so they are defined once. The provider selects its default model;
# the Anthropic model is also what every Claude-subscription fallback uses when
# the implementer itself bills to another vendor. Explicit model IDs, never
# aliases: "opus" silently changed meaning the day Opus 5 shipped, which is
# exactly the condition drift the pinning exists to stop.
#
# Deliberately not HARNESS_*: in this repo that prefix means "an environment
# knob a user may set", and these are constants the environment cannot
# reach. IMPLEMENTER_MODEL / IMPLEMENTER_EFFORT are the knobs; these are only
# what they fall back to.
DEFAULT_IMPLEMENTER_PROVIDER="anthropic"
DEFAULT_ANTHROPIC_MODEL="claude-opus-5"
DEFAULT_ZAI_MODEL="glm-5.3"
DEFAULT_IMPLEMENTER_MODEL="$DEFAULT_ANTHROPIC_MODEL"
DEFAULT_IMPLEMENTER_EFFORT="high"

# Cap a long-running child. macOS ships no timeout(1), so fall back to a
# perl alarm wrapper (SIGALRM survives exec and kills the child after N secs).
with_timeout() {  # $1 = seconds, rest = command + args
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# A script's header comment IS its --help, read back at runtime so the two can
# never drift. Every caller used to carry its own `sed -n 'A,Bp' "$0"`, and a
# line added to or removed from a header silently truncated — or over-ran —
# that script's help without anything failing.
#
# By default the whole header is the help: everything from the line after the
# shebang up to the first line that is not a comment. A script whose help is
# only part of its header fences that part off, and the fence lines themselves
# are never printed:
#
#   # >>> --help >>>
#   #   thing.sh --flag   what it does
#   # <<< --help <<<
#
# Printed to stdout; the redirection and the exit status stay with the caller,
# because they differ (install.sh's --help succeeds, schedule.sh's usage is an
# error message on stderr that exits 2).
harness_usage() {  # $1 = the script, usually "$0"; prints its header comment
  awk '
    NR == 1 { next }                              # the shebang is not documentation
    $0 == "# >>> --help >>>" { n = 0; next }      # anything before this was preamble
    $0 == "# <<< --help <<<" { exit }
    !/^#/ { exit }                                # the header ends at the first code line
    { line = $0; sub(/^#/, "", line); sub(/^ /, "", line); buf[++n] = line }
    END { for (i = 1; i <= n; i++) print buf[i] }
  ' "$1"
}

# Where a run built its work. run-task.sh writes the path into the run dir as
# soon as the worktree exists; result.json is the fallback for runs that
# predate that file. Prints nothing when neither answers — the callers disagree
# about what that means (preview.sh and cleanup.sh treat it as "already cleaned
# up", the janitor counts it), so the decision stays with them.
harness_worktree() {  # $1 = run dir; prints the worktree path, or nothing
  cat "$1/worktree" 2>/dev/null || jq -r '.worktree // empty' "$1/result.json" 2>/dev/null
}

# Read a knob pinned in a run dir, falling back to a default. An empty pin file
# reads as empty, not as the default: a blank reviewer-model is a deliberate
# pin (run-task.sh writes one for a Claude-only first dispatch), not a missing one.
harness_knob() {  # $1 = run dir, $2 = file basename, $3 = default
  cat "$1/$2" 2>/dev/null || printf '%s' "$3"
}

# Is a worktree free of uncommitted work? The single predicate behind both the
# implementer→gate boundary and the read-only review passes: every stage after
# the implementer judges the committed diff, so a partial diff is refused
# wherever it is found, by the same test. Harness-ignored paths (.harness/ and
# friends) sit in the worktree's info/exclude and never count as dirty.
require_clean_worktree() {  # $1 = worktree; 0 clean, 1 dirty (paths listed on stderr)
  local dirty
  dirty=$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null)
  [ -z "$dirty" ] && return 0
  echo "[harness] implementer left uncommitted changes — not gating a partial diff. Commit them or discard:" >&2
  printf '%s\n' "$dirty" | sed 's/^/  /' >&2
  return 1
}

# Does a push's combined output carry a credential signature? Non-auth failures
# (non-fast-forward, missing remote, dead network) are deliberately not ours to
# judge — they belong to the real push at the end of the run.
_is_auth_error() {  # $1 = combined stderr; testable in isolation
  printf '%s' "$1" | grep -qiE "could not read (Username|Password)|Authentication failed|(Invalid|Bad) credentials|\\b403\\b"
}

# Exercise WRITE auth before any machine time is spent: an anonymous read (the
# setup fetch) can pass on a public repo while the push at the end cannot.
# GIT_TERMINAL_PROMPT=0 is what keeps a 401 from hanging on /dev/tty. Fails
# only on a credential signature; everything else falls through to the real push.
preflight_remote_auth() {  # $1 = worktree, $2 = branch, $3 = remote (default origin)
  local remote="${3:-origin}" out
  out=$(GIT_TERMINAL_PROMPT=0 git -C "$1" push --dry-run "$remote" "HEAD:refs/heads/$2" 2>&1) && return 0
  if _is_auth_error "$out"; then
    echo "[harness] cannot authenticate a push to '$remote' — the push at the end will fail." >&2
    echo "[harness] fix: set GH_TOKEN=\$(gh auth token --user <acct>) or check 'gh auth status', then re-dispatch." >&2
    return 1
  fi
  return 0   # non-auth failure — leave it to the real push
}

# Is the Codex CLI here? The Codex CLI is optional: a Claude subscription alone
# runs the same pipeline with a fresh Claude review tier and Claude handling
# base-sync conflicts. Resolved once per invocation so no stage ever shells out
# to a missing binary and logs a 127.
#
# Sets CODEX_BIN and CODEX_AVAILABLE, plus the labels for the
# conflict-resolution stage line and the escalation text: they name whichever
# CLI actually does the work.
harness_codex_preamble() {  # sets CODEX_BIN CODEX_AVAILABLE CONFLICT_AGENT CONFLICT_MODEL
  CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || echo codex)}"
  if command -v "$CODEX_BIN" >/dev/null 2>&1; then CODEX_AVAILABLE=1; else CODEX_AVAILABLE=0; fi
  CONFLICT_AGENT="Codex, ChatGPT sub"; CONFLICT_MODEL="Codex"
  [ "$CODEX_AVAILABLE" = 1 ] || { CONFLICT_AGENT="Claude sub"; CONFLICT_MODEL="Claude"; }
}

# Is a run's driver still alive? One predicate behind every "is this run working
# or dead" question, because status.sh, statusline.sh and janitor.sh each
# answered it differently and a killed driver rendered as a growing IN STAGE
# timer. Two signals: driver.pid is authoritative on this machine and meaningless
# in a run dir mirrored from another, where only an mtime travels.
HARNESS_DEAD_AFTER="${HARNESS_DEAD_AFTER:-120}"         # secs of silence = dead
HARNESS_HEARTBEAT_SECS="${HARNESS_HEARTBEAT_SECS:-20}"  # how often a driver ticks

# The ANSWER is validated, not the exit status, and GNU is asked first. BSD's
# `stat -f %m` is the mtime; GNU's `-f` is *filesystem* status, where `%m` is not
# a valid specifier — GNU prints `?` and exits **0**, so a BSD-first order never
# reaches its own fallback and hands every caller a non-number on Linux. The
# callers that guard (`run_alive`, the janitor) then read "cannot tell" forever,
# and the one that did not read zero rows out of a full run history.
harness_mtime() {  # $1 = path; prints the epoch mtime, or nothing
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) || m="" ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

# Run ids reach grep as data, not pattern: they are ticket ids and adhoc slugs,
# and one containing `[` makes grep exit 2 — which every caller reads as "not
# this driver", so a live holder looks unrecognised and a second driver is
# allowed to start. Escape the BRE metacharacters instead of trusting the input.
harness_bre_escape() {  # $1 = literal -> a BRE matching exactly it
  printf '%s' "$1" | sed 's/[][\.*^$\\]/\\&/g'
}

# Does this pid belong to a harness driver for this run? `kill -0` alone answers
# "some process has this pid", which on a machine that has wrapped its pid space
# is a different question.
#   0 = a driver for this run   1 = no such process   2 = alive, unrecognised
# The third answer is never treated as the first or the second by callers: ps(1)
# can be absent, restricted or truncating, and a caller that resolves "cannot
# identify" to "gone" would act on every live process it failed to read.
harness_driver_pid_live() {  # $1 = pid, $2 = run id (may be empty)
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "${2:-}" ] || return 2
  ps -o command= -p "$1" 2>/dev/null \
    | grep -q "\(run-task\|sync-pr\)\.sh $(harness_bre_escape "$2")\([[:space:]]\|\$\)" && return 0
  return 2
}

# The stages for which no driver process is expected, so "no process" is not
# evidence of death. Centralised here so status.sh, statusline.sh and janitor.sh
# cannot disagree and reap a run that is merely waiting on a human.
harness_stage_expects_no_driver() {  # $1 = stage text
  case "$1" in
    done:*|deferred:*|waiting*|'sync failed'*) return 0 ;;
    *) return 1 ;;
  esac
}

run_alive() {  # $1 = run dir -> 0 alive, 1 dead, 2 cannot tell
  local pid hb age _ts _stage
  if [ -r "$1/status" ]; then
    read -r _ts _stage < "$1/status" 2>/dev/null || _stage=""
    harness_stage_expects_no_driver "${_stage:-}" && return 2
  fi
  # Both reads are guarded by a builtin and the pid uses `read`, not `cat`:
  # statusline.sh pays for this per live run on every shell prompt.
  hb=""
  if [ -f "$1/heartbeat" ]; then
    hb=$(harness_mtime "$1/heartbeat") || hb=""
    case "$hb" in ''|*[!0-9]*) hb="" ;; esac
  fi
  if [ -n "$hb" ]; then
    age=$(( $(date +%s) - hb ))
    [ "$age" -le "$HARNESS_DEAD_AFTER" ] && return 0
  fi
  pid=""
  if [ -f "$1/driver.pid" ]; then
    read -r pid < "$1/driver.pid" 2>/dev/null || pid=""
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  fi
  if [ -n "$pid" ]; then
    harness_driver_pid_live "$pid" "${1##*/}" && return 0
  fi
  [ -n "$hb" ] || [ -n "$pid" ] || return 2   # neither file: cannot tell
  return 1
}

# --- The heartbeat ticker -----------------------------------------------------
# Shared by both drivers so there is one implementation to reason about and one
# for tests to exercise.
#
# Output is closed because nothing waits for the ticker: in the foreground arm
# the driver's stdout is a pipe the gate reads, and a ticker still holding it
# would keep the gate waiting on EOF after the run had finished.
harness_start_heartbeat() {  # $1 = run dir -> sets HEARTBEAT_PID
  local dir="$1" owner=$$
  touch "$dir/heartbeat" 2>/dev/null || true
  ( trap 'exit 0' TERM INT
    while kill -0 "$owner" 2>/dev/null; do
      sleep "${HARNESS_HEARTBEAT_SECS:-20}"
      touch "$dir/heartbeat" 2>/dev/null || exit 0
      # The same tick keeps the run's Linear session out of `stale`, at its own
      # much slower interval. Only where lib/linear.sh is loaded — common.sh is
      # sourced on its own by callers that have no ticket sync at all.
      if declare -F linear_heartbeat >/dev/null 2>&1; then linear_heartbeat || true; fi
    done ) >/dev/null 2>&1 &
  HEARTBEAT_PID=$!
}

# Two signals, and both are needed. `kill` alone is deferred: bash runs a trap
# only once the foreground command returns, so the ticker sits inside its sleep
# and a `wait` blocks for the rest of the interval — with everything the exit
# path still owes queued behind it. Simply not waiting is no answer either: the
# ticker is a fork of the driver and carries its argv, so a survivor reads as
# the run still having a process (tests/mirror.test.sh counts exactly that).
# Killing the sleep first makes the wait return at once.
harness_stop_heartbeat() {
  [ -n "${HEARTBEAT_PID:-}" ] || return 0
  pkill -P "$HEARTBEAT_PID" 2>/dev/null || true
  kill -9 "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}

# --- The per-repo gate lock ---------------------------------------------------
# Two runs on the SAME repo ran their `npm test` gates at once and both seeded
# the one local Postgres their worktrees share: deadlocks, unique-constraint
# failures in the seeder, 52 phantom failures. Only the gate takes this lock;
# implementer and review stages stay parallel.
#
# The lock is a SYMLINK whose target is the owner record "<pid> <epoch> <run id>".
# A directory plus an owner file is two operations, and a waiter reading the gap
# between them sees an unattributable lock; symlink(2) publishes the lock and
# its owner in one syscall. The run id is last so `read` takes it whole — adhoc
# run ids can contain spaces. Nothing follows the link, so test it with -L: it
# dangles by design.
#
# THE SAFETY RULE, and every branch below answers to it: a lock is only ever
# taken from a holder PROVEN gone. `kill -0` failing is proof. Nothing else is —
# not an unreadable owner, not an argv ps(1) would not show us, not a timer.
# A waiter that guesses is a waiter that runs the gate beside a live one, which
# is the collision this lock exists to prevent.
HARNESS_GATE_LOCK_WAIT="${HARNESS_GATE_LOCK_WAIT:-3600}"  # max secs to wait
HARNESS_GATE_LOCK_POLL="${HARNESS_GATE_LOCK_POLL:-5}"     # secs between tries

# The basename is the key, not the path: workspace-1/olyxbase and
# workspace-2/olyxbase are different checkouts of one repo sharing one local
# test database, which is exactly the collision. HARNESS_GATE_LOCK_KEY overrides
# it for a repo whose gate touches nothing shared.
harness_gate_lock_key() {  # $1 = repo path
  if [ -n "${HARNESS_GATE_LOCK_KEY:-}" ]; then printf '%s' "$HARNESS_GATE_LOCK_KEY"; return 0; fi
  basename "$1" | tr -c 'A-Za-z0-9._-' '_'
}

harness_gate_lock_path() {  # $1 = key
  printf '%s/locks/gate-%s.lock' "$HARNESS_DIR" "$1"
}

harness_gate_lock_owner() {  # $1 = lock path -> "<pid> <epoch> <run id>"
  readlink "$1" 2>/dev/null
}

# Who holds it, in words, or nothing when nobody readable does.
harness_gate_lock_holder() {  # $1 = lock path
  local pid ots rid
  read -r pid ots rid <<EOF
$(harness_gate_lock_owner "$1")
EOF
  [ -n "${pid:-}" ] || return 1
  printf '%s' "${rid:-pid $pid}"
}

# A lock left by the version of this code that used mkdir(2). Its owner file is
# "<pid> <run id> <epoch>" — the run id in the middle, which is why the order
# changed. Returns that pid, so a rolling upgrade can tell a stale directory
# from one a still-running old driver is inside.
harness_gate_lock_legacy_pid() {  # $1 = lock path
  local pid rest
  [ -f "$1/owner" ] || return 1
  read -r pid rest < "$1/owner" 2>/dev/null || return 1
  case "${pid:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pid"
}

# 0 = held (ours now), 1 = gave up and the caller must gate unserialized.
# $3 is a function name called ONCE with the holder's description, the first
# time we actually wait — that is what puts "waiting for gate lock" in the
# stage text instead of leaving a silent gap.
harness_gate_lock_acquire() {  # $1 = key, $2 = run id, $3 = on-wait fn (optional)
  local key="$1" rid="$2" onwait="${3:-}" lock waited=0 pid ots orid other told=0
  local legacy alive
  [ "${HARNESS_GATE_LOCK:-1}" = 0 ] && return 1
  lock=$(harness_gate_lock_path "$key")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  while :; do
    alive=0
    # A non-symlink here is a lock from the mkdir(2) era. It may still be held:
    # during a rolling upgrade an old driver can be inside its gate right now,
    # and clearing it would put two runs on one database — the very thing being
    # fixed. Read its owner and leave it alone while that pid lives.
    if [ -e "$lock" ] && [ ! -L "$lock" ]; then
      if legacy=$(harness_gate_lock_legacy_pid "$lock") && kill -0 "$legacy" 2>/dev/null; then
        alive=1
      elif mv "$lock" "$lock.stale.$$" 2>/dev/null; then
        rm -rf "$lock.stale.$$" 2>/dev/null || true
      fi
    fi
    if [ "$alive" = 0 ] && ln -s "$$ $(date +%s) $rid" "$lock" 2>/dev/null; then return 0; fi

    pid=''; ots=''; orid=''
    read -r pid ots orid <<EOF
$(harness_gate_lock_owner "$lock")
EOF
    case "${pid:-}" in ''|*[!0-9]*) pid='' ;; esac
    # Ours already — a nested call, not a deadlock against ourselves. The run id
    # is checked too: $$ is shared by every subshell of one script and is
    # recycled by the OS, so the pid alone would hand the lock to a stranger.
    if [ -n "$pid" ] && [ "$pid" = "$$" ]; then
      [ "$orid" = "$rid" ] && return 0
      # Our own pid, a different run: waiting is a deadlock against ourselves,
      # because the only process that can release this lock is the one blocked
      # here. Give up instead of hanging until somebody kills the run.
      return 1
    fi

    if [ -n "$pid" ]; then
      harness_driver_pid_live "$pid" "$orid"
      case $? in
        1) # Proven gone. Steal by RENAME: rename(2) picks exactly one winner
           # when several waiters spot the same dead holder at the same instant.
           if mv "$lock" "$lock.stale.$$" 2>/dev/null; then
             rm -f "$lock.stale.$$" 2>/dev/null || true
             continue
           fi ;;
        *) alive=1 ;;   # 0 or 2: something is running. Wait for it.
      esac
    else
      # Unreadable. Almost always the moment between a holder releasing and the
      # next one claiming, and never proof of anything — a waiter that stole
      # here removed a live lock. Retry the claim instead.
      :
    fi

    if [ "$told" = 0 ] && [ -n "$onwait" ]; then
      other=$(harness_gate_lock_holder "$lock" 2>/dev/null) || other=""
      "$onwait" "${other:-another run}"
      told=1
    fi
    # The ceiling releases a run from a lock it cannot make sense of — an
    # unreadable owner, a holder that vanished mid-claim. It does NOT authorise
    # barging past a holder that is demonstrably running: gating unserialized
    # beside a live gate IS the collision, so the wait outlasts the ceiling and
    # says so once. A stall a human can see beats two runs seeding one database.
    # HARNESS_GATE_LOCK=0 is the escape if a holder is wedged beyond saving.
    if [ "$waited" -ge "$HARNESS_GATE_LOCK_WAIT" ]; then
      [ "$alive" = 0 ] && return 1
      if [ "$told" != 2 ] && [ -n "$onwait" ]; then
        other=$(harness_gate_lock_holder "$lock" 2>/dev/null) || other=""
        "$onwait" "${other:-another run} — still running after $((waited / 60))m"
        told=2
      fi
    fi
    sleep "$HARNESS_GATE_LOCK_POLL"
    waited=$((waited + HARNESS_GATE_LOCK_POLL))
  done
}

# Only the owner releases, so a run cannot drop a lock it does not hold.
harness_gate_lock_release() {  # $1 = key
  local lock pid ots rid
  [ -n "${1:-}" ] || return 0
  lock=$(harness_gate_lock_path "$1")
  [ -L "$lock" ] || return 0    # -L, not -e: the link dangles on purpose
  read -r pid ots rid <<EOF
$(harness_gate_lock_owner "$lock")
EOF
  [ "${pid:-}" = "$$" ] || return 0
  rm -f "$lock" 2>/dev/null || true
}
