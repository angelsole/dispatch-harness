#!/usr/bin/env bash
# The scheduled-dispatch contract: schedule.sh arms a launchd one-shot for a
# brief that already exists, the wrapper it writes fires that run exactly once
# with the scheduling shell's environment and then erases every trace of itself,
# and --list/--cancel see the same state.
#
# No real launchd is involved anywhere. `launchctl` and `uname` are fake
# binaries on PATH that record what they were asked to do (the technique
# tests/preprod.test.sh uses for the workers), so this suite is hermetic and
# runs on the Linux CI box as well as on the Mac the feature ships for.
# run-task.sh is faked the same way: schedule.sh resolves it beside itself, so
# the fixture copies schedule.sh into a sandbox harness dir next to a stand-in
# that records its argv and the environment it was handed.
#
# Usage: bash tests/schedule.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
README="$SRC/README.md"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/schedule-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"; AGENTS="$FHOME/Library/LaunchAgents"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
CALLS="$ROOT/run-task-calls.log"
LCLOG="$ROOT/launchctl.log"
UNAME_STATE="$ROOT/fake-uname"
mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES"
: > "$CALLS"; : > "$LCLOG"
printf 'Darwin\n' > "$UNAME_STATE"

# The script under test, installed the way install.sh installs it: beside the
# run-task.sh it will hand the run to.
cp "$SRC/schedule.sh" "$SRCDIR/schedule.sh"
chmod +x "$SRCDIR/schedule.sh"

cat > "$FAKES/uname" <<EOF
#!/usr/bin/env bash
cat "$UNAME_STATE"
EOF
cat > "$FAKES/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LCLOG"
EOF
# The pipeline stand-in: every fired run appends one record, so "exactly once"
# is a line count, and the environment it saw is asserted field by field.
cat > "$SRCDIR/run-task.sh" <<EOF
#!/usr/bin/env bash
{
  printf 'argv:%s\n' "\$*"
  printf 'canary:%s\n'     "\${HARNESS_CANARY-<unset>}"
  printf 'owner:%s\n'      "\${HARNESS_OWNER-<unset>}"
  printf 'ghtoken:%s\n'    "\${GH_TOKEN-<unset>}"
  printf 'effort:%s\n'     "\${IMPLEMENTER_EFFORT-<unset>}"
  printf 'harnessdir:%s\n' "\${HARNESS_DIR-<unset>}"
  printf 'unrelated:%s\n'  "\${SCHEDULE_UNRELATED-<unset>}"
  lc=\$(printf '%s' "\$1" | tr '[:upper:]' '[:lower:]')
  if [ -e "$RUNS/\$1/scheduled" ]; then printf 'marker:yes\n'; else printf 'marker:no\n'; fi
  if [ -e "$AGENTS/com.olyx.dispatch.\$lc.plist" ]; then printf 'plist:yes\n'; else printf 'plist:no\n'; fi
} >> "$CALLS"
echo "fake run-task.sh dispatched \$1"
EOF
chmod +x "$FAKES/uname" "$FAKES/launchctl" "$SRCDIR/run-task.sh"

git init -q "$ROOT/greenapp" >/dev/null 2>&1
REPO="$(cd "$ROOT/greenapp" && pwd)"

brief_for() { mkdir -p "$RUNS/$1"; printf '# fixture task\n' > "$RUNS/$1/brief.md"; }
for t in AHEAD ROLL ABS FIRE RE-ARM RELPATH; do brief_for "$t"; done

sched() {  # schedule.sh inside the fixture, with the fakes ahead of the real tools
  HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
    bash "$SRCDIR/schedule.sh" "$@" 2>&1
}
plist_of()   { printf '%s/com.olyx.dispatch.%s.plist' "$AGENTS" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }
wrapper_of() { printf '%s/%s/scheduled-run.sh' "$RUNS" "$1"; }
marker_of()  { printf '%s/%s/scheduled' "$RUNS" "$1"; }
fired()      { cat "$(marker_of "$1")" 2>/dev/null || echo 0; }

