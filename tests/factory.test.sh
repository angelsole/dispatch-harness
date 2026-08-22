#!/usr/bin/env bash
# The asset factory, hermetically.
#
# Nothing here reaches a vendor. `factory.py` is pointed at a stdlib HTTP stub
# on a loopback port (PIXELLAB_BASE_URL / RD_BASE_URL, the knobs that exist for
# exactly this), the stub answers every endpoint with a canned PNG and records
# what it was asked for, and the assertions are made against that record — which
# is the only way to check the things that actually matter about a paid API
# client: that the palette really is on every request, that the seed really is
# derived from the id, that a cache hit really makes no second call, and that a
# vendor error echoing an Authorization header cannot put a key on stderr.
#
# Five parts:
#   A  factory.py against the stub — palette, seeds, cache, --dry-run, 429,
#      manifest shape, redaction, a missing key naming its own variable.
#   B  postpass.py on sprites drawn here — feathered alpha, off-palette
#      gradient, a true 4x upscale, an off-grid one, and the RD fixer path.
#   C  palette.py extract / show / check.
#   D  run-task.sh key scoping: a fake `claude`, a fake gate and a fake reviewer
#      that each dump their environment, and a fake factory.conf.sh whose secret
#      must appear in exactly one of the three dumps and nowhere in the run dir.
#   E  the static contracts — worker-settings rules, the MCP config, install.
#
# Two of the fork's part-E blocks did not travel, because their subject is this
# repo's own .creative/ rather than the factory: the assertion that bible.md
# opens with a DRAFT banner (this wall's bible has been signed off since) and
# the one over .creative/demo/, a batch generated from a 14-entry assets.json
# that has grown a great deal since. Neither tested factory.py.
#
# The live arm (FACTORY_LIVE=1) is the only thing that spends money, and it is
# off unless you ask for it.
#
# Usage: bash tests/factory.test.sh   [FACTORY_LIVE=1 for the two balance calls]
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="$SRC/profiles/visual"
CREATIVE="$PROFILE/creative"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/factory-test.XXXXXX")"
STUB_PID=""
cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { skipped=$((skipped+1)); printf '  skip %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has(){ if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

HAVE_PY=0
python3 -c 'import numpy, PIL' >/dev/null 2>&1 && HAVE_PY=1

if [ "$HAVE_PY" = 0 ]; then
  skip "the whole suite: python3 with numpy and Pillow is not available here"
  printf '\nfactory: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
  [ "$fail" -eq 0 ]
  exit
fi

# ---------------------------------------------------------------------------
# The stub factory
# ---------------------------------------------------------------------------
# One process answering both vendors. It writes every request to a JSONL log
# (method, path, headers of interest, body) and reads a one-word mode file, so a
# test can make the next call fail in a specific, documented way without
# restarting anything.
cat > "$ROOT/stub.py" <<'PY'
import base64
import io
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image

LOG = sys.argv[1]
MODE = sys.argv[2]
PORT_FILE = sys.argv[3]
LOCK = threading.Lock()


def png(w, h, seed=0):
    im = Image.new("RGBA", (w, h))
    im.putdata([((x * 7 + seed) % 256, (y * 11 + seed) % 256,
                 (x * y + seed) % 256, 255)
                for y in range(h) for x in range(w)])
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def upscaled(n=4, base=8):
    """A pixel-exact n-times upscale — what the pixel fixer is asked to return."""
    im = Image.new("RGBA", (base, base))
    im.putdata([((x * 31) % 256, (y * 17) % 256, 90, 255)
                for y in range(base) for x in range(base)])
    im = im.resize((base * n, base * n), Image.Resampling.NEAREST)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def mode():
    try:
        with open(MODE) as fh:
            return fh.read().strip()
    except OSError:
        return "ok"


def take_mode():
    """Read the mode and reset it — for the once-only failure arms."""
    m = mode()
    if m.endswith("-once"):
        with open(MODE, "w") as fh:
            fh.write("ok")
    return m


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_a):
        pass

    def record(self, body):
        entry = {"method": self.command, "path": self.path,
                 "authorization": self.headers.get("Authorization", ""),
                 "x_rd_token": self.headers.get("X-RD-Token", ""),
                 "user_agent": self.headers.get("User-Agent", ""),
                 "body": body}
        with LOCK:
            with open(LOG, "a") as fh:
                fh.write(json.dumps(entry) + "\n")

    def send(self, code, payload):
        raw = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def send_bytes(self, code, raw, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.record(None)
        p = self.path
        if p.endswith("/balance"):
            return self.send(200, {"credits": {"type": "usd", "usd": 1.5},
                                   "subscription": {"type": "generations",
                                                    "status": "trial",
                                                    "generations": 40, "total": 40}})
        if p.endswith("/inferences/credits"):
            return self.send(200, {"credits": 50, "balance": 0.5})
        if "/inferences/tasks/" in p:
            return self.send(200, {"status": "succeeded", "task_id": "t1",
                                   "result": {"base64_images": [png(16, 16, 5)],
                                              "balance_cost": 0.023,
                                              "remaining_balance": 0.477}})
        if "/background-jobs/" in p:
            job = p.rsplit("/", 1)[-1]
            last = {}
            if job == "job-anim":
                last = {"images": [{"type": "base64", "base64": png(16, 16, i)}
                                   for i in range(2)]}
            usage = ({"type": "generations", "generations": 1}
                     if job == "job-char" else
                     {"type": "usd", "usd": 0.0221} if job == "job-anim" else None)
            return self.send(200, {"id": job, "status": "completed",
                                   "created_at": "2026-01-01T00:00:00Z",
                                   "usage": usage,
                                   "last_response": last})
        if "/tilesets/" in p:
            return self.send(200, {"usage": {"type": "usd", "usd": 0.0079},
                                   "tileset": {"total_tiles": 2,
                                               "tile_size": {"width": 16, "height": 16},
                                               "terrain_types": ["lower", "upper"],
                                               "tiles": [
                                                   {"id": "a", "name": "none",
                                                    "image": {"type": "base64",
                                                              "base64": png(16, 16, 1)}},
                                                   {"id": "b", "name": "NW+SE",
                                                    "image": {"type": "base64",
                                                              "base64": png(16, 16, 2)}}]}})
        if "/characters/" in p:
            host = self.headers.get("Host", "127.0.0.1")
            base = "http://%s/img" % host
            west = None if mode() == "missing-rotation" else base + "/west.png"
            return self.send(200, {"id": "ch-1", "status": "completed",
                                   "size": {"width": 16, "height": 16},
                                   "directions": 4,
                                   "rotation_urls": {
                                       "south": base + "/south.png",
                                       "east": base + "/east.png",
                                       "north": base + "/north.png",
                                       "west": west,
                                       "south-east": None, "north-east": None,
                                       "north-west": None, "south-west": None}})
        if p.startswith("/img/"):
            return self.send_bytes(200, base64.b64decode(png(16, 16, 3)), "image/png")
        return self.send(404, {"detail": "no such stub route: " + p})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode() or "{}")
        except ValueError:
            body = {}
        self.record(body)
        p = self.path
        m = take_mode()

        if m == "429-once":
            self.send_response(429)
            self.send_header("Retry-After", "0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if m == "echo-key-once":
            # The failure that motivates redact(): a vendor quoting the request
            # it rejected, Authorization header and all.
            return self.send(400, {"detail": "rejected request with headers: "
                                             "Authorization: %s X-RD-Token: %s"
                                             % (self.headers.get("Authorization", ""),
                                                self.headers.get("X-RD-Token", ""))})

        if p.endswith("/pixel-fixer/standard"):
            return self.send(200, {"base64_images": [upscaled()]})
        if p.endswith("/create-image-pixflux"):
            return self.send(200, {"usage": {"type": "usd", "usd": 0.0079},
                                   "image": {"type": "base64", "base64": png(16, 16)}})
        if p.endswith("/create-tileset"):
            return self.send(202, {"usage": None,
                                   "background_job_id": "job-tileset",
                                   "tileset_id": "ts-1", "status": "processing"})
        if p.endswith("/create-character-with-4-directions"):
            return self.send(200, {"usage": None,
                                   "background_job_id": "job-char",
                                   "character_id": "ch-1", "status": "processing"})
        if p.endswith("/animate-with-text-v3"):
            return self.send(200, {"usage": None,
                                   "background_job_id": "job-anim",
                                   "status": "processing"})
        if p.endswith("/inferences"):
            if body.get("async"):
                return self.send(200, {"status": "accepted", "task_id": "t1"})
            return self.send(200, {"base64_images": [png(16, 16, 5)],
                                   "balance_cost": 0.023, "model": "rd_plus",
                                   "remaining_balance": 0.477})
        return self.send(404, {"detail": "no such stub route: " + p})


srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
PY

STUB_LOG="$ROOT/stub.jsonl"; : > "$STUB_LOG"
STUB_MODE="$ROOT/stub.mode"; printf 'ok\n' > "$STUB_MODE"
PORT_FILE="$ROOT/stub.port"
python3 "$ROOT/stub.py" "$STUB_LOG" "$STUB_MODE" "$PORT_FILE" >"$ROOT/stub.err" 2>&1 &
STUB_PID=$!
PORT=""
for _ in $(seq 1 50); do
  [ -s "$PORT_FILE" ] && PORT="$(cat "$PORT_FILE")" && break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  bad "stub: never bound a port ($(cat "$ROOT/stub.err" 2>/dev/null | head -3))"
  printf '\nfactory: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
  exit 1
fi

PL_KEY="FAKE-PIXELLAB-SECRET-9f13"
RD_KEY="rdpk-FAKE-RETRO-KEY-4b02"
export PIXELLAB_BASE_URL="http://127.0.0.1:$PORT/v2"
export RD_BASE_URL="http://127.0.0.1:$PORT/v1"
export PIXELLAB_SECRET="$PL_KEY"
export RETRO_DIFFUSION_API_KEY="$RD_KEY"

# The fixture palette: eight colours, one row of 1x1 swatches — the format
# vcheck.py, factory.py and postpass.py all agree on.
python3 - "$ROOT/palette.png" <<'PY'
import sys

from PIL import Image

PAL = ["#010306", "#15202e", "#253038", "#96c3c8", "#e0a23c", "#ffc680",
       "#7ad6ec", "#e4fff3"]
im = Image.new("RGB", (len(PAL), 1))
im.putdata([tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in PAL])
im.save(sys.argv[1])
PY

cat > "$ROOT/assets.json" <<'JSON'
[
  {"id": "tile-a", "tool": "pixellab.image", "width": 16, "height": 16,
   "prompt": "brick wall"},
  {"id": "set-a", "tool": "pixellab.tileset", "tile_size": 16,
   "lower": "asphalt", "upper": "pavement"},
  {"id": "hero", "tool": "pixellab.character4", "width": 16, "height": 16,
   "prompt": "courier"},
  {"id": "hero-idle", "tool": "pixellab.animate", "from": "hero#south",
   "frame_count": 4, "prompt": "breathing"},
  {"id": "rd-a", "tool": "rd.image", "width": 16, "height": 16,
   "prompt_style": "rd_plus__low_res", "prompt": "facade"},
  {"id": "rd-t", "tool": "rd.tile", "width": 16, "height": 16, "prompt": "asphalt"}
]
JSON

fac() { python3 "$CREATIVE/factory.py" "$@"; }
requests() { grep -c '' "$STUB_LOG" 2>/dev/null | tr -d ' '; }

# ---------------------------------------------------------------------------
echo "== part A: factory.py against the stub =="
# ---------------------------------------------------------------------------
: > "$STUB_LOG"
DRY_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/dry" \
             --palette "$ROOT/palette.png" --dry-run 2>&1)"
check "dry-run: makes no request" "$(requests)" "0"
has "$DRY_OUT" "would call" "dry-run: prints the calls it would make"
has "$DRY_OUT" "dry run: 6 call(s)" "dry-run: prices the whole list"
if [ -e "$ROOT/dry/manifest.json" ]; then
  bad "dry-run: writes no manifest"
else
  ok "dry-run: writes no manifest"
fi

: > "$STUB_LOG"
GEN_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/gen" \
             --palette "$ROOT/palette.png" 2>&1)"
GEN_RC=$?
check "gen: exits 0" "$GEN_RC" "0"
FIRST_REQUESTS="$(requests)"
if [ "$FIRST_REQUESTS" -ge 6 ]; then
  ok "gen: reached the stub ($FIRST_REQUESTS requests)"
else
  bad "gen: reached the stub (only $FIRST_REQUESTS requests) — $GEN_OUT"
fi

# Deterministic file names, one per image the vendors returned.
for f in tile-a.png set-a-t00.png set-a-t01.png hero-south.png hero-east.png \
         hero-north.png hero-west.png hero-idle-f00.png hero-idle-f01.png \
         rd-a.png rd-t.png; do
  if [ -f "$ROOT/gen/raw/$f" ]; then ok "gen: raw/$f"; else bad "gen: raw/$f is missing"; fi
done

# --- what every generation request had to carry ---------------------------
python3 - "$STUB_LOG" "$PL_KEY" "$RD_KEY" > "$ROOT/bodies.txt" <<'PY'
import hashlib
import json
import sys

log, pl_key, rd_key = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(line) for line in open(log) if line.strip()]
posts = [r for r in rows if r["method"] == "POST"]
gen = [r for r in posts if not r["path"].endswith("/pixel-fixer/standard")]

