#!/usr/bin/env bash
# Smoke test for the wall: wall.sh's flags, the static page, the JSON snapshot
# endpoint, the live-only skyline runs are grouped into, the stage -> floor
# ladder a run climbs, live SSE updates, and tolerance of half-written run dirs.
# Also pins the two run-task.sh contracts the city is derived from: the
# `worktree` path (which names the tower) and the `owner` pin (which tints the
# light on the car).
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
# The fixture generator accepts a target for hermetic tests, but must never
# treat an arbitrary existing directory as disposable fixture output.
UNMARKED="$ROOT/not-fixtures"
mkdir -p "$UNMARKED"
printf 'keep\n' > "$UNMARKED/important.txt"
if node "$SRC/wall/fixtures/seed.js" "$UNMARKED" >/dev/null 2>&1; then
  bad "fixtures: seeder refuses an unmarked existing directory"
else
  ok "fixtures: seeder refuses an unmarked existing directory"
fi
if [ -f "$UNMARKED/important.txt" ]; then
  ok "fixtures: refused seed target is untouched"
else
  bad "fixtures: refused seed target is untouched"
fi
# The page must not pull anything in from off-origin: the TV may only see the
# tailnet, so a CDN font or script would render as a blank. XML namespace URIs
# (w3.org) are identifiers, never fetched.
PAGE_SRC="$(cat "$SRC/wall/index.html" "$SRC/wall/wall.css" "$SRC/wall/wall.js")"
CSS_SRC="$(cat "$SRC/wall/wall.css")"
OFFSITE="$(printf '%s' "$PAGE_SRC" | grep -oE 'https?://[A-Za-z0-9./_-]+' \
  | grep -v '^https\{0,1\}://www\.w3\.org/' | sort -u | tr '\n' ' ')"
if [ -z "$OFFSITE" ]; then
  ok "assets: no off-origin URLs"
else
  bad "assets: off-origin URLs in the page: $OFFSITE"
fi
# No image assets either: the city is CSS and inline SVG, so the page renders on
# a screen that can reach nothing but this server.
if printf '%s' "$PAGE_SRC" | grep -qiE '\.(png|jpe?g|gif|webp|woff2?)\b'; then
  bad "assets: the page references a binary asset"
else
  ok "assets: the city is drawn, not loaded"
fi

# The crew manifest is gone, and must not creep back: the wall organises around
# the work. Attribution survives only as a tinted light on the run's own car and
# its dispatcher's name in type, so none of the lane vocabulary — nor any
# per-person furniture — may exist in the page.
echo "== wall: no crew-lane furniture survives =="
for banned in STANDBY UNREGISTERED 'DISPATCH CREW' lane__ '.lane' laneEls; do
  grep_not "$PAGE_SRC" "$banned" "ui: no [$banned] anywhere in the page"
done

# Nothing may hover: the crew vehicles that used to sit beside every car are
# gone, and the crossing traffic they were confused with stays.
echo "== wall: nothing hovers, the traffic still crosses =="
for banned in shaft__ship g-spinner g-drone g-unregistered '@keyframes hover'; do
  grep_not "$PAGE_SRC" "$banned" "ui: no [$banned] anywhere in the page"
done
grep_ok "$PAGE_SRC" 'traffic__ship' "ui: distant traffic still crosses the sky"
grep_ok "$PAGE_SRC" '.shaft__car::before' \
  "ui: the dispatcher is a tinted light on the car itself"
grep_ok "$PAGE_SRC" 'brief__owner' "ui: the dispatcher is named on the brief plate"
grep_ok "$PAGE_SRC" 'comms__who' "ui: and on their run's ticker line"

# Nothing on the wall keeps a finished run alive: the retention fade the city
# shipped with is gone, and the completion moment the server times replaced it.
echo "== wall: the retention fade is gone =="
for banned in FRESH_S COLD_S 'function fade' '--fade'; do
  grep_not "$PAGE_SRC" "$banned" "ui: no [$banned] anywhere in the page"
done
grep_ok "$PAGE_SRC" 'completionSeconds' \
  "ui: the completion moment is timed by the server, not the page"

echo "== wall: city state vocabulary =="
grep_ok "$PAGE_SRC" '.tower[data-ready="1"] .tower__beacon' \
  "ui: ready runs light a rooftop beacon"
grep_ok "$PAGE_SRC" '.tower[data-alarm="1"] .tower__sweep' \
  "ui: needs_input towers raise the searchlight"
grep_ok "$PAGE_SRC" '.shaft[data-state="failed"] .shaft__car' \
  "ui: failed runs use the flare treatment"
grep_ok "$PAGE_SRC" '.tower[data-spot="1"] .tower__spot' \
  "ui: the run on the brief plate is spotlit in the skyline"
grep_ok "$PAGE_SRC" '.shaft[data-spot="1"] .shaft__halo' \
  "ui: and the beam lands on that run's own car"
