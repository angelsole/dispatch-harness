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
for f in wall/server.js wall/wall.js wall/scene.js wall/world-canvas.js wall/room.js \
         wall/fixtures/seed.js wall/fixtures/city.js; do
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
# --- provenance ----------------------------------------------------------------
# The doctrine used to be "the city is drawn, not loaded" and the test for it was
# a ban on binaries. It is now "nothing the wall needs leaves this machine": the
# page may ship committed, licensed, manifest-listed assets — it vendors a WebGL
# engine — but every byte it can load has to be in this repo and accounted for.
# So the binary ban is retired on purpose, and three checks replace it: the
# authored files reach nowhere off-origin, everything the page can load resolves
# to a real file this server serves, and everything under wall/vendor/ has a
# THIRD_PARTY.md row whose hash still matches.
PAGE_SRC="$(cat "$SRC/wall/index.html" "$SRC/wall/wall.css" "$SRC/wall/wall.js" \
  "$SRC/wall/scene.js" "$SRC/wall/world-canvas.js" "$SRC/wall/room.js")"
CSS_SRC="$(cat "$SRC/wall/wall.css")"
# The AUTHORED page files only: the vendored bundle carries its upstream in its
# own banner and is pinned by hash rather than by this grep. XML namespace URIs
# (w3.org) are identifiers, never fetched.
OFFSITE="$(printf '%s' "$PAGE_SRC" | grep -oE 'https?://[A-Za-z0-9./_-]+' \
  | grep -v '^https\{0,1\}://www\.w3\.org/' | sort -u | tr '\n' ' ')"
if [ -z "$OFFSITE" ]; then
  ok "assets: no off-origin URLs in anything the page authors"
else
  bad "assets: off-origin URLs in the page: $OFFSITE"
fi
# Everything under wall/vendor/ that is not documentation is third-party code,
# and the manifest is the pin: a swapped bundle fails here rather than shipping.
VENDOR_CHECK="$(node -e '
  const fs = require("fs"), path = require("path"), crypto = require("crypto");
  const dir = path.join(process.argv[1], "wall", "vendor");
  const manifest = fs.readFileSync(path.join(process.argv[1], "wall", "THIRD_PARTY.md"), "utf8");
  const bad = [];
  let listed = 0;
  for (const name of fs.readdirSync(dir).sort()) {
    if (name.endsWith(".md")) continue;
    const sum = crypto.createHash("sha256")
      .update(fs.readFileSync(path.join(dir, name))).digest("hex");
    const row = manifest.split("\n").find((line) =>
      line.includes("wall/vendor/" + name) && line.startsWith("|"));
    if (!row) bad.push(name + ": no THIRD_PARTY.md row");
    else if (!row.includes(sum)) bad.push(name + ": sha256 " + sum + " is not in its row");
    else listed++;
  }
  process.stdout.write(bad.length ? bad.join("; ") : "ok:" + listed);
' "$SRC" 2>&1)"
case "$VENDOR_CHECK" in
  ok:0) bad "assets: wall/vendor/ carries at least one manifest-listed file" ;;
  ok:*) ok  "assets: every vendored file has a THIRD_PARTY.md row whose sha256 matches" ;;
  *)    bad "assets: vendored files disagree with THIRD_PARTY.md ($VENDOR_CHECK)" ;;
esac
# And the bundle the doctrine names is the build the manifest names.
PHASER_SUM="$(node -e '
  const fs = require("fs"), crypto = require("crypto");
  process.stdout.write(crypto.createHash("sha256")
    .update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$SRC/wall/vendor/phaser.min.js" 2>/dev/null)"
check "assets: the vendored engine is the pinned Phaser 4.2.1 build" \
  "$PHASER_SUM" "66348b1b5141e49b7d5ebbe688cddcb502eab1cb00f21c538686a5b2c5abe4de"
if [ -f "$SRC/wall/vendor/PHASER-LICENSE.md" ]; then
  ok "assets: its licence travels beside it"
else
  bad "assets: its licence travels beside it"
fi
grep_ok "$(cat "$SRC/.gitattributes")" 'wall/vendor/** -diff linguist-vendored' \
  "assets: the vendored bundle reads as a blob, not as a 1.4 MB diff"

# The room's sprites are the other half of the same doctrine. They were not
# written by somebody else — they were generated for this repo, by tools this
# machine drives — so they get their own manifest rather than a THIRD_PARTY.md
# row, pinned by the same idea: every committed file has a row, every row
# carries the hash it was committed at, and a sprite that changes without its
# row changing fails here rather than shipping.
ASSET_CHECK="$(node -e '
  const fs = require("fs"), path = require("path"), crypto = require("crypto");
  const dir = path.join(process.argv[1], "wall", "assets");
  const manifest = fs.readFileSync(path.join(dir, "MANIFEST.md"), "utf8").split("\n");
  const bad = [];
  let listed = 0;
  const walk = (at) => {
    for (const name of fs.readdirSync(at).sort()) {
      const full = path.join(at, name);
      if (fs.statSync(full).isDirectory()) { walk(full); continue; }
      if (name.endsWith(".md")) continue;
      const rel = path.relative(dir, full).split(path.sep).join("/");
      const sum = crypto.createHash("sha256").update(fs.readFileSync(full)).digest("hex");
      const row = manifest.find((line) => line.startsWith("|") && line.includes("`" + rel + "`"));
      if (!row) bad.push(rel + ": no MANIFEST.md row");
      else if (!row.includes(sum)) bad.push(rel + ": sha256 " + sum + " is not in its row");
      else listed++;
    }
  };
  walk(dir);
  process.stdout.write(bad.length ? bad.join("; ") : "ok:" + listed);
' "$SRC" 2>&1)"
case "$ASSET_CHECK" in
  ok:0) bad "assets: wall/assets/ carries at least one manifest-listed file" ;;
  ok:*) ok  "assets: every committed sprite has a MANIFEST.md row whose sha256 matches" ;;
  *)    bad "assets: committed sprites disagree with MANIFEST.md ($ASSET_CHECK)" ;;
esac

# Two claims about the committed sprites are made from the pixels rather than from
# a manifest column, and both want a PNG reader. It is written out of node's own
# zlib — this wall has no dependencies and is not about to grow one for a test —
# and it lives in one file that both checks require, because two copies of a
# Paeth filter in one suite is one copy too many.
PNG_JS="$ROOT/png.js"
cat > "$PNG_JS" <<'JS'
// 8-bit truecolour PNGs only, with or without alpha, which is what the post-pass
// writes and what the palette itself is.
const zlib = require("zlib");

function decode(buf) {
  const w = buf.readUInt32BE(16), h = buf.readUInt32BE(20);
  const depth = buf[24], type = buf[25];
  if (depth !== 8 || (type !== 2 && type !== 6)) throw new Error("png " + depth + "/" + type);
  const parts = [];
  for (let at = 8; at + 8 <= buf.length;) {
    const len = buf.readUInt32BE(at);
    if (buf.toString("ascii", at + 4, at + 8) === "IDAT") parts.push(buf.subarray(at + 8, at + 8 + len));
    at += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(parts));
  const bpp = type === 6 ? 4 : 3, stride = w * bpp;
  const out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const filter = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[y * stride + x - bpp] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? out[(y - 1) * stride + x - bpp] : 0;
      let v = raw[y * (stride + 1) + 1 + x];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[y * stride + x] = v & 255;
    }
  }
  return { w, h, bpp, px: out };
}

// Opaque or not, at a pixel. A sprite with no alpha channel is opaque
// everywhere; the post-pass writes binary alpha, so 128 is a cut and not a
// threshold anybody has to tune.
const opaque = (img, x, y) =>
  (img.bpp === 3 ? true : img.px[(y * img.w + x) * img.bpp + 3] >= 128);

