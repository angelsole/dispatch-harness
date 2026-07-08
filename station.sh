#!/usr/bin/env bash
# The dispatch station — a parked orchestrator session you control from your
# phone. Run this in a dedicated terminal tab; it reattaches to the existing
# station if one is already running (safe to re-run after closing the tab).
#
# Inside the session, once: /remote-control  → scan the QR with the Claude app.
# Discipline: /clear after each verdict to keep the planner's context cheap.
#
# Starts in DISPATCH_STATION_DIR (default: $HOME) — set it to wherever your
# repos live. On macOS, caffeinate -i keeps the machine awake while parked; on
# other platforms it is skipped automatically.
STATION_DIR="${DISPATCH_STATION_DIR:-$HOME}"
CAFFEINATE=""
command -v caffeinate >/dev/null 2>&1 && CAFFEINATE="caffeinate -i"
exec tmux new-session -A -s dispatch "cd \"$STATION_DIR\" && exec $CAFFEINATE claude"