grep_ok "$PAGE_SRC" 'id="rain"' "ui: rain is a drawn layer, not a tiled texture"
grep_ok "$PAGE_SRC" '@media (prefers-reduced-motion: reduce)' \
  "motion: the page honors reduced-motion"
grep_ok "$PAGE_SRC" 'animation: none !important; transition: none !important' \
  "motion: reduced-motion freezes animation and travel"
grep_ok "$PAGE_SRC" '.boot, .rain, .traffic { display: none; }' \
  "motion: reduced-motion removes the boot, rain, and traffic"
grep_ok "$PAGE_SRC" "matchMedia('(prefers-reduced-motion: reduce)')" \
  "motion: and the rain loop never starts in the first place"

# Motion that changes the scene must stay on composited properties. Static
# shadows and filters are fine; transitioning or keyframing them makes the
# browser repaint the city on every frame and is exactly the jank this pass is
# meant to remove.
BAD_TRANSITIONS="$(printf '%s\n' "$CSS_SRC" | grep 'transition:' \
  | grep -Eo '(filter|color|background(-color)?|box-shadow|text-shadow|height|width|top|right|bottom|left)' \
  | sort -u | tr '\n' ' ')"
check "motion: transitions use only transform and opacity" "$BAD_TRANSITIONS" ""
BAD_KEYFRAMES="$(printf '%s\n' "$CSS_SRC" | awk '
  /@keyframes/ { inside=1; depth=0 }
  inside {
    line=$0
    opens=gsub(/{/, "{", line)
    closes=gsub(/}/, "}", line)
    depth += opens - closes
    if ($0 ~ /(filter|color|background|box-shadow|text-shadow|height|width|top|right|bottom|left):/) print
    if (depth == 0) inside=0
  }
')"
check "motion: keyframes use only transform and opacity" "$BAD_KEYFRAMES" ""
grep_not "$CSS_SRC" 'steps(' "motion: no animation uses stepped jumps"

# The palette is night, not sunset. These are the exact sunset stops and the
# pink/purple neon the city shipped with in #8 — none of them may come back.
echo "== wall: the synthwave palette is gone =="
for banned in sky__sun '#f3bd6c' '#d9803f' '#a3454a' '#5b2450' '#231041' '#ff5ec9' '#b78bff'; do
  grep_not "$PAGE_SRC" "$banned" "palette: no [$banned] anywhere in the page"
done
grep_ok "$PAGE_SRC" '--phosphor' "palette: the comms ticker is green phosphor"