// The opaque bounding box of a band of rows, as [x, y, w, h], or null.
function bounds(img, from, to) {
  let x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1;
  for (let y = Math.max(0, from); y < Math.min(img.h, to); y++) {
    for (let x = 0; x < img.w; x++) {
      if (!opaque(img, x, y)) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return x1 < 0 ? null : [x0, y0, x1 - x0 + 1, y1 - y0 + 1];
}

module.exports = { decode, opaque, bounds };
JS

# And the palette is a lock, not a suggestion: every pixel of every sprite is
# one of the 32 in .creative/palette.png, and the room draws with that same 32
# rather than a copy that has drifted from it. Both claims are checked against
# the real files.
PALETTE_CHECK="$(node -e '
  const fs = require("fs"), path = require("path");
  const { decode } = require(process.argv[2]);
  const hex = (r, g, b) => "#" + [r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("");
  const root = process.argv[1];
  const lockPng = decode(fs.readFileSync(path.join(root, ".creative", "palette.png")));
  const lock = new Set();
  for (let i = 0; i < lockPng.w * lockPng.h; i++) {
    lock.add(hex(lockPng.px[i * lockPng.bpp], lockPng.px[i * lockPng.bpp + 1], lockPng.px[i * lockPng.bpp + 2]));
  }
  const room = require(path.join(root, "wall", "room.js"));
  const bad = [];
  if (room.LOCK.length !== lock.size || room.LOCK.some((c) => !lock.has(c))) {
    bad.push("room.js draws with a palette that is not the lock");
  }
  // Being ON the lock is not enough. Green is a WORD in this palette — it means
  // shipped — so the success ramp belongs to a run that finished and to nothing
  // else. A potted plant wearing it, or one stray emerald pixel a quantiser
  // chose in the middle of a lamp bulb, is the palette telling the room a lie.
  const SHIPPED = ["#3fd984", "#4ff08f", "#2c9a61", "#9fe8b8"];
  // Every sprite under wall/assets, whichever set it belongs to: the room grew
  // a crew directory and a check that only ever walked room/ would have let
  // three new characters in without asking them the palette question at all.
  const dir = path.join(root, "wall", "assets");
  const sprites = [];
  const walk = (at) => {
    for (const name of fs.readdirSync(at).sort()) {
      const full = path.join(at, name);
      if (fs.statSync(full).isDirectory()) walk(full);
      else if (name.endsWith(".png")) sprites.push(full);
    }
  };
  walk(dir);
  for (const full of sprites) {
    const name = path.relative(dir, full).split(path.sep).join("/");
    const img = decode(fs.readFileSync(full));
    const stray = new Set();
    const shipped = new Set();
    for (let i = 0; i < img.w * img.h; i++) {
      const at = i * img.bpp;
      if (img.bpp === 4 && img.px[at + 3] === 0) continue;   // transparent is no colour
      const c = hex(img.px[at], img.px[at + 1], img.px[at + 2]);
      if (!lock.has(c)) stray.add(c);
      if (SHIPPED.includes(c)) shipped.add(c);
    }
    if (stray.size) bad.push(name + ": " + [...stray].join(","));
    if (shipped.size) bad.push(name + " wears the shipped ramp: " + [...shipped].join(","));
  }
  process.stdout.write(bad.length ? bad.join("; ") : "ok:" + lock.size);
' "$SRC" "$PNG_JS" 2>&1)"
check "assets: every sprite is quantised to the 32-colour lock, and so is the room" \
  "$PALETTE_CHECK" "ok:32"

# The POSE LOCK, from the pixels. A character set is only interchangeable with
# another if every frame of it lands in the same box, and "the manifest says so"
# is not a check — so this measures the committed PNGs, through room.js's own
# splits and frame names, and fails on the numbers.
#
# Two bounds, because the room draws a figure in two bands and only one of them
# comes from a generated frame:
#
#   (a) the DRAWN composite — the base's rows above the set's split plus the
#       frame's rows at and below it, which is the figure that goes on the wall —
#       within +/-1 px of the set's base box. This is the one that decides whether
#       a set can sit at the room's worker origin.
#   (b) the ANIMATED BAND on its own — x, width and bottom edge of the rows at and
#       below the split — within +/-3 px of the base's same rows. Without this,
#       (a) would pass a frame whose arms had floated off the keyboard, because the
#       base's head would still be setting the top of the box.
#
# The rows a frame carries ABOVE the split are not measured, because the room
# discards them: every generated frame redraws the whole figure, and their drift
# is a fact about the animator rather than about the picture. The raw numbers are
# in the run notes.
#
# What this does NOT check is which rows came from where — a bounding box cannot
# see that, and on these sprites the box happens to be the same whichever side of
# the split the shoulders come from. That claim is `headAlwaysBase` further down,
# over the room's own band table, and `splitsSane`, which refuses a split outside
# the jacket. Three probes, three claims; none of them stands in for another.
LOCK_PROBE="$ROOT/lock-probe.js"
cat > "$LOCK_PROBE" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const R = require(path.join(root, "wall", "room.js"));
const { decode, opaque, bounds } = require(process.argv[3]);

const png = (rel) => decode(fs.readFileSync(path.join(root, "wall", rel)));
const near = (a, b, tol) => Math.abs(a - b) <= tol;

// The figure the room draws: base above the split, frame at and below it. Built
// the same way worker() builds it — the band is CLEARED and then taken from the
// frame, so a base pixel cannot show through a frame's transparent one.
function composite(base, frame, split) {
  const out = { w: base.w, h: base.h, bpp: 4, px: Buffer.alloc(base.w * base.h * 4) };
  for (let y = 0; y < base.h; y++) {
    const src = y < split ? base : frame;
    for (let x = 0; x < base.w; x++) {
      out.px[(y * out.w + x) * 4 + 3] = opaque(src, x, y) ? 255 : 0;
    }
  }
  return out;
}

// Every set the roster names, plus the one every unknown owner falls back to —
// which is exactly the list the room loads.
const crew = JSON.parse(fs.readFileSync(path.join(root, "wall", "crew.json"), "utf8"));
const sets = [...new Set(Object.keys(crew)
  .map((owner) => R.setOf(crew, owner))
  .concat(R.FALLBACK))].sort();

const cycles = R.TYPE_SET.concat(R.WAIT_SET);
const bad = [];
let drawnWorst = 0;
let bandWorst = 0;
let counted = 0;
// Per set as well as overall. One set at the ceiling hides every other set
// behind it: `crew/angel` was regenerated at 0 px on both bounds and a re-roll
// that quietly costs it four should fail here rather than pass on Ran's two.
const perSet = {};

for (const set of sets) {
  const split = R.splitOf(set);
  perSet[set] = [0, 0];
  const base = png(R.fileOf(set, "base"));
  const box = bounds(base, 0, base.h);
  const bandBox = bounds(base, split, base.h);
  if (!box || !bandBox) { bad.push(set + ": base has no opaque pixels"); continue; }
  for (const frame of cycles) {
    const img = png(R.fileOf(set, frame));
    if (img.w !== base.w || img.h !== base.h) {
      bad.push(set + "/" + frame + ": " + img.w + "x" + img.h + " is not the base's canvas");
      continue;
    }
    counted++;
    const drawn = bounds(composite(base, img, split), 0, base.h);
    const band = bounds(img, split, img.h);
    if (!drawn || !band) { bad.push(set + "/" + frame + ": nothing opaque"); continue; }
    // (a) the whole drawn figure, all four numbers.
    for (let i = 0; i < 4; i++) {
      drawnWorst = Math.max(drawnWorst, Math.abs(drawn[i] - box[i]));
      perSet[set][0] = Math.max(perSet[set][0], Math.abs(drawn[i] - box[i]));
    }
    if (!drawn.every((v, i) => near(v, box[i], 1))) {
      bad.push(set + "/" + frame + ": drawn " + drawn.join(",") + " vs base " + box.join(","));
    }
    // (b) the animated band: x, width, and where the bottom edge lands. The
    // band's own TOP is the split by construction, so it says nothing.
    const got = [band[0], band[2], band[1] + band[3]];
    const want = [bandBox[0], bandBox[2], bandBox[1] + bandBox[3]];
    for (let i = 0; i < 3; i++) {
      bandWorst = Math.max(bandWorst, Math.abs(got[i] - want[i]));
      perSet[set][1] = Math.max(perSet[set][1], Math.abs(got[i] - want[i]));
    }
    if (!got.every((v, i) => near(v, want[i], 3))) {
      bad.push(set + "/" + frame + ": band x/w/bottom " + got.join(",") + " vs base " + want.join(","));
    }
  }
}

console.log(JSON.stringify({
  sets: sets.join(" "),
  splits: sets.map((s) => s + "=" + R.splitOf(s)).join(" "),
  frames: counted,
  drawnWorst,
  bandWorst,
  perSet: sets.map((s) => s + "=" + perSet[s][0] + "/" + perSet[s][1]).join(" "),
  bad: bad.join("; "),
}));
JS
LOCK="$(node "$LOCK_PROBE" "$SRC" "$PNG_JS" 2>&1)"
lock_of() { printf '%s' "$LOCK" | jq -r ".$1" 2>/dev/null; }
check "lock: every frame of every set was measured" "$(lock_of frames)" "64"
check "lock: and every one is a set the room will actually draw" \
  "$(lock_of sets)" "crew/angel crew/emre crew/ran room"
check "lock: nothing is out of tolerance" "$(lock_of bad)" ""
if [ "$(lock_of drawnWorst)" -le 1 ] 2>/dev/null; then
  ok "lock: the drawn figure is its base's box to $(lock_of drawnWorst) px (ceiling 1)"
else
  bad "lock: the drawn figure is off its base's box by $(lock_of drawnWorst) px (ceiling 1)"
fi
if [ "$(lock_of bandWorst)" -le 3 ] 2>/dev/null; then
  ok "lock: the animated band holds x/width/bottom to $(lock_of bandWorst) px (ceiling 3)"
else
  bad "lock: the animated band drifts $(lock_of bandWorst) px on x/width/bottom (ceiling 3)"
fi
# Per set as well, because one set at the ceiling hides every other one behind it.
# Angel was regenerated to the owner's own description and its sixteen frames hold
# BOTH bounds to zero — the prompt that got there names every part that must not
# move. A re-roll that quietly costs it four pixels must fail here rather than pass
# on somebody else's two.
check "lock: and each set is pinned on its own, not behind the worst of them" \
  "$(lock_of perSet)" "crew/angel=0/0 crew/emre=1/2 crew/ran=1/1 room=0/0"

# Who is at the desk. wall/crew.json is the one place an owner is mapped to a
# character, and a set it names that is missing a frame is a room that never
# lights for that person — so the file is asked for the frames THE ROOM asks
# for, through room.js's own fileOf, rather than against a list written twice.
# base.png used to be the seventh file of a set and never drawn — the still both
# animate jobs were handed. It is a DRAWN frame now: every worker on the wall is
# the base above the split and a cycle frame below it, so it comes down the same
# route as the rest and is covered by FRAMES rather than by a line here.
CREW_CHECK="$(node -e '
  const fs = require("fs"), path = require("path");
  const root = process.argv[1];
  const R = require(path.join(root, "wall", "room.js"));
  const crew = JSON.parse(fs.readFileSync(path.join(root, "wall", "crew.json"), "utf8"));
  const bad = [];
  const owners = Object.keys(crew);
  for (const owner of owners) {
    if (owner !== owner.toLowerCase()) bad.push(owner + ": not a lane key");
    const entry = crew[owner];
    if (!entry || typeof entry.label !== "string" || !entry.label) bad.push(owner + ": no label");
    const set = R.setOf(crew, owner);
    if (set !== entry.set) bad.push(owner + ": set [" + entry.set + "] is not one the room will load");
    const wanted = R.FRAMES.map((f) => R.fileOf(set, f));
    if (set !== R.FALLBACK) wanted.push("assets/" + set + "/base.png");
    for (const rel of wanted) {
      if (!fs.existsSync(path.join(root, "wall", rel))) bad.push(owner + ": missing " + rel);
    }
  }
  // And the fallback is a real set too, for every owner nobody drew.
  for (const f of R.FRAMES) {
    const rel = R.fileOf(R.FALLBACK, f);
    if (!fs.existsSync(path.join(root, "wall", rel))) bad.push("fallback: missing " + rel);
  }
  process.stdout.write(bad.length ? bad.join("; ") : "ok:" + owners.length);
' "$SRC" 2>&1)"
check "crew: every set wall/crew.json names is complete, and so is the fallback" \
  "$CREW_CHECK" "ok:4"

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
grep_ok "$PAGE_SRC" 'shaft__band' \
  "ui: every skyline run lights the floors it has climbed"
grep_ok "$PAGE_SRC" '.shaft[data-state="active"] .shaft__work' \
  "ui: active runs light their current working storey"
grep_ok "$PAGE_SRC" '.shaft[data-state="alarm"] .shaft__work' \
  "ui: blocked live runs keep their current working storey lit"
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
grep_ok "$(cat "$SRC/wall/scene.js")" 'function wetness' \
  "weather: rain intensity is a function, not a loop"
grep_ok "$CSS_SRC" 'var(--haze, 1)'      "weather: the street haze reads it, a lag behind"
grep_ok "$CSS_SRC" 'opacity: var(--dawn, 0)' "weather: and the sky cools toward local dawn"
check "weather: haze and dawn samples blend instead of stepping each second" \
  "$(printf '%s\n' "$CSS_SRC" | grep -c 'transition: opacity var(--weather-blend) linear')" "2"
grep_ok "$PAGE_SRC" 'if (still.matches)' \
  "weather: reduced motion leaves both of those unwritten — today's static scene"
# The weather model moved into the renderer-agnostic scene model when the city
# grew a second body: both worlds have to read the same sky. That makes it
# Node-loadable, so the probe below requires the real file instead of awking a
# section out of it — the same "run the real code" idea, one indirection fewer.
WEATHER_SRC="$(awk '/^  \/\/ --- weather/,/^  \/\/ --- nightlife/' "$SRC/wall/scene.js")"
RAIN_SRC="$(awk '/^  \/\/ --- rain/,/^  render\(\);/' "$SRC/wall/wall.js")"
grep_not "$(printf '%s\n' "$WEATHER_SRC" "$RAIN_SRC" | grep -v '^ *//')" 'Math.random' \
  "weather: neither its state nor its drops rely on unseeded randomness"

PROBE="$ROOT/weather-probe.js"
{
  printf '%s\n' "  const S = require(process.argv[2]);"
  printf '%s\n' "  const { wetness, dawn, seededRandom, weatherSeed } = S;"
  printf '%s\n' "  const { RAIN_LAG, WEATHER_SEED_MS } = S;"
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
WEATHER="$(node "$PROBE" "$SRC/wall/scene.js" 2>&1)"
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
# The other half of the provenance rule: everything the page can pull in has to
# be a file this server actually serves. Collected from the document's own
# src/href attributes plus the two scripts wall.js injects for the canvas world
# — data: URIs and in-document fragments are neither fetched nor served.
ASSETS="$(node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const js = fs.readFileSync(process.argv[2], "utf8");
  const found = new Set();
  for (const m of html.matchAll(/(?:src|href)="([^"]+)"/g)) found.add(m[1]);
  const list = (js.match(/const CANVAS_SCRIPTS = \[([^\]]*)\]/) || [, ""])[1];
  for (const m of list.matchAll(/'"'"'([^'"'"']+)'"'"'/g)) found.add(m[1]);
  const out = [...found].filter((u) => !/^(data:|#|https?:)/.test(u));
  process.stdout.write(out.sort().join(" "));
' "$SRC/wall/index.html" "$SRC/wall/wall.js")"
if [ -z "$ASSETS" ]; then
  bad "assets: the page loads at least one file of its own"
else
  ok "assets: the page's own loads are [$ASSETS]"
fi
for asset in $ASSETS; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/$asset")"
  if [ "$CODE" = 200 ] && [ -f "$SRC/wall/$asset" ]; then
    ok "assets: $asset is a committed file this server serves"
  else
    bad "assets: $asset is a committed file this server serves (http $CODE)"
  fi
done
# And the wall the room actually looks at never asks for the engine: the canvas
# scripts are injected by wall.js behind ?world=canvas, never linked in the page.
grep_not "$(cat "$SRC/wall/index.html")" 'vendor/phaser.min.js' \
  "assets: the DOM wall's document never links the 1.4 MB engine"
grep_not "$(cat "$SRC/wall/index.html")" 'world-canvas.js' \
  "assets: nor the canvas world it belongs to"

API="$(get "$PORT" /api/runs)"
# Kept on disk as well: the room probe further down runs the real renderer's
# arithmetic over this exact payload rather than a restatement of it.
printf '%s' "$API" > "$ROOT/api.json"
check "api: valid JSON" "$(printf '%s' "$API" | jq -r 'type')" "object"
check "api: every fixture run is listed" "$(printf '%s' "$API" | jq '.runs | length')" "12"
for id in OLYX-1631 OLYX-1655 OLYX-1660 OLYX-1642 OLYX-1648 OLYX-1667 OLYX-1673 OLYX-1598 \
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
  "$ORDER" "OLYX-1642 LEGACY-0042 OLYX-1655 OLYX-1648 OLYX-1660 OLYX-1667 adhoc-kpi-sparklines OLYX-1631 BOT-2291 OLYX-1673 OLYX-1598 BOT-2287 "

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
# Idle is a scene fact now, shared by either body; keep this earlier structural
# guard as well as the semantic scene probe below so moving the decision does
# not weaken the plate's established empty-week rule.
grep_ok "$(cat "$SRC/wall/scene.js")" "quiet ? (blocks.length ? 'rest' : 'empty') : 'off'" \
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
# The shortest tower the skyline can stand: the floor of the scene model's own
# height ramp, plus the one run it takes to put a tower on the wall at all. Read
# out of scene.js since the ramp became a field both worlds are handed.
TOWER_RAMP="$(sed -n 's/.*Math.min(94, \([0-9]*\) + n \* \([0-9]*\)).*/\1 \2/p' \
  "$SRC/wall/scene.js" | head -1)"
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
' "$SRC/wall/index.html" "$SRC/wall/wall.css" "$SRC/wall/wall.js" \
  "$SRC/wall/scene.js" "$SRC/wall/world-canvas.js" "$SRC/wall/room.js")"
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
NIGHT_SRC="$(awk '/^  \/\/ --- nightlife/,/^  \/\/ --- the street/' "$SRC/wall/scene.js")"
grep_not "$(printf '%s\n' "$NIGHT_SRC" | grep -v '^ *//')" 'Math.random' \
  "life: no unseeded randomness anywhere in the plan"
NIGHT_PROBE="$ROOT/nightlife-probe.js"
{
  printf '%s\n' "  const S = require(process.argv[2]);"
  printf '%s\n' "  const { storefrontOf, formOf, nightlifeOf, SHOP_GLYPH, FORM_SHARES } = S;"
  printf '%s\n' "  const { MAX_WALKERS, MAX_VEHICLES, GAP_BUSY, MALL_AT, TRAM_AT, OCCUPIED } = S;"
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
NIGHT="$(node "$NIGHT_PROBE" "$SRC/wall/scene.js" 2>&1)"
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

# --- the scene model ----------------------------------------------------------------
# The city grew a second body, so what the city IS moved out of the renderer and
# into wall/scene.js: pure, Node-loadable, no document and no clock of its own.
# Both worlds are handed the same object, which is the only reason they can be
# the same city — so the contract is exercised against the real fixture payload
# rather than against a hand-written stub.
echo "== wall: the scene model is the city, without a renderer =="
SCENE_SRC="$(cat "$SRC/wall/scene.js")"
for banned in document window. 'Date.now' 'Math.random'; do
  grep_not "$(printf '%s\n' "$SCENE_SRC" | grep -v '^ *//')" "$banned" \
    "scene: no [$banned] anywhere in the model"
done
SCENE_PROBE="$ROOT/scene-probe.js"
cat > "$SCENE_PROBE" <<'JS'
const S = require(process.argv[2]);
const snap = JSON.parse(require('node:fs').readFileSync(process.argv[3], 'utf8'));
const AT = snap.at;
const scene = S.buildScene(snap, AT);
const again = S.buildScene(snap, AT);
const plan = S.nightlifeOf(snap.week.ships);
console.log(JSON.stringify({
  towers: scene.towers.length === snap.towers.length && snap.towers.length > 0,
  ranks: scene.towers.every((tower, rank) => tower.rank === rank),
  blocks: scene.blocks.length === snap.city.length,
  ghosts: scene.ghosts.length === snap.ghost.length,
  // Exactly one dedication, and it is not one of the week's ships.
  landmark: scene.landmark.glyph + ':' + (scene.blocks.some((b) => b.id === '冉') ? 'ship' : 'fixture'),
  // Every shaft the snapshot's towers carry is resolved, so a renderer never
  // has to go back to the payload to find out what a car is doing.
  shafts: scene.towers.reduce((n, t) => n + t.shafts.length, 0)
    === snap.towers.reduce((n, t) => n + t.runIds.length, 0),
  levels: scene.towers.every((t) => t.shafts.every((s) => s.level > 0 && s.level <= 1)),
  crew: scene.towers.every((t) => t.shafts.every((s) => /^#[0-9a-f]{6}$/.test(s.crew))),
  street: plan.walkers + 'w' + plan.vehicles + 'v' + plan.gap + 's',
  planned: scene.street.walkers === plan.walkers && scene.street.vehicles === plan.vehicles
    && scene.street.cycle === (plan.vehicles ? plan.gap * plan.vehicles : 48),
  // Semantic sizes only: a height is a percentage of the skyline's own band and
  // a plot is a fraction of the street. No renderer's pixels in here.
  semantic: scene.towers.every((t) => t.heightPct > 0 && t.heightPct <= 94)
    && scene.blocks.every((b) => b.x >= 0 && b.x <= 1 && b.storeys >= 0),
  // Same inputs, same city — byte for byte.
  stable: JSON.stringify(scene) === JSON.stringify(again),
  // And a different clock is a different city, because ages move.
  ages: JSON.stringify(scene) !== JSON.stringify(S.buildScene(snap, AT + 600)),
  idle: scene.idle === 'off'
    && S.buildScene({ city: snap.city, week: snap.week }, AT).idle === 'rest',
  // An empty payload is an empty plain rather than a throw.
  empty: (() => {
    const bare = S.buildScene({}, AT);
    return bare.towers.length === 0 && bare.blocks.length === 0 && bare.quiet === true
      && bare.idle === 'empty' && bare.landmark.glyph === '冉';
  })(),
}));
JS
SNAP="$ROOT/snapshot.json"
printf '%s' "$API" > "$SNAP"
SCENE="$(node "$SCENE_PROBE" "$SRC/wall/scene.js" "$SNAP" 2>&1)"
scene_of() { printf '%s' "$SCENE" | jq -r ".$1" 2>/dev/null; }
check "scene: one tower per tower the server is standing" "$(scene_of towers)" "true"
check "scene: each tower carries its stable skyline rank"       "$(scene_of ranks)" "true"
check "scene: one building per ship in the week's city"   "$(scene_of blocks)" "true"
check "scene: and one silhouette per ship in last week's" "$(scene_of ghosts)" "true"
check "scene: the dedication is in it, and is not a ship" "$(scene_of landmark)" "冉:fixture"
check "scene: every run standing in a tower is resolved"  "$(scene_of shafts)" "true"
check "scene: a car's floor is a fraction of the ladder"  "$(scene_of levels)" "true"
check "scene: and it carries its dispatcher's tint"       "$(scene_of crew)" "true"
check "scene: the street is the week's own plan" \
  "$(scene_of street)" "$(printf '%s' "$API" | jq -r '.week.ships' \
    | xargs -I{} node -e 'const p=require(process.argv[2]).nightlifeOf(+process.argv[3]);
      process.stdout.write(p.walkers+"w"+p.vehicles+"v"+p.gap+"s")' x "$SRC/wall/scene.js" {})"
check "scene: and it carries the cycle the cars share"    "$(scene_of planned)" "true"
check "scene: every size in it is semantic, never a pixel" "$(scene_of semantic)" "true"
check "scene: two calls with equal inputs are the same city" "$(scene_of stable)" "true"
check "scene: a later clock is a later city"              "$(scene_of ages)" "true"
check "scene: idle distinguishes live, resting, and empty cities" "$(scene_of idle)" "true"
check "scene: an empty payload is an empty plain, not a throw" "$(scene_of empty)" "true"

# --- the canvas world -----------------------------------------------------------------
# The same city, on a GPU, behind ?world=canvas — and from this pass a game
# rather than a transcription of one: pixel art authored on the contract's own
# grid, stamped into textures once, lit by additive light on top. What is
# checked here is what a screenshot cannot check: that the page picks a world
# from the query string and nothing else, that the engine is configured the way
# the owner fixed it, that every sprite the code asks for is really a frame in
# the committed atlas, that the world's pixel is the contract's pixel at any
# wall — and the one a keyframe grep could never prove about WebGL, that
# reduced motion genuinely stops the world rather than slowing it down.
echo "== wall: the city's second body =="
CANVAS_SRC="$(cat "$SRC/wall/world-canvas.js")"
grep_ok "$PAGE_SRC" "get('world') === 'canvas'" \
  "canvas: the world is chosen by the query string, in the idiom ?cinema uses"
grep_ok "$PAGE_SRC" 'const world = wantsCanvas ? canvasWorld() : domWorld' \
  "canvas: and the DOM world is what anything else gets"
grep_ok "$PAGE_SRC" "const CANVAS_SCRIPTS = ['vendor/phaser.min.js', 'world-canvas.js']" \
  "canvas: the engine is fetched only for the world that needs it"
# The mount moved OUT of the stage this pass, which is why the world no longer
# appends its own host: the director drives a CSS transform on #stage, a
# transform on a WebGL canvas rasterises it, and a 5 % establishing creep was
# costing the whole city its sharpness on every hold. The box is a sibling of
# the stage, in index.html, and the in/out-of-stage arithmetic further down
# counts it as the tenth element.
grep_ok "$PAGE_SRC" "const worldMount = document.getElementById('world')" \
  "canvas: it mounts in a box the page owns, outside the camera's stage"
grep_ok "$CSS_SRC" '.world { position: fixed; inset: 0;' \
  "canvas: which fills the wall the DOM world's layers used to"
# The DOM world's nodes stay in index.html — the structural tests read it by
# line — but nothing populates them and nothing draws them.
grep_ok "$PAGE_SRC" "if (node) node.setAttribute('hidden', '')" \
  "canvas: the DOM world's layers are hidden rather than deleted"
# The engine config the owner fixed. Read as declarations, so a renamed option
# fails here rather than on the TV. `fps: { limit: 30 }` was lifted to 60 this
# pass: the budget is stated as frames per second at 1920x1080 dpr 2 and a
# 30 Hz cap makes that unmeasurable, and this world draws about a tenth of the
# geometry the transcription did.
for option in "type: Phaser.AUTO" "mode: Phaser.Scale.NONE" \
              "smoothPixelArt: true" "roundPixels: true" \
              "powerPreference: 'low-power'" "fps: { limit: 60 }" \
              "audio: { noAudio: true }" "banner: false"; do
  grep_ok "$CANVAS_SRC" "$option" "canvas: the engine is configured with [$option]"
done
# The canvas covers the wall at whatever aspect the viewport has, and its
# backing store is device pixels: a MacBook is 16:10 and Retina, and both of
# those used to cost black bars and a soft city.
for banned in 'Scale.FIT' 'Scale.ENVELOP' 'autoCenter'; do
  grep_not "$(printf '%s\n' "$CANVAS_SRC" | grep -v '^ *//')" "$banned" \
    "canvas: no [$banned] — the world fills the wall rather than fitting inside it"
done
grep_ok "$CANVAS_SRC" 'zoom: 1 / DPR' \
  "canvas: the backing store is device pixels, shown at CSS size"
grep_ok "$CANVAS_SRC" 'Math.min(window.devicePixelRatio || 1, 2)' \
  "canvas: at the panel's own ratio, capped at 2 for fill-rate"
# smoothPixelArt sets antialias and pixelArt itself; declaring either would fight it.
for banned in 'antialias:' 'pixelArt:'; do
  grep_not "$(printf '%s\n' "$CANVAS_SRC" | grep -v '^ *//')" "$banned" \
    "canvas: [$banned] is left to smoothPixelArt"
done

# THE WORLD'S PIXEL IS THE CONTRACT'S PIXEL. .creative/proportions.md states
# every size at 1280x720 — a person ~10 px, a storey ~14, a 16 px district tile,
# a 32 px facade panel — so the world is 1280 of its own pixels wide at every
# wall and the engine's camera is what scales it to the panel. The old body
# derived a rem from the live viewport instead, which meant a sprite authored
# at 32 px was 32 px of the city on exactly one screen.
grep_ok "$CANVAS_SRC" 'const GRID_W = 1280;' \
  "canvas: the world is 1280 of the contract's own pixels wide, at any wall"
grep_ok "$CANVAS_SRC" 'const REM = 13.44;' \
  "canvas: its module is the stylesheet's clamp resolved at that width"
grep_ok "$CANVAS_SRC" 'const PANEL = 32;' "canvas: and a facade panel is the module's 32"
grep_ok "$CANVAS_SRC" 'cam.setZoom(PIX)' \
  "canvas: the camera is what puts that grid on the panel"
grep_ok "$CANVAS_SRC" 'function measure(cssWidth, cssHeight, ratio)' \
  "canvas: the wall is measured, not declared"
# A resized wall re-measures and lays out again rather than stretching a frame
# drawn for the old size — and the two ScaleManager calls that do it are
# order-dependent: setZoom refreshes the CSS size off the backing store, so
# calling it first leaves the canvas displayed at the size of the previous wall.
check "canvas: a resize sets the backing store before refreshing the CSS size off it" \
  "$(printf '%s\n' "$CANVAS_SRC" | grep -oE 'game\.scale\.(resize|setZoom)' \
     | sed 's/game\.scale\.//' | tr '\n' ' ')" "resize setZoom "
grep_ok "$CANVAS_SRC" 'city.scene.restart()' \
  "canvas: and the city is rebuilt for the new wall rather than repositioned"
GRID_PROBE="$ROOT/grid-probe.js"
cat > "$GRID_PROBE" <<'JS'
const C = require(process.argv[2]);
const shot = (w, h, dpr) => { C.measure(w, h, dpr); return C.grid(); };
const gate = shot(1280, 720, 1);
const tv = shot(3840, 2160, 1);
const retina = shot(1920, 1080, 2);
const capped = shot(1920, 1080, 4);
const laptop = shot(1440, 900, 2);
console.log(JSON.stringify({
  // The backing store is the wall in device pixels, at any aspect.
  gate: gate.w + 'x' + gate.h + '@' + gate.pix,
  // The office TV is an exact 3x of the authored grid: one authored pixel is a
  // clean 3x3 block and nothing is resampled.
  tv: tv.w + 'x' + tv.h + '@' + tv.pix,
  // And so, by arithmetic rather than by luck, is 1920 at dpr 2.
  retina: retina.w + 'x' + retina.h + '@' + retina.pix,
  // Never past dpr 2, however proud the display is of its pixels.
  capped: capped.w + 'x' + capped.h + '@' + capped.pix,
  // The world stays 1280 wide whatever the wall is; a 16:10 laptop gets a
  // taller world rather than a letterbox or a squeeze.
  world: [gate, tv, retina, laptop].map((g) => g.gw + 'x' + Math.round(g.gh)).join(' '),
  // A module is a module everywhere: this is what makes a facade panel the
  // same building at 1280 and on the TV.
  module: [gate, tv, laptop].every((g) => g.rem === 13.44 && g.panel === 32 && g.tile === 16),
  // 16:10 is not letterboxed: the ground line is 9 % of the world's own height.
  ground: (laptop.gh - laptop.groundY).toFixed(3) === (9 * laptop.gh / 100).toFixed(3),
  // And the sky's own 1600x900 box is covered rather than fitted, so a 16:10
  // wall crops the painting exactly as `xMidYMid slice` does in the DOM.
  slice: laptop.sky >= laptop.gw / 1600 && laptop.sky >= laptop.gh / 900
    && Math.min(laptop.skyX, laptop.skyY) <= 0,
}));
JS
GRID="$(node "$GRID_PROBE" "$SRC/wall/world-canvas.js" 2>&1)"
grid_of() { printf '%s' "$GRID" | jq -r ".$1" 2>/dev/null; }
check "canvas: the gate's own 1280x720 wall is drawn 1:1" "$(grid_of gate)" "1280x720@1"
check "canvas: the office 4K panel is an exact 3x of it" "$(grid_of tv)" "3840x2160@3"
check "canvas: and so is 1920x1080 at dpr 2" "$(grid_of retina)" "3840x2160@3"
check "canvas: the ratio is capped at 2, never higher" "$(grid_of capped)" "3840x2160@3"
check "canvas: the world is the contract's 1280 wide at every wall" \
  "$(grid_of world)" "1280x720 1280x720 1280x720 1280x800"
check "canvas: a rem, a panel and a tile are the same size in it everywhere" \
  "$(grid_of module)" "true"
check "canvas: 16:10 is not letterboxed — the ground is 9 % of the world" \
  "$(grid_of ground)" "true"
check "canvas: and the painted sky is sliced to cover, as the DOM slices it" \
  "$(grid_of slice)" "true"

# SOLIDS ARE SPRITES. So the sprites have to be there: every frame name this
# world asks the atlas for is checked against the committed atlas.json, both
# ways. A renamed asset is a hole in the city, and a frame nobody draws is
# weight in the texture and a row in a manifest for nothing.
grep_ok "$CANVAS_SRC" "this.load.atlas(ATLAS, 'assets/city/atlas.png', 'assets/city/atlas.json')" \
  "canvas: the set is one atlas, committed under wall/assets/city"
check "canvas: and it is the only thing this world loads" \
  "$(printf '%s\n' "$CANVAS_SRC" | grep -c 'this\.load\.')" "1"
FRAME_CHECK="$(node -e '
  const fs = require("fs"), path = require("path");
  const root = process.argv[1];
  const atlas = JSON.parse(fs.readFileSync(
    path.join(root, "wall/assets/city/atlas.json"), "utf8"));
  const frames = new Set(Object.keys(atlas.frames));
  const src = fs.readFileSync(path.join(root, "wall/world-canvas.js"), "utf8");
  const asked = new Set();
  for (const m of src.matchAll(/.(city-[a-z0-9-]+)./g)) asked.add(m[1]);
  const missing = [...asked].filter((name) => !frames.has(name));
  const unused = [...frames].filter((name) => !asked.has(name));
  process.stdout.write(missing.length ? "missing: " + missing.join(",")
    : unused.length ? "unused: " + unused.join(",")
    : "ok:" + frames.size);
' "$SRC" 2>&1)"
case "$FRAME_CHECK" in
  ok:*) ok "assets: every sprite the city draws is a frame in the committed atlas" ;;
  *)    bad "assets: the city and its atlas disagree ($FRAME_CHECK)" ;;
esac
# LIGHT IS DRAWN, and state colour is light. A sprite is authored once at full
# value: the alarm's red and a ship's green are a tint on a shared glow, which
# is why neither is allowed to exist in a committed PNG (the palette police
# above refuses the whole shipped ramp from every sprite in wall/assets).
grep_ok "$CANVAS_SRC" 'setTint(tower.alarm ? ALARM : ' \
  "canvas: an alarm is a tint on a light, never a red building in the atlas"
grep_ok "$CANVAS_SRC" 'Phaser.BlendModes.ADD' "canvas: and light is added, not painted over"
grep_ok "$CANVAS_SRC" 'this.mall.setVisible(plan.mall)' \
  "canvas: the street plan's mall milestone has its own visible counterpart"
grep_ok "$CANVAS_SRC" "stone.stamp(ATLAS, 'city-prop-ac'" \
  "canvas: steam rises from a solid atlas vent, not an empty point"
grep_ok "$CANVAS_SRC" "const bollardFrame = this.cut('city-prop-lamp'" \
  "canvas: the pavement's bollards reuse the set's solid post"
grep_ok "$CANVAS_SRC" 'this.tramStop.setVisible(plan.tram)' \
  "canvas: the tram milestone brings its stop marker with it"
# The frame loop moves what is on the GPU and never builds anything: no object
# is created, no sprite is stamped and no texture is allocated inside it. This
# is the whole difference between this world and the one it replaces, whose
# every frame replayed a hundred thousand Graphics commands.
FRAME_SRC="$(awk '/^      step\(force\) \{/,/^      paintCascade/' "$SRC/wall/world-canvas.js")"
for banned in 'this.add.' '.stamp(' 'renderTexture' 'this.make.'; do
  grep_not "$FRAME_SRC" "$banned" "canvas: the frame loop never reaches for [$banned]"
done
# The sky painting is authored once, in index.html. This world reads that node
# rather than keeping a second copy of the same skyline.
grep_ok "$CANVAS_SRC" "document.querySelector('.sky__' + plane.key + ' path')" \
  "canvas: the parallax planes are the page's own path data, not a second copy"
check "canvas: and the three of them stay separately positioned" \
  "$(printf '%s\n' "$CANVAS_SRC" | grep -c "plane.setX(phase.planes\[i\])")" "1"
grep_ok "$CANVAS_SRC" 'fontFamily: CJK' \
  "canvas: the lettering declares the same CJK stack the signs do"

# Reduced motion. A keyframe grep proves nothing about a GPU, so the claim is
# made where it can be checked: the whole of this world's motion is one pure
# function of one clock, and asking it for a still frame returns the SAME frame
# at every second — which is what "nothing tweens, no timer advances state"
# actually means once there is no stylesheet to inspect.
grep_ok "$PAGE_SRC" 'factory.create({ parent: worldMount, still,' \
  "motion: the canvas world is handed the page's own reduced-motion guard"
check "motion: and there is exactly one matchMedia on this wall" \
  "$(printf '%s\n' "$PAGE_SRC" | grep -c "matchMedia('(prefers-reduced-motion: reduce)')")" "1"
grep_ok "$CANVAS_SRC" 'const frozen = still.matches;' \
  "motion: which is what its frame loop asks before it advances anything"
# One clock, and a monotonic one. `clock()` is Date.now()+skew and the skew is
# re-measured on every snapshot, so a world that read it per frame stepped
# sideways every time the server spoke. It is read once, at boot, and the loop
# runs on its own time after that.
grep_ok "$CANVAS_SRC" 'const at = this.origin + this.time.now / 1000;' \
  "motion: the frame loop runs on one monotonic clock, anchored at boot"
grep_not "$(printf '%s\n' "$CANVAS_SRC" | grep -v '^ *//' | grep -v 'this.origin = ')" \
  'clock()' "motion: and never re-reads the skewed wall clock mid-shift"
STILL_PROBE="$ROOT/still-probe.js"
cat > "$STILL_PROBE" <<'JS'
const C = require(process.argv[2]);
const at = [0, 1, 7.5, 3600, 86399, 1755000000.25];
const frozen = at.map((t) => JSON.stringify(C.phaseAt(t, { reducedMotion: true })));
const moving = at.map((t) => JSON.stringify(C.phaseAt(t, {})));
const rest = C.phaseAt(0, { reducedMotion: true });
C.measure(1280, 720, 1);
const WIDE = C.grid().gw;
const whole = (n) => Number.isInteger(n);
const roomy = C.towerLayout(Array.from({ length: 5 }, () => ({ widthRem: 5.6 })));
const crowded = C.towerLayout(Array.from({ length: 20 }, () => ({ widthRem: 5.6 })));
const packed = C.towerLayout(Array.from({ length: 40 }, () => ({ widthRem: 5.6 })));
const bounded = (boxes) => boxes.every((box, i) => box.x >= 0 && box.x + box.w <= WIDE
  && whole(box.x) && whole(box.w)
  && (i === 0 || box.x >= boxes[i - 1].x + boxes[i - 1].w));
console.log(JSON.stringify({
  // Every second of the clock gives the same still frame.
  frozen: new Set(frozen).size === 1,
  // And the same world, asked without that flag, genuinely moves.
  moving: new Set(moving).size === at.length,
  // Every per-object beat derives from that one phase, so freezing it freezes
  // the neon, the occupied windows, the facades and the population too.
  beats: new Set(at.map((t) => {
    const p = C.phaseAt(t, { reducedMotion: true });
    return [C.tubeAt(p, 40, 23), C.tubeAt(p, 3, 16), C.paneAt(p, 1, 55),
      C.facadeAt(p, 9.4), C.walkerAt(p, 2, false), C.walkerAt(p, 5, true),
      JSON.stringify(C.vehicleAt(p, 1, { cycle: 96, gap: 32 }))].join('|');
  })).size === 1,
  // CSS removes both animations under reduced motion. A completion stays on
  // its base frame however old it gets, while attribution is a static 0.85
  // until the server-owned sign lifetime expires and then switches off.
  completionStill: JSON.stringify(C.shaftAt(rest, 0, 40, false))
    === JSON.stringify(C.shaftAt(rest, 39, 40, false))
    && C.shaftAt(rest, 39, 40, true).scale === 1.3,
  signStill: C.signAt(rest, 0, 40) === 0.85 && C.signAt(rest, 39, 40) === 0.85
    && C.signAt(rest, 40, 40) === 0,
  // With motion allowed, those same ages really do advance the two beats.
  timedBeats: C.shaftAt(C.phaseAt(1, {}), 0, 40, false).root
    !== C.shaftAt(C.phaseAt(1, {}), 40, 40, false).root
    && C.signAt(C.phaseAt(1, {}), 0, 40) !== C.signAt(C.phaseAt(1, {}), 40, 40),
  // A still city is a LIT city standing still, which is what wall.css's own
  // reduced-motion block leaves the DOM world showing: the tubes are on, the
  // occupied windows are up, the tram sits on its line and the beacon still
  // faces the room, and only the things that are nothing but motion — the
  // aircraft and the street passes — are out.
  lit: C.tubeAt(rest, 40, 23) === 1 && C.paneAt(rest, 0, 12) === 0.85
    && rest.tram.a > 0 && rest.beam.face === 1
    && rest.ships.every((s) => s.a === 0) && rest.street.every((s) => s.a === 0),
  // And nothing is mid-drift: the planes, the ghost and the weather slabs are
  // all parked where they started.
  parked: rest.planes.every((p) => p === 0) && rest.ghost === 0
    && rest.air.every((a) => a === 0) && rest.steam.every((s) => s.a === 0),
  // The alarm beacon turns, and it only ever turns ONE WAY. A beam that swings
  // back is a windscreen wiper; a beam that goes round is a building asking
  // for a human. Sampled across a whole revolution, the angle never decreases,
  // and the room sees the half of it that faces the room.
  oneWay: (() => {
    const step = 8.8 / 40;
    let last = -Infinity;
    for (let i = 0; i < 40; i++) {
      const a = C.phaseAt(i * step, {}).beam.angle;
      if (a <= last) return false;
      last = a;
    }
    const facing = C.phaseAt(8.8 * 0.25, {}).beam.face;
    const away = C.phaseAt(8.8 * 0.75, {}).beam.face;
    return facing === 1 && away === 0 && rest.beam.angle === -14;
  })(),
  // The hand-written flex row keeps both an ordinary fixture and a genuinely
  // crowded skyline inside the world without letting towers overlap — and
  // every edge of it lands on a whole world pixel, because a tower standing on
  // x.5 is a tower whose windows are half a pixel off their own rhythm.
  layout: bounded(roomy) && bounded(crowded) && bounded(packed),
  // space-evenly leaves a single tower centred in the skyline band.
  centred: (() => {
    const [box] = C.towerLayout([{ widthRem: 5.6 }]);
    return Math.abs(box.x + box.w / 2 - WIDE / 2) <= 1;
  })(),
  // Every building in the district is a stack of rectangles standing on the
  // pavement, all of them inside their own plot, and the widest of them is the
  // one at the bottom: that is the silhouette, and it has no off-grid edge in
  // it anywhere.
  masses: [...Object.values(C.TOWER_MASSES), ...Object.values(C.FORM_MASSES),
    ...Object.values(C.KIND_MASSES)].every((stack) =>
    stack.length && stack[0].w === 1 && stack[0].x === 0
      && stack.every((m) => m.x >= 0 && m.x + m.w <= 1 && m.top >= 0 && m.top < 1)),
  // And a plot is whole pixels wide, whole pixels tall and standing on the
  // ground line, at whatever depth band it is in.
  plots: [0, 1, 2].every((depth) => {
    const box = C.blockBox({ id: 'X', kind: 'midrise', depth, x: 0.5, storeys: 4,
      shape: { form: 'slab', grade: 1 } });
    return whole(box.x) && whole(box.y) && whole(box.w) && whole(box.h)
      && box.y + box.h === Math.round(C.grid().groundY);
  }),
}));
JS
STILL="$(node "$STILL_PROBE" "$SRC/wall/world-canvas.js" 2>&1)"
still_of() { printf '%s' "$STILL" | jq -r ".$1" 2>/dev/null; }
check "motion: reduced motion is one frame, at every second of the clock" \
  "$(still_of frozen)" "true"
check "motion: and the same world without it genuinely moves" "$(still_of moving)" "true"
check "motion: every beat in the world derives from that one phase" \
  "$(still_of beats)" "true"
check "motion: reduced motion keeps completed shafts on their static frame" \
  "$(still_of completionStill)" "true"
check "motion: and holds attribution steady until its lifetime expires" \
  "$(still_of signStill)" "true"
check "motion: those completion and cooling beats advance when motion is allowed" \
  "$(still_of timedBeats)" "true"
check "motion: a still canvas city is a lit city, not a dark one" "$(still_of lit)" "true"
check "motion: with nothing left mid-drift" "$(still_of parked)" "true"
check "alarm: the beacon turns one way, for ever" "$(still_of oneWay)" "true"
check "canvas: even an uncapped live skyline shrinks without hiding or overlapping work" \
  "$(still_of layout)" "true"
check "canvas: space-evenly keeps a lone tower centred" "$(still_of centred)" "true"
check "canvas: every silhouette is a stack of rectangles on the pavement" \
  "$(still_of masses)" "true"
check "canvas: and every plot is whole pixels standing on the ground line" \
  "$(still_of plots)" "true"

# A RUNNING JOB IS A LIT FLOOR. No lift cars: the storey a run has reached
# lights its own windows and the light comes out of the building. Two claims
# carry it and both are arithmetic — the band lands on the façade's own 32 px
# course, and the glass in that course is where the atlas actually drew it.
grep_not "$(printf '%s\n' "$CANVAS_SRC" | grep -v '^ *//')" 'paintShaft' \
  "floor: the lift car and its shaft are gone from the canvas world"
grep_ok "$CANVAS_SRC" 'paintFloor(S, run, T, slot, slots)' \
  "floor: a run is painted as a storey of a tower, not as a car in a lane"
grep_ok "$CANVAS_SRC" 'const shared = new Map();' \
  "floor: two runs on one floor share its bays rather than lighting it twice"

# THE WORLD OWNS ITS CAMERA. The page's director drives one CSS transform on
# #stage and this canvas is deliberately not under it, so in ?world=canvas the
# section hands the reel over and returns — one line, and everything else in it
# byte for byte what the DOM wall runs. The block further down still counts
# leaveShot() three times and greps the same literals.
grep_ok "$PAGE_SRC" 'if (world.direct && world.direct(reelSignals())) return;' \
  "reel: the director hands the film to a world that draws its own city"
grep_ok "$PAGE_SRC" 'direct(signals) { reel = signals; if (live) live.direct(signals); return true; }' \
  "reel: answered before the engine lands, so the DOM camera never starts"
grep_ok "$PAGE_SRC" 'wantsCinema,                              // the whole truth table, verbatim' \
  "reel: and the activation rules are handed over rather than restated"
grep_ok "$PAGE_SRC" 'function roomDive(on, runId) {' \
  "reel: the run the dive went in through is pinned by the room's own section"
grep_ok "$CANVAS_SRC" 'cam.setZoom(pose.zoom);' "reel: the camera is the scene's own"
grep_ok "$CANVAS_SRC" 'cam.centerOn(pose.x, pose.y);' \
  "reel: pointed by one pose function and nothing else"
grep_ok "$CANVAS_SRC" 'this.textures.addCanvas(ROOM_KEY, canvas)' \
  "dive: the room in the window is wall/room.js's own canvas, sampled"
grep_ok "$CANVAS_SRC" 'this.roomTex.refresh();' \
  "dive: refreshed per frame, so the room in there is the room that is running"
grep_ok "$CSS_SRC" 'body[data-world="canvas"] .room[data-on="1"] { opacity: 0; }' \
  "dive: the overlay stays out of the push's way while room.js paints for it"
grep_ok "$CSS_SRC" 'body[data-world="canvas"][data-dive="inside"] .room[data-on="1"] { opacity: 1; }' \
  "dive: and takes the frame only once the push has landed on that same picture"
# Reduced motion is absolute here too: the reel is only ever consulted when the
# wall is filming AND the room has not asked for stillness.
grep_ok "$CANVAS_SRC" 'const rolling = film.on && !still.matches && !s.forcedRoom;' \
  "reel: reduced motion never rolls, so there is no dive to park"
grep_ok "$CANVAS_SRC" "step = { phase: 'room', u: 1 };" \
  "reel: ?shot=room is the camera born in the dived pose, with no move at all"

# And the film itself, run in node. The reel is a pure function of the clock,
# the plan and whether the wall is filming — no tween, no timer, no integrator
# — which is the only reason a camera can be checked without a GPU, and also
# the reason a snapshot landing mid-push cannot move it.
REEL_PROBE="$ROOT/reel-probe.js"
cat > "$REEL_PROBE" <<'JS'
const C = require(process.argv[2]);
const cadence = { wide: 20000, moveMin: 6000, moveMax: 10000,
                  roomMin: 15000, roomMax: 20000, cut: 700 };
// The suite's own draw, not the wall's: seeded, so the plans below are the
// same two hundred plans on every machine.
let seed = 1;
const draw = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
const plans = Array.from({ length: 200 }, () => C.reelPlan(draw, cadence));
const walk = (plan, steps) => Array.from({ length: steps },
  (_, i) => C.reelAt((i / (steps - 1)) * plan.total, plan));
const whole = (n) => Number.isInteger(n);
// Every wall the gate, the office TV and a laptop can show this on.
const walls = [[1280, 720, 1], [1920, 1080, 1], [1280, 720, 2], [3840, 2160, 1]];
const pane = { x: 639, y: 531, w: 7, h: 22 };
const landing = walls.map(([w, h, dpr]) => {
  C.measure(w, h, dpr);
  const g = C.grid();
  const room = C.roomBoxAt(pane);
  const end = C.poseAt(1, room);
  // The room is on screen at the whole multiple wall.css picks for the DOM
  // overlay, and its left edge lands on a whole device pixel of the wall.
  return {
    wall: w + 'x' + h + '@' + dpr,
    scale: end.zoom,
    css: end.zoom / g.dpr,
    edge: g.w / 2 - (C.grid().roomW / 2) * end.zoom,
    holds: room.x <= pane.x && room.x + room.w >= pane.x + pane.w
      && room.y <= pane.y && room.y + room.h >= pane.y + pane.h,
  };
});
C.measure(1280, 720, 1);
const G = C.grid();
const room = C.roomBoxAt(pane);
const poses = Array.from({ length: 101 }, (_, i) => C.poseAt(i / 100, room));
const mass = { x: 588, y: 154, w: 132, h: 502 };
const storeys = [0, 0.1, 0.26, 0.42, 0.59, 0.75, 0.92, 1].map((l) => C.storeyAt(mass, l));
const groundTop = mass.y + mass.h - G.panel;
console.log(JSON.stringify({
  // The cadence is the DOM wall's, to the millisecond.
  cadence: plans.every((p) => p.wide === 20000
    && p.move >= 6000 && p.move <= 10000 && p.back >= 6000 && p.back <= 10000
    && p.hold >= 15000 && p.hold <= 20000
    && p.total === p.wide + p.move + p.hold + p.back),
  // ...and it varies, rather than being the same film on a loop.
  varies: new Set(plans.map((p) => p.move + ':' + p.hold + ':' + p.back)).size > 150,
  // One cycle is wide, in, the room, out. In that order, once each, and
  // nothing else is on offer in this world.
  sequence: new Set(plans.map((p) => walk(p, 400)
    .map((s) => s.phase).filter((k, i, all) => k !== all[i - 1]).join(','))).size === 1,
  order: walk(plans[0], 400).map((s) => s.phase)
    .filter((k, i, all) => k !== all[i - 1]).join(','),
  // The push only ever goes in, and the pull back only ever comes out: a lens
  // that eased backwards mid-move is the cut the whole shot exists to avoid.
  monotonic: plans.every((p) => walk(p, 800).every((s, i, all) => {
    if (i === 0) return true;
    if (s.phase === 'in') return s.u >= all[i - 1].u;
    if (s.phase === 'out') return all[i - 1].phase !== 'out' || s.u <= all[i - 1].u;
    return s.phase === 'wide' ? s.u === 0 : s.u === 1;
  })),
  // The wall says what it is showing in the DOM director's own words.
  shots: ['wide', 'in', 'room', 'out'].map(C.shotOf).join(','),
  // No lit floor, no dive: a city with nothing running holds the wide shot.
  noWindow: JSON.stringify(C.reelWith({ phase: 'in', u: 0.6 }, null)),
  withWindow: C.reelWith({ phase: 'in', u: 0.6 }, { run: 'X' }).u,
  // u = 0 IS the wide shot: same zoom and same centre the scene boots with.
  wide: poses[0].zoom === G.pix && poses[0].x === G.gw / 2 && poses[0].y === G.gh / 2,
  // The zoom is geometric and never reverses; the last stretch is the slowest,
  // which is the pane opening rather than the camera arriving.
  zoomIn: poses.every((p, i) => i === 0 || p.zoom > poses[i - 1].zoom),
  eased: (() => {
    const first = poses[10].zoom - poses[0].zoom;
    const middle = poses[55].zoom - poses[45].zoom;
    const last = poses[100].zoom - poses[90].zoom;
    return first < middle && last < middle;
  })(),
  // Every frame of the push is full of city: the view never leaves the world,
  // at any point of the move, however near the edge the window is.
  inCity: [pane, { x: 8, y: 40, w: 7, h: 22 }, { x: 1268, y: 620, w: 7, h: 22 }]
    .every((p) => {
      const box = C.roomBoxAt(p);
      return Array.from({ length: 101 }, (_, i) => C.poseAt(i / 100, box)).every((q) => {
        const halfW = G.w / (2 * q.zoom);
        const halfH = G.h / (2 * q.zoom);
        return q.x - halfW >= -0.01 && q.x + halfW <= G.gw + 0.01
          && q.y - halfH >= -0.01 && q.y + halfH <= G.gh + 0.01;
      });
    }),
  // The pane opens from the window the camera is flying at onto the room's own
  // rectangle, and never shrinks on the way.
  apertureStart: JSON.stringify(C.apertureAt(0, pane, room)) === JSON.stringify(pane),
  apertureEnd: JSON.stringify(C.apertureAt(1, pane, room)) === JSON.stringify(room),
  apertureOpens: Array.from({ length: 101 }, (_, i) => C.apertureAt(i / 100, pane, room))
    .every((a, i, all) => i === 0 || (a.w >= all[i - 1].w && a.h >= all[i - 1].h)),
  // The landing, at every wall: a WHOLE number of device pixels per authored
  // room pixel, the same whole number wall.css gives the DOM overlay, and the
  // room's own edge on a whole pixel of the panel.
  landing: landing.map((l) => l.wall + '=' + l.scale + 'x').join(' '),
  landingWhole: landing.every((l) => whole(l.scale) && whole(l.css) && whole(l.edge)),
  // ...and the window it came in through is inside the room it opens onto,
  // wherever on the wall that window happens to be.
  landingHolds: landing.every((l) => l.holds)
    && [{ x: 4, y: 12, w: 7, h: 22 }, { x: 1270, y: 640, w: 7, h: 22 }].every((p) => {
      const box = C.roomBoxAt(p);
      return box.x <= p.x && box.x + box.w >= p.x + p.w
        && box.y <= p.y && box.y + box.h >= p.y + p.h;
    }),
  // A lit floor is a COURSE of the façade, not a band at a fraction of a
  // height: whole panels above the ground floor, one panel tall, inside the
  // mass, and climbing with the stage rather than wandering.
  courses: storeys.every((s) => s.h === G.panel && (groundTop - s.y) % G.panel === 0
    && s.y >= mass.y && s.y + s.h <= groundTop && s.x === mass.x && s.w === mass.w),
  climbs: storeys.every((s, i) => i === 0 || s.course >= storeys[i - 1].course)
    && storeys[storeys.length - 1].course > storeys[0].course,
  // A setback tower is narrower up top: a course lit there spans the wall AT
  // that height — inside the box, narrower than the base, never in the sky.
  setback: (() => {
    const masses = [{ x: 0, w: 1, top: 0.6 }, { x: 0.07, w: 0.86, top: 0.3 },
                    { x: 0.14, w: 0.72, top: 0 }];
    const low = C.storeyAt(mass, 0.05, masses);
    const high = C.storeyAt(mass, 1, masses);
    return low.w === mass.w && low.x === mass.x
      && high.w < low.w && high.x > mass.x && high.x + high.w < mass.x + mass.w
      && high.w === Math.round(0.72 * mass.w)
      && C.spanAt(mass, masses, low.y).w === mass.w;
  })(),
  // And the glass in that course is where the atlas drew it: two bays to every
  // 32 px panel, tiled from the mass's own left edge, every pane inside the
  // course, and a part-panel at the right simply drops its bays.
  glass: ['concrete', 'glass', 'brick'].every((skin) => {
    const bays = C.baysOf(storeys[3], skin);
    return bays.length === Math.floor(mass.w / G.panel) * 2
      && bays.every((b) => b.x >= mass.x && b.x + b.w <= mass.x + mass.w
        && (b.x - mass.x) % G.panel < G.panel
        && b.panes.every((p) => p.y >= storeys[3].y
          && p.y + p.h <= storeys[3].y + storeys[3].h));
  }),
  // The window the camera goes in through is one of those bays.
  window: ['concrete', 'glass', 'brick'].every((skin) => {
    const w = C.windowAt(storeys[3], skin);
    return C.baysOf(storeys[3], skin).some((b) => b.x === w.x && b.w === w.w)
      && w.y >= storeys[3].y && w.y + w.h <= storeys[3].y + storeys[3].h;
  }),
}));
JS
REEL="$(node "$REEL_PROBE" "$SRC/wall/world-canvas.js" 2>&1)"
reel_of() { printf '%s' "$REEL" | jq -r ".$1" 2>/dev/null; }
check "reel: the cadence is the DOM wall's, to the millisecond" "$(reel_of cadence)" "true"
check "reel: and no two cycles are the same film" "$(reel_of varies)" "true"
check "reel: one cycle is wide, in, the room, out — and nothing else" \
  "$(reel_of order)" "wide,in,room,out"
check "reel: every cycle, at every clock" "$(reel_of sequence)" "true"
check "reel: the push only goes in and the pull back only comes out" \
  "$(reel_of monotonic)" "true"
check "reel: the wall says which shot it is showing, in the director's words" \
  "$(reel_of shots)" "establishing,room,room,establishing"
check "reel: a city with no lit floor to dive into holds the wide shot" \
  "$(reel_of noWindow)" '{"phase":"wide","u":0}'
check "reel: and one with a lit floor gets its dive" "$(reel_of withWindow)" "0.6"
check "reel: the start of the push IS the wide shot the wall was already on" \
  "$(reel_of wide)" "true"
check "reel: the zoom is a lens — geometric, and it never reverses" \
  "$(reel_of zoomIn)" "true"
check "reel: eased in and out, so the last second is the pane opening" \
  "$(reel_of eased)" "true"
check "reel: and every frame of the move is still full of city" "$(reel_of inCity)" "true"
check "dive: the aperture starts as the window the camera is flying at" \
  "$(reel_of apertureStart)" "true"
check "dive: and ends as the room's own rectangle, exactly" \
  "$(reel_of apertureEnd)" "true"
check "dive: opening all the way, never shrinking" "$(reel_of apertureOpens)" "true"
check "dive: the room lands at a whole multiple of its own 320x180" \
  "$(reel_of landing)" "1280x720@1=4x 1920x1080@1=6x 1280x720@2=8x 3840x2160@1=12x"
check "dive: in device pixels, in CSS pixels, and on a whole pixel of the wall" \
  "$(reel_of landingWhole)" "true"
check "dive: with the window it came in through inside the room it opens onto" \
  "$(reel_of landingHolds)" "true"
check "floor: a lit floor is a whole course of the façade, inside the mass" \
  "$(reel_of courses)" "true"
check "floor: and it climbs with the stage rather than wandering" \
  "$(reel_of climbs)" "true"
check "floor: on a setback tower the lit course spans the wall at its own height, not the box" \
  "$(reel_of setback)" "true"
check "floor: its light lands on the glass the atlas drew, in every wall of the set" \
  "$(reel_of glass)" "true"
check "floor: and the window the dive goes through is one of those bays" \
  "$(reel_of window)" "true"

# --- the director films the city --------------------------------------------------
# The wall can film itself: a slow camera that holds the skyline, pushes in on
# something living in it, and comes back out. Two structural claims carry the
# whole feature — the camera is ONE transform on ONE stage, and the HUD is not
# on that stage — so they are checked as structure rather than as prose.
echo "== wall: the camera is one transform on one stage =="
DIRECTOR_SRC="$(awk '/^  \/\/ --- the director/,/^  \/\/ --- start of shift/' "$SRC/wall/wall.js")"
grep_ok "$PAGE_SRC" 'id="stage"' "cinema: every world layer shares one stage"
line_of() { grep -n -- "$2" "$SRC/wall/$1" | head -1 | cut -d: -f1; }
STAGE_OPEN="$(line_of index.html 'id="stage"')"
STAGE_CLOSE="$(line_of index.html '<!-- /stage -->')"
inside() {  # $1 = human name, $2 = marker, $3 = "in" | "out"
  local at; at="$(line_of index.html "$2")"
  local where="out"
  [ -n "$at" ] && [ -n "$STAGE_OPEN" ] && [ -n "$STAGE_CLOSE" ] \
    && [ "$at" -gt "$STAGE_OPEN" ] && [ "$at" -lt "$STAGE_CLOSE" ] && where="in"
  check "cinema: $1 is $3 the stage" "$where" "$3"
}
# The world rides the camera...
inside "the painted sky"    'class="sky"'      in
inside "the week's district" 'id="district"'   in
inside "the skyline"        'id="city"'        in
inside "the street life"    'id="life"'        in
inside "the haze"           'class="haze"'     in
# ...and everything the room reads does not. A push-in on a shopfront must not
# scale a word of type, and the rain is the nearest thing there is to the lens.
inside "the HUD"            'class="hud"'      out
inside "the brief plate"    'id="brief"'       out
inside "the comms ticker"   'id="comms"'       out
inside "the rain"           'id="rain"'        out
# The tenth element, and the newest: the canvas world's box. A CSS transform on
# a WebGL canvas rasterises it, and the establishing shot creeps this stage by
# 5 % on every hold — so the world that draws itself keeps its own camera and
# stays out from under the director's.
inside "the canvas world"   'id="world"'       out
grep_ok "$CSS_SRC" 'transform-origin: 0 0' "cinema: the stage has a fixed camera origin"
grep_ok "$PAGE_SRC" 'stage.style.transform' \
  "cinema: the director drives that transform and nothing else"
grep_not "$DIRECTOR_SRC" 'hud' "cinema: and never reaches for a chrome element"
# The camera is a long JS-driven transition, not a keyframe: the transform/opacity
# police above already covers any keyframe this pass might have added.
grep_ok "$PAGE_SRC" "stage.style.transition = 'transform '" \
  "cinema: moves are eased transitions, timed per shot"
grep_ok "$CSS_SRC" '.stage { transform: none !important; }' \
  "motion: reduced motion parks the camera wide, whatever a session left behind"
# The one line this section grew for the world that draws its own city: it is
# INSIDE the director, it is the first thing the director does, and everything
# after it is what the DOM wall has always run. Handing over is not the same as
# having two cameras.
grep_ok "$DIRECTOR_SRC" 'if (world.direct && world.direct(reelSignals())) return;' \
  "cinema: a world that draws its own city is handed the reel, here"
check "cinema: and that is the whole of the hand-off" \
  "$(printf '%s\n' "$DIRECTOR_SRC" | grep -cF 'world.direct')" "1"

# The whole fabric of this city is seeded off a run id or the wall clock. The
# director is presentation and gets the wall-clock bucket, never a raw draw —
# so after this pass the page still contains no unseeded randomness at all.
# Every authored file the page runs, both worlds included; never wall/vendor/,
# whose contents are pinned by hash rather than read line by line.
for authored in wall.js scene.js world-canvas.js room.js; do
  grep_not "$(grep -v '^ *//' "$SRC/wall/$authored")" 'Math.random' \
    "cinema: nothing in $authored is drawn from unseeded randomness"
done
grep_ok "$DIRECTOR_SRC" 'seededRandom(bucket)' \
  "cinema: shot variety reuses the weather's wall-clock bucket"

# Activation, and the two switches that outrank everything else. The decision is
# one pure function with no DOM in it, so the suite runs the real thing over the
# whole truth table rather than restating it in prose.
CINE_PROBE="$ROOT/cinema-probe.js"
{
  grep -E '^  const (MAX_ZOOM|CREEP|CINEMA_IDLE_MS|SHOT_SEED_MS|MOVE_MIN|MOVE_MAX|HOLD_MIN|HOLD_MAX|WIDE_HOLD|CUT_MS) = ' \
    "$SRC/wall/wall.js"
  # The section reads the query string once at load; nothing else in it touches
  # the DOM until a shot is cut.
  printf '%s\n' '  const window = { location: { search: "" } };'
  printf '%s\n' "$DIRECTOR_SRC"
  cat <<'JS'
  const FLAGS = [null, 'on', 'off'];
  const MANUAL = [null, true, false];
  const rows = [];
  for (const forced of FLAGS) for (const manual of MANUAL) for (const idle of [false, true]) {
    for (const reduced of [false, true]) {
      rows.push({ forced, manual, idle, reduced, on: wantsCinema({ forced, manual, idle, reduced }) });
    }
  }
  const only = (f) => rows.filter(f);
  const view = { w: 1600, h: 900 };
  const frames = [];
  for (const w of [4, 40, 400, 1600]) for (const h of [3, 30, 300, 900]) {
    for (const x of [-200, 0, 700, 1580]) for (const y of [-50, 0, 400, 880]) {
      for (const ax of [0.3, 0.5, 0.7]) {
        const cam = frameFor({ x, y, w, h }, view, { fillW: 0.5, fillH: 0.6, ax, ay: 0.5 });
        frames.push({ ...cam, creep: creepFrom(cam, view, 0.03, -0.02) });
      }
    }
  }
  const legal = (c) => c.s >= 1 && c.x <= 0.001 && c.y <= 0.001
    && c.x >= view.w * (1 - c.s) - 0.001 && c.y >= view.h * (1 - c.s) - 0.001;
  console.log(JSON.stringify({
    // Reduced motion and ?cinema=0 are absolute: nothing talks past either.
    reducedNever: only((r) => r.reduced).every((r) => !r.on),
    offNever: only((r) => r.forced === 'off').every((r) => !r.on),
    // With neither in play: the param forces it on, the key wins over the param,
    // and an untouched wall waits for the idle timer.
    onForces: rows.find((r) => !r.reduced && r.forced === 'on' && r.manual === null && !r.idle).on,
    keyOverridesOn: rows.find((r) => !r.reduced && r.forced === 'on' && r.manual === false).on,
    keyOverridesIdle: rows.find((r) => !r.reduced && !r.forced && r.manual === true && !r.idle).on,
    quietEngages: rows.find((r) => !r.reduced && !r.forced && r.manual === null && r.idle).on,
    busyWaits: rows.find((r) => !r.reduced && !r.forced && r.manual === null && !r.idle).on,
    // The event transition matters as much as the activation truth table: `c`
    // must stop a film the idle timer started, and ordinary input must dismiss
    // one that `c` started instead of leaving a sticky manual override behind.
    toggleStopsIdle: manualAfterActivity(null, true, true) === false,
    inputStopsManual: !wantsCinema({
      reduced: false, forced: null,
      manual: manualAfterActivity(true, true, false), idle: false,
    }),
    idleMinutes: CINEMA_IDLE_MS / 60000,
    // A shot is always a legal frame: never wider than the wide shot, never
    // past the lens ceiling, and never showing anything that is not city.
    framesLegal: frames.every((c) => legal(c) && c.s <= MAX_ZOOM + 0.001),
    creepLegal: frames.every((c) => legal(c.creep) && c.creep.s >= c.s),
    // A tiny target saturates the lens; a target the size of the frame is the
    // wide shot and needs no move at all.
    tiny: frameFor({ x: 800, y: 450, w: 4, h: 3 }, view, {}).s,
    whole: frameFor({ x: 0, y: 0, w: view.w, h: view.h }, view, {}),
    // Alarm beats active beats shipped, and a tower with none of them is not a
    // shot at all.
    rank: ['alarm', 'active', 'ready', 'failed'].map((s) => towerRank([s])).join(','),
    rankPicks: towerRank(['ready', 'alarm', 'active']) === towerRank(['alarm']),
    rankEmpty: towerRank([]),
    // Timings: seconds, not frames.
    moves: MOVE_MIN >= 6000 && MOVE_MAX <= 10000 && MOVE_MIN < MOVE_MAX,
    holds: HOLD_MIN >= 8000 && HOLD_MAX <= 20000 && WIDE_HOLD >= HOLD_MAX,
    cutFast: CUT_MS <= 1000,
    // Leaving a shot, which every exit shares. The dive is the one shot that
    // puts something on the wall the camera cannot take back off it, so the
    // hook has to run whether the hold ended, the wall was resized, `c` was
    // pressed or somebody walked in — and exactly once.
    ...(() => {
      const left = [];
      current = { kind: 'room', leave: () => left.push('room') };
      shotTimer = 7;
      leaveShot();
      const once = left.join(',');
      leaveShot();
      return {
        leavesOnce: once === 'room' && left.join(',') === 'room',
        leaveClearsTimer: shotTimer === 0,
        leaveForgetsShot: current === null,
      };
    })(),
  }));
JS
} > "$CINE_PROBE"
CINE="$(node "$CINE_PROBE" 2>&1)"
cine_of() { printf '%s' "$CINE" | jq -r ".$1" 2>/dev/null; }
check "cinema: reduced motion never engages the director, ever" \
  "$(cine_of reducedNever)" "true"
check "cinema: ?cinema=0 never engages it either" "$(cine_of offNever)" "true"
check "cinema: ?cinema=1 forces it on"            "$(cine_of onForces)" "true"
check "cinema: and the c key can still stop a forced film" \
  "$(cine_of keyOverridesOn)" "false"
check "cinema: the c key starts one on an untouched wall" \
  "$(cine_of keyOverridesIdle)" "true"
check "cinema: a quiet room gets the film by itself" "$(cine_of quietEngages)" "true"
check "cinema: a room in use does not"               "$(cine_of busyWaits)" "false"
check "cinema: the c key stops a film the idle timer started" \
  "$(cine_of toggleStopsIdle)" "true"
check "cinema: any other input stops a film the c key started" \
  "$(cine_of inputStopsManual)" "true"
check "cinema: it takes a minute and a half of quiet" "$(cine_of idleMinutes)" "1.5"
check "cinema: every framing is inside the city and inside the lens" \
  "$(cine_of framesLegal)" "true"
check "cinema: and the drift across a hold stays there too" \
  "$(cine_of creepLegal)" "true"
check "cinema: a detail smaller than the lens tops out at the ceiling" \
  "$(cine_of tiny)" "4"
check "cinema: framing the whole frame IS the wide shot" \
  "$(cine_of 'whole | "\(.s),\(.x),\(.y)"')" "1,0,0"
check "cinema: alarm outranks active outranks shipped" "$(cine_of rank)" "3,2,1,0"
check "cinema: a tower is worth its most interesting run" "$(cine_of rankPicks)" "true"
check "cinema: a tower with nothing live in it is not a shot" "$(cine_of rankEmpty)" "0"
check "cinema: moves take six to ten seconds"  "$(cine_of moves)" "true"
check "cinema: holds are long, and the wide shot holds longest" "$(cine_of holds)" "true"
check "cinema: a dismissed film gets the wide shot back inside a second" \
  "$(cine_of cutFast)" "true"
check "cinema: leaving a shot runs its own leave hook exactly once" \
  "$(cine_of leavesOnce)" "true"
check "cinema: and cancels the timer the next cut was waiting on" \
  "$(cine_of leaveClearsTimer)" "true"
check "cinema: after which there is no shot left to leave" \
  "$(cine_of leaveForgetsShot)" "true"
# One exit, three call sites: the hold ending, the engage/disengage switch that
# `c` and a hand on the mouse both come through, and the resize. A resize that
# cancelled the timer and cut straight to the next shot is how a dive used to
# leave its room covering the shot after it.
check "cinema: every path out of a shot goes through leaveShot" \
  "$(printf '%s\n' "$DIRECTOR_SRC" | grep -cF 'leaveShot();')" "3"
grep_ok "$DIRECTOR_SRC" 'reframe = setTimeout(() => { leaveShot(); nextShot(); }, 400);' \
  "cinema: a resize leaves the shot it re-frames away from"
grep_not "$DIRECTOR_SRC" 'clearTimeout(shotTimer); nextShot();' \
  "cinema: and nothing cancels a shot's timer behind its back"

# Every shot type the brief names exists, and — the wide shot aside, which is
# always available — each one can say there is nothing to film: an empty
# district is skyline and towers only, and a landmark behind a tower is no
# landmark shot at all.
grep_ok "$DIRECTOR_SRC" "function wideShot(" "cinema: the reel knows the wide shot"
for kind in towerShot streetShot windowShot landmarkShot roomShot; do
  BODY="$(printf '%s\n' "$DIRECTOR_SRC" | awk -v k="  function $kind(" 'index($0, k) == 1, /^  }$/')"
  if [ -z "$BODY" ]; then
    bad "cinema: the reel knows the $kind"
  elif printf '%s\n' "$BODY" | grep -q 'return null;'; then
    ok "cinema: the $kind declines when the city is not offering it"
  else
    bad "cinema: the $kind declines when the city is not offering it"
  fi
done
grep_ok "$DIRECTOR_SRC" "wideNext = next.kind !== 'establishing'" \
  "cinema: and the wide shot is what every close shot returns to"

# --- the dive -------------------------------------------------------------------
# Every other shot stops at the glass. The dive goes through it: the camera
# pushes into the lit storey of the spotlit run, the room fades up over it at
# full frame, holds, and the wall comes back out. Two halves to check — that the
# reel really carries it, and that what it lands on is the truth about that run.
echo "== wall: the camera goes inside =="
grep_ok "$DIRECTOR_SRC" "kinds = ['tower', 'street', 'window', 'room']" \
  "dive: the room is one of the shots a rotation can offer"
grep_ok "$DIRECTOR_SRC" ".shaft[data-spot=\"1\"] .shaft__work" \
  "dive: and it goes through the lit storey of the run the beam is already on"
grep_ok "$DIRECTOR_SRC" 'if (next.enter) next.enter();' \
  "dive: the cross-fade happens where the push lands, not where it started"
grep_ok "$DIRECTOR_SRC" 'if (next.leave) next.leave();' \
  "dive: and the wall comes back out of it before the next cut"
grep_ok "$PAGE_SRC" "roomHold(false);" \
  "dive: somebody walking in takes the room away with the film"
grep_ok "$PAGE_SRC" "roomParams.get('shot') === 'room'" \
  "dive: ?shot=room is read once at load, in the idiom ?cinema uses"
grep_ok "$DIRECTOR_SRC" 'if (forcedRoom) {' \
  "dive: and that still parks the camera instead of filming under the room"

# Whose room it is. The plate hands over every seven seconds and a dive is a
# six-to-ten second push onto a fifteen-to-twenty second hold, so a room that
# kept asking the plate would enter one run's window and finish on somebody
# else's ticket. Run the real chooser out of the real file, the way the cinema
# probe runs the real activation rules.
ROOM_PAGE_SRC="$(awk '/^  \/\/ --- the room ---/,/^  \/\/ --- the director ---/' "$SRC/wall/wall.js")"
ROOM_PIN="$ROOT/room-pin.js"
{
  printf '%s\n' '  const window = { location: { search: "" } };'
  printf '%s\n' '  const document = { getElementById: () => null };'
  printf '%s\n' '  const still = { matches: false };'
  printf '%s\n' '  const seededRandom = () => () => 0.5;'
  printf '%s\n' '  const crewTint = () => "#e8cfa6";'
  printf '%s\n' '  let latest = null;'
  printf '%s\n' '  let runs = [{ id: "A", state: "alarm" }, { id: "B", state: "active" }];'
  printf '%s\n' '  let plateId = "A";'
  printf '%s\n' '  const plateQueue = () => runs.filter((r) => r.state === "alarm");'
  printf '%s\n' "$ROOM_PAGE_SRC"
  cat <<'JS'
  const of = () => (roomRun() || { id: '' }).id;
  const seen = {};
  seen.plate = of();                       // no dive yet: the room follows the plate
  pinnedRun = 'A';                         // the dive pins the window it chose
  seen.pinned = of();
  plateId = 'B';                           // the plate hands over mid-hold
  seen.held = of();
  runs = [{ id: 'B', state: 'active' }];   // and the pinned run finishes mid-hold
  seen.vanished = of();
  runs = [{ id: 'A', state: 'alarm' }, { id: 'B', state: 'active' }];
  pinnedRun = '';                          // the dive is over
  seen.released = of();
  console.log(JSON.stringify(seen));
JS
} > "$ROOM_PIN"
PIN="$(node "$ROOM_PIN" 2>&1)"
pin_of() { printf '%s' "$PIN" | jq -r ".$1" 2>/dev/null; }
check "dive: with no dive up, the room is whoever holds the plate" "$(pin_of plate)" "A"
check "dive: the dive shows the run whose window it went through" "$(pin_of pinned)" "A"
check "dive: and keeps showing it when the plate hands over mid-hold" "$(pin_of held)" "A"
check "dive: a pinned run that finishes mid-hold falls back to the plate" \
  "$(pin_of vanished)" "B"
check "dive: and the plate has the room back once the dive is over" \
  "$(pin_of released)" "B"
grep_ok "$DIRECTOR_SRC" 'const dived = plateId;' \
  "dive: the run is read once, where the window is chosen"

ROOM_HOLD="$(sed -n 's/^  const ROOM_MIN = \([0-9]*\), ROOM_MAX = \([0-9]*\);.*/\1 \2/p' "$SRC/wall/wall.js")"
if [ -n "$ROOM_HOLD" ] && awk "BEGIN { split(\"$ROOM_HOLD\", h, \" \");
     exit !(h[1] >= 15000 && h[2] <= 20000 && h[1] < h[2]) }"; then
  ok "dive: the room holds fifteen to twenty seconds (${ROOM_HOLD}ms)"
else
  bad "dive: the room holds fifteen to twenty seconds (got [$ROOM_HOLD])"
fi
# The room is a canvas at the room's own scale. A push-in that scaled its pixels
# would undo the whole point of authoring it on a 320x180 grid, so it lives
# outside the stage exactly like the plate and the rain do.
inside "the room" 'id="room"' out
grep_ok "$CSS_SRC" 'image-rendering: pixelated' \
  "dive: and it is scaled by nearest neighbour, never interpolated"
grep_ok "$CSS_SRC" '.room[data-on="1"] { opacity: 1; }' \
  "dive: the wall cross-fades into it on opacity alone"

# What the room says. Run through the real file against the real fixture
# payload, because "the monitor shows the stage in one word" is a claim about
# arithmetic over a run, not about a stylesheet.
ROOM_PROBE="$ROOT/room-probe.js"
cat > "$ROOM_PROBE" <<'JS'
const fs = require("fs");
const path = require("path");
const R = require(process.argv[2]);
const api = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const CREW = JSON.parse(fs.readFileSync(path.join(process.argv[4], "wall", "crew.json"), "utf8"));
// Their things are files as well as names, so this probe reads pixels and asks
// the server's own asset guard about them: the same two instruments the sprite
// checks at the top of this suite use, rather than a second opinion on either.
const { decode, bounds } = require(process.argv[5]);
const S = require(path.join(process.argv[4], "wall", "server.js"));
const FLOORS = api.floors;
const by = (id) => api.runs.find((r) => r.id === id);
// The plate's hero, which is what a dive with no run named lands on: alarms
// first, then actives — the same queue wall.js hands the beam.
const alarms = api.runs.filter((r) => r.state === "alarm");
const hero = (alarms.length ? alarms : api.runs.filter((r) => r.state === "active"))[0];
const view = (id) => R.viewOf({ ...by(id), crew: "#e8cfa6" }, FLOORS);
const seen = view(hero.id);
const gate = view("OLYX-1660");
// Every string the room can be asked to draw, in the face that draws it — the
// feed included, which is why the small face grew punctuation: a line of code
// with the slash or the colon missing is a line nobody wrote.
const missing = [];
for (const run of api.runs) {
  const v = R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS);
  for (const ch of v.word + v.id) if (!R.BIG.rows[ch]) missing.push("BIG:" + ch);
  for (const ch of v.repo + v.owner + v.floorName) if (!R.SMALL.rows[ch]) missing.push("SMALL:" + ch);
  // The card is type too, and its words come from a markdown heading somebody
  // typed rather than from a closed vocabulary the server owns — so it is the
  // one string in this room that could arrive with a glyph in it that no face
  // has. It goes through the same probe as everything else.
  for (const ch of R.fit(R.BIG, v.id, R.CARD_ROOM)) {
    if (!R.BIG.rows[ch]) missing.push("CARD-ID:" + ch);
  }
  for (const line of v.card) {
    for (const ch of line) if (!R.SMALL.rows[ch]) missing.push("CARD:" + ch);
  }
  for (const row of v.feed) {
    for (const ch of row.text) if (!R.SMALL.rows[ch]) missing.push("FEED:" + ch);
    if (!R.MARKS[row.mark]) missing.push("MARK:" + row.mark);
  }
}
const still = [0, 1, 7.5, 3600, 86399, 1755000000.25].map((t) =>
  JSON.stringify(R.beatAt(t, true)));
const moving = [0, 1, 7.5, 3600, 86399, 1755000000.25].map((t) =>
  JSON.stringify(R.beatAt(t, false)));
const shotClock = [100, 100.75, 101.5, 102.25].map((t) => R.beatAt(t, false, 100));
const SETS = ["room", "crew/angel", "crew/emre", "crew/ran"];
const GATE = [0, 0.75, 1.5, 2.25, 3, 3.75];
// The burst schedule as it is actually realised, walked at a millisecond over
// eight super-cycles: every run of typing and every rest between them. Walked
// rather than read off the table, because a rest the arithmetic skipped would
// merge two runs into one six-second stretch and the table would still look
// right. One decimal place, because a 1 ms walk cannot see a boundary closer.
const segments = [];
{
  let on = R.burstAt(0);
  let from = 0;
  for (let ms = 1; ms <= 8 * R.BURST_CYCLE * 1000; ms++) {
    const now = R.burstAt(ms / 1000);
    if (now !== on) { segments.push([on, (ms - from) / 1000]); on = now; from = ms; }
  }
}
const spans = (working) => segments.filter((s) => s[0] === working)
  .map((s) => Number(s[1].toFixed(1)));
const burstSig = (from) => Array.from({ length: 1390 },
  (_, i) => (R.burstAt(from + i * 0.01) ? "1" : "0")).join("");
// Which frame each band of the drawn worker comes from, over every set, both
// states, and either side of the reveal override.
const bands = [];
for (const set of SETS) {
  for (let t = 0; t < 40; t += 0.017) {
    for (const alarm of [false, true]) {
      for (const typing of [false, true]) {
        bands.push({ set, ...R.bandsOf(set, R.beatAt(t, false, 0), alarm, typing) });
      }
    }
  }
}
// And every frame the body band is ever drawn from, over one long hold. `when`
// picks the seconds this asks about: the ones the schedule is working through,
// the ones it is resting through, or all of them.
const bodies = (alarm, typing, when) => {
  const seen = new Set();
  for (let t = 0; t < 40; t += 0.017) {
    const beat = R.beatAt(t, false, 0);
    if (when !== undefined && beat.burst !== when) continue;
    seen.add(R.bandsOf("room", beat, alarm, typing).body);
  }
  return [...seen].sort().join(",");
};
console.log(JSON.stringify({
  hero: hero.id,
  // A blocked run shows the alarm, not the stage it stopped on — and the floor
  // plate still says which floor that was.
  word: seen.word,
  plate: seen.floor + "/" + seen.floors + " " + seen.floorName,
  repo: seen.repo,
  owner: seen.owner,
  alarm: seen.alarm,
  // A run that is merely working says its stage in one word.
  gateWord: gate.word,
  gateAlarm: gate.alarm,
  gateActor: gate.workActorKey,
  // Nothing the room draws is missing a glyph...
  missing: missing.join(","),
  // --- the job card --------------------------------------------------------
  // WHICH ticket and WHAT IT IS, on a sheet on the wall. The words come from the
  // brief's own first heading, which the server has been shipping all along, so
  // what is checked here is the wrapping — a title is prose and the sheet is 24
  // cells of a 3x5 face.
  cardCells: R.CARD_CELLS,
  cardLines: R.CARD_LINES,
  // The card is a SECONDARY object, and that is arithmetic rather than an
  // opinion: the first attempt filled the bare wall between the window and the
  // floor plate at the plate's own height and turned the three of them into one
  // edge-to-edge row of lit rectangles. This one is held to 55 % of that area and
  // hangs UNDER the plate's band rather than beside it, so the dark central wall
  // the champion has comes back.
  cardArea: R.CARD.w * R.CARD.h,
  cardCeiling: Math.floor(R.CARD_WAS.w * R.CARD_WAS.h * R.CARD_SHARE),
  cardSecondary: R.CARD.w * R.CARD.h <= R.CARD_WAS.w * R.CARD_WAS.h * R.CARD_SHARE,
  cardBelowThePlate: R.CARD.y > R.PLATE.y + R.PLATE.h / 2,
  // And it clears the two things under it by measurement, not by eye: the
  // monitor's own halo, and the head of every person the room can seat — read
  // from the committed bases rather than from a number somebody typed.
  cardClearOfTheMonitor: R.CARD.y + R.CARD.h <= R.BEZEL.y - 3,
  cardClearOfEveryHead: (() => {
    const sets = [...new Set(Object.keys(CREW).map((o) => R.setOf(CREW, o))
      .concat(R.FALLBACK))];
    const tops = sets.map((set) => {
      const img = decode(fs.readFileSync(
        path.join(process.argv[4], "wall", R.fileOf(set, "base"))));
      return R.WORKER.y + bounds(img, 0, img.h)[1];
    });
    return R.CARD.y + R.CARD.h <= Math.min(...tops);
  })(),
  // Every run the fixtures can serve, wrapped: never more lines than the sheet
  // has, never a line wider than the sheet, and never one that overruns in
  // pixels either — the cell count and the pixel width are two different claims
  // and only the second one is what the eye sees.
  cardFits: api.runs.every((run) => {
    const v = R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS);
    return v.card.length > 0 && v.card.length <= R.CARD_LINES
      && v.card.every((line) => line.length <= R.CARD_CELLS
        && R.widthOf(R.SMALL, line) <= R.CARD_ROOM);
  }),
  // The id is in the BIG face and the sheet holds sixteen of them; an ad-hoc
  // ticket longer than that is cut the way the tube cuts, not shrunk.
  cardIdFits: api.runs.every((run) => {
    const v = R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS);
    return R.widthOf(R.BIG, R.fit(R.BIG, v.id, R.CARD_ROOM)) <= R.CARD_ROOM;
  }),
  cardLongId: R.fit(R.BIG, "ADHOC-KPI-SPARKLINES", R.CARD_ROOM),
  // What one real fixture's heading turns into, exactly.
  cardTitle: R.viewOf({ ...by("OLYX-1631"), crew: "#e8cfa6" }, FLOORS).card.join(" | "),
  // The blocked run keeps its card, and it says the ticket rather than the
  // alarm: NEEDS INPUT is the monitor's job and the red is the monitor's alone.
  cardAlarm: seen.card.join(" | "),
  // A title too long for three lines ends in the three stops the face can
  // spell, because the ellipsis a heading is written with is a glyph neither
  // face has.
  cardEllipsis: R.wrapped(R.SMALL,
    "Retire the legacy quote renderer and the invoice exporter behind it and "
    + "everything that ever called either of them", R.CARD_CELLS, R.CARD_LINES)
    .join("|"),
  // A word no line can hold is cut rather than dropped.
  cardLongWord: R.wrapped(R.SMALL, "Internationalisation", 12, 3).join("|"),
  // An accent is the same letter at three pixels of width, so it folds to the
  // letter the face has instead of leaving a hole mid-word.
  cardAccents: R.wrapped(R.SMALL, "Facturación & anexos — límites", R.CARD_CELLS,
    R.CARD_LINES).join("|"),
  // A run whose brief has no heading says which repo it is instead of showing an
  // empty sheet.
  cardNoTitle: R.viewOf({ id: "x", projectLabel: "olyxbase" }, FLOORS).card.join("|"),
  cardNoTitleNoRepo: R.viewOf({ id: "x" }, FLOORS).card.join("|"),
  // Every fixture carries a heading, so the card always has something to say.
  cardTitled: api.runs.every((run) => !!(run.title && run.title.trim())),
  // WHERE it hangs. The sheet goes in the one span of this wall that is bare:
  // right of the window frame, left of the floor plate's halo, under the conduit
  // and clear of the monitor and the head of whoever is at the desk.
  cardClearOfWindow: R.CARD.x > R.WINDOW.x + R.BOX.windowFrame.x + R.BOX.windowFrame.w,
  cardClearOfPlate: R.CARD.x + R.CARD.w < R.PLATE.x - 1,
  cardUnderTheConduit: R.CARD.y >= 24,
  cardAboveTheDesk: R.CARD.y + R.CARD.h < R.BEZEL.y,
  // And it is IN SHOT for the whole hold, not only at the top of the push: the
  // lens crops whole source pixels and its origin travels to x 39, y 15 over
  // twelve seconds, which is exactly why the card is not on the bare wall above
  // the conduit where there was more room.
  cardInShot: Array.from({ length: 201 }, (_, i) => R.cropAt(i / 200)).every((c) =>
    R.CARD.x - 1 >= c.x && R.CARD.y - 1 >= c.y
    && R.CARD.x + R.CARD.w + 1 <= c.x + c.w
    && R.CARD.y + R.CARD.h + 1 <= c.y + c.h),
  lensOrigin: (() => {
    const at = R.cropAt(1);
    return at.x + "," + at.y;
  })(),
  // The lens only ever pushes IN, which is what makes the line above a bound
  // rather than a sample: the crop origin never travels back out.
  lensNeverBacks: Array.from({ length: 201 }, (_, i) => R.cropAt(i / 200))
    .every((c, i, all) => i === 0 || (c.x >= all[i - 1].x && c.y >= all[i - 1].y)),
  // --- their things --------------------------------------------------------
  // A room is a room; a desk is somebody's. The pool is closed and lives in
  // room.js, the roster picks from it, and the three places are the same in every
  // room — so what is checked is that a hand-edited line cannot break the room
  // and that the four people are four people.
  slots: R.SLOTS.map((s) => s.key + "=" + s.plane).join(" "),
  // Every prop the pool names is a file this repo committed, and the asset route
  // will serve it: the same guard the sprites and the crew sets come down.
  propFiles: Object.values(R.PROP_ART)
    .every((art) => fs.existsSync(path.join(process.argv[4], "wall", "assets", "room", art.file))),
  propsServable: Object.values(R.PROP_ART)
    .every((art) => S.assetOf("/assets/room/" + art.file) !== ""),
  // Every prop FITS the slot its plane sends it to. Measured from the committed
  // PNGs, because the room is a flat elevation and a thing wider than the gap it
  // stands in is a thing under somebody's forearm. The slot widths are the
  // NARROWEST row of each gap, not the widest.
  propsFit: Object.entries(R.PROP_ART).map(([name, art]) => {
    const img = decode(fs.readFileSync(
      path.join(process.argv[4], "wall", "assets", "room", art.file)));
    const slot = R.SLOTS.find((s) => s.plane === art.plane);
    const worst = R.SLOTS.filter((s) => s.plane === art.plane)
      .reduce((least, s) => Math.min(least, s.wide), Infinity);
    return (img.w <= worst && img.h <= slot.tall) ? "" : name + " " + img.w + "x" + img.h;
  }).filter(Boolean).join(","),
  // And it is trimmed to its own drawing, which is what lets the room place a
  // thing by one corner instead of carrying a padding table for it.
  propsTrimmed: Object.values(R.PROP_ART).every((art) => {
    const img = decode(fs.readFileSync(
      path.join(process.argv[4], "wall", "assets", "room", art.file)));
    const box = bounds(img, 0, img.h);
    return box && box[0] === 0 && box[1] === 0 && box[2] === img.w && box[3] === img.h;
  }),
  // Who has what. Four people, four DISTINCT sets, and every one of them two or
  // three things: the point of the line in crew.json is that an owner can edit
  // their own, so this is the first assignment rather than a law.
  whoseThings: Object.keys(CREW).sort()
    .map((who) => who + "=" + R.propsOf(CREW, who).join("+")).join(" "),
  thingsDistinct: (() => {
    const sets = Object.keys(CREW).map((who) => R.propsOf(CREW, who).join("+"));
    return new Set(sets).size === sets.length;
  })(),
  thingsSized: Object.keys(CREW).every((who) => {
    const n = R.propsOf(CREW, who).length;
    return n >= 2 && n <= R.SLOTS.length;
  }),
  // Every name any owner wrote is in the pool, so no line resolves to nothing.
  thingsKnown: Object.keys(CREW)
    .every((who) => R.propsOf(CREW, who).every((name) => !!R.PROP_ART[name])),
  // A name the pool does not have is NOT A THING: it takes no place, so the slot
  // it would have filled stays empty and the room draws one fewer object.
  unknownThing: JSON.stringify(R.slotsOf(["nope", "mug"])),
  noThings: JSON.stringify(R.slotsOf([])),
  // A poster does not stand on a desk, and more things than places puts the
  // extras nowhere rather than on top of each other.
  wallThingStaysOnTheWall: JSON.stringify(R.slotsOf(["poster", "mug"])),
  tooManyThings: JSON.stringify(R.slotsOf(["mug", "books", "ball", "poster", "pennant"])),
  // A hand-edited roster cannot take the room out through the asset route or make
  // it throw: everything below is a line somebody could plausibly write wrong.
  hostileThings: JSON.stringify([
    R.slotsOf(["../../server", "assets/room/prop-mug.png", 7, null, ""]),
    R.slotsOf("mug"),
    R.propsOf({ x: { set: "room", props: "mug" } }, "x"),
    R.propsOf({ x: { set: "room" } }, "x"),
    R.propsOf(null, "x"),
    R.propsOf(CREW, null),
  ]),
  // An owner nobody drew borrows the desk of the person whose character they
  // borrowed — the entry that names the fallback set — because a room with a face
  // in it and nothing on the desk is a room somebody moved out of.
  strangerThings: R.propsOf(CREW, "nobody").join("+"),
  unownedThings: R.propsOf(CREW, "").join("+"),
  // And the view carries them per fixture owner, resolved once so the baked plane
  // redraws when the desk changes and never otherwise.
  viewThings: api.runs.map((run) =>
    run.id + "=" + R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS, CREW).props.join("/"))
    .sort().join(" "),
  // ...and no stage in the ladder is too wide for the tube it is drawn on.
  fits: FLOORS.every((name) => R.widthOf(R.BIG, name) <= 64),
  // Reduced motion is ONE frame at every second of the clock, and a lit one:
  // both lights come back at full rather than going out.
  frozen: new Set(still).size === 1,
  moves: new Set(moving).size === moving.length,
  lit: R.beatAt(0, true).glow === 1 && R.beatAt(0, true).tube === 1,
  camera: [0, 3, 6, 9, 12, 15].map((t) => R.beatAt(t, false).push).join(","),
  scan: [0, 0.75, 1.5, 2.25].map((t) => R.beatAt(t, false).scan).join(","),
  shotClock: shotClock.map((b) => b.elapsed).join(","),
  // The actor neon a worker is tinted with is the city's own, on the lock.
  tints: ["opus", "codex", "gate", "alarm"].map((k) => R.ACTOR[k]).join(","),
  onLock: Object.values(R.ACTOR).every((c) => R.LOCK.includes(c)),
  // The typing loop, sampled the way the gate samples: eight poses at 120 ms is
  // a 960 ms cycle against a 750 ms sample, so no two tiles of a six-frame
  // contact sheet catch the same pose. A loop and not a ping-pong: one full
  // cycle visits every pose once, in order, and comes back round.
  typingCadence: GATE.map((t) => R.beatAt(t, false).typing).join(","),
  typingLoops: Array.from({ length: R.TYPE_FRAMES + 1 },
    (_, i) => R.beatAt((i * R.TYPE_MS) / 1000, false).typing).join(","),
  // And it never stalls: at the cadence the hands are drawn at, every frame is
  // a different pose from the one before it, all the way round the loop.
  typingNeverStalls: Array.from({ length: 4 * R.TYPE_FRAMES },
    (_, i) => R.beatAt((i * R.TYPE_MS) / 1000, false).typing)
    .every((pose, i, all) => i === 0 || pose !== all[i - 1]),
  typingMs: R.TYPE_MS,
  typingFrames: R.TYPE_FRAMES,
  // Waiting breathes rather than flicking between two stills — eight poses at
  // 220 ms, which is the cycle the visual gate's own room shot is OF, since the
  // run it lands on is an alarm.
  waitCadence: GATE.map((t) => R.beatAt(t, false).waiting).join(","),
  waitLoops: Array.from({ length: R.WAIT_FRAMES + 1 },
    (_, i) => R.beatAt((i * R.WAIT_MS) / 1000, false).waiting).join(","),
  waitMs: R.WAIT_MS,
  // The bursts. A person types for a few seconds and then reads for half of one,
  // and the schedule that says so is arithmetic on the shot clock: pure, so two
  // recordings of the same second are the same picture, and irregular, so it is
  // not a metronome.
  burstTyping: spans(true).length
    ? Math.min(...spans(true)) + ".." + Math.max(...spans(true)) : "none",
  burstResting: spans(false).length
    ? Math.min(...spans(false)) + ".." + Math.max(...spans(false)) : "none",
  burstSegments: segments.length,
  burstDeterministic: burstSig(0) === burstSig(0) && burstSig(7.3) === burstSig(7.3),
  burstVaries: burstSig(0) !== burstSig(R.BURST_CYCLE)
    && burstSig(0) !== burstSig(2 * R.BURST_CYCLE),
  // The head pin. Every drawn worker is the set's BASE above the split and the
  // cycle's own frame below it, at every second, in both states, and whether or
  // not a line arriving on the tube has overridden the schedule. A head drawn
  // from frame N is the whole defect this run removes, and this is the probe
  // that refuses to let it back in.
  headAlwaysBase: bands.every((b) => b.head === "base"),
  headNeverACycle: bands.every((b) =>
    !R.TYPE_SET.includes(b.head) && !R.WAIT_SET.includes(b.head)),
  bandIsAFrame: bands.every((b) => R.FRAMES.includes(b.body)),
  // The split sits below the shoulders and above the hands, per set, and every
  // set has one of its own.
  splits: SETS.map((s) => s + "=" + R.splitOf(s)).join(" "),
  splitsSane: SETS.every((s) => R.splitOf(s) >= 38 && R.splitOf(s) <= 46),
  // Which frames the body band is ever drawn from: the whole typing cycle while
  // working, the whole waiting cycle in an alarm, and the base itself — hands on
  // the keys, still — while the person is resting between bursts.
  workingBodies: bodies(false, false, true),
  restingBodies: bodies(false, false, false),
  revealBodies: bodies(false, true, false),
  alarmBodies: bodies(true, false),
  // The push only ever goes in. A lens that eased back, even by a rounding
  // error, is the cut the whole shot exists to avoid.
  pushNeverBacks: (() => {
    let last = -1;
    for (let t = 0; t <= 24; t += 0.05) {
      const p = R.beatAt(t, false).push;
      if (p < last - 1e-9) return false;
      last = p;
    }
    return true;
  })(),
  // Who is at the desk, in colour. The server preserves the work actor while
  // actorKey becomes the wide city's alarm light, so the room consumes domain
  // attribution instead of duplicating the floor ladder. Never stone, never red.
  blockedActor: seen.workActorKey,
  blockedTint: R.tintOf(seen),
  workingTint: R.tintOf(gate),
  blockedNotAlarm: R.tintOf(seen) !== R.ACTOR.alarm,
  everyWorkerIsAnActor: api.runs.every((run) => {
    const tint = R.tintOf(R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS));
    return Object.values(R.ACTOR).includes(tint);
  }),
  // --- the tube ------------------------------------------------------------
  // The log fits: four rows of the small face under the stage word, a row of air,
  // and the two rows the progress ticks need, all inside the tube.
  tubeRows: R.FEED_TOP + (R.FEED_ROWS - 1) * R.FEED_PITCH + R.SMALL.h < R.FEED_TICKS
    && R.FEED_TICKS + 2 <= R.SCREEN.h,
  // And sixteen characters plus the source mark fit across it, exactly.
  tubeCells: R.FEED_CELLS,
  tubeWidth: R.FEED_MARK + 1 + R.widthOf(R.SMALL, "X".repeat(R.FEED_CELLS)) <= R.SCREEN.w,
  tubeSpare: R.SCREEN.w - (R.FEED_MARK + 1 + R.widthOf(R.SMALL, "X".repeat(R.FEED_CELLS))),
  // A full line's cursor asks for the cell one past the right edge, which is the
  // bezel. There is exactly one column of the tube no glyph reaches, and it is
  // where the cursor is held instead.
  caretFits: R.FEED_MARK + 1 + (R.FEED_CELLS - 1) * R.SMALL.pitch + R.SMALL.w
    < R.SCREEN.w,
  // Every character a feed line can be cut to has a glyph, including the whole
  // punctuation set code is written in.
  punctuation: "{}()[]=;:+_,<>'\"#*!?|@-./ ".split("")
    .filter((ch) => !R.SMALL.rows[ch]).join(""),
  // A mark is not a letter, and it must not be able to be read as one: the
  // reviewer's line often opens with `+` or `-`, so neither mark may be the same
  // shape as any glyph the small face can draw.
  markIsNotAGlyph: Object.values(R.MARKS).every((shape) =>
    !Object.values(R.SMALL.rows).some((glyph) => glyph.join('/') === shape.join('/'))),
  marks: Object.keys(R.MARKS).sort().join(","),
  // Both faces and both marks are on their own grid, to the character.
  faceGrid: [[R.BIG, 5, 7], [R.SMALL, 3, 5]].every(([face, w, h]) =>
    Object.values(face.rows).every((g) =>
      g.length === h && g.every((line) => new RegExp("^[#.]{" + w + "}$").test(line))))
    && Object.values(R.MARKS).every((g) =>
      g.length === 5 && g.every((line) => /^[#.]{3}$/.test(line))),
  // The ink the four rows are drawn in is a cold ramp and nothing else: red is
  // an alarm in this palette and green is a run that shipped, so neither may
  // appear in a log line — a diff hunk's minus and plus are text.
  inkOnLock: R.FEED_INK.every((colour) => R.LOCK.includes(colour)),
  inkMeansNothing: R.FEED_INK.every((colour) =>
    !["#ff2f45", "#3fd984", "#4ff08f", "#2c9a61", "#9fe8b8"].includes(colour)),
  inkSteps: R.FEED_INK.join(","),
  // What the room makes of a real feed line: the source glyph off the front and
  // into a mark, a path down to the name that matters, and the whole thing in the
  // one face the tube has.
  feedLines: R.viewOf({ ...by("OLYX-1631"), crew: "#e8cfa6" }, FLOORS).feed
    .slice(-2).map((row) => row.mark + " " + row.text).join(" | "),
  feedCodex: R.viewOf({ ...by("OLYX-1655"), crew: "#e8cfa6" }, FLOORS).feed
    .slice(-1).map((row) => row.mark + " " + row.text).join(""),
  // The display is only sixteen cells, but its truncated text is not a line's
  // identity. Patch lines often share a timestamp, source and long prefix; both
  // still have to reach the scroll queue.
  feedIdentity: (() => {
    const first = R.lineOf({ t: "05:04:15", src: "codex",
      text: "+  const sharedPrefix = firstValue;" });
    const second = R.lineOf({ t: "05:04:15", src: "codex",
      text: "+  const sharedPrefix = secondValue;" });
    return first.text === second.text && R.keyOf(first) !== R.keyOf(second);
  })(),
  // A run with no feed.log at all is a screen with a word and a cursor on it,
  // never a black tube and never a stale line.
  feedEmpty: JSON.stringify(R.viewOf({ id: "x" }, FLOORS).feed),
  feedNeverOverflows: api.runs.every((run) =>
    R.viewOf({ ...run, crew: "#e8cfa6" }, FLOORS).feed
      .every((row) => R.widthOf(R.SMALL, row.text) <= R.FEED_W)),
  // The reveal. Pure arithmetic on how long ago a line landed, so no character
  // can appear before its own second: nothing at all at the moment it lands,
  // never more than the line has, monotonic in between, and complete at the
  // rate the constant says.
  revealStartsEmpty: R.revealed(16, 0) === 0,
  revealNeverEarly: (() => {
    let last = 0;
    for (let ms = 0; ms <= 2000; ms++) {
      const at = R.revealed(16, ms / 1000);
      if (at < last || at > 16 || at > Math.ceil((ms / 1000) * R.REVEAL_CPS)) return false;
      last = at;
    }
    return last === 16;
  })(),
  revealCps: R.REVEAL_CPS,
  scrollMs: R.SCROLL_MS,
  blinkMs: R.BLINK_MS,
  // And every sprite the room asks for is a file that was committed: the
  // furniture, plus the base and both eight-frame cycles for every set on the
  // roster and the fallback.
  sprites: Object.keys(R.PROPS)
    .map((k) => "assets/room/" + R.PROPS[k])
    .concat([...new Set(Object.keys(CREW).map((o) => R.setOf(CREW, o)).concat(R.FALLBACK))]
      .flatMap((set) => R.FRAMES.map((f) => R.fileOf(set, f))))
    .every((rel) => fs.existsSync(path.join(process.argv[4], "wall", rel))),
  // Whose character the room draws, per fixture owner. This is the run: a
  // dive is supposed to land on the person who dispatched it, not on one
  // hooded figure standing in for all of them.
  whose: api.runs.map((run) => run.id + "=" + R.setOf(CREW, run.owner)).sort().join(" "),
  // The lane key is lower-cased on the way in, the way crewTint has always
  // done it, and an owner nobody drew — or none at all — is the room worker.
  shouty: R.setOf(CREW, "ANGEL"),
  padded: R.setOf(CREW, "  Emre  "),
  stranger: R.setOf(CREW, "nobody"),
  unowned: R.setOf(CREW, ""),
  // A hand-edited crew.json cannot take the room out through the asset route.
  hostile: ["../../server", "crew/angel/../..", "", 7].map((set) =>
    R.setOf({ x: { set } }, "x")).join(","),
  // The plate says the name crew.json spells, and falls back to the run dir.
  named: R.labelOf(CREW, R.viewOf({ owner: "ran" }, FLOORS)),
  unnamed: R.labelOf(CREW, R.viewOf({ owner: "nobody" }, FLOORS)),
}));
JS
ROOM="$(node "$ROOM_PROBE" "$SRC/wall/room.js" "$ROOT/api.json" "$SRC" "$PNG_JS" 2>&1)"
room_of() { printf '%s' "$ROOM" | jq -r ".$1" 2>/dev/null; }
check "room: the dive lands on the run the plate is pinned to" "$(room_of hero)" "OLYX-1642"
check "room: a blocked run's monitor asks for a human" "$(room_of word)" "NEEDS INPUT"
check "room: and its wall plate still says which floor that is" \
  "$(room_of plate)" "1/6 IMPLEMENT"
check "room: the repo is named"  "$(room_of repo)" "OLYXBASE"
check "room: so is the dispatcher" "$(room_of owner)" "REINIER"
check "room: a working run gets its stage in one word" "$(room_of gateWord)" "GATE"
check "room: and is not drawn as an alarm" "$(room_of gateAlarm)" "false"
check "room: the worker is the actor that owns the stage" "$(room_of gateActor)" "gate"
check "room: nothing it draws is missing a glyph" "$(room_of missing)" ""
check "room: no stage in the ladder overruns the tube" "$(room_of fits)" "true"

# The job card. The room said which stage, which floor and who; it never said
# WHICH TICKET or WHAT THE JOB IS, which is the one question somebody on the sofa
# could not answer about a person they could see working. The words are the
# brief's own first heading — the server has shipped it all along — so what is
# checked here is the wrapping, the cutting, and where the sheet hangs.
check "card: the sheet holds twenty-one cells of the small face" \
  "$(room_of cardCells)" "21"
check "card: and the title never runs past two lines" "$(room_of cardLines)" "2"
check "card: every run in the city wraps inside it, in cells and in pixels" \
  "$(room_of cardFits)" "true"
check "card: the ticket fits the big face, whatever it is called" \
  "$(room_of cardIdFits)" "true"
check "card: an ad-hoc id is cut rather than shrunk" \
  "$(room_of cardLongId)" "ADHOC-KPI-SPA."
check "card: a real heading reads as the sentence somebody wrote" \
  "$(room_of cardTitle)" "INVOICE EXPORT | ENDPOINT - CSV + XLSX"
check "card: a blocked run keeps its card, and it says the job" \
  "$(room_of cardAlarm)" "RETIRE THE LEGACY | QUOTE PDF RENDERER"
check "card: a heading too long for the sheet ends in three stops" \
  "$(room_of cardEllipsis)" \
  "RETIRE THE LEGACY|QUOTE RENDERER AND..."
check "card: a word no line can hold is cut, not dropped" \
  "$(room_of cardLongWord)" "INTERNATION."
check "card: an accent folds to the letter the face has" \
  "$(room_of cardAccents)" "FACTURACION ANEXOS -|LIMITES"
check "card: a run with no heading says which repo it is" \
  "$(room_of cardNoTitle)" "OLYXBASE"
check "card: and one with neither still has a sheet with something on it" \
  "$(room_of cardNoTitleNoRepo)" "UNCHARTED"
check "card: every committed fixture carries a heading to put on it" \
  "$(room_of cardTitled)" "true"
check "card: it hangs clear of the window frame" \
  "$(room_of cardClearOfWindow)" "true"
check "card: clear of the floor plate" "$(room_of cardClearOfPlate)" "true"
check "card: it is secondary, at 55 % of the area the first one took" \
  "$(room_of cardSecondary)" "true"
check "card: which is $(room_of cardArea) px against a ceiling of $(room_of cardCeiling)" \
  "$(room_of cardSecondary)" "true"
check "card: it hangs under the floor plate's band, not beside it" \
  "$(room_of cardBelowThePlate)" "true"
check "card: clear of the monitor's own halo" \
  "$(room_of cardClearOfTheMonitor)" "true"
check "card: and above the head of every person the room can seat" \
  "$(room_of cardClearOfEveryHead)" "true"
check "card: and it is in shot at every second of the push, not only the first" \
  "$(room_of cardInShot)" "true"
check "card: which is a bound because the lens crop only ever travels in" \
  "$(room_of lensNeverBacks)" "true"
check "card: to x 39, y 15 by the end of the hold" "$(room_of lensOrigin)" "39,15"

# The card carries no state at all: an alarm keeps it exactly as it is, because
# the ticket is the thing you most need when the screen says NEEDS INPUT and the
# red belongs to the monitor. Checked as structure, because "it never turns red"
# is a claim about what is NOT in the function.
CARD_FN="$(awk '/^    function jobCard\(v\) \{/, /^    \}$/' "$SRC/wall/room.js")"
CARD_CODE="$(printf '%s\n' "$CARD_FN" | grep -v '^ *//')"
grep_ok "$CARD_FN" 'box(CARD.x, CARD.y, CARD.w, CARD.h, BOARD);' \
  "card: the sheet is the palette's one warm mid-value"
grep_not "$CARD_CODE" 'alarm' "card: nothing on it depends on the alarm"
grep_not "$CARD_CODE" 'ALARM' "card: and the klaxon red is never drawn on it"
grep_not "$CARD_CODE" 'v.crew' "card: nor the crew tint, which belongs to the lamp"
grep_ok "$(cat "$SRC/wall/room.js")" '        jobCard(v);' \
  "card: and it is baked with the still planes, not redrawn every frame"

# Their things. Four rooms with four faces in them were still four copies of one
# room. The pool is closed and lives in room.js, wall/crew.json says who owns
# what, and there are three places — so what is checked is that a hand-edited
# line cannot break the room, that every prop fits the gap it stands in, and that
# the four people read as four people.
check "things: three places, the same three in every room" \
  "$(room_of slots)" "deskWarm=desk deskCold=desk wall=wall"
check "things: every one in the pool is a file this repo committed" \
  "$(room_of propFiles)" "true"
check "things: and one the asset route will actually serve" \
  "$(room_of propsServable)" "true"
check "things: every one fits the narrowest row of its own gap" \
  "$(room_of propsFit)" ""
check "things: and is trimmed to its own drawing, so there is no padding table" \
  "$(room_of propsTrimmed)" "true"
check "things: who has what, as crew.json first assigned it" \
  "$(room_of whoseThings)" \
  "angel=mug+cactus+poster emre=ball+pennant ran=photo+mug reinier=figurine+books"
check "things: four people, four different sets" "$(room_of thingsDistinct)" "true"
check "things: two or three each, never more places than there are" \
  "$(room_of thingsSized)" "true"
check "things: and every name any of them wrote is in the pool" \
  "$(room_of thingsKnown)" "true"
check "things: a name the pool does not have leaves its place empty" \
  "$(room_of unknownThing)" '["mug","",""]'
check "things: an owner with no things has an empty desk, not a crash" \
  "$(room_of noThings)" '["","",""]'
check "things: a poster does not stand on a desk" \
  "$(room_of wallThingStaysOnTheWall)" '["mug","","poster"]'
check "things: more things than places puts the extras nowhere" \
  "$(room_of tooManyThings)" '["mug","books","poster"]'
check "things: nothing a hand-edited roster can say reaches the asset route" \
  "$(room_of hostileThings)" \
  '[["","",""],["","",""],[],[],[],["figurine","books"]]'
check "things: an owner nobody drew borrows the desk they borrowed the face from" \
  "$(room_of strangerThings)" "figurine+books"
check "things: and so does a run with no owner at all" \
  "$(room_of unownedThings)" "figurine+books"
check "things: and the view carries them per run, so the plane rebakes on a swap" \
  "$(room_of viewThings)" \
  "BOT-2287=figurine/books/ BOT-2291=figurine/books/ LEGACY-0042=figurine/books/ OLYX-1598=ball//pennant OLYX-1631=mug/cactus/poster OLYX-1642=figurine/books/ OLYX-1648=figurine/books/ OLYX-1655=mug/cactus/poster OLYX-1660=mug/cactus/poster OLYX-1667=photo/mug/ OLYX-1673=ball//pennant adhoc-kpi-sparklines=mug/cactus/poster"

# Nothing on the desk may cross the forearms or the keyboard, and the way that is
# guaranteed is an ORDER rather than a measurement: their things are the last
# thing baked into the middle plane, and the worker is drawn over that plane every
# frame. A prop cannot be in front of a hand it is drawn behind.
ROOM_ALL="$(cat "$SRC/wall/room.js")"
grep_ok "$ROOM_ALL" '        theirThings(v);' \
  "things: they are baked with the still planes, not redrawn every frame"
grep_ok "$ROOM_ALL" '      worker(view, beat, revealing());' \
  "things: and the worker is drawn over that plane, so nothing crosses a forearm"
THING_FN="$(awk '/^    function thing\(slot, name\) \{/, /^    \}$/' "$SRC/wall/room.js")"
THING_CODE="$(printf '%s\n' "$THING_FN" | grep -v '^ *//')"
grep_ok "$THING_CODE" 'edge(slot.warm, GLOW, 0.24);' \
  "things: lit warm on the side the lamp is on"
grep_ok "$THING_CODE" 'edge(slot.cold, CYAN, 0.16);' \
  "things: and cold on the side the tube is"
grep_not "$THING_CODE" 'v.crew' \
  "things: never in the crew tint, which the wide city gives to the lamp"
grep_not "$THING_CODE" 'ALARM' "things: and never in the alarm's red"
check "room: reduced motion is one frame at every second of the clock" \
  "$(room_of frozen)" "true"
check "room: and the same room without it genuinely moves" "$(room_of moves)" "true"
check "room: a still room is a LIT room standing still" "$(room_of lit)" "true"
check "room: the camera pushes in one direction and holds without a cut" \
  "$(room_of camera)" "0,0.25,0.5,0.75,1,1"
check "room: the CRT retrace travels down on the gate clock" \
  "$(room_of scan)" "-4,-1,2,5"
check "room: that gate clock starts with the shot, not the server epoch" \
  "$(room_of shotClock)" "0,0.75,1.5,2.25"
check "room: the worker's tint is the city's own actor neon" \
  "$(room_of tints)" "#4c9dff,#3fd984,#e0a23c,#ff2f45"
check "room: every one of them is on the palette lock" "$(room_of onLock)" "true"
check "room: the typing hands land on a different pose in every gate frame" \
  "$(room_of typingCadence)" "0,6,4,2,1,7"
check "room: and never repeat one frame to the next, all the way round" \
  "$(room_of typingNeverStalls)" "true"
check "room: the hands loop rather than ping-pong" \
  "$(room_of typingLoops)" "0,1,2,3,4,5,6,7,0"
check "room: eight poses is the loop" "$(room_of typingFrames)" "8"
# 100-130 ms per pose is 8-10 poses a second, which is where a hand starts
# reading as a hand instead of as a slideshow.
if [ "$(room_of typingMs)" -ge 100 ] && [ "$(room_of typingMs)" -le 130 ]; then
  ok "room: at a hand's own cadence ($(room_of typingMs) ms a pose)"
else
  bad "room: at a hand's own cadence (got $(room_of typingMs) ms a pose)"
fi
check "room: waiting breathes on eight poses, one per gate sample" \
  "$(room_of waitCadence)" "0,3,6,2,5,1"
check "room: and its breath comes round rather than reversing" \
  "$(room_of waitLoops)" "0,1,2,3,4,5,6,7,0"
if [ "$(room_of waitMs)" -ge 180 ] && [ "$(room_of waitMs)" -le 250 ]; then
  ok "room: slower than the hands, as a breath is ($(room_of waitMs) ms a pose)"
else
  bad "room: slower than the hands, as a breath is (got $(room_of waitMs) ms)"
fi

# The bursts. A person types for a few seconds and then reads for half of one,
# and the schedule that says so has to be arithmetic on the shot clock: a
# recording of the same second has to be the same picture, which is why there is
# no random draw in it and no schedule dealt once at create().
check "room: typing comes in runs of two to four seconds" \
  "$(room_of burstTyping)" "2..3.6"
check "room: with a rest of under a second between them" \
  "$(room_of burstResting)" "0.4..1"
check "room: and the schedule is the same schedule every time it is asked" \
  "$(room_of burstDeterministic)" "true"
check "room: while not being the same bar over and over" \
  "$(room_of burstVaries)" "true"

# The head pin — the whole point of the run. Every drawn worker is the set's base
# above the split and the cycle's own frame below it, at every second of the
# clock, in both states, and whether or not a line arriving on the tube has
# overridden the burst schedule.
check "room: the head, hood and shoulders come from the base at every frame" \
  "$(room_of headAlwaysBase)" "true"
check "room: and never from a frame of either cycle" \
  "$(room_of headNeverACycle)" "true"
check "room: the band under the split is a frame the room loaded" \
  "$(room_of bandIsAFrame)" "true"
check "room: every set is cut at its own row, below the shoulders" \
  "$(room_of splits)" "room=41 crew/angel=41 crew/emre=43 crew/ran=40"
check "room: and no cut lands outside the jacket" "$(room_of splitsSane)" "true"
check "room: a working worker's hands are the whole typing cycle" \
  "$(room_of workingBodies)" "type8-0,type8-1,type8-2,type8-3,type8-4,type8-5,type8-6,type8-7"
check "room: a resting one holds the base — hands on the keys, still" \
  "$(room_of restingBodies)" "base"
check "room: unless a line is arriving, and then they are typing it" \
  "$(room_of revealBodies)" "type8-0,type8-1,type8-2,type8-3,type8-4,type8-5,type8-6,type8-7"
check "room: a blocked one breathes through the whole waiting cycle" \
  "$(room_of alarmBodies)" "wait8-0,wait8-1,wait8-2,wait8-3,wait8-4,wait8-5,wait8-6,wait8-7"

# What the tube says. Four rows of the run's own feed.log, in the one face the
# room has, with the punctuation code is written in.
check "room: four rows of feed and the progress ticks fit the tube" \
  "$(room_of tubeRows)" "true"
check "room: sixteen characters and a source mark fit across it" \
  "$(room_of tubeWidth)" "true"
check "room: which is what a 68 px tube holds at a four-pixel advance" \
  "$(room_of tubeCells)" "16"
check "room: with one pixel of the tube to spare" "$(room_of tubeSpare)" "1"
check "room: which is the column the cursor is held in on a full line" \
  "$(room_of caretFits)" "true"
check "room: the small face carries the whole punctuation set code needs" \
  "$(room_of punctuation)" ""
check "room: and every glyph of both faces is on its own grid" \
  "$(room_of faceGrid)" "true"
check "room: there are two source marks and no more" "$(room_of marks)" "diamond,dot"
check "room: and neither can be misread as a character of the face" \
  "$(room_of markIsNotAGlyph)" "true"
check "room: the log's ink is a cold ramp on the lock" "$(room_of inkOnLock)" "true"
check "room: none of it means alarm or shipped" "$(room_of inkMeansNothing)" "true"
check "room: older lines step back down that ramp" \
  "$(room_of inkSteps)" "#525852,#79907e,#96c3c8,#deeaee"
# The last two lines of OLYX-1631's feed.log are a thought and an edit:
#   "🧠 The XLSX golden file wants the amounts as numbers, not strings"
#   "⏺ Edit src/invoices/export.ts"
# The glyph comes off the front and becomes the mark; the path collapses to the
# file name, which is the part somebody three metres away needs; the sentence is
# cut where it stops fitting, with the space before the stop taken out.
check "room: a tool call reads as what it touched, with the implementer's mark" \
  "$(room_of feedLines)" \
  "dot THE XLSX GOLDEN. | dot EDIT EXPORT.TS"
check "room: and the reviewer's line wears the reviewer's" \
  "$(room_of feedCodex)" "diamond RE-RUNNING THE."
check "room: truncated lookalikes remain distinct lines in the scroll queue" \
  "$(room_of feedIdentity)" "true"
check "room: a run with no feed at all leaves the tube with nothing to say" \
  "$(room_of feedEmpty)" "[]"
check "room: no line the fixtures can produce overruns the tube" \
  "$(room_of feedNeverOverflows)" "true"
check "room: the newest line shows nothing at the moment it lands" \
  "$(room_of revealStartsEmpty)" "true"
check "room: and never a character before its own second" \
  "$(room_of revealNeverEarly)" "true"
if [ "$(room_of revealCps)" -ge 25 ] && [ "$(room_of revealCps)" -le 30 ]; then
  ok "room: it arrives at a typing speed ($(room_of revealCps) chars/s)"
else
  bad "room: it arrives at a typing speed (got $(room_of revealCps) chars/s)"
fi
check "room: the screen scrolls by rows, a row every 120 ms" \
  "$(room_of scrollMs)" "120"
check "room: and the cursor blinks on a terminal's own interval" \
  "$(room_of blinkMs)" "530"

check "room: the lens never eases back, at any second of the hold" \
  "$(room_of pushNeverBacks)" "true"
check "room: a blocked worker wears the neon of the floor work stopped on" \
  "$(room_of blockedTint)" "#4c9dff"
check "room: a working one wears their own" "$(room_of workingTint)" "#e0a23c"
check "room: blocked actor attribution comes from the run snapshot" \
  "$(room_of blockedActor)" "opus"
check "room: the alarm red is for the monitor, never for the jacket" \
  "$(room_of blockedNotAlarm)" "true"
check "room: every run in the city puts an actor at that desk" \
  "$(room_of everyWorkerIsAnActor)" "true"
check "room: and every sprite it asks for is one this repo committed" \
  "$(room_of sprites)" "true"

# The one fact in this room that is about a human rather than about the work.
# The dive is supposed to land on whoever dispatched the run, so this is asked
# of the real chooser over the real fixture payload — a hard-coded expectation
# per run id, because "the room picks a set" is not the claim; "it picks THAT
# person's set" is.
check "crew: the room draws the owner of the run, not one figure for all of them" \
  "$(room_of whose)" \
  "BOT-2287=room BOT-2291=room LEGACY-0042=room OLYX-1598=crew/emre OLYX-1631=crew/angel OLYX-1642=room OLYX-1648=room OLYX-1655=crew/angel OLYX-1660=crew/angel OLYX-1667=crew/ran OLYX-1673=crew/emre adhoc-kpi-sparklines=crew/angel"
check "crew: ANGEL and angel are one crew member" "$(room_of shouty)" "crew/angel"
check "crew: and so are Emre and the spaces around him" "$(room_of padded)" "crew/emre"
check "crew: an owner nobody drew gets the room's own worker" "$(room_of stranger)" "room"
check "crew: so does a run with no owner at all" "$(room_of unowned)" "room"
check "crew: a set name the asset route would refuse never gets asked for" \
  "$(room_of hostile)" "room,room,room,room"
check "crew: the plate says the name crew.json spells" "$(room_of named)" "RAN"
check "crew: and keeps the run dir's own when there is no entry" \
  "$(room_of unnamed)" "NOBODY"

# The room's clock. rAF timestamps only ever go forward; Date.now() plus the
# server skew is re-measured on every snapshot and steps in both directions,
# which is what turned a twelve-second push into a jump cut half way through a
# six-frame contact sheet. So the room is handed no clock at all.
ROOM_SRC="$(cat "$SRC/wall/room.js")"
ROOM_CODE="$(grep -v '^ *//' "$SRC/wall/room.js")"
grep_not "$ROOM_CODE" 'Date.now' "room: nothing in here reads the wall clock"
grep_not "$ROOM_CODE" 'skew'     "room: nor the server skew that moves under it"
grep_ok "$ROOM_SRC" 'paint(ts / 1000);' \
  "room: the loop draws at the timestamp rAF hands it"
grep_ok "$ROOM_SRC" 'cancelAnimationFrame(raf);' \
  "room: and a stopped room cancels the frame it had already queued"
grep_ok "$PAGE_SRC" 'Room.create({ canvas: roomCanvas, still, random: seededRandom });' \
  "room: the page hands it a canvas and a seed, and no clock"
# The still planes are drawn once per run rather than at the display's refresh:
# the wall, the window, the plate, the floor and the desk are facts about a run,
# and forty rectangles of wall grain a frame is work with no picture in it.
grep_ok "$ROOM_SRC" 'function bakePlanes(v) {' \
  "room: the still planes are baked, not redrawn every frame"
for plane in plateBack plateMid plateFront; do
  grep_ok "$ROOM_SRC" "ctx.drawImage($plane, 0, 0);" "room: and $plane is composited in"
done
# The klaxon red thinned over a blue-black floor is not red light on night, it
# is violet: the shipped room's two floor slabs measured hue 318 and 277. The
# floor takes the palette's own deep red, banded; the bright one stays on the
# tube, which is the thing raising the alarm.
grep_ok "$ROOM_SRC" 'const cast = v.alarm ? RUST : CYAN;' \
  "room: the alarm's light on the floor is a deep red, not a thinned klaxon"
grep_ok "$ROOM_SRC" 'const tint = v.alarm ? ALARM : CYAN;' \
  "room: and the klaxon red itself belongs to the monitor"

# The route the sprites come down. A directory route is the path traversal this
# server has never had, so the fence is checked from both sides: the real
# function over the paths an attacker would try, and the running server over the
# ones a browser would send.
GUARD="$(node -e '
  const S = require(process.argv[1]);
  const path = require("path");
  const inside = (u) => { const f = S.assetOf(u); return f ? path.relative(S.ASSETS, f) : ""; };
  console.log(JSON.stringify({
    plain: inside("/assets/room/worker-type-0.png"),
    up: inside("/assets/../server.js"),
    deep: inside("/assets/room/../../server.js"),
    encoded: inside("/assets/%2e%2e/server.js"),
    doubled: inside("/assets/%252e%252e/server.js"),
    absolute: inside("/assets//etc/passwd"),
    tilde: inside("/assets/~/.ssh/id_rsa"),
    markdown: inside("/assets/MANIFEST.md"),
    script: inside("/assets/room/evil.js"),
    naked: inside("/assets/room/"),
    dotfile: inside("/assets/.git/config"),
    elsewhere: inside("/wall.css"),
  }));
' "$SRC/wall/server.js" 2>&1)"
guard_of() { printf '%s' "$GUARD" | jq -r ".$1" 2>/dev/null; }
check "assets: a plain sprite path resolves under wall/assets" \
  "$(guard_of plain)" "room/worker-type-0.png"
for probe in up deep encoded doubled absolute tilde markdown script naked dotfile elsewhere; do
  check "assets: [$probe] is refused by the guard" "$(guard_of "$probe")" ""
done
check "assets: the room's sprites are served" \
  "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/assets/room/worker-type-0.png")" "200"
check "assets: and so is every crew set the roster names" \
  "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/assets/crew/ran/type-0.png")" "200"
# The roster is its own route, not an asset: the room fetches it before it
# decides which sprites to ask for at all.
check "crew: the roster is served as json" \
  "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$PORT/crew.json")" \
  "application/json; charset=utf-8"
check "crew: and it is the roster this repo committed" \
  "$(curl -s "http://127.0.0.1:$PORT/crew.json" | jq -r '[.angel.set, .reinier.set] | join(",")')" \
  "crew/angel,room"
check "assets: as image/png" \
  "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$PORT/assets/room/worker-type-0.png")" \
  "image/png"
