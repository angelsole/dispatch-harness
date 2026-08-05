#!/usr/bin/env bash
# Fire a prepared dispatch at a set time — "start OLYX-1566 at 08:10 tomorrow".
#
# The brief must already exist at <HARNESS_DIR>/runs/<TICKET>/brief.md, exactly
# as run-task.sh expects it: the planner writes the brief now, the run happens
# later, and the reviewed PR is waiting when the office opens. Same argument
# contract as run-task.sh, plus a time.
#
# Usage:
#   schedule.sh <TICKET> <repo-path> <branch-name> <when>
#   schedule.sh --list                pending schedules and their fire times
#   schedule.sh --cancel <TICKET>     disarm one (the brief is kept)
#
# <when> is either HH:MM — the next occurrence: today if that is still ahead,
# tomorrow otherwise — or an absolute "YYYY-MM-DD HH:MM". Both are local time.
#
# macOS only. The mechanism is a per-user launchd LaunchAgent
# (com.olyx.dispatch.<ticket>) holding a single StartCalendarInterval, and
# launchd coalesces a fire time missed while the machine slept into the next
# wake — so the honest promise is "08:10, or as soon as the machine wakes after
# that". For a hard guarantee, schedule on a machine that stays awake.
#
# The wrapper it arms carries a snapshot of THIS shell's harness environment
# (every HARNESS_*, CLAUDE_CONFIG_DIR, CODEX_HOME, GH_CONFIG_DIR, GH_TOKEN, the
# model/effort knobs and PATH), so the scheduled run dispatches with the
# identity it was scheduled with. It can therefore hold a token: it is written
# mode 600 and lives in the run dir.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="com.olyx.dispatch"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail()  { echo "FATAL: $*" >&2; exit 1; }

# The harness is macOS-first and this feature is launchd, not a portable timer:
# say so instead of arming something that will never fire.
[ "$(uname -s 2>/dev/null)" = "Darwin" ] || fail "schedule.sh needs macOS (it arms a launchd LaunchAgent) — this is $(uname -s 2>/dev/null || echo an unknown OS).
Dispatch now with run-task.sh, or schedule it on the Mac that should run it."

label_for() { printf '%s.%s' "$LABEL_PREFIX" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }
plist_for() { printf '%s/%s.plist' "$AGENTS_DIR" "$(label_for "$1")"; }

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------
# All date arithmetic goes through perl (already a hard dependency): BSD and GNU
# date(1) disagree on every flag this would need. Scanning real minute boundaries
# makes "08:10 next occurrence" correct across skipped and repeated DST hours.
fire_epoch() {  # $1 = <when>; prints the fire epoch, or explains and fails
  perl -e '
    use strict; use warnings; use POSIX qw(mktime);
    my $when = $ARGV[0];
    my $now = time;
    my @now = localtime($now);
    my ($y, $mo, $d, $h, $mi, $rel);
    $rel = 0;
    if ($when =~ /^(\d{1,2}):(\d{2})$/) {
      ($h, $mi) = ($1 + 0, $2 + 0);
      ($y, $mo, $d) = ($now[5], $now[4], $now[3]);
      $rel = 1;
    } elsif ($when =~ /^(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{2})$/) {
      ($y, $mo, $d) = ($1 - 1900, $2 - 1, $3 + 0);
      ($h, $mi) = ($4 + 0, $5 + 0);
    } else {
      die "FATAL: cannot read [$when] as a time — use HH:MM or \"YYYY-MM-DD HH:MM\"\n";
    }
    die "FATAL: [$when] is not a time of day\n" if $h > 23 || $mi > 59;
    if ($rel) {
      # Scan real minute boundaries instead of adding 24 hours or asking
      # mktime() to normalise a date. That finds the genuinely next occurrence
      # across both the missing and repeated wall-clock hours at DST changes.
      my $t = int($now / 60) * 60 + 60;
      for (0 .. 48 * 60) {
        my @got = localtime($t);
        if ($got[2] == $h && $got[1] == $mi) { print $t; exit 0; }
        $t += 60;
      }
      die "FATAL: cannot find the next local occurrence of [$when]\n";
    }

    my $t = mktime(0, $mi, $h, $d, $mo, $y);
    defined $t or die "FATAL: no such local time: [$when]\n";
    # mktime happily normalises invalid dates and nonexistent DST times. Round
    # trip every requested calendar field so a typo never silently moves.
    my @got = localtime($t);
    die "FATAL: no such date: [$when]\n"
      if $got[5] != $y || $got[4] != $mo || $got[3] != $d;
    die "FATAL: no such local time: [$when]\n"
      if $got[2] != $h || $got[1] != $mi;
    die "FATAL: [$when] is already in the past\n" if $t <= $now;
    print $t;
  ' -- "$1"
}

