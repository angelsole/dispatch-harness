# shellcheck shell=bash
# Every var here is an output consumed by creative/visual-gate.sh, which sources
# this file; shellcheck cannot see that use from inside the fragment.
# shellcheck disable=SC2034
# The visual contract for THIS repo — the wall (Ghost Shift).
#
# Sourced by creative/visual-gate.sh with the worktree as cwd. Machinery lives
# in the harness; this file is the part that is about this project, and it is
# the only place a threshold may be tuned. (Tuning one to make a red gate green
# is gate-gaming — the visual equivalent of deleting a test.)
#
# This is the wall's home repo, so this file is what /dispatch-pixel grades a
# wall run against (the machinery lives in ~/.claude/creative-harness). The DOM
# world is the champion's world — the city the office TV shows — and
# `?world=canvas` is the WebGL challenger behind it, rendered on demand:
#
#   VISUAL_WORLD=canvas VISUAL_CRITIC=0 bash creative/visual-gate.sh
#
# A run of the gate grades the DOM city unless a human asks for the other one.

VISUAL_WORLD="${VISUAL_WORLD:-dom}"

# The wall serves itself. --port 0 lets the OS pick, so parallel runs never
# collide on a port; the gate reads the bound port back out of the server's
# first line (VISUAL_SERVER_PORT_RE, default) and substitutes it below.
# $VISUAL_TMP is the gate's scratch dir — the city ledger is per-run state and
# must never be written inside the repo.
VISUAL_SERVER_CMD='bash wall.sh --host 127.0.0.1 --port 0 --runs wall/fixtures/runs --city "$VISUAL_TMP/city.jsonl"'
VISUAL_URL='http://127.0.0.1:{port}'

# One shot, six frames: a 3x2 contact sheet of 640x360 tiles is the cheap end
# of the vision-token sweet spot, and six consecutive frames are what make the
# continuity axis answerable at all.
VISUAL_SHOTS=("wide|/?world=$VISUAL_WORLD|750")
VISUAL_FRAMES=6
VISUAL_WAIT_MS=750
VISUAL_SETTLE_MS=3000
VISUAL_WIDTH=1280
VISUAL_HEIGHT=720
VISUAL_DPR=1

# Motion, on a page whose ambience is CSS. Three settings, one decision.
#
# The wall honours prefers-reduced-motion by killing every animation and
# transition, so asking for it renders six identical tiles and then asks a
# critic to judge animation continuity — which is how the first live run of this
# gate earned a deserved 1/5 on that axis for a page that animates fine.
# animations="disabled" does the same thing from the other side, pinning CSS
# keyframes to their initial state. And the frozen clock drives requestAnimation
# Frame but not the compositor's CSS timeline, so even with both switched on the
# skyline needs real milliseconds to move in.
#
# So: motion on, captured live, with a quarter second of real time between
# frames. What that costs is exactness — two runs of this shot differ by more
# than the ~0.02 % floor — and nothing downstream compares frames for equality:
# SSIM and RMSE thresholds are what the gate judges with, and they are set wide
# enough below to tell "the city moved" from "the city broke".
VISUAL_REDUCED_MOTION=no-preference
VISUAL_ANIMATIONS=allow
VISUAL_REAL_WAIT_MS=250

# Ready means "the city is drawn", in whichever world is drawing it: a DOM
# tower, or the WebGL canvas (the rain canvas is always there and proves
# nothing). Never wait on networkidle here — the wall polls every second, so
# idle never comes.
VISUAL_READY_JS='!!document.querySelector(".tower, canvas:not(#rain)")'

# No palette lock yet — the wall is anti-aliased CSS and WebGL, not pixel art,
# so a palette LUT would fail every frame for being what it is. The palette
# check skips itself when this is empty. Same reasoning for the grid: an
# off-grid figure near 90 % is what a smooth render looks like, not a defect.
VISUAL_PALETTE=""
VISUAL_MAX_OFFPALETTE_PCT=""
VISUAL_MAX_OFFGRID_PCT=""

# What IS enforced here, and why each number is where it is. All three were
# measured on the shipped DOM wall first — a threshold no champion can pass is
# a threshold that only ever fails challengers.
#
#   pure black — the wall is a night city, so a large black share is the art
#   direction, not a bug. The shipped DOM city measures 42 %; the ceiling sits
#   above that and below "the render died and we are looking at an empty
#   canvas".
VISUAL_MAX_PURE_BLACK_PCT=60
#   legibility — the share of edge energy that survives a downscale to TV
#   size, normalised by the scale factor: 1.0 is "nothing was lost", and the
#   shipped DOM city measures 0.50-0.53 (small HUD type is what it loses). The
#   floor is set below that and well above zero: a city that only reads at 1:1
#   is a city nobody on the office TV can read.
VISUAL_MIN_LEGIBILITY=0.35
#   continuity — consecutive frames may move, but they may not cut. The wall
#   measures 0.037-0.048 with its ambience running; the ceiling is well above
#   that and far above the ~0.02 % pixel jitter a frozen clock still leaves.
VISUAL_MAX_FRAME_RMSE=0.12
#   SSIM vs the champion frame — a floor against "the render broke", not a
#   demand for sameness: the DOM and canvas worlds draw the same city with
#   different engines and still score 0.83 against each other. Well below that,
#   because a challenger is allowed to change the picture; what it may not do
#   is stop drawing one.
VISUAL_MIN_SSIM=0.30

# The frozen reference board: what the wall is supposed to look like. Three
# stills of the shipped DOM city, taken by this gate and approved by eye.
VISUAL_REFS=".creative/refs"
VISUAL_RUBRIC=".creative/rubric.md"
# On by default, and overridable from the environment so a human iterating on
# thresholds can re-render for free: VISUAL_CRITIC=0 bash creative/visual-gate.sh.
# The pipeline never sets it, so a run always pays for the opinion.
VISUAL_CRITIC="${VISUAL_CRITIC:-1}"