# Values are read back out of the plist by position — the generator writes each
# value on the line after its key — which is exactly the shape being asserted.
plist_val() {  # $1 = plist, $2 = key, $3 = integer|string
  awk -v k="<key>$2</key>" '$0 ~ k {getline; print; exit}' "$1" \
    | sed -e "s|.*<$3>||" -e "s|</$3>.*||" | tr -d '[:space:]'
}
at() {  # $1 = epoch, $2 = strftime format
  perl -e 'use POSIX qw(strftime); print strftime($ARGV[1], localtime($ARGV[0]))' -- "$1" "$2"
}

NOW=$(date +%s)
UID_NUM=$(id -u)
# A wall-clock time an hour out: its next occurrence is an hour from now, and a
# wall-clock time an hour ago: its next occurrence is ~23h away. Neither depends
# on what the calendar does at midnight, so the suite is safe at any hour.
AHEAD_HHMM=$(at "$((NOW + 3600))" '%H:%M')
ROLL_HHMM=$(at "$((NOW - 3600))" '%H:%M')
ABS_WHEN="$(at "$((NOW + 3 * 86400))" '%Y-%m-%d') 07:45"

# ---------------------------------------------------------------------------
echo "== guards: nothing is armed on a bad request =="
# ---------------------------------------------------------------------------
printf 'Linux\n' > "$UNAME_STATE"
out=$(sched AHEAD "$REPO" fix/ahead "$AHEAD_HHMM"); rc=$?
check "guard: non-macOS exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "needs macOS" "guard: non-macOS says the harness needs macOS"
has "$out" "launchd"     "guard: non-macOS names the mechanism it cannot use"
absent "guard: non-macOS armed no agent"  "$(plist_of AHEAD)"
absent "guard: non-macOS armed no marker" "$(marker_of AHEAD)"
printf 'Darwin\n' > "$UNAME_STATE"

out=$(sched NOBRIEF "$REPO" fix/nobrief "$AHEAD_HHMM"); rc=$?
check "guard: missing brief exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "brief" "guard: missing brief says which file is missing"
absent "guard: missing brief armed nothing" "$(plist_of NOBRIEF)"

out=$(sched AHEAD "$ROOT" fix/ahead "$AHEAD_HHMM"); rc=$?
check "guard: non-repo path exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "not a git repo" "guard: non-repo path says so"

out=$(sched AHEAD "$REPO" fix/ahead "tea time"); rc=$?
check "guard: unparseable time exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "HH:MM" "guard: unparseable time shows the accepted forms"

out=$(sched AHEAD "$REPO" fix/ahead "$(at "$((NOW - 86400))" '%Y-%m-%d') 09:00"); rc=$?
check "guard: past date exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "in the past" "guard: past date says it is in the past"

out=$(sched AHEAD "$REPO" fix/ahead "2027-02-31 09:00"); rc=$?
check "guard: impossible date exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "no such date" "guard: impossible date is rejected, not normalised"

out=$(sched AHEAD "$REPO" fix/ahead); rc=$?
check "guard: wrong argument count exits 2" "$rc" "2"
absent "guard: no agent survives the guard block" "$(plist_of AHEAD)"
check "guard: no run was dispatched" "$(grep -c '^argv:' "$CALLS" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== arming HH:MM still ahead today =="
# ---------------------------------------------------------------------------
out=$(sched AHEAD "$REPO" fix/ahead "$AHEAD_HHMM"); rc=$?
check "ahead: exits 0" "$rc" "0"
exists "ahead: marker written"  "$(marker_of AHEAD)"
exists "ahead: wrapper written" "$(wrapper_of AHEAD)"
exists "ahead: agent written"   "$(plist_of AHEAD)"
AHEAD_FIRE=$(fired AHEAD)
check "ahead: fires at the requested wall-clock time" "$(at "$AHEAD_FIRE" '%H:%M')" "$AHEAD_HHMM"
check "ahead: fires today, about an hour out" \
  "$([ "$AHEAD_FIRE" -gt "$NOW" ] && [ $((AHEAD_FIRE - NOW)) -le 3660 ] && echo yes || echo no)" "yes"