human_time() {  # $1 = epoch
  perl -e 'use POSIX qw(strftime); print strftime("%a %d %b %H:%M", localtime($ARGV[0]))' -- "$1"
}

countdown() {  # $1 = seconds from now (may be negative)
  local s="$1" word="in"
  if [ "$s" -lt 0 ]; then word="overdue"; s=$(( -s )); fi
  printf '%s %dh%02dm' "$word" "$((s / 3600))" "$(( (s % 3600) / 60 ))"
}

# ---------------------------------------------------------------------------
# The environment snapshot
# ---------------------------------------------------------------------------
shquote() {  # $1 = value; prints it single-quoted for the wrapper
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Everything the pipeline reads from its environment. The HARNESS_* sweep is
# what makes this compose with the rest of the harness by construction: a knob
# added to run-task.sh under that prefix rides along without a change here.
env_names() {
  { compgen -e 2>/dev/null | grep -E '^HARNESS_[A-Za-z0-9_]+$'
    printf '%s\n' HARNESS_DIR CLAUDE_CONFIG_DIR CODEX_HOME GH_CONFIG_DIR GH_TOKEN \
      IMPLEMENTER_MODEL IMPLEMENTER_EFFORT REVIEWER_MODEL REVIEWER_EFFORT PATH
  } | sort -u
}

env_snapshot() {
  local n set_flag val
  for n in $(env_names); do
    eval "set_flag=\${$n+x}; val=\${$n:-}"
    [ -n "$set_flag" ] || continue
    printf 'export %s=' "$n"; shquote "$val"; printf '\n'
  done
}

# ---------------------------------------------------------------------------
# Arm / disarm
# ---------------------------------------------------------------------------
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

armed() {  # $1 = ticket: anything of this schedule still on disk?
  [ -e "$(plist_for "$1")" ] || [ -e "$RUNS/$1/scheduled" ] || [ -e "$RUNS/$1/scheduled-run.sh" ]
}

validate_ticket() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*)
      fail "ticket must be letters, digits, dot, dash or underscore and must not start with dot: [$1]"
      ;;
  esac
}

disarm() {  # $1 = ticket: remove the agent and every file that arms it
  launchctl bootout "gui/$(id -u)/$(label_for "$1")" >/dev/null 2>&1 || true
  rm -f "$(plist_for "$1")" "$RUNS/$1/scheduled" "$RUNS/$1/scheduled-run.sh"
}