# Over the wire, only the paths a client will actually transmit: curl collapses
# a literal `..` before it sends, so the raw-traversal cases are the probe's
# above — this half proves the guard is wired into the server at all, and that
# the manifest and the directory itself are not readable through it.
for hostile in /assets/%2e%2e/server.js /assets/MANIFEST.md /assets/room/ \
               /assets/room/nope.png /assets/room/wall.js; do
  check "assets: [$hostile] 404s" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$hostile")" "404"
done

# The way out of a directory that has no `..` in it. A symlink is an ordinary
# segment with an ordinary extension whose contents are somewhere else, so the
# fence has to ask the filesystem and not only the string — checked against a
# throwaway copy of wall/, because the committed tree is only ever read.
FENCE="$ROOT/fence"
mkdir -p "$FENCE"
cp "$SRC/wall.sh" "$FENCE/wall.sh"
cp -R "$SRC/wall" "$FENCE/wall"
printf 'the private key\n' > "$ROOT/outside.txt"
ln -s "$ROOT/outside.txt" "$FENCE/wall/assets/room/escape.png"
ln -s "$FENCE/wall/assets/room" "$FENCE/wall/assets/shortcut"
printf '{"room":"ok"}\n' > "$FENCE/wall/assets/room/probe.json"
FENCE_GUARD="$(node -e '
  const S = require(process.argv[1]);
  const path = require("path");
  const inside = (u) => { const f = S.assetOf(u); return f ? path.relative(S.ASSETS, f) : ""; };
  console.log(JSON.stringify({
    escape: inside("/assets/room/escape.png"),
    through: inside("/assets/shortcut/probe.json"),
    json: inside("/assets/room/probe.json"),
  }));
