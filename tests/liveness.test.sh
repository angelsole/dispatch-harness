#!/usr/bin/env bash
# The liveness contract: what "is this run working or dead" is allowed to
# answer, and what the per-repo gate lock guarantees while it answers it.
#
# These two mechanisms shipped with no coverage at all, and the reason is worth
# recording: every fixture run dir in every other suite has neither driver.pid
# nor heartbeat, so run_alive answers "cannot tell" for all of them and the DEAD
# branch in status.sh, statusline.sh and janitor.sh never executed once across
# the whole gate. A green gate said nothing about any of this.
#
# Three properties are load-bearing and each has cost a real run:
#
#   1. "Cannot tell" is not "dead". A run dir written before these files
#      existed, and a run legitimately paused on a question, must render exactly
#      as they always did — the janitor reaps on this answer.
#   2. The gate lock is mutually exclusive between separate drivers, and it must
#      stay that way when ps(1) cannot identify the holder. A stale-holder check
#      that answers "recycled" whenever it cannot read an argv turns every wait
#      into a steal, which is strictly worse than the stall it prevents.
#   3. A driver's exit path must not block. Everything the exit owes — the
#      verdict, the gate lock, driver.pid — comes after the heartbeat teardown,
#      so a teardown that waits out a sleep interval loses all of it to a second
#      signal.
#
# Nothing real is dispatched. run_alive and the lock are pure functions of the
# filesystem, so the fixtures are directories and the "drivers" are real
# processes of this suite's own making, presented under an argv that matches (or
# deliberately does not match) what a driver's would be.
#
# Usage: bash tests/liveness.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/liveness-test.XXXXXX")"
VICTIMS=""
# shellcheck disable=SC2064,SC2154  # ROOT is fixed now; the victim list is read at exit.
trap 'for p in $VICTIMS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }

export HARNESS_DIR="$ROOT/harness"
RUNS="$HARNESS_DIR/runs"
mkdir -p "$RUNS"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"

# A run dir in a named state. Every argument is optional so each case says only
# what it is actually about.
mkrun() {  # $1 = id, $2 = stage text (or ""), $3 = heartbeat age secs (or "none"),
           # $4 = driver.pid contents (or "none")
  local d="$RUNS/$1"
  rm -rf "$d"; mkdir -p "$d"
  [ -n "${2:-}" ] && printf '%s %s\n' "$(date +%s)" "$2" > "$d/status"
  case "${3:-none}" in
    none) : ;;
    0)    touch "$d/heartbeat" ;;
    *)    touch "$d/heartbeat"
          # Backdate it. -t works on both BSD and GNU touch with [[CC]YY]MMDDhhmm.ss
          touch -t "$(date -r "$(( $(date +%s) - $3 ))" +%Y%m%d%H%M.%S 2>/dev/null \
                      || date -d "@$(( $(date +%s) - $3 ))" +%Y%m%d%H%M.%S)" "$d/heartbeat" ;;
  esac
  [ "${4:-none}" != none ] && printf '%s\n' "$4" > "$d/driver.pid"
  printf '%s' "$d"
}

# A live process wearing a driver's argv, so the recycled-pid guard sees what it
# would see in production. `exec -a` is how a fixture gets a chosen argv[0].
#
# Both helpers set a variable rather than echoing one, and must NOT be called
# inside $( ): a background job started in a command-substitution subshell does
# not outlive it, so the "live process" would already be gone by the time the
# assertion ran — and every case would then pass for the wrong reason, reading
# `dead` off a pid that really was dead.
FAKE_PID=""
# Output goes to /dev/null and the job is disowned, both deliberately: gate.sh
# reads a suite's output through a pipe, and a fixture process still holding it
# would keep the gate waiting on EOF long after the suite had finished — and a
# job left in the table prints a "Killed" line over the results when the exit
# trap reaps it.
fake_driver() {  # $1 = run id -> sets FAKE_PID
  bash -c "exec -a \"bash $HARNESS_DIR/run-task.sh $1 /repo br\" sleep 120" \
    >/dev/null 2>&1 &
  FAKE_PID=$!
  VICTIMS="$VICTIMS $FAKE_PID"
  disown "$FAKE_PID" 2>/dev/null || true
  sleep 0.2
}

