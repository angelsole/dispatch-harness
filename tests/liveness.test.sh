#!/usr/bin/env bash
# The liveness contract and the gate lock's safety rule.
#
# Both shipped in PR #85 with no coverage, and the reason is worth recording:
# every fixture run dir in every other suite has neither driver.pid nor
# heartbeat, so run_alive answers "cannot tell" for all of them and the DEAD
# branch in status.sh, statusline.sh and janitor.sh never ran once.
#
# The rule the lock cases exist to defend: a lock is only ever taken from a
# holder PROVEN gone. `kill -0` failing is proof; an unreadable owner, an argv
# ps(1) will not show us, and an expired timer are not. Every "does not steal"
# case below is that rule, because the failure it prevents — two runs gating one
# database — is silent and expensive.
#
# Nothing real is dispatched: run_alive and the lock are pure functions of the
# filesystem, so fixtures are directories and the "drivers" are real processes
# wearing an argv that does or does not match a driver's.
#
# Usage: bash tests/liveness.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/liveness-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "FATAL: no fixture root" >&2; exit 1; }
VICTIMS=""
# shellcheck disable=SC2064,SC2154
trap 'for p in $VICTIMS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

export HARNESS_DIR="$ROOT/harness"
RUNS="$HARNESS_DIR/runs"
mkdir -p "$RUNS" || { echo "FATAL: cannot build the fixture tree" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

mkrun() {  # $1 = id, $2 = stage (or ""), $3 = heartbeat age secs | none, $4 = driver.pid | none
  local d="$RUNS/$1"
  rm -rf "$d"; mkdir -p "$d" || { echo "FATAL: cannot create $d" >&2; exit 1; }
  [ -n "${2:-}" ] && printf '%s %s\n' "$(date +%s)" "$2" > "$d/status"
  case "${3:-none}" in
    none) : ;;
    0)    touch "$d/heartbeat" ;;
    *)    touch "$d/heartbeat"
          touch -t "$(date -r "$(( $(date +%s) - $3 ))" +%Y%m%d%H%M.%S 2>/dev/null \
                      || date -d "@$(( $(date +%s) - $3 ))" +%Y%m%d%H%M.%S)" "$d/heartbeat" ;;
  esac
  [ "${4:-none}" != none ] && printf '%s\n' "$4" > "$d/driver.pid"
  printf '%s' "$d"
}

# Real processes, started outside any command substitution — a background job in
# a $( ) subshell does not outlive it, and every case below would then pass for
# the wrong reason, reading "dead" off a pid that really was dead.
FAKE_PID=""
fake_driver() {  # $1 = run id -> FAKE_PID, wearing a driver's argv
  bash -c "exec -a \"bash $HARNESS_DIR/run-task.sh $1 /repo br\" sleep 120" >/dev/null 2>&1 &
  FAKE_PID=$!; VICTIMS="$VICTIMS $FAKE_PID"; disown "$FAKE_PID" 2>/dev/null || true; sleep 0.2
}
fake_stranger() {  # -> FAKE_PID, alive but not a driver
  sleep 120 >/dev/null 2>&1 &
  FAKE_PID=$!; VICTIMS="$VICTIMS $FAKE_PID"; disown "$FAKE_PID" 2>/dev/null || true; sleep 0.2
}
live() {  # a fixture process that died makes its case a tautology — say so
  kill -0 "$1" 2>/dev/null && return 0
  bad "fixture: the $2 process died before its assertion could use it"; return 1
}
alive_code() { run_alive "$1"; printf '%s' "$?"; }

