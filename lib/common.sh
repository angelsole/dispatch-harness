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

# Is a run's driver still alive? The one predicate behind every "is this run
# working or dead" question — status.sh's table, status.sh --watch,
# statusline.sh and janitor.sh's zombie reap all used to answer it differently
# or not at all, and a killed driver therefore rendered as a growing "IN STAGE"
# timer indistinguishable from a slow gate. Two signals, because neither alone
# is enough: run-task.sh writes its pid to <run>/driver.pid, which is
# authoritative on THIS machine and meaningless in a run dir mirrored from
# another one (HARNESS_MIRROR), where only an mtime travels — so it also touches
# <run>/heartbeat every HARNESS_HEARTBEAT_SECS.
#
# Three answers, and the third one matters: a run dir written before this
# existed has neither file and must render exactly as it always did rather than
# be slandered as dead.
HARNESS_DEAD_AFTER="${HARNESS_DEAD_AFTER:-120}"         # secs of silence = dead
HARNESS_HEARTBEAT_SECS="${HARNESS_HEARTBEAT_SECS:-20}"  # how often a driver ticks

# The GNU form is probed FIRST because it is the one that fails silently on the
# other platform. `stat -c` on BSD/macOS writes a usage line to stderr, nothing
# to stdout, and exits 1 — a clean miss. The reverse order looks equivalent and
# is not: `stat -f` on GNU coreutils means --file-system, so it prints six lines
# of filesystem statistics to STDOUT and exits 1, the `||` fallback then appends
# the real epoch, and the caller's numeric guard throws the whole blob away. The
# heartbeat signal was therefore dead on Linux, which is where CI runs, and with
# it the only liveness signal a mirrored run dir carries.
# Memoised: run_alive is on statusline.sh's per-prompt path, so the flavour is
# resolved once per shell rather than costing a doomed fork on every call.
_DISPATCH_STAT_FLAVOUR=""
harness_mtime() {  # $1 = path; prints the epoch mtime, or nothing
  case "$_DISPATCH_STAT_FLAVOUR" in
    gnu) stat -c %Y "$1" 2>/dev/null; return ;;
    bsd) stat -f %m "$1" 2>/dev/null; return ;;
  esac
  local v
  if v=$(stat -c %Y "$1" 2>/dev/null) && [ -n "$v" ]; then
    _DISPATCH_STAT_FLAVOUR=gnu; printf '%s\n' "$v"; return 0
  fi
  if v=$(stat -f %m "$1" 2>/dev/null) && [ -n "$v" ]; then
    _DISPATCH_STAT_FLAVOUR=bsd; printf '%s\n' "$v"; return 0
  fi
  return 1
}

# The stages for which NO driver process is expected, so "no process" is not
# evidence of death. `waiting` is a run that asked the human a question,
# `deferred:` one armed for a later window, `sync failed` one the vocab
# deliberately keeps non-terminal so it stays a loud live panel; `done:` is
# terminal. harness_on_exit leaves the run dir behind when a driver exits
# cleanly on any of them, so without this the pid is gone, the heartbeat goes
# cold two minutes later and run_alive calls a perfectly healthy paused run
# DEAD. status.sh and statusline.sh each guarded that with their own arm and
# janitor.sh did not — which is how reap_zombies came to replace the loudest
# alarm on the wall with a dim `done: reaped` ten minutes after a run asked a
# question. The exclusion lives HERE so all three consumers agree by
# construction rather than by three separate remembering.
harness_stage_expects_no_driver() {  # $1 = stage text
  case "$1" in
    done:*|deferred:*|waiting*|'sync failed'*) return 0 ;;
    *) return 1 ;;
  esac
}

