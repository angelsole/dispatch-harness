#!/usr/bin/env bash
# The visual gate — the stage that looks at the render.
#
# The code harness gates on correctness: tests, lint, a diff review. Visual work
# is not judged that way, and a whole day of it went green through that gate and
# was rejected by eye every round, because nothing in the loop ever LOOKED at
# the picture. This is the missing check, and it runs like the test gate does:
# render fixed shots, measure what can be measured for free, ask one fresh critic
# what cannot, and fail the round into a fix.
#
# Two tiers, in this order and for this reason:
#   1. Deterministic checks (vcheck.py) — free, ~1 s, and calibrated by
#      per-repo thresholds rather than by taste. A render that fails these is
#      broken in a way no critic needs to be paid to notice.
#   2. One VLM critic (critic.sh) — fresh context, no shell, strict
#      JSON, and judged PAIRWISE against the reigning champion. A challenger the
#      critic calls `worse` fails the gate however high its absolute scores are.
#      That verdict is the one this whole stage exists to obtain — which is why
#      the critic is blind to which sheet reigns and is asked in both
#      presentation orders, and why a verdict it will not repeat is a `tie`.
#      Its per-axis scores and its absolute pass/fail decide nothing: they are
#      recorded in the score's `advisory` list for the fix round and the human
#      to read, and the round is decided by pairwise when there is a champion
#      and by the checks when there is not.
#
# Run by run-task.sh as VISUAL_GATE_CMD, inside the worktree; also runnable by
# hand from a worktree (see the live-demo recipe in this directory's README.md).
#
# Usage:  visual-gate.sh            (cwd = the repo/worktree being judged)
# Config: .creative/visual.conf.sh in that repo — see repos.local.sh.example
#         and profiles/visual/creative/README.md.
# Env:    VISUAL_CONF   config path        (default .creative/visual.conf.sh)
#         VISUAL_OUT    artefact dir       (default .harness)
#         VISUAL_REPO   champion key       (default the main checkout's name)
#         VISUAL_ROUND  round number       (default 1)
#         VISUAL_LIVE=1 force the real critic on
#         VISUAL_PY     python with Playwright
#                       (default ~/.local/share/uv/tools/shot-scraper/bin/python)
#
# Exit 0 = pass, 1 = the render failed the gate, 2 = the gate could not run at
# all because this repo's contract is broken, 3 = the MACHINE could not render
# (no browser, no server). 1 and 2 are a failed round to the harness; 3 is
# `not_run` — no fix round, no outcome, because no model can install Chromium.
set -u -o pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# The shared helpers, read from beside this script the way every other harness
# script reads them: profiles/<name>/creative/ is three levels under the root,
# in the checkout and in HARNESS_DIR alike.
# shellcheck source=../../../lib/common.sh
. "$SELF_DIR/../../../lib/common.sh"
VISUAL_CONF="${VISUAL_CONF:-.creative/visual.conf.sh}"
VISUAL_OUT="${VISUAL_OUT:-.harness}"
VISUAL_ROUND="${VISUAL_ROUND:-1}"
VISUAL_PY="${VISUAL_PY:-$HOME/.local/share/uv/tools/shot-scraper/bin/python}"
VCHECK_PY="${VCHECK_PY:-python3}"

FRAMES_DIR="$VISUAL_OUT/frames"
SHEET="$VISUAL_OUT/contact-sheet.png"
SCORE="$VISUAL_OUT/visual-score.json"
CHECKS="$VISUAL_OUT/visual-checks.json"
CRITIC_OUT="$VISUAL_OUT/visual-critic.json"

# The step the harness names in the log header and in the fix prompt.
# run_visual_gate hands us the file; a bare run just skips it.
step() {
  [ -n "${HARNESS_GATE_STEP:-}" ] || return 0
  printf '%s\n' "$1" > "$HARNESS_GATE_STEP" 2>/dev/null || true
}

