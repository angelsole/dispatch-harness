#!/usr/bin/env bash
# Which model is handling what, right now — across all dispatch runs.
# Usage: status.sh            one-shot table
#        status.sh <TICKET>   full timeline of one run
#        status.sh --watch    live dashboard: the table plus each run's actor and
#                             current activity, redrawn in place every 2s
#                             (HARNESS_WATCH_INTERVAL overrides). The zero-config
#                             alternative to wiring statusline.sh.
set -u
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH
RUNS="$HARNESS_DIR/runs"

fmt() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# --- live dashboard ----------------------------------------------------------
# One frame of the dashboard. $1 = max rows to print (newest-first, the rest are
# summarised) so a machine with hundreds of runs still fits on one screen.
watch_render() {
  local max="$1" interval="$2" now name dir ts stagetext started act inst shown=0 total=0
  now=$(date +%s)
  printf '%sdispatch%s %s%s · every %ss · ctrl-c to quit%s\n\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$(date '+%H:%M:%S')" "$interval" "$C_RESET"
  if [ ! -d "$RUNS" ]; then printf 'no runs yet\n'; return 0; fi
  printf '%s%-24s %-11s %-34s %-30s %-9s %s%s\n' \
    "$C_DIM" "RUN" "ACTOR" "STAGE" "ACTIVITY" "IN STAGE" "TOTAL" "$C_RESET"
  # Newest-first: run-id dir names are ticket IDs / adhoc slugs (no whitespace),
  # so word-splitting ls -t output is safe here.
  # shellcheck disable=SC2045
  for name in $(ls -t "$RUNS" 2>/dev/null); do
    dir="$RUNS/$name"
    [ -f "$dir/status" ] || continue
    total=$((total + 1))
    [ "$shown" -ge "$max" ] && continue
    shown=$((shown + 1))
    ts=''; stagetext=''
    read -r ts stagetext < "$dir/status" || true
    case "$ts" in ''|*[!0-9]*) ts="$now" ;; esac
    started=$(cat "$dir/started" 2>/dev/null || echo "$ts")
    case "$started" in ''|*[!0-9]*) started="$ts" ;; esac
    act=''; [ -f "$dir/activity" ] && { IFS= read -r act < "$dir/activity" || true; }
    harness_actor "$stagetext"
    # A stage timer only means something while something is working: run_alive
    # (driver.pid + heartbeat, lib/common.sh) separates a slow gate from a dead
    # driver, which used to render identically. "Cannot tell" (a run dir from
    # before those files existed) renders exactly as it always did.
    case "$stagetext" in
      done:*) inst="-" ;;
      deferred:*|waiting*|'sync failed'*) inst="$(fmt $((now - ts)))" ;;
      *)
        if run_alive "$dir"; then inst="$(fmt $((now - ts)))"
        elif [ $? -eq 1 ]; then inst="DEAD $(fmt $((now - ts)))"
        else inst="$(fmt $((now - ts)))"; fi
        ;;
    esac
    printf '%-24s %s%-11s%s %-34s %s%-30s%s %-9s %s\n' \
      "${name:0:24}" "$HARNESS_ACTOR_COLOR" "$HARNESS_ACTOR" "$C_RESET" \
      "${stagetext:0:34}" "$C_DIM" "${act:0:30}" "$C_RESET" \
      "$inst" "$(fmt $((now - started)))"
  done
  [ "$total" -eq 0 ] && printf 'no runs yet\n'
  [ "$total" -gt "$shown" ] && \
    printf '%s… %d more — status.sh for the full table%s\n' "$C_DIM" "$((total - shown))" "$C_RESET"
  return 0
}

watch_loop() {
  local interval="${HARNESS_WATCH_INTERVAL:-2}" rows max frame
  if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$interval" =~ ^0+([.]0+)?$ ]]; then
    echo "status.sh: HARNESS_WATCH_INTERVAL must be a positive number" >&2
    return 2
  fi
  trap 'printf "\033[?25h"' EXIT
  trap 'exit 0' INT TERM
  printf '\033[?25l'
  while :; do
    rows=$(tput lines 2>/dev/null || true)
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    max=$((rows - 5)); [ "$max" -lt 1 ] && max=1
    frame=$(watch_render "$max" "$interval")
    # Home + erase-below redraws over the previous frame instead of scrolling a
    # new copy onto the screen, which is what makes a `while; do status.sh` loop
    # unreadable.
    printf '\033[H\033[J%s\n' "$frame"
    sleep "$interval"
  done
}

if [ "${1:-}" = "--watch" ]; then
  # statusline.sh owns the stage -> actor mapping (single source of truth for
  # the contract with run-task.sh's stage()) and the colors; degrade to a blank
  # actor column if this install predates it.
  # shellcheck source=statusline.sh
  . "$(cd "$(dirname "$0")" && pwd)/statusline.sh" 2>/dev/null || {
    C_RESET=''; C_BOLD=''; C_DIM=''
    harness_actor() { HARNESS_ACTOR='-'; HARNESS_ACTOR_COLOR=''; }
  }
  watch_loop
  exit $?
fi

[ -d "$RUNS" ] || { echo "no runs yet"; exit 0; }