# --- serve the fixtures -------------------------------------------------------
# Start a wall on an OS-assigned port. Sets PORT_OUT (empty if it never came
# up); not a command substitution, so the background pid lands in the real PIDS.
# $1 = runs dir, $2 = log file, rest = extra wall.sh flags
serve() {
  local runs="$1" log="$2"; shift 2
  bash "$WALL" --runs "$runs" --host 127.0.0.1 --port 0 "$@" > "$log" 2>&1 &
  PIDS="$PIDS $!"
  PORT_OUT=''
  local i=0
  while [ "$i" -lt 100 ]; do
    PORT_OUT=$(sed -n 's|.*http://[^:]*:\([0-9][0-9]*\)/.*|\1|p' "$log" 2>/dev/null | head -1)
    [ -n "$PORT_OUT" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$PORT_OUT" ] || sed 's/^/       /' "$log" 2>/dev/null
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
grep_ok "$PAGE" 'id="city"'   "page: ships the skyline the towers are built into"
grep_ok "$PAGE" 'class="sky"' "page: ships the night sky an idle wall is left with"
check "page: css is served"   "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/wall.css")" "200"
check "page: js is served"    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/wall.js")"  "200"
check "page: unknown path 404s" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/etc/passwd")" "404"

API="$(get "$PORT" /api/runs)"
check "api: valid JSON" "$(printf '%s' "$API" | jq -r 'type')" "object"
check "api: every fixture run is listed" "$(printf '%s' "$API" | jq '.runs | length')" "11"
for id in OLYX-1631 OLYX-1655 OLYX-1660 OLYX-1642 OLYX-1648 OLYX-1673 OLYX-1598 \
          BOT-2291 BOT-2287 adhoc-kpi-sparklines LEGACY-0042; do
  grep_ok "$API" "\"$id\"" "api: lists $id"
done

state_of() { printf '%s' "$API" | jq -r --arg id "$1" '.runs[] | select(.id==$id) | .'"$2"; }
check "state: mid-implement run is active"  "$(state_of OLYX-1631 state)" "active"
check "state: waiting run raises the alarm" "$(state_of OLYX-1642 state)" "alarm"
check "state: done: ready is ready"         "$(state_of OLYX-1598 state)" "ready"
check "state: done: rejected is failed"     "$(state_of BOT-2287 state)" "failed"

echo "== wall: stage -> actor attribution =="
check "actor: implementing -> Opus"  "$(state_of OLYX-1631 actor)"    "Opus"
check "actor: implementing key"      "$(state_of OLYX-1631 actorKey)" "opus"
check "actor: review -> Codex"       "$(state_of OLYX-1655 actor)"    "Codex"
check "actor: review key"            "$(state_of OLYX-1655 actorKey)" "codex"
check "actor: waiting -> needs input" "$(state_of OLYX-1642 actor)"   "needs input"
check "actor: done -> done"          "$(state_of OLYX-1598 actor)"    "done"

# --- the stage -> floor ladder --------------------------------------------------
# How high a run's car has climbed IS its pipeline stage: setup at street level,
# the PR on the roof. This is the wall's second axis and the only one you can
# read from across the room, so every rung is pinned.
echo "== wall: stage -> floor ladder =="
check "floors: the ladder is published to the page" \
  "$(printf '%s' "$API" | jq -r '.floors | join(",")')" "SETUP,IMPLEMENT,GATE,REVIEW,DEMO,PUSH"
check "floor: base sync is street level"   "$(state_of BOT-2291 floor)" "0"
check "floor: implementing is one up"      "$(state_of OLYX-1631 floor)" "1"
check "floor: the gate is two up"          "$(state_of OLYX-1660 floor)" "2"
check "floor: review is three up"          "$(state_of OLYX-1655 floor)" "3"
check "floor: demo is four up"             "$(state_of adhoc-kpi-sparklines floor)" "4"
check "floor: the PR is the roof"          "$(state_of OLYX-1673 floor)" "5"
check "floor: a blocked run holds the floor it stopped on" \
  "$(state_of OLYX-1642 floor)" "1"
check "floor: a shipped run reaches the roof" "$(state_of OLYX-1598 floor)" "5"
check "floor: a rejection parks at review, not on the roof" \
  "$(state_of BOT-2287 floor)" "3"
check "floor: the name travels with the number" \
  "$(state_of OLYX-1655 floorName)" "REVIEW"

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
grep_ok "$(state_of BOT-2287 reason)"  "opposite directions" "detail: the rejection reason surfaces"

echo "== wall: ordering =="
ORDER="$(printf '%s' "$API" | jq -r '.runs[].id' | tr '\n' ' ')"
check "order: alarm first, then live oldest-first, then finished" \
  "$ORDER" "OLYX-1642 LEGACY-0042 OLYX-1655 OLYX-1648 OLYX-1660 adhoc-kpi-sparklines OLYX-1631 BOT-2291 OLYX-1673 OLYX-1598 BOT-2287 "

# --- project towers -------------------------------------------------------------
# The wall is organised around the work: one tower per project, that project's
# live runs climbing it. The project comes out of the run's worktree path, which
# is the only repo identity a run dir carries.
echo "== wall: project towers =="
tower_of() { printf '%s' "$API" | jq -r --arg p "$1" '.towers[] | select(.project==$p) | .'"$2"; }
check "project: derived from the run dir's worktree pin" \
  "$(state_of OLYX-1631 project)" "olyxbase"
check "project: the label is the repo in lights" \
  "$(state_of OLYX-1631 projectLabel)" "OLYXBASE"
check "project: a worktree only in result.json still names the tower" \
  "$(state_of OLYX-1598 project)" "olyxbase"
check "project: an adhoc ticket suffix comes off the same way" \
  "$(state_of adhoc-kpi-sparklines project)" "olyx-dashboard"
check "project: an unreadable worktree yields no project, never a guess" \
  "$(state_of LEGACY-0042 project)" ""
check "project: and stands in the honest fallback tower" \
  "$(state_of LEGACY-0042 projectLabel)" "UNCHARTED"

check "towers: one per project present on the wall" \
  "$(printf '%s' "$API" | jq '.towers | length')" "5"
check "towers: alphabetical, fallback last — a skyline must not reshuffle" \
  "$(printf '%s' "$API" | jq -r '[.towers[].project] | join(",")')" \
  "olyx-agents,olyx-dashboard,olyxbase,valoryx-graphql-api,"
check "towers: a project's live runs climb its own tower" \
  "$(tower_of olyxbase 'runIds | join(",")')" "OLYX-1642,OLYX-1660,OLYX-1631"
check "towers: live counts what is climbing right now" "$(tower_of olyxbase live)" "3"
# The run shipped 55 minutes ago is still in the JSON — it is what is on disk —
# but its completion moment is long over, so it stands in nobody's skyline.
check "towers: a long-finished run is still in the snapshot" \
  "$(printf '%s' "$API" | jq '[.runs[] | select(.id=="OLYX-1598")] | length')" "1"
check "towers: but it has left the skyline"  \
  "$(printf '%s' "$API" | jq '[.towers[].runIds[]] | index("OLYX-1598")')" "null"
check "towers: a blocked run raises its tower's alarm" "$(tower_of olyxbase alarm)" "1"
check "towers: a quiet tower raises none"              "$(tower_of olyx-agents alarm)" "0"
check "towers: the fallback tower is labelled honestly" \
  "$(printf '%s' "$API" | jq -r '.towers[] | select(.project=="") | .label')" "UNCHARTED"
check "towers: and is marked as a fallback, not a repo" \
  "$(printf '%s' "$API" | jq -r '.towers[] | select(.project=="") | .known')" "false"
check "towers: silhouettes stay inside the shapes the page can draw" \
  "$(printf '%s' "$API" | jq '[.towers[] | select(.shape >= 0 and .shape < 5 and .crown >= 0 and .crown < 4)] | length')" "5"
# A project a person has never dispatched to is simply absent: no empty tower,
# no standby, nothing that reads as an accusation.
check "towers: a project with nothing on the wall has no tower" \
  "$(printf '%s' "$API" | jq '[.towers[] | select(.project=="never-dispatched")] | length')" "0"

# --- the skyline is live only -----------------------------------------------------
# Nobody watching a wall wants yesterday's green ticks. The skyline carries what
# is happening, plus one short completion moment per run that just finished; a
# tower with nothing left standing in it leaves with its runs, and an alarm
# stays pinned however long it has been waiting for a human.
echo "== wall: the skyline is live only =="
SKY="$ROOT/skyline"
SKY_NOW="$(date +%s)"
sky_run() {  # $1 = id, $2 = project, $3 = seconds since the stage, $4 = stage
  mkdir -p "$SKY/$1"
  printf '%s %s\n' "$((SKY_NOW - $3))" "$4" > "$SKY/$1/status"
  printf '/tmp/%s-%s\n' "$2" "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" > "$SKY/$1/worktree"
}
sky_run LIVE-1   alpha   30   'implementing — Opus (Claude sub)'
sky_run FRESH-1  alpha   2    'done: ready'
sky_run STALE-1  alpha   3600 'done: ready'
sky_run GONE-1   beta    3600 'done: rejected'
sky_run PINNED-1 gamma   9000 'waiting — implementer needs your input (QUESTIONS.md)'
serve "$SKY" "$ROOT/skyline.log"; SKY_PORT="$PORT_OUT"
WINDOW=0
if [ -n "$SKY_PORT" ]; then
  SKY_API="$(get "$SKY_PORT" /api/runs)"
  WINDOW="$(printf '%s' "$SKY_API" | jq -r '.completionSeconds')"
  check "skyline: every run is still in the snapshot — it is what is on disk" \
    "$(printf '%s' "$SKY_API" | jq '.runs | length')" "5"
  check "skyline: only live work and a fresh completion stand in it" \
    "$(printf '%s' "$SKY_API" | jq -r '[.towers[].runIds[]] | sort | join(",")')" \
    "FRESH-1,LIVE-1,PINNED-1"
  check "skyline: the completion moment is a short one" \
    "$(printf '%s' "$SKY_API" | jq '.completionSeconds > 0 and .completionSeconds <= 60')" "true"
  check "skyline: a tower with nothing left standing leaves too" \
    "$(printf '%s' "$SKY_API" | jq '[.towers[] | select(.project=="beta")] | length')" "0"
  check "skyline: an alarm stays pinned however long it has waited" \
    "$(printf '%s' "$SKY_API" | jq -r '.towers[] | select(.project=="gamma") | .alarm')" "1"
  check "skyline: live counts what is climbing, not what is finishing" \
    "$(printf '%s' "$SKY_API" | jq -r '.towers[] | select(.project=="alpha") | .live')" "1"
  check "skyline: no tower carries a retention aggregate any more" \
    "$(printf '%s' "$SKY_API" | jq '[.towers[] | has("total")] | any')" "false"
else
  bad "skyline: server starts against the live-only fixtures"
fi

# A moment ending is a change nothing on disk records: no run moved, but the
# skyline did, and a wall nobody touches has to push that frame by itself.
echo "== wall: a completion moment ends on its own =="
ENDING="$ROOT/ending"
mkdir -p "$ENDING/KEEP-1" "$ENDING/ENDS-1"
printf '%s implementing — Opus (Claude sub)\n' "$(date +%s)" > "$ENDING/KEEP-1/status"
printf '/tmp/delta-keep-1\n' > "$ENDING/KEEP-1/worktree"
printf '%s done: ready\n' "$(( $(date +%s) - WINDOW + 3 ))" > "$ENDING/ENDS-1/status"
printf '/tmp/delta-ends-1\n' > "$ENDING/ENDS-1/worktree"
serve "$ENDING" "$ROOT/ending.log"; END_PORT="$PORT_OUT"
if [ -n "$END_PORT" ] && [ "$WINDOW" -gt 3 ]; then
  check "expiry: a run still inside its moment is standing" \
    "$(get "$END_PORT" /api/runs | jq '[.towers[].runIds[]] | index("ENDS-1") != null')" "true"
  END_SSE="$ROOT/ending.sse"
  curl -sN --max-time 8 "http://127.0.0.1:$END_PORT/api/stream" > "$END_SSE" 2>/dev/null &
  END_SSE_PID=$!
  PIDS="$PIDS $END_SSE_PID"
  sleep 5
  kill "$END_SSE_PID" 2>/dev/null || true
  wait "$END_SSE_PID" 2>/dev/null || true
  LAST_END="$(grep '^data: ' "$END_SSE" | tail -1 | cut -c7-)"
  check "expiry: the wall pushes the moment ending with nothing else changing" \
    "$(printf '%s' "$LAST_END" | jq '[.towers[].runIds[]] | index("ENDS-1")')" "null"
  check "expiry: and the live run beside it keeps the tower" \
    "$(printf '%s' "$LAST_END" | jq -r '[.towers[].runIds[]] | join(",")')" "KEEP-1"
else
  bad "expiry: server starts against a run mid-completion"
fi

echo "== wall: crew is ambient, never furniture =="
check "owner: read from the run's owner file"   "$(state_of OLYX-1631 owner)" "angel"
check "owner: the synthetic's runs are its own" "$(state_of BOT-2291 owner)" "bot"
check "owner: a human dispatcher gets a crew tint" "$(state_of OLYX-1631 ownerKind)" "human"
check "owner: the synthetic is named as one"    "$(state_of BOT-2291 ownerKind)" "synthetic"
check "owner: an unowned run is not mis-assigned" "$(state_of LEGACY-0042 ownerKind)" "unowned"
check "crew: the snapshot carries no per-person aggregate at all" \
  "$(printf '%s' "$API" | jq -r '[paths | map(tostring) | join(".")] | map(select(test("lane"))) | length')" "0"

# --crew survives so an existing launch script keeps working, but a roster no
# longer conjures anything up: an idle name is not a tower, and never was one of
# these projects.
serve "$RUNS" "$ROOT/crew.log" --crew angel,reinier,emre,ripley; ROSTER="$PORT_OUT"
if [ -n "$ROSTER" ]; then
  ROSTER_API="$(get "$ROSTER" /api/runs)"
  check "roster: --crew is still accepted and echoed" \
    "$(printf '%s' "$ROSTER_API" | jq -r '.crew | join(",")')" "angel,reinier,emre,ripley"
  check "roster: a declared roster creates no empty-state UI" \
    "$(printf '%s' "$ROSTER_API" | jq -r '[.towers[].project] | join(",")')" \
    "$(printf '%s' "$API" | jq -r '[.towers[].project] | join(",")')"
  check "roster: a crew member with nothing running adds nothing" \
    "$(printf '%s' "$ROSTER_API" | jq '[.towers[] | select(.label=="RIPLEY")] | length')" "0"
  # A project keeps its building whoever else is on the wall, so the room can
  # learn the skyline as a place rather than re-reading it every morning.
  check "roster: a project's silhouette is stable across processes" \
    "$(printf '%s' "$ROSTER_API" | jq -r '[.towers[] | "\(.project):\(.shape).\(.crown)"] | join(",")')" \
    "$(printf '%s' "$API" | jq -r '[.towers[] | "\(.project):\(.shape).\(.crown)"] | join(",")')"
else
  bad "roster: server starts with --crew"
fi

# --- the pipeline contracts the city is derived from ----------------------------
# A tower is named by reversing run-task.sh's worktree construction, so that
# construction is part of the wall's contract just like the owner pin.
echo "== run-task.sh: the worktree path the towers reverse =="
grep_ok "$(cat "$SRC/run-task.sh")" 'WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$TICKET_LC"' \
  "project: run-task.sh still builds <repo>-<ticket> beside the repo"
grep_ok "$(cat "$SRC/run-task.sh")" 'echo "$WORKTREE" > "$RUN_DIR/worktree"' \
  "project: the run dir still records its worktree"
grep_ok "$(cat "$SRC/run-task.sh")" 'worktree:$worktree' \
  "project: result.json still carries the worktree the fallback reads"

# The vehicles are only as good as run-task.sh's pin. Exercise the real function
# out of the real file rather than restating its rules here.
echo "== run-task.sh: the owner pin the vehicles depend on =="
PIN_SRC="$(awk '/^pin_knob\(\)/,/^\}/' "$SRC/run-task.sh")"
if printf '%s' "$PIN_SRC" | grep -q 'pin_knob()'; then
  ok "owner: pin_knob extracted from run-task.sh"
else
  bad "owner: pin_knob extracted from run-task.sh (extraction broken?)"
fi
pin_owner() {  # $1 = run dir, $2 = HARNESS_OWNER ('-' = unset) -> the pinned value
  # shellcheck disable=SC2034  # RUN_DIR is read by the pin_knob body we eval in
  ( RUN_DIR="$1"; eval "$PIN_SRC"
    if [ "$2" = '-' ]; then unset HARNESS_OWNER; else HARNESS_OWNER="$2"; fi
    pin_knob owner HARNESS_OWNER ""
    printf '%s' "$HARNESS_OWNER" )
}
OWNED="$ROOT/owner-run"; mkdir -p "$OWNED"
check "owner: first dispatch pins HARNESS_OWNER"   "$(pin_owner "$OWNED" angel)" "angel"
check "owner: the run dir records it"              "$(cat "$OWNED/owner")" "angel"
check "owner: a resume reuses the pinned owner"    "$(pin_owner "$OWNED" reinier)" "angel"
UNOWNED="$ROOT/owner-none"; mkdir -p "$UNOWNED"
check "owner: an unset HARNESS_OWNER pins empty"   "$(pin_owner "$UNOWNED" -)" ""
grep_ok "$(cat "$SRC/run-task.sh")" 'owner:$owner' "owner: result.json carries the owner"
grep_ok "$(cat "$SRC/run-task.sh")" 'pin_knob owner HARNESS_OWNER' \
  "owner: run-task.sh pins it the same way as the ablation knobs"

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
mkdir -p "$RUNS/BARE-1" "$RUNS/EMPTY-1" "$RUNS/JUNK-1" "$RUNS/PINNED-EMPTY" \
  "$RUNS/SYNC-FAIL" "$RUNS/DONE-INPUT" "$RUNS/LONG-1"
printf '%s setup: worktree\n' "$(date +%s)" > "$RUNS/BARE-1/status"   # status only
: > "$RUNS/EMPTY-1/status"                                            # caught mid-write
printf '%s implementing — Opus (Claude sub)\n' "$(date +%s)" > "$RUNS/JUNK-1/status"
printf '%s implementing — Opus (Claude sub)\n' "$(date +%s)" > "$RUNS/PINNED-EMPTY/status"
: > "$RUNS/PINNED-EMPTY/owner"                                       # empty is a real pin
printf '{"owner":"stale-result-owner"}\n' > "$RUNS/PINNED-EMPTY/result.json"
printf '%s sync failed: gate failed after base sync\n' "$(date +%s)" > "$RUNS/SYNC-FAIL/status"
printf '%s done: needs_input\n' "$(date +%s)" > "$RUNS/DONE-INPUT/status"
printf '%s review — Codex (ChatGPT sub)\n%s done: needs_input\n' \
  "$(( $(date +%s) - 10 ))" "$(date +%s)" > "$RUNS/DONE-INPUT/stages.log"
printf '{"status":"needs_input"}\n' > "$RUNS/DONE-INPUT/result.json"
printf '# Questions\n\nChoose the deployment region.\n' > "$RUNS/DONE-INPUT/QUESTIONS.md"
printf '/tmp/input-project-done-input\n' > "$RUNS/DONE-INPUT/worktree"
printf '%s implementing — Opus (Claude sub)\n' "$(date +%s)" > "$RUNS/LONG-1/status"
LONG_PROJECT='a-project-name-that-is-definitely-longer-than-thirty-two-characters'
printf '/tmp/%s-long-1\n' "$LONG_PROJECT" > "$RUNS/LONG-1/worktree"
printf '{"status": "rea' > "$RUNS/JUNK-1/result.json"                 # half-written JSON
printf 'not an epoch\n' > "$RUNS/JUNK-1/started"
mkdir -p "$RUNS/NOTARUN"                                              # no status at all
sleep 1.2
API="$(get "$PORT" /api/runs)"
check "partial: still valid JSON" "$(printf '%s' "$API" | jq -r 'type')" "object"
grep_ok  "$API" "BARE-1"   "partial: a status-only run still renders"
grep_ok  "$API" "JUNK-1"   "partial: a half-written result.json does not drop the run"
grep_ok  "$API" "SYNC-FAIL" "partial: a sync failure remains prominent on the live wall"
grep_not "$API" "NOTARUN"  "partial: a dir with no status is not a run"
grep_ok  "$API" "OLYX-1598" "partial: the healthy runs are untouched"
check "partial: an empty status falls back to stages.log/blank, not a crash" \
  "$(printf '%s' "$API" | jq -r '[.runs[] | select(.id=="EMPTY-1")] | length')" "0"
check "partial: a bad started epoch degrades to the stage time" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="JUNK-1") | (.started != null)')" "true"
check "partial: a run with no owner is unowned, not mis-assigned" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="BARE-1") | .owner')" ""
check "owner: an empty pin wins over stale result metadata" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="PINNED-EMPTY") | .owner')" ""
check "partial: a run with no worktree gets no project, not a guess" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="BARE-1") | .project')" ""
check "partial: those runs still stand somewhere — the fallback tower" \
  "$(printf '%s' "$API" | jq -r '[.towers[] | select(.project=="") | .runIds[]] | index("BARE-1") != null')" "true"
