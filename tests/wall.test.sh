#!/usr/bin/env bash
# Smoke test for the wall: wall.sh's flags, the static page, the JSON snapshot
# endpoint, live SSE updates, and tolerance of half-written run dirs.
#
# Hermetic: fixtures are seeded into a temp root (the committed
# wall/fixtures/runs is only ever read), every server binds --port 0 so the OS
# picks a free port, and nothing outside the temp root is written.
#
# Usage: bash tests/wall.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
WALL="$SRC/wall.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wall-test.XXXXXX")"
RUNS="$ROOT/runs"
PIDS=""
cleanup() {
  # shellcheck disable=SC2086  # PIDS is a deliberate list of background pids
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
grep_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected [$2])"; else ok "$3"; fi; }

if ! command -v node >/dev/null 2>&1; then
  echo "  FAIL wall: node is required to run this suite"
  echo; printf 'wall smoke: 0 passed, 1 failed\n'; exit 1
fi

# --- the JS parses -----------------------------------------------------------
echo "== wall: static checks =="
if [ -x "$WALL" ]; then ok "wall.sh is executable"; else bad "wall.sh is executable"; fi
for f in wall/server.js wall/wall.js wall/fixtures/seed.js; do
  if node --check "$SRC/$f" 2>/dev/null; then ok "node --check $f"; else bad "node --check $f"; fi
done
# The page must not pull anything in from off-origin: the TV may only see the
# tailnet, so a CDN font or script would render as a blank. XML namespace URIs
# (w3.org) are identifiers, never fetched.
PAGE_SRC="$(cat "$SRC/wall/index.html" "$SRC/wall/wall.css" "$SRC/wall/wall.js")"
OFFSITE="$(printf '%s' "$PAGE_SRC" | grep -oE 'https?://[A-Za-z0-9./_-]+' \
  | grep -v '^https\{0,1\}://www\.w3\.org/' | sort -u | tr '\n' ' ')"
if [ -z "$OFFSITE" ]; then
  ok "assets: no off-origin URLs"
else
  bad "assets: off-origin URLs in the page: $OFFSITE"
fi

# --- serve the fixtures -------------------------------------------------------
# Start a wall on an OS-assigned port. Sets PORT_OUT (empty if it never came
# up); not a command substitution, so the background pid lands in the real PIDS.
# $1 = runs dir, $2 = log file
serve() {
  bash "$WALL" --runs "$1" --host 127.0.0.1 --port 0 > "$2" 2>&1 &
  PIDS="$PIDS $!"
  PORT_OUT=''
  local i=0
  while [ "$i" -lt 100 ]; do
    PORT_OUT=$(sed -n 's|.*http://[^:]*:\([0-9][0-9]*\)/.*|\1|p' "$2" 2>/dev/null | head -1)
    [ -n "$PORT_OUT" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$PORT_OUT" ] || sed 's/^/       /' "$2" 2>/dev/null
  return 0
}
get() { curl -s --max-time 5 "http://127.0.0.1:$1$2"; }

echo "== wall: page and data endpoints =="
node "$SRC/wall/fixtures/seed.js" "$RUNS" >/dev/null
serve "$RUNS" "$ROOT/server.log"; PORT="$PORT_OUT"
if [ -n "$PORT" ]; then ok "wall.sh starts and reports its port"; else bad "wall.sh starts and reports its port"; fi
[ -n "$PORT" ] || { echo; cat "$ROOT/server.log"; printf 'wall smoke: %d passed, %d failed\n' "$pass" "$((fail+1))"; exit 1; }

PAGE="$(get "$PORT" /)"
grep_ok "$PAGE" "THE WALL"    "page: renders the wall document"
grep_ok "$PAGE" "wall.css"    "page: links its stylesheet"
grep_ok "$PAGE" "wall.js"     "page: links its script"
grep_ok "$PAGE" "NO ACTIVE DISPATCH" "page: ships the idle state"
check "page: css is served"   "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/wall.css")" "200"
check "page: js is served"    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/wall.js")"  "200"
check "page: unknown path 404s" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/etc/passwd")" "404"

API="$(get "$PORT" /api/runs)"
check "api: valid JSON" "$(printf '%s' "$API" | jq -r 'type')" "object"
check "api: every fixture run is listed" "$(printf '%s' "$API" | jq '.runs | length')" "5"
for id in OLYX-1631 OLYX-1655 OLYX-1642 OLYX-1598 OLYX-1604; do
  grep_ok "$API" "\"$id\"" "api: lists $id"