' "$FENCE/wall/server.js" 2>&1)"
fence_of() { printf '%s' "$FENCE_GUARD" | jq -r ".$1" 2>/dev/null; }
check "assets: a symlink pointing out of wall/assets is refused" "$(fence_of escape)" ""
check "assets: an in-root symlink resolves to the canonical asset" \
  "$(fence_of through)" "room/probe.json"
check "assets: a committed .json under wall/assets still resolves" \
  "$(fence_of json)" "room/probe.json"
bash "$FENCE/wall.sh" --runs "$RUNS" --host 127.0.0.1 --port 0 --city "$ROOT/fence-city.jsonl" \
  > "$ROOT/fence.log" 2>&1 &
PIDS="$PIDS $!"
FENCE_PORT=''
tries=0
while [ "$tries" -lt 100 ]; do
  FENCE_PORT=$(sed -n 's|.*http://[^:]*:\([0-9][0-9]*\)/.*|\1|p' "$ROOT/fence.log" 2>/dev/null | head -1)
  [ -n "$FENCE_PORT" ] && break
  sleep 0.1
  tries=$((tries + 1))
done
if [ -z "$FENCE_PORT" ]; then
  bad "assets: the fenced copy of the wall starts"
else
  ok "assets: the fenced copy of the wall starts"
  check "assets: the server refuses the symlink too" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FENCE_PORT/assets/room/escape.png")" "404"
  check "assets: a .json asset is served as JSON" \
    "$(curl -s -o /dev/null -w '%{content_type}' "http://127.0.0.1:$FENCE_PORT/assets/room/probe.json")" \
    "application/json; charset=utf-8"
