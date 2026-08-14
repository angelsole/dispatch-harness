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
grep_ok()  { if grep -qF -- "$2" <<< "$1"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
grep_not() { if grep -qF -- "$2" <<< "$1"; then bad "$3 (unexpected [$2])"; else ok "$3"; fi; }

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

# --- the brief plate ------------------------------------------------------------
# The plate is the thing people actually read, so it gets chrome — and the
# carousel hands over between runs instead of cutting. Neither may cost the type
# hierarchy anything: the chrome is around the words, never instead of them.
echo "== wall: the brief plate is chrome, and hands over =="
grep_ok "$CSS_SRC" '.brief::after' "plate: the frame carries its own hairline and ticks"
grep_ok "$CSS_SRC" 'clip-path: polygon(0.85rem 0' "plate: its corners are cut, not square"
grep_ok "$CSS_SRC" 'repeating-linear-gradient(180deg, rgba(150, 216, 200, 0.045)' \
  "plate: and a whisper of scan texture under the panel"
grep_ok "$CSS_SRC" '.brief[data-swap="out"]' "plate: the outgoing run eases out"
grep_ok "$CSS_SRC" '.brief[data-swap="in"]'  "plate: and the incoming one eases in"
grep_ok "$PAGE_SRC" "relight('out')" "plate: the hand-off is two phases, never a cut"
grep_ok "$PAGE_SRC" "run.state === 'alarm' ? 'alarm' : run.actorKey" \
  "plate: an alarm outranks the actor neon on the accent edge"
check "plate: the ticket type is untouched by the chrome pass" \
  "$(printf '%s\n' "$CSS_SRC" | sed -n '/^\.brief__id {/,/^}/p' | grep -c 'font-size: 2.5rem')" "1"

# --- the shipping ceremony ------------------------------------------------------
# A run reaching `done: ready` gets a short beat before the normal completion
# exit: light climbing the facade, the rooftop lamp thrown wide, one bright line
# on the ticker. It is one animation family on one duration, fast-forwarded by
# --age exactly like the exit it precedes, and every part has to end on nothing
# or a browser opening tomorrow finds a tower still celebrating.
echo "== wall: the shipping ceremony =="
grep_ok "$PAGE_SRC" 'tower__cascade' "ceremony: light climbs the facade floor by floor"
grep_ok "$CSS_SRC" '.tower[data-ready="1"] .tower__cascade' \
  "ceremony: only a tower with a shipped run plays it"
grep_ok "$CSS_SRC" '.tower[data-ready="1"] .tower__halo' \
  "ceremony: and the rooftop lamp throws wider"
grep_ok "$PAGE_SRC" "if (shipped !== T.ready)" \
  "ceremony: a tower remembers which run received the beat"
grep_ok "$PAGE_SRC" "T.root.dataset.ready = '0'" \
  "ceremony: a second shipped run first detaches the old animation"
grep_ok "$PAGE_SRC" 'void T.root.offsetWidth' \
  "ceremony: then commits that reset before starting its own timeline"
grep_ok "$PAGE_SRC" "'SHIPPED · '" "ceremony: the ticker prints the shipped line"
grep_ok "$CSS_SRC" '.comms__line[data-src="shipped"]' "ceremony: in the brightest type it has"
CEREMONY_CSS="$(printf '%s\n' "$CSS_SRC" | sed -n 's/^ *--ceremony: \([0-9.]*\)s;.*/\1/p' | head -1)"
CEREMONY_JS="$(sed -n 's/^  const CEREMONY_S = \([0-9.]*\);.*/\1/p' "$SRC/wall/wall.js")"
check "ceremony: the page and the stylesheet agree on the beat" "$CEREMONY_JS" "$CEREMONY_CSS"
if [ -n "$CEREMONY_CSS" ] && awk "BEGIN { exit !($CEREMONY_CSS > 0 && $CEREMONY_CSS <= 6) }"; then
  ok "ceremony: the whole beat is six seconds or less"
else
  bad "ceremony: the whole beat is six seconds or less (got [$CEREMONY_CSS])"
fi
check "ceremony: every part of it runs on that one duration" \
  "$(printf '%s\n' "$CSS_SRC" | grep -cE 'animation: ship-[a-z]+ var\(--ceremony\)')" "3"
check "ceremony: and is fast-forwarded by --age, like the exit it precedes" \
  "$(printf '%s\n' "$CSS_SRC" | grep -A1 -E 'animation: ship-[a-z]+ var\(--ceremony\)' \
     | grep -cF 'animation-delay: calc(var(--age, 0) * -1s)')" "3"
for beat in ship-lit ship-halo; do
  check "ceremony: $beat leaves nothing behind" \
    "$(printf '%s\n' "$CSS_SRC" | awk -v k="@keyframes $beat" 'index($0, k) == 1, /^}/' \
       | grep -c '100% { opacity: 0')" "1"
done

# --- living weather -------------------------------------------------------------
# The weather is a pure function of the wall clock, which is what lets two TVs
# opened side by side show the same sky. That makes it checkable the same way
# run-task.sh's owner pin is: run the real code out of the real file rather than
# restating its numbers here.
echo "== wall: the weather drifts =="
grep_ok "$PAGE_SRC" 'function wetness' "weather: rain intensity is a function, not a loop"
grep_ok "$CSS_SRC" 'var(--haze, 1)'      "weather: the street haze reads it, a lag behind"
grep_ok "$CSS_SRC" 'opacity: var(--dawn, 0)' "weather: and the sky cools toward local dawn"
check "weather: haze and dawn samples blend instead of stepping each second" \
  "$(printf '%s\n' "$CSS_SRC" | grep -c 'transition: opacity var(--weather-blend) linear')" "2"
grep_ok "$PAGE_SRC" 'if (still.matches)' \
  "weather: reduced motion leaves both of those unwritten — today's static scene"
WEATHER_SRC="$(awk '/^  \/\/ --- weather/,/^  \/\/ --- rain/' "$SRC/wall/wall.js")"
RAIN_SRC="$(awk '/^  \/\/ --- rain/,/^  render\(\);/' "$SRC/wall/wall.js")"
grep_not "$(printf '%s\n' "$WEATHER_SRC" "$RAIN_SRC" | grep -v '^ *//')" 'Math.random' \
  "weather: neither its state nor its drops rely on unseeded randomness"

PROBE="$ROOT/weather-probe.js"
{
  grep -E '^  const (RAIN_LAG|DAWN_H|DAWN_RAMP|WEATHER_SEED_MS) =' "$SRC/wall/wall.js"
  printf '%s\n' "$WEATHER_SRC"
  cat <<'JS'
  const DAY = 86400;
  let lo = 1, hi = 0, step = 0, dry = -1, fastest = Infinity;
  for (let t = 0; t < DAY * 3; t += 15) {
    const v = wetness(t);
    lo = Math.min(lo, v);
    hi = Math.max(hi, v);
    step = Math.max(step, Math.abs(wetness(t + 1) - v));
    if (v < 0.1) dry = t;
    if (v > 0.9 && dry >= 0) { fastest = Math.min(fastest, t - dry); dry = -1; }
  }
  const at = (h, m) => dawn(new Date(2026, 0, 2, h, m));
  const sequence = (seed) => {
    const random = seededRandom(seed);
    return Array.from({ length: 8 }, random);
  };
  const seeded = sequence(weatherSeed(WEATHER_SEED_MS));
  console.log(JSON.stringify({
    bounded: lo >= 0 && hi <= 1,
    nearDry: lo < 0.05,
    downpour: hi > 0.9,
    smooth: step < 0.002,
    slow: fastest > 15 * 60,
    lagMinutes: RAIN_LAG / 60,
    dawnPeak: at(6, 30) > 0.95,
    dawnRamp: at(5, 15) > 0.4 && at(5, 15) < 0.6,
    dawnNoon: at(12, 0),
    dawnNight: at(22, 0),
    seededSame: JSON.stringify(seeded) === JSON.stringify(sequence(weatherSeed(WEATHER_SEED_MS))),
    seededChanges: JSON.stringify(seeded) !== JSON.stringify(sequence(weatherSeed(WEATHER_SEED_MS * 2))),
    seededBounded: seeded.every((value) => value >= 0 && value < 1),
    seedWindow: weatherSeed(0) === weatherSeed(WEATHER_SEED_MS - 1)
      && weatherSeed(0) !== weatherSeed(WEATHER_SEED_MS),
  }));
JS
} > "$PROBE"
WEATHER="$(node "$PROBE" 2>&1)"
weather_of() { printf '%s' "$WEATHER" | jq -r ".$1" 2>/dev/null; }
check "weather: intensity never leaves 0..1"        "$(weather_of bounded)"  "true"
check "weather: it reaches a near-dry spell"        "$(weather_of nearDry)"  "true"
check "weather: and it reaches a downpour"          "$(weather_of downpour)" "true"
check "weather: it drifts — under 0.2% of its range a second" \
  "$(weather_of smooth)" "true"
check "weather: no swing between the two inside a quarter of an hour" \
  "$(weather_of slow)" "true"
check "weather: the haze follows the rain minutes later" "$(weather_of lagMinutes)" "7"
check "weather: the sky is coldest at local dawn"   "$(weather_of dawnPeak)" "true"
check "weather: and ramps into it rather than switching" "$(weather_of dawnRamp)" "true"
check "weather: midday is not dawn"                 "$(weather_of dawnNoon)"  "0"
check "weather: nor is late evening"                "$(weather_of dawnNight)" "0"
check "weather: equal wall-clock seeds draw equal rain" "$(weather_of seededSame)" "true"
check "weather: later seed windows draw a fresh field"  "$(weather_of seededChanges)" "true"
check "weather: seeded drop values stay in range"       "$(weather_of seededBounded)" "true"
check "weather: nearby openings share one seed window"  "$(weather_of seedWindow)" "true"

# --- traffic and the searchlight -------------------------------------------------
echo "== wall: ground traffic, and a beam that lands =="
grep_ok "$PAGE_SRC" 'street__car' "traffic: something crosses at street level"
grep_ok "$CSS_SRC" '.street { display: none; }' "traffic: and reduced motion parks it"
# Every animation duration declared for a selector matching $1, whichever of the
# two spellings the rule uses.
durations() {
  printf '%s\n' "$CSS_SRC" | awk -v want="$1" '
    /^[.@]/ { sel = $0 }
    sel ~ want && /animation(-duration)?:/ {
      if (match($0, /[0-9.]+s/)) print substr($0, RSTART, RLENGTH - 1)
    }
  '
}
AIR_SLOWEST="$(durations 'traffic__ship' | sort -n | tail -1)"
GROUND_RAREST="$(durations 'street__car' | sort -n | head -1)"
if [ -n "$AIR_SLOWEST" ] && [ -n "$GROUND_RAREST" ] \
   && awk "BEGIN { exit !($GROUND_RAREST > $AIR_SLOWEST) }"; then
  ok "traffic: a ground pass is rarer than anything in the air (${GROUND_RAREST}s vs ${AIR_SLOWEST}s)"
else
  bad "traffic: a ground pass is rarer than anything in the air (ground [$GROUND_RAREST] air [$AIR_SLOWEST])"
fi
grep_ok "$PAGE_SRC" 'tower__ceiling' "alarm: the beam paints a patch on the cloud ceiling"
check "alarm: and the patch runs on the sweep's own timing, not its own" \
  "$(printf '%s\n' "$CSS_SRC" | sed -n 's/^ *animation: ceiling \(.*\);$/\1/p')" \
  "$(printf '%s\n' "$CSS_SRC" | sed -n 's/^ *animation: sweep \(.*\);$/\1/p')"

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
#
# Every server gets its OWN city ledger under the temp root unless the caller
# names one. Two reasons: the default path is beside the runs dir, and most of
# these fixture roots are siblings under $ROOT — they would otherwise share one
# ledger and each other's cities. And the committed wall/fixtures/runs is served
# from the repo, where nothing may be written at all. CITY_OUT is the ledger the
# server was handed, so a test can read it back.
SERVED=0
serve() {
  local runs="$1" log="$2"; shift 2
  SERVED=$((SERVED + 1))
  CITY_OUT="$ROOT/city-$SERVED.jsonl"
  case " $* " in *" --city "*) CITY_OUT='' ;; esac
  if [ -n "$CITY_OUT" ]; then
    bash "$WALL" --runs "$runs" --host 127.0.0.1 --port 0 --city "$CITY_OUT" "$@" \
      > "$log" 2>&1 &
  else
    bash "$WALL" --runs "$runs" --host 127.0.0.1 --port 0 "$@" > "$log" 2>&1 &
  fi
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
grep_ok "$PAGE" "GHOST SHIFT"  "page: renders the wall document"
grep_ok "$PAGE" "SHIFT STANDING BY" "page: carries the idle standby plate"
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

# The shell statusline and the wall keep separate prefix tables. Exercise the
# wall's copy directly so a shell-only fix cannot leave the room display calling
# an exhausted review "Codex" or parking review_failed on the PUSH roof.
REVIEW_WALL="$ROOT/review-wall"
REVIEW_NOW=$(date +%s)
for id in UNREVIEWED-1 REVIEW-FAILED-1; do
  mkdir -p "$REVIEW_WALL/$id"
  printf '%s\n' "$((REVIEW_NOW - 60))" > "$REVIEW_WALL/$id/started"
  printf '/tmp/review-wall-%s\n' "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" \
    > "$REVIEW_WALL/$id/worktree"
done
printf '%s review failed silently — diff is unreviewed\n' "$REVIEW_NOW" \
  > "$REVIEW_WALL/UNREVIEWED-1/status"
printf '%s done: review_failed\n' "$REVIEW_NOW" \
  > "$REVIEW_WALL/REVIEW-FAILED-1/status"
serve "$REVIEW_WALL" "$ROOT/review-wall.log"; REVIEW_PORT="$PORT_OUT"
if [ -n "$REVIEW_PORT" ]; then
  REVIEW_API="$(get "$REVIEW_PORT" /api/runs)"
  review_state_of() {
    printf '%s' "$REVIEW_API" | jq -r --arg id "$1" \
      '.runs[] | select(.id==$id) | .'"$2"
  }
  check "actor: a review no tier completed is not attributed to Codex" \
    "$(review_state_of UNREVIEWED-1 actor)" "unreviewed"
  check "actor: the wall exposes the matching failure key" \
    "$(review_state_of UNREVIEWED-1 actorKey)" "unreviewed"
  check "floor: review_failed parks on REVIEW, not PUSH" \
    "$(review_state_of REVIEW-FAILED-1 floor)" "3"
  check "state: review_failed is terminal failure" \
    "$(review_state_of REVIEW-FAILED-1 state)" "failed"
else
  bad "review attribution: server starts against focused fixtures"
fi

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

# --- the week's city ------------------------------------------------------------
# The other half of the wall. The skyline above is live and leaves nothing
# behind; the district accretes — every run that reaches `done: ready` since
# Monday 00:00 local is a permanent building, and last week's is a flat ghost
# behind it. The ledger is rendered per poll, so the rules are arithmetic over a
# run id, a finish epoch and a diff — exercised out of the real server.js rather
# than restated here, the same way the weather is.
echo "== wall: the week's rules =="
CITY_PROBE="$ROOT/city-probe.js"
cat > "$CITY_PROBE" <<'JS'
const w = require(process.argv[2]);
const now = Number(process.argv[3]);
const start = w.weekStartOf(now);
const monday = new Date(start * 1000);
const prev = w.weekStartOf(start - 1);
const next = w.weekEndOf(now);

// Which window a finish epoch lands in, straight through the real builder. A
// ledger line is all it gets: the run dir it came from may have been cleaned up
// weeks ago, and the building has to stand anyway.
const line = (id, epoch) => ({ id, epoch, repo: '', owner: '', insertions: 0, deletions: 0 });
const bucket = (epoch) => {
  const built = w.buildCity([line('EDGE-1', epoch)], now);
  return built.city.length ? 'city' : built.ghost.length ? 'ghost' : 'gone';
};

const ids = [];
for (let i = 0; i < 160; i++) ids.push('OLYX-' + (1500 + i));
const bands = [0, 0, 0, 0, 0];
const depths = [0, 0, 0];
for (const id of ids) {
  const plot = w.plotOf(id);
  bands[Math.min(4, Math.floor(plot.x * 5))] += 1;
  depths[plot.depth] += 1;
}

// The ledger, as text: junk lines are skipped rather than fatal, a line missing
// either of the two things the city cannot invent is junk, and a run id that
// appears twice — which is exactly what a mirrored dir discovered beside a local
// one produces — keeps its FIRST line.
const ledger = w.parseLedger([
  JSON.stringify({ id: 'MIR-1', epoch: 100, repo: 'olyxbase', owner: 'angel', insertions: 10, deletions: 2 }),
  '{ half a line written when the power went',
  '',
  JSON.stringify({ id: 'MIR-1', epoch: 400, repo: 'olyxbase', owner: 'emre', insertions: 99, deletions: 9 }),
  JSON.stringify({ epoch: 200, repo: 'olyxbase' }),
  JSON.stringify({ id: 'MIR-3', repo: 'olyxbase' }),
  JSON.stringify({ id: 'MIR-BAD-EPOCH', epoch: null, repo: 'olyxbase' }),
  JSON.stringify({ id: { nested: true }, epoch: 200, repo: 'olyxbase' }),
  JSON.stringify({ id: 'MIR-2', epoch: 200, repo: 'olyx-agents', owner: 'bot', insertions: 5, deletions: 0 }),
].join('\n'));
const kept = ledger.records.get('MIR-1') || {};

const sample = w.buildCity([line('NOW-1', start + 10), line('OLD-1', prev + 10)], now);
const storeys = (n) => w.storeysOf({ insertions: n, deletions: 0 });

console.log(JSON.stringify({
  mondayDay: monday.getDay(),
  mondayClock: [monday.getHours(), monday.getMinutes(), monday.getSeconds()].join(':'),
  weekSane: (start - prev) >= 167 * 3600 && (start - prev) <= 169 * 3600,
  idempotent: w.weekStartOf(start) === start,
  onTheEdge: bucket(start),
  oneSecondBefore: bucket(start - 1),
  lastMonday: bucket(prev),
  oneSecondBeforeThat: bucket(prev - 1),
  rightNow: bucket(now),
  lastSecondThisWeek: bucket(next - 1),
  nextMonday: bucket(next),
  kinds: ['olyx-agents', 'olyxbase', 'olyx-dashboard', 'olyxdashboard',
          'valoryx-intelligence', 'valoryx-graphql-api', 'dispatch-harness',
          'somebody-elses-repo', ''].map(w.kindOf).join(','),
  storeys: [0, 20, 200, 2000].map(storeys).join(','),
  storeysFloor: w.storeysOf(undefined) === w.STOREYS_MIN
    && w.storeysOf({ insertions: 'nonsense', deletions: null }) === w.STOREYS_MIN,
  storeysRise: storeys(20) > storeys(0) && storeys(400) > storeys(20),
  storeysCapped: storeys(400000) === storeys(2000) && storeys(2000) === w.STOREYS_MAX,
  resultShapes: [
    { metrics: { diff: { insertions: 0, deletions: null } } },
    true,
    [],
    {},
    { metrics: { diff: {} } },
    { metrics: { diff: { insertions: '12', deletions: 1 } } },
    { metrics: { diff: { insertions: -1, deletions: 1 } } },
  ].map((result) => Boolean(w.shippedDiffOf(result))).join(','),
  plotStable: JSON.stringify(w.plotOf('OLYX-1598')) === JSON.stringify(w.plotOf('OLYX-1598')),
  plotDiffers: JSON.stringify(w.plotOf('OLYX-1598')) !== JSON.stringify(w.plotOf('OLYX-1599')),
  plotInFrame: [...ids, 'adhoc-thing'].every((id) => {
    const plot = w.plotOf(id);
    return plot.x >= 0 && plot.x < 1 && plot.depth >= 0 && plot.depth < 3;
  }),
  plotSpread: bands.every((n) => n > 0),
  depthSpread: depths.every((n) => n > 0),
  ledgerKept: [...ledger.records.keys()].sort().join(','),
  ledgerSkipped: ledger.skipped,
  ledgerFirstWins: kept.epoch + '/' + kept.owner,
  ledgerFields: Object.keys(kept).sort().join(','),
  ghostKeys: Object.keys(sample.ghost[0] || {}).sort().join(','),
  ghostEmpty: w.buildCity([line('NOW-1', start + 10)], now).ghost.length,
  weekShips: sample.week.ships,
  lifeKeys: Object.keys(w.lifeOf(1)).sort().join(','),
  life: [0, 2, 3, 9, 10, 19, 20, 90].map((n) => {
    const plan = w.lifeOf(n);
    return n + ':' + plan.movers + (plan.shops ? 'S' : '-') + (plan.tram ? 'T' : '-');
  }).join(' '),
  signHours: w.SIGN_S / 3600,
}));
JS
CITY="$(node "$CITY_PROBE" "$SRC/wall/server.js" "$(date +%s)" 2>&1)"
city_of() { printf '%s' "$CITY" | jq -r ".$1" 2>/dev/null; }
check "week: the window opens on a Monday"        "$(city_of mondayDay)" "1"
check "week: at midnight, local time"             "$(city_of mondayClock)" "0:0:0"
check "week: the previous window is one week long, DST included" \
  "$(city_of weekSane)" "true"
check "week: a Monday is its own week's start"    "$(city_of idempotent)" "true"
check "week: a run finishing exactly at 00:00 belongs to the new week" \
  "$(city_of onTheEdge)" "city"
check "week: one second earlier belongs to the old one"  "$(city_of oneSecondBefore)" "ghost"
check "week: last Monday 00:00 is still the ghost"       "$(city_of lastMonday)" "ghost"
check "week: one second before that is gone entirely"    "$(city_of oneSecondBeforeThat)" "gone"
check "week: something that shipped just now is standing" "$(city_of rightNow)" "city"
check "week: the current window includes its final second" \
  "$(city_of lastSecondThisWeek)" "city"
check "week: the next Monday is outside this week's city" \
  "$(city_of nextMonday)" "gone"
check "type: the repo family names the building" "$(city_of kinds)" \
  "residential,industrial,industrial,industrial,spire,spire,infra,midrise,midrise"
check "height: the diff, log-scaled"  "$(city_of storeys)" "3,7,11,14"
check "height: an unreadable diff is the shortest building, never an invented one" \
  "$(city_of storeysFloor)" "true"
check "height: more lines is a taller building" "$(city_of storeysRise)" "true"
check "height: and a monster PR stops growing"  "$(city_of storeysCapped)" "true"
check "tolerance: only a result-shaped JSON value supplies a building diff" \
  "$(city_of resultShapes)" "true,false,false,false,false,false,false"
check "plot: the same run stands on the same spot, always" "$(city_of plotStable)" "true"
check "plot: two runs do not pile onto one"      "$(city_of plotDiffers)" "true"
check "plot: every building is inside the frame" "$(city_of plotInFrame)" "true"
check "plot: a ticket range spreads across the district"  "$(city_of plotSpread)" "true"
check "plot: and across all three depth bands"            "$(city_of depthSpread)" "true"
check "ledger: junk lines are skipped, never fatal" "$(city_of ledgerSkipped)" "5"
check "mirror: one line per run id survives the read" \
  "$(city_of ledgerKept)" "MIR-1,MIR-2"
check "mirror: and the first sighting is the one that stands" \
  "$(city_of ledgerFirstWins)" "100/angel"
check "ledger: a record carries what a building is made of, and no more" \
  "$(city_of ledgerFields)" "deletions,epoch,id,insertions,owner,repo"
check "ghost: last week is a height and a plot, nothing else" \
  "$(city_of ghostKeys)" "storeys,x"
check "ghost: an empty last week draws no ghost at all" "$(city_of ghostEmpty)" "0"
check "week: the ship count is this week's buildings" "$(city_of weekShips)" "1"
check "life: the server payload keeps its established keys" \
  "$(city_of lifeKeys)" "movers,shops,tram"
check "life: the server's established presentation contract is unchanged" \
  "$(city_of life)" "0:0-- 2:0-- 3:1-- 9:3-- 10:3S- 19:6S- 20:6ST 90:8ST"
check "sign: a dispatcher's tint lasts about a shift" "$(city_of signHours)" "6"

# --- where the city's memory lives ------------------------------------------------
# The ledger is the whole point of the amendment: a run dir is not permanent
# (cleanup.sh promotes a run, mirror_remove() deletes the mirrored copy), so the
# city cannot be derived from one.
echo "== wall: the city ledger =="
city_file() { WALL_RUNS="$1" WALL_CITY="${2:-}" node -e \
  'process.stdout.write(require(process.argv[1]).CITY_FILE)' "$SRC/wall/server.js"; }
check "ledger: it lands beside the runs dir by default" \
  "$(city_file /var/harness/runs)" "/var/harness/wall-city.jsonl"
check "ledger: a trailing slash on the runs dir does not move it" \
  "$(city_file /var/harness/runs/)" "/var/harness/wall-city.jsonl"
check "ledger: and WALL_CITY puts it wherever you want it" \
  "$(city_file /var/harness/runs /elsewhere/demo.jsonl)" "/elsewhere/demo.jsonl"

# --- the district, end to end ---------------------------------------------------
echo "== wall: the district accretes =="
WEEK="$ROOT/week"
WEEK_CITY="$ROOT/week-city.jsonl"
mkdir -p "$WEEK"
# Both window edges from the server's own function rather than from a second
# implementation of "Monday" in shell, which would drift the first time one of
# them learned something about DST.
WEEK_EDGES="$(node -e 'const w = require(process.argv[1]);
  const start = w.weekStartOf(Math.floor(Date.now() / 1000));
  console.log(start, w.weekStartOf(start - 1));' "$SRC/wall/server.js")"
MONDAY="${WEEK_EDGES% *}"
LAST_MONDAY="${WEEK_EDGES#* }"
NEXT_MONDAY="$(node -e 'const w = require(process.argv[1]);
  process.stdout.write(String(w.weekEndOf(Math.floor(Date.now() / 1000))));' "$SRC/wall/server.js")"
# Last week's ledger, as the wall that was running last week left it — plus one
# entry old enough that Monday's rollover has to prune it, and one line of junk.
led() {  # $1 = id, $2 = epoch, $3 = repo, $4 = owner, $5 = insertions
  printf '{"id":"%s","epoch":%s,"repo":"%s","owner":"%s","insertions":%s,"deletions":0}\n' \
    "$1" "$2" "$3" "$4" "$5" >> "$WEEK_CITY"
}
led GHOST-SUN "$((MONDAY - 1))"       olyxbase    emre  300
led GHOST-MON "$LAST_MONDAY"          olyx-agents angel 90
led ANCIENT-1 "$((LAST_MONDAY - 1))"  olyxbase    angel 500
printf 'half a line written when the power went\n' >> "$WEEK_CITY"
# $1 = id, $2 = finish epoch, $3 = project ('-' = unreadable), $4 = stage,
# $5 = insertions ('-' = no result.json, 'junk' = caught mid-write, 'shape' =
# valid JSON but not a result document, 'flat' = a zero-line diff)
ship_run() {
  mkdir -p "$WEEK/$1"
  printf '%s %s\n' "$2" "$4" > "$WEEK/$1/status"
  [ "$3" = '-' ] || printf '/tmp/%s-%s\n' "$3" "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" \
    > "$WEEK/$1/worktree"
  case "$5" in
    -) ;;
    junk) printf '{"metrics": {"diff": {"inser' > "$WEEK/$1/result.json" ;;
    shape) printf 'true\n' > "$WEEK/$1/result.json" ;;
    flat) printf '{"metrics":{"diff":{"insertions":0,"deletions":0}}}\n' \
      > "$WEEK/$1/result.json" ;;
    *) printf '{"metrics":{"diff":{"insertions":%s,"deletions":0}}}\n' "$5" \
         > "$WEEK/$1/result.json" ;;
  esac
}
ship_run SHIP-EDGE  "$MONDAY"          olyx-agents          'done: ready' 40
ship_run SHIP-BIG   "$((MONDAY + 60))" olyxbase             'done: ready' 1800
ship_run SHIP-SPIRE "$((MONDAY + 70))" valoryx-intelligence 'done: ready' 260
ship_run SHIP-INFRA "$((MONDAY + 80))" dispatch-harness     'done: ready' 150
ship_run SHIP-FLAT  "$((MONDAY + 90))" olyxbase             'done: ready' flat
ship_run SHIP-JUNK  "$((MONDAY + 100))" olyxbase            'done: ready' junk
ship_run SHIP-BARE  "$((MONDAY + 110))" olyxbase            'done: ready' -
ship_run SHIP-SHAPE "$((MONDAY + 120))" olyxbase            'done: ready' shape
ship_run SHIP-FUTURE "$NEXT_MONDAY"      olyxbase            'done: ready' 90
ship_run LIVE-W     "$(date +%s)"      olyxbase             'implementing — Opus (Claude sub)' -
ship_run BURNT-W    "$((MONDAY + 200))" olyxbase            'done: rejected' 120
ship_run SYNCED-W   "$((MONDAY + 210))" olyxbase 'done: PR branch synced with main, gate green, pushed' 120
printf 'reinier\n' > "$WEEK/SHIP-EDGE/owner"
serve "$WEEK" "$ROOT/week.log" --city "$WEEK_CITY"; WEEK_PORT="$PORT_OUT"
if [ -n "$WEEK_PORT" ]; then
  WEEK_API="$(get "$WEEK_PORT" /api/runs)"
  city_at() { printf '%s' "$WEEK_API" | jq -r --arg id "$1" '.city[] | select(.id==$id) | .'"$2"; }
  check "district: the window opens where the server says it does" \
    "$(printf '%s' "$WEEK_API" | jq -r '.week.start')" "$MONDAY"
  check "district: this week's ships are standing" \
    "$(printf '%s' "$WEEK_API" | jq -r '[.city[].id] | sort | join(",")')" \
    "SHIP-BIG,SHIP-EDGE,SHIP-FLAT,SHIP-INFRA,SHIP-SPIRE"
  check "district: a run finishing on the stroke of Monday is this week's" \
    "$(city_at SHIP-EDGE at)" "$MONDAY"
  check "district: a future window is neither rendered nor recorded early" \
    "$(grep -c 'SHIP-FUTURE' "$WEEK_CITY")" "0"
  check "district: last week's ledger stands behind it as the ghost" \
    "$(printf '%s' "$WEEK_API" | jq '.ghost | length')" "2"
  check "district: only a done: ready builds — a rejection does not" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="BURNT-W")] | length')" "0"
  check "district: nor does sync-pr.sh's prose done line" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="SYNCED-W")] | length')" "0"
  check "district: a live run is in the skyline, not in the district" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="LIVE-W")] | length')" "0"
  check "district: the ship count agrees with what is standing" \
    "$(printf '%s' "$WEEK_API" | jq '.week.ships')" "5"
  check "type: agent work is residential"     "$(city_at SHIP-EDGE kind)" "residential"
  check "type: the data repo is industrial"   "$(city_at SHIP-BIG kind)"  "industrial"
  check "type: valoryx is a spire"            "$(city_at SHIP-SPIRE kind)" "spire"
  check "type: the harness itself is infrastructure" "$(city_at SHIP-INFRA kind)" "infra"
  check "height: the big diff is the tall building" \
    "$(printf '%s' "$WEEK_API" | jq '(.city[] | select(.id=="SHIP-BIG") | .storeys) > (.city[] | select(.id=="SHIP-EDGE") | .storeys)')" "true"
  # A building is a record of a real diff. A result.json that is missing or
  # caught mid-write is skipped silently and retried; only a file that was
  # actually readable — and simply recorded nothing — is a minimum-height
  # building. Inventing a height from a file we could not read is the one thing
  # that would make the city lie.
  check "tolerance: a half-written result.json builds nothing, and does not crash" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="SHIP-JUNK")] | length')" "0"
  check "tolerance: neither does a run with no result.json at all" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="SHIP-BARE")] | length')" "0"
  check "tolerance: valid JSON without the result schema is still malformed" \
    "$(printf '%s' "$WEEK_API" | jq '[.city[] | select(.id=="SHIP-SHAPE")] | length')" "0"
  check "tolerance: a recorded zero-line diff is the shortest building" \
    "$(city_at SHIP-FLAT storeys)" "3"
  check "sign: a building carries its dispatcher, and their kind" \
    "$(city_at SHIP-EDGE owner),$(city_at SHIP-EDGE ownerKind)" "reinier,human"
  check "sign: an unowned ship is not mis-attributed" \
    "$(city_at SHIP-BIG ownerKind)" "unowned"
  check "sign: the fade is timed by the server, like the completion moment" \
    "$(printf '%s' "$WEEK_API" | jq '.signSeconds')" "21600"
  # No per-person zones, no cumulative anything: a building carries exactly what
  # it takes to draw one, and the standing anti-blame rule is a shape, not prose.
  check "district: a building carries nothing but what draws it" \
    "$(printf '%s' "$WEEK_API" | jq -r '[.city[] | keys] | flatten | unique | join(",")')" \
    "at,depth,id,kind,owner,ownerKind,project,storeys,x"
  check "district: and no per-person aggregate exists anywhere in the snapshot" \
    "$(printf '%s' "$WEEK_API" | jq -r '[paths | map(tostring) | join(".")] | map(select(test("lane|district|byOwner"))) | length')" "0"

  # Monday's rollover, on disk: what has fallen out of both windows is gone from
  # the file, not merely hidden — and the rewrite drops the junk line with it.
  check "rollover: the ledger keeps only the two windows it can draw" \
    "$(jq -r '.id' < "$WEEK_CITY" | sort | tr '\n' ' ')" \
    "GHOST-MON GHOST-SUN SHIP-BIG SHIP-EDGE SHIP-FLAT SHIP-INFRA SHIP-SPIRE "
  check "rollover: and the rewrite leaves a file that parses cleanly" \
    "$(jq -s 'length' < "$WEEK_CITY")" "7"
  # Discovery only ever records THIS week: the ledger is what the wall witnessed,
  # not a history it went looking for.
  check "ledger: a run that finished last week is not backfilled from its dir" \
    "$(grep -c 'ANCIENT-1' "$WEEK_CITY")" "0"
  # The district's dedication is drawn by the page and by nothing else. It is not
  # a run, so it may not appear in the ledger the wall writes, in the city the
  # server serves, or anywhere else in the snapshot.
  check "landmark: the dedication is never written to the ledger" \
    "$(grep -c '冉' "$WEEK_CITY")" "0"
  check "landmark: nor does it reach the snapshot the server serves" \
    "$(printf '%s' "$WEEK_API" | grep -c '冉')" "0"

  # A skyline the room can learn: the same week drawn by a second process puts
  # every building on the same plot.
  serve "$WEEK" "$ROOT/week2.log" --city "$WEEK_CITY"; WEEK_TWO="$PORT_OUT"
  if [ -n "$WEEK_TWO" ]; then
    WEEK_TWO_API="$(get "$WEEK_TWO" /api/runs)"
    check "plot: a second wall draws the identical district" \
      "$(printf '%s' "$WEEK_TWO_API" | jq -r '[.city[] | "\(.id):\(.x).\(.depth)"] | join(",")')" \
      "$(printf '%s' "$WEEK_API" | jq -r '[.city[] | "\(.id):\(.x).\(.depth)"] | join(",")')"
    check "plot: and the identical ghost behind it" \
      "$(printf '%s' "$WEEK_TWO_API" | jq -r '[.ghost[] | "\(.x).\(.storeys)"] | join(",")')" \
      "$(printf '%s' "$WEEK_API" | jq -r '[.ghost[] | "\(.x).\(.storeys)"] | join(",")')"
    check "ledger: a second wall on the same ledger appends nothing new" \
      "$(jq -s 'length' < "$WEEK_CITY")" "7"
  else
    bad "plot: a second wall starts against the same week"
  fi