palette_missing = [r["path"] for r in gen
                   if not (("color_image" in (r["body"] or {}))
                           or ("input_palette" in (r["body"] or {}))
                           or ("first_frame" in (r["body"] or {})))]
print("PALETTE_MISSING=%s" % (",".join(palette_missing) or "none"))

auth_ok = all(r["authorization"] == "Bearer " + pl_key
              for r in rows if "/v2/" in r["path"])
rd_ok = all(r["x_rd_token"] == rd_key for r in rows if "/v1/" in r["path"])
print("PL_AUTH_OK=%s" % auth_ok)
print("RD_AUTH_OK=%s" % rd_ok)

# A list, not a dict keyed on path: rd.image and rd.tile are both POSTs to
# /v1/inferences, and keying on the path would quietly count them as one.
seeds = [r for r in gen if "seed" in (r["body"] or {})]
print("SEED_TILE=%s" % next((b["seed"] for b in (r["body"] for r in gen)
                             if b.get("description", "").startswith("brick wall")), None))
print("SEED_EXPECTED=%d" % int(hashlib.sha256(b"tile-a").hexdigest()[:8], 16))
print("ALL_SEEDED=%s" % (len(seeds) == len(gen)))

frozen = [b for b in (r["body"] or {} for r in gen) if "description" in b]
print("FROZEN_VIEW=%s" % all(b.get("view") == "side" for b in frozen
                             if b.get("description", "").startswith("brick wall")))
