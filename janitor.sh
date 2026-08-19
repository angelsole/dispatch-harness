#!/usr/bin/env bash
# The Janitor — the pass that closes the loop cleanup.sh only closes when
# somebody is watching.
#
# cleanup.sh runs when the orchestrator promotes a PR in-session. Every other
# road to a merged PR leaves the run's worktree on disk forever, because nothing
# in the harness ever looks back: a PR merged from the web UI, merged by a
# teammate, promoted in a session that died, or a `push_failed` run whose branch
# shipped anyway. Twenty-two of those worktrees, thirteen gigabytes, was the
# state of the machine this was written for. `flutter test` compounds it — it
# leaves detached `flutter_tester` processes behind, and removing a worktree does
# not kill them.
#
# Usage:
#   janitor.sh [--report]        what --clean would do; sweeps nothing
#   janitor.sh --clean           sweep those worktrees, reap those processes
#   janitor.sh --install [MODE]  daily LaunchAgent (MODE: --report|--clean)
#   janitor.sh --uninstall       remove that agent
#
# A run is swept only when every one of these holds: its result.json carries a
# pr_url, `gh pr view` says that PR is MERGED, the worktree is still there, and
# `git status --porcelain` in it is empty. Everything else is listed and left —
# an OPEN PR above all, whose worktree is where post-PR review fixes land. A PR
# whose state cannot be read is `unknown`, never "probably merged": a state that
# could not be read is not evidence of anything.
#
# Sweeping is delegated to cleanup.sh, which already knows how to remove a
# worktree, delete the local branch only when it is on origin, and drop a
# mirrored copy. Run logs under runs/<RUN-ID>/ are never deleted: this script
# removes worktrees and processes, nothing else.
#
# What leaves this machine: one read-only `gh pr view` per run that has a PR.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"
JAN_DIR="$RUNS/janitor"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_ID="com.olyx.janitor"
WRAPPER="$JAN_DIR/janitor-agent.sh"
PLIST="$AGENTS_DIR/$LABEL_ID.plist"
AGENT_LOG="$JAN_DIR/janitor.log"
CLEANUP="$SELF_DIR/cleanup.sh"

# Every knob env-tunable, the way the sibling scripts do it.
AT="${JANITOR_AT:-09:00}"                       # when the installed agent fires
PROC_AGE="${JANITOR_PROC_AGE:-7200}"            # seconds one may live (2h)
GH_TIMEOUT="${JANITOR_GH_TIMEOUT:-20}"          # seconds allowed per gh call
# The one knob that does NOT swallow an empty value into its default: an
# accidentally-empty `JANITOR_PROC_MATCH=$SOMETHING` has to be refused out loud
# rather than quietly reaping the default's processes instead.
PROC_MATCH="${JANITOR_PROC_MATCH-flutter_tester}"   # process name to reap

usage() { sed -n '14,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail()  { echo "FATAL: $*" >&2; exit 1; }
say()   { echo "[janitor] $*"; }

# A process cap that exists on macOS, where timeout(1) does not — the same perl
# one-liner capacity.sh uses, for the same reason.
capped() { perl -e 'alarm shift; exec @ARGV' "$@"; }

case "$PROC_AGE" in ''|*[!0-9]*) fail "JANITOR_PROC_AGE must be whole seconds — got [$PROC_AGE]" ;; esac
case "$GH_TIMEOUT" in ''|*[!0-9]*) fail "JANITOR_GH_TIMEOUT must be whole seconds — got [$GH_TIMEOUT]" ;; esac
# An empty match would select every process on the machine.
[ -n "$PROC_MATCH" ] || fail "JANITOR_PROC_MATCH must not be empty"

WORK=""
cleanup_work() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup_work EXIT

SWEEP_FAILED=0   # cleanup.sh calls that did not succeed, in --clean

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
human_secs() {  # $1 = seconds
  if   [ "$1" -ge 3600 ]; then printf '%dh%02dm' "$(($1 / 3600))" "$((($1 % 3600) / 60))"
  elif [ "$1" -ge 60 ];   then printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"
  else                         printf '%ds' "$1"
  fi
}

