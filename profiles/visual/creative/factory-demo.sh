#!/usr/bin/env bash
# The factory end to end, in one command: generate, post-pass, and produce the
# one artefact a person actually judges the run by — a contact sheet of every
# asset, nearest-neighbour upscaled so 16 px of art is visible on a screen.
#
# Re-running is free. factory.py caches on the request body, so the second run
# of this script makes zero vendor calls and reproduces byte-identical output;
# that is what makes it safe to put in a README and in a demo.
#
# Usage: factory-demo.sh [options]
#   --assets FILE   asset list           (default .creative/assets.json)
#   --palette PNG   palette LUT          (default .creative/palette.png)
#   --out DIR       working dir          (default .harness/factory)
#   --atlas NAME    atlas basename       (default wall-demo)
#   --sheet PNG     contact sheet        (default .harness/asset-sheet.png)
#   --publish DIR   copy the small outputs here for committing (default: none)
#   --scale N       nearest upscale for the sheet (default 8)
#   --dry-run       price the run, call nothing
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "$HERE/../../../lib/common.sh"
ASSETS=".creative/assets.json"
PALETTE=".creative/palette.png"
OUT=".harness/factory"
ATLAS="wall-demo"
SHEET=".harness/asset-sheet.png"
PUBLISH=""
SCALE=8
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --assets)  ASSETS="$2"; shift 2 ;;
    --palette) PALETTE="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    --atlas)   ATLAS="$2"; shift 2 ;;
    --sheet)   SHEET="$2"; shift 2 ;;
    --publish) PUBLISH="$2"; shift 2 ;;
    --scale)   SCALE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) harness_usage "$0"; exit 0 ;;
    *) echo "factory-demo.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

PY="${FACTORY_PYTHON:-python3}"

if [ -n "$PUBLISH" ]; then
  # --publish replaces its destination wholesale below. Resolve symlinks and
  # require a strict child of the working tree before allowing that recursive
  # removal; the intended target is `.creative/demo`, never a repo or /tmp.
  PUBLISH="$("$PY" - "$PWD" "$PUBLISH" <<'PY'
import os
import sys

root, target = map(os.path.realpath, sys.argv[1:])
if target == root or os.path.commonpath((root, target)) != root:
    raise SystemExit(1)
print(target)
PY
)" || {
    echo "factory-demo.sh: --publish must be a child of the current working tree" >&2
    exit 2
  }
fi

if [ "$DRY" = 1 ]; then
  exec "$PY" "$HERE/factory.py" gen --assets "$ASSETS" --out "$OUT" \
    --palette "$PALETTE" --dry-run
fi

echo "== balance before =="
"$PY" "$HERE/factory.py" balance || exit 1

echo "== generate =="
"$PY" "$HERE/factory.py" gen --assets "$ASSETS" --out "$OUT" --palette "$PALETTE" \
  || exit 1

echo "== post-pass =="
# Deliberately NOT `|| exit 1`: a failing asset must still leave the report and
# the sheet behind, because the report is how anybody finds out WHICH asset
# failed and the sheet is how they see why. The exit status is carried to the
# end instead.
"$PY" "$HERE/postpass.py" --in "$OUT/raw" --out "$OUT/out" --palette "$PALETTE" \
  --atlas "$ATLAS" --report "$OUT/report.json"
STATUS=$?

echo "== contact sheet =="
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-sheet.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# The upscale is the whole point of this step: at 1:1 a 16 px tile is a speck
# on a review page, and the sheet exists to be looked at. NEAREST only —
# anything else smears the hard edges the post-pass just guaranteed. The file
# name becomes the montage label, so it has to stay the asset id.
"$PY" - "$OUT/out" "$TMP" "$SCALE" "$ATLAS" <<'PY' || exit 1
import os
import sys

from PIL import Image

src, dst, scale, atlas = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
skip = atlas + ".png"
names = sorted(f for f in os.listdir(src)
               if f.lower().endswith(".png") and f != skip)
for name in names:
    im = Image.open(os.path.join(src, name)).convert("RGBA")
    im.resize((im.width * scale, im.height * scale), Image.Resampling.NEAREST) \
      .save(os.path.join(dst, name))
print("upscaled %d asset(s) x%d" % (len(names), scale))
PY

SHEET_DIR="$(dirname "$SHEET")"
mkdir -p "$SHEET_DIR"
SHEET_INPUTS=("$TMP"/*.png)
if [ -e "${SHEET_INPUTS[0]}" ]; then
  bash "$HERE/contact-sheet.sh" "$SHEET" "${SHEET_INPUTS[@]}" || exit 1
else
  rm -f "$SHEET"
  echo "contact sheet SKIP — no assets passed the post-pass"
fi

if [ -n "$PUBLISH" ]; then
  echo "== publish =="
  rm -rf "$PUBLISH"
  mkdir -p "$PUBLISH"
  cp -R "$OUT/raw" "$PUBLISH/raw"
  cp -R "$OUT/out" "$PUBLISH/out"
  [ ! -f "$OUT/manifest.json" ] || cp "$OUT/manifest.json" "$PUBLISH/manifest.json"
  if [ -f "$OUT/report.json" ]; then
    "$PY" - "$OUT/report.json" "$PUBLISH/report.json" <<'PY'
import json
import os
import sys

report = json.load(open(sys.argv[1]))
if report.get("atlas"):
    for key in ("image", "json"):
        report["atlas"][key] = "out/" + os.path.basename(report["atlas"][key])
with open(sys.argv[2], "w") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  fi
  cp "$SHEET" "$PUBLISH/asset-sheet.png" 2>/dev/null || true
  echo "published: $PUBLISH ($(du -sh "$PUBLISH" | cut -f1))"
fi

echo "== balance after =="
"$PY" "$HERE/factory.py" balance || true
exit $STATUS