# Every exit that is not a pass leaves the same artefact behind: a score file
# whose `failures` list says, in one human sentence, what went wrong. The fix
# round reads that list and nothing else, so an early death must not hand it an
# empty file — or, worse, the previous round's.
die() {  # $1 = exit code, $2 = the one-line reason
  step "$2"
  echo "visual gate: $2" >&2
  if [ -d "$VISUAL_OUT" ]; then
    jq -n --arg r "$2" --argjson round "${VISUAL_ROUND:-1}" \
      '{status:"fail", round:$round, failures:[$r], advisory:[], pairwise:"none",
        worst_axis:"", one_fix:"", critic:null, critic_ran:false}' \
      > "$SCORE" 2>/dev/null || true
  fi
  echo "=== visual gate (round $VISUAL_ROUND): FAIL ==="
  exit "$1"
}

# The gate could not run and the render is not why. A machine with no browser
# scored `fail` once and cost a fix round aimed at an environment no model can
# reach; the score file says `not_run` instead, and carries the one command a
# human runs to make the stage possible. Never reachable once frames exist:
# anything measured is a verdict, and a verdict is die()'s.
not_run_die() {  # $1 = the one-line reason, $2 = the remedy command
  step "$1"
  echo "visual gate: $1" >&2
  echo "visual gate: remedy: $2" >&2
  if [ -d "$VISUAL_OUT" ]; then
    jq -n --arg r "$1" --arg m "$2" --argjson round "${VISUAL_ROUND:-1}" \
      '{status:"not_run", round:$round, reason:$r, remedy:$m, failures:[],
        advisory:[], pairwise:"none", worst_axis:"", one_fix:"", critic:null,
        critic_ran:false}' > "$SCORE" 2>/dev/null || true
  fi
  echo "=== visual gate (round $VISUAL_ROUND): NOT RUN — $1 ==="
  echo "=== remedy: $2 ==="
  exit 3
}

# --- config ------------------------------------------------------------------
# Defaults first, so a repo's file only states what it means to change and an
# unset threshold is "measure it, do not enforce it" — the honest default, since
# the same number means opposite things for pixel art and for a live dashboard.
#
# Every one reads the environment first, so an operator iterating by hand can
# override a single knob without editing the repo's contract (VISUAL_CRITIC=0 to
# re-render for free is the one that gets used). A conf that assigns plainly
# wins over the environment; a conf that wants the other precedence writes
# ${VAR:-…} itself, as this repo's does for VISUAL_CRITIC.
VISUAL_URL="${VISUAL_URL:-}"
VISUAL_SERVER_CMD="${VISUAL_SERVER_CMD:-}"
VISUAL_SERVER_PORT_RE="${VISUAL_SERVER_PORT_RE:-http://[^:]*:([0-9]+)}"
VISUAL_SERVER_TIMEOUT="${VISUAL_SERVER_TIMEOUT:-30}"
VISUAL_SHOTS=()
VISUAL_FRAMES="${VISUAL_FRAMES:-6}"
VISUAL_WAIT_MS="${VISUAL_WAIT_MS:-750}"
VISUAL_SETTLE_MS="${VISUAL_SETTLE_MS:-3000}"
VISUAL_WIDTH="${VISUAL_WIDTH:-1280}"
VISUAL_HEIGHT="${VISUAL_HEIGHT:-720}"
VISUAL_DPR="${VISUAL_DPR:-1}"
VISUAL_READY_JS="${VISUAL_READY_JS:-}"
VISUAL_REDUCED_MOTION="${VISUAL_REDUCED_MOTION:-reduce}"
VISUAL_COLOR_SCHEME="${VISUAL_COLOR_SCHEME:-dark}"
VISUAL_ANIMATIONS="${VISUAL_ANIMATIONS:-disabled}"
VISUAL_REAL_WAIT_MS="${VISUAL_REAL_WAIT_MS:-0}"
VISUAL_PALETTE="${VISUAL_PALETTE:-}"
VISUAL_REFS="${VISUAL_REFS:-}"
VISUAL_RUBRIC="${VISUAL_RUBRIC:-.creative/rubric.md}"
VISUAL_CRITIC="${VISUAL_CRITIC:-1}"
VISUAL_MAX_OFFPALETTE_PCT="${VISUAL_MAX_OFFPALETTE_PCT:-}"
VISUAL_MAX_OFFGRID_PCT="${VISUAL_MAX_OFFGRID_PCT:-}"
VISUAL_MAX_PURE_BLACK_PCT="${VISUAL_MAX_PURE_BLACK_PCT:-}"
VISUAL_MIN_LUMA="${VISUAL_MIN_LUMA:-}"
VISUAL_MIN_LEGIBILITY="${VISUAL_MIN_LEGIBILITY:-}"
VISUAL_MAX_FRAME_RMSE="${VISUAL_MAX_FRAME_RMSE:-}"
VISUAL_MIN_SSIM="${VISUAL_MIN_SSIM:-}"