run_alive() {  # $1 = run dir -> 0 alive, 1 dead, 2 cannot tell
  local pid hb age _ts _stage
  # A paused run is not a dead one, whatever the pid and the heartbeat say.
  if [ -r "$1/status" ]; then
    read -r _ts _stage < "$1/status" 2>/dev/null || _stage=""
    harness_stage_expects_no_driver "${_stage:-}" && return 2
  fi
  # The heartbeat first: it is the cheapest answer and the common one for a live
  # run, and statusline.sh pays for this on every prompt.
  hb=$(harness_mtime "$1/heartbeat") || hb=""
  case "$hb" in ''|*[!0-9]*) hb="" ;; esac
  if [ -n "$hb" ]; then
    age=$(( $(date +%s) - hb ))
    [ "$age" -le "$HARNESS_DEAD_AFTER" ] && return 0
  fi
  # A cold or absent heartbeat is not proof on its own — a stopped ticker, a
  # clock that moved, a run dir from before this existed. The pid decides.
  pid=$(cat "$1/driver.pid" 2>/dev/null) || pid=""
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # A recycled pid must not vouch for a dead run: check the process really is
    # this run's driver, the way janitor.sh's zombie guard checks with pgrep.
    if ps -o command= -p "$pid" 2>/dev/null \
         | grep -q "\(run-task\|sync-pr\)\.sh ${1##*/}\([[:space:]]\|\$\)"; then
      return 0
    fi
  fi
  [ -n "$hb" ] || [ -n "$pid" ] || return 2   # neither file: cannot tell
  return 1
}

# --- The per-repo gate lock ---------------------------------------------------
# Two runs on the SAME repo ran their `npm test` gates at the same moment and
# both seeded the one local Postgres their worktrees share: deadlock detected,
# unique-constraint failures in the seeder, 52 phantom failures, one run
# gate_failed and the other sent into a fix round it did not need. The gate is
# the only stage with that problem — it is the one that touches a resource
# outside the worktree — so the gate, and only the gate, is serialized per repo.
# Implementer and review stages stay fully parallel.
#
# mkdir(2) is the primitive: it either creates the directory or fails, on every
# filesystem, and macOS ships no flock(1). The holder's pid and run id live in
# the directory so a waiter can say WHO it is waiting for, and so a crashed
# holder can be stolen from rather than blocking every future gate forever.
HARNESS_GATE_LOCK_WAIT="${HARNESS_GATE_LOCK_WAIT:-3600}"  # max secs to wait
HARNESS_GATE_LOCK_POLL="${HARNESS_GATE_LOCK_POLL:-5}"     # secs between tries

# Which repo this run's gate contends on. The basename is deliberately the key
# rather than the path: dashboard-workspace-1/olyxbase and
# dashboard-workspace-2/olyxbase are different checkouts of one repo sharing one
# local test database, which is exactly the collision. HARNESS_GATE_LOCK_KEY
# overrides it for a repo whose gate touches nothing shared.
harness_gate_lock_key() {  # $1 = repo path
  if [ -n "${HARNESS_GATE_LOCK_KEY:-}" ]; then printf '%s' "$HARNESS_GATE_LOCK_KEY"; return 0; fi
  basename "$1" | tr -c 'A-Za-z0-9._-' '_'
}

harness_gate_lock_path() {  # $1 = key
  printf '%s/locks/gate-%s.lock' "$HARNESS_DIR" "$1"
}

# The lock is a SYMLINK whose target is the owner record — "<pid> <run id>
# <epoch>" — and not a directory with an owner file inside it, because those are
# two operations and a lock needs one. mkdir(2) publishes an unattributable lock
# and the owner write lands microseconds later; a waiter reading that gap finds
# no owner, concludes the holder crashed, steals the lock by rename and gates
# the same database at the same moment as the live holder — the exact collision
# the lock exists to prevent. symlink(2) is equally atomic and equally portable
# (macOS ships no flock(1)) and it carries a payload: the lock becomes visible
# and attributable in the same syscall, so the ownerless window does not exist.
#
# Nothing ever follows the link, so its target is a string and not a path. Test
# it with -L, never -e: -e follows, and this link is deliberately dangling.
# The run id comes LAST in the record, so `read` can absorb it whole: run ids
# are mostly ticket ids, but an adhoc slug may carry a space (tests/janitor's
# own "zombie odd" fixture does), and a middle field would have shifted the
# epoch into the name and left the id truncated.
harness_gate_lock_owner() {  # $1 = lock path -> the raw "<pid> <epoch> <run id>"
  readlink "$1" 2>/dev/null
}