has "$out" "$(at "$AHEAD_FIRE" '%H:%M')" "ahead: the confirmation prints the fire time"
has "$out" "wakes after it" "ahead: the confirmation is honest about sleep"

echo "== the agent launchd is handed =="
P=$(plist_of AHEAD)
check "plist: label"  "$(plist_val "$P" Label string)"      "com.olyx.dispatch.ahead"
check "plist: hour"   "$(plist_val "$P" Hour integer)"      "$(at "$AHEAD_FIRE" '%H' | sed 's/^0//;s/^$/0/')"
check "plist: minute" "$(plist_val "$P" Minute integer)"    "$(at "$AHEAD_FIRE" '%M' | sed 's/^0//;s/^$/0/')"
check "plist: month"  "$(plist_val "$P" Month integer)"     "$(at "$AHEAD_FIRE" '%m' | sed 's/^0//')"
check "plist: day"    "$(plist_val "$P" Day integer)"       "$(at "$AHEAD_FIRE" '%d' | sed 's/^0//')"
file_has "$P" "<key>StartCalendarInterval</key>" "plist: fires on a calendar interval"
file_has "$P" "<string>/bin/bash</string>"       "plist: runs the wrapper through bash (it is mode 600, not executable)"
file_has "$P" "$(wrapper_of AHEAD)"              "plist: runs this run's wrapper"
file_has "$P" "$RUNS/AHEAD/scheduled.log"        "plist: output backstop points at the run log"
has_not "$(cat "$P")" "RunAtLoad" "plist: no RunAtLoad — loading the agent must not fire it"
check "wrapper: mode 600 (it carries an env snapshot)" \
  "$(ls -l "$(wrapper_of AHEAD)" | cut -c1-10)" "-rw-------"
file_has "$LCLOG" "bootstrap gui/$UID_NUM $P" "launchctl: the agent was bootstrapped into the user domain"

# launchd runs the job from a directory of its own choosing, so a repo path that
# was relative to the scheduling shell has to be resolved at arming time.
( cd "$ROOT" && sched RELPATH greenapp fix/rel "$AHEAD_HHMM" ) > /dev/null
file_has "$(wrapper_of RELPATH)" "REPO='$REPO'" \
  "ahead: a relative repo path is resolved before launchd ever sees it"
sched --cancel RELPATH > /dev/null

# ---------------------------------------------------------------------------
echo "== arming HH:MM already past today: next occurrence =="
# ---------------------------------------------------------------------------
out=$(sched ROLL "$REPO" fix/roll "$ROLL_HHMM"); rc=$?
check "roll: exits 0" "$rc" "0"
ROLL_FIRE=$(fired ROLL)
check "roll: keeps the requested wall-clock time" "$(at "$ROLL_FIRE" '%H:%M')" "$ROLL_HHMM"
check "roll: never fires in the past" "$([ "$ROLL_FIRE" -gt "$NOW" ] && echo yes || echo no)" "yes"
# ~23h out (22h/24h across a DST boundary) — i.e. the next occurrence, not today's.
check "roll: rolls to the next occurrence, roughly a day out" \
  "$([ $((ROLL_FIRE - NOW)) -gt 79200 ] && [ $((ROLL_FIRE - NOW)) -lt 90000 ] && echo yes || echo no)" "yes"
check "roll: the agent carries the rolled-over day" \
  "$(plist_val "$(plist_of ROLL)" Day integer)" "$(at "$ROLL_FIRE" '%d' | sed 's/^0//')"

# ---------------------------------------------------------------------------
echo "== arming an absolute YYYY-MM-DD HH:MM =="
# ---------------------------------------------------------------------------
out=$(sched ABS "$REPO" fix/abs "$ABS_WHEN"); rc=$?
check "abs: exits 0" "$rc" "0"
ABS_FIRE=$(fired ABS)
check "abs: fires at exactly the requested local time" "$(at "$ABS_FIRE" '%Y-%m-%d %H:%M')" "$ABS_WHEN"
check "abs: agent hour"   "$(plist_val "$(plist_of ABS)" Hour integer)"   "7"
check "abs: agent minute" "$(plist_val "$(plist_of ABS)" Minute integer)" "45"
check "abs: agent month"  "$(plist_val "$(plist_of ABS)" Month integer)"  "$(at "$ABS_FIRE" '%m' | sed 's/^0//')"
check "abs: agent day"    "$(plist_val "$(plist_of ABS)" Day integer)"    "$(at "$ABS_FIRE" '%d' | sed 's/^0//')"