mkdir -p "$VISUAL_OUT" 2>/dev/null || true
# Stale artefacts are worse than missing ones: run_visual_gate reads the score
# file after every round, and last round's verdict left in place would be read
# as this one's.
rm -f "$SCORE" "$CHECKS" "$CRITIC_OUT" "$SHEET"

[ -f "$VISUAL_CONF" ] || die 2 "no visual contract at $VISUAL_CONF — a repo opts into the visual gate by writing one (see profiles/visual/creative/README.md)"

# The scratch dir exists before the config is read: a server command needs
# somewhere to put its own state, and $VISUAL_TMP is where.
VISUAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/visual-gate.XXXXXX")" || die 2 "could not make a scratch dir"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    pkill -P "$SERVER_PID" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$VISUAL_TMP"
}
trap cleanup EXIT
export VISUAL_TMP
# shellcheck source=/dev/null
. "$VISUAL_CONF" || die 2 "$VISUAL_CONF could not be sourced"

[ "${VISUAL_LIVE:-0}" != 1 ] || VISUAL_CRITIC=1
case "$VISUAL_CRITIC" in
  0|1) ;;
  *) die 2 "$VISUAL_CONF sets VISUAL_CRITIC='$VISUAL_CRITIC' — expected 0 or 1" ;;
esac
case "$VISUAL_FRAMES" in
  ''|*[!0-9]*|0) die 2 "$VISUAL_CONF sets VISUAL_FRAMES='$VISUAL_FRAMES' — expected a positive integer" ;;
esac
[ "${#VISUAL_SHOTS[@]}" -gt 0 ] \
  || die 2 "$VISUAL_CONF declares no VISUAL_SHOTS — there is nothing to render"

# Which project's champion this render is challenging. The worktree is
# <repo>-<ticket>, so its own basename is the wrong key; the main checkout's is
# the right one, and git knows it.
if [ -z "${VISUAL_REPO:-}" ]; then
  GIT_COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
  if [ -n "$GIT_COMMON" ]; then VISUAL_REPO=$(basename "$(dirname "$GIT_COMMON")")
  else VISUAL_REPO=$(basename "$PWD"); fi
fi
CHAMPION_DIR="${VISUAL_CHAMPION_DIR:-$HARNESS_DIR/champion/$VISUAL_REPO}"

rm -rf "$FRAMES_DIR" "$VISUAL_OUT/champion"
mkdir -p "$FRAMES_DIR" || die 2 "cannot write frames into $FRAMES_DIR"

echo "=== visual gate (round $VISUAL_ROUND) ==="
echo "repo: $VISUAL_REPO   config: $VISUAL_CONF"

# --- the champion, copied in so the critic can Read it ------------------------
# Before the machine is asked for anything: this is the repo's own state, so a
# broken champion has to fail closed whether or not a browser exists here.
CHAMPION_SHEET=""
CHAMPION_COUNT=0
if [ -d "$CHAMPION_DIR" ]; then
  mkdir -p "$VISUAL_OUT/champion"
  for f in "$CHAMPION_DIR"/champion-*.png "$CHAMPION_DIR/champion.json"; do
    [ -e "$f" ] || continue
    cp "$f" "$VISUAL_OUT/champion/" 2>/dev/null \
      || die 2 "champion: could not copy $f into $VISUAL_OUT/champion"
  done
  [ -f "$VISUAL_OUT/champion/champion-sheet.png" ] \
    && CHAMPION_SHEET="$VISUAL_OUT/champion/champion-sheet.png"
  CHAMPION_COUNT=$(find "$VISUAL_OUT/champion" -maxdepth 1 -name 'champion-*.png' \
    ! -name 'champion-sheet.png' 2>/dev/null | grep -c '' | tr -d ' ')