# ---------------------------------------------------------------------------
echo "== harness_mtime =="
# ---------------------------------------------------------------------------
# `stat -f` on GNU means --file-system: six lines to stdout, then exit 1. Probed
# in the wrong order it contaminated the fallback and the numeric guard threw
# the lot away, so the heartbeat was dead on Linux — where CI runs.
touch "$ROOT/probe"
MT=$(harness_mtime "$ROOT/probe")
case "$MT" in ''|*[!0-9]*) bad "mtime: a bare epoch (got [$MT])" ;; *) ok "mtime: a bare epoch" ;; esac
check "mtime: one line, not a filesystem report" "$(printf '%s' "$MT" | grep -c '')" "1"
check "mtime: close to now" "$(( $(date +%s) - MT < 5 ? 1 : 0 ))" "1"
check "mtime: a missing file reports nothing" "$(harness_mtime "$ROOT/nope" 2>/dev/null)" ""
# Resolved at load: inside harness_mtime it would be assigned in the caller's
# command substitution and lost with that subshell.
case "$_DISPATCH_STAT_FLAVOUR" in
  gnu|bsd) ok "mtime: the stat flavour is resolved once, at load" ;;
  *)       bad "mtime: flavour is [$_DISPATCH_STAT_FLAVOUR]" ;;
esac

# ---------------------------------------------------------------------------
echo "== harness_bre_escape: run ids are data, not patterns =="
# ---------------------------------------------------------------------------
# A run id containing `[` made grep exit 2, which every caller reads as "not
# this driver": a live holder looked unrecognised and a second driver was let in.
check "escape: a bracket is matched literally" \
  "$(printf 'x RUN[1 y\n' | grep -c "RUN$(harness_bre_escape '[1')")" "1"
check "escape: a dot matches only a dot" \
  "$(printf 'RUN-1\n' | grep -c "$(harness_bre_escape 'RUN.1')")" "0"
fake_driver 'RUN[1'; HOSTILE=$FAKE_PID
live "$HOSTILE" "hostile-id driver" && \
check "escape: a driver whose id is hostile is still recognised" \
  "$(harness_driver_pid_live "$HOSTILE" 'RUN[1'; printf '%s' "$?")" "0"

# ---------------------------------------------------------------------------
echo "== run_alive: three answers, and the third is the one that matters =="
# ---------------------------------------------------------------------------
check "legacy run dir (neither file) cannot tell — it is not dead" \
  "$(alive_code "$(mkrun LEGACY 'test gate #1' none none)")" "2"
check "a fresh heartbeat is alive" \
  "$(alive_code "$(mkrun FRESH 'test gate #1' 0 none)")" "0"
check "a cold heartbeat with no driver is dead" \
  "$(alive_code "$(mkrun COLD 'test gate #1' 9999 none)")" "1"

fake_driver LIVEPID; DPID=$FAKE_PID
live "$DPID" "fake driver" && \
check "a cold heartbeat with this run's live driver is alive" \
  "$(alive_code "$(mkrun LIVEPID 'test gate #1' 9999 "$DPID")")" "0"

fake_stranger; SPID=$FAKE_PID
live "$SPID" "stranger" && \
check "a cold heartbeat with a live but unrelated pid is dead" \
  "$(alive_code "$(mkrun RECYCLED 'test gate #1' 9999 "$SPID")")" "1"
check "a pid naming no process is dead" \
  "$(alive_code "$(mkrun GONE 'test gate #1' 9999 999998)")" "1"

# A paused run is not a dead one: harness_on_exit leaves the dir behind whenever
# a driver exits cleanly, which is what a run does when it asks a question.
# status.sh and statusline.sh each carried their own guard and janitor.sh none,
# so the reap replaced the wall's loudest alarm with a dim `done: reaped`.
for st in 'waiting — implementer needs your input (QUESTIONS.md)' \
          'deferred: capacity resets 1:30pm' \
          'sync failed: conflicts unresolved' \
          'done: ready'; do
  check "paused [${st%% *}] is never reported dead" \
    "$(alive_code "$(mkrun PAUSED "$st" 9999 none)")" "2"
done
check "a paused run with a stale pid file is still not dead" \
  "$(alive_code "$(mkrun PAUSED2 'waiting — implementer needs your input' 9999 999998)")" "2"
check "a working stage is judged on its signals, not its words" \
  "$(alive_code "$(mkrun WORDS 'review round 2 — waiting on codex' 9999 none)")" "1"

# ---------------------------------------------------------------------------
echo "== the lock is published and attributed by one syscall =="
# ---------------------------------------------------------------------------
export HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=4
LOCK=$(harness_gate_lock_path k)
harness_gate_lock_acquire k RUN-A >/dev/null 2>&1
check "lock: it is a symlink, so creation carries the owner" \
  "$([ -L "$LOCK" ] && echo link || echo other)" "link"
