#!/usr/bin/env bash
# Which model is handling what, right now — across all dispatch runs.
# Usage: status.sh            one-shot table
#        status.sh <TICKET>   full timeline of one run
#        status.sh --watch    live dashboard: the table plus each run's actor and
#                             current activity, redrawn in place every 2s
#                             (HARNESS_WATCH_INTERVAL overrides). The zero-config
#                             alternative to wiring statusline.sh.
set -u
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"

fmt() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

# --- live dashboard ----------------------------------------------------------
# One frame of the dashboard. $1 = max rows to print (newest-first, the rest are
# summarised) so a machine with hundreds of runs still fits on one screen.
watch_render() {
  local max="$1" now name dir ts stagetext started act inst shown=0 total=0
  now=$(date +%s)
  printf '%sdispatch%s %s%s · every %ss · ctrl-c to quit%s\n\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$(date '+%H:%M:%S')" "${HARNESS_WATCH_INTERVAL:-2}" "$C_RESET"
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
    case "$stagetext" in done:*) inst="-" ;; *) inst="$(fmt $((now - ts)))" ;; esac
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
  trap 'printf "\033[?25h"' EXIT
  trap 'exit 0' INT TERM
  printf '\033[?25l'
  while :; do
    rows=$(tput lines 2>/dev/null || true)
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    max=$((rows - 5)); [ "$max" -lt 1 ] && max=1
    frame=$(watch_render "$max")
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
  exit 0
fi

[ -d "$RUNS" ] || { echo "no runs yet"; exit 0; }

if [ $# -eq 1 ]; then
  dir="$RUNS/$1"
  [ -d "$dir" ] || { echo "no run named $1" >&2; exit 1; }
  echo "== $1 timeline =="
  cat "$dir/timeline" 2>/dev/null || echo "(no timeline yet)"
  [ -f "$dir/result.json" ] && { echo "== result =="; jq -r 'to_entries[] | "\(.key): \(.value)"' "$dir/result.json"; }
  exit 0
fi

now=$(date +%s)
found=0
printf '%-26s %-46s %-12s %s\n' "RUN" "STAGE" "IN STAGE" "TOTAL"
# Newest-first: run-id dir names are ticket IDs / adhoc slugs (no whitespace),
# so word-splitting ls -t output is safe here.
# shellcheck disable=SC2045
for name in $(ls -t "$RUNS" 2>/dev/null); do
  dir="$RUNS/$name"
  [ -f "$dir/status" ] || continue
  found=1
  read -r ts stagetext < "$dir/status"
  started=$(cat "$dir/started" 2>/dev/null || echo "$ts")
  case "$stagetext" in
    done:*) printf '%-26s %-46s %-12s %s\n' "$name" "$stagetext" "-" "$(fmt $((ts - started)))" ;;
    *)      printf '%-26s %-46s %-12s %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))" "$(fmt $((now - started)))" ;;
  esac
done
[ $found -eq 1 ] || echo "no runs yet"