else
  bad "district: server starts against a fresh week"
fi

# --- a building outlives its run dir ---------------------------------------------
# The reason the ledger exists. cleanup.sh removes a promoted run's worktree and
# mirror_remove() deletes the mirrored run dir off this machine — neither is in
# this feature's scope, and neither may demolish a building.
echo "== wall: a building outlives the run dir it came from =="
KEEP="$ROOT/persist"
KEEP_CITY="$ROOT/persist-city.jsonl"
mkdir -p "$KEEP/PERSIST-1"
printf '%s done: ready\n' "$((MONDAY + 400))" > "$KEEP/PERSIST-1/status"
printf '/tmp/olyxbase-persist-1\n' > "$KEEP/PERSIST-1/worktree"
printf 'angel\n' > "$KEEP/PERSIST-1/owner"
printf '{"metrics":{"diff":{"insertions":120,"deletions":30}}}\n' > "$KEEP/PERSIST-1/result.json"
serve "$KEEP" "$ROOT/persist.log" --city "$KEEP_CITY"; KEEP_PORT="$PORT_OUT"
if [ -n "$KEEP_PORT" ]; then
  check "persist: the ship is discovered and stands" \
    "$(get "$KEEP_PORT" /api/runs | jq -r '[.city[].id] | join(",")')" "PERSIST-1"
  check "ledger: a missing file is reported once while the wall starts empty" \
    "$(grep -c 'city ledger missing' "$ROOT/persist.log")" "1"
  # Several more polls: the ledger is append-once, not append-per-poll.
  get "$KEEP_PORT" /api/runs > /dev/null
  get "$KEEP_PORT" /api/runs > /dev/null
  check "persist: repeated polls append one line, not one per poll" \
    "$(grep -c 'PERSIST-1' "$KEEP_CITY")" "1"
  # cleanup.sh, or mirror_remove(), taking the run dir away.
  rm -rf "$KEEP/PERSIST-1"
  KEEP_API="$(get "$KEEP_PORT" /api/runs)"
  check "persist: the run has left the disk entirely" \
    "$(printf '%s' "$KEEP_API" | jq '.runs | length')" "0"
  check "persist: and the building it left behind is still standing" \
    "$(printf '%s' "$KEEP_API" | jq -r '[.city[].id] | join(",")')" "PERSIST-1"
  check "persist: with everything it needs to be drawn" \
    "$(printf '%s' "$KEEP_API" | jq -r '.city[0] | "\(.kind):\(.storeys):\(.owner)"')" \
    "industrial:10:angel"
  # A mirrored copy of the same run arriving afterwards, with a later status: one
  # run id is one building, and the first sighting is the one that stands.
  mkdir -p "$KEEP/PERSIST-1"
  printf '%s done: ready\n' "$((MONDAY + 9000))" > "$KEEP/PERSIST-1/status"
  printf '/tmp/olyx-agents-persist-1\n' > "$KEEP/PERSIST-1/worktree"
  printf '{"metrics":{"diff":{"insertions":4000,"deletions":0}}}\n' > "$KEEP/PERSIST-1/result.json"
  MIRROR_API="$(get "$KEEP_PORT" /api/runs)"
  check "mirror: a duplicate sighting appends no second line" \
    "$(grep -c 'PERSIST-1' "$KEEP_CITY")" "1"
  # The second sighting is a taller diff in a different repo, so every field
  # here would move if the wall had let it overwrite the first.
  check "mirror: and the building is the one the wall saw first" \
    "$(printf '%s' "$MIRROR_API" | jq -r '.city[0] | "\(.kind):\(.storeys):\(.at)"')" \
    "industrial:10:$((MONDAY + 400))"
  # Reboot: a fresh process with the run dir gone reads the city off the ledger.
  rm -rf "$KEEP/PERSIST-1"
  serve "$KEEP" "$ROOT/persist2.log" --city "$KEEP_CITY"; KEEP_TWO="$PORT_OUT"
  if [ -n "$KEEP_TWO" ]; then
    check "persist: a restarted wall rebuilds the city from the ledger alone" \
      "$(get "$KEEP_TWO" /api/runs | jq -r '[.city[].id] | join(",")')" "PERSIST-1"
  else
    bad "persist: a restarted wall starts against the same ledger"
  fi