print("BYPASS=%s" % all((r["body"] or {}).get("bypass_prompt_expansion") is True
                        for r in gen if "/v1/inferences" in r["path"]))
print("FORCE_COLORS=%s" % any((r["body"] or {}).get("force_colors") is True
                              for r in gen))
PY
BODIES="$(cat "$ROOT/bodies.txt")"
has "$BODIES" "PALETTE_MISSING=none" "gen: every generation request carries the palette"
has "$BODIES" "PL_AUTH_OK=True"      "gen: every PixelLab request carries the bearer header"
has "$BODIES" "RD_AUTH_OK=True"      "gen: every RD request carries the X-RD-Token header"
has "$BODIES" "ALL_SEEDED=True"      "gen: every generation request carries a seed"
has "$BODIES" "FROZEN_VIEW=True"     "gen: the frozen style block is applied"
has "$BODIES" "BYPASS=True"          "gen: RD calls bypass prompt expansion"
has "$BODIES" "FORCE_COLORS=True"    "gen: the character request forces the palette colours"
SEED_TILE="$(printf '%s' "$BODIES" | sed -n 's/^SEED_TILE=//p')"
SEED_WANT="$(printf '%s' "$BODIES" | sed -n 's/^SEED_EXPECTED=//p')"
check "gen: seed is sha256(id), not a random number" "$SEED_TILE" "$SEED_WANT"

# --- the manifest ---------------------------------------------------------
python3 - "$ROOT/gen/manifest.json" "$PL_KEY" "$RD_KEY" > "$ROOT/manifest.txt" <<'PY'
import json
import sys

raw = open(sys.argv[1]).read()
man = json.loads(raw)
need = {"id", "tool", "endpoint", "params", "seed", "cost", "sha256",
        "generated_at", "cached", "files", "vendor"}
missing = set()
for a in man["assets"]:
    missing |= need - set(a)
print("MISSING_FIELDS=%s" % (",".join(sorted(missing)) or "none"))
print("SORTED=%s" % ([a["id"] for a in man["assets"]]
                     == sorted(a["id"] for a in man["assets"])))
print("COUNT=%d" % len(man["assets"]))
print("HAS_KEY=%s" % (sys.argv[2] in raw or sys.argv[3] in raw))
print("BLOBS=%s" % ("base64" in raw and "iVBORw0KGgo" not in raw))
print("COST_REAL=%s" % all(a["cost"].get("estimated") is False for a in man["assets"]))
PY
MAN="$(cat "$ROOT/manifest.txt")"
has "$MAN" "MISSING_FIELDS=none" "manifest: every asset carries the full provenance record"
has "$MAN" "SORTED=True"         "manifest: assets are in id order"
has "$MAN" "COUNT=6"             "manifest: one record per asset entry"
has "$MAN" "HAS_KEY=False"       "manifest: contains neither key"
has "$MAN" "BLOBS=True"          "manifest: image bytes are digested, not inlined"
has "$MAN" "COST_REAL=True"      "manifest: costs come from the vendor, not the formula"

# --- the cache ------------------------------------------------------------
BEFORE="$(requests)"
CACHE_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/gen" \
               --palette "$ROOT/palette.png" 2>&1)"
check "cache: a second run makes no request" "$(requests)" "$BEFORE"
has "$CACHE_OUT" "cached" "cache: the run reports the hits"
has "$CACHE_OUT" "0 call(s)" "cache: the manifest records zero calls"

# A different palette is a different picture, so it must miss.
python3 - "$ROOT/palette2.png" <<'PY'
import sys

from PIL import Image

im = Image.new("RGB", (4, 1))
im.putdata([(1, 3, 6), (255, 0, 0), (0, 255, 0), (0, 0, 255)])
im.save(sys.argv[1])
PY
BEFORE="$(requests)"
fac gen --assets "$ROOT/assets.json" --out "$ROOT/gen2" \
    --palette "$ROOT/palette2.png" --only tile-a >/dev/null 2>&1