# ---------------------------------------------------------------------------
echo "== re-arming a ticket replaces its schedule =="
# ---------------------------------------------------------------------------
out=$(sched RE-ARM "$REPO" fix/rearm "$ROLL_HHMM")
before=$(fired RE-ARM)
out=$(sched RE-ARM "$REPO" fix/rearm "$AHEAD_HHMM")
has "$out" "already armed" "re-arm: says the previous schedule is being replaced"
check "re-arm: the marker holds the new fire time" "$(at "$(fired RE-ARM)" '%H:%M')" "$AHEAD_HHMM"
check "re-arm: the old fire time is gone" "$([ "$(fired RE-ARM)" != "$before" ] && echo yes || echo no)" "yes"
check "re-arm: exactly one agent for the ticket" \
  "$(find "$AGENTS" -name 'com.olyx.dispatch.re-arm.plist' | grep -c '' | tr -d ' ')" "1"
file_has "$LCLOG" "bootout gui/$UID_NUM/com.olyx.dispatch.re-arm" \
  "re-arm: the previous agent was booted out first"

# ---------------------------------------------------------------------------
echo "== --list: what is pending, soonest first =="
# ---------------------------------------------------------------------------
LIST=$(sched --list)
has "$LIST" "AHEAD" "list: shows the ticket armed for today"
has "$LIST" "ROLL"  "list: shows the rolled-over ticket"
has "$LIST" "ABS"   "list: shows the absolute-time ticket"
has "$LIST" "$(at "$ABS_FIRE" '%a %d %b %H:%M')" "list: prints a human fire time"
first=$(printf '%s\n' "$LIST" | grep -E '^(AHEAD|ROLL|ABS) ' | head -1 | awk '{print $1}')
last=$(printf '%s\n' "$LIST" | grep -E '^(AHEAD|ROLL|ABS) ' | tail -1 | awk '{print $1}')
check "list: soonest first" "$first" "AHEAD"
check "list: furthest last" "$last"  "ABS"
check "list: one row per armed ticket" \
  "$(printf '%s\n' "$LIST" | grep -cE '^(AHEAD|ROLL|ABS) ' | tr -d ' ')" "3"

# ---------------------------------------------------------------------------
echo "== the fired wrapper: one run, with the scheduling shell's identity =="
# ---------------------------------------------------------------------------
CANARY="it is 08:10 and Angel's shell said so"
(
  export HARNESS_CANARY="$CANARY" HARNESS_OWNER=angel GH_TOKEN=gho_fixture \
         IMPLEMENTER_EFFORT=max SCHEDULE_UNRELATED=must-not-travel
  sched FIRE "$REPO" fix/fire "$AHEAD_HHMM" > /dev/null
)
W=$(wrapper_of FIRE)
exists "fire: wrapper armed" "$W"
# launchd hands the job a bare environment, so the wrapper must carry its own:
# env -i is the closest a test gets to that, and it also proves PATH travelled
# (nothing below would resolve otherwise).
env -i HOME="$FHOME" /bin/bash "$W"
check "fire: run-task.sh ran exactly once" "$(grep -c '^argv:' "$CALLS" | tr -d ' ')" "1"
check "fire: with the ticket, repo and branch it was scheduled with" \
  "$(grep '^argv:' "$CALLS" | sed 's/^argv://')" "FIRE $REPO fix/fire"
check "fire: HARNESS_* travelled verbatim (quotes and all)" \
  "$(grep '^canary:' "$CALLS" | sed 's/^canary://')" "$CANARY"
