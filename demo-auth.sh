#!/usr/bin/env bash
# One-time (per app) login capture for demo recordings.
# Starts the app's dev server on the demo port (4173), opens a real browser for
# you to log in like a human (email/password or Google — anything works), then
# saves the session to ~/.claude/harness/auth/<repo>.json. The demo stage
# passes it to `shot-scraper video --auth` automatically.
# Re-run only when recordings start landing on the login screen again.
#
# Usage: demo-auth.sh <repo-path>       e.g. demo-auth.sh "$HOME/code/myapp"
set -u
[ $# -ge 1 ] || { echo "usage: demo-auth.sh <repo-path>" >&2; exit 2; }
REPO="${1%/}"
[ -d "$REPO" ] || { echo "no such repo: $REPO" >&2; exit 1; }
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
SHOT_BIN="${SHOT_BIN:-$HOME/.local/bin/shot-scraper}"
AUTH_DIR="$HARNESS_DIR/auth"; mkdir -p "$AUTH_DIR"
OUT="$AUTH_DIR/$(basename "$REPO").json"

. "$HARNESS_DIR/repos.conf.sh"
repo_config "$REPO"
PORT="${DEMO_PORT:-5173}"
[ -n "${DEMO_DEV_CMD:-}" ] || DEMO_DEV_CMD="npm run dev -- --port $PORT"

# Reuse an already-running dev server on the port (same app, same origin);
# only start (and later kill) our own if the port is free.
if curl -so /dev/null "http://localhost:$PORT"; then
  echo "[demo-auth] reusing dev server already running on :$PORT"
else
  echo "[demo-auth] starting dev server: $DEMO_DEV_CMD (in $REPO)"
  (cd "$REPO" && exec bash -c "$DEMO_DEV_CMD") > /tmp/demo-auth-server.log 2>&1 &
  SRV=$!
  cleanup() { kill "$SRV" 2>/dev/null; lsof -ti tcp:"$PORT" 2>/dev/null | xargs kill 2>/dev/null; }
  trap cleanup EXIT
  for i in $(seq 1 60); do
    curl -so /dev/null "http://localhost:$PORT" && break
    [ $i -eq 60 ] && { echo "[demo-auth] server never came up (see /tmp/demo-auth-server.log)" >&2; exit 1; }
    sleep 1
  done
fi

# No terminal interaction: the capture script auto-detects the login and saves.
PY="$HOME/.local/share/uv/tools/shot-scraper/bin/python"
[ -x "$PY" ] || PY=python3
echo "[demo-auth] browser opening — just log in; saving is automatic."
"$PY" "$HARNESS_DIR/auth-capture.py" "http://localhost:$PORT" "$OUT"
RC=$?
[ $RC -eq 0 ] && echo "[demo-auth] done — demos will use this session automatically."
exit $RC
