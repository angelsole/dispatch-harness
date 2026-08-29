#!/usr/bin/env bash
# Ghost Shift — the office-TV dashboard for dispatch runs. Serves one page that
# shows what every agent is doing right now, live, read-only: it visualises the
# run dirs the pipeline already writes and never dispatches anything.
#
# Point a fullscreen browser on the TV at this machine's tailnet address. One
# node (>= 20) server, one static page, and everything the page loads ships in
# this repo — no build step, no npm at runtime, no CDN, and no request that
# leaves the machine.
#
# The wall is a city at night. Each project is a tower — named by reversing the
# worktree path run-task.sh records — and each run is a lit car climbing it, its
# floor being its pipeline stage. A blocked run puts a searchlight over its
# tower. Whoever dispatched a run appears only as a tinted light on its car.
#
# The skyline is live: a finished run gets one short completion moment and then
# leaves it, and a tower with nothing left standing in it leaves too.
#
# The district under it accretes instead. Every run that reaches `done: ready`
# since Monday 00:00 local is a permanent building — type from the repo family,
# height from the diff, plot from the run id — so by Friday the city IS the
# week's shipped work. Last week's stands behind it as a flat ghost, and Monday
# 00:00 empties the plain again.
#
# The city's memory is one append-only JSONL ledger the wall owns (--city, by
# default beside the runs dir). Run dirs only ever DISCOVER a ship: cleanup.sh
# and mirror removal delete them, and a building has to outlive that. Deleting
# the ledger razes the city; nothing else does. Serving the repo's own fixtures
# with no ledger yet seeds a week's district into it, so the demo has one.
#
# Usage:
#   wall.sh                             serve ~/.claude/harness/runs on :4711
#   wall.sh --port 8080                 listen on another port
#   wall.sh --host 127.0.0.1            bind to one interface (default 0.0.0.0)
#   wall.sh --runs wall/fixtures/runs   serve the staged fixtures instead
#   wall.sh --city /tmp/demo.jsonl      keep the city's memory somewhere else
#   wall.sh --crew angel,reinier,emre   declare the roster (accepted for
#                                       compatibility; it adds nothing to the
#                                       skyline — crew tints are stable already)
#   wall.sh --init-token [--url URL]    make this the team's wall: write a
#                                       random ingest token to
#                                       <HARNESS_DIR>/wall-ingest-token (600)
#                                       and this wall's URL to
#                                       <HARNESS_DIR>/wall-url (the Tailscale
#                                       IP + port unless --url says otherwise),
#                                       then exit. Laptops join with
#                                       `./install.sh --team <ssh host>`.
#
# Env:
#   HARNESS_DIR     where runs live      (default: ~/.claude/harness)
#   WALL_CITY       the city ledger      (default: <runs>/../wall-city.jsonl)
#   WALL_CREW       default roster       (same list as --crew)
#   WALL_POLL_MS    disk re-read cadence (default: 1000)
#
# Fan-in, so runs on other machines reach this board (see docs/wall.md#ingest):
#   WALL_INGEST_TOKEN  the shared secret runs send as `Authorization: Bearer`.
#                      Unset (the default) and every ingest route 404s: the wall
#                      is read-only and accepts nothing at all. When unset, the
#                      first line of <HARNESS_DIR>/wall-ingest-token is used if
#                      that file exists — what --init-token writes, so a launchd
#                      plist never has to carry the secret.
#   WALL_INGEST_FILE   where reports are kept across a restart
#                      (default: <runs>/../wall-ingest.json)
#
# The same server also serves /console — the functional ops board over the same
# run data: what each agent is doing right now, what is blocked, and the attach
# command to step into it. Not a city; a flight board.
#
# Query string:
#   ?world=canvas   draw the city with the vendored Phaser 4 in wall/vendor/
#                   rather than in CSS. Same city, same street; the DOM world is
#                   the default and never requests the engine.
#   ?cinema=1       start the ambient camera at once (?cinema=0 keeps it off).
#                   The `c` key toggles it and any other input dismisses it;
#                   prefers-reduced-motion outranks all three.
#
# There is no auth: the wall is meant to sit behind your tailnet, and it exposes
# only what is already on this machine's disk. Do not port-forward it publicly.
set -u

_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH

usage() { harness_usage "$0"; }