fi
if [ "$CHAMPION_COUNT" -gt 0 ] && [ -z "$CHAMPION_SHEET" ]; then
  die 2 "champion: $CHAMPION_DIR has frame(s) but no champion-sheet.png — promote it again before comparing"
fi
if [ "$CHAMPION_COUNT" -eq 0 ] && [ -f "$VISUAL_OUT/champion/champion.json" ]; then
  die 2 "champion: $CHAMPION_DIR has metadata but no champion shot frames — promote it again before comparing"
fi
if [ "$CHAMPION_COUNT" -gt 0 ]; then
  echo "champion: $CHAMPION_COUNT shot(s) from $CHAMPION_DIR"
else
  echo "champion: none for $VISUAL_REPO — pairwise is 'none' this round, and the gate decides on the deterministic checks alone (the critic still grades, advisory)"
fi

# --- the renderer, and the one dependency it needs ---------------------------
# Playwright comes from the venv shot-scraper already installed. Assert it here
# rather than discovering it three steps later: a gate that cannot render must
# say so in one line, and must never pass by default.
"$VISUAL_PY" -c 'import playwright' >/dev/null 2>&1 \
  || not_run_die "no Playwright at $VISUAL_PY — this machine cannot render" \
       "uv tool install shot-scraper && npx playwright install chromium"
"$VCHECK_PY" -c 'import numpy, PIL' >/dev/null 2>&1 \
  || not_run_die "$VCHECK_PY has no numpy/Pillow — the deterministic checks cannot run" \
       "$VCHECK_PY -m pip install numpy pillow"

# Importable is not launchable: the browser binaries are a second install step,
# and skipping it renders zero frames with nothing in the log that says why.
# One launch, once, before a server is started or a shot is taken.
step "probe: the headless browser"
if ! "$VISUAL_PY" - > "$VISUAL_TMP/launch-probe.log" 2>&1 <<'PY'
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    p.chromium.launch(headless=True, args=[
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]).close()
PY
then
  tail -5 "$VISUAL_TMP/launch-probe.log" 2>/dev/null | sed 's/^/  probe: /'
  not_run_die "the headless browser at $VISUAL_PY could not be launched" \
    "npx playwright install chromium"
fi

# --- the page under judgement ------------------------------------------------
if [ -n "$VISUAL_SERVER_CMD" ]; then
  SRV_LOG="$VISUAL_TMP/server.log"
  bash -c "$VISUAL_SERVER_CMD" > "$SRV_LOG" 2>&1 &
  SERVER_PID=$!
  # A server on --port 0 tells us its port and nothing else can: wait for the
  # line, never guess, never sleep a fixed amount.
  PORT=""
  i=0
  while [ "$i" -lt $((VISUAL_SERVER_TIMEOUT * 10)) ]; do
    PORT=$(sed -nE "s|.*${VISUAL_SERVER_PORT_RE}.*|\1|p" "$SRV_LOG" 2>/dev/null | head -1)
    [ -n "$PORT" ] && break
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$PORT" ]; then
    tail -20 "$SRV_LOG" 2>/dev/null | sed 's/^/  server: /'
    not_run_die "the server named by VISUAL_SERVER_CMD never printed a port matching $VISUAL_SERVER_PORT_RE — there was no page to judge" \
      "run VISUAL_SERVER_CMD by hand in the worktree and see what it prints"
  fi
  VISUAL_URL="${VISUAL_URL//\{port\}/$PORT}"
  echo "server: pid $SERVER_PID on port $PORT"
fi
[ -n "$VISUAL_URL" ] \
  || die 2 "$VISUAL_CONF sets neither VISUAL_URL nor a VISUAL_SERVER_CMD that yields one"
echo "url: $VISUAL_URL"