check "towers: the fallback tower sorts last, whatever else is on the wall" \
  "$(printf '%s' "$API" | jq -r '.towers[-1].project')" ""
check "state: a non-done sync failure remains a live panel" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="SYNC-FAIL") | .state')" "active"
check "actor: a sync failure keeps its failure attribution" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="SYNC-FAIL") | .actor')" "failed"
check "state: terminal needs_input remains an alarm, never a ready beacon" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="DONE-INPUT") | .state')" "alarm"
check "actor: terminal needs_input keeps the blocking attribution" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="DONE-INPUT") | .actor')" "needs input"
check "floor: terminal needs_input stays where work stopped" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="DONE-INPUT") | .floor')" "3"
check "alarm: terminal needs_input raises its project's searchlight" \
  "$(printf '%s' "$API" | jq -r '.towers[] | select(.project=="input-project") | .alarm')" "1"
check "project: long repo basenames are not truncated or merged" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="LONG-1") | .project')" "$LONG_PROJECT"

echo "== wall: no runs dir at all =="
serve "$ROOT/does-not-exist" "$ROOT/nope.log"; NOPE="$PORT_OUT"
if [ -n "$NOPE" ]; then ok "missing runs dir: server still starts"; else bad "missing runs dir: server still starts"; fi
if [ -n "$NOPE" ]; then
  check "missing runs dir: empty snapshot" "$(get "$NOPE" /api/runs | jq '.runs | length')" "0"
  check "missing runs dir: page still serves" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NOPE/")" "200"