fi

# A set that is not there. `crew/angl` passes every syntax check `crew/angel`
# does, so a roster taken at its word would have the room ask for six sprites
# that do not exist, take six 404s, and hold an empty chair — one typo in a
# hand-edited file costing the whole room its worker. The server is what
# settles it: every frame goes through the asset guard before the roster is
# served, and an entry that does not survive keeps its owner's name and gets the
# room's own worker. Asked of a THIRD throwaway tree, because proving it needs a
# broken crew.json and a half-deleted set, and the committed tree is only read.
GHOST="$ROOT/ghost"
mkdir -p "$GHOST"
cp "$SRC/wall.sh" "$GHOST/wall.sh"
cp -R "$SRC/wall" "$GHOST/wall"
cat > "$GHOST/wall/crew.json" <<'JSON'
{
  "angel": { "set": "crew/angel", "label": "ANGEL" },
  "typo": { "set": "crew/angl", "label": "TYPO" },
  "gutted": { "set": "crew/ran", "label": "GUTTED" },
  "reinier": { "set": "room", "label": "REINIER" }
}
JSON
# `gutted` names a set that exists and is one frame short of complete, which is
# what a half-finished commit looks like and what a directory listing alone
# would wave through. The frame removed is one the room actually asks for — the
# set still has its old four-and-two on the disk, and a check that took those for
# the set would wave this through too.
rm "$GHOST/wall/assets/crew/ran/wait8-7.png"
GHOST_ROSTER="$(node -e '
  const S = require(process.argv[1]);
  const R = require(process.argv[2]);
  const served = S.roster();
  console.log(JSON.stringify({
    // What goes over the wire says what the room will actually draw...
    whole: served.angel.set,
    typo: served.typo.set,
    gutted: served.gutted.set,
    // ...and the names survive losing the faces.
    labels: [served.typo.label, served.gutted.label].join(","),
    // ...which is what the room then picks, for real.
    draws: [R.setOf(served, "typo"), R.setOf(served, "gutted")].join(","),
  }));