# --- render -------------------------------------------------------------------
RENDER_STARTED=$(date +%s)
SHOT_NAMES=""
for entry in "${VISUAL_SHOTS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  suffix="${rest%%|*}"
  waitms="$VISUAL_WAIT_MS"
  case "$rest" in *"|"*) waitms="${rest##*|}" ;; esac
  case "$waitms" in ''|*[!0-9]*) waitms="$VISUAL_WAIT_MS" ;; esac
  [ -n "$name" ] && [ "$name" != "$entry" ] \
    || die 2 "VISUAL_SHOTS entry '$entry' is not name|url-suffix|wait-ms"
  case "$name" in
    *[!A-Za-z0-9._-]*) die 2 "VISUAL_SHOTS name '$name' contains unsafe characters — use letters, digits, dot, underscore or hyphen" ;;
  esac
  step "render: $name"
  if ! "$VISUAL_PY" "$SELF_DIR/frames.py" \
        --url "$VISUAL_URL$suffix" --out "$FRAMES_DIR" --tag "$name" \
        --frames "$VISUAL_FRAMES" --wait-ms "$waitms" --settle-ms "$VISUAL_SETTLE_MS" \
        --width "$VISUAL_WIDTH" --height "$VISUAL_HEIGHT" --dpr "$VISUAL_DPR" \
        --ready-js "$VISUAL_READY_JS" --reduced-motion "$VISUAL_REDUCED_MOTION" \
        --color-scheme "$VISUAL_COLOR_SCHEME" --animations "$VISUAL_ANIMATIONS" \
        --real-wait-ms "$VISUAL_REAL_WAIT_MS" > "$VISUAL_TMP/render-$name.json"; then
    die 1 "render: shot '$name' produced no frames at $VISUAL_URL$suffix — the page did not come up, or the ready predicate never fired"
  fi
  echo "render: $name -> $(jq -r '.frames | length' "$VISUAL_TMP/render-$name.json") frames in $(jq -r .seconds "$VISUAL_TMP/render-$name.json")s"
  jq -r '.page_errors[]? | "  page error: " + .' "$VISUAL_TMP/render-$name.json"
  SHOT_NAMES="$SHOT_NAMES $name"
done
RENDER_SECONDS=$(( $(date +%s) - RENDER_STARTED ))

# --- deterministic checks ------------------------------------------------------
step "checks: vcheck.py"
SPEC="$VISUAL_TMP/spec.json"
{
  printf '{"palette":'
  if [ -n "$VISUAL_PALETTE" ] && [ -f "$VISUAL_PALETTE" ]
    then jq -n --arg p "$VISUAL_PALETTE" '$p'
    else printf 'null'
  fi
  printf ',"thresholds":'
  jq -n --arg op "$VISUAL_MAX_OFFPALETTE_PCT" --arg og "$VISUAL_MAX_OFFGRID_PCT" \
        --arg bl "$VISUAL_MAX_PURE_BLACK_PCT" --arg ml "$VISUAL_MIN_LUMA" \
        --arg lg "$VISUAL_MIN_LEGIBILITY" --arg fr "$VISUAL_MAX_FRAME_RMSE" \
        --arg ss "$VISUAL_MIN_SSIM" \
    '{max_offpalette_pct:$op, max_offgrid_pct:$og, max_pure_black_pct:$bl,
      min_luma:$ml, min_legibility:$lg, max_frame_rmse:$fr, min_ssim:$ss}
     | with_entries(select(.value != ""))'
  printf ',"shots":['
  first=1
  for name in $SHOT_NAMES; do
    [ "$first" = 1 ] || printf ','
    first=0
    champ="$VISUAL_OUT/champion/champion-$name.png"
    [ -f "$champ" ] || champ=""
    find "$FRAMES_DIR" -maxdepth 1 -name "$name-f*.png" | sort \
      | jq -Rn --arg n "$name" --arg c "$champ" \
          '{name:$n, frames:[inputs], champion:(if $c == "" then null else $c end)}'
  done
  printf ']}'
} > "$SPEC"

"$VCHECK_PY" "$SELF_DIR/vcheck.py" --spec "$SPEC" --out "$CHECKS" > /dev/null \
  || die 2 "the deterministic checks could not run over $SPEC"

echo "checks:"
jq -r '
  .shots | to_entries[] | . as $s
  | ($s.value.frames[]
     | "  \(.frame | split("/") | last)  offgrid \(.grid.offgrid_pct)%  black \(.luminance.pure_black_pct)%  legibility \(.readability.edge_energy_retained_480x270)  pitch \(.grid.pitch_px)px"
       + (if .palette then "  offpalette \(.palette.offpalette_pct)%" else "" end)),
    "  \($s.key): continuity max RMSE \($s.value.continuity.max_rmse // "n/a"), SSIM vs champion \($s.value.vs_champion.ssim // "n/a")"