human_kb() {  # $1 = kilobytes, as du -sk reports them
  if   [ "$1" -ge 1048576 ]; then printf '%d.%dG' "$(($1 / 1048576))" "$((($1 % 1048576) * 10 / 1048576))"
  elif [ "$1" -ge 1024 ];    then printf '%dM' "$(($1 / 1024))"
  else                            printf '%dK' "$1"
  fi
}

# One line per worktree the harness still holds, and what may be done about it.
# The full path is printed rather than a basename: it is what an operator checks
# before trusting --clean.
line() {  # $1 = verb, $2 = run id, $3 = why, $4 = worktree
  printf '[janitor]   %-7s %-24s %-44s %s\n' "$1" "$2" "$3" "$4"
}

# ps prints elapsed time as [[DD-]HH:]MM:SS. Leading zeros make $(( )) read a
# field as octal, so every field goes through base 10 explicitly.
dec() { case "${1:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%d' "$((10#$1))" ;; esac; }

etime_secs() {  # $1 = a ps etime field; prints seconds, fails when it is not one
  local e="${1:-}" days=0 h=0 m=0 s=0
  case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
  case "$e" in *-*) days="${e%%-*}"; e="${e#*-}" ;; esac
  case "$e" in
    *:*:*) h="${e%%:*}"; e="${e#*:}"; m="${e%%:*}"; s="${e##*:}" ;;
    *:*)   m="${e%%:*}"; s="${e##*:}" ;;
    *)     s="$e" ;;
  esac
  printf '%d' "$(( $(dec "$days") * 86400 + $(dec "$h") * 3600 + $(dec "$m") * 60 + $(dec "$s") ))"
}

# ---------------------------------------------------------------------------
# The PR state — the one thing this asks the network
# ---------------------------------------------------------------------------
GH_OK=1
GH_NOTE=''

gh_probe() {
  if ! command -v gh >/dev/null 2>&1; then
    GH_OK=0
    GH_NOTE='gh is not installed — no PR state can be read, so nothing is sweepable'
    return 0
  fi
  if ! capped "$GH_TIMEOUT" gh auth status >/dev/null 2>&1; then
    GH_OK=0
    GH_NOTE='gh is not authenticated (gh auth login) — no PR state can be read, so nothing is sweepable'
  fi
  return 0
}

# Prints MERGED, OPEN or CLOSED — and nothing at all when the state could not be
# read. An unreadable state is never collapsed into one of the three: that is
# the whole difference between a janitor and a data-loss incident.
pr_state() {  # $1 = PR url
  local out
  [ "$GH_OK" = 1 ] || return 0
  out=$(capped "$GH_TIMEOUT" gh pr view "$1" --json state -q .state 2>/dev/null) || return 0
  case "$out" in MERGED|OPEN|CLOSED) printf '%s' "$out" ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------