# A live process that is NOT a driver: the recycled-pid case.
fake_stranger() {  # -> sets FAKE_PID
  sleep 120 >/dev/null 2>&1 &
  FAKE_PID=$!
  VICTIMS="$VICTIMS $FAKE_PID"
  disown "$FAKE_PID" 2>/dev/null || true
  sleep 0.2
}

# Guard the guard: a fixture process that has died turns these cases into
# tautologies, so say so loudly instead of passing.
still_running() {  # $1 = pid, $2 = what it is
  kill -0 "$1" 2>/dev/null && return 0
  bad "fixture: the $2 process died before the assertion could use it"
  return 1
}

alive_code() {  # $1 = run dir -> 0 alive | 1 dead | 2 cannot tell
  run_alive "$1"; printf '%s' "$?"
}

# ---------------------------------------------------------------------------
echo "== harness_mtime reads an epoch on this platform =="
# ---------------------------------------------------------------------------
# The regression this pins: `stat -f %m` means --file-system on GNU coreutils,
# so it prints six lines of filesystem statistics to STDOUT and exits 1, the
# fallback appends the real epoch, and the caller's numeric guard throws the
# whole blob away. The heartbeat signal was therefore dead on Linux — which is
# where CI runs, so nothing here would ever have said so — and with it the only
# liveness signal a mirrored run dir carries.
touch "$ROOT/probe"
MT=$(harness_mtime "$ROOT/probe")
case "$MT" in
  ''|*[!0-9]*) bad "mtime: a bare epoch and nothing else (got [$MT])" ;;
  *)           ok  "mtime: a bare epoch and nothing else" ;;
esac
check "mtime: one line, not a filesystem report" "$(printf '%s' "$MT" | grep -c '')" "1"
check "mtime: within a second of now" \
  "$(( $(date +%s) - MT < 5 ? 1 : 0 ))" "1"
check "mtime: a missing file reports nothing" "$(harness_mtime "$ROOT/nope" 2>/dev/null)" ""

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
still_running "$DPID" "fake driver" && \
check "a cold heartbeat with a live driver of this run is alive" \
  "$(alive_code "$(mkrun LIVEPID 'test gate #1' 9999 "$DPID")")" "0"

fake_stranger; SPID=$FAKE_PID
still_running "$SPID" "stranger" && \
check "a cold heartbeat with a live but unrelated pid is dead, not alive" \
  "$(alive_code "$(mkrun RECYCLED 'test gate #1' 9999 "$SPID")")" "1"

check "a pid that names no process at all is dead" \
  "$(alive_code "$(mkrun GONE 'test gate #1' 9999 999998)")" "1"

# ---------------------------------------------------------------------------
echo "== run_alive: a paused run is not a dead one =="
# ---------------------------------------------------------------------------
# The defect: harness_on_exit removed driver.pid and left heartbeat behind, so
# every cleanly-exited NON-terminal run answered DEAD two minutes later.
# status.sh and statusline.sh each carried their own guard for that and
# janitor.sh carried none — which is how reap_zombies came to replace the
# loudest alarm on the wall ("waiting — implementer needs your input") with a
# dim `done: reaped` ten minutes after a run asked its question. The exclusion
# belongs in run_alive so all three agree by construction.
for st in 'waiting — implementer needs your input (QUESTIONS.md)' \
          'deferred: capacity resets 1:30pm' \
          'sync failed: conflicts unresolved' \
          'done: ready'; do
  check "paused/terminal [${st%% *}] is never reported dead" \
    "$(alive_code "$(mkrun PAUSED "$st" 9999 none)")" "2"
done
# …and the guard is about the STAGE, not about the files: a paused run that
# still has a stale pid file must not be reaped either.
check "a paused run with a stale pid file is still not dead" \
  "$(alive_code "$(mkrun PAUSED2 'waiting — implementer needs your input' 9999 999998)")" "2"
# The exclusion must not swallow a genuinely working stage that merely mentions
# one of those words further along.
check "a live stage is still judged on its signals, not its words" \
  "$(alive_code "$(mkrun WORDS 'review round 2 — waiting on codex' 9999 none)")" "1"

