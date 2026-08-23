#!/usr/bin/env bash
# The visual gate, in two halves — because it has two contracts.
#
#   PART A — the gate itself. Two fixture pages that differ only in what the
#     deterministic checks measure: good.html is 16 colours on a 16 px grid
#     with a luminance floor, bad.html is gradients over pure black at no grid
#     at all. The gate must pass one and fail the other from the numbers alone,
#     with no model in the loop. Then, with a champion promoted and a FAKE
#     critic, the verdict this whole stage exists to obtain: a challenger the
#     critic calls `pairwise: worse` fails even when every absolute axis is 5/5
#     and the critic's own verdict is `pass` — and its converse, the half that
#     lets a repo bootstrap at all: an absolute verdict of `fail` is recorded as
#     advisory and decides nothing, so a render the checks passed and no
#     pairwise loss condemned ships whatever the critic thought of it.
#
#   PART B — the pipeline wiring. run-task.sh against a stub VISUAL_GATE_CMD:
#     rounds, the fix round and what it is told, the `visual_failed` terminal
#     status, the round ledger, result.json.visual, the reviewer's prompt, the
#     PR body — and, the one that protects every repo that will never use this,
#     that an unset VISUAL_GATE_CMD leaves the run exactly as it was, down to
#     result.json's key set.
#
# Nothing real is contacted. `claude` (implementer, reviewer, visual fixer and
# critic), `gh` and `curl` are fakes on PATH driven by mode files; the only real
# outside process is the headless Chromium the gate renders with, and the pages
# it renders are two static files in this repo. Part A skips itself with a
# `skip` line on a machine without Playwright rather than pretending to pass.
#
# Usage: bash tests/visual-gate.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$SRC/profiles/visual"
CREATIVE="$PROFILE/creative"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/visual-gate-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { skipped=$((skipped+1)); printf '  skip %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()  { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()  { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has(){ if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
# Numeric comparisons on values the checks produce: awk, because these are
# floats and [ -lt ] is integers only.
lt() { awk -v a="$2" -v b="$3" 'BEGIN{exit !(a+0 < b+0)}' && ok "$1" || bad "$1 ($2 is not < $3)"; }
gt() { awk -v a="$2" -v b="$3" 'BEGIN{exit !(a+0 > b+0)}' && ok "$1" || bad "$1 ($2 is not > $3)"; }

FX="$SRC/tests/fixtures/visual"
FAKES="$ROOT/bin"; mkdir -p "$FAKES"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"; mkdir -p "$RUNS"
CRITIC_MODE="$ROOT/critic-mode"; printf 'better\n' > "$CRITIC_MODE"
CRITIC_CALLS="$ROOT/critic-calls.log"; : > "$CRITIC_CALLS"
CRITIC_PROMPT="$ROOT/critic-prompt.txt"; : > "$CRITIC_PROMPT"
# One answer file per call index, for the cases that must script the two
# presentation orders apart; empty means "use the mode file".
CRITIC_SCRIPT="$ROOT/critic-script"; mkdir -p "$CRITIC_SCRIPT"
# What the critic was actually shown, hashed: one "<sha of A> <sha of B>" line
# per call. The only way to prove the swap really swapped the pixels rather
# than just the labels.
CRITIC_IMAGES="$ROOT/critic-images.log"; : > "$CRITIC_IMAGES"
# sha256 -> the score this image deserves, for the cases that need a critic
# with consistent taste rather than a scripted one.
CRITIC_QUALITY="$ROOT/critic-quality"; mkdir -p "$CRITIC_QUALITY"

VISUAL_PY="${VISUAL_PY:-$HOME/.local/share/uv/tools/shot-scraper/bin/python}"
HAVE_PW=0
"$VISUAL_PY" - <<'PY' >/dev/null 2>&1 && HAVE_PW=1
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=[
        "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
    browser.close()
PY
HAVE_PY=0
python3 -c 'import numpy, PIL' >/dev/null 2>&1 && HAVE_PY=1
HAVE_MAGICK=0
command -v magick >/dev/null 2>&1 && HAVE_MAGICK=1

# Browser selection belongs to the visual profile's established contract, not
# to unrelated feature branches. The renderer launches Playwright's managed
# browser directly and carries no named system-browser channel fallback.
if python3 - "$CREATIVE/frames.py" <<'PY'
import ast
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
launches = [
    node
    for node in ast.walk(tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Attribute)
    and node.func.attr == "launch"
]
assert launches
assert all(all(keyword.arg != "channel" for keyword in call.keywords) for call in launches)
PY
then
  ok "renderer: browser selection stays on Playwright's managed executable"
else
  bad "renderer: an out-of-scope named-browser fallback was introduced"
fi

# --- the fake critic ---------------------------------------------------------
# One `claude` stand-in for every model call in this suite, answering in the
# CLI's own envelope shape (a parsed structured_output object beside the raw
# result string), because that is what critic.sh parses.
#
# It answers per the mode file, or — for the calibration cases, which have to
# make the two presentation orders say different things — per an answer file
# named for the call index ($CRITIC_SCRIPT/1, /2, …). A scripted answer is
# `PREFERRED|AXES_A|AXES_B`, where an axes spec is one score for all six axes,
# optionally `base/bump` to lift `composition` alone: that is how a discordant
# pair lands INSIDE the tiebreak margin rather than two whole points outside it.
#
# Two answer shapes, told apart by the prompt: the blind two-image call
# (images.A, images.B, preferred) and the single-image call (pairwise: none).
# The one-word modes stay order-aware — `worse` means the challenger lost
# whichever position it was shown in — so every case written before the swap
# existed still says what it always said. `worse` is the interesting one:
# perfect axes, a verdict of pass, and a pairwise loss in both orders — the
# shape that must still fail the gate.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in
  *"visual critic"*)
    printf 'critic\n' >> "$CRITIC_CALLS"
    n=\$(grep -c '' "$CRITIC_CALLS" | tr -d ' ')
    printf '%s\n' "\$prompt" > "$CRITIC_PROMPT"
    printf '%s\n' "\$prompt" > "$CRITIC_PROMPT.\$n"
    a=\$(printf '%s\n' "\$prompt" | sed -n 's/^2\. Image A: //p' | head -1)
    b=\$(printf '%s\n' "\$prompt" | sed -n 's/^3\. Image B: //p' | head -1)
    sha_a=""; sha_b=""
    if [ -f "\$a" ] && [ -f "\$b" ]; then
      sha_a=\$(shasum -a 256 "\$a" | awk '{print \$1}')
      sha_b=\$(shasum -a 256 "\$b" | awk '{print \$1}')
      printf '%s %s\n' "\$sha_a" "\$sha_b" >> "$CRITIC_IMAGES"
    fi
    scripted=\$(cat "$CRITIC_SCRIPT/\$n" 2>/dev/null || true)
    mode="\$scripted"
    [ -n "\$mode" ] || mode=\$(cat "$CRITIC_MODE")
    [ "\$mode" = "garbage-once" ] && { printf 'better\n' > "$CRITIC_MODE"; mode=garbage; }
    if [ "\$mode" = garbage ]; then echo "I am afraid I cannot do that."; exit 0; fi
    axes_json() {  # \$1 = base[/bump]
      local base bump
      base="\${1%%/*}"; bump="\${1#*/}"
      [ "\$bump" != "\$1" ] || bump="\$base"
      jq -n --argjson b "\$base" --argjson c "\$bump" \\
        '{palette_discipline:\$b, grid_discipline:\$b, silhouette_readability:\$b,
          composition:\$c, animation_continuity:\$b, style_match_to_reference:\$b}'
    }
    image_json() {  # \$1 = base[/bump]
      jq -n --argjson ax "\$(axes_json "\$1")" \\
        '{axes:\$ax, worst_axis:"composition", evidence:"tile scene-f00, the hero block",
          one_fix:"raise the hero tower and clear the sky above it",
          verdict:(if (\$ax | [.[]] | add / 6) >= 4 then "pass" else "fail" end)}'
    }
    order=1
    case "\$prompt" in *"/call-2/image-a.png"*) order=2 ;; esac
    case "\$prompt" in
      *"images.A and images.B"*)
        # A critic with taste and no memory: when the case has given the two
        # images a quality apiece, it grades them at that quality and prefers
        # the better picture — whichever label it is wearing and whichever call
        # index this is. That is what makes the eval runner testable, and it is
        # parallel-safe in a way an index-scripted answer can never be.
        qa=\$(cat "$CRITIC_QUALITY/\$sha_a" 2>/dev/null || true)
        qb=\$(cat "$CRITIC_QUALITY/\$sha_b" 2>/dev/null || true)
        if [ -z "\$scripted" ] && [ -n "\$qa" ] && [ -n "\$qb" ]; then
          axa="\$qa"; axb="\$qb"
          if   [ "\$qa" -gt "\$qb" ]; then pref=A
          elif [ "\$qb" -gt "\$qa" ]; then pref=B
          else pref=tie; fi
        else
        case "\$mode" in
          *"|"*)         IFS='|' read -r pref axa axb <<<"\$mode" ;;
          no-preference) pref=""; axa=4; axb=4 ;;
          worse)         axa=5; axb=5; if [ "\$order" = 1 ]; then pref=A; else pref=B; fi ;;
          failing)       axa=2; axb=2; if [ "\$order" = 1 ]; then pref=B; else pref=A; fi ;;
          *)             axa=4; axb=4; if [ "\$order" = 1 ]; then pref=B; else pref=A; fi ;;
        esac
        fi
        so=\$(jq -n --argjson A "\$(image_json "\$axa")" --argjson B "\$(image_json "\$axb")" \\
                --arg p "\$pref" \\
          'if \$p == "" then {images:{A:\$A, B:\$B}}
           else {images:{A:\$A, B:\$B}, preferred:\$p} end')
        ;;
      *)
        case "\$mode" in
          worse)   pw=worse; ax=5 ;;
          failing) pw=none;  ax=2 ;;
          *)       pw=none;  ax=4 ;;
        esac
        so=\$(jq -n --argjson im "\$(image_json "\$ax")" --arg pw "\$pw" '\$im + {pairwise:\$pw}')
        ;;
    esac
    jq -n --argjson so "\$so" \\
      '{type:"result", subtype:"success", num_turns:2, total_cost_usd:0.01,
        session_id:"fake-critic", result:(\$so|tostring), structured_output:\$so}'
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKES/claude"