AFTER="$(requests)"
if [ "$AFTER" -gt "$BEFORE" ]; then
  ok "cache: a changed palette invalidates the entry"
else
  bad "cache: a changed palette invalidates the entry (no new request)"
fi

# --- --only, --max-calls --------------------------------------------------
ONLY_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/gen" \
              --palette "$ROOT/palette.png" --only tile-a rd-a 2>&1)"
has "$ONLY_OUT" "tile-a" "--only: generates the named assets"
has_not "$ONLY_OUT" "set-a" "--only: leaves the rest alone"

rm -rf "$ROOT/capped"
CAP_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/capped" \
             --palette "$ROOT/palette.png" --max-calls 2 2>&1)"
CAP_RC=$?
check "--max-calls: stops the run non-zero" "$CAP_RC" "1"
has "$CAP_OUT" "--max-calls 2 reached" "--max-calls: says why it stopped"

# --- 429 ------------------------------------------------------------------
rm -rf "$ROOT/retry"
printf '429-once\n' > "$STUB_MODE"
BEFORE="$(requests)"
fac gen --assets "$ROOT/assets.json" --out "$ROOT/retry" \
    --palette "$ROOT/palette.png" --only tile-a > "$ROOT/retry.log" 2>&1
RETRY_RC=$?
printf 'ok\n' > "$STUB_MODE"
check "429: the call still succeeds after a retry" "$RETRY_RC" "0"
AFTER="$(requests)"
if [ "$((AFTER - BEFORE))" -ge 2 ]; then
  ok "429: the request was actually made twice"
else
  bad "429: the request was actually made twice (delta $((AFTER - BEFORE)))"
fi

# --- redaction ------------------------------------------------------------
rm -rf "$ROOT/redact"
printf 'echo-key-once\n' > "$STUB_MODE"
REDACT_OUT="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/redact" \
                --palette "$ROOT/palette.png" --only tile-a 2>&1)"
REDACT_RC=$?
printf 'ok\n' > "$STUB_MODE"
check "redaction: a vendor rejection fails the run" "$REDACT_RC" "1"
has_not "$REDACT_OUT" "$PL_KEY" "redaction: the PixelLab key is not on stderr"
has_not "$REDACT_OUT" "$RD_KEY" "redaction: the RD key is not on stderr"
has "$REDACT_OUT" "redacted" "redaction: the error says a value was removed"

# --- a missing key names itself -------------------------------------------
MISSING_OUT="$(env -u PIXELLAB_SECRET python3 "$CREATIVE/factory.py" gen \
                 --assets "$ROOT/assets.json" --out "$ROOT/nokey" \
                 --palette "$ROOT/palette.png" --only tile-a 2>&1)"
MISSING_RC=$?
check "missing key: the run fails" "$MISSING_RC" "1"
has "$MISSING_OUT" "PIXELLAB_SECRET is not set" "missing key: the error names the variable"
has "$MISSING_OUT" "factory.conf.sh" "missing key: the error says where the key belongs"

BAL_OUT="$(fac balance 2>&1)"
has "$BAL_OUT" "pixellab:" "balance: reports PixelLab"
has "$BAL_OUT" "retro-diffusion:" "balance: reports Retro Diffusion"
NOKEY_BAL="$(env -u RETRO_DIFFUSION_API_KEY python3 "$CREATIVE/factory.py" balance 2>&1)"
NOKEY_RC=$?
check "balance: exits 1 when a key is missing" "$NOKEY_RC" "1"
has "$NOKEY_BAL" "RETRO_DIFFUSION_API_KEY is not set" "balance: names the missing variable"

# A mainline RD style at a tile size is the expensive mistake this client
# refuses to make for you.
cat > "$ROOT/bad-style.json" <<'JSON'
[{"id": "oops", "tool": "rd.image", "width": 16, "height": 16,
  "prompt_style": "rd_pro__default", "prompt": "facade"}]
JSON
BADSTYLE="$(fac gen --assets "$ROOT/bad-style.json" --out "$ROOT/bad" \
              --palette "$ROOT/palette.png" 2>&1)"
BADSTYLE_RC=$?
check "rd: a mainline style is refused" "$BADSTYLE_RC" "1"
has "$BADSTYLE" "mainline style" "rd: the refusal explains the size trap"

# Asset ids become file names. A list in a repo must not be able to escape the
# requested raw/ directory through an absolute path or `..` component.
cat > "$ROOT/bad-id.json" <<'JSON'
[{"id": "../escape", "tool": "pixellab.image", "width": 32, "height": 32,
  "prompt": "facade"}]
JSON
BADID="$(fac gen --assets "$ROOT/bad-id.json" --out "$ROOT/bad-id-out" \
           --palette "$ROOT/palette.png" --dry-run 2>&1)"
BADID_RC=$?
check "ids: an unsafe output basename is refused" "$BADID_RC" "1"
has "$BADID" "asset id" "ids: the refusal names the invalid field"

rm -rf "$ROOT/incomplete-character"
printf 'missing-rotation\n' > "$STUB_MODE"
INCOMPLETE="$(fac gen --assets "$ROOT/assets.json" --out "$ROOT/incomplete-character" \
                --palette "$ROOT/palette.png" --only hero 2>&1)"
INCOMPLETE_RC=$?
printf 'ok\n' > "$STUB_MODE"
check "character4: a missing cardinal rotation fails the asset" "$INCOMPLETE_RC" "1"
has "$INCOMPLETE" "west" "character4: the failure names the missing rotation"

# ---------------------------------------------------------------------------
echo "== part B: postpass.py on sprites drawn here =="
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/pp/in"
python3 - "$ROOT/pp/in" <<'PY'
import numpy as np
from PIL import Image
import sys

d = sys.argv[1]

# feathered alpha: 16 distinct alpha values, and off-palette RGB under them
a = np.zeros((16, 16, 4), np.uint8)
for y in range(16):
    for x in range(16):
        a[y, x, :3] = (17 + x * 9, 33 + y * 7, 61 + (x + y) * 4)
        a[y, x, 3] = x * 17
Image.fromarray(a, "RGBA").save(d + "/feathered.png")

# an off-palette gradient, fully opaque
g = np.zeros((16, 16, 4), np.uint8)
for y in range(16):
    for x in range(16):
        g[y, x] = (x * 16, y * 16, 255 - x * 8, 255)