fi

# A wall with lots of history must never lose an older run that is still live.
# Only completed history is capped in the JSON, and none of it reaches the
# skyline: what a busy day leaves behind is one lit shaft, not twenty-five.
echo "== wall: busy history never evicts live work =="
CROWDED="$ROOT/crowded"
BUSY_NOW="$(date +%s)"
mkdir -p "$CROWDED/LIVE-OLD"
printf '%s implementing — Opus (Claude sub)\n' "$((BUSY_NOW - 7200))" > "$CROWDED/LIVE-OLD/status"
printf '%s\n' "$((BUSY_NOW - 9000))" > "$CROWDED/LIVE-OLD/started"
touch -t 200001010000 "$CROWDED/LIVE-OLD/status"
for i in $(seq 1 25); do
  mkdir -p "$CROWDED/DONE-$i"
  printf '%s done: ready\n' "$((BUSY_NOW - 3600 - i))" > "$CROWDED/DONE-$i/status"
  printf '%s\n' "$((BUSY_NOW - 3700 - i))" > "$CROWDED/DONE-$i/started"
done
serve "$CROWDED" "$ROOT/crowded.log"; BUSY="$PORT_OUT"
if [ -n "$BUSY" ]; then
  BUSY_API="$(get "$BUSY" /api/runs)"
  check "busy: the older live run survives the history cap" \
    "$(printf '%s' "$BUSY_API" | jq '[.runs[] | select(.id=="LIVE-OLD" and .state=="active")] | length')" "1"
  check "busy: only completed history is capped" \
    "$(printf '%s' "$BUSY_API" | jq '[.runs[] | select(.state=="ready" or .state=="failed")] | length')" "24"
  check "busy: a day of finished work leaves the live run alone up there" \
    "$(printf '%s' "$BUSY_API" | jq -r '.towers[] | select(.project=="") | .runIds | join(",")')" "LIVE-OLD"
  check "busy: towers do not hide runs behind an overflow count" \
    "$(printf '%s' "$BUSY_API" | jq '[.towers[] | has("hiddenIds")] | any')" "false"