OWNER=$(harness_gate_lock_owner "$LOCK")
check "lock: field 1 is our pid"    "$(printf '%s' "$OWNER" | cut -d' ' -f1)" "$$"
check "lock: field 3 is the run id" "$(printf '%s' "$OWNER" | cut -d' ' -f3-)" "RUN-A"
check "lock: the holder reads back in words" "$(harness_gate_lock_holder "$LOCK")" "RUN-A"
# No separate owner write exists to race: the record is inline in the `ln -s`.
check "lock: nothing publishes the lock before its owner" \
  "$(grep -c 'ln -s "\$\$ \$(date +%s) \$rid" "\$lock"' "$SRC/lib/common.sh")" "1"
harness_gate_lock_release k

# Adhoc run ids can contain spaces (tests/janitor.test.sh dispatches "zombie odd"),
# so the id is the last field and `read` takes it whole.
harness_gate_lock_acquire k 'run with spaces' >/dev/null 2>&1
check "lock: a run id with spaces survives intact" \
  "$(harness_gate_lock_holder "$LOCK")" "run with spaces"
check "lock: re-entrant acquire returns held" \
  "$(harness_gate_lock_acquire k 'run with spaces' >/dev/null 2>&1; printf '%s' "$?")" "0"
# $$ is shared by subshells and recycled by the OS, so the pid alone would hand
# the lock to a stranger.
check "lock: the same pid under a DIFFERENT run id is not us" \
  "$(HARNESS_GATE_LOCK_WAIT=1 harness_gate_lock_acquire k SOMEONE-ELSE >/dev/null 2>&1; printf '%s' "$?")" "1"
harness_gate_lock_release k
check "lock: the owner released it" "$([ -L "$LOCK" ] && echo held || echo free)" "free"

ln -s "999998 $(date +%s) NOT-US" "$LOCK"
harness_gate_lock_release k
check "lock: a non-owner cannot release someone else's" \
  "$([ -L "$LOCK" ] && echo held || echo free)" "held"
rm -f "$LOCK"

# ---------------------------------------------------------------------------
echo "== mutual exclusion between separate drivers =="
# ---------------------------------------------------------------------------
# Separate processes: $$ is shared by every subshell of one script. Each holder
# drops a marker while inside and counts them — "how many of us are in here
# right now" cannot be faked by load the way an ordered IN/OUT log can.
LOG="$ROOT/critical.log"; : > "$LOG"
HOLDING="$ROOT/holding"; mkdir -p "$HOLDING"
HOLDERS=""
for i in 1 2 3 4 5 6 7 8; do
  bash -c '
    export HARNESS_DIR="'"$HARNESS_DIR"'" HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=90
    . "'"$SRC"'/lib/common.sh"
    if harness_gate_lock_acquire excl "R'"$i"'" >/dev/null 2>&1; then
      : > "'"$HOLDING"'/$$"
      sleep 1
      n=$(find "'"$HOLDING"'" -type f | grep -c "")
      own=$(harness_gate_lock_owner "$(harness_gate_lock_path excl)" | cut -d" " -f1)
      printf "%s %s %s\n" "$n" "$own" "$$" >> "'"$LOG"'"
      rm -f "'"$HOLDING"'/$$"
      harness_gate_lock_release excl
    fi' &
  HOLDERS="$HOLDERS $!"
done
# Only these eight: a bare `wait` also waits on the long-lived fixture processes.
for h in $HOLDERS; do wait "$h" 2>/dev/null || true; done
check "lock: all eight got a turn" "$(grep -c '' "$LOG")" "8"
check "lock: none saw another holder inside" "$(awk '$1 != 1 { n++ } END { print n+0 }' "$LOG")" "0"
check "lock: and each WAS the pid the lock named" "$(awk '$2 != $3 { n++ } END { print n+0 }' "$LOG")" "0"