write_wrapper() {  # $1 ticket, $2 repo, $3 branch, $4 fire epoch, $5 wrapper path
  # Created empty and locked down before a single byte of the snapshot lands in
  # it: the snapshot may carry GH_TOKEN.
  : > "$5" || return 1
  chmod 600 "$5" || return 1
  {
    cat <<EOF
#!/usr/bin/env bash
# One-shot dispatch wrapper — generated by schedule.sh, do not edit.
# Armed for $(human_time "$4"). Mode 600: the snapshot below may carry a token.
set -u

LABEL=$(shquote "$(label_for "$1")")
PLIST=$(shquote "$(plist_for "$1")")
WRAPPER=$(shquote "$5")
MARKER=$(shquote "$RUNS/$1/scheduled")
LOG=$(shquote "$RUNS/$1/scheduled.log")
RUN_TASK=$(shquote "$SELF_DIR/run-task.sh")
TICKET=$(shquote "$1")
REPO=$(shquote "$2")
BRANCH=$(shquote "$3")
FIRE_EPOCH=$(shquote "$4")

$(env_snapshot)
EOF
    cat <<'EOF'

# launchd has no Year field, so an absolute date more than a year away may
# produce an earlier annual calendar match. Leave the schedule armed until the
# requested epoch; a missed target still fires on wake because now is then
# greater than FIRE_EPOCH.
exec >> "$LOG" 2>&1
now=$(date +%s 2>/dev/null) || {
  echo "[schedule] cannot read the current time; leaving $TICKET armed"
  exit 1
}
case "$now" in
  ''|*[!0-9]*)
    echo "[schedule] invalid current time [$now]; leaving $TICKET armed"
    exit 1
    ;;
esac
if [ "$now" -lt "$FIRE_EPOCH" ]; then
  echo "[schedule] early annual calendar match for $TICKET; still armed for $FIRE_EPOCH"
  exit 0
fi

# Disarm BEFORE dispatching, so exactly one run can ever come out of this
# schedule: with the plist already gone, a crash, a power cut or a reboot in the
# middle of the run cannot re-arm it, and there is nothing left for a launchd
# calendar rollover to fire a year from now. Deleting this script while bash is
# running it is safe — the interpreter holds the open file descriptor.
rm -f "$PLIST" "$WRAPPER" "$MARKER"

echo "[schedule] $(date '+%Y-%m-%d %H:%M:%S') firing $TICKET"
"$RUN_TASK" "$TICKET" "$REPO" "$BRANCH"
rc=$?
echo "[schedule] $(date '+%Y-%m-%d %H:%M:%S') run-task.sh exited $rc"

# Last, because booting a job out of launchd terminates that job — us. Nothing
# may follow it; everything above has already happened. This only clears the
# in-memory agent, which the deleted plist would otherwise outlive until logout.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
exit $rc
EOF
  } >> "$5"
}

write_plist() {  # $1 ticket, $2 wrapper path, $3 fire epoch, $4 plist path
  local mon day hour min
  # launchd takes calendar fields, not an epoch, and has no Year: Month + Day +
  # Hour + Minute is the most specific it gets. Exactly-once is the wrapper's
  # job, not the calendar's.
  read -r mon day hour min <<EOF
$(perl -e 'my @t = localtime($ARGV[0]); printf "%d %d %d %d", $t[4] + 1, $t[3], $t[2], $t[1]' -- "$3")
EOF
  cat > "$4" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml_escape "$(label_for "$1")")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml_escape "$2")</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Month</key>
		<integer>$mon</integer>
		<key>Day</key>
		<integer>$day</integer>
		<key>Hour</key>
		<integer>$hour</integer>
		<key>Minute</key>
		<integer>$min</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$RUNS/$1/scheduled.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$RUNS/$1/scheduled.log")</string>
</dict>
</plist>
EOF
}