' "$GHOST/wall/server.js" "$GHOST/wall/room.js" 2>&1)"
ghost_of() { printf '%s' "$GHOST_ROSTER" | jq -r ".$1" 2>/dev/null; }
check "crew: a set that is all there is served as itself" "$(ghost_of whole)" "crew/angel"
check "crew: a set that is not there at all falls back to the room worker" \
  "$(ghost_of typo)" "room"
check "crew: and so does one that is a frame short of complete" \
  "$(ghost_of gutted)" "room"
check "crew: losing the face never costs the dispatcher their name" \
  "$(ghost_of labels)" "TYPO,GUTTED"
check "crew: which is the set the room then draws for both of them" \
  "$(ghost_of draws)" "room,room"

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
check "actor: terminal needs_input preserves who was working on that floor" \
  "$(printf '%s' "$API" | jq -r '.runs[] | select(.id=="DONE-INPUT") | .workActorKey')" "codex"
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
  check "fixtures: twelve staged runs" "$(printf '%s' "$FIXAPI" | jq '.runs | length')" "12"
  check "fixtures: one alarm" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="alarm")] | length')" "1"
  check "fixtures: one ready, one failed" \
    "$(printf '%s' "$FIXAPI" | jq '[.runs[] | select(.state=="ready" or .state=="failed")] | length')" "2"
  check "fixtures: four repos plus the fallback tower" \
    "$(printf '%s' "$FIXAPI" | jq '.towers | length')" "5"
  check "fixtures: the long-finished runs are not in the skyline" \
    "$(printf '%s' "$FIXAPI" | jq '[.towers[].runIds[]] | length')" "10"
  # One run per crew member the room has a character for, so the dive can be
  # pointed at every one of them. LEGACY-0042 is deliberately unowned and is not
  # a crew member, which is why the empty string is dropped rather than counted.
  check "fixtures: every crew member the room can draw has dispatched one" \
    "$(printf '%s' "$FIXAPI" | jq -r '[.runs[].owner | select(. != "")] | unique | join(",")')" \
    "angel,bot,emre,ran,reinier"
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