else
  bad "persist: server starts against a run about to be cleaned up"
fi

# A write failure may make the building session-only for a moment, but it must
# not become session-only forever. Once the path is writable, a later poll
# persists the pending record without duplicating it.
echo "== wall: a transient ledger write failure =="
RETRY="$ROOT/retry"
RETRY_CITY="$ROOT/retry-city.jsonl"
mkdir -p "$RETRY/RETRY-1" "$RETRY_CITY"
printf '%s done: ready\n' "$((MONDAY + 500))" > "$RETRY/RETRY-1/status"
printf '/tmp/olyxbase-retry-1\n' > "$RETRY/RETRY-1/worktree"
printf '{"metrics":{"diff":{"insertions":40,"deletions":2}}}\n' > "$RETRY/RETRY-1/result.json"
serve "$RETRY" "$ROOT/retry.log" --city "$RETRY_CITY"; RETRY_PORT="$PORT_OUT"
if [ -n "$RETRY_PORT" ]; then
  check "ledger: a temporary write failure does not hide the building" \
    "$(get "$RETRY_PORT" /api/runs | jq -r '[.city[].id] | join(",")')" "RETRY-1"
  rmdir "$RETRY_CITY"
  get "$RETRY_PORT" /api/runs >/dev/null
  check "ledger: the next poll retries and persists the pending building" \
    "$(grep -c 'RETRY-1' "$RETRY_CITY")" "1"
  get "$RETRY_PORT" /api/runs >/dev/null
  check "ledger: a successful retry is still append-once" \
    "$(grep -c 'RETRY-1' "$RETRY_CITY")" "1"