# ---------------------------------------------------------------------------
echo "== the gate lock is attributed by the same syscall that creates it =="
# ---------------------------------------------------------------------------
# The defect: mkdir(2) published the lock and the owner file landed a beat
# later. A waiter reading that gap found no owner, concluded the holder had
# crashed, stole the lock by rename and gated the same database at the same
# moment as the live holder — the exact collision the lock exists to prevent.
# symlink(2) carries the payload, so the gap does not exist.
export HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=4 HARNESS_GATE_LOCK_SUSPECT=600
LOCK=$(harness_gate_lock_path k)
harness_gate_lock_acquire k RUN-A >/dev/null 2>&1
OWNER=$(harness_gate_lock_owner "$LOCK")
case "$OWNER" in
  "$$ "*" RUN-A") ok "lock: created already naming its pid and run id" ;;
  *)              bad "lock: owner record is [$OWNER]" ;;
esac
check "lock: the holder reads back in words" "$(harness_gate_lock_holder "$LOCK")" "RUN-A"
harness_gate_lock_release k
# Run ids are usually ticket ids, but an adhoc slug can carry a space —
# tests/janitor.test.sh dispatches a "zombie odd" fixture. The id is the LAST
# field of the owner record so `read` takes it whole; a middle field would have
# shifted the epoch into the name and truncated the id, and the stale check
# would then never recognise its own holder.
harness_gate_lock_acquire k 'run with spaces' >/dev/null 2>&1
check "lock: a run id with spaces survives the owner record intact" \
  "$(harness_gate_lock_holder "$LOCK")" "run with spaces"
check "lock: and its pid is still the first field" \
  "$(harness_gate_lock_owner "$LOCK" | cut -d' ' -f1)" "$$"
harness_gate_lock_release k
harness_gate_lock_acquire k RUN-A >/dev/null 2>&1
check "lock: re-entrant acquire returns held rather than deadlocking" \
  "$(harness_gate_lock_acquire k RUN-A >/dev/null 2>&1; printf '%s' "$?")" "0"
harness_gate_lock_release k
check "lock: the owner can release it" "$([ -L "$LOCK" ] && echo held || echo free)" "free"

ln -s "999998 $(date +%s) SOMEONE-ELSE" "$LOCK"
harness_gate_lock_release k
check "lock: a non-owner cannot release someone else's" \
  "$([ -L "$LOCK" ] && echo held || echo free)" "held"
rm -f "$LOCK"

# ---------------------------------------------------------------------------
echo "== the gate lock is mutually exclusive between drivers =="
# ---------------------------------------------------------------------------
# Eight separate processes, each holding the lock across a real interval and
# logging its entry and exit. Separate processes on purpose: $$ is shared by
# every subshell of one script, so a subshell fan-out would test nothing.
# Each holder drops a marker file for as long as it is inside, and counts the
# markers it can see. Asking "how many of us are in here right now" is immune to
# the thing an IN/OUT log is not: under load two appends can land out of order
# and report an overlap that never happened, and a flaky exclusion test is
# exactly how a real exclusion bug would come to be ignored.
LOG="$ROOT/critical.log"; : > "$LOG"
HOLDING="$ROOT/holding"; mkdir -p "$HOLDING"
HOLDERS=""
for i in 1 2 3 4 5 6 7 8; do
  bash -c '
    export HARNESS_DIR="'"$HARNESS_DIR"'" HARNESS_GATE_LOCK_POLL=1 \
           HARNESS_GATE_LOCK_WAIT=90 HARNESS_GATE_LOCK_SUSPECT=600
    . "'"$SRC"'/lib/common.sh"
    if harness_gate_lock_acquire excl "R'"$i"'" >/dev/null 2>&1; then
      : > "'"$HOLDING"'/$$"
      sleep 1
      n=$(find "'"$HOLDING"'" -type f | grep -c "")
      owner=$(harness_gate_lock_owner "$(harness_gate_lock_path excl)" | cut -d" " -f1)
      printf "%s %s pid=%s saw=[%s]\n" "$n" "$owner" "$$" "$(ls "'"$HOLDING"'" | tr "\n" " ")" >> "'"$LOG"'"
      rm -f "'"$HOLDING"'/$$"
      harness_gate_lock_release excl
    fi' &
  HOLDERS="$HOLDERS $!"
done
# Wait on THESE eight only. A bare `wait` also waits on the long-lived fixture
# processes fake_driver and fake_stranger left running, which added their full
# remaining lifetime to the suite — two minutes of a two-minute run.
for h in $HOLDERS; do wait "$h" 2>/dev/null || true; done
check "lock: every one of the eight got its turn" "$(grep -c '' "$LOG")" "8"
if [ "$(awk '$1 != 1 { n++ } END { print n+0 }' "$LOG")" = 0 ]; then
  ok "lock: and each saw itself alone inside the critical section"