# Who holds it, in words, or nothing when it is not held by anyone readable.
harness_gate_lock_holder() {  # $1 = lock path
  local pid ots rid
  read -r pid ots rid <<EOF
$(harness_gate_lock_owner "$1")
EOF
  [ -n "${pid:-}" ] || return 1
  printf '%s' "${rid:-pid $pid}"
}

# Is the pid in an owner record really a harness driver, or a recycled number?
# `kill -0` alone answers "some process has this pid", which on a machine that
# has wrapped its pid space is not the same question: a recycled pid makes every
# gate on that repo wait the full ceiling for a holder that died hours ago. The
# record carries the run id, so the argv can be checked the way run_alive does.
#
# THREE answers, and the third is what keeps this safe. "Alive but I do not
# recognise it" must never mean "steal": ps(1) can be absent, restricted or
# truncating, and a check that answers "recycled" whenever it cannot see the
# argv turns every wait into a steal and destroys the mutual exclusion this lock
# exists to provide — concurrently, on every waiter, which is strictly worse
# than the recycled-pid stall it was meant to fix. So an unrecognised live pid
# is merely SUSPECT: the caller keeps waiting, and only breaks the wait after
# HARNESS_GATE_LOCK_SUSPECT seconds, which is far below the full ceiling and far
# above any scheduling hiccup.
#   0 = the holder, definitely   1 = gone   2 = alive but unrecognised
HARNESS_GATE_LOCK_SUSPECT="${HARNESS_GATE_LOCK_SUSPECT:-60}"
harness_gate_lock_pid_live() {  # $1 = pid, $2 = run id (may be empty)
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "${2:-}" ] || return 0   # no run id recorded: kill -0 is all we have
  ps -o command= -p "$1" 2>/dev/null \
    | grep -q "\(run-task\|sync-pr\)\.sh $2\([[:space:]]\|\$\)" && return 0
  return 2
}