else
  bad "ledger: server starts against a temporarily unwritable ledger"
fi

# An unreadable ledger is an empty plain and a line on stderr — never a crash,
# and never a wall that refuses to serve.
echo "== wall: an unreadable ledger =="
BUSTED="$ROOT/busted"
mkdir -p "$BUSTED" "$ROOT/busted-city.jsonl"   # a directory where a file belongs
serve "$BUSTED" "$ROOT/busted.log" --city "$ROOT/busted-city.jsonl"; BUSTED_PORT="$PORT_OUT"
if [ -n "$BUSTED_PORT" ]; then
  ok "ledger: an unreadable ledger still serves the wall"
  check "ledger: it starts from an empty plain" \
    "$(get "$BUSTED_PORT" /api/runs | jq '.city | length')" "0"
  check "ledger: and says so once, rather than dying" \
    "$(grep -c 'city ledger unreadable' "$ROOT/busted.log")" "1"
else
  bad "ledger: an unreadable ledger still serves the wall"
fi

# A very good week is still a city: the district is not capped by the JSON feed's
# finished-run cap, the population tops out, and every milestone is lit.
echo "== wall: a week that shipped thirty things =="
BUSY_WEEK="$ROOT/busy-week"
mkdir -p "$BUSY_WEEK"
for i in $(seq 1 30); do
  mkdir -p "$BUSY_WEEK/SHIPPED-$i"
  printf '%s done: ready\n' "$((MONDAY + i))" > "$BUSY_WEEK/SHIPPED-$i/status"
  printf '/tmp/olyx-agents-shipped-%s\n' "$i" > "$BUSY_WEEK/SHIPPED-$i/worktree"
  printf '{"metrics":{"diff":{"insertions":%s,"deletions":7}}}\n' "$((i * 13))" \
    > "$BUSY_WEEK/SHIPPED-$i/result.json"