if [ $# -eq 1 ] && [ "${1:-}" != "--doctor" ]; then
  dir="$RUNS/$1"
  [ -d "$dir" ] || { echo "no run named $1" >&2; exit 1; }
  echo "== $1 timeline =="
  cat "$dir/timeline" 2>/dev/null || echo "(no timeline yet)"
  [ -f "$dir/result.json" ] && { echo "== result =="; jq -r 'to_entries[] | "\(.key): \(.value)"' "$dir/result.json"; }
  # The verifier's advisory score, spelled out: the generic dump above renders
  # the whole metrics object as one unreadable line, and this is the one number
  # in it a human reads on purpose. Silent on every run that has none.
  [ -f "$dir/result.json" ] && jq -r '.metrics.verifier // empty
    | select(.score != null)
    | "verifier: \(.score)"
      + (if .at_implementer == null then "" else " (implementer \(.at_implementer))" end)
      + " · \((.criteria // []) | length) criteria"
      + (if (.model // "") == "" then "" else " · \(.model)" end)' \
    "$dir/result.json" 2>/dev/null
  exit 0
fi

# The exact command that resumes a dead run, derived from what the run dir
# already records. The worktree is "<repo>-<run-id lowercased>", so the repo is
# the worktree minus that suffix; the branch comes from result.json or, absent
# that, from the worktree's own HEAD.
redispatch_command() {  # $1 = run dir, $2 = run name
  local wt branch lc repo
  wt=$(jq -r '.worktree // empty' "$1/result.json" 2>/dev/null)
  [ -n "$wt" ] || wt=$(cat "$1/worktree" 2>/dev/null)
  branch=$(jq -r '.branch // empty' "$1/result.json" 2>/dev/null)
  [ -n "$branch" ] || branch=$(git -C "${wt:-/nonexistent}" rev-parse --abbrev-ref HEAD 2>/dev/null)
  lc=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  repo="${wt%-$lc}"
  if [ -n "$repo" ] && [ "$repo" != "$wt" ] && [ -n "$branch" ]; then
    printf '  %s/run-task.sh %s %s %s\n' "$HARNESS_DIR" "$2" "$repo" "$branch"
  else
    printf '  %s — cannot derive the re-dispatch args (see %s)\n' "$2" "$1"
  fi
}

dead_footer() {  # $1 = space-separated dead run names
  [ -n "$1" ] || return 0
  echo
  echo "STALLED — no driver process and no heartbeat. The worktree and the worker"
  echo "session survive, so a re-dispatch resumes where it stopped:"
  local name
  for name in $1; do redispatch_command "$RUNS/$name" "$name"; done
}

# --doctor: every run with a stage, no driver and a cold heartbeat, with the
# exact command that resumes it. Read-only on purpose: the janitor is the only
# thing that rewrites another process's status file.
if [ "${1:-}" = "--doctor" ]; then
  now=$(date +%s)
  dead=""
  # shellcheck disable=SC2045
  for name in $(ls -t "$RUNS" 2>/dev/null); do
    dir="$RUNS/$name"
    [ -f "$dir/status" ] || continue
    read -r ts stagetext < "$dir/status"
    case "$stagetext" in done:*|deferred:*|waiting*|'sync failed'*) continue ;; esac
    run_alive "$dir"; [ $? -eq 1 ] || continue
    dead="$dead $name"
    printf '%-26s %-46s dead %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))"
  done
  if [ -n "$dead" ]; then dead_footer "$dead"; else echo "no dead runs"; fi
  exit 0
fi

now=$(date +%s)
found=0
dead=""
printf '%-26s %-46s %-12s %-9s %s\n' "RUN" "STAGE" "IN STAGE" "TOTAL" "SCORE"
# Newest-first: run-id dir names are ticket IDs / adhoc slugs (no whitespace),
# so word-splitting ls -t output is safe here.
# shellcheck disable=SC2045
for name in $(ls -t "$RUNS" 2>/dev/null); do
  dir="$RUNS/$name"
  [ -f "$dir/status" ] || continue
  found=1
  read -r ts stagetext < "$dir/status"
  started=$(cat "$dir/started" 2>/dev/null || echo "$ts")
  # The verifier's advisory score, blank on every run that never got one — which
  # is every run before this existed, and every run whose verifier was off.
  score=$(jq -r '.metrics.verifier.score // empty' "$dir/result.json" 2>/dev/null || echo "")
  case "$stagetext" in
    # No process is expected to be alive for any of these, and for `waiting` /
    # `sync failed` the growing timer is the point (how long it has been
    # blocked). `sync failed` is non-terminal on purpose — but it is not a
    # stalled stage either.
    done:*)     printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "-" "$(fmt $((ts - started)))" "$score" ;;
    deferred:*) printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "armed" "$(fmt $((now - started)))" "$score" ;;
    waiting*|'sync failed'*)
                printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))" "$(fmt $((now - started)))" "$score" ;;
    *)
      # A stage timer only means something while something is working. run_alive
      # (driver.pid + heartbeat, lib/common.sh): 0 alive, 1 dead, 2 cannot tell
      # — and "cannot tell" (a run dir from before those files existed) renders
      # exactly as it always did rather than being slandered as dead.
      if run_alive "$dir"; then
        printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))" "$(fmt $((now - started)))" "$score"
      elif [ $? -eq 1 ]; then
        printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "DEAD $(fmt $((now - ts)))" "$(fmt $((now - started)))" "$score"
        dead="$dead $name"
      else
        printf '%-26s %-46s %-12s %-9s %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))" "$(fmt $((now - started)))" "$score"
      fi
      ;;
  esac
done
[ $found -eq 1 ] || echo "no runs yet"
dead_footer "$dead"
