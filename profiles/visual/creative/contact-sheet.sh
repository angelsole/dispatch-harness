#!/usr/bin/env bash
# One contact sheet from a run's frames — the artefact a model (and a human)
# actually looks at.
#
# Two constraints decide every number here, both measured rather than guessed:
#
#   * A 3x3 sheet of 512 px tiles is the vision-token sweet spot (3025 tokens,
#     tiles kept at full resolution). Go wider and the API downscales the whole
#     sheet, so you pay the per-image cap for progressively blurrier tiles. Six
#     frames or fewer fit a 3x2 of 640x360 at the same cost.
#   * The Read tool JPEG-recompresses any PNG over 500 KB. JPEG smears hard
#     pixel edges — exactly what palette and grid discipline are judged on — so
#     a sheet that breaches the ceiling is worse than a smaller one. This shrinks
#     until it fits: 256-colour quantisation first (edges survive it), then
#     smaller tiles.
#
# Usage: contact-sheet.sh <out.png> <frame.png>...
# Env:   SHEET_MAX_BYTES (default 500000), SHEET_BG (default #111)
set -u

READ_MAX_BYTES=500000
MAX_BYTES="${SHEET_MAX_BYTES:-$READ_MAX_BYTES}"
BG="${SHEET_BG:-#111}"

case "$MAX_BYTES" in
  ''|*[!0-9]*|0)
    echo "contact-sheet.sh: SHEET_MAX_BYTES must be a positive integer" >&2
    exit 2
    ;;
esac
# The environment may tighten the budget for a test or a stricter consumer,
# but it may not opt out of the Read tool's hard recompression boundary.
[ "$MAX_BYTES" -le "$READ_MAX_BYTES" ] || MAX_BYTES=$READ_MAX_BYTES

[ $# -ge 2 ] || { echo "usage: contact-sheet.sh <out.png> <frame.png>..." >&2; exit 2; }
OUT="$1"; shift

command -v magick >/dev/null 2>&1 || {
  echo "contact-sheet.sh: ImageMagick (magick) is required — brew install imagemagick" >&2
  exit 2
}

N=$#
if [ "$N" -le 6 ]; then
  TILE=3x2
elif [ "$N" -le 9 ]; then
  TILE=3x3
else
  # A fixed row count makes ImageMagick paginate into out-0.png, out-1.png,
  # leaving the requested OUT path missing. Keep one three-column sheet for a
  # larger shot list; the progressively smaller geometries below still enforce
  # the Read tool's byte ceiling.
  TILE=3x
fi

# Tile widths to try, largest first. The label strip under each tile is what
# lets a critic say WHICH frame it is talking about.
# -label and its typography go BEFORE the frames: ImageMagick settings apply to
# the images that FOLLOW them, so the obvious order silently produces an
# unlabelled sheet — and an unlabelled sheet makes the critic's "name the tile"
# instruction unanswerable.
montage_at() {  # $1 = tile geometry, rest = the frames
  local geom="$1"; shift
  magick montage -background "$BG" -fill '#9aa' ${FONT_ARGS[@]+"${FONT_ARGS[@]}"} -pointsize 13 -label '%t' \
    "$@" -tile "$TILE" -geometry "$geom+4+4" "$OUT" 2>/dev/null
}

size_of() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

# The tile labels need a font ImageMagick can actually open. A build without
# the fontconfig delegate (Homebrew's on a fresh Mac, for one) lists no fonts
# and `-label` then fails on every geometry with "unable to read font `'" —
# and the gate reports the sheet as over the byte ceiling, which it is not.
# SHEET_FONT names a file to use; otherwise the first system face found is
# passed explicitly, and a machine that lists fonts keeps its default.
FONT_ARGS=()
if [ -n "${SHEET_FONT:-}" ]; then
  FONT_ARGS=(-font "$SHEET_FONT")
elif ! magick -list font 2>/dev/null | grep -q '^ *Font:'; then
  for f in /System/Library/Fonts/Supplemental/Arial.ttf /System/Library/Fonts/Monaco.ttf \
           /System/Library/Fonts/Helvetica.ttc /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
           /usr/share/fonts/dejavu/DejaVuSans.ttf; do
    [ -r "$f" ] && { FONT_ARGS=(-font "$f"); break; }
  done
fi

if [ "$N" -le 6 ]; then
  STEPS="640x360 512x288 384x216 320x180 256x144 192x108"
else
  STEPS="512x512 384x384 320x320 256x256 192x192 128x128"
fi

for geom in $STEPS; do
  montage_at "$geom" "$@" || continue
  [ -f "$OUT" ] || continue
  bytes=$(size_of "$OUT")
  [ -n "$bytes" ] || continue
  if [ "$bytes" -le "$MAX_BYTES" ]; then
    echo "contact sheet: $OUT ${bytes}B (${TILE} of $geom, $N frames)"
    exit 0
  fi
  # Palette quantisation before geometry: 256 colours keeps hard edges hard,
  # which a downscale does not.
  magick "$OUT" -colors 256 "PNG8:$OUT" 2>/dev/null || true
  bytes=$(size_of "$OUT")
  if [ -n "$bytes" ] && [ "$bytes" -le "$MAX_BYTES" ]; then
    echo "contact sheet: $OUT ${bytes}B (${TILE} of $geom, $N frames, 256 colours)"
    exit 0
  fi
done

if [ -f "$OUT" ]; then
  echo "contact-sheet.sh: $OUT is $(size_of "$OUT")B after every size/quantisation attempt — over the ${MAX_BYTES}B ceiling" >&2
  exit 1
fi
echo "contact-sheet.sh: montage produced nothing for $N frame(s)" >&2
exit 1