done

state_of() { printf '%s' "$API" | jq -r --arg id "$1" '.runs[] | select(.id==$id) | .'"$2"; }
check "state: mid-implement run is active"  "$(state_of OLYX-1631 state)" "active"
check "state: waiting run raises the alarm" "$(state_of OLYX-1642 state)" "alarm"
check "state: done: ready is ready"         "$(state_of OLYX-1598 state)" "ready"
check "state: done: rejected is failed"     "$(state_of OLYX-1604 state)" "failed"

echo "== wall: stage -> actor attribution =="
check "actor: implementing -> Opus"  "$(state_of OLYX-1631 actor)"    "Opus"
check "actor: implementing key"      "$(state_of OLYX-1631 actorKey)" "opus"
check "actor: review -> Codex"       "$(state_of OLYX-1655 actor)"    "Codex"
check "actor: review key"            "$(state_of OLYX-1655 actorKey)" "codex"
check "actor: waiting -> needs input" "$(state_of OLYX-1642 actor)"   "needs input"
check "actor: done -> done"          "$(state_of OLYX-1598 actor)"    "done"

echo "== wall: run detail =="
check "detail: title comes from brief.md" \
  "$(state_of OLYX-1631 title)" "Invoice export endpoint — CSV + XLSX"
check "detail: activity is the worker's last action" \
  "$(state_of OLYX-1631 activity)" "⏺ Edit src/invoices/export.ts"
check "detail: feed tail is shipped" "$(state_of OLYX-1631 'feed | length')" "9"
check "detail: feed lines keep their timestamp" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="OLYX-1631") | .feed[-1].t | test("^[0-9]{2}:[0-9]{2}:[0-9]{2}$")')" "true"
check "detail: codex feed lines are attributed" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="OLYX-1655") | .feed[-1].src')" "codex"
check "detail: pr_url surfaces on a ready run" \
  "$(state_of OLYX-1598 prUrl)" "https://github.com/acme/dashboard/pull/812"
check "detail: demo_url surfaces on a ready run" \
  "$(state_of OLYX-1598 demoUrl)" "https://demo.example.net/OLYX-1598/demo.mp4"
check "detail: gate verdict surfaces"  "$(state_of OLYX-1598 gate)" "pass"
check "detail: gate rounds surface"    "$(state_of OLYX-1598 'gateRounds | length')" "2"
check "detail: diff size surfaces"     "$(state_of OLYX-1598 'diff.insertions')" "214"
grep_ok "$(state_of OLYX-1642 blocked)" "Legacy quotes" "detail: the blocking question surfaces"
grep_ok "$(state_of OLYX-1604 reason)"  "nothing evicts" "detail: the rejection reason surfaces"

echo "== wall: ordering =="
ORDER="$(printf '%s' "$API" | jq -r '.runs[].id' | tr '\n' ' ')"
check "order: alarm first, then live oldest-first, then finished" \
  "$ORDER" "OLYX-1642 OLYX-1655 OLYX-1631 OLYX-1598 OLYX-1604 "

# --- live updates -------------------------------------------------------------
# The page never reloads: one SSE stream carries every later frame. Read it in
# the background, change a run on disk, and both a new frame and the new JSON
# must show up.
echo "== wall: live updates =="
SSE="$ROOT/sse.out"
curl -sN --max-time 6 "http://127.0.0.1:$PORT/api/stream" > "$SSE" 2>/dev/null &
SSE_PID=$!
PIDS="$PIDS $SSE_PID"
sleep 1
printf '%s ⏺ Bash npm run gate\n' "$(date '+%H:%M:%S')" >> "$RUNS/OLYX-1631/feed.log"
printf '%s test gate #1 (deterministic — no model)\n' "$(date +%s)" > "$RUNS/OLYX-1631/status"
sleep 2
kill "$SSE_PID" 2>/dev/null || true
wait "$SSE_PID" 2>/dev/null || true

FRAMES=$(grep -c '^event: snapshot' "$SSE" | tr -d ' ')
if [ "$FRAMES" -ge 2 ]; then
  ok "sse: pushes a new frame when a run changes ($FRAMES frames)"