else
  bad "busy: server starts against crowded history"
fi

# Mirror the complete stage contract, using statusline.sh itself as the oracle
# rather than a second hand-maintained expectation table in this test.
echo "== wall: every pipeline stage mirrors statusline attribution =="
MAP_RUNS="$ROOT/mapping-runs"
MAP_EXPECTED="$ROOT/mapping-expected.tsv"
mkdir -p "$MAP_RUNS"
i=0
grep -hoE 'stage "[^"]+"' "$SRC/run-task.sh" "$SRC/sync-pr.sh" \
  | sed -e 's/^stage "//' -e 's/"$//' \
        -e 's/\$[A-Za-z_][A-Za-z0-9_]*/X/g' -e 's/\$[0-9]/X/g' \
  | sort -u | while IFS= read -r stage; do
      i=$((i + 1))
      id="$(printf 'MAP-%02d' "$i")"
      mkdir -p "$MAP_RUNS/$id"
      printf '%s %s\n' "$(date +%s)" "$stage" > "$MAP_RUNS/$id/status"
      expected="$(NO_COLOR=1 bash -c '. "$1"; harness_actor "$2"; printf "%s" "$HARNESS_ACTOR"' \
        _ "$SRC/statusline.sh" "$stage")"
      printf '%s\t%s\t%s\n' "$id" "$expected" "$stage" >> "$MAP_EXPECTED"
    done