# Scripted answers for the next N calls, indexed from 1. Clears what the last
# case left behind, so a stale answer file can never decide a later run.
script_calls() {
  local i=1 m
  rm -f "$CRITIC_SCRIPT"/*
  : > "$CRITIC_CALLS"
  : > "$CRITIC_IMAGES"
  for m in "$@"; do printf '%s\n' "$m" > "$CRITIC_SCRIPT/$i"; i=$((i + 1)); done
}

# -u VISUAL_LIVE: that flag forces the critic tier on, which is exactly what it
# is for and exactly what these runs must not inherit — the checks-only
# assertions below are about the tier that costs nothing.
run_gate_on() {  # $1 = page, rest = extra env assignments
  local page="$1"; shift
  ( cd "$ROOT/repo" && env -u VISUAL_LIVE PATH="$FAKES:$PATH" CLAUDE_BIN="$FAKES/claude" \
      HARNESS_DIR="$HARNESS" VISUAL_REPO=fixture TEST_PAGE="$page" \
      "$@" bash "$CREATIVE/visual-gate.sh" ) > "$ROOT/gate-$page.log" 2>&1
}

# ---------------------------------------------------------------------------
echo "== part A: the gate against two fixture pages =="
# ---------------------------------------------------------------------------
if [ "$HAVE_PW" = 0 ] || [ "$HAVE_PY" = 0 ] || [ "$HAVE_MAGICK" = 0 ]; then
  skip "part A: needs a runnable Playwright browser ($VISUAL_PY), python3 numpy/Pillow and ImageMagick — not all available here"
else
mkdir -p "$ROOT/repo/.creative"
# The palette LUT good.html is drawn from. Written here rather than committed:
# the sixteen values ARE the fixture's contract, and a list beside the assertion
# that reads it is easier to keep honest than a binary blob.
python3 - "$ROOT/palette.png" <<'PY'
import sys
from PIL import Image
pal = ["#14182c", "#1e2440", "#2b3358", "#3d4a78", "#5a6ea0", "#7d94c0", "#a8bce0",
       "#d6e2f5", "#4a2e1e", "#7a4a2a", "#b4703c", "#e0a45c", "#2e4a2e", "#4a7a3c",
       "#7ab45c", "#f0d890"]
im = Image.new("RGB", (len(pal), 1))
im.putdata([tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in pal])
im.save(sys.argv[1])
PY

cat > "$ROOT/repo/.creative/visual.conf.sh" <<EOF
VISUAL_URL="file://$FX"
VISUAL_SHOTS=("scene|/\${TEST_PAGE:-good.html}|100")
VISUAL_FRAMES=2
VISUAL_WAIT_MS=100
VISUAL_SETTLE_MS=200
VISUAL_WIDTH=640
VISUAL_HEIGHT=360
VISUAL_DPR=1
VISUAL_PALETTE="$ROOT/palette.png"
VISUAL_REFS="$ROOT/repo/.creative/refs"
VISUAL_MAX_OFFPALETTE_PCT=2
VISUAL_MAX_OFFGRID_PCT=25
VISUAL_MAX_PURE_BLACK_PCT=20
VISUAL_MIN_LEGIBILITY=0.3
VISUAL_MAX_FRAME_RMSE=0.05
VISUAL_MIN_SSIM=0.6
# Deliberately NOT \${VISUAL_CRITIC:-0}: visual-gate.sh applies its own default
# before it sources this file, so a conf written that way can never see the
# variable unset. Its own knob, so a test can ask for the tier explicitly.
VISUAL_CRITIC="\${TEST_CRITIC:-0}"
EOF
mkdir -p "$ROOT/repo/.creative/refs"
cp "$ROOT/palette.png" "$ROOT/repo/.creative/refs/board.png"

# --- the good page, checks only ---------------------------------------------
run_gate_on good.html
RC=$?
OUT=$(cat "$ROOT/gate-good.html.log")
check "good: the gate passes a render that satisfies every check" "$RC" "0"
exists "good: frame 0" "$ROOT/repo/.harness/frames/scene-f00.png"
exists "good: frame 1" "$ROOT/repo/.harness/frames/scene-f01.png"
exists "good: a contact sheet" "$ROOT/repo/.harness/contact-sheet.png"
exists "good: a score file" "$ROOT/repo/.harness/visual-score.json"
SHEET_BYTES=$(wc -c < "$ROOT/repo/.harness/contact-sheet.png" | tr -d ' ')
lt "good: the sheet stays under the 500 KB the Read tool recompresses above" "$SHEET_BYTES" 500000
CHECKS="$ROOT/repo/.harness/visual-checks.json"
F0="$(jq -r '.shots.scene.frames[0]' "$CHECKS")"
check "good: nothing is pure black" "$(printf '%s' "$F0" | jq -r .luminance.pure_black_pct)" "0.0"
gt "good: and the darkest pixel is above the floor" \
  "$(printf '%s' "$F0" | jq -r .luminance.min_luma)" 0.002
check "good: every pixel is a palette colour" \
  "$(printf '%s' "$F0" | jq -r .palette.offpalette_pct)" "0.0"
check "good: the 16 px grid is detected as 16 px" \
  "$(printf '%s' "$F0" | jq -r .grid.pitch_px)" "16"
lt "good: and nothing sits off it" "$(printf '%s' "$F0" | jq -r .grid.offgrid_pct)" 1
lt "good: two identical frames are perfectly continuous" \
  "$(jq -r '.shots.scene.continuity.max_rmse' "$CHECKS")" 0.0001
check "good: the verdict is a pass" "$(jq -r .status "$ROOT/repo/.harness/visual-score.json")" "pass"
check "good: with no champion, pairwise is none" \
  "$(jq -r .pairwise "$ROOT/repo/.harness/visual-score.json")" "none"
check "good: and no critic was paid for" "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "0"

# The sheet is required evidence, not a best-effort decoration. Force an
# impossible byte ceiling: a checks-clean render must fail closed before the
# critic rather than pass with no image for either model to inspect.
run_gate_on good.html TEST_CRITIC=1 SHEET_MAX_BYTES=1
check "sheet: the gate fails when it cannot build the required contact sheet" "$?" "2"
file_has "$ROOT/repo/.harness/visual-score.json" "could not build a PNG" \
  "sheet: the score says why the required artefact is absent"
check "sheet: the critic is not called without its image" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "0"

# --- the bad page, checks only ----------------------------------------------
run_gate_on bad.html
RC=$?
OUT=$(cat "$ROOT/gate-bad.html.log")
check "bad: the gate fails it on the numbers alone" "$RC" "1"
BAD="$(jq -r '.shots.scene.frames[0]' "$ROOT/repo/.harness/visual-checks.json")"
gt "bad: most of the frame is pure black" \
  "$(printf '%s' "$BAD" | jq -r .luminance.pure_black_pct)" 50
gt "bad: and almost nothing is on the palette" \
  "$(printf '%s' "$BAD" | jq -r .palette.offpalette_pct)" 20
has "$OUT" "of the frame is pure black" "bad: the log says which check failed, in words"
has "$OUT" "off-palette" "bad: and names the palette failure too"
check "bad: the score records the failure" \
  "$(jq -r .status "$ROOT/repo/.harness/visual-score.json")" "fail"
gt "bad: with one reason per failing check" \
  "$(jq -r '.failures | length' "$ROOT/repo/.harness/visual-score.json")" 1

# The two tiers, in the order that saves money: the same broken page with the
# critic switched ON must still not reach it.
run_gate_on bad.html TEST_CRITIC=1
check "tiers: it still fails" "$?" "1"
has "$(cat "$ROOT/gate-bad.html.log")" "the deterministic checks already failed" \
  "tiers: the critic is not asked to price an opinion on a render that is already broken"
check "tiers: so nothing was billed" "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "0"

# --- the bootstrap round: no champion, and a critic that hates the render -----
# The first run any repo ever makes has nothing to be pairwise against, so the
# only opinion on offer is an absolute grade calibrated by nothing — and the
# shipped wall this gate was built for fails its own. Enforcing that verdict
# means no repo can ever have a first green round, so it decides nothing: the
# deterministic checks decide, and the critic's opinion is written down.
script_calls
printf 'failing\n' > "$CRITIC_MODE"
run_gate_on good.html TEST_CRITIC=1
check "absolute: a critic that fails the render does not fail the gate" "$?" "0"
BOOT="$ROOT/repo/.harness/visual-score.json"
check "absolute: the round the checks passed is a pass" "$(jq -r .status "$BOOT")" "pass"
check "absolute: the critic was asked, and said fail" "$(jq -r .critic.verdict "$BOOT")" "fail"
check "absolute: with nothing to be pairwise against" "$(jq -r .pairwise "$BOOT")" "none"
check "absolute: so nothing it said is a failure" "$(jq -r '.failures | length' "$BOOT")" "0"
check "absolute: its verdict is recorded as advisory instead" \
  "$(jq -r '.advisory | length' "$BOOT")" "1"
ADV="$(jq -r '.advisory[0]' "$BOOT")"
has "$ADV" "the critic fails this render on composition" \
  "absolute: in the sentence that used to be the failure, naming the axis"
has "$ADV" "raise the hero tower" "absolute: and the one fix travels with it"
has "$(cat "$ROOT/gate-good.html.log")" "advisory:" \
  "absolute: under its own heading in the log, where failures would have been"
has "$(cat "$ROOT/gate-good.html.log")" "PASS — 1 advisory" \
  "absolute: and the pass line says the opinion exists"
printf 'better\n' > "$CRITIC_MODE"

# --- a champion, and the pairwise verdict ------------------------------------
run_gate_on good.html   # restore the good frames to promote from
env HARNESS_DIR="$HARNESS" bash "$CREATIVE/champion.sh" promote fixture \
  "$ROOT/repo/.harness" > "$ROOT/promote.log" 2>&1
check "champion: promotion is a human command, and it worked" "$?" "0"
exists "champion: the shot's frame is kept outside every worktree" \
  "$HARNESS/champion/fixture/champion-scene.png"
exists "champion: with the sheet the critic compares against" \
  "$HARNESS/champion/fixture/champion-sheet.png"
file_has "$HARNESS/champion/fixture/champion.json" '"shots"' \
  "champion: and a record of what reigns"

printf 'worse\n' > "$CRITIC_MODE"
script_calls
run_gate_on good.html TEST_CRITIC=1
RC=$?
OUT=$(cat "$ROOT/gate-good.html.log")
SCORE="$ROOT/repo/.harness/visual-score.json"
check "pairwise: a challenger the critic calls WORSE fails the gate" "$RC" "1"
check "pairwise: even though every axis it scored is 5/5" \
  "$(jq -r '[.critic.axes[]] | unique | join(",")' "$SCORE")" "5"
check "pairwise: and its own verdict was pass" "$(jq -r .critic.verdict "$SCORE")" "pass"
check "pairwise: the verdict is recorded where result.json reads it" \
  "$(jq -r .pairwise "$SCORE")" "worse"
file_has "$SCORE" "WORSE than the reigning champion" \
  "pairwise: with a reason a fix round can act on"
file_has "$SCORE" "in both presentation orders" \
  "pairwise: which says how firm the verdict is, not just what it was"
exists "champion: it was copied in so the critic could Read it" \
  "$ROOT/repo/.harness/champion/champion-scene.png"
gt "champion: SSIM against an identical render is ~1" \
  "$(jq -r '.checks.shots.scene.vs_champion.ssim' "$SCORE")" 0.9

# The calibrated protocol, through the gate: two calls, one per order, and the
# concordance facts carried into the file every downstream stage reads.
check "orders: the gate paid for both presentation orders" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "2"
check "orders: and they agreed" "$(jq -r '.critic_calibration.concordant' "$SCORE")" "true"
check "orders: so no tiebreak was needed" \
  "$(jq -r '.critic_calibration.tiebreak.used' "$SCORE")" "false"
check "orders: the score file carries the whole calibration record" \
  "$(jq -r '.critic_calibration.runs | length' "$SCORE")" "2"
CHAMP_SHA=$(shasum -a 256 "$ROOT/repo/.harness/champion/champion-sheet.png" | awk '{print $1}')
CHAL_SHA=$(shasum -a 256 "$ROOT/repo/.harness/contact-sheet.png" | awk '{print $1}')
check "blind: order 1 showed the champion as A and the challenger as B" \
  "$(sed -n 1p "$CRITIC_IMAGES")" "$CHAMP_SHA $CHAL_SHA"
check "blind: order 2 showed the same two sheets the other way round" \
  "$(sed -n 2p "$CRITIC_IMAGES")" "$CHAL_SHA $CHAMP_SHA"

CRITIC_TEXT=$(cat "$CRITIC_PROMPT")
has "$CRITIC_TEXT" "grading someone else's work" "critic: is told whose work it is grading"
has "$CRITIC_TEXT" "Image A:" "critic: is given one sheet as A"
has "$CRITIC_TEXT" "Image B:" "critic: and the other as B"
has "$CRITIC_TEXT" "board.png" "critic: reference board first, so the prefix caches"
# Blindness is the whole point, and a path is a label too: `champion-sheet.png`
# tells the model which one reigns as plainly as the word would.
has_not "$CRITIC_TEXT" "champion" "blind: the word never reaches the model"
has_not "$CRITIC_TEXT" "challenger" "blind: nor its opposite"
has_not "$CRITIC_TEXT" "champion-sheet.png" "blind: nor the file name that gives it away"
has "$CRITIC_TEXT" "image-a.png" "blind: it reads laundered copies instead"

printf 'better\n' > "$CRITIC_MODE"
script_calls
run_gate_on good.html TEST_CRITIC=1
RC=$?
check "better: the same render passes when the critic prefers it" "$RC" "0"
check "better: and the pairwise verdict says so" "$(jq -r .pairwise "$SCORE")" "better"
check "better: the score carries what both calls cost" \
  "$(jq -r .critic.cost_usd "$SCORE")" "0.02"

# The orders disagree: the axes margin decides, and the failure sentence says so
# rather than claiming a firmness the two answers never had.
script_calls 'A|5|3' 'A|3|5'
run_gate_on good.html TEST_CRITIC=1
check "tiebreak: a challenger the axes put 2 points down still fails the gate" "$?" "1"
check "tiebreak: with the orders recorded as discordant" \
  "$(jq -r '.critic_calibration.concordant' "$SCORE")" "false"
check "tiebreak: the margin decided it" \
  "$(jq -r '.critic_calibration.tiebreak.used' "$SCORE")" "true"
check "tiebreak: on a delta the score file states" \
  "$(jq -r '.critic_calibration.tiebreak.delta' "$SCORE")" "-2"
file_has "$SCORE" "by an axes margin of -2" \
  "tiebreak: and the fix round is told the verdict was the margin's, not the critic's"

# The same rule with a champion in play: pairwise is the answer that decides,
# so a challenger the critic will not call worse in either order ships — even
# though the same critic, grading it alone, failed it outright. Scripted rather
# than moded, because this pair of answers is the whole point: `tie` from both
# presentation orders, on axes low enough for the absolute verdict to be `fail`.
script_calls 'tie|2|2' 'tie|2|2'
run_gate_on good.html TEST_CRITIC=1
check "advisory: a challenger tied in both orders passes with the critic against it" "$?" "0"
check "advisory: the answer that decided it" "$(jq -r .pairwise "$SCORE")" "tie"
check "advisory: the answer that did not" "$(jq -r .critic.verdict "$SCORE")" "fail"
check "advisory: which cost the round nothing" "$(jq -r '.failures | length' "$SCORE")" "0"
check "advisory: and is on the record anyway" "$(jq -r '.advisory | length' "$SCORE")" "1"
has "$(jq -r '.advisory[0]' "$SCORE")" "raise the hero tower" \
  "advisory: with the one fix a human can act on"
fi

# ---------------------------------------------------------------------------
echo "== the critic protocol =="
# ---------------------------------------------------------------------------
# No render needed: this is about what critic.sh does with what the CLI returns.
if [ "$HAVE_MAGICK" = 0 ]; then
  skip "critic: needs ImageMagick to make a sheet to grade"
else
magick -size 64x64 xc:'#2b3358' "$ROOT/sheet.png" 2>/dev/null
mkdir -p "$ROOT/promotion-source/frames"
cp "$ROOT/sheet.png" "$ROOT/promotion-source/frames/scene-f00.png"
cp "$ROOT/sheet.png" "$ROOT/promotion-source/frames/scene-f01.png"
env HARNESS_DIR="$HARNESS" bash "$CREATIVE/champion.sh" promote manual \
  "$ROOT/promotion-source" > "$ROOT/manual-promote.log" 2>&1
check "champion: a valid source is promoted" "$?" "0"
exists "champion: promotion always builds the pairwise sheet" \
  "$HARNESS/champion/manual/champion-sheet.png"
CHAMPION_SHA=$(shasum -a 256 "$HARNESS/champion/manual/champion-scene.png" | awk '{print $1}')
mkdir -p "$ROOT/bad-promotion/frames"
cp "$ROOT/sheet.png" "$ROOT/bad-promotion/frames/not-a-first-frame.png"
env HARNESS_DIR="$HARNESS" bash "$CREATIVE/champion.sh" promote manual \
  "$ROOT/bad-promotion" > "$ROOT/bad-promote.log" 2>&1
check "champion: a malformed promotion source is rejected" "$?" "1"
check "champion: and cannot erase the render that already reigns" \
  "$(shasum -a 256 "$HARNESS/champion/manual/champion-scene.png" | awk '{print $1}')" \
  "$CHAMPION_SHA"
env HARNESS_DIR="$HARNESS" bash "$CREATIVE/champion.sh" promote '../escape' \
  "$ROOT/promotion-source" > "$ROOT/unsafe-promote.log" 2>&1
check "champion: unsafe repo names cannot escape the champion root" "$?" "2"

# Corrupt champion state must not silently downgrade a pairwise round into a
# no-champion absolute grade. This fails before Chromium is launched, so it is
# testable even in the review sandbox where browser launch is denied.
mkdir -p "$HARNESS/champion/broken" "$ROOT/champion-check/.creative"
cp "$ROOT/sheet.png" "$HARNESS/champion/broken/champion-scene.png"
cat > "$ROOT/champion-check/.creative/visual.conf.sh" <<EOF
VISUAL_URL="file://$FX"
VISUAL_SHOTS=("scene|/good.html|100")
VISUAL_CRITIC=0
EOF
( cd "$ROOT/champion-check" && HARNESS_DIR="$HARNESS" VISUAL_REPO=broken \
    bash "$CREATIVE/visual-gate.sh" ) > "$ROOT/broken-champion.log" 2>&1
check "champion: frames without a pairwise sheet fail closed" "$?" "2"
file_has "$ROOT/broken-champion.log" "no champion-sheet.png" \
  "champion: the log explains how to repair the state"
script_calls
printf 'garbage\n' > "$CRITIC_MODE"
env CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic.sh" \
  --challenger "$ROOT/sheet.png" --out "$ROOT/verdict.json" > "$ROOT/critic.log" 2>&1
check "malformed: a critic that answers with prose is a failed gate, not a pass" "$?" "1"
check "malformed: after exactly one retry" "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "2"
check "malformed: and the verdict says fail" "$(jq -r .verdict "$ROOT/verdict.json")" "fail"
file_has "$ROOT/verdict.json" "no valid structured output" "malformed: with the reason"

script_calls
printf 'garbage-once\n' > "$CRITIC_MODE"
env CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic.sh" \
  --challenger "$ROOT/sheet.png" --out "$ROOT/verdict.json" > "$ROOT/critic2.log" 2>&1
check "retry: one bad answer followed by a good one is a verdict" "$?" "0"
check "retry: it took two calls" "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "2"
check "retry: and no champion produces the required pairwise value" \
  "$(jq -r .pairwise "$ROOT/verdict.json")" "none"
check "retry: a single image has nothing to calibrate" \
  "$(jq -r '.calibration' "$ROOT/verdict.json")" "null"

script_calls
printf 'worse\n' > "$CRITIC_MODE"
env CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic.sh" \
  --challenger "$ROOT/sheet.png" --out "$ROOT/verdict.json" > "$ROOT/critic3.log" 2>&1
check "semantic: pairwise cannot compare against a champion that was not supplied" "$?" "1"
check "semantic: the invalid answer is retried once" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "2"

script_calls no-preference no-preference
env CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic.sh" \
  --challenger "$ROOT/sheet.png" --champion "$ROOT/sheet.png" \
  --out "$ROOT/verdict.json" > "$ROOT/critic4.log" 2>&1
check "semantic: a two-image call that states no preference is a failed critic" "$?" "1"
file_has "$ROOT/verdict.json" "must score images.A and images.B" \
  "semantic: the failed verdict records the broken invariant"

# --- the calibrated protocol -------------------------------------------------
# Blind, both orders, concordance or a margin — with the model faked per call
# index, which is the only way to make one order disagree with the other on
# demand. Two different sheets, so the swap is provable by their hashes.
magick -size 64x64 xc:'#7a4a2a' "$ROOT/sheet-b.png" 2>/dev/null
CHAMP_PNG="$ROOT/sheet.png"; CHAL_PNG="$ROOT/sheet-b.png"
CHAMP_SHA=$(shasum -a 256 "$CHAMP_PNG" | awk '{print $1}')
CHAL_SHA=$(shasum -a 256 "$CHAL_PNG" | awk '{print $1}')
CAL="$ROOT/calibrated.json"
run_critic() {  # $1 = CRITIC_ORDERS, $2 = margin, rest = one scripted answer per call
  local orders="$1" margin="$2"; shift 2
  script_calls "$@"
  env CLAUDE_BIN="$FAKES/claude" CRITIC_ORDERS="$orders" \
      CRITIC_TIEBREAK_MARGIN="$margin" bash "$CREATIVE/critic.sh" \
      --challenger "$CHAL_PNG" --champion "$CHAMP_PNG" --rubric "$CREATIVE/rubric.md" \
      --out "$CAL" > "$ROOT/critic-calibrated.log" 2>&1
}
cal() { jq -r "$1" "$CAL"; }

# Order 1 prefers A (the champion), order 2 prefers B (the champion again):
# the same answer about the challenger from both positions.
run_critic 2 0.5 'A|4|3' 'B|3|4'
check "concordant: two agreeing orders are a verdict" "$?" "0"
check "concordant: which is what the gate reads" "$(cal .pairwise)" "worse"
check "concordant: recorded as concordant" "$(cal .calibration.concordant)" "true"
check "concordant: with no tiebreak" "$(cal .calibration.tiebreak.used)" "false"
check "concordant: and the rule that fired, in words" \
  "$(cal '.calibration.rule | split(" —")[0]')" "concordance"
check "concordant: it cost two calls" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "2"
check "concordant: both of which are in the record" "$(cal '.calibration.runs | length')" "2"
check "concordant: order 1 showed the champion as A" \
  "$(sed -n 1p "$CRITIC_IMAGES")" "$CHAMP_SHA $CHAL_SHA"
check "concordant: order 2 showed it as B" \
  "$(sed -n 2p "$CRITIC_IMAGES")" "$CHAL_SHA $CHAMP_SHA"
check "concordant: the axes belong to the challenger, from the first call" \
  "$(cal '[.axes[]] | unique | join(",")')" "3"
check "concordant: and its absolute verdict too" "$(cal .verdict)" "fail"
check "concordant: the two calls' cost is summed" "$(cal .cost_usd)" "0.02"
check "concordant: so are their turns" "$(cal .num_turns)" "4"
check "concordant: the mean axes of each image are stated" \
  "$(cal '[.calibration.champion_axes, .calibration.challenger_axes] | join("/")')" "4/3"
check "concordant: every field the gate has always read is still there" \
  "$(cal '[.ran,.model,.verdict,.pairwise,.worst_axis,.evidence,.one_fix,.axes,
           .cost_usd,.num_turns,.attempts,.seconds] | map(. != null) | all')" "true"
check "concordant: and error is null on a verdict" "$(cal '.error')" "null"

run_critic 2 0.5 'B|3|4' 'A|4|3'
check "concordant: two orders that agree the other way are better" "$(cal .pairwise)" "better"
run_critic 2 0.5 'tie|4|4' 'tie|4|4'
check "concordant: two ties are a tie" "$(cal .pairwise)" "tie"

# Order 1 says the challenger won, order 2 says it lost. The axes break it.
run_critic 2 0.5 'B|3|5' 'B|5|3'
check "discordant: the axes margin decides" "$(cal .pairwise)" "better"
check "discordant: and says so" "$(cal .calibration.tiebreak.used)" "true"
check "discordant: on the difference of the two means" \
  "$(cal .calibration.tiebreak.delta)" "2"
check "discordant: never claiming the orders agreed" "$(cal .calibration.concordant)" "false"
check "discordant: the rule that fired is named" \
  "$(cal '.calibration.rule | split(" —")[0]')" "axes margin"

run_critic 2 0.5 'A|5|3' 'A|3|5'
check "discordant: a challenger the axes put below the champion is worse" "$(cal .pairwise)" "worse"
check "discordant: by a negative margin" "$(cal .calibration.tiebreak.delta)" "-2"

# The interesting one: the orders disagree and the axes barely separate them.
# 4.1667 - 4 = 0.1667, inside the margin — so the honest answer is `tie`, not
# whichever order happened to be asked first.
run_critic 2 0.5 'B|4|4/5' 'B|4/5|4'
check "margin: a disagreement inside the margin is a tie" "$(cal .pairwise)" "tie"
gt "margin: even though the challenger scored a shade higher" \
  "$(cal .calibration.tiebreak.delta)" 0
lt "margin: by less than the margin" "$(cal .calibration.tiebreak.delta)" 0.5
run_critic 2 0.1 'B|4|4/5' 'B|4/5|4'
check "margin: and the knob moves the line" "$(cal .pairwise)" "better"
check "margin: which the record states rather than assuming the default" \
  "$(cal .calibration.tiebreak.margin)" "0.1"
run_critic 2 0 'B|4|4' 'B|4|4'
check "margin: a zero margin still calls an exact zero delta a tie" \
  "$(cal .pairwise)" "tie"

# A second call that dies is a failed critic. Falling back to the one order we
# already measured as biased is exactly the silent pass this stage forbids.
run_critic 2 0.5 'A|4|3' garbage garbage
check "second call: a critic that cannot answer twice is a failed gate" "$?" "1"
check "second call: after its own retry" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "3"
check "second call: with no verdict to fall back on" "$(cal .verdict)" "fail"
check "second call: and none of the first order's pairwise answer" "$(cal .pairwise)" "none"
file_has "$CAL" "presentation order 2" "second call: the reason names which order died"
check "second call: what the dead run did cost is still reported" "$(cal .cost_usd)" "0.01"

run_critic 1 0.5 'A|4|3'
check "one order: CRITIC_ORDERS=1 asks once" \
  "$(grep -c '^critic$' "$CRITIC_CALLS" | tr -d ' ')" "1"
check "one order: and takes that answer" "$(cal .pairwise)" "worse"
check "one order: recorded as one order" "$(cal .calibration.orders)" "1"
check "one order: cannot claim concordance from one answer" \
  "$(cal .calibration.concordant)" "false"
check "one order: with no concordance claimed for it" \
  "$(cal '.calibration.rule | split(" —")[0]')" "single order"
check "one order: and no tiebreak" "$(cal .calibration.tiebreak.used)" "false"

# --- the eval runner ----------------------------------------------------------
# critic-eval.sh is live-only for a reason — a fake critic scoring
# 100 % on an eval set would be the most misleading artefact in this repo — but
# its ARITHMETIC is not about the model at all, and shipping an unrun scorer
# would be its own joke. So: the flag on, the CLI faked, and a critic with fixed
# taste (above) standing in for one with judgement. What is asserted here is the
# table, the three rates, summary.json and the exit code; whether the real
# critic can tell a good render from a bad one is what the live run answers.
script_calls
EVAL="$ROOT/eval"; mkdir -p "$EVAL/sheets"
magick -size 64x64 xc:'#14182c' "$EVAL/sheets/good.png" 2>/dev/null
magick -size 64x64 xc:'#7a4a2a' "$EVAL/sheets/bad.png" 2>/dev/null
quality() { printf '%s\n' "$2" > "$CRITIC_QUALITY/$(shasum -a 256 "$1" | awk '{print $1}')"; }
quality "$EVAL/sheets/good.png" 5
quality "$EVAL/sheets/bad.png" 2
jq -n '{pairs:[
  {id:"good-vs-bad", better:"sheets/good.png", worse:"sheets/bad.png",
   expect:"worse", note:"a human ranked these"},
  {id:"good-vs-good", better:"sheets/good.png", worse:null,
   expect:"tie", note:"the same sheet twice"}]}' > "$EVAL/pairs.json"
run_eval() {  # $1 = pairs file, rest = extra args
  local pairs="$1"; shift
  rm -rf "$ROOT/eval-out"
  env VISUAL_LIVE=1 CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic-eval.sh" \
    --pairs "$pairs" --out "$ROOT/eval-out" "$@" > "$ROOT/eval.log" 2>&1
}
esum() { jq -r "$1" "$ROOT/eval-out/summary.json"; }

run_eval "$EVAL/pairs.json" --repeats 2 --jobs 1
check "eval: a set the critic gets right exits clean" "$?" "0"
exists "eval: and leaves a summary" "$ROOT/eval-out/summary.json"
check "eval: one run per pair per repeat" "$(esum '.runs | length')" "4"
check "eval: the ranked pair comes out worse, every time" \
  "$(esum '[.runs[] | select(.id == "good-vs-bad") | .got] | unique | join(",")')" "worse"
check "eval: and the same sheet twice is a tie" \
  "$(esum '[.runs[] | select(.id == "good-vs-good") | .got] | unique | join(",")')" "tie"
check "eval: accuracy is measured against the human ranking" \
  "$(esum '.accuracy.correct')" "4"
check "eval: separately on the pairs a human judged outright" \
  "$(esum '"\(.accuracy_enforced.correct)/\(.accuracy_enforced.total)"')" "2/2"
check "eval: order-concordance counts the runs whose two orders agreed" \
  "$(esum '"\(.order_concordance.agreed)/\(.order_concordance.total)"')" "4/4"
check "eval: repeat-agreement counts the pairs that answered the same way twice" \
  "$(esum '"\(.repeat_agreement.pairs)/\(.repeat_agreement.total)"')" "2/2"
check "eval: and says it actually measured it" "$(esum '.repeat_agreement.measured')" "true"
file_has "$ROOT/eval.log" "order-concordance:" "eval: the three numbers are printed, not just filed"
file_has "$ROOT/eval.log" "PAIR" "eval: under a table of every run"
gt "eval: with what the whole thing cost" "$(esum '.cost_usd')" 0

# The same critic, a set that claims the opposite: the ranking is what fails,
# and it fails loudly enough to stop a pipeline.
jq -n '{pairs:[{id:"upside-down", better:"sheets/bad.png", worse:"sheets/good.png",
                expect:"worse", note:"claims the good sheet is the weaker one"}]}' \
  > "$EVAL/wrong.json"
run_eval "$EVAL/wrong.json"
check "eval: a human-judged pair the critic gets wrong exits non-zero" "$?" "1"
file_has "$ROOT/eval.log" "expected worse, got better" "eval: naming the pair and both answers"

# A tie that came back strong is information, not a regression.
jq -n '{pairs:[{id:"call-it-a-tie", better:"sheets/good.png", worse:"sheets/bad.png",
                expect:"tie", note:"expected to tie, will not"}]}' > "$EVAL/tie.json"
run_eval "$EVAL/tie.json"
check "eval: a tie pair with a strong verdict is reported, not failed" "$?" "0"
file_has "$ROOT/eval.log" "reported, not failed" "eval: and said out loud"

run_eval "$EVAL/pairs.json" --jobs 2
check "eval: pairs can run concurrently" "$?" "0"
check "eval: without losing a run" "$(esum '.runs | length')" "2"

CRITIC_ORDERS=1 run_eval "$EVAL/pairs.json"
check "eval: single-order mode does not invent an order-concordance rate" \
  "$(esum '"\(.order_concordance.total)/\(.order_concordance.rate)"')" "0/null"
check "eval: one repeat does not invent a repeat-agreement rate" \
  "$(esum '"\(.repeat_agreement.total)/\(.repeat_agreement.rate)"')" "0/null"

printf 'garbage\n' > "$CRITIC_MODE"
run_eval "$EVAL/pairs.json" --repeats 2
check "eval: repeated critic failures still fail the ranked pair" "$?" "1"
check "eval: repeated failures are not counted as repeat agreement" \
  "$(esum '"\(.repeat_agreement.pairs)/\(.repeat_agreement.total)"')" "0/2"
printf 'better\n' > "$CRITIC_MODE"

env -u VISUAL_LIVE CLAUDE_BIN="$FAKES/claude" bash "$CREATIVE/critic-eval.sh" \
  --pairs "$EVAL/pairs.json" --out "$ROOT/eval-out" > "$ROOT/eval-refuse.log" 2>&1
check "eval: it refuses to spend money without VISUAL_LIVE=1" "$?" "2"
file_has "$ROOT/eval-refuse.log" "VISUAL_LIVE=1" "eval: telling you how to ask for it"
run_eval "$EVAL/pairs.json" --jobs 9
check "eval: and refuses to run nine critics at a subscription" "$?" "2"

# The rubric is pasted verbatim into a blind call, so a rubric that names the
# champion un-blinds it. The two this repo ships must not.
leak=''
for r in "$CREATIVE/rubric.md" "$SRC/.creative/rubric.md"; do
  grep -qiE 'champion|challenger|the (current|new) render' "$r" && leak="$leak $r"
done
if [ -z "$leak" ]; then ok "blind: no shipped rubric names either image"
else bad "blind: a shipped rubric un-blinds the critic:$leak"; fi

# More than nine images used to make ImageMagick paginate into out-0.png and
# out-1.png while leaving the requested path missing. It must remain one sheet.
bash "$CREATIVE/contact-sheet.sh" "$ROOT/many-sheet.png" \
  "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" \
  "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" "$ROOT/sheet.png" \
  > "$ROOT/many-sheet.log" 2>&1
check "sheet: ten frames still produce one contact sheet" "$?" "0"
exists "sheet: at the requested path" "$ROOT/many-sheet.png"

SHEET_MAX_BYTES=1 bash "$CREATIVE/contact-sheet.sh" "$ROOT/impossible-sheet.png" \
  "$ROOT/sheet.png" > "$ROOT/impossible-sheet.log" 2>&1
check "sheet: an impossible byte ceiling is an error, never a warning-pass" "$?" "1"
fi

# --- the real critic, on request only ----------------------------------------
# Everything above fakes the model, which is what makes this suite hermetic and
# free. The one thing a fake can never prove is that the CLI contract still
# holds: that --json-schema is real, that the settings profile lets Read open a
# PNG, that --add-dir makes the blinded copies readable where they actually
# live, and that what comes back parses. VISUAL_LIVE=1 spends ~$1 and a few
# minutes to check exactly that, and nothing else. It is not the eval set —
# critic-eval.sh is, and it measures whether the answers are any good.
if [ "${VISUAL_LIVE:-0}" != 1 ]; then
  skip "live: the real critic is not exercised (VISUAL_LIVE=1 spends ~\$1 to check the CLI contract, both orders included)"
elif [ "$HAVE_MAGICK" = 0 ]; then
  skip "live: needs ImageMagick to make a sheet to grade"
else
  magick -size 512x288 gradient:'#14182c-#7d94c0' "$ROOT/live-sheet.png" 2>/dev/null
  env -u CLAUDE_BIN bash "$CREATIVE/critic.sh" \
    --challenger "$ROOT/live-sheet.png" --rubric "$CREATIVE/rubric.md" \
    --out "$ROOT/live-verdict.json" > "$ROOT/live-critic.log" 2>&1
  check "live: the real critic returns a verdict" "$?" "0"
  case "$(jq -r .verdict "$ROOT/live-verdict.json" 2>/dev/null)" in
    pass|fail) ok "live: which is pass or fail, per the schema" ;;
    *) bad "live: the verdict is neither pass nor fail" ;;
  esac
  case "$(jq -r .pairwise "$ROOT/live-verdict.json" 2>/dev/null)" in
    none) ok "live: and pairwise is none, because no champion was given" ;;
    *) bad "live: pairwise should be none without a champion" ;;
  esac
  check "live: all six axes came back" \
    "$(jq -r '.axes | length' "$ROOT/live-verdict.json" 2>/dev/null)" "6"

  # The two-image half of the contract, which the single call above cannot
  # reach: the blind schema, the swapped second call, and the Read of a
  # laundered copy that lives in the scratch dir --add-dir names. The same
  # sheet is given twice on purpose — there is no better picture, so a
  # calibrated critic has nothing to prefer, and `tie` is the answer this whole
  # protocol was built to be able to give.
  env -u CLAUDE_BIN bash "$CREATIVE/critic.sh" \
    --challenger "$ROOT/live-sheet.png" --champion "$ROOT/live-sheet.png" \
    --rubric "$CREATIVE/rubric.md" \
    --out "$ROOT/live-pair.json" > "$ROOT/live-pair.log" 2>&1
  check "live: the real critic answers a two-image call too" "$?" "0"
  check "live: in both presentation orders" \
    "$(jq -r '.calibration.runs | length' "$ROOT/live-pair.json" 2>/dev/null)" "2"
  check "live: each of which graded both images" \
    "$(jq -r '[.calibration.runs[] | (.axes_a | length), (.axes_b | length)] | unique | join(",")' \
       "$ROOT/live-pair.json" 2>/dev/null)" "6"
  check "live: and stated a preference the schema allows" \
    "$(jq -r '[.calibration.runs[] | .preferred]
              | map(. == "A" or . == "B" or . == "tie") | all' \
       "$ROOT/live-pair.json" 2>/dev/null)" "true"
  case "$(jq -r .pairwise "$ROOT/live-pair.json" 2>/dev/null)" in
    tie) ok "live: the same sheet twice is a tie" ;;
    *) bad "live: the same sheet twice came back as $(jq -r .pairwise "$ROOT/live-pair.json") — the judge preferred a position over a picture" ;;
  esac
fi

# The profile is the guarantee, so assert it rather than trusting the prose.
SETTINGS="$CREATIVE/critic-settings.json"
check "profile: the critic may Read" "$(jq -r '.permissions.allow | index("Read") != null' "$SETTINGS")" "true"
check "profile: and may not Bash" "$(jq -r '.permissions.deny | index("Bash") != null' "$SETTINGS")" "true"
check "profile: nor Write" "$(jq -r '.permissions.deny | index("Write") != null' "$SETTINGS")" "true"
check "profile: no allow rule grants a shell" \
  "$(jq -r '[.permissions.allow[] | select(startswith("Bash"))] | length' "$SETTINGS")" "0"

# The shipped eval set is a runnable contract, not just three valid PNGs. Its
# paths moved two directories deeper with the profile and must still resolve
# before a live run spends anything.
EVAL_PAIRS="$CREATIVE/eval/pairs.json"
EVAL_DIR="$(cd "$(dirname "$EVAL_PAIRS")" && pwd)"
EVAL_RUBRIC=$(jq -r .rubric "$EVAL_PAIRS")
EVAL_REFS=$(jq -r .refs "$EVAL_PAIRS")
if [ -f "$EVAL_DIR/$EVAL_RUBRIC" ]; then
  ok "eval fixture: the shipped rubric path resolves"
else
  bad "eval fixture: missing rubric at $EVAL_DIR/$EVAL_RUBRIC"
fi
if [ -d "$EVAL_DIR/$EVAL_REFS" ]; then
  ok "eval fixture: the shipped reference-board path resolves"
else
  bad "eval fixture: missing reference board at $EVAL_DIR/$EVAL_REFS"
fi

# The visual gate names its own failing step. An inherited ERR trap overwrites
# it on Bash >= 4, so the profile must build a DEBUG-only trace prelude rather
# than reusing the ordinary test gate's prelude.
PROFILE_IMPL="$PROFILE/profile.sh"
file_has "$PROFILE_IMPL" 'visual_trace_prelude="trap '\''$GATE_TRACE_WRITE'\'' DEBUG"' \
  "trace: the visual stage preserves the gate's own failing step"
file_has "$PROFILE_IMPL" 'script="$visual_trace_prelude' \
  "trace: the visual runner uses its DEBUG-only prelude"

# ---------------------------------------------------------------------------
echo "== part B: the stage inside run-task.sh =="
# ---------------------------------------------------------------------------
FHOME="$ROOT/home"; mkdir -p "$FHOME"
SRCDIR="$ROOT/src"; mkdir -p "$SRCDIR"
PROMPTS="$ROOT/prompts.log"; : > "$PROMPTS"
FIX_PROMPTS="$ROOT/fix-prompts.log"; : > "$FIX_PROMPTS"
STUB_MODE="$ROOT/stub-mode"; printf 'pass\n' > "$STUB_MODE"
STUB_CALLS="$ROOT/stub-calls.log"; : > "$STUB_CALLS"
FIX_BEHAVIOUR="$ROOT/fix-behaviour"; printf 'noop\n' > "$FIX_BEHAVIOUR"

# run-task.sh reads lib/ and profiles/ from beside itself, so the copy has to
# take them along: a $SRCDIR holding the script alone would load no profile and
# the whole of part B would pass by testing nothing.
cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp -R "$SRC/lib" "$SRC/profiles" "$SRCDIR/"
cp "$SRC/metrics.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp -R "$SRC/lib" "$HARNESS/"

cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    pixelapp|pixelapp-*)
      INSTALL_CMD=''
      GATE_CMD='true'
      VISUAL_GATE_CMD="${TEST_VISUAL_GATE_CMD:-}"
      ;;
  esac
}
EOF

# The stub VISUAL_GATE_CMD: everything the real gate leaves behind, in a
# hundredth of the time and with no browser. Part A is where the real one is
# exercised; this half is about what run-task.sh does with the result.
cat > "$ROOT/visual-stub.sh" <<EOF
#!/usr/bin/env bash
printf 'stub round %s\n' "\${VISUAL_ROUND:-?}" >> "$STUB_CALLS"
mkdir -p .harness/frames
printf 'not really a png\n' > .harness/frames/scene-f00.png
printf 'not really a png\n' > .harness/contact-sheet.png
mode=\$(cat "$STUB_MODE")
echo "=== visual gate (round \${VISUAL_ROUND:-1}) ==="
echo "checks: scene-f00.png offgrid 2% black 1%"
if [ "\$mode" = pass ]; then
  jq -n '{status:"pass",round:1,pairwise:"better",worst_axis:"composition",one_fix:"",
          champion_shots:1,critic:{axes:{composition:4},verdict:"pass"},failures:[]}' \\
    > .harness/visual-score.json
  echo "=== visual gate: PASS ==="
  exit 0
fi
jq -n '{status:"fail",round:1,pairwise:"worse",worst_axis:"composition",
        one_fix:"raise the hero tower and clear the sky above it",
        champion_shots:1,critic:{verdict:"fail"},
        failures:["the critic judges this render WORSE than the reigning champion"]}' \\
  > .harness/visual-score.json
echo "failures:"
echo "  - the critic judges this render WORSE than the reigning champion"
echo "=== visual gate: FAIL ==="
printf 'critic: pairwise worse\n' > "\${HARNESS_GATE_STEP:-/dev/null}"
exit 1
EOF
chmod +x "$ROOT/visual-stub.sh"

# Implementer, reviewer and visual fixer in one stand-in, told apart by prompt.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
printf '%s\n' "\$prompt" >> "$PROMPTS"
case "\$prompt" in
  *"visual critic"*) exit 0 ;;
  *"visual gate is failing"*)
    printf '%s\n' "\$prompt" >> "$FIX_PROMPTS"
    if [ "\$(cat "$FIX_BEHAVIOUR")" = fix ]; then
      printf 'pass\n' > "$STUB_MODE"
      printf 'the fixer touched this\n' >> render.txt
      git add -A && git commit -q -m "fix: lift the hero tower"
    fi
    exit 0 ;;
  *"reviewer stage"*)
    printf '# review\n\nEverything is sound.\n' > .harness/review-notes.md
    exit 0 ;;
esac
seq 1 30 >> impl.txt
git add -A
git commit -q -m "feat: fixture change"
EOF
chmod +x "$FAKES/claude"

cat > "$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF
chmod +x "$FAKES/curl" "$FAKES/gh"

BARE="$ROOT/origin.git"
REPO="$ROOT/pixelapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

RC=0; OUT=""; RUN=""
dispatch() {  # $1 = run id, $2 = VISUAL_GATE_CMD (may be empty), rest = env
  local ticket="$1" vcmd="$2"; shift 2
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$PROMPTS"
  env -u HARNESS_MAX_TURNS -u HARNESS_REDISPATCH \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      TEST_VISUAL_GATE_CMD="$vcmd" HARNESS_NOTIFY=0 \
      "$@" \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
result() { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }

# --- unset: the stage does not exist ----------------------------------------
# The fixture repo pins no VISUAL_GATE_CMD and carries no .creative/, so the
# profile does not load at all — which is a stronger statement than the fork's
# "the stage skipped itself": there is no stage, and no hook of any kind.
dispatch VIS-OFF ""
has_not "$OUT" "profile: visual" "off: the visual profile never loads for this repo"
check "off: no round was recorded" "$(result '.visual.rounds')" ""
check "off: and result.json carries no visual field at all" \
  "$(jq -r 'has("visual")' "$RUN/result.json")" "false"
# Spelled out rather than derived, and asserted in order: this is the promise
# that the hook layer costs a repo with no profile nothing at all, and a
# `has("visual") == false` would still pass while a hook quietly appended a key.
check "off: so its key set is the one every repo has always had" \
  "$(jq -r 'keys_unsorted | join(",")' "$RUN/result.json")" \
  "ticket,status,owner,arm,review,review_account,implementer_provider,implementer_model,implementer_effort,reviewer_model,reviewer_effort,gate,attempt,attempts_total,worktree,branch,base,pr_url,opus_head,opus_session,demo_url,gate_integrity,metrics,logs"
absent "off: and nothing was rendered" "$RUN/visual"
has_not "$OUT" "visual gate #1" "off: no stage line either"
check "off: the run ships as it always did" "$(result .status)" "ready"

# --- a passing visual gate ---------------------------------------------------
printf 'pass\n' > "$STUB_MODE"
: > "$STUB_CALLS"
dispatch VIS-PASS "bash $ROOT/visual-stub.sh"
check "pass: the gate ran exactly once" "$(grep -c 'stub round' "$STUB_CALLS" | tr -d ' ')" "1"
file_has "$RUN/timeline" "visual gate #1 (deterministic + critic)" \
  "pass: with a stage line in the words the statusline maps"
check "pass: the round ledger is one row" "$(grep -c '' "$RUN/visual-rounds.log" | tr -d ' ')" "1"
check "pass: in gate-rounds.log's own shape (round, verdict, seconds)" \
  "$(awk '{print $1, $2, ($3 ~ /^[0-9]+$/ ? "secs" : "?")}' "$RUN/visual-rounds.log")" \
  "1 pass secs"
exists "pass: the model-facing log is written like the test gate's" \
  "$ROOT/pixelapp-vis-pass/.harness/visual-latest.log"
file_has "$ROOT/pixelapp-vis-pass/.harness/visual-latest.log" "=== gate round 1 (visual) ===" \
  "pass: behind a header that says which round it is"
exists "pass: frames are harvested out of the worktree" "$RUN/visual/frames/scene-f00.png"
exists "pass: so is the sheet" "$RUN/visual/contact-sheet.png"
exists "pass: and the score" "$RUN/visual/visual-score.json"
check "pass: result.json records the verdict" "$(result '.visual.status')" "pass"
check "pass: the round count" "$(result '.visual.rounds')" "1"
check "pass: the pairwise answer" "$(result '.visual.pairwise')" "better"
check "pass: and where the score lives" "$(result '.visual.score_path')" "$RUN/visual/visual-score.json"
check "pass: the run ships" "$(result .status)" "ready"
file_has "$PROMPTS" "contact-sheet.png" \
  "pass: the reviewer is handed the sheet it cannot render for itself"
file_has "$PROMPTS" "cannot render this yourself" \
  "pass: and told why that is the only look it gets"
file_has "$RUN/pr-body.md" "## Visual gate" "pass: the PR body carries the render"
file_has "$RUN/pr-body.md" "pairwise vs champion: **better**" "pass: with the verdict in it"
file_has "$RUN/pr-body.md" "no R2 remote configured" \
  "pass: and says plainly that nothing was uploaded, rather than linking nowhere"
absent "pass: no upload was attempted" "$RUN/visual-upload.log"

# --- a failing visual gate, fixed on the second round ------------------------
printf 'fail\n' > "$STUB_MODE"
printf 'fix\n' > "$FIX_BEHAVIOUR"
: > "$STUB_CALLS"; : > "$FIX_PROMPTS"
dispatch VIS-FIX "bash $ROOT/visual-stub.sh"
check "fix: the gate ran twice — fail, fix, re-check" \
  "$(grep -c 'stub round' "$STUB_CALLS" | tr -d ' ')" "2"
file_has "$RUN/timeline" "visual fix round 1 — Claude worker (Claude sub)" \
  "fix: the fix round goes to a worker with eyes, and says so"
check "fix: one fix round, not two" \
  "$(grep -c 'The visual gate is failing' "$FIX_PROMPTS" | tr -d ' ')" "1"
FIXP=$(cat "$FIX_PROMPTS")
has "$FIXP" "raise the hero tower and clear the sky above it" \
  "fix: the prompt carries the critic's one fix"
has "$FIXP" "WORSE than the reigning champion" "fix: and the reason the gate failed"
has "$FIXP" ".harness/contact-sheet.png" "fix: with the sheet to look at"
has "$FIXP" ".harness/frames/" "fix: and the frames"
has "$FIXP" "Do NOT touch .creative/visual.conf.sh thresholds" \
  "fix: moving the bar is named as the gate-gaming it is"
check "fix: the second round passed" "$(result '.visual.status')" "pass"
check "fix: two rounds are recorded" "$(result '.visual.rounds')" "2"
check "fix: and the run ships" "$(result .status)" "ready"

# --- a failing visual gate, never fixed --------------------------------------
printf 'fail\n' > "$STUB_MODE"
printf 'noop\n' > "$FIX_BEHAVIOUR"
: > "$STUB_CALLS"; : > "$FIX_PROMPTS"
dispatch VIS-FAIL "bash $ROOT/visual-stub.sh"
check "failed: the rounds are bounded at two" \
  "$(grep -c 'stub round' "$STUB_CALLS" | tr -d ' ')" "2"
check "failed: one fix round was spent" \
  "$(grep -c 'The visual gate is failing' "$FIX_PROMPTS" | tr -d ' ')" "1"
check "failed: the run ends on the new terminal status" "$(result .status)" "visual_failed"
check "failed: with the test gate still green, which is the whole point" \
  "$(result .gate)" "pass"
check "failed: no PR" "$(result .pr_url)" ""
check "failed: and a non-zero exit" "$RC" "1"
file_has "$RUN/timeline" "done: visual_failed" "failed: the timeline says so"
check "failed: both rounds are in the ledger" \
  "$(grep -c '' "$RUN/visual-rounds.log" | tr -d ' ')" "2"
check "failed: each one recording its failing step" \
  "$(cut -f2 "$RUN/visual-rounds.log" | sort -u)" "critic: pairwise worse"
check "failed: the pairwise verdict survives into result.json" \
  "$(result '.visual.pairwise')" "worse"

# --- the review still happens on a visually failed run -----------------------
file_has "$PROMPTS" "reviewer stage" "failed: the diff is still reviewed"
check "failed: and the review is recorded" "$(result .review)" "reviewed_claude"

# --- a round budget of one ---------------------------------------------------
printf 'fail\n' > "$STUB_MODE"
: > "$STUB_CALLS"; : > "$FIX_PROMPTS"
dispatch VIS-ONE "bash $ROOT/visual-stub.sh" HARNESS_VISUAL_ROUNDS=1
check "budget: one round means one round" \
  "$(grep -c 'stub round' "$STUB_CALLS" | tr -d ' ')" "1"
check "budget: and no fix round is spent" \
  "$(grep -c 'The visual gate is failing' "$FIX_PROMPTS" | tr -d ' ')" "0"
check "budget: the run still parks at visual_failed" "$(result .status)" "visual_failed"

# Zero is not a useful round budget. Treat it like the other malformed values
# and fall back to the documented default instead of silently running once.
printf 'fail\n' > "$STUB_MODE"
: > "$STUB_CALLS"; : > "$FIX_PROMPTS"
dispatch VIS-ZERO "bash $ROOT/visual-stub.sh" HARNESS_VISUAL_ROUNDS=0
check "budget: zero falls back to the two-round default" \
  "$(grep -c 'stub round' "$STUB_CALLS" | tr -d ' ')" "2"

echo
printf 'visual gate: %d passed, %d failed%s\n' "$pass" "$fail" \
  "$( [ "$skipped" -gt 0 ] && printf ', %d SKIPPED' "$skipped" )"
[ "$fail" -eq 0 ]