Image.fromarray(g, "RGBA").save(d + "/gradient.png")

# a pixel-exact 4x upscale of an 8x8 sprite
small = np.zeros((8, 8, 4), np.uint8)
for y in range(8):
    for x in range(8):
        small[y, x] = ((x * 31) % 256, (y * 17) % 256, 90, 255)
Image.fromarray(np.kron(small, np.ones((4, 4, 1), np.uint8)), "RGBA") \
     .save(d + "/upscaled.png")

# bilinear: the same sprite with a grid that only looks like one
Image.fromarray(small, "RGBA").resize((32, 32), Image.Resampling.BILINEAR) \
     .save(d + "/offgrid.png")
PY

python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/in" --out "$ROOT/pp/out1" \
    --palette "$ROOT/palette.png" --atlas sheet --report "$ROOT/pp/r1.json" \
    > "$ROOT/pp/out1.log" 2>&1
PP_RC=$?
check "postpass: exits 0 when everything passes" "$PP_RC" "0"

python3 - "$ROOT/pp/out1" "$ROOT/palette.png" "$ROOT/pp/r1.json" > "$ROOT/pp/a1.txt" <<'PY'
import json
import os
import sys

import numpy as np
from PIL import Image

out, pal_path, report = sys.argv[1], sys.argv[2], sys.argv[3]
lut = np.asarray(Image.open(pal_path).convert("RGB"), np.uint8).reshape(-1, 3)
bad_alpha, off_palette = [], []
for name in sorted(os.listdir(out)):
    if not name.endswith(".png") or name == "sheet.png":
        continue
    a = np.asarray(Image.open(os.path.join(out, name)).convert("RGBA"), np.uint8)
    if not set(np.unique(a[..., 3]).tolist()) <= {0, 255}:
        bad_alpha.append(name)
    opaque = a[a[..., 3] == 255][:, :3]
    if opaque.size and not (opaque[:, None, :] == lut[None]).all(-1).any(-1).all():
        off_palette.append(name)
    if name == "feathered.png":
        transparent = a[a[..., 3] == 0][:, :3]
        print("ZEROED=%s" % (transparent.size == 0 or bool((transparent == 0).all())))
print("BAD_ALPHA=%s" % (",".join(bad_alpha) or "none"))
print("OFF_PALETTE=%s" % (",".join(off_palette) or "none"))

rep = json.load(open(report))
by_id = {a["id"]: a for a in rep["assets"]}
print("FEATHER_BEFORE_ALPHAS=%d" % by_id["feathered"]["before"]["alphas"])
print("FEATHER_AFTER_ALPHAS=%d" % by_id["feathered"]["after"]["alphas"])
print("GRADIENT_BEFORE_OFF=%.0f" % by_id["gradient"]["before"]["offpalette_pct"])
print("GRADIENT_AFTER_OFF=%.0f" % by_id["gradient"]["after"]["offpalette_pct"])
print("REPORT_PASS=%s" % rep["pass"])

atlas = json.load(open(os.path.join(out, "sheet.json")))
frames = atlas["frames"]
print("ATLAS_FRAMES=%d" % len(frames))
print("ATLAS_META=%s" % all(k in atlas["meta"] for k in
                            ("app", "version", "image", "format", "size", "scale")))
print("ATLAS_SHAPE=%s" % all(
    set(f) >= {"frame", "rotated", "trimmed", "spriteSourceSize", "sourceSize"}
    and set(f["frame"]) == {"x", "y", "w", "h"}
    and f["rotated"] is False and f["trimmed"] is False
    for f in frames.values()))
overlap = False
rects = [(f["frame"]["x"], f["frame"]["y"], f["frame"]["w"], f["frame"]["h"])
         for f in frames.values()]
for i, (x1, y1, w1, h1) in enumerate(rects):
    for (x2, y2, w2, h2) in rects[i + 1:]:
        if x1 < x2 + w2 and x2 < x1 + w1 and y1 < y2 + h2 and y2 < y1 + h1:
            overlap = True
print("ATLAS_OVERLAP=%s" % overlap)
sheet = Image.open(os.path.join(out, "sheet.png"))
print("ATLAS_FITS=%s" % (sheet.size == (atlas["meta"]["size"]["w"],
                                        atlas["meta"]["size"]["h"])))
print("ATLAS_CROPS=%s" % all(
    np.array_equal(
        np.asarray(sheet.convert("RGBA"))[f["frame"]["y"]:f["frame"]["y"] + f["frame"]["h"],
                                          f["frame"]["x"]:f["frame"]["x"] + f["frame"]["w"]],
        np.asarray(Image.open(os.path.join(out, fid + ".png")).convert("RGBA")))
    for fid, f in frames.items()))
PY
A1="$(cat "$ROOT/pp/a1.txt")"
has "$A1" "BAD_ALPHA=none"   "postpass: every output's alphas are within {0,255}"
has "$A1" "OFF_PALETTE=none" "postpass: every opaque pixel is exactly on the LUT"
has "$A1" "ZEROED=True"      "postpass: transparent pixels have their RGB zeroed"
has "$A1" "FEATHER_BEFORE_ALPHAS=16" "postpass: the report records the 16 alphas it started with"
has "$A1" "FEATHER_AFTER_ALPHAS=2"   "postpass: and the two it ended with"
has "$A1" "GRADIENT_BEFORE_OFF=100"  "postpass: the report records a fully off-palette input"
has "$A1" "GRADIENT_AFTER_OFF=0"     "postpass: and a fully conformant output"
has "$A1" "REPORT_PASS=True"         "postpass: the report's verdict is pass"
has "$A1" "ATLAS_FRAMES=4"   "atlas: one frame per passing asset"
has "$A1" "ATLAS_META=True"  "atlas: meta carries the Phaser 3 JSON-hash keys"
has "$A1" "ATLAS_SHAPE=True" "atlas: every frame has the JSON-hash shape, unrotated and untrimmed"
has "$A1" "ATLAS_OVERLAP=False" "atlas: no two frames overlap"
has "$A1" "ATLAS_FITS=True"  "atlas: the PNG is the size meta claims"
has "$A1" "ATLAS_CROPS=True" "atlas: every frame rect crops back to its own asset"

# --- the grid arm ---------------------------------------------------------
PP4="$(python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/in" --out "$ROOT/pp/out4" \
         --palette "$ROOT/palette.png" --pitch 4 --report "$ROOT/pp/r4.json" 2>&1)"