# 0 = held (ours now), 1 = gave up and the caller must gate unserialized.
# $3 is a function name called ONCE, with the holder's description, the first
# time we actually have to wait — that is what puts "waiting for gate lock" in
# the run's stage text instead of leaving a silent gap.
harness_gate_lock_acquire() {  # $1 = key, $2 = run id, $3 = on-wait fn (optional)
  local key="$1" rid="$2" onwait="${3:-}" lock waited=0 pid ots orid other told=0
  local live suspect=0 ownerless=0 record lastrecord=
  [ "${HARNESS_GATE_LOCK:-1}" = 0 ] && return 1
  lock=$(harness_gate_lock_path "$key")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || return 1
  while :; do
    # Clear a NON-symlink at the lock path before claiming. This is the upgrade
    # path and it is not hypothetical: the first version of this lock was a
    # directory, so any machine that ran it has `gate-<key>.lock` directories
    # left on disk. `ln -s target DIR` does not fail on an existing directory —
    # it creates the link INSIDE it and reports success — so every acquirer
    # would have "taken" the lock at once, silently, with no mutual exclusion at
    # all. Nobody owns a bare directory here, and only an old harness ever made
    # one, so clearing it is safe.
    if [ -e "$lock" ] && [ ! -L "$lock" ]; then
      if mv "$lock" "$lock.stale.$$" 2>/dev/null; then
        rm -rf "$lock.stale.$$" 2>/dev/null || true
      fi
    fi
    # One syscall: the lock exists and says who owns it, or it does not exist.
    if ln -s "$$ $(date +%s) $rid" "$lock" 2>/dev/null; then return 0; fi
    record=$(harness_gate_lock_owner "$lock")
    # The suspect clock is per HOLDER, not per wait. Without this reset it
    # accumulates across a whole queue: on a machine where ps(1) cannot identify
    # anyone — a container, a restricted host — every holder is unrecognised, so
    # the counter would run on through handoff after handoff and eventually rob
    # a holder that had only just taken the lock. That is the exact failure this
    # grace exists to prevent, arrived at from the other direction.
    if [ "$record" != "$lastrecord" ]; then suspect=0; lastrecord="$record"; fi
    pid=''; ots=''; orid=''
    read -r pid ots orid <<EOF
$record
EOF
    case "${pid:-}" in ''|*[!0-9]*) pid='' ;; esac
    # Ours already: a nested call, not a deadlock against ourselves.
    if [ -n "$pid" ] && [ "$pid" = "$$" ]; then return 0; fi
    live=2
    [ -n "$pid" ] && { harness_gate_lock_pid_live "$pid" "$orid"; live=$?; }
    if [ -n "$pid" ] && [ "$live" -eq 2 ] && [ "$suspect" -ge "$HARNESS_GATE_LOCK_SUSPECT" ]; then
      live=1   # unrecognised for long enough that a recycled pid is the better bet
    fi
    if [ -n "$pid" ] && [ "$live" -ne 1 ]; then
      [ "$live" -eq 2 ] && suspect=$((suspect + HARNESS_GATE_LOCK_POLL)) || suspect=0
      if [ "$told" = 0 ] && [ -n "$onwait" ]; then
        other=$(harness_gate_lock_holder "$lock" 2>/dev/null) || other=""
        "$onwait" "${other:-another run}"
        told=1
      fi
      # Never block a gate forever: past the ceiling, say so and let the caller
      # gate unserialized rather than park the run on a wedged holder.
      [ "$waited" -lt "$HARNESS_GATE_LOCK_WAIT" ] || return 1
      sleep "$HARNESS_GATE_LOCK_POLL"
      waited=$((waited + HARNESS_GATE_LOCK_POLL))
      continue
    fi
    if [ -z "$pid" ]; then
      # No readable owner. symlink(2) closed the gap between creating the lock
      # and naming its holder, but not the gap between our `ln -s` failing and
      # our `readlink`: in between, the holder can release and somebody else can
      # take it, and we read the empty moment. Stealing on that reads a live
      # lock as an abandoned one and lets two runs gate the same database at
      # once — the collision this lock exists to prevent, reintroduced one step
      # further along. So an unreadable lock is never proof of anything:
      if [ ! -L "$lock" ] && [ -e "$lock" ]; then
        : # not a symlink at all — a lock dir from before this was a link, or
          # junk at the path. Nobody owns that, and it would block every gate on
          # this repo forever, so it is the one unreadable state worth clearing.
      elif [ -L "$lock" ] && [ "$ownerless" -ge 2 ]; then
        : # a symlink whose target we still cannot parse after two polls
      else
        # Transient. Retry the claim rather than reach for someone else's lock.
        ownerless=$((ownerless + 1))
        [ "$waited" -lt "$HARNESS_GATE_LOCK_WAIT" ] || return 1
        sleep "$HARNESS_GATE_LOCK_POLL"
        waited=$((waited + HARNESS_GATE_LOCK_POLL))
        continue
      fi
    fi
    ownerless=0
    # A holder proven gone, or an unownable artefact. Steal by RENAME, not by
    # rm: rename(2) picks exactly one winner when several waiters spot the same
    # dead holder in the same instant, so only one of them re-creates the lock.
    if mv "$lock" "$lock.stale.$$" 2>/dev/null; then
      rm -rf "$lock.stale.$$" 2>/dev/null || true
      continue
    fi
    # Another waiter won the steal. Poll like every other path, so no lock state
    # can spin this loop without advancing the clock towards the ceiling.
    [ "$waited" -lt "$HARNESS_GATE_LOCK_WAIT" ] || return 1
    sleep "$HARNESS_GATE_LOCK_POLL"
    waited=$((waited + HARNESS_GATE_LOCK_POLL))
  done
}

# Only the owner releases. Called from the gate's own path AND from the driver's
# EXIT trap, so a run that dies holding the lock does not park it on the repo.
harness_gate_lock_release() {  # $1 = key
  local lock pid rest
  [ -n "${1:-}" ] || return 0
  lock=$(harness_gate_lock_path "$1")
  [ -L "$lock" ] || return 0    # -L, not -e: the link dangles on purpose
  pid=''; rest=''
  read -r pid rest <<EOF
$(harness_gate_lock_owner "$lock")
EOF
  [ "${pid:-}" = "$$" ] || return 0
  rm -f "$lock" 2>/dev/null || true
}