serve "$MAP_RUNS" "$ROOT/mapping.log"; MAP_PORT="$PORT_OUT"
if [ -n "$MAP_PORT" ]; then
  MAP_API="$(get "$MAP_PORT" /api/runs)"
  mismatches=''
  while IFS=$'\t' read -r id expected stage; do
    actual="$(printf '%s' "$MAP_API" | jq -r --arg id "$id" '.runs[] | select(.id==$id) | .actor')"
    [ "$actual" = "$expected" ] || mismatches="$mismatches\n    $stage: want [$expected], got [$actual]"
  done < "$MAP_EXPECTED"
  if [ -z "$mismatches" ]; then
    ok "mapping: every pipeline stage matches statusline.sh"
  else
    bad "mapping: wall attribution drift:$mismatches"
  fi
else
  bad "mapping: server starts against generated stage fixtures"
fi

# --- the committed fixtures ---------------------------------------------------
# What `wall.sh --runs wall/fixtures/runs` (README, demo storyboard) serves.
echo "== wall: the committed fixtures =="
serve "$SRC/wall/fixtures/runs" "$ROOT/fixtures.log"; FIX="$PORT_OUT"
if [ -n "$FIX" ]; then
  FIXAPI="$(get "$FIX" /api/runs)"
  check "fixtures: eleven staged runs" "$(printf '%s' "$FIXAPI" | jq '.runs | length')" "11"
  check "fixtures: one alarm" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="alarm")] | length')" "1"
  check "fixtures: one ready, one failed" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="ready" or .state=="failed")] | length')" "2"
  check "fixtures: four repos plus the fallback tower" \
    "$(printf '%s' "$FIXAPI" | jq '.towers | length')" "5"
  check "fixtures: the long-finished runs are not in the skyline" \
    "$(printf '%s' "$FIXAPI" | jq '[.towers[].runIds[]] | length')" "9"
  check "fixtures: exactly one of those towers is the fallback" \
    "$(printf '%s' "$FIXAPI" | jq '[.towers[] | select(.known == false)] | length')" "1"
  check "fixtures: one project has three runs climbing at once" \
    "$(printf '%s' "$FIXAPI" | jq '[.towers[] | select(.live == 3)] | length')" "1"
  check "fixtures: every floor of the ladder is lit somewhere" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[].floor] | unique | length')" "6"
  check "fixtures: the synthetic dispatches some of them" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.ownerKind=="synthetic")] | length')" "2"
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