PP4_RC=$?
check "postpass --pitch: exits 1 when an asset fails" "$PP4_RC" "1"
has "$PP4" "off-grid, no fixer" "postpass --pitch: an off-grid asset fails with a reason"
python3 - "$ROOT/pp/r4.json" "$ROOT/pp/out4" > "$ROOT/pp/a4.txt" <<'PY'
import json
import os
import sys

from PIL import Image

rep = json.load(open(sys.argv[1]))
by_id = {a["id"]: a for a in rep["assets"]}
print("UPSCALED_PASS=%s" % by_id["upscaled"]["pass"])
print("OFFGRID_PASS=%s" % by_id["offgrid"]["pass"])
print("OFFGRID_REASON=%s" % ("off-grid" in " ".join(by_id["offgrid"]["reasons"])))
print("REPORT_FAILED=%d" % rep["failed"])
im = Image.open(os.path.join(sys.argv[2], "upscaled.png"))
print("DOWNSAMPLED=%s" % (im.size == (8, 8)))
PY
A4="$(cat "$ROOT/pp/a4.txt")"
has "$A4" "UPSCALED_PASS=True"  "postpass --pitch: a true 4x upscale passes"
has "$A4" "DOWNSAMPLED=True"    "postpass --pitch: and is block-sampled back to 8x8"
has "$A4" "OFFGRID_PASS=False"  "postpass --pitch: a bilinear upscale is NOT guessed at"
has "$A4" "OFFGRID_REASON=True" "postpass --pitch: the report names the reason"
has "$A4" "REPORT_FAILED=3"     "postpass --pitch: the report counts every failure"

# A malformed PNG is one failed asset, not an exception that suppresses the
# report and leaves a stale previously-passing output behind.
mkdir -p "$ROOT/pp/mixed" "$ROOT/pp/mixedout"
cp "$ROOT/pp/in/gradient.png" "$ROOT/pp/mixed/good.png"
printf 'not a png\n' > "$ROOT/pp/mixed/bad.png"
cp "$ROOT/pp/in/gradient.png" "$ROOT/pp/mixedout/bad.png"
MIXED_OUT="$(python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/mixed" \
               --out "$ROOT/pp/mixedout" --palette "$ROOT/palette.png" \
               --report "$ROOT/pp/rmixed.json" 2>&1)"
MIXED_RC=$?
check "postpass invalid PNG: the completed run exits 1" "$MIXED_RC" "1"
has "$MIXED_OUT" "invalid PNG" "postpass invalid PNG: the failure has a reason"
if [ -f "$ROOT/pp/rmixed.json" ]; then
  ok "postpass invalid PNG: the full report is still written"
else
  bad "postpass invalid PNG: the full report is still written"
fi
if [ -f "$ROOT/pp/mixedout/good.png" ]; then
  ok "postpass invalid PNG: later valid assets are still processed"
else
  bad "postpass invalid PNG: later valid assets are still processed"
fi
if [ -e "$ROOT/pp/mixedout/bad.png" ]; then
  bad "postpass invalid PNG: a stale prior output was removed"
else
  ok "postpass invalid PNG: a stale prior output was removed"
fi

BAD_ATLAS="$(python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/mixed" \
               --out "$ROOT/pp/mixedout" --palette "$ROOT/palette.png" \
               --atlas ../escape 2>&1)"
check "atlas: an unsafe output basename is refused" "$?" "2"
has "$BAD_ATLAS" "--atlas" "atlas: the refusal names the invalid option"

# --fix-grid rd: the same off-grid sprite, repaired through the (stubbed) free
# Pixel Fixer rather than through a pitch this file refuses to invent.
mkdir -p "$ROOT/pp/fix"
cp "$ROOT/pp/in/offgrid.png" "$ROOT/pp/fix/offgrid.png"
FIX_OUT="$(python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/fix" --out "$ROOT/pp/fixout" \
             --palette "$ROOT/palette.png" --pitch 4 --fix-grid rd \
             --report "$ROOT/pp/rfix.json" 2>&1)"
FIX_RC=$?
check "--fix-grid rd: the repaired asset passes" "$FIX_RC" "0"
file_has "$STUB_LOG" "/pixel-fixer/standard" "--fix-grid rd: the free Pixel Fixer was called"
has "$FIX_OUT" "ok" "--fix-grid rd: the run reports the asset as ok"

# --tile: the dimension assertion
TILE_OUT="$(python3 "$CREATIVE/postpass.py" --in "$ROOT/pp/in" --out "$ROOT/pp/outt" \
              --palette "$ROOT/palette.png" --tile 16x16 --report "$ROOT/pp/rt.json" 2>&1)"
TILE_RC=$?
check "--tile: a wrong-sized asset fails the run" "$TILE_RC" "1"
has "$TILE_OUT" "expected 16x16, got 32x32" "--tile: the reason names both sizes"

# ---------------------------------------------------------------------------
echo "== part C: palette.py =="
# ---------------------------------------------------------------------------
pal() { python3 "$CREATIVE/palette.py" "$@"; }
EX_OUT="$(pal extract "$ROOT/pp/in/gradient.png" --colors 6 --out "$ROOT/pal-ex.png" \
            --hex '#010306,#ffc680' 2>&1)"
EX_RC=$?
check "palette extract: exits 0" "$EX_RC" "0"
has "$EX_OUT" "6 colours" "palette extract: honours --colors"
has "$EX_OUT" "#010306" "palette extract: forced colours survive"
has "$EX_OUT" "#ffc680" "palette extract: every forced colour survives"
SHOW_OUT="$(pal show "$ROOT/pal-ex.png" 2>&1)"
has "$SHOW_OUT" "#010306" "palette show: lists the colours back"
python3 -c "
from PIL import Image
im = Image.open('$ROOT/pal-ex.png')
print('SIZE=%dx%d MODE=%s' % (im.width, im.height, im.mode))" > "$ROOT/pal-size.txt"
file_has "$ROOT/pal-size.txt" "SIZE=6x1" "palette extract: writes one row of 1x1 swatches"