' "$CHECKS"
CHECKS_PASS=$(jq -r '.pass' "$CHECKS")

# --- the contact sheet ---------------------------------------------------------
step "contact sheet"
SHEET_FRAMES=()
while IFS= read -r f; do SHEET_FRAMES+=("$f"); done < <(find "$FRAMES_DIR" -maxdepth 1 -name '*.png' | sort)
if ! bash "$SELF_DIR/contact-sheet.sh" "$SHEET" "${SHEET_FRAMES[@]}"; then
  die 2 "contact sheet: could not build a PNG under the 500 KB critic ceiling"
fi
[ -f "$SHEET" ] || die 2 "contact sheet: the builder returned success without writing $SHEET"

# --- the critic ----------------------------------------------------------------
CRITIC_RAN=0
CRITIC_RC=0
if [ "$VISUAL_CRITIC" != 1 ]; then
  echo "critic: off (VISUAL_CRITIC=0)"
elif [ "$CHECKS_PASS" != "true" ]; then
  echo "critic: not asked — the deterministic checks already failed, and a paid opinion adds nothing to that"
else
  step "critic"
  CRITIC_RAN=1
  RUBRIC_ARG="$SELF_DIR/rubric.md"
  [ -f "$VISUAL_RUBRIC" ] && RUBRIC_ARG="$VISUAL_RUBRIC"
  CRITIC_ARGS=(--challenger "$SHEET" --rubric "$RUBRIC_ARG" --out "$CRITIC_OUT")
  [ -n "$CHAMPION_SHEET" ] && CRITIC_ARGS+=(--champion "$CHAMPION_SHEET")
  [ -n "$VISUAL_REFS" ] && [ -d "$VISUAL_REFS" ] && CRITIC_ARGS+=(--refs "$VISUAL_REFS")
  bash "$SELF_DIR/critic.sh" "${CRITIC_ARGS[@]}" || CRITIC_RC=$?
  if [ -f "$CRITIC_OUT" ]; then
    jq -r '"critic: verdict=\(.verdict) pairwise=\(.pairwise) worst=\(.worst_axis)",
           (if .calibration then
              "  orders:   \(.calibration.rule); axes mean \(.calibration.challenger_axes) vs \(.calibration.champion_axes) (delta \(.calibration.tiebreak.delta))"
            else empty end),
           "  evidence: \(.evidence // "")",
           "  one fix:  \(.one_fix // "")"' "$CRITIC_OUT"
  fi
fi