check "fire: the dispatching owner travelled"  "$(grep '^owner:' "$CALLS" | sed 's/^owner://')" "angel"
check "fire: the gh token travelled"           "$(grep '^ghtoken:' "$CALLS" | sed 's/^ghtoken://')" "gho_fixture"
check "fire: the effort knob travelled"        "$(grep '^effort:' "$CALLS" | sed 's/^effort://')" "max"
check "fire: HARNESS_DIR travelled"            "$(grep '^harnessdir:' "$CALLS" | sed 's/^harnessdir://')" "$HARNESS"
check "fire: unrelated environment stayed home" \
  "$(grep '^unrelated:' "$CALLS" | sed 's/^unrelated://')" "<unset>"
check "fire: disarmed before dispatching — no marker left to fire twice" \
  "$(grep '^marker:' "$CALLS" | sed 's/^marker://')" "no"
check "fire: disarmed before dispatching — the agent plist was already gone" \
  "$(grep '^plist:' "$CALLS" | sed 's/^plist://')" "no"
absent "fire: wrapper removed itself" "$W"
absent "fire: marker removed"         "$(marker_of FIRE)"
absent "fire: agent plist removed"    "$(plist_of FIRE)"
file_has "$LCLOG" "bootout gui/$UID_NUM/com.olyx.dispatch.fire" \
  "fire: the wrapper booted its own agent out of launchd"
file_has "$RUNS/FIRE/scheduled.log" "firing FIRE"                  "fire: the run log records the firing"
file_has "$RUNS/FIRE/scheduled.log" "fake run-task.sh dispatched FIRE" "fire: run-task output lands in the run log"
file_has "$RUNS/FIRE/scheduled.log" "run-task.sh exited 0"         "fire: the run log records the exit status"
exists "fire: the brief survives its run" "$RUNS/FIRE/brief.md"

# ---------------------------------------------------------------------------
echo "== --cancel: disarm completely, keep the brief =="
# ---------------------------------------------------------------------------
out=$(sched --cancel ROLL); rc=$?
check "cancel: exits 0" "$rc" "0"
has "$out" "disarmed" "cancel: says what happened"
absent "cancel: agent plist gone" "$(plist_of ROLL)"
absent "cancel: wrapper gone"     "$(wrapper_of ROLL)"
absent "cancel: marker gone"      "$(marker_of ROLL)"
exists "cancel: the brief is kept" "$RUNS/ROLL/brief.md"
file_has "$LCLOG" "bootout gui/$UID_NUM/com.olyx.dispatch.roll" "cancel: the agent was booted out"
LIST=$(sched --list)
has_not "$LIST" "ROLL " "cancel: the schedule leaves --list"
has     "$LIST" "ABS "  "cancel: the other schedules are untouched"
exists  "cancel: another ticket's agent is untouched" "$(plist_of ABS)"

out=$(sched --cancel NEVERARMED); rc=$?
check "cancel: cancelling nothing exits 0" "$rc" "0"
has "$out" "nothing scheduled" "cancel: cancelling nothing says so plainly"

sched --cancel AHEAD > /dev/null
sched --cancel ABS   > /dev/null
sched --cancel RE-ARM > /dev/null
check "cancel: --list is empty once everything is disarmed" "$(sched --list)" "no pending schedules"
check "cancel: no run was ever dispatched by cancelling" \
  "$(grep -c '^argv:' "$CALLS" | tr -d ' ')" "1"

# ---------------------------------------------------------------------------
echo "== shipped and documented alongside run-task =="
# ---------------------------------------------------------------------------
file_has "$SRC/install.sh" "schedule.sh" "install: schedule.sh is installed with the rest"
file_has "$README" 'schedule.sh <TICKET> <repo-path> <branch-name>' "README: documents the argument contract"
file_has "$README" 'schedule.sh --list'   "README: documents --list"
file_has "$README" 'schedule.sh --cancel' "README: documents --cancel"
file_has "$README" 'launchd'  "README: names the mechanism"
file_has "$README" 'GH_TOKEN' "README: warns that the wrapper can hold a token"
file_has "$README" 'mode 600' "README: documents the wrapper's permissions"
if grep -q 'as soon as the machine wakes' "$README"; then
  ok "README: is honest about a machine that sleeps through the fire time"
else
  bad "README: is honest about a machine that sleeps through the fire time"
fi

echo
printf 'schedule: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