sweep_runs() {  # $1 = report | clean
  local mode="$1"
  local d id wt pr state porcelain gitdir kb rc stage_text dirty
  local n_runs=0 n_sweep=0 n_open=0 n_closed=0 n_dirty=0 n_unknown=0
  local n_nopr=0 n_unfinished=0 n_gone=0 reclaim=0 kept=0

  if [ ! -d "$RUNS" ]; then
    say "no runs directory at $RUNS — nothing to sweep"
    return 0
  fi
  [ -n "$GH_NOTE" ] && say "$GH_NOTE"

  for d in "$RUNS"/*; do
    [ -d "$d" ] || continue
    # A run dir is one the pipeline wrote a status or a result into. The
    # quartermaster's and this script's own directories live under runs/ too and
    # are not runs.
    [ -f "$d/status" ] || [ -f "$d/result.json" ] || continue
    id="${d##*/}"
    n_runs=$((n_runs + 1))

    # The worktree, read exactly the way cleanup.sh reads it.
    wt=$(cat "$d/worktree" 2>/dev/null || jq -r '.worktree // empty' "$d/result.json" 2>/dev/null)
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
      n_gone=$((n_gone + 1))
      continue
    fi

    # A run that has not reached a done: stage may still be building in that
    # worktree, or waiting in it for an answer. Never touched, whatever its PR
    # says — and a run with no stage line at all is one whose state cannot be
    # read, which is the same answer.
    stage_text=$(sed -n '1s/^[0-9]* //p' "$d/status" 2>/dev/null)
    case "$stage_text" in
      done:*) ;;
      '') line keep "$id" "no status line — cannot tell if it is done" "$wt"
          n_unfinished=$((n_unfinished + 1)); continue ;;
      *)  line keep "$id" "still running — $stage_text" "$wt"
          n_unfinished=$((n_unfinished + 1)); continue ;;
    esac

    pr=$(jq -r '.pr_url // empty' "$d/result.json" 2>/dev/null)
    if [ -z "$pr" ]; then
      line keep "$id" "no pr_url — the work exists only here" "$wt"
      n_nopr=$((n_nopr + 1)); continue
    fi

    state=$(pr_state "$pr")
    case "$state" in
      MERGED) ;;
      OPEN)   line keep "$id" "PR is OPEN — review fixes land here" "$wt"
              n_open=$((n_open + 1)); continue ;;
      CLOSED) line keep "$id" "PR is CLOSED, not merged" "$wt"
              n_closed=$((n_closed + 1)); continue ;;
      *)      line keep "$id" "PR state unreadable — left alone" "$wt"
              n_unknown=$((n_unknown + 1)); continue ;;
    esac

    if ! porcelain=$(git -C "$wt" status --porcelain 2>/dev/null); then
      line keep "$id" "not a readable git worktree" "$wt"
      n_unknown=$((n_unknown + 1)); continue
    fi
    if [ -n "$porcelain" ]; then
      dirty=$(printf '%s\n' "$porcelain" | grep -c '' | tr -d ' ')
      line keep "$id" "merged, but dirty ($dirty uncommitted)" "$wt"
      n_dirty=$((n_dirty + 1)); continue
    fi

    kb=$(du -sk "$wt" 2>/dev/null | awk 'NR==1 {print $1}')
    case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
    n_sweep=$((n_sweep + 1))

    # The repo can only be resolved through the worktree, so it is resolved
    # before cleanup.sh removes it.
    if gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      dirname "$gitdir" >> "$WORK/repos"
    fi

    if [ "$mode" != clean ]; then
      line sweep "$id" "merged and clean — $(human_kb "$kb") to reclaim" "$wt"
      reclaim=$((reclaim + kb))
      continue
    fi

    line sweep "$id" "merged and clean — reclaiming $(human_kb "$kb")" "$wt"
    rc=0
    HARNESS_DIR="$HARNESS_DIR" bash "$CLEANUP" "$id" > "$WORK/cleanup.out" 2>&1 || rc=$?
    sed 's/^/[janitor]           /' "$WORK/cleanup.out"
    if [ "$rc" -ne 0 ] || [ -d "$wt" ]; then
      say "  cleanup.sh left $wt standing (exit $rc) — kept for the next pass"
      SWEEP_FAILED=$((SWEEP_FAILED + 1))
      n_sweep=$((n_sweep - 1))
    else
      reclaim=$((reclaim + kb))
    fi
  done

  kept=$((n_open + n_closed + n_dirty + n_unknown + n_nopr + n_unfinished))
  echo
  if [ "$mode" = clean ]; then
    say "$n_sweep worktree(s) swept, $(human_kb "$reclaim") reclaimed · $kept kept · $n_gone of $n_runs runs had no worktree left"
  else
    say "$n_sweep worktree(s) sweepable, $(human_kb "$reclaim") to reclaim · $kept kept · $n_gone of $n_runs runs had no worktree left"
  fi
  say "  kept: $n_open open · $n_closed closed · $n_dirty dirty · $n_unknown unknown · $n_nopr no-pr · $n_unfinished unfinished"
  return 0
}