done
serve "$BUSY_WEEK" "$ROOT/busy-week.log"; BUSY_WEEK_PORT="$PORT_OUT"
if [ -n "$BUSY_WEEK_PORT" ]; then
  BUSY_WEEK_API="$(get "$BUSY_WEEK_PORT" /api/runs)"
  check "district: the JSON feed's history cap never truncates the week" \
    "$(printf '%s' "$BUSY_WEEK_API" | jq '.city | length')" "30"
  check "district: while the run feed stays capped, as it always was" \
    "$(printf '%s' "$BUSY_WEEK_API" | jq '[.runs[] | select(.state=="ready")] | length')" "24"
  check "life: thirty ships retain the established server milestones" \
    "$(printf '%s' "$BUSY_WEEK_API" | jq -r '.week.life | "\(.movers),\(.shops),\(.tram)"')" \
    "8,true,true"
else
  bad "life: server starts against a very good week"
fi

# The other end of the same contract, and the one the brief is actually about: a
# week that has shipped exactly once is a lit, populated street — not a dark
# plain waiting for a milestone.
echo "== wall: a week that shipped one thing =="
LONE="$ROOT/lone-week"
mkdir -p "$LONE/LONE-1"
printf '%s done: ready\n' "$((MONDAY + 300))" > "$LONE/LONE-1/status"
printf '/tmp/olyx-agents-lone-1\n' > "$LONE/LONE-1/worktree"
printf '{"metrics":{"diff":{"insertions":60,"deletions":4}}}\n' > "$LONE/LONE-1/result.json"
serve "$LONE" "$ROOT/lone-week.log"; LONE_PORT="$PORT_OUT"
if [ -n "$LONE_PORT" ]; then
  LONE_API="$(get "$LONE_PORT" /api/runs)"
  check "life: one shipped building reaches the page as the density input" \
    "$(printf '%s' "$LONE_API" | jq -r '.week.ships')" "1"
  check "life: without changing the established server life payload" \
    "$(printf '%s' "$LONE_API" | jq -r '.week.life | "\(.movers),\(.shops),\(.tram)"')" \
    "0,false,false"
else
  bad "life: server starts against a week that shipped once"
fi

# --- the painted sky ----------------------------------------------------------
# Three hand-drawn parallax planes fill most of this screen, so a run of similar
# flat-topped rectangles is most of what the room sees. The structure is pinned
# (three groups, two reusable paths, one window pattern drawn through them) and
# so is the shape of the city they draw: mixed heights, sloped and stepped
# rooflines, roof furniture, and only a little of it tall.
echo "== wall: the painted sky is a city, not a fence =="
grep_ok "$PAGE_SRC" '<pattern id="farlights"' "sky: distant windows are still one pattern"
for plane in far mid near; do
  grep_ok "$PAGE_SRC" "class=\"sky__$plane\"" "sky: the $plane plane is its own group"
done
for line in farline midline; do
  grep_ok "$PAGE_SRC" "<use href=\"#$line\" fill=\"url(#farlights)\"" \
    "sky: #$line is drawn twice, once through the window pattern"
done
SKY_PROBE="$ROOT/sky-probe.js"
cat > "$SKY_PROBE" <<'JS'
// Read the three painted silhouettes out of the page and describe the city they
// draw. Everything here is measured off the path data itself: the point is that
// nothing restates the drawing, so a redraw that flattens it back into a fence
// fails rather than passing on a comment.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const open = html.indexOf('<svg class="sky"');
const sky = html.slice(open, html.indexOf('</svg>', open));

function pathOf(plane) {
  const at = sky.indexOf('class="sky__' + plane + '"');
  if (at < 0) return '';
  // The leading space matters: `id="farline"` ends in `d="farline"`.
  const d = /\sd="([^"]*)"/.exec(sky.slice(at));
  return d ? d[1] : '';
}

// The rooftops, as horizontal runs. Only the absolute M/H/V/L vocabulary the
// three planes are drawn in — an unknown command is a parse failure, not a
// silently empty profile.
function roofs(d) {
  const runs = [];
  let x = 0, y = 0, bad = 0;
  for (const token of d.trim().split(/(?=[A-Za-z])/)) {
    const cmd = token.trim()[0];
    const nums = token.trim().slice(1).trim().split(/[\s,]+/).filter(Boolean).map(Number);
    if (cmd === 'M') { [x, y] = nums; }
    else if (cmd === 'V') { y = nums[0]; }
    else if (cmd === 'H') { runs.push({ w: Math.abs(nums[0] - x), y, slope: false }); x = nums[0]; }
    else if (cmd === 'L') {
      runs.push({ w: Math.abs(nums[0] - x), y: (y + nums[1]) / 2, slope: true });
      [x, y] = nums;
    } else if (cmd !== 'Z') bad++;
  }
  return { runs, bad };
}

const report = {};
for (const plane of ['far', 'mid', 'near']) {
  const { runs, bad } = roofs(pathOf(plane));
  const flats = runs.filter((r) => !r.slope && r.w > 0);
  const ys = runs.map((r) => r.y);
  const high = Math.min(...ys), low = Math.max(...ys);
  const band = low - high;
  // Roof furniture: a narrow run standing well clear of what is either side of
  // it — a mast, an antenna, a water tower's vent.
  let spikes = 0;
  for (let i = 1; i < flats.length - 1; i++) {
    if (flats[i].w <= 8 && flats[i - 1].y - flats[i].y > 40 && flats[i + 1].y - flats[i].y > 40) spikes++;
  }
  const span = (test) => flats.filter(test).reduce((n, r) => n + r.w, 0)
    / flats.reduce((n, r) => n + r.w, 0);
  report[plane] = {
    parsed: bad === 0 && flats.length > 0,
    levels: new Set(flats.map((r) => r.y)).size,
    band: Math.round(band),
    slopes: runs.filter((r) => r.slope).length,
    spikes,
    // Mixed, and mixed the right way round: most of the width is low or mid
    // rise, and only a little of it is genuinely tall.
    lowish: span((r) => r.y > high + band * 0.5) > 0.5,
    towers: span((r) => r.y < high + band * 0.3) < 0.2,
  };
}
console.log(JSON.stringify(report));
JS
SKY="$(node "$SKY_PROBE" "$SRC/wall/index.html" 2>&1)"
sky_of() { printf '%s' "$SKY" | jq -r ".$1" 2>/dev/null; }
for plane in far mid near; do
  check "sky: the $plane plane parses as one absolute-coordinate silhouette" \
    "$(sky_of "$plane.parsed")" "true"
  if [ "$(sky_of "$plane.levels")" -ge 20 ] 2>/dev/null; then
    ok "sky: the $plane plane draws many different roof heights ($(sky_of "$plane.levels"))"
  else
    bad "sky: the $plane plane draws many different roof heights ($(sky_of "$plane.levels"))"
  fi
  if [ "$(sky_of "$plane.band")" -ge 140 ] 2>/dev/null; then
    ok "sky: and spans a real height range ($(sky_of "$plane.band"))"
  else
    bad "sky: and spans a real height range ($(sky_of "$plane.band"))"
  fi
  if [ "$(sky_of "$plane.slopes")" -ge 3 ] 2>/dev/null; then
    ok "sky: the $plane plane is not all flat tops ($(sky_of "$plane.slopes") sloped)"
  else
    bad "sky: the $plane plane is not all flat tops ($(sky_of "$plane.slopes") sloped)"
  fi
  if [ "$(sky_of "$plane.spikes")" -ge 2 ] 2>/dev/null; then
    ok "sky: and carries roof furniture ($(sky_of "$plane.spikes") masts or vents)"
  else
    bad "sky: and carries roof furniture ($(sky_of "$plane.spikes") masts or vents)"
  fi
  check "sky: most of the $plane plane is low or mid rise" "$(sky_of "$plane.lowish")" "true"
  check "sky: and only a little of it is a skyscraper" "$(sky_of "$plane.towers")" "true"