pal check "$ROOT/pp/in/gradient.png" --palette "$ROOT/palette.png" > "$ROOT/pal-check1.txt" 2>&1
check "palette check: exits 1 on an off-palette image" "$?" "1"
file_has "$ROOT/pal-check1.txt" "off-palette" "palette check: reports the conformance figure"
pal check "$ROOT/pp/out1/gradient.png" --palette "$ROOT/palette.png" > "$ROOT/pal-check2.txt" 2>&1
check "palette check: exits 0 on a post-passed image" "$?" "0"
file_has "$ROOT/pal-check2.txt" "100.00% conformant" "palette check: a post-passed asset is 100 % conformant"
pal check "$ROOT/pp/out1/feathered.png" --palette "$ROOT/palette.png" > "$ROOT/pal-check3.txt" 2>&1
check "palette check: ignores zeroed RGB beneath transparent pixels" "$?" "0"
file_has "$ROOT/pal-check3.txt" "100.00% conformant" \
  "palette check: a transparent post-passed sprite is conformant"

# ---------------------------------------------------------------------------
echo "== part D: run-task.sh gives the keys to the worker and nobody else =="
# ---------------------------------------------------------------------------
SCOPE_KEY="FAKE-KEY-SCOPE-a41f7c"
BARE="$ROOT/origin.git"; REPO="$ROOT/facapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

FAKES="$ROOT/bin"; FHOME="$ROOT/home"; mkdir -p "$FAKES" "$FHOME"
cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
# Implementer stand-in: dump the environment it was handed, then commit so the
# run reaches the gate and the review.
env > "$CAPTURE_WORKER"
date > fixture.txt
git add fixture.txt
git commit -q -m "feat: fixture change"
SH
cat > "$FAKES/codex" <<'SH'
#!/usr/bin/env bash
# Reviewer stand-in: dump its environment, then reject to end the run before
# anything is pushed.
env > "$CAPTURE_REVIEW"
wt=""; prev=""
for a in "$@"; do [ "$prev" = "-C" ] && wt="$a"; prev="$a"; done
printf 'fixture stop\n' > "$wt/.harness/REJECTED.md"
SH
chmod +x "$FAKES/claude" "$FAKES/codex"

run_scoped() {  # $1 = ticket, $2 = pin MCP_CONFIG?, $3 = write factory.conf.sh?
  local ticket="$1" h="$ROOT/harness-$1"
  mkdir -p "$h/runs/$ticket"
  cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$h/"
  cp -R "$SRC/lib" "$h/"
  if [ "$3" = 1 ]; then
    printf 'export PIXELLAB_SECRET=%s\nexport RETRO_DIFFUSION_API_KEY=%s\n' \
      "$SCOPE_KEY" "rdpk-$SCOPE_KEY" > "$h/factory.conf.sh"
    chmod 600 "$h/factory.conf.sh"
  fi
  # The keys belong to the visual profile now, so the fixture repo has to be one
  # the profile loads for — `true` is a visual gate that costs nothing and
  # always passes, which is all this part needs from it.
  {
    printf 'repo_config_local() {\n  case "$2" in\n    facapp|facapp-*)\n'
    printf '      GATE_CMD="env > %s"\n' "$ROOT/gate-$ticket.txt"
    printf '      VISUAL_GATE_CMD="true"\n'
    [ "$2" = 1 ] && printf '      MCP_CONFIG="%s"\n' "$CREATIVE/factory.mcp.json"
    printf '      ;;\n  esac\n}\n'
  } > "$h/repos.local.sh"
  printf '# fixture task\n' > "$h/runs/$ticket/brief.md"
  CAPTURE_WORKER="$ROOT/worker-$ticket.txt" CAPTURE_REVIEW="$ROOT/review-$ticket.txt" \
  HOME="$FHOME" HARNESS_DIR="$h" PATH="$FAKES:$PATH" \
  CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
  HARNESS_REVIEW_NETWORK=0 HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC="" \
    bash "$SRC/run-task.sh" "$ticket" "$REPO" "fix/$ticket" > "$ROOT/run-$ticket.log" 2>&1
  return 0   # the fixture run ends `rejected` by design
}

run_scoped both 1 1
run_scoped noconf 1 0
run_scoped nomcp 0 1

grep_file() {  # $1 = file, $2 = needle -> "yes"/"no"/"absent"
  [ -f "$1" ] || { printf 'absent'; return; }
  if grep -qF -- "$2" "$1"; then printf 'yes'; else printf 'no'; fi
}

check "scoping: the worker ran"   "$(grep_file "$ROOT/worker-both.txt" PATH=)" "yes"
check "scoping: the gate ran"     "$(grep_file "$ROOT/gate-both.txt" PATH=)"   "yes"
check "scoping: the reviewer ran" "$(grep_file "$ROOT/review-both.txt" PATH=)" "yes"

check "scoping: the worker gets the key" \
  "$(grep_file "$ROOT/worker-both.txt" "$SCOPE_KEY")" "yes"
check "scoping: the gate does NOT" \
  "$(grep_file "$ROOT/gate-both.txt" "$SCOPE_KEY")" "no"
check "scoping: the reviewer does NOT" \
  "$(grep_file "$ROOT/review-both.txt" "$SCOPE_KEY")" "no"
check "scoping: MCP_CONFIG unset means the worker gets nothing either" \
  "$(grep_file "$ROOT/worker-nomcp.txt" "$SCOPE_KEY")" "no"

# The run dir is what an operator, the wall and the PR stage all read.
if grep -rlF -- "$SCOPE_KEY" "$ROOT/harness-both/runs" >/dev/null 2>&1; then
  bad "scoping: the key appears somewhere under the run dir"
else
  ok "scoping: the key appears nowhere under the run dir"
fi
if grep -rlF -- "$SCOPE_KEY" "$ROOT/facapp-both" >/dev/null 2>&1; then
  bad "scoping: the key appears somewhere in the worktree"
else
  ok "scoping: the key appears nowhere in the worktree"
fi

file_has "$ROOT/run-noconf.log" "factory keys SKIP" \
  "scoping: a missing factory.conf.sh is a logged SKIP, not an error"
if grep -qF "factory keys SKIP" "$ROOT/run-nomcp.log"; then
  bad "scoping: no MCP_CONFIG means no SKIP line either"
else
  ok "scoping: no MCP_CONFIG means no SKIP line either"
fi
file_has "$ROOT/run-noconf.log" "review" \
  "scoping: the run without a conf still reaches the reviewer"

