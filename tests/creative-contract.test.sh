#!/usr/bin/env bash
# The wall's visual contract, as a test: `.creative/` is what the creative
# harness grades a render of this repo against, and a contract with a file
# missing — or a threshold that stopped being a number — is a gate that quietly
# stops enforcing something. Nothing here judges the picture; it pins that the
# contract is complete and loadable off this checkout.
#
# Read-only: sources visual.conf.sh in a subshell with a temp VISUAL_TMP, the
# way creative/visual-gate.sh does, and writes nothing.
#
# Usage: bash tests/creative-contract.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
CREATIVE="$SRC/.creative"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/creative-contract-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

echo "== contract: every file the gate reads is here =="
for f in visual.conf.sh rubric.md bible.md palette.png proportions.md assets.json \
         refs; do
  if [ -e "$CREATIVE/$f" ]; then ok "contract: .creative/$f"; else bad "contract: .creative/$f is missing"; fi
done

echo "== contract: visual.conf.sh loads and answers the gate =="
if bash -n "$CREATIVE/visual.conf.sh" 2>/dev/null; then ok "conf: parses"; else bad "conf: parses"; fi
# Sourced exactly as visual-gate.sh sources it, and dumped as name=value so a
# broken fragment fails here rather than mid-render.
CONF="$(VISUAL_TMP="$TMP" bash -c '. "$1" || exit 1
  for v in VISUAL_SERVER_CMD VISUAL_URL VISUAL_READY_JS VISUAL_REFS VISUAL_RUBRIC \
           VISUAL_MAX_PURE_BLACK_PCT VISUAL_MIN_LEGIBILITY VISUAL_MAX_FRAME_RMSE \
           VISUAL_MIN_SSIM; do printf "%s=%s\n" "$v" "${!v-}"; done
  printf "VISUAL_SHOTS=%s\n" "${VISUAL_SHOTS[*]-}"' _ "$CREATIVE/visual.conf.sh" 2>&1)"
val() { printf '%s\n' "$CONF" | sed -n "s/^$1=//p"; }
for v in VISUAL_SERVER_CMD VISUAL_URL VISUAL_SHOTS VISUAL_READY_JS VISUAL_REFS VISUAL_RUBRIC; do
  if [ -n "$(val "$v")" ]; then ok "conf: $v is set"; else bad "conf: $v is empty ($CONF)"; fi
done
# A threshold that is not a number is not enforced — the check reads it as unset
# and reports instead of failing, which is a gate with a hole in it.
for v in VISUAL_MAX_PURE_BLACK_PCT VISUAL_MIN_LEGIBILITY VISUAL_MAX_FRAME_RMSE VISUAL_MIN_SSIM; do
  case "$(val "$v")" in
    ''|*[!0-9.]*|*.*.*) bad "conf: $v is a number (got [$(val "$v")])" ;;
    *) ok "conf: $v is a number" ;;
  esac
done

echo "== contract: the board and the palette lock =="
REFS=$(find "$CREATIVE/refs" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
if [ "$REFS" -ge 3 ]; then ok "refs: the board carries $REFS frames"; else bad "refs: the board carries $REFS frames, want 3 or more"; fi
# PNG dimensions off the IHDR: portable where sips(1) is not (the CI runner).
check "palette: palette.png is 32 colours in one row" \
  "$(python3 -c 'import struct,sys
d=open(sys.argv[1],"rb").read(24)
print("%dx%d" % struct.unpack(">II", d[16:24]))' "$CREATIVE/palette.png" 2>/dev/null)" "32x1"

echo
printf 'creative contract: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