# ---------------------------------------------------------------------------
echo "== the safety rule: only a holder PROVEN gone is taken from =="
# ---------------------------------------------------------------------------
rm -f "$LOCK"
ln -s "999998 $(date +%s) DEAD-RUN" "$LOCK"
harness_gate_lock_acquire k TAKER >/dev/null 2>&1
check "lock: a holder whose pid names no process is taken over" "$?" "0"
check "lock: and the taker owns the replacement, not just a return code" \
  "$(harness_gate_lock_owner "$LOCK" | cut -d' ' -f1)" "$$"
check "lock: under its own run id" \
  "$(harness_gate_lock_holder "$LOCK")" "TAKER"
harness_gate_lock_release k

# A live pid is NEVER taken from, however unrecognisable. ps(1) can be absent,
# restricted or truncating, and a check that resolved "cannot identify" to
# "gone" would rob every holder it failed to read — losing exclusion entirely,
# which is worse than the recycled-pid stall it was meant to avoid.
fake_stranger; UNKNOWN=$FAKE_PID
if live "$UNKNOWN" "unrecognised holder"; then
  ln -s "$UNKNOWN $(date +%s) UNKNOWN-RUN" "$LOCK"
  # Waited on past the ceiling, deliberately: the wait is bounded only for locks
  # nobody demonstrably holds. Asserted by running the acquire in the background
  # and confirming it neither returns nor touches the lock — a bounded return
  # here would mean the caller had been told it could gate.
  ( HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=2 \
      harness_gate_lock_acquire k THIEF >/dev/null 2>&1 ) & THIEF_PID=$!
  sleep 6
  if kill -0 "$THIEF_PID" 2>/dev/null; then
    ok "lock: an unrecognised LIVE holder is waited on past the ceiling, never robbed"
  else
    bad "lock: the acquire returned while a live holder still had the lock"
  fi
  kill -9 "$THIEF_PID" 2>/dev/null || true; wait "$THIEF_PID" 2>/dev/null || true
  check "lock: and the holder's record is untouched" \
    "$(harness_gate_lock_holder "$LOCK")" "UNKNOWN-RUN"
  # Once that holder is gone the same waiter takes it immediately — the wait was
  # on the process, not on a timer.
  kill -9 "$UNKNOWN" 2>/dev/null || true; sleep 0.3
  check "lock: and is taken the moment that holder dies" \
    "$(HARNESS_GATE_LOCK_WAIT=5 harness_gate_lock_acquire k TAKER2 >/dev/null 2>&1; printf '%s' "$?")" "0"
  harness_gate_lock_release k
  rm -f "$LOCK"
fi

# An unreadable owner is the moment between one holder releasing and the next
# claiming. A waiter that stole on it removed a live lock; forcing the empty
# read makes that deterministic rather than a one-in-three race.
ln -s "$$ $(date +%s) LIVE-HOLDER" "$LOCK"
_real_reader=$(declare -f harness_gate_lock_owner)
harness_gate_lock_owner() { printf ''; }
HARNESS_GATE_LOCK_WAIT=3 harness_gate_lock_acquire k THIEF >/dev/null 2>&1
check "lock: an unreadable owner never hands the lock over" "$?" "1"
eval "$_real_reader"
check "lock: the live holder still has it" \
  "$(readlink "$LOCK" | cut -d' ' -f3-)" "LIVE-HOLDER"
rm -f "$LOCK"

# ---------------------------------------------------------------------------
echo "== the rolling upgrade from PR #85's directory lock =="
# ---------------------------------------------------------------------------
# `ln -s target DIR` does not fail on an existing directory — it links INSIDE it
# and reports success — so a leftover directory lock would let every run "take"
# the lock at once. But an old driver can still be inside that gate while the
# harness is upgraded, so the directory goes only when its owner is gone.
mkdir -p "$LOCK"
printf '%s %s %s\n' 999998 OLD-RUN "$(date +%s)" > "$LOCK/owner"
harness_gate_lock_acquire k TAKER >/dev/null 2>&1
check "upgrade: an abandoned directory lock is cleared" "$?" "0"
check "upgrade: and replaced by a proper attributed link" \
  "$([ -L "$LOCK" ] && harness_gate_lock_holder "$LOCK")" "TAKER"