# --- the fixtures come with a week ----------------------------------------------
# The demo, and the scene the visual gate renders, is `--runs wall/fixtures/runs`
# against a ledger that does not exist yet. The staged run dirs give that a full
# skyline; the district under it is fed by the ledger instead, and the fixtures
# ship one shipped run into it — a plain. So the repo's OWN fixtures, with no
# ledger, seed a week first. Nothing else in the world does: the guard is the
# whole feature, because a live wall's memory is not ours to invent.
echo "== wall: the fixtures' own week =="
grep_not "$(grep -v '^ *//' "$SRC/wall/fixtures/city.js")" 'Math.random' \
  "fixtures: the seeded district is drawn from no randomness at all"
FIXCITY_PROBE="$ROOT/fixture-city-probe.js"
cat > "$FIXCITY_PROBE" <<'JS'
const w = require(process.argv[2]);
const { cityRecords } = require(process.argv[3]);
const staged = new Set(require('node:fs').readdirSync(process.argv[4])
  .filter((entry) => !entry.startsWith('.')));
const now = Number(process.argv[5]);
const records = cityRecords(now, w.weekStartOf);

const start = w.weekStartOf(now);
const end = w.weekEndOf(now);
const previous = w.weekStartOf(start - 1);
const standing = records.filter((r) => r.epoch >= start && r.epoch < end);
const behind = records.filter((r) => r.epoch >= previous && r.epoch < start);
const uniq = (list) => [...new Set(list)].sort().join(',');
const storeys = standing.map((r) => w.storeysOf(r));