done

# --- what the district looks like -------------------------------------------------
# The page half of the same contract: the plate that used to fire on an empty
# skyline must not fire on a full week, buildings land once and then stop, and
# the only attribution on the layer is one sign that cools.
echo "== wall: the district on screen =="
grep_ok "$PAGE_SRC" 'id="district"' "district: the week's buildings have their own layer"
grep_ok "$PAGE_SRC" 'id="ghost"'    "district: and last week has its own behind it"
grep_ok "$PAGE_SRC" "ghostLayer.toggleAttribute('hidden'" \
  "ghost: the SVG layer is unhidden when last week exists"
GHOST_LINE="$(grep -n 'id="ghost"' "$SRC/wall/index.html" | cut -d: -f1)"
FAR_LINE="$(grep -n 'class="sky__far"' "$SRC/wall/index.html" | cut -d: -f1)"
if [ -n "$GHOST_LINE" ] && [ -n "$FAR_LINE" ] && [ "$GHOST_LINE" -lt "$FAR_LINE" ]; then
  ok "ghost: last week is painted behind every parallax skyline plane"
else
  bad "ghost: last week is painted behind every parallax skyline plane"
fi
grep_ok "$PAGE_SRC" "towers.length ? 'off' : blocks.length ? 'rest' : 'empty'" \
  "idle: the plate needs an empty week, not just an empty skyline"
grep_ok "$CSS_SRC" 'body[data-idle="empty"] .idle' "idle: the full plate is gated on that"
grep_ok "$CSS_SRC" 'body[data-idle="rest"] .rest' \
  "idle: a week with buildings and nothing live gets the quiet line"
grep_ok "$PAGE_SRC" 'DISTRICT AT REST' "idle: and the line says what is actually true"
grep_not "$PAGE_SRC" 'body:has(.city[data-empty="1"]) .idle' \
  "idle: the old empty-skyline rule is gone, not left shadowing it"
grep_ok "$PAGE_SRC" 'if (!B) { B = makeBlock();' \
  "district: a building is written once, when it lands"
grep_ok "$CSS_SRC" 'animation: settle var(--settle) var(--ease) backwards' \
  "district: it arrives with one settle"
grep_not "$CSS_SRC" '.district { transform-origin' \
  "district: after settling, shipped buildings are not kept in a camera loop"
grep_ok "$CSS_SRC" 'animation: sign-cool var(--sign-life) linear forwards' \
  "sign: and its dispatcher's tint cools out of it"
grep_ok "$PAGE_SRC" "--sign-static', age < signSeconds" \
  "sign: reduced motion still expires attribution on the server's lifetime"
grep_ok "$PAGE_SRC" 'signSeconds' "sign: on the server's clock, not the page's"
SIGN_CSS="$(sed -n 's/^ *--sign-life: \([0-9]*\)s;.*/\1/p' "$SRC/wall/wall.css" | head -1)"
check "sign: the page and the server agree on how long a tint lasts" \
  "$SIGN_CSS" "$(printf '%s' "$API" | jq -r '.signSeconds')"
grep_ok "$CSS_SRC" '.life[data-mall="1"] .life__mall' \
  "life: the mall block is a milestone, on top of a street already living"
grep_ok "$CSS_SRC" '.life[data-tram="1"] .life__tram' "life: so is the tram line"
# The ghost is one flat layer. Nothing that says what shipped last week — no
# window grid, no sign, no repo type — may be attached to it.
GHOST_CSS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.ghost/, /^}/')"
for banned in windows sign data-kind data-form; do
  grep_not "$GHOST_CSS" "$banned" "ghost: no [$banned] on last week's silhouette"
done

# --- building typologies ----------------------------------------------------------
# The district used to be one slab per ship, taller or shorter. Every block now
# also draws a typology, which is what stops a week of similar diffs reading as a
# picket fence. Same rules as everything else on this layer: the run id is the
# only input, the vocabulary is closed, and the server has never heard of it.
echo "== wall: the district's building typologies =="
grep_ok "$PAGE_SRC" "seedOf(id + '·form')" \
  "form: a typology is its own draw, not a re-slice of the shop's or the plot's"
grep_ok "$PAGE_SRC" 'B.root.dataset.form = shape.form' \
  "form: and it is written onto the building, once, when it lands"
grep_ok "$PAGE_SRC" "B.root.style.setProperty('--grade', String(shape.grade))" \
  "form: with a footprint grade beside it, so one type is not one shape"