harness_gate_lock_release k; rm -rf "$LOCK"

fake_stranger; OLDHOLDER=$FAKE_PID
if live "$OLDHOLDER" "legacy holder"; then
  mkdir -p "$LOCK"
  printf '%s %s %s\n' "$OLDHOLDER" OLD-RUN "$(date +%s)" > "$LOCK/owner"
  ( HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=2 \
      harness_gate_lock_acquire k NEWRUN >/dev/null 2>&1 ) & NEW_PID=$!
  sleep 6
  if kill -0 "$NEW_PID" 2>/dev/null; then
    ok "upgrade: a directory lock a LIVE old driver owns is waited on, not cleared"
  else
    bad "upgrade: the acquire returned while an old driver still held the directory"
  fi
  kill -9 "$NEW_PID" 2>/dev/null || true; wait "$NEW_PID" 2>/dev/null || true
  check "upgrade: and it is left exactly as it was" \
    "$([ -d "$LOCK" ] && cut -d' ' -f1 < "$LOCK/owner")" "$OLDHOLDER"
  rm -rf "$LOCK"
fi

# ---------------------------------------------------------------------------
echo "== the driver's exit path: prompt, complete, and leaves nothing =="
# ---------------------------------------------------------------------------
# The fixture uses the SHIPPED harness_start_heartbeat / harness_stop_heartbeat.
# A copy here passed against a reintroduced blocking `wait` — which is exactly
# what it did before this suite was rewritten.
mkdir -p "$ROOT/exitrun"
cat > "$ROOT/exiting-driver.sh" <<EOF
export HARNESS_DIR="$HARNESS_DIR"
. "$SRC/lib/common.sh"
HARNESS_HEARTBEAT_SECS=30
harness_start_heartbeat "$ROOT/exitrun"
printf '%s\\n' "\$HEARTBEAT_PID" > "$ROOT/hb.pid"
pgrep -P "\$HEARTBEAT_PID" > "$ROOT/hb.child" 2>/dev/null || true
GATE_LOCK_KEY=exitlock
harness_gate_lock_acquire "\$GATE_LOCK_KEY" EXIT-RUN >/dev/null 2>&1
on_exit() {
  local rc=\$?
  harness_gate_lock_release "\${GATE_LOCK_KEY:-}" 2>/dev/null || true
  harness_stop_heartbeat
  return "\$rc"
}
trap on_exit EXIT
exit 0
EOF
START=$(date +%s)
bash "$ROOT/exiting-driver.sh"
ELAPSED=$(( $(date +%s) - START ))
check "exit: the driver does not wait out a heartbeat interval" \
  "$([ "$ELAPSED" -lt 10 ] && echo prompt || echo "blocked ${ELAPSED}s")" "prompt"
check "exit: the gate lock is not left parked on the repo" \
  "$([ -L "$(harness_gate_lock_path exitlock)" ] && echo parked || echo released)" "released"
check "exit: the ticker is gone, not merely signalled" \
  "$(kill -0 "$(cat "$ROOT/hb.pid" 2>/dev/null || echo 999998)" 2>/dev/null && echo alive || echo gone)" "gone"
# Not blocking must not mean leaking: the ticker's `sleep` is its own process,
# and killing only the ticker would orphan it for a full interval.
HBC=$(cat "$ROOT/hb.child" 2>/dev/null || echo "")
if [ -n "$HBC" ]; then
  check "exit: and the sleep it was parked in went with it" \
    "$(kill -0 "$HBC" 2>/dev/null && echo alive || echo gone)" "gone"
else
  ok "exit: (no separate sleep child to reap on this platform)"
fi

# Ordering, as a property of the shipped file: everything that must survive a
# second signal precedes the housekeeping.
V_LINE=$(grep -n 'harness_record_death "" "\$rc"' "$SRC/run-task.sh" | head -1 | cut -d: -f1)
L_LINE=$(grep -n 'harness_gate_lock_release "\${GATE_LOCK_KEY:-}"' "$SRC/run-task.sh" | head -1 | cut -d: -f1)
S_LINE=$(awk 'f && /harness_stop_heartbeat/ { print NR; exit } /^harness_on_exit\(\)/ { f=1 }' "$SRC/run-task.sh")
check "exit: the verdict is written before the ticker is touched" \
  "$([ "$V_LINE" -lt "$S_LINE" ] && echo yes || echo no)" "yes"