// The minute is the quantum, so the whole of one minute is one city.
const base = now - (now % 60);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

console.log(JSON.stringify({
  count: records.length,
  standing: standing.length,
  behind: behind.length,
  outside: records.length - standing.length - behind.length,
  ahead: records.filter((r) => r.epoch > now).length,
  distinct: new Set(records.map((r) => r.id)).size,
  // A seeded id that collided with a staged run dir would shadow it under the
  // ledger's first-sighting rule, and the demo would stop showing a discovery.
  collisions: records.filter((r) => staged.has(r.id)).length,
  // Every line has to survive the ledger's own parser with nothing coerced: a
  // record the wall would rewrite is not the district this file describes.
  valid: records.every((r) => {
    const rec = w.recordOf(r);
    return rec !== null && rec.id === r.id && rec.epoch === r.epoch && rec.repo === r.repo
      && rec.owner === r.owner && rec.insertions === r.insertions
      && rec.deletions === r.deletions;
  }),
  chronological: records.every((r, i) => i === 0 || records[i - 1].epoch <= r.epoch),
  depths: uniq(standing.map((r) => w.plotOf(r.id).depth)),
  kinds: uniq(standing.map((r) => w.kindOf(r.repo))),
  owners: uniq(records.map((r) => r.owner)),
  storeys: Math.min(...storeys) + '..' + Math.max(...storeys),
  // No two buildings on one plot: same depth band, a footprint apart at least.
  crowded: standing.some((a) => standing.some((b) => a.id !== b.id
    && w.plotOf(a.id).depth === w.plotOf(b.id).depth
    && Math.abs(w.plotOf(a.id).x - w.plotOf(b.id).x) < 0.03)),
  stable: same(cityRecords(now, w.weekStartOf), records),
  sameMinute: same(cityRecords(base, w.weekStartOf), cityRecords(base + 59, w.weekStartOf)),
}));
JS
FIXCITY="$(node "$FIXCITY_PROBE" "$SRC/wall/server.js" "$SRC/wall/fixtures/city.js" \
  "$SRC/wall/fixtures/runs" "$(date +%s)" 2>&1)"
fixcity_of() { printf '%s' "$FIXCITY" | jq -r ".$1" 2>/dev/null; }
check "seed: a week's worth of memory, not a token building" \
  "$(fixcity_of count)" "28"
check "seed: most of it is this week's district"  "$(fixcity_of standing)" "21"
check "seed: and the rest is last week's ghost"   "$(fixcity_of behind)" "7"
check "seed: nothing lands outside the two windows the wall can draw" \
  "$(fixcity_of outside)" "0"
check "seed: nor in a future the fixtures have not had yet" "$(fixcity_of ahead)" "0"
check "seed: every ticket is its own building"    "$(fixcity_of distinct)" "28"
check "seed: and none of them shadows a staged run" "$(fixcity_of collisions)" "0"
check "seed: every record is one the ledger stores verbatim" "$(fixcity_of valid)" "true"
check "seed: the ledger it lays down reads as a chronicle" \
  "$(fixcity_of chronological)" "true"
check "seed: the district fills all three depth bands" "$(fixcity_of depths)" "0,1,2"
check "seed: and every family the wall can draw" \
  "$(fixcity_of kinds)" "industrial,infra,midrise,residential,spire"
check "seed: the crew and the synthetic both shipped" \
  "$(fixcity_of owners)" "angel,bot,emre,reinier"
check "seed: heights span the whole of the scale" "$(fixcity_of storeys)" "3..14"
check "seed: no two buildings stand on one plot"  "$(fixcity_of crowded)" "false"
check "seed: the same clock draws the same city"  "$(fixcity_of stable)" "true"
check "seed: and so does anywhere in the same minute" "$(fixcity_of sameMinute)" "true"

# End to end: the wall the demo and the visual gate actually start.
serve "$SRC/wall/fixtures/runs" "$ROOT/fixture-week.log"; FW="$PORT_OUT"
FW_CITY="$CITY_OUT"
if [ -n "$FW" ]; then
  FWAPI="$(get "$FW" /api/runs)"
  FW_STANDING="$(printf '%s' "$FWAPI" | jq '.city | length')"
  if [ "$FW_STANDING" -ge 20 ]; then
    ok "fixtures: the demo opens on a district, not a plain ($FW_STANDING buildings)"
  else
    bad "fixtures: the demo opens on a district, not a plain (only $FW_STANDING)"
  fi
  check "fixtures: standing across all three depth bands" \
    "$(printf '%s' "$FWAPI" | jq -r '[.city[].depth] | unique | join(",")')" "0,1,2"
  FW_KINDS="$(printf '%s' "$FWAPI" | jq '[.city[].kind] | unique | length')"
  if [ "$FW_KINDS" -ge 4 ]; then
    ok "fixtures: in $FW_KINDS different families"
  else
    bad "fixtures: in at least four different families (got $FW_KINDS)"
  fi
  FW_GHOSTS="$(printf '%s' "$FWAPI" | jq '.ghost | length')"
  if [ "$FW_GHOSTS" -gt 0 ]; then
    ok "fixtures: with last week standing behind it ($FW_GHOSTS silhouettes)"
  else
    bad "fixtures: with last week standing behind it"
  fi
  check "fixtures: and it says so once, in the house voice" \
    "$(grep -c "seeding the city's memory" "$ROOT/fixture-week.log")" "1"
  # The seed is a ledger like any other: the demo restarted on it finds the
  # district it left, and does not pour a second one on top.
  serve "$SRC/wall/fixtures/runs" "$ROOT/fixture-week2.log" --city "$FW_CITY"
  FW_TWO="$PORT_OUT"
  if [ -n "$FW_TWO" ]; then
    check "fixtures: a restart on the same ledger stands the same city up" \
      "$(get "$FW_TWO" /api/runs | jq '.city | length')" "$FW_STANDING"
    check "fixtures: and seeds nothing a second time" \
      "$(grep -c "seeding the city's memory" "$ROOT/fixture-week2.log")" "0"
  else
    bad "fixtures: a second wall starts against the seeded ledger"
  fi
else
  bad "fixtures: server starts against the repo's fixtures with no ledger"
fi

# The guard, from the other side. $RUNS is a byte-identical copy of the same
# fixtures staged somewhere else — which is what every real deployment looks
# like — and an existing ledger is a wall with its own history. Neither is
# seeded, so the only building either can have is the one it discovered.
serve "$RUNS" "$ROOT/elsewhere.log"; ELSEWHERE="$PORT_OUT"
if [ -n "$ELSEWHERE" ]; then
  check "guard: fixtures staged anywhere else are a plain, exactly as before" \
    "$(get "$ELSEWHERE" /api/runs | jq '[.city[] | select(.id != "OLYX-1598")] | length')" "0"
  check "guard: and nothing was seeded into them" \
    "$(grep -c "seeding the city's memory" "$ROOT/elsewhere.log")" "0"
else
  bad "guard: server starts against a copy of the fixtures elsewhere"
fi
PRIOR_CITY="$ROOT/prior-city.jsonl"
: > "$PRIOR_CITY"
serve "$SRC/wall/fixtures/runs" "$ROOT/prior.log" --city "$PRIOR_CITY"; PRIOR="$PORT_OUT"
if [ -n "$PRIOR" ]; then
  check "guard: a ledger that already exists is never seeded into" \
    "$(get "$PRIOR" /api/runs | jq '[.city[] | select(.id != "OLYX-1598")] | length')" "0"
  check "guard: not even an empty one" \
    "$(grep -c "seeding the city's memory" "$ROOT/prior.log")" "0"
else
  bad "guard: server starts against the fixtures with a ledger already there"
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