# wall.sh is only useful after install if its sibling wall/ assets travel with
# it. Cover both supported installer modes, including replacement of stale
# files in a previous copied directory.
echo "== wall: install modes =="
INSTALL_HOME="$ROOT/install-home"
COPY_HARNESS="$ROOT/install-copy"
HOME="$INSTALL_HOME" HARNESS_DIR="$COPY_HARNESS" \
  CLAUDE_SKILLS_DIR="$ROOT/copy-skills" CLAUDE_SETTINGS_FILE="$ROOT/copy-settings.json" \
  bash "$SRC/install.sh" --copy --no-statusline >/dev/null
if [ -x "$COPY_HARNESS/wall.sh" ]; then ok "install: copy includes wall.sh"; else bad "install: copy includes wall.sh"; fi
if [ -f "$COPY_HARNESS/wall/server.js" ]; then ok "install: copy includes wall assets"; else bad "install: copy includes wall assets"; fi
printf 'stale\n' > "$COPY_HARNESS/wall/removed-in-update.txt"
HOME="$INSTALL_HOME" HARNESS_DIR="$COPY_HARNESS" \
  CLAUDE_SKILLS_DIR="$ROOT/copy-skills" CLAUDE_SETTINGS_FILE="$ROOT/copy-settings.json" \
  bash "$SRC/install.sh" --copy --no-statusline >/dev/null
if [ ! -e "$COPY_HARNESS/wall/removed-in-update.txt" ]; then
  ok "install: copy replaces a stale wall directory"
else
  bad "install: copy replaces a stale wall directory"
fi

LINK_HARNESS="$ROOT/install-link"
HOME="$INSTALL_HOME" HARNESS_DIR="$LINK_HARNESS" \
  CLAUDE_SKILLS_DIR="$ROOT/link-skills" CLAUDE_SETTINGS_FILE="$ROOT/link-settings.json" \
  bash "$SRC/install.sh" --symlink --no-statusline >/dev/null
if [ -L "$LINK_HARNESS/wall" ]; then ok "install: symlink mode links wall assets"; else bad "install: symlink mode links wall assets"; fi

echo
printf 'wall smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
