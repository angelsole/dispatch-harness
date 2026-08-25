# shellcheck shell=bash
# Every var here is an output consumed by creative/visual-gate.sh, which sources
# this file; shellcheck cannot see that use from inside the fragment.
# shellcheck disable=SC2034
# EXAMPLE visual contract for an app frontend — a Flutter web build.
#
# Copy to `.creative/visual.conf.sh` in the target repo and edit. Sourced by
# profiles/visual/creative/visual-gate.sh with the worktree as cwd. This file is
# the part that is about the project; the machinery is in the harness.
#
# For pixel art, start from the annotated contract in dispatch-harness's own
# `.creative/visual.conf.sh` instead. The difference is one line — VISUAL_KIND —
# and everything below follows from it.

# `ui` instead of `pixel`. It changes four defaults and nothing else: a real
# clock, two frames per shot rather than six, the app-UI rubric
# (profiles/visual/creative/rubric-ui.md) when this repo ships no
# `.creative/rubric.md`, and the six app-UI axes. Every one of them is still
# overridable here, one line at a time.
VISUAL_KIND=ui

# --- serving the build -------------------------------------------------------
# The gate reads the port back out of the server's own output, so whatever
# command goes here MUST print a URL containing a port that
# VISUAL_SERVER_PORT_RE matches (default `http://[^:]*:([0-9]+)`). Nothing else
# tells the gate where the app is.
#
# `flutter run -d web-server` prints such a line, but it also compiles inside
# the run, which is what VISUAL_SERVER_TIMEOUT below is sized for. A release
# build served by a static server is the faster and steadier shape when CI
# already has the build:
#
#   VISUAL_SERVER_CMD='flutter build web --release >&2 && cd build/web && python3 -m http.server 0 --bind 127.0.0.1'
#
# — with the caveat that `python3 -m http.server` prints `(http://0.0.0.0:PORT/)`,
# so match it with VISUAL_SERVER_PORT_RE below rather than assuming the default.
VISUAL_SERVER_CMD='flutter run -d web-server --web-hostname 127.0.0.1 --web-port 0 --release'
VISUAL_SERVER_PORT_RE='http://[^:]*:([0-9]+)'
VISUAL_URL='http://127.0.0.1:{port}'
# A cold `flutter run` compiles the whole app before it says a word. Thirty
# seconds is the default and it is not enough; a server that never prints a port
# fails the round with nothing rendered.
VISUAL_SERVER_TIMEOUT=300

# --- what to photograph ------------------------------------------------------
# name|url-suffix|wait-ms. Route suffixes for a Flutter app using the URL
# strategy; drop them for a single-screen app.
VISUAL_SHOTS=("home|/|300" "settings|/#/settings|300")
VISUAL_WIDTH=1440
VISUAL_HEIGHT=900
VISUAL_DPR=1
VISUAL_COLOR_SCHEME=light

# --- waiting for the engine --------------------------------------------------
# Flutter web announces its first painted frame by dispatching a one-shot window
# event. By the time anything outside the page could poll for a flag the event
# has already come and gone, so the gate installs the listener before any page
# script runs and waits on that. Composable with VISUAL_READY_JS if the screen
# you want needs more than "the engine is up" — both must become true.
VISUAL_READY_EVENT=flutter-first-frame
VISUAL_READY_JS=""

# Two Flutter gotchas, both of them here:
#
#   1. CanvasKit needs WebGL, and headless Chromium has no GPU. The gate always
#      launches with --use-angle=swiftshader --enable-unsafe-swiftshader, which
#      is what makes CanvasKit come up at all — nothing to set, but if a render
#      comes back blank, that pair is the first thing to check in frames.py.
#   2. A real clock. `frozen` pins the page's Date to a fixed epoch, and an
#      engine that is timing its own boot against the wall clock, loading fonts
#      and instantiating WASM has no reason to enjoy that. `ui` defaults to
#      `real`, which is what the line below states out loud; --settle-ms and
#      --wait-ms then spend real milliseconds instead of fake ones.
VISUAL_CLOCK=real
# Real milliseconds, counted from the moment the app reports ready: enough for
# the first route's animations to land and for images to arrive.
VISUAL_SETTLE_MS=2000
VISUAL_WAIT_MS=300
# Two frames per shot is the `ui` default. Continuity across six frames of a
# mostly static screen measures nothing and costs six screenshots.
VISUAL_FRAMES=2

# --- the checks --------------------------------------------------------------
# An app frontend is anti-aliased by construction, so the pixel-art checks are
# measured and reported but NOT enforced: leave the palette and grid thresholds
# empty. A threshold you do not set is the honest default.
VISUAL_PALETTE=""
VISUAL_MAX_OFFPALETTE_PCT=""
VISUAL_MAX_OFFGRID_PCT=""
# What is worth enforcing on a UI. Measure the reigning render first and set the
# numbers around what it actually scores — a threshold the champion cannot pass
# only ever fails challengers.
#   pure black — a white-background app that suddenly measures 40 % black did
#   not render. On a dark-theme app this ceiling has to go up.
VISUAL_MAX_PURE_BLACK_PCT=10
#   legibility — the share of edge energy that survives a downscale. Small UI
#   type is what it loses, so measure before you set it.
VISUAL_MIN_LEGIBILITY=""
#   continuity — a static screen barely moves between frames; a screen still
#   animating when it was photographed does. Set it after a first run.
VISUAL_MAX_FRAME_RMSE=""
#   SSIM vs the champion frame — a floor against "the app stopped drawing",
#   not a demand for sameness.
VISUAL_MIN_SSIM=0.30

# --- the critic --------------------------------------------------------------
# The axes and the rubric travel together: if you set VISUAL_AXES, point
# VISUAL_RUBRIC at a rubric whose table names the same axes. Both are commented
# out here, which takes the `ui` defaults — the six axes in
# profiles/visual/creative/rubric-ui.md, graded against that rubric.
# VISUAL_AXES="layout_integrity,typography,spacing_alignment,color_contrast,visual_hierarchy,polish"
VISUAL_RUBRIC=".creative/rubric.md"
# A frozen reference board of what the app is supposed to look like — screens a
# human approved. Optional, and the single biggest lever on whether the critic's
# answers agree with yours.
VISUAL_REFS=".creative/refs"
# Don't pay for an opinion on a render that cannot have changed: when every
# shot's first frame scores at least this SSIM against its champion frame, the
# gate records `tie` and skips the two critic calls.
VISUAL_UNCHANGED_SSIM=0.995
# On by default, overridable from the environment so a human iterating on
# thresholds can re-render for free: VISUAL_CRITIC=0 bash …/visual-gate.sh
VISUAL_CRITIC="${VISUAL_CRITIC:-1}"
