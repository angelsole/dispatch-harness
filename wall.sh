#!/usr/bin/env bash
# Ghost Shift — the office-TV dashboard for dispatch runs. Serves one page that
# shows what every agent is doing right now, live, read-only: it visualises the
# run dirs the pipeline already writes and never dispatches anything.
#
# Point a fullscreen browser on the TV at this machine's tailnet address. Zero
# dependencies beyond node (>= 20) and zero build step.
#
# The wall is a city at night. Each project is a tower — named by reversing the
# worktree path run-task.sh records — and each run is a lit car climbing it, its
# floor being its pipeline stage. A blocked run puts a searchlight over its
# tower. Whoever dispatched a run appears only as a tinted light on its car.
#
# The skyline is live: a finished run gets one short completion moment and then
# leaves it, and a tower with nothing left standing in it leaves too.
#
# Usage:
#   wall.sh                             serve ~/.claude/harness/runs on :4711
#   wall.sh --port 8080                 listen on another port
#   wall.sh --host 127.0.0.1            bind to one interface (default 0.0.0.0)
#   wall.sh --runs wall/fixtures/runs   serve the staged fixtures instead
#   wall.sh --crew angel,reinier,emre   declare the roster (accepted for
#                                       compatibility; it adds nothing to the
#                                       skyline — crew tints are stable already)
#
# Env:
#   HARNESS_DIR     where runs live      (default: ~/.claude/harness)
#   WALL_CREW       default roster       (same list as --crew)
#   WALL_POLL_MS    disk re-read cadence (default: 1000)
#
# There is no auth: the wall is meant to sit behind your tailnet, and it exposes
# only what is already on this machine's disk. Do not port-forward it publicly.
set -u

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

SRC="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
PORT=4711
HOST=0.0.0.0
RUNS="$HARNESS_DIR/runs"
CREW="${WALL_CREW:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 || true ;;
    --host) HOST="${2:-}"; shift 2 || true ;;
    --runs) RUNS="${2:-}"; shift 2 || true ;;
    --crew) CREW="${2:-}"; shift 2 || true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) echo "wall.sh: --port must be a number" >&2; exit 2 ;; esac
[ -n "$HOST" ] || { echo "wall.sh: --host must not be empty" >&2; exit 2; }
[ -n "$RUNS" ] || { echo "wall.sh: --runs must not be empty" >&2; exit 2; }

command -v node >/dev/null 2>&1 || {
  echo "wall.sh: node (>= 20) is required — https://nodejs.org" >&2; exit 1
}
# A missing runs dir is not fatal: the wall renders its idle state and picks the
# directory up the moment the first dispatch creates it.
[ -d "$RUNS" ] || echo "wall.sh: $RUNS does not exist yet — showing the idle screen"

exec env WALL_PORT="$PORT" WALL_HOST="$HOST" WALL_RUNS="$RUNS" WALL_CREW="$CREW" \
  node "$SRC/wall/server.js"