# cleanup.sh prunes the repo it just removed a worktree from. This prunes them
# again, once each, after the whole sweep: a stale administrative entry left by
# something else is the same disk lie, and it costs nothing to catch it here.
prune_repos() {
  local repo
  [ -s "$WORK/repos" ] || return 0
  sort -u "$WORK/repos" > "$WORK/repos.uniq"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if git -C "$repo" worktree prune 2>/dev/null; then
      say "  pruned worktree metadata in $repo"
    else
      say "  could not prune $repo — left as it is"
    fi
  done < "$WORK/repos.uniq"
  return 0
}

# ---------------------------------------------------------------------------
# The reap
# ---------------------------------------------------------------------------
# `flutter test` spawns a detached test runner and does not always take it with
# it, and removing the worktree it ran in does not kill it either. Nothing
# legitimate keeps one of these alive for hours, so age is the whole test.
kill_proc() {  # $1 = pid
  kill -TERM "$1" 2>/dev/null || return 1
  # A runner that ignores TERM still has to go.
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$1" 2>/dev/null; then kill -KILL "$1" 2>/dev/null || return 1; fi
  return 0
}

reap_procs() {  # $1 = report | clean
  local mode="$1" pid etime comm secs
  local old=0 young=0 killed=0 stubborn=0

  say "processes: $PROC_MATCH older than $(human_secs "$PROC_AGE")"
  # Read from a file, not a pipe: the counters have to survive the loop.
  ps -Ao pid=,etime=,comm= > "$WORK/ps" 2>/dev/null || : > "$WORK/ps"
  while read -r pid etime comm; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$PPID" ] && continue
    # comm is a full path on macOS and a bare name on Linux; both end in the name.
    case "${comm##*/}" in *"$PROC_MATCH"*) ;; *) continue ;; esac
    secs=$(etime_secs "$etime") || continue
    if [ "$secs" -lt "$PROC_AGE" ]; then
      young=$((young + 1))
      continue
    fi
    old=$((old + 1))
    if [ "$mode" != clean ]; then
      line kill "$pid" "up $(human_secs "$secs")" "$comm"
      continue
    fi
    if kill_proc "$pid"; then
      killed=$((killed + 1))
      line killed "$pid" "up $(human_secs "$secs")" "$comm"
    else
      stubborn=$((stubborn + 1))
      line alive "$pid" "up $(human_secs "$secs") — would not die" "$comm"
    fi
  done < "$WORK/ps"

  if [ "$mode" = clean ]; then
    say "  $killed killed, $stubborn survived, $young younger than $(human_secs "$PROC_AGE") left alone"
  else
    say "  $old to kill, $young younger than $(human_secs "$PROC_AGE") left alone"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# One pass