# ---------------------------------------------------------------------------
echo "== part E: the static contracts =="
# ---------------------------------------------------------------------------
# The permission-rule form is the one the CLI documents: a glob is allowed only
# in the tool position after a literal mcp__<server>__ prefix, and the server
# segment must be glob-free (docs.claude.com/en/docs/claude-code/settings —
# Permission settings, the `allow` row).
WS="$SRC/worker-settings.json"
for rule in 'mcp__pixellab__*' 'mcp__retro-diffusion__*'; do
  if python3 -c "
import json, sys
allow = json.load(open('$WS'))['permissions']['allow']
sys.exit(0 if '$rule' in allow else 1)"; then
    ok "settings: worker-settings.json allows $rule"
  else
    bad "settings: worker-settings.json allows $rule"
  fi
done
if python3 -c "
import json, sys
deny = json.load(open('$WS'))['permissions']['deny']
sys.exit(0 if all(d.startswith('Bash(') or d.startswith('mcp__') for d in deny) else 1)"; then
  ok "settings: the deny list is untouched in shape"
else
  bad "settings: the deny list is untouched in shape"
fi

MCPJSON="$CREATIVE/factory.mcp.json"
python3 - "$MCPJSON" > "$ROOT/mcp.txt" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))["mcpServers"]
print("SERVERS=%s" % ",".join(sorted(d)))
print("PL_URL=%s" % d["pixellab"]["url"])
print("RD_URL=%s" % d["retro-diffusion"]["url"])
print("PL_AUTH=%s" % d["pixellab"]["headers"]["Authorization"])
print("RD_AUTH=%s" % d["retro-diffusion"]["headers"]["Authorization"])
print("TYPES=%s" % ",".join(sorted({s["type"] for s in d.values()})))
PY
MCP="$(cat "$ROOT/mcp.txt")"
has "$MCP" "SERVERS=pixellab,retro-diffusion" "mcp: both servers are declared"
has "$MCP" "PL_URL=https://api.pixellab.ai/mcp" "mcp: the PixelLab endpoint"
has "$MCP" "RD_URL=https://mcp.retrodiffusion.ai/mcp" "mcp: the RD endpoint"
has "$MCP" 'PL_AUTH=Bearer ${PIXELLAB_SECRET}' "mcp: the PixelLab key is expanded, never inlined"
has "$MCP" 'RD_AUTH=Bearer ${RETRO_DIFFUSION_API_KEY}' "mcp: the RD key is expanded, never inlined"
has "$MCP" "TYPES=http" "mcp: both servers are http transports"

# No key may ever be committed. The example ships the names and nothing else.
if grep -rlE 'rdpk-[A-Za-z0-9]{8,}' "$CREATIVE" "$PROFILE/factory.conf.sh.example" \
     "$SRC/.creative" >/dev/null 2>&1; then
  bad "secrets: something under creative/ or .creative/ looks like a real RD key"
else
  ok "secrets: nothing shipped looks like a real RD key"
fi
file_has "$PROFILE/factory.conf.sh.example" "PIXELLAB_SECRET" "example: names PIXELLAB_SECRET"
file_has "$PROFILE/factory.conf.sh.example" "RETRO_DIFFUSION_API_KEY" "example: names RETRO_DIFFUSION_API_KEY"
EXAMPLE_VALUES="$(grep -c '^export [A-Z_]*=""$' "$PROFILE/factory.conf.sh.example" | tr -d ' ')"
check "example: both variables ship empty" "$EXAMPLE_VALUES" "2"

for f in factory.py postpass.py palette.py factory-demo.sh factory.mcp.json \
         templates/bible.md templates/rubric.md templates/proportions.md; do
  if [ -f "$CREATIVE/$f" ]; then ok "ships: creative/$f"; else bad "ships: creative/$f is missing"; fi
done
for f in bible.md palette.png proportions.md assets.json; do
  if [ -f "$SRC/.creative/$f" ]; then ok "ships: .creative/$f"; else bad "ships: .creative/$f is missing"; fi
done
for t in bible rubric proportions; do
  file_has "$CREATIVE/templates/$t.md" 'Copy to `.creative/' \
    "template: $t.md says where to copy it"
  n=$(grep -c '' "$CREATIVE/templates/$t.md" | tr -d ' ')
  if [ "$n" -le 40 ]; then ok "template: $t.md is $n lines"; else bad "template: $t.md is $n lines (max 40)"; fi
done
BIBLE_LINES=$(grep -c '' "$SRC/.creative/bible.md" | tr -d ' ')
if [ "$BIBLE_LINES" -le 60 ]; then
  ok "bible: $BIBLE_LINES lines"
else
  bad "bible: $BIBLE_LINES lines (max 60)"
fi

# The credential template travels inside the profile, so what install.sh has to
# carry is the profiles/ directory itself — assert the entry, not a mention of
# the filename somewhere in the file.
if awk '/^FILES=\(/{f=1} f&&/(^| )profiles( |$)/{found=1} /^\)/{f=0} END{exit !found}' \
     "$SRC/install.sh"; then
  ok "install: FILES ships profiles/"
else
  bad "install: FILES ships profiles/"
fi
if [ -f "$PROFILE/factory.conf.sh.example" ]; then
  ok "install: with the factory.conf.sh.example inside it"
else
  bad "install: with the factory.conf.sh.example inside it"
fi

PUBLISH_GUARD="$(bash "$CREATIVE/factory-demo.sh" --dry-run \
                   --publish /tmp/factory-demo-escape 2>&1)"
check "demo publish: refuses to replace a directory outside the worktree" "$?" "2"
has "$PUBLISH_GUARD" "--publish must be a child" \
  "demo publish: the refusal explains the safe boundary"

# ---------------------------------------------------------------------------
echo "== live (FACTORY_LIVE=1 only) =="
# ---------------------------------------------------------------------------
if [ "${FACTORY_LIVE:-0}" = 1 ]; then
  LIVE="$(env -u PIXELLAB_BASE_URL -u RD_BASE_URL python3 "$CREATIVE/factory.py" \
            balance 2>&1)"
  has "$LIVE" "pixellab:" "live: the real PixelLab balance endpoint answers"
  has "$LIVE" "retro-diffusion:" "live: the real RD credits endpoint answers"
else
  skip "live: FACTORY_LIVE is not 1 — the two real balance calls were not made"
fi

echo
printf 'factory: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