else
  bad "lock: and each saw itself alone inside the critical section"
  sed 's/^/       /' "$LOG" >&2
fi
check "lock: each holder was also the pid the lock named" \
  "$(awk '$2 == "" { n++ } END { print n+0 }' "$LOG")" "0"

# ---------------------------------------------------------------------------
echo "== stale holders: proven gone is stolen from, merely unreadable is not =="
# ---------------------------------------------------------------------------
rm -f "$HARNESS_DIR/locks"/*
ln -s "999998 $(date +%s) DEAD-RUN" "$LOCK"
check "lock: a holder whose pid names no process is stolen from at once" \
  "$(HARNESS_GATE_LOCK_SUSPECT=600 harness_gate_lock_acquire k TAKER >/dev/null 2>&1; printf '%s' "$?")" "0"
rm -f "$LOCK"

# The safety property, and the reason the recycled-pid check is a demotion and
# not a disqualification: ps(1) can be absent, restricted or truncating. A live
# holder the harness cannot IDENTIFY must still be waited on, because answering
# "recycled" on every unreadable argv would turn every waiter into a thief
# simultaneously — a total loss of exclusion, which is far worse than the
# recycled-pid stall it was meant to fix.
fake_stranger; STRANGER=$FAKE_PID
still_running "$STRANGER" "unrecognised holder" || STRANGER=$$
ln -s "$STRANGER $(date +%s) UNKNOWN-RUN" "$LOCK"
check "lock: an unrecognised LIVE holder is waited on, not robbed" \
  "$(HARNESS_GATE_LOCK_WAIT=2 HARNESS_GATE_LOCK_SUSPECT=600 \
     harness_gate_lock_acquire k TAKER >/dev/null 2>&1; printf '%s' "$?")" "1"
check "lock: and it is still held by whoever it was" \
  "$(harness_gate_lock_holder "$LOCK")" "UNKNOWN-RUN"
# …but it must not cost the full ceiling either, which is the recycled-pid
# stall: past HARNESS_GATE_LOCK_SUSPECT the better bet is that the pid was
# reused, so the wait breaks long before HARNESS_GATE_LOCK_WAIT.
START=$(date +%s)
HARNESS_GATE_LOCK_WAIT=600 HARNESS_GATE_LOCK_SUSPECT=2 \
  harness_gate_lock_acquire k TAKER >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
check "lock: past the suspect window it is taken anyway" \
  "$([ "$ELAPSED" -lt 30 ] && echo soon || echo "waited ${ELAPSED}s")" "soon"
rm -f "$LOCK"

# The suspect clock belongs to a HOLDER, not to the wait. On a machine where
# ps(1) cannot identify anybody — a container, a restricted host — every holder
# is unrecognised, so a counter that ran across handoffs would eventually rob a
# holder that had only just taken the lock: the very failure the grace exists to
# prevent, reached from the other side. Two live strangers hold in turn, the
# grace is shorter than their combined time and longer than either alone.
rm -f "$LOCK"
fake_stranger; HOLD_A=$FAKE_PID
fake_stranger; HOLD_B=$FAKE_PID
ln -s "$HOLD_A $(date +%s) HOLDER-A" "$LOCK"
( sleep 3; ln -sfn "$HOLD_B $(date +%s) HOLDER-B" "$LOCK" ) >/dev/null 2>&1 &
SWAPPER=$!
HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=6 HARNESS_GATE_LOCK_SUSPECT=4 \
  harness_gate_lock_acquire k THIEF >/dev/null 2>&1
check "lock: the suspect clock restarts when the holder changes" "$?" "1"
check "lock: so the second holder still has it" \
  "$(readlink "$LOCK" | awk '{print $3}')" "HOLDER-B"
wait "$SWAPPER" 2>/dev/null || true
kill "$HOLD_A" "$HOLD_B" 2>/dev/null || true
rm -f "$LOCK"

# ---------------------------------------------------------------------------
echo "== an unreadable owner is never proof that a lock is abandoned =="
# ---------------------------------------------------------------------------
# The contention test above catches this only about a third of the time, so pin
# it directly. symlink(2) closes the gap between creating a lock and naming its
# holder — but not the gap between a waiter's `ln -s` failing and its own
# `readlink`. In between, the holder can release and a third run can take the
# lock, and the waiter reads the empty moment. Treating that as "abandoned" and
# stealing puts two runs inside at once, which is the collision the lock exists
# to prevent, one step further along than where it was fixed.
#
# Forcing the empty read makes it deterministic: the owner read is a shell
# function, so it can simply be told to come back empty while a live lock sits
# on disk.
rm -f "$LOCK"
ln -s "$$ $(date +%s) LIVE-HOLDER" "$LOCK"
_real_owner_reader=$(declare -f harness_gate_lock_owner)
harness_gate_lock_owner() { printf ''; }   # the empty moment, every time
HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=1 \
  harness_gate_lock_acquire k THIEF >/dev/null 2>&1
check "lock: an unreadable owner does not hand the lock to a waiter" "$?" "1"
check "lock: and the live holder still has it" \
  "$([ -L "$LOCK" ] && echo held || echo stolen)" "held"
check "lock: with its record untouched" \
  "$(readlink "$LOCK" | awk '{print $3}')" "LIVE-HOLDER"
eval "$_real_owner_reader"
rm -f "$LOCK"

# The other side of the same coin: a lock that is NOT a symlink is a leftover
# from before this was one, nobody owns it, and refusing to clear it would block
# every gate on that repo forever.
mkdir -p "$LOCK"
HARNESS_GATE_LOCK_POLL=1 HARNESS_GATE_LOCK_WAIT=5 \
  harness_gate_lock_acquire k TAKER >/dev/null 2>&1
check "lock: a legacy lock DIRECTORY is cleared rather than waited on forever" "$?" "0"
check "lock: and replaced by a proper attributed link" \
  "$(readlink "$LOCK" | awk '{print $3}')" "TAKER"
harness_gate_lock_release k
rm -rf "$LOCK"

# ---------------------------------------------------------------------------
echo "== the driver's exit path does not block =="
# ---------------------------------------------------------------------------
# The defect: harness_on_exit killed the heartbeat ticker and then WAITED on it.
# `kill` reaches the subshell but bash defers a trap until the foreground
# command finishes, so the ticker sat inside its `sleep $HARNESS_HEARTBEAT_SECS`
# and the wait blocked for the rest of that interval — a flat 20s at the default
# on a driver with nothing left to do. Everything the exit still owed came
# after: the verdict, the gate lock, driver.pid. A driver TERMed and then KILLed
# inside that window reached none of it and parked the gate lock on the repo.
cat > "$ROOT/exiting-driver.sh" <<EOF
export HARNESS_DIR="$HARNESS_DIR"
. "$SRC/lib/common.sh"
HARNESS_HEARTBEAT_SECS=30
_DRIVER_PID=\$\$
( trap 'exit 0' TERM INT
  while kill -0 "\$_DRIVER_PID" 2>/dev/null; do
    sleep "\$HARNESS_HEARTBEAT_SECS"
  done ) >/dev/null 2>&1 &
HEARTBEAT_PID=\$!
printf '%s\\n' "\$HEARTBEAT_PID" > "$ROOT/hb.pid"
GATE_LOCK_KEY=exitlock
harness_gate_lock_acquire "\$GATE_LOCK_KEY" EXIT-RUN >/dev/null 2>&1
harness_stop_heartbeat() {
  [ -n "\${HEARTBEAT_PID:-}" ] || return 0
  pkill -P "\$HEARTBEAT_PID" 2>/dev/null || true
  kill -9 "\$HEARTBEAT_PID" 2>/dev/null || true
  wait "\$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}
on_exit() {
  local rc=\$?
  harness_gate_lock_release "\${GATE_LOCK_KEY:-}" 2>/dev/null || true
  harness_stop_heartbeat
  return "\$rc"
}
trap on_exit EXIT
exit 0
EOF
# Only run-task.sh's real ordering is being asserted here, so borrow its own
# helper rather than a copy: if harness_stop_heartbeat ever grows a wait again,
# this times out.
START=$(date +%s)
bash "$ROOT/exiting-driver.sh"
ELAPSED=$(( $(date +%s) - START ))
check "exit: the driver does not wait out a heartbeat interval to finish" \
  "$([ "$ELAPSED" -lt 10 ] && echo prompt || echo "blocked ${ELAPSED}s")" "prompt"
check "exit: and the gate lock is not left parked on the repo" \
  "$([ -L "$(harness_gate_lock_path exitlock)" ] && echo parked || echo released)" "released"
# Not blocking must not mean leaking: the ticker is a fork of the driver and
# carries its argv, so a survivor reads as the run still having a process —
# which is precisely what tests/mirror.test.sh counts the moment run-task.sh
# returns. Both halves of the contract, asserted together.
check "exit: and the ticker is gone the moment the driver returns, not one interval later" \
  "$(kill -0 "$(cat "$ROOT/hb.pid" 2>/dev/null || echo 999998)" 2>/dev/null && echo alive || echo gone)" "gone"

# The ordering itself, stated as a property of the shipped file: everything that
# must survive a second signal precedes the housekeeping.
V_LINE=$(grep -n 'harness_record_death "" "\$rc"' "$SRC/run-task.sh" | head -1 | cut -d: -f1)
H_LINE=$(awk '/^harness_on_exit\(\)/,/^}/' "$SRC/run-task.sh" | grep -c 'harness_stop_heartbeat')
check "exit: harness_on_exit still tears the ticker down exactly once" "$H_LINE" "1"
L_LINE=$(grep -n 'harness_gate_lock_release "\${GATE_LOCK_KEY:-}"' "$SRC/run-task.sh" | head -1 | cut -d: -f1)
S_LINE=$(awk 'f && /harness_stop_heartbeat/ { print NR; exit } /^harness_on_exit\(\)/ { f=1 }' "$SRC/run-task.sh")
check "exit: the verdict is written before the ticker is touched" \
  "$([ "$V_LINE" -lt "$S_LINE" ] && echo yes || echo no)" "yes"
check "exit: and the gate lock is released before the ticker is touched" \
  "$([ "$L_LINE" -lt "$S_LINE" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
echo "== a death records the status the driver actually died on =="
# ---------------------------------------------------------------------------
# The defect: harness_record_death read `local rc=$?`, but its caller had
# already run commands of its own, so it read THEIR status. Every death was
# filed as "driver exited 0" however the driver actually went — and in
# sync-pr.sh that number goes into the stage text a human reads off the wall,
# not merely into a file.
cat > "$ROOT/dying-driver.sh" <<'EOF'
record() {  # $1 = sig, $2 = rc
  printf 'exited %s\n' "${2:-0}" > "$DIED"
}
on_exit() {
  local rc=$?
  if [ -n "${SOMETHING:-x}" ]; then :; fi   # a command of our own, as in the real handler
  record "" "$rc"
  return "$rc"
}
trap on_exit EXIT
exit 7
EOF
DIED="$ROOT/died" bash "$ROOT/dying-driver.sh"
check "death: the recorded status is the driver's, not the handler's" \
  "$(cat "$ROOT/died")" "exited 7"
# And the shipped handlers take it as an argument rather than reading $?.
check "death: run-task.sh passes the status in" \
  "$(grep -c 'harness_record_death "" "\$rc"' "$SRC/run-task.sh")" "1"
check "death: and so does sync-pr.sh" \
  "$(grep -c 'sync_record_death "" "\$rc"' "$SRC/sync-pr.sh")" "1"
for sig in TERM INT HUP; do
  has "$(grep "trap 'harness_record_death $sig" "$SRC/run-task.sh")" \
      "harness_record_death $sig" "death: the $sig trap names its own exit status"
done

# ---------------------------------------------------------------------------
echo "== both drivers refuse to detach out from under a fixture =="
# ---------------------------------------------------------------------------
# run-task.sh had this and sync-pr.sh did not, so three suites that run
# sync-pr.sh in the foreground and assert on its exit status would, run by hand,
# have asserted against the instant 0 of the launcher half. gate.sh pins
# HARNESS_DETACH=0 for the suites it runs, which is why CI never saw it.
for f in run-task.sh sync-pr.sh; do
  check "detach: $f captures HARNESS_DIR before common.sh defaults it" \
    "$(grep -c '^_INSTALL_DIR_FROM_ENV="\${HARNESS_DIR:-}"' "$SRC/$f")" "1"
  check "detach: $f lets an explicit HARNESS_DETACH=1 override the guess" \
    "$(grep -c '\[ "\${HARNESS_DETACH:-}" = 1 \]' "$SRC/$f")" "1"
  if grep -qF 'HARNESS_DIR came from the environment' "$SRC/$f"; then
    ok "detach: $f says so rather than suppressing in silence"
  else
    bad "detach: $f suppresses the detach in silence"
  fi
done

printf '\nliveness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