arm() {  # $1 ticket, $2 repo path, $3 branch, $4 when
  local ticket="$1" repo branch="$3" fire plist wrapper run_dir now

  validate_ticket "$1"
  [ -n "$branch" ] || fail "branch name is empty"
  repo=$(cd "$2" 2>/dev/null && pwd) || repo=""
  [ -n "$repo" ] || fail "no such repo directory: $2"
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || fail "$repo is not a git repo"
  [ -x "$SELF_DIR/run-task.sh" ] || fail "no executable run-task.sh beside $0"

  run_dir="$RUNS/$ticket"
  [ -f "$run_dir/brief.md" ] || fail "no brief at $run_dir/brief.md — write the brief before scheduling the run"

  fire=$(fire_epoch "$4") || exit 1

  plist=$(plist_for "$ticket")
  wrapper="$run_dir/scheduled-run.sh"
  if armed "$ticket"; then
    echo "[schedule] $ticket was already armed — replacing that schedule"
  fi
  disarm "$ticket"

  mkdir -p "$AGENTS_DIR" || fail "cannot create $AGENTS_DIR"
  write_wrapper "$ticket" "$repo" "$branch" "$fire" "$wrapper" \
    || fail "cannot write $wrapper"
  write_plist "$ticket" "$wrapper" "$fire" "$plist" \
    || { rm -f "$wrapper" "$plist"; fail "cannot write $plist"; }
  # Put the marker in place before bootstrap. A calendar event can become due
  # while launchctl is loading the job; the wrapper must be able to remove the
  # marker even if it starts before bootstrap returns.
  echo "$fire" > "$run_dir/scheduled" \
    || { rm -f "$wrapper" "$plist"; fail "cannot write $run_dir/scheduled"; }
  launchctl bootstrap "gui/$(id -u)" "$plist" \
    || { disarm "$ticket"; fail "launchctl could not load $plist"; }

  now=$(date +%s)
  echo "[schedule] $ticket armed for $(human_time "$fire") ($(countdown "$((fire - now))"))"
  echo "[schedule]   $repo  $branch"
  echo "[schedule]   agent   $(label_for "$ticket")"
  echo "[schedule]   wrapper $wrapper (mode 600 — holds an env snapshot)"
  echo "[schedule]   log     $run_dir/scheduled.log"
  echo "[schedule] launchd fires at that wall-clock time, or as soon as the machine"
  echo "[schedule] wakes after it if it was asleep. Cancel: schedule.sh --cancel $ticket"
}

list() {
  local rows now marker ticket fire note
  [ -d "$RUNS" ] || { echo "no pending schedules"; return 0; }
  # Collected in a loop rather than inside a command substitution: bash 3.2, the
  # macOS default, cannot parse a `case` inside $( ).
  rows=""
  for marker in "$RUNS"/*/scheduled; do
    [ -f "$marker" ] || continue
    read -r fire < "$marker" || continue
    [ -n "$fire" ] && [ -z "${fire//[0-9]/}" ] || continue
    ticket=$(basename "$(dirname "$marker")")
    rows="$rows$fire $ticket
"
  done
  [ -n "$rows" ] || { echo "no pending schedules"; return 0; }
  rows=$(printf '%s' "$rows" | sort -n)

  now=$(date +%s)
  printf '%-24s %-20s %s\n' "TICKET" "FIRES" "WHEN"
  while read -r fire ticket; do
    [ -n "$ticket" ] || continue
    note=""
    [ -e "$(plist_for "$ticket")" ] || note="  (agent missing — cancel and re-arm)"
    printf '%-24s %-20s %s%s\n' "$ticket" "$(human_time "$fire")" \
      "$(countdown "$((fire - now))")" "$note"
  done <<EOF
$rows
EOF
}

cancel() {  # $1 = ticket
  validate_ticket "$1"
  if ! armed "$1"; then
    echo "nothing scheduled for $1"
    return 0
  fi
  disarm "$1"
  echo "[schedule] $1 disarmed — agent, plist, wrapper and marker removed (the brief is kept)"
}

case "${1:-}" in
  --list)   [ $# -eq 1 ] || usage; list ;;
  --cancel) [ $# -eq 2 ] || usage; cancel "$2" ;;
  -h|--help) usage ;;
  '')       usage ;;
  -*)       echo "unknown option: $1" >&2; echo >&2; usage ;;
  *)        [ $# -eq 4 ] || usage; arm "$1" "$2" "$3" "$4" ;;
esac