for form in shophouse warehouse tank slab setback mast; do
  # Read the declaration the same way the landmark height check below reads it, so
  # a form that stops declaring its own ceiling fails here rather than there.
  if [ -n "$(sed -n "s/^\.block\[data-form=\"$form\"\] *{.*--form-tall: \([0-9.]*\);.*/\1/p" \
       "$SRC/wall/wall.css")" ]; then
    ok "form: [$form] declares its own proportions"
  else
    bad "form: [$form] declares its own proportions"
  fi
done
# `slab` is the district's existing look on purpose: it is the one type that keeps
# the repo family's roofline and roof furniture, so it must NOT redeclare them.
for form in shophouse warehouse tank setback mast; do
  grep_ok "$CSS_SRC" ".block[data-form=\"$form\"] .block__mass {" \
    "form: [$form] cuts its own roofline"
  grep_ok "$CSS_SRC" ".block[data-form=\"$form\"] .block__crown::before {" \
    "form: and stands its own roof furniture on it"
done
grep_not "$CSS_SRC" '.block[data-form="slab"] .block__mass {' \
  "form: slab keeps the repo family's roofline, which is the whole point of it"
# Everything a building already carried has to survive every one of them: the
# typology reshapes the box, it does not replace what hangs on the box.
grep_ok "$CSS_SRC" 'top: var(--eaves);' \
  "form: the dispatcher's tube hangs off the form's own roofline, not a fixed inset"
grep_ok "$CSS_SRC" 'min-height: calc(var(--form-floor) * var(--deep));' \
  "form: and a form declares a floor, so a two-line diff is still a building"
grep_ok "$CSS_SRC" 'var(--wide) * var(--form-wide)' \
  "form: the footprint is the family's times the type's, not one instead of the other"
FORM_JITTER_CSS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.block\[data-form\] \{/, /^}/')"
grep_ok "$FORM_JITTER_CSS" '--jitter: calc(1 + (var(--grade)' \
  "form: footprint grades only reshape shipped blocks"
BLOCK_DEFAULTS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.block \{/, /^}/')"
grep_ok "$BLOCK_DEFAULTS" '--jitter: 1;' \
  "landmark: blocks without a typology keep their established footprint"
# The server payload is frozen: a typology is presentation derived from the id
# the payload already carries, exactly like the shop under the building.
SERVER_SRC="$(cat "$SRC/wall/server.js")"
for banned in data-form form-tall shophouse warehouse setback; do
  grep_not "$SERVER_SRC" "$banned" "form: the server carries no [$banned]"
done

# --- the landmark ---------------------------------------------------------------
# One building in the district is a fixture rather than a ship: the dedication to
# the person whose subscription every run here is spent from. It is the page's
# alone — the server has never heard of it — it stands on an empty ledger, and it
# reads as a landmark rather than as another mid-rise.
echo "== wall: the district's landmark =="
grep_ok "$PAGE_SRC" 'if (!landmark) { landmark = makeLandmark(); district.append(landmark); }' \
  "landmark: the page stands it up itself, once, before the week's first building"
grep_ok "$PAGE_SRC" '冉 — For Ran, who keeps the lights on' \
  "landmark: hovering it says who the district is for"
grep_ok "$PAGE_SRC" "root.title = RAN.dedication" \
  "landmark: and that dedication is carried as a title the browser will show"
grep_ok "$CSS_SRC" '.block--landmark {' "landmark: it is a block, not a second kind of building"
LANDMARK_CSS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.block--landmark \{/, /^\}/')"
grep_ok "$LANDMARK_CSS" 'pointer-events: auto;' \
  "landmark: the inert district makes one exception so the tooltip is reachable"
grep_ok "$LANDMARK_CSS" 'animation: none;' \
  "landmark: it was standing before the week, so it does not settle into it"
# Reaching a tooltip behind the skyline means the skyline stops eating pointers.
# The towers have their own hover — a shaft carries its run id in a title — so
# the exemption has to hand back the air between towers and nothing else.
CITY_CSS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.city \{/, /^\}/')"
grep_ok "$CITY_CSS" 'pointer-events: none;' \
  "landmark: the skyline hands back the empty air it was covering the district with"
TOWER_CSS="$(printf '%s\n' "$CSS_SRC" | awk '/^\.tower \{/, /^\}/')"
grep_ok "$TOWER_CSS" 'pointer-events: auto;' \
  "landmark: and a tower keeps the hover its shafts' titles depend on"
SERVER_SRC="$(cat "$SRC/wall/server.js")"
for banned in 冉 landmark; do
  grep_not "$SERVER_SRC" "$banned" "landmark: the server carries no [$banned]"
done

# A landmark that does not read as one is a mid-rise. Compute the heights the
# page will actually produce, out of the page's own numbers rather than restating
# them here: taller than anything the week can ship into its own depth band, and
# still under the shortest tower the skyline stands in front of it.
lm_var() { sed -n "/^\.block--landmark {/,/^}/s/^ *--$1: \([0-9.]*\);.*/\1/p" "$SRC/wall/wall.css"; }
BLOCK_H="$(sed -n 's/^ *height: calc((\([0-9.]*\)vh + var(--storeys) \* \([0-9.]*\)vh).*/\1 \2/p' \
  "$SRC/wall/wall.css" | head -1)"
BASE_VH="${BLOCK_H% *}"; PITCH_VH="${BLOCK_H#* }"
DEEP_BACK="$(sed -n 's/^\.block\[data-depth="0"\] { --deep: \([0-9.]*\);.*/\1/p' "$SRC/wall/wall.css")"
TALL_MAX="$(sed -n 's/^\.block\[data-kind="[a-z]*"\] *{.*--tall: \([0-9.]*\);.*/\1/p' \
  "$SRC/wall/wall.css" | sort -n | tail -1)"
STOREYS_MAX="$(sed -n 's/^const STOREYS_MAX = \([0-9]*\);.*/\1/p' "$SRC/wall/server.js")"
CITY_VH="$(sed -n '/^\.city {/,/^}/s/^ *height: \([0-9.]*\)vh;.*/\1/p' "$SRC/wall/wall.css")"
# The building typologies multiply into the same height, so the ceiling this
# comparison is about is theirs too. Read the tallest of them the same way, and
# the tallest floor a form can declare — a `min-height` no formula above knows
# about would otherwise raise a shed over the dedication without failing here.
FORM_TALL_MAX="$(sed -n 's/^\.block\[data-form="[a-z]*"\] *{.*--form-tall: \([0-9.]*\);.*/\1/p' \
  "$SRC/wall/wall.css" | sort -n | tail -1)"
FORM_FLOOR_MAX="$(sed -n 's/^\.block\[data-form="[a-z]*"\] *{.*--form-floor: \([0-9.]*\)vh;.*/\1/p' \
  "$SRC/wall/wall.css" | sort -n | tail -1)"
DEEP_NEAR="$(sed -n 's/^\.block\[data-depth="2"\] { --deep: \([0-9.]*\);.*/\1/p' "$SRC/wall/wall.css")"
# And the jitter inside a form has to be a shortening, never a lengthening, or
# the ceiling above is not a ceiling. Read as the formula, not as a number.
grep_ok "$FORM_JITTER_CSS" '--jitter-tall: calc(1 - var(--grade)' \
  "district: the footprint jitter inside a form only ever shortens a building"
# The shortest tower the skyline can stand: the floor of the page's own height
# ramp, plus the one run it takes to put a tower on the wall at all.
TOWER_RAMP="$(sed -n 's/.*Math.min(94, \([0-9]*\) + n \* \([0-9]*\)).*/\1 \2/p' \
  "$SRC/wall/wall.js" | head -1)"
# Every one of those numbers has to have actually been found: a formula fed an
# empty field computes zero, and a zero-height landmark would sail through the
# comparison below rather than failing it.
GEOM="$BASE_VH|$PITCH_VH|$(lm_var storeys)|$(lm_var tall)|$DEEP_BACK|$TALL_MAX|$STOREYS_MAX|$CITY_VH|$TOWER_RAMP|$FORM_TALL_MAX|$FORM_FLOOR_MAX|$DEEP_NEAR"
if printf '%s' "$GEOM" | grep -qE '\|\||^\||\|$'; then
  bad "landmark: the height check reads every number out of the page itself [$GEOM]"
else
  ok "landmark: the height check reads every number out of the page itself"
fi
HEIGHTS="$(awk -v base="$BASE_VH" -v pitch="$PITCH_VH" \
  -v ls="$(lm_var storeys)" -v lt="$(lm_var tall)" -v deep="$DEEP_BACK" \
  -v ms="$STOREYS_MAX" -v mt="$TALL_MAX" -v city="$CITY_VH" \
  -v ft="$FORM_TALL_MAX" -v ff="$FORM_FLOOR_MAX" -v near="$DEEP_NEAR" \
  -v floor="${TOWER_RAMP% *}" -v step="${TOWER_RAMP#* }" 'BEGIN {
    lm = (base + ls * pitch) * deep * lt;
    neighbour = (base + ms * pitch) * deep * mt * ft;
    tower = city * (floor + step) / 100;
    printf "%d %d %d", (lm > neighbour * 1.15), (lm < tower), (ff * near < lm);
  }')"
check "landmark: it stands well clear of anything its own band can ship" \
  "$(printf '%s' "$HEIGHTS" | cut -d' ' -f1)" "1"
check "landmark: and still under the shortest tower on the skyline" \
  "$(printf '%s' "$HEIGHTS" | cut -d' ' -f2)" "1"
check "landmark: no typology's own floor reaches it either" \
  "$(printf '%s' "$HEIGHTS" | cut -d' ' -f3)" "1"

# --- the street's lettering -------------------------------------------------------
# Five glyphs, and no sixth: the four shops and the dedication. Everything else on
# this wall is the terminal face it has always been.
echo "== wall: the signs say something =="
grep_ok "$PAGE_SRC" "const SHOP_GLYPH = { noodle: '麵', diner: '食', arcade: '樂', repair: '修' };" \
  "signage: one character per shop, and the vocabulary is closed"
grep_ok "$PAGE_SRC" "seedOf(id + '·signage')" \
  "signage: how a sign hangs is its own draw, not a re-slice of the shop's"
grep_ok "$CSS_SRC" '.block[data-shop] .block__glyph' \
  "signage: every shop displays its matching glyph"
grep_not "$CSS_SRC" '.block[data-neon="1"] .block__glyph' \
  "signage: glyph visibility is not limited to the one-in-three neon tube"
grep_ok "$CSS_SRC" 'font-family: var(--cjk);' \
  "signage: the signs declare a CJK stack the page's monospace does not carry"
CJK_USERS="$(printf '%s\n' "$CSS_SRC" | grep -c 'font-family: var(--cjk);')"
check "signage: and only the signs do" "$CJK_USERS" "2"
# Sized off the frontage rather than in rem, both of them: the same lesson the
# shopfront row already learned, so a sign under a narrow spire is a narrow sign.
for sign in .block__glyph .landmark__sign; do
  SIGN_CSS="$(printf '%s\n' "$CSS_SRC" | awk -v k="$sign {" 'index($0, k) == 1, /^\}/')"
  grep_ok "$SIGN_CSS" 'var(--facade)' "signage: $sign is sized off the facade it hangs on"
done
# No sixth glyph anywhere in the page — comments included. Done in node rather
# than with grep -P, which BSD grep does not have and would silently pass.
STRAY_GLYPHS="$(node -e '
  const fs = require("fs");
  const curated = new Set([..."冉麵食樂修"]);
  const text = process.argv.slice(1).map((f) => fs.readFileSync(f, "utf8")).join("");
  const stray = [...new Set([...text])].filter((c) => /[一-鿿]/.test(c) && !curated.has(c));
  process.stdout.write(stray.join(""));
' "$SRC/wall/index.html" "$SRC/wall/wall.css" "$SRC/wall/wall.js")"
if [ -z "$STRAY_GLYPHS" ]; then
  ok "signage: no lettering beyond the five curated glyphs"
else
  bad "signage: no lettering beyond the five curated glyphs (found [$STRAY_GLYPHS])"
fi

# --- the city lives at night ------------------------------------------------------
# The desk's verdict on the accreting district was that it read as a mausoleum
# after hours. The fix is that ambient life is no longer milestone-gated: one
# building standing lights the ground floor, and the week only sets the tempo.
echo "== wall: the ground floor is lit from the first ship =="
grep_not "$PAGE_SRC" 'data-shops' \
  "life: the tenth-ship gate on the shop windows is gone, not left shadowing it"
grep_ok "$PAGE_SRC" 'const plan = nightlifeOf(week.ships)' \
  "life: density is page-owned and reads the established ship count"
grep_ok "$PAGE_SRC" 'life.hidden = blocks.length === 0' \
  "life: one building standing is the whole condition for a living street"
grep_ok "$CSS_SRC" '.block__shop {' "life: every building carries a lit shopfront row"
grep_ok "$CSS_SRC" '.block[data-neon="1"] .block__neon' \
  "life: and some of them the neon that says which shop it is"
grep_ok "$CSS_SRC" '.block__occupancy i {' \
  "life: a few windows per facade keep their own hours"
grep_ok "$PAGE_SRC" 'life__vent' "life: steam comes off the street vents"
grep_ok "$PAGE_SRC" 'life__walker' "life: somebody is out walking"
grep_ok "$PAGE_SRC" 'life__car'    "life: and a car goes past now and then"
grep_ok "$CSS_SRC" 'animation: prowl var(--vehicle-cycle) linear infinite' \
  "life: the gap between passes is the week's, not a constant"
grep_ok "$CSS_SRC" 'body[data-quiet="0"] .life' \
  "life: and all of it steps back the moment something is climbing"
grep_ok "$CSS_SRC" '.life__vent, .life__car { display: none; }' \
  "motion: reduced motion drops the two things that are only motion"
grep_not "$PAGE_SRC" 'life__mover' \
  "life: the milestone-gated movers are gone, replaced rather than layered"

# Every animation this pass adds, held to the same rule as the rest of the wall:
# transform and opacity, nothing that costs the browser a layout on a screen
# that has to hold 60fps for a month.
for beat in occupancy neon-hum steam prowl trundle; do
  BEAT_CSS="$(printf '%s\n' "$CSS_SRC" | awk -v k="@keyframes $beat" 'index($0, k) == 1, /^}/')"
  if [ -z "$BEAT_CSS" ]; then
    bad "motion: @keyframes $beat exists"
    continue
  fi
  STRAY="$(printf '%s\n' "$BEAT_CSS" | grep -oE '[a-z-]+:' | grep -vE '^(transform|opacity):' \
    | sort -u | tr '\n' ' ')"
  check "motion: @keyframes $beat animates transform and opacity only" "$STRAY" ""
done

# The page owns and bounds the population plan. This is presentation derived
# from the established ship count, not a reason to change the server payload.
grep_ok "$PAGE_SRC" 'Math.min(MAX_WALKERS' "life: the page caps the crowd it plans"
grep_ok "$PAGE_SRC" 'Math.min(MAX_VEHICLES' "life: and the traffic"
grep_ok "$PAGE_SRC" 'plan.gap * plan.vehicles' \
  "life: multiple cars preserve the planned gap instead of dividing it"

# Storefronts are planned the way plots are: a pure function of the run id. The
# noodle bar is on the same corner after a reload, on the second TV, and on a
# colleague's laptop — and a whole ticket range does not end up as one long row
# of arcades.
NIGHT_SRC="$(awk '/^  \/\/ --- nightlife/,/^  \/\/ --- the street/' "$SRC/wall/wall.js")"
grep_not "$(printf '%s\n' "$NIGHT_SRC" | grep -v '^ *//')" 'Math.random' \
  "life: no unseeded randomness anywhere in the plan"
NIGHT_PROBE="$ROOT/nightlife-probe.js"
{
  grep -E '^  const (MAX_WALKERS|MAX_VEHICLES|PER_WALKER|PER_VEHICLE|GAP_QUIET|GAP_BUSY|BUSY_AT|MALL_AT|TRAM_AT|OCCUPIED) = ' \
    "$SRC/wall/wall.js"
  printf '%s\n' "$NIGHT_SRC"
  cat <<'JS'
  const ids = [];
  for (let i = 0; i < 200; i++) ids.push('OLYX-' + (1500 + i));
  const plans = ids.map(storefrontOf);
  const forms = ids.map(formOf);
  const LOW = ['shophouse', 'warehouse', 'tank'];
  const TALL = ['setback', 'mast'];
  const kinds = {};
  for (const plan of plans) kinds[plan.shop] = (kinds[plan.shop] || 0) + 1;
  const bays = new Set(plans.map((plan) => plan.bay));
  const neon = plans.filter((plan) => plan.neon).length;
  const life = [0, 1, 2, 4, 9, 12, 20, 90].map((n) => {
    const plan = nightlifeOf(n);
    return n + ':' + plan.walkers + 'w' + plan.vehicles + 'v' + plan.gap + 's'
      + (plan.mall ? 'M' : '-') + (plan.tram ? 'T' : '-');
  }).join(' ');
  console.log(JSON.stringify({
    life,
    lifeDead: Object.values(nightlifeOf(0)).filter(Boolean).length,
    lifeBaseline: (() => {
      const plan = nightlifeOf(1);
      return plan.walkers >= 1 && plan.vehicles >= 1 && plan.gap > 0;
    })(),
    lifeScales: (() => {
      let prev = nightlifeOf(1);
      for (let n = 2; n <= 120; n++) {
        const plan = nightlifeOf(n);
        if (plan.walkers < prev.walkers || plan.vehicles < prev.vehicles ||
            plan.gap > prev.gap) return false;
        prev = plan;
      }
      return nightlifeOf(120).walkers > nightlifeOf(1).walkers
        && nightlifeOf(120).gap < nightlifeOf(1).gap;
    })(),
    lifeCapped: (() => {
      const plan = nightlifeOf(5000);
      return plan.walkers === MAX_WALKERS && plan.vehicles === MAX_VEHICLES
        && plan.gap === GAP_BUSY;
    })(),
    mallEdge: !nightlifeOf(MALL_AT - 1).mall && nightlifeOf(MALL_AT).mall,
    tramEdge: !nightlifeOf(TRAM_AT - 1).tram && nightlifeOf(TRAM_AT).tram,
    stable: JSON.stringify(storefrontOf('OLYX-1598')) === JSON.stringify(storefrontOf('OLYX-1598')),
    differs: JSON.stringify(storefrontOf('OLYX-1598')) !== JSON.stringify(storefrontOf('OLYX-1599')),
    everyKind: Object.keys(kinds).sort().join(','),
    spread: Object.values(kinds).every((n) => n > ids.length / 10),
    bays: [...bays].sort((a, b) => a - b).join(','),
    // The brighter neon tube keeps its established one-in-three density even
    // though every shop now carries a small glyph.
    someNeon: neon > ids.length / 6 && neon < ids.length / 2,
    windows: plans.every((plan) => plan.windows.length === OCCUPIED),
    inFrame: plans.every((plan) => plan.windows.every((w) =>
      w.col >= 0 && w.col < 7 && w.row >= 0 && w.row < 5 && w.phase >= 0 && w.phase < 8)),
    // The shop and the hours are separate draws: a facade's windows must not be
    // predictable from what is selling downstairs.
    unlinked: new Set(plans.map((plan) => plan.shop + ':' + plan.windows[0].phase)).size > 8,
    // Every sign says the shop it hangs over, and the vocabulary never grows.
    glyphMatched: plans.every((plan) => plan.glyph === SHOP_GLYPH[plan.shop]),
    glyphVocab: [...new Set(plans.map((plan) => plan.glyph))].sort().join(''),
    // How a sign hangs is a third draw: both sides of a frontage get used, and
    // which one a building gets is not readable off what is selling under it.
    sides: [...new Set(plans.map((plan) => plan.side))].sort().join(','),
    hangUnlinked: new Set(plans.map((plan) =>
      plan.shop + ':' + plan.side + ':' + plan.hang)).size > 40,
    // And the typology, planned the same way and held to the same rules.
    formStable: JSON.stringify(formOf('OLYX-1598')) === JSON.stringify(formOf('OLYX-1598')),
    formDiffers: JSON.stringify(formOf('OLYX-1598')) !== JSON.stringify(formOf('OLYX-1599')),
    formVocab: [...new Set(FORM_SHARES)].sort().join(','),
    formDrawn: [...new Set(forms.map((f) => f.form))].sort().join(','),
    // The shares ARE the skyline: mostly low and wide, a couple of towers in it.
    formLow: forms.filter((f) => LOW.includes(f.form)).length > ids.length * 0.55,
    formTowers: (() => {
      const tall = forms.filter((f) => TALL.includes(f.form)).length;
      return tall > 0 && tall < ids.length * 0.25;
    })(),
    // What kind of building it is has nothing to do with what is selling under it.
    formUnlinked: new Set(plans.map((plan, i) => plan.shop + ':' + forms[i].form)).size > 16,
    formGrades: [...new Set(forms.map((f) => f.grade))].sort((a, b) => a - b).join(','),
  }));
JS
} > "$NIGHT_PROBE"
NIGHT="$(node "$NIGHT_PROBE" 2>&1)"
night_of() { printf '%s' "$NIGHT" | jq -r ".$1" 2>/dev/null; }
check "life: the week's tempo starts with its first ship" \
  "$(night_of life)" \
  "0:0w0v0s-- 1:1w1v48s-- 2:1w1v46s-- 4:2w1v43s-- 9:3w2v36s-- 12:4w2v31sM- 20:6w3v19sMT 90:6w3v11sMT"
check "life: an empty plain is the only plan with no nightlife" "$(night_of lifeDead)" "0"
check "life: one building standing is enough for a living street" \
  "$(night_of lifeBaseline)" "true"
check "life: more ships is a livelier night, never a quieter one" \
  "$(night_of lifeScales)" "true"
check "life: and a monstrous week is still a street, not a parade" \
  "$(night_of lifeCapped)" "true"
check "life: the mall unlocks on its own ship, as a bonus" "$(night_of mallEdge)" "true"
check "life: the tram unlocks on its own ship, as a bonus" "$(night_of tramEdge)" "true"
check "life: the same building keeps the same shop, always" "$(night_of stable)" "true"
check "life: two buildings do not get the same street twice" "$(night_of differs)" "true"
check "life: the whole vocabulary of the street gets used" \
  "$(night_of everyKind)" "arcade,diner,noodle,repair"
check "life: and a ticket range is not one long row of arcades" "$(night_of spread)" "true"
check "life: shopfronts spread across every bay of a base" "$(night_of bays)" "0,1,2,3,4"
check "life: about a third of the buildings carry a neon tube" "$(night_of someNeon)" "true"
check "life: every facade gets its fixed handful of lit windows" "$(night_of windows)" "true"
check "life: and every one of them lands on the building" "$(night_of inFrame)" "true"
check "life: a facade's hours are not readable off its shop" "$(night_of unlinked)" "true"
check "signage: every sign says the shop it hangs over" "$(night_of glyphMatched)" "true"
check "signage: and the lettering is the four curated glyphs, no more" \
  "$(night_of glyphVocab)" "修樂食麵"
check "signage: signs hang off both sides of a frontage" "$(night_of sides)" "0,1"
check "signage: and how one hangs is not readable off its shop" \
  "$(night_of hangUnlinked)" "true"
check "form: the same building is the same type, always" "$(night_of formStable)" "true"
check "form: two buildings do not get the same type twice" "$(night_of formDiffers)" "true"
check "form: the vocabulary is six types and closed" \
  "$(night_of formVocab)" "mast,setback,shophouse,slab,tank,warehouse"
check "form: and a ticket range uses all six" \
  "$(night_of formDrawn)" "$(night_of formVocab)"
check "form: the district is mostly low and wide" "$(night_of formLow)" "true"
check "form: with a couple of towers in it, not a row of them" \
  "$(night_of formTowers)" "true"
check "form: what kind of building it is is not readable off its shop" \
  "$(night_of formUnlinked)" "true"
check "form: every footprint grade inside a type gets used" \
  "$(night_of formGrades)" "0,1,2,3"

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
  # The ledger is the one thing on this wall that writes. Serving the committed
  # fixtures must still leave the repo exactly as it found it — hence --city, and
  # hence this.
  if [ -e "$SRC/wall/fixtures/wall-city.jsonl" ] || [ -e "$SRC/wall/wall-city.jsonl" ]; then
    bad "fixtures: serving the repo's fixtures wrote a ledger into the repo"
  else
    ok "fixtures: serving the repo's fixtures writes nothing into the repo"
  fi
else
  bad "fixtures: server starts against wall/fixtures/runs"
fi

# --- flags --------------------------------------------------------------------
echo "== wall.sh: flags =="
HELP="$(bash "$WALL" --help 2>&1)"
check   "flags: --help exits 0" "$?" "0"
grep_ok "$HELP" "--runs" "flags: --help documents --runs"
grep_ok "$HELP" "--city" "flags: --help documents --city"
grep_ok "$HELP" "WALL_POLL_MS" "flags: --help reaches the end of the header"
# The header is printed by line range, so growing it and forgetting the range
# either truncates the help or spills the script into it.
grep_not "$HELP" "set -u" "flags: --help stops before the code"
# Losing the city's memory to a shifted argument is exactly the accident worth
# catching, so an empty --city is a typo rather than "put it back on default".
if bash "$WALL" --city '' >/dev/null 2>&1; then
  bad "flags: an empty --city exits non-zero"
else
  ok "flags: an empty --city exits non-zero"
fi
# A flag with no value at all used to spin the argument loop forever, because
# `shift 2` on a one-element list shifts nothing. Every flag takes a value, so
# every flag is checked — with a timeout, since the failure mode is a hang and a
# hung suite tells you nothing about which flag did it.
for flag in --port --host --runs --city --crew; do
  if perl -e 'alarm 5; exec @ARGV' bash "$WALL" "$flag" >/dev/null 2>&1; then
    bad "flags: a value-less $flag exits instead of looping"
  else
    ok "flags: a value-less $flag exits instead of looping"
  fi
done
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