# ---------------------------------------------------------------------------
pass() {  # $1 = report | clean
  say "$(date '+%Y-%m-%d %H:%M:%S') · $1 · $RUNS"
  if [ "$1" = clean ]; then
    [ -r "$CLEANUP" ] || fail "cannot read $CLEANUP — re-run install.sh"
  fi
  gh_probe
  sweep_runs "$1"
  [ "$1" = clean ] && prune_repos
  echo
  reap_procs "$1"
  if [ "$1" != clean ]; then
    echo
    say "--report touched nothing. janitor.sh --clean does the above."
    return 0
  fi
  # A sweep that could not finish is the one thing an operator has to notice.
  [ "$SWEEP_FAILED" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# The daily agent — quartermaster.sh's launchd conventions, one label over
# ---------------------------------------------------------------------------
shquote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

need_macos() {  # $1 = the mode that needs it
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || fail "$1 needs macOS (it manages a launchd LaunchAgent) — this is $(uname -s 2>/dev/null || echo an unknown OS).
Run janitor.sh --report from your own timer instead."
}

# launchd hands a job an almost empty environment, so the agent carries a
# snapshot of the shell that installed it. GH_CONFIG_DIR is swept in — it is
# what decides which account can read a PR's state — while GH_TOKEN is not: gh
# prefers a token over its config dir, and a credential does not belong in a
# generated file.
env_names() {
  { compgen -e 2>/dev/null | grep -E '^(HARNESS|JANITOR)_[A-Za-z0-9_]+$'
    printf '%s\n' HARNESS_DIR GH_CONFIG_DIR HOME PATH
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

write_agent_wrapper() {
  : > "$WRAPPER" || return 1
  chmod 600 "$WRAPPER" || return 1
  {
    cat <<EOF
#!/usr/bin/env bash
# Daily janitor wrapper — generated by janitor.sh, do not edit.
# Mode 600: it carries the environment snapshot of the shell that installed it.
set -u

JAN=$(shquote "$SELF_DIR/janitor.sh")

$(env_snapshot)
EOF
    cat <<'EOF'

echo "[janitor] $(date '+%Y-%m-%d %H:%M:%S') waking up: $*"
exec "$JAN" "$@"
EOF
  } >> "$WRAPPER"
}

write_agent_plist() {  # $1 = mode argument, $2 = hour, $3 = minute
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml_escape "$LABEL_ID")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml_escape "$WRAPPER")</string>
		<string>$(xml_escape "$1")</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$2</integer>
		<key>Minute</key>
		<integer>$3</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
</dict>
</plist>
EOF
}

install_agent() {  # $1 = the mode the agent runs in
  local hour minute
  need_macos "--install"
  case "$AT" in
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
    *) fail "JANITOR_AT must be HH:MM — got [$AT]" ;;
  esac
  hour=$(printf '%s' "${AT%%:*}" | sed 's/^0//'); hour="${hour:-0}"
  minute=$(printf '%s' "${AT##*:}" | sed 's/^0//'); minute="${minute:-0}"
  { [ "$hour" -le 23 ] && [ "$minute" -le 59 ]; } || fail "JANITOR_AT is not a time of day: [$AT]"

  mkdir -p "$JAN_DIR" "$AGENTS_DIR" || fail "cannot create $JAN_DIR / $AGENTS_DIR"
  # Re-installing is how the trust dial is flipped, so an existing agent is
  # replaced rather than refused.
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  write_agent_wrapper || fail "cannot write $WRAPPER"
  write_agent_plist "$1" "$hour" "$minute" || { rm -f "$WRAPPER" "$PLIST"; fail "cannot write $PLIST"; }
  launchctl bootstrap "gui/$(id -u)" "$PLIST" \
    || { rm -f "$WRAPPER" "$PLIST"; fail "launchctl could not load $PLIST"; }

  echo "[janitor] installed — every day at $AT, mode $1"
  echo "[janitor]   agent   $LABEL_ID"
  echo "[janitor]   wrapper $WRAPPER (mode 600 — holds an env snapshot)"
  echo "[janitor]   plist   $PLIST"
  echo "[janitor]   log     $AGENT_LOG"
  if [ "$1" = "--report" ]; then
    echo "[janitor] It only reports. When you trust it, flip the dial:"
    echo "[janitor]   janitor.sh --install --clean"
    echo "[janitor] (or edit the third <string> in the plist and reload it)."
  fi
  echo "[janitor] Remove: janitor.sh --uninstall"
}

uninstall_agent() {
  need_macos "--uninstall"
  if [ ! -e "$PLIST" ] && [ ! -e "$WRAPPER" ]; then
    echo "[janitor] nothing installed"
    return 0
  fi
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$WRAPPER"
  echo "[janitor] uninstalled — agent, plist and wrapper removed (the log in $JAN_DIR is kept)"
}

# ---------------------------------------------------------------------------
main() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/janitor.XXXXXX") || fail "cannot create a work dir"
  case "${1:-}" in
    ''|--report) [ $# -le 1 ] || usage; pass report ;;
    --clean)     [ $# -eq 1 ] || usage; pass clean ;;
    --install)
      case "${2:---report}" in
        --report|--clean) [ $# -le 2 ] || usage; install_agent "${2:---report}" ;;
        *) echo "--install takes --report or --clean: $2" >&2; echo >&2; usage ;;
      esac
      ;;
    --uninstall) [ $# -eq 1 ] || usage; uninstall_agent ;;
    -h|--help)   usage ;;
    *)           echo "unknown option: $1" >&2; echo >&2; usage ;;
  esac
}

main "$@"