check "exit: and the gate lock released before it" \
  "$([ "$L_LINE" -lt "$S_LINE" ] && echo yes || echo no)" "yes"

# The liveness artifacts must not outlive the trap that removes them: created
# before it, any early exit left a pid file and a live ticker with no verdict.
for f in run-task.sh sync-pr.sh; do
  T=$(grep -n '^trap .*_on_exit EXIT' "$SRC/$f" | head -1 | cut -d: -f1)
  A=$(grep -n 'harness_start_heartbeat "\$RUN_DIR"' "$SRC/$f" | head -1 | cut -d: -f1)
  check "exit: $f starts the ticker only after its traps are installed" \
    "$([ -n "$T" ] && [ -n "$A" ] && [ "$A" -gt "$T" ] && echo yes || echo no)" "yes"
done

# ---------------------------------------------------------------------------
echo "== a death records the status the driver actually died on =="
# ---------------------------------------------------------------------------
cat > "$ROOT/dying-driver.sh" <<'EOF'
record() { printf 'exited %s\n' "${2:-0}" > "$DIED"; }
on_exit() {
  local rc=$?
  if [ -n "${SOMETHING:-x}" ]; then :; fi   # a command of its own, as in the real handler
  record "" "$rc"
  return "$rc"
}
trap on_exit EXIT
exit 7
EOF
DIED="$ROOT/died" bash "$ROOT/dying-driver.sh"
check "death: the recorded status is the driver's, not the handler's" \
  "$(cat "$ROOT/died")" "exited 7"
check "death: run-task.sh passes it in" \
  "$(grep -c 'harness_record_death "" "\$rc"' "$SRC/run-task.sh")" "1"
check "death: and so does sync-pr.sh" \
  "$(grep -c 'sync_record_death "" "\$rc"' "$SRC/sync-pr.sh")" "1"

# ---------------------------------------------------------------------------
echo "== both drivers refuse to detach out from under a fixture =="
# ---------------------------------------------------------------------------
# Executed, not grepped: run-task.sh had this guard and sync-pr.sh did not, so
# three suites that run sync-pr.sh in the foreground would, run by hand, have
# asserted against the instant 0 of the launcher half.
FIX="$ROOT/fixture"; mkdir -p "$FIX/runs/DEMO-1"
cp -R "$SRC/lib" "$FIX/lib"; cp "$SRC/sync-pr.sh" "$SRC/run-task.sh" "$FIX/"
echo '{"worktree":"/nonexistent","branch":"b"}' > "$FIX/runs/DEMO-1/result.json"
printf 'brief\n' > "$FIX/runs/DEMO-1/brief.md"
printf 'REPOS=""\n' > "$FIX/repos.conf.sh"
# A real repo, because run-task.sh checks for one before it reaches the detach —
# with a bogus path it exits first and the case proves nothing.
FIXREPO="$ROOT/fixrepo"; mkdir -p "$FIXREPO"
git -C "$FIXREPO" init -q 2>/dev/null || { echo "FATAL: git init failed" >&2; exit 1; }
for f in run-task.sh sync-pr.sh; do
  args="DEMO-1"; [ "$f" = run-task.sh ] && args="DEMO-1 $FIXREPO b"
  # shellcheck disable=SC2086
  out=$(env -u HARNESS_DETACH HARNESS_DIR="$FIX" bash "$FIX/$f" $args 2>&1)
  case "$out" in
    *"detached, this shell no longer owns it"*) bad "detach: $f detached under a fixture HARNESS_DIR" ;;
    *) ok "detach: $f stays in the foreground under a fixture HARNESS_DIR" ;;
  esac
  case "$out" in
    *"came from the environment"*) ok "detach: $f says which variable suppressed it" ;;
    *) bad "detach: $f suppressed the detach silently" ;;
  esac
done

printf '\nliveness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