else
  bad "sse: expected >=2 frames (first + change), got $FRAMES"
fi
LAST="$(grep '^data: ' "$SSE" | tail -1 | cut -c7-)"
check "sse: the new stage is in the pushed frame" \
  "$(printf '%s' "$LAST" | jq -r '.runs[] | select(.id=="OLYX-1631") | .actor')" "gate"
grep_ok "$LAST" "npm run gate" "sse: the appended feed line is in the pushed frame"

API="$(get "$PORT" /api/runs)"
check "poll: the snapshot endpoint agrees" "$(state_of OLYX-1631 actorKey)" "gate"

# --- tolerance ----------------------------------------------------------------
# Run dirs are written by live pipelines: any file can be missing, empty or
# caught mid-write. None of that may blank the wall.
echo "== wall: partial and missing files =="
mkdir -p "$RUNS/BARE-1" "$RUNS/EMPTY-1" "$RUNS/JUNK-1"
printf '%s setup: worktree\n' "$(date +%s)" > "$RUNS/BARE-1/status"   # status only
: > "$RUNS/EMPTY-1/status"                                            # caught mid-write
printf '%s implementing — Opus (Claude sub)\n' "$(date +%s)" > "$RUNS/JUNK-1/status"
printf '{"status": "rea' > "$RUNS/JUNK-1/result.json"                 # half-written JSON
printf 'not an epoch\n' > "$RUNS/JUNK-1/started"
mkdir -p "$RUNS/NOTARUN"                                              # no status at all
sleep 1.2
API="$(get "$PORT" /api/runs)"
check "partial: still valid JSON" "$(printf '%s' "$API" | jq -r 'type')" "object"
grep_ok  "$API" "BARE-1"   "partial: a status-only run still renders"
grep_ok  "$API" "JUNK-1"   "partial: a half-written result.json does not drop the run"
grep_not "$API" "NOTARUN"  "partial: a dir with no status is not a run"
grep_ok  "$API" "OLYX-1598" "partial: the healthy runs are untouched"
check "partial: an empty status falls back to stages.log/blank, not a crash" \
  "$(printf '%s' "$API" | jq -r '[.runs[] | select(.id=="EMPTY-1")] | length')" "0"
check "partial: a bad started epoch degrades to the stage time" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="JUNK-1") | (.started != null)')" "true"

echo "== wall: no runs dir at all =="
serve "$ROOT/does-not-exist" "$ROOT/nope.log"; NOPE="$PORT_OUT"
if [ -n "$NOPE" ]; then ok "missing runs dir: server still starts"; else bad "missing runs dir: server still starts"; fi
if [ -n "$NOPE" ]; then
  check "missing runs dir: empty snapshot" "$(get "$NOPE" /api/runs | jq '.runs | length')" "0"
  check "missing runs dir: page still serves" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NOPE/")" "200"
fi

# --- the committed fixtures ---------------------------------------------------
# What `wall.sh --runs wall/fixtures/runs` (README, demo storyboard) serves.
echo "== wall: the committed fixtures =="
serve "$SRC/wall/fixtures/runs" "$ROOT/fixtures.log"; FIX="$PORT_OUT"
if [ -n "$FIX" ]; then
  FIXAPI="$(get "$FIX" /api/runs)"
  check "fixtures: five staged runs" "$(printf '%s' "$FIXAPI" | jq '.runs | length')" "5"
  check "fixtures: one alarm" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="alarm")] | length')" "1"
  check "fixtures: one ready, one failed" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="ready" or .state=="failed")] | length')" "2"
else
  bad "fixtures: server starts against wall/fixtures/runs"
fi

# --- flags --------------------------------------------------------------------
echo "== wall.sh: flags =="
HELP="$(bash "$WALL" --help 2>&1)"
check   "flags: --help exits 0" "$?" "0"
grep_ok "$HELP" "--runs" "flags: --help documents --runs"
if bash "$WALL" --nope >/dev/null 2>&1; then
  bad "flags: an unknown option exits non-zero"
else
  ok "flags: an unknown option exits non-zero"
fi
if bash "$WALL" --port abc >/dev/null 2>&1; then
  bad "flags: a non-numeric --port exits non-zero"
else
  ok "flags: a non-numeric --port exits non-zero"
fi

echo
printf 'wall smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