SRC="$(cd "$(dirname "$0")" && pwd)"
PORT=4711
HOST=0.0.0.0
RUNS="$HARNESS_DIR/runs"
CREW="${WALL_CREW:-}"
# Empty means "let the server put it beside the runs dir". Whether the flag was
# passed is tracked separately, so `--city ""` is caught as the typo it is
# rather than silently sending the city's memory back to the default path.
CITY="${WALL_CITY:-}"
CITY_GIVEN=0
INIT_TOKEN=0
URL=""
TOKEN_FILE="$HARNESS_DIR/wall-ingest-token"
URL_FILE="$HARNESS_DIR/wall-url"

# Every flag here takes a value. `shift 2` with only the flag left shifts
# NOTHING and returns non-zero, so a trailing `wall.sh --port` used to spin this
# loop forever on the same argument; the value is checked before the shift
# instead. $# is passed in because the check happens inside a function.
need() {  # $1 = flag, $2 = args remaining
  [ "$2" -ge 2 ] || { echo "wall.sh: $1 needs a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port) need --port $#; PORT="$2"; shift 2 ;;
    --host) need --host $#; HOST="$2"; shift 2 ;;
    --runs) need --runs $#; RUNS="$2"; shift 2 ;;
    --city) need --city $#; CITY="$2"; CITY_GIVEN=1; shift 2 ;;
    --crew) need --crew $#; CREW="$2"; shift 2 ;;
    --init-token) INIT_TOKEN=1; shift ;;
    --url) need --url $#; URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) echo "wall.sh: --port must be a number" >&2; exit 2 ;; esac
[ -n "$HOST" ] || { echo "wall.sh: --host must not be empty" >&2; exit 2; }
[ -n "$RUNS" ] || { echo "wall.sh: --runs must not be empty" >&2; exit 2; }
[ "$CITY_GIVEN" -eq 0 ] || [ -n "$CITY" ] || {
  echo "wall.sh: --city must not be empty" >&2; exit 2; }

# The Tailscale address is the one every teammate's laptop can reach; the CLI
# lives inside the app bundle on macOS and on PATH on Linux.
wall_tailscale_ip() {
  local ts
  ts=$(command -v tailscale 2>/dev/null) || ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [ -x "$ts" ] || return 1
  "$ts" ip -4 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

if [ "$INIT_TOKEN" -eq 1 ]; then
  mkdir -p "$HARNESS_DIR" || exit 1
  if [ -s "$TOKEN_FILE" ]; then
    echo "keep  $TOKEN_FILE (exists — the team's laptops already carry it)"
  else
    # 48 hex chars from the kernel; od is POSIX, so no openssl dependency.
    ( umask 077; head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE" \
        && printf '\n' >> "$TOKEN_FILE" ) \
      || { echo "wall.sh: could not write $TOKEN_FILE" >&2; exit 1; }
    chmod 600 "$TOKEN_FILE"
    echo "wrote $TOKEN_FILE (mode 600)"
  fi
  if [ -z "$URL" ]; then
    ip=$(wall_tailscale_ip) || ip=""
    URL="http://${ip:-$(hostname -s)}:$PORT"
  fi
  printf '%s\n' "$URL" > "$URL_FILE" || { echo "wall.sh: could not write $URL_FILE" >&2; exit 1; }
  echo "wrote $URL_FILE ($URL)"
  echo
  echo "Restart the wall so it reads the token (launchctl kickstart -k gui/\$(id -u)/<label>, or re-run wall.sh)."
  echo "On each laptop that should report here, from its dispatch-harness checkout:  ./install.sh --team <ssh host of this machine>"
  exit 0
fi

if [ -z "${WALL_INGEST_TOKEN:-}" ] && [ -r "$TOKEN_FILE" ]; then
  WALL_INGEST_TOKEN=$(head -n 1 "$TOKEN_FILE" | tr -d '[:space:]')
fi

command -v node >/dev/null 2>&1 || {
  echo "wall.sh: node (>= 20) is required — https://nodejs.org" >&2; exit 1
}
# A missing runs dir is not fatal: the wall renders its idle state and picks the
# directory up the moment the first dispatch creates it.
[ -d "$RUNS" ] || echo "wall.sh: $RUNS does not exist yet — showing the idle screen"

exec env WALL_PORT="$PORT" WALL_HOST="$HOST" WALL_RUNS="$RUNS" WALL_CREW="$CREW" \
  WALL_INGEST_TOKEN="${WALL_INGEST_TOKEN:-}" \
  WALL_CITY="$CITY" node "$SRC/wall/server.js"