# --- the verdict ----------------------------------------------------------------
# One JSON with everything downstream reads: the fix round's prompt, the
# reviewer's context, the PR body, and result.json's visual field.
CRITIC_JSON="$VISUAL_TMP/no-critic.json"
: > "$CRITIC_JSON"
[ -f "$CRITIC_OUT" ] && CRITIC_JSON="$CRITIC_OUT"
jq -n \
  --argjson round "${VISUAL_ROUND:-1}" \
  --arg repo "$VISUAL_REPO" \
  --arg url "$VISUAL_URL" \
  --arg sheet "$SHEET" \
  --arg frames "$FRAMES_DIR" \
  --argjson render_seconds "$RENDER_SECONDS" \
  --argjson champion_shots "$CHAMPION_COUNT" \
  --argjson critic_ran "$CRITIC_RAN" \
  --slurpfile checks "$CHECKS" \
  --slurpfile critic "$CRITIC_JSON" \
  '($critic[0] // null) as $c
   | {status:"pending", round:$round, repo:$repo, url:$url,
      contact_sheet:$sheet, frames_dir:$frames,
      render_seconds:$render_seconds, champion_shots:$champion_shots,
      checks:($checks[0] // {}), critic:$c, critic_ran:($critic_ran == 1),
      pairwise:($c.pairwise // "none"),
      critic_calibration:($c.calibration // null),
      worst_axis:($c.worst_axis // ""),
      one_fix:($c.one_fix // ""),
      failures:[(($checks[0].failures) // [])[] | .reason],
      advisory:[]}' > "$SCORE"

# The critic's two failure modes, appended in the words the fix round is handed.
# `pairwise: worse` is listed first on purpose: it is the verdict this stage
# exists to obtain, and the one that fails a render every absolute score liked.
# It carries HOW the verdict was reached, because "both orders said so" and "the
# axes broke a disagreement by 0.6" are two different degrees of certainty, and
# the fix round and the reviewer are entitled to know which one they are acting
# on before they rebuild a scene over it. The other is a critic that answered
# nothing usable at all: no verdict is not a pass.
#
# The absolute verdict is neither. It goes to `advisory`, which decides nothing,
# because an absolute aesthetic score is calibrated by nothing and the bar has
# to be one the reigning look itself clears: this repo's shipped wall — the very
# city the reference board is stills of — fails its own absolute verdict on
# animation_continuity, so enforcing it would fail every challenger and let no
# repo bootstrap. Same rule .creative/visual.conf.sh states for the thresholds.
# It is still written down, because "the critic would have failed this" is worth
# knowing to the fix round, the reviewer and the PR body.
if [ "$CRITIC_RAN" = 1 ]; then
  ADD=$(jq -c '
    (.calibration // null) as $cal
    | (if $cal == null then ""
       elif $cal.tiebreak.used then ", by an axes margin of \($cal.tiebreak.delta) after the \($cal.orders) presentation orders disagreed"
       elif ($cal.orders // 1) > 1 then ", in both presentation orders"
       else "" end) as $firmness
    | {failures: [
        if .pairwise == "worse" then
          "the critic judges this render WORSE than the reigning champion\($firmness) — \(.evidence // "no evidence given"). One fix: \(.one_fix // "none given")"
        else empty end,
        if .error then "the critic produced no usable verdict: \(.error)" else empty end
      ],
       advisory: [
        if .verdict == "fail" and (.error // null) == null then
          "the critic fails this render on \(.worst_axis // "an unnamed axis") — \(.evidence // "no evidence given"). One fix: \(.one_fix // "none given")"
        else empty end
      ]}' "$CRITIC_OUT" 2>/dev/null) || ADD=""
  [ -n "$ADD" ] || ADD='{"failures":[],"advisory":[]}'
  jq --argjson add "$ADD" \
    '.failures = (.failures + $add.failures) | .advisory = (.advisory + $add.advisory)' \
    "$SCORE" > "$SCORE.tmp" && mv "$SCORE.tmp" "$SCORE"
fi

FAIL_COUNT=$(jq -r '.failures | length' "$SCORE")
ADVISORY_COUNT=$(jq -r '.advisory | length' "$SCORE")
if [ "$FAIL_COUNT" -gt 0 ] || [ "$CRITIC_RC" -ne 0 ]; then
  jq '.status = "fail"' "$SCORE" > "$SCORE.tmp" && mv "$SCORE.tmp" "$SCORE"
else
  jq '.status = "pass"' "$SCORE" > "$SCORE.tmp" && mv "$SCORE.tmp" "$SCORE"
fi

echo "artefacts: $FRAMES_DIR/  $SHEET  $SCORE"
# Printed before the failures, so whatever decided the round is the last thing
# above the verdict line — and printed on a passing round too, which is the
# whole point of recording it.
if [ "$ADVISORY_COUNT" -gt 0 ]; then
  echo "advisory:"
  jq -r '.advisory[] | "  - " + .' "$SCORE"
fi
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "failures:"
  jq -r '.failures[] | "  - " + .' "$SCORE"
  # The harness quotes ONE failing step in the log header and in the fix prompt,
  # so make it the one that decided the round.
  step "$(jq -r '.failures[0]' "$SCORE" | tr '\n' ' ' | cut -c1-200)"
  echo "=== visual gate (round $VISUAL_ROUND): FAIL ==="
  exit 1
fi
if [ "$CRITIC_RC" -ne 0 ]; then
  step "the critic returned no usable verdict"
  echo "=== visual gate (round $VISUAL_ROUND): FAIL — the critic returned no verdict ==="
  exit 1
fi
if [ "$ADVISORY_COUNT" -gt 0 ]; then
  echo "=== visual gate (round $VISUAL_ROUND): PASS — $ADVISORY_COUNT advisory ==="
else
  echo "=== visual gate (round $VISUAL_ROUND): PASS ==="
fi
exit 0
