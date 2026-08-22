#!/usr/bin/env python3
"""The asset factory — bulk generation through PixelLab and Retro Diffusion.

The worker can call either vendor conversationally through MCP. This is the
other half: the deterministic, re-runnable path a list of assets goes through,
which is what makes a hundred sprites a build step rather than a hundred
decisions. Four properties are the whole point of the file.

  * **Coherence is frozen, not prompted.** One prompt template and one fixed
    style per tool — view, outline, shading, detail — with only the entry's
    subject substituted. An asset list cannot override them, because "same
    prompt, different mood" is exactly how a set of two hundred sprites stops
    looking like one set.
  * **Seeds are derived, not chosen.** `seed = int(sha256(id)[:8], 16)` unless
    an entry pins one, so the same list re-run asks for the same pictures.
  * **A repeat costs nothing.** The cache key is the request body's hash, so a
    second run of the demo makes zero calls and a changed palette invalidates
    everything that was locked to it.
  * **Every asset carries its provenance.** manifest.json records the tool, the
    endpoint, the parameters (secrets and base64 blobs digested away), the
    seed, what it cost and whether the number came from the vendor or from a
    price formula.

Keys come from the environment (`PIXELLAB_SECRET`, `RETRO_DIFFUSION_API_KEY`)
and are never printed: every error this file echoes goes through `redact()`
first, which scrubs both values and any `Authorization`/`X-RD-Token` header
that made it into a vendor's error body.

Stdlib only (urllib/json/base64/hashlib), plus Pillow for one job: turning the
palette PNG into the RGB base64 both vendors want.

Usage:
  factory.py balance
  factory.py gen --assets FILE.json --out DIR [--palette PNG] [--only ID ...]
                 [--dry-run] [--max-calls N]

assets.json is a list of {"id", "tool", ...params}. Tools:

  pixellab.image      /create-image-pixflux         palette-locked flat image
  pixellab.tileset    /create-tileset               Wang tileset, 16 or 32 px
  pixellab.character4 /create-character-with-4-directions
  pixellab.animate    /animate-with-text-v3         from a frame made earlier
  rd.image            /v1/inferences                low-res styles only
  rd.tile             /v1/inferences                seamless single tile

Endpoints and field names were re-verified against api.pixellab.ai/v2/openapi.json
and the Retro Diffusion llms.txt at github.com/Retro-Diffusion/api-examples
before this file was written; see creative/README.md for what each one is for.

Testing knobs: PIXELLAB_BASE_URL and RD_BASE_URL point the client at a stub.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

PIXELLAB_BASE = os.environ.get("PIXELLAB_BASE_URL", "https://api.pixellab.ai/v2").rstrip("/")
RD_BASE = os.environ.get("RD_BASE_URL", "https://api.retrodiffusion.ai/v1").rstrip("/")
PIXELLAB_KEY_NAME = "PIXELLAB_SECRET"
RD_KEY_NAME = "RETRO_DIFFUSION_API_KEY"
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# PixelLab serves its rotation PNGs from a Cloudflare-fronted bucket whose
# browser-integrity check answers `Python-urllib/3.x` with a 403 (error 1010).
# Sent on every request, not only those: a vendor edge that starts filtering
# tomorrow should not take a whole run down with an unexplained Forbidden.
USER_AGENT = "creative-harness-factory/1.0"
MAX_RETRIES = 3
POLL_INTERVAL_S = 3.0
POLL_CEILING_S = 600.0
# Pixel Fixer is free and rate-limited to 10 requests/minute per token; nothing
# else about it is documented, so the client simply never exceeds that.
FIXER_MIN_INTERVAL_S = 6.0

# The 4-direction order every character asset is written in. Fixed here so a
# re-run cannot reorder frames in an atlas.
DIRECTIONS = ("south", "east", "north", "west")

# Styles whose size range actually reaches 16-32 px. RD's mainline models start
# at 64 px, so asking one for a 32 px tile gets a downscaled 64 px picture with
# a broken grid — the single most expensive mistake available on this vendor.
RD_SMALL_STYLES = (
    "rd_plus__low_res", "rd_fast__low_res", "rd_mini__low_res",
    "rd_mini__fast_low_res", "rd_plus__classic", "rd_mini__classic",
    "rd_plus__topdown_item", "rd_mini__topdown_item",
    "rd_tile__single_tile", "rd_tile__tileset", "rd_tile__tileset_advanced",
    "rd_tile__tile_object", "rd_tile__tile_variation",
)

# Per-call USD, from PixelLab's own API page (the vendor calls them estimates
# that vary with GPU time). Used only for --dry-run and for the rare response
# that reports no usage at all; a real response always wins.
PIXELLAB_PRICE_USD = {
    "pixellab.image": 0.0079,
    "pixellab.tileset": 0.0079,
    "pixellab.character4": 0.0105,
    "pixellab.animate": 0.0221,
}


class FactoryError(Exception):
    pass


def valid_output_name(value):
    """Whether a user-controlled id is safe as one output-file basename."""
    return isinstance(value, str) and bool(SAFE_NAME_RE.fullmatch(value))


# --- secrets ----------------------------------------------------------------

def redact(text):
    """Everything this file prints goes through here first.

    Two passes on purpose: the literal key values (which is what a leak would
    actually be) and the header shapes (which is what a vendor error body
    echoes back when it quotes the request).
    """
    text = str(text)
    for name in (PIXELLAB_KEY_NAME, RD_KEY_NAME):
        v = os.environ.get(name)
        if v and len(v) > 6:
            text = text.replace(v, "<redacted:%s>" % name)
    text = re.sub(r"(?i)\b(authorization|x-rd-token)(\s*[:=]\s*)([^\s,\"']+)",
                  r"\1\2<redacted>", text)
    text = re.sub(r"(?i)\bbearer\s+[^\s,\"']+", "Bearer <redacted>", text)
    return text


def key(name):
    v = os.environ.get(name, "").strip()
    if not v:
        raise FactoryError("%s is not set — put it in $HARNESS_DIR/factory.conf.sh "
                           "(mode 600) and re-run" % name)
    return v


# --- HTTP -------------------------------------------------------------------

def _request(method, url, headers, body=None, timeout=180):
    data = None
    hdrs = {"User-Agent": USER_AGENT}
    hdrs.update(headers)
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def request_json(method, url, headers, body=None, timeout=180):
    """One vendor call, with the retry policy both vendors document.

    429 is honoured with the server's own Retry-After when it sends one; 5xx is
    backed off. Anything else is final — retrying a 400 just spends the same
    money on the same rejection, and both vendors document 400 as invalid input
    rather than as a wobble.
    """
    delay = 2.0
    for attempt in range(MAX_RETRIES + 1):
        try:
            _, raw = _request(method, url, headers, body, timeout)
            return json.loads(raw.decode() or "{}")
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode()[:600]
            except Exception:  # noqa: BLE001 - a body we cannot read is not the error
                pass
            retryable = exc.code == 429 or 500 <= exc.code < 600
            if not retryable or attempt == MAX_RETRIES:
                raise FactoryError(redact("%s %s -> HTTP %s %s"
                                          % (method, url, exc.code, detail)))
            wait = delay
            if exc.code == 429:
                hdr = (exc.headers or {}).get("Retry-After")
                if hdr:
                    try:
                        wait = max(wait, float(hdr))
                    except ValueError:
                        pass
            time.sleep(wait)
            delay *= 2
        except urllib.error.URLError as exc:
            if attempt == MAX_RETRIES:
                raise FactoryError(redact("%s %s -> %s" % (method, url, exc.reason)))
            time.sleep(delay)
            delay *= 2
    raise FactoryError("unreachable")


def pixellab_headers():
    return {"Authorization": "Bearer %s" % key(PIXELLAB_KEY_NAME)}


def rd_headers():
    return {"X-RD-Token": key(RD_KEY_NAME)}


def download(url, timeout=120):
    """Fetch a vendor-hosted PNG.

    Sent unauthenticated first: PixelLab's rotation URLs are pre-signed, and a
    stray Authorization header is how a pre-signed URL turns into a 403.
    """
    try:
        _, raw = _request("GET", url, {}, None, timeout)
        return raw
    except urllib.error.HTTPError as exc:
        if exc.code not in (401, 403):
            raise FactoryError(redact("GET %s -> HTTP %s" % (url, exc.code)))
    try:
        _, raw = _request("GET", url, pixellab_headers(), None, timeout)
        return raw
    except urllib.error.HTTPError as exc:
        raise FactoryError(redact("GET %s -> HTTP %s (unauthenticated too)"
                                  % (url, exc.code)))


# --- palette ----------------------------------------------------------------

def palette_b64(path, square=None):
    """The palette PNG as raw RGB base64 — what both vendors' palette fields want.

    Re-encoded through Pillow rather than base64'ing the file: an operator's
    palette may carry an alpha channel or a colour profile, and Retro Diffusion
    documents its base64 inputs as RGB with no transparency.

    `square` exists because /create-tileset rejects anything that is not
    64x64 ("Expected image of size 64x64 but got another size") while every
    other palette field takes the one-row swatch strip as-is. The strip is
    nearest-resized to `square` wide and repeated down, so every colour keeps
    an equal share of the area and none is interpolated into existence.
    """
    from PIL import Image
    with Image.open(path) as src:
        im = src.convert("RGB")
        if square:
            if im.width * im.height > square * square:
                raise FactoryError(
                    "%s has more colours than a %dx%d palette image can carry"
                    % (path, square, square))
            row = im.resize((square, 1), Image.Resampling.NEAREST)
            im = row.resize((square, square), Image.Resampling.NEAREST)
        buf = io.BytesIO()
        im.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


# --- the frozen contract ----------------------------------------------------
# One template and one style block per tool. `prompt` is the only part an asset
# entry writes; everything below it is the coherence rule, and `build_body()`
# applies it last so an entry cannot talk its way past it.

TOOLS = {
    "pixellab.image": {
        "vendor": "pixellab",
        "endpoint": "/create-image-pixflux",
        "template": "{prompt}, night, neon lit, wet reflections, latin lettering only",
        "style": {"view": "side", "outline": "single color black outline",
                  "shading": "basic shading", "detail": "low detail",
                  "text_guidance_scale": 8.0},
    },
    "pixellab.tileset": {
        "vendor": "pixellab",
        "endpoint": "/create-tileset",
        "template": "{prompt}, night, wet, neon spill",
        "style": {"view": "high top-down", "outline": "single color black outline",
                  "shading": "basic shading", "detail": "low detail",
                  "mode": "standard", "text_guidance_scale": 8.0},
    },
    "pixellab.character4": {
        "vendor": "pixellab",
        "endpoint": "/create-character-with-4-directions",
        "template": "{prompt}, night city, neon lit",
        "style": {"view": "low top-down", "outline": "single color black outline",
                  "shading": "basic shading", "detail": "low detail"},
    },
    "pixellab.animate": {
        "vendor": "pixellab",
        "endpoint": "/animate-with-text-v3",
        "template": "{prompt}",
        "style": {"drift_threshold": 0.1},
    },
    # Both RD tools submit async and poll. That is the vendor's own advice for
    # anything slower than a plain image, and it is not optional here: a
    # synchronous rd_tile__single_tile took this machine past a three-minute
    # socket read timeout and died with the tile already paid for.
    "rd.image": {
        "vendor": "rd",
        "endpoint": "/inferences",
        "template": "{prompt}, night, neon lit, wet reflections",
        "style": {"bypass_prompt_expansion": True, "num_images": 1,
                  "upscale_output_factor": 1, "async": True},
    },
    "rd.tile": {
        "vendor": "rd",
        "endpoint": "/inferences",
        "template": "{prompt}, night, wet, neon spill",
        # No tile_x/tile_y. Those flags make a MAINLINE style tile; on
        # rd_tile__single_tile, which is seamless by construction, they are the
        # difference between a tile and `400 inference_failed` — isolated by
        # running the same body with and without them.
        "style": {"bypass_prompt_expansion": True, "num_images": 1,
                  "upscale_output_factor": 1, "prompt_style": "rd_tile__single_tile",
                  "async": True},
    },
}


class DryFrames(dict):
    """Stand-in for the frames a --dry-run never generates.

    An animation's body needs a first frame that only a real call produces. A
    dry run still has to build (and price) that body, so it builds it against a
    placeholder — and never caches it, because the placeholder is not the
    picture the real run would send.
    """

    def __contains__(self, _key):
        return True

    def __getitem__(self, _key):
        return "<dry-run>"


def stable_seed(asset_id):
    return int(hashlib.sha256(asset_id.encode()).hexdigest()[:8], 16)


def _size(entry, default=32):
    return int(entry.get("width", default)), int(entry.get("height", default))


def build_body(entry, palettes, first_frames):
    """The exact JSON one asset becomes. Pure: same entry -> same bytes.

    `palettes` is None (no lock) or {"strip", "square64"} — the same colours in
    the two shapes the vendors accept.
    """
    pal_b64 = palettes["strip"] if palettes else None
    tool = TOOLS[entry["tool"]]
    prompt = tool["template"].format(prompt=entry.get("prompt", ""))
    seed = int(entry["seed"]) if "seed" in entry else stable_seed(entry["id"])
    name = entry["tool"]
    w, h = _size(entry)

    if name == "pixellab.image":
        body = {"description": prompt, "image_size": {"width": w, "height": h},
                "seed": seed}
        for k in ("no_background", "background_removal_task"):
            if k in entry:
                body[k] = entry[k]
        if pal_b64:
            body["color_image"] = {"type": "base64", "base64": pal_b64, "format": "png"}
        body.update(tool["style"])
        return body

    if name == "pixellab.tileset":
        ts = int(entry.get("tile_size", 16))
        body = {
            "lower_description": tool["template"].format(prompt=entry["lower"]),
            "upper_description": tool["template"].format(prompt=entry["upper"]),
            "tile_size": {"width": ts, "height": ts},
            "seed": seed,
        }
        if entry.get("transition"):
            body["transition_description"] = tool["template"].format(
                prompt=entry["transition"])
        if "transition_size" in entry:
            body["transition_size"] = float(entry["transition_size"])
        if palettes:
            body["color_image"] = {"type": "base64", "base64": palettes["square64"],
                                   "format": "png"}
        body.update(tool["style"])
        return body

    if name == "pixellab.character4":
        body = {"description": prompt, "image_size": {"width": w, "height": h},
                "seed": seed}
        if entry.get("template_id"):
            body["template_id"] = entry["template_id"]
        if pal_b64:
            body["color_image"] = {"type": "base64", "base64": pal_b64, "format": "png"}
            # force_colors is the character endpoint's own palette lock. It is a
            # bias, not a guarantee — the post-pass is what makes conformance
            # true — but it costs nothing and moves the starting point.
            body["force_colors"] = True
        body.update(tool["style"])
        return body

    if name == "pixellab.animate":
        src = entry["from"]
        if src not in first_frames:
            raise FactoryError(
                "%s: animate source %r was not produced by this list "
                "(available: %s)" % (entry["id"], src, ", ".join(sorted(first_frames))))
        count = int(entry.get("frame_count", 4))
        if count % 2 or not 4 <= count <= 16:
            raise FactoryError("%s: frame_count must be even and 4..16" % entry["id"])
        body = {"first_frame": {"type": "base64", "base64": first_frames[src],
                                "format": "png"},
                "action": prompt, "frame_count": count, "seed": seed}
        if "no_background" in entry:
            body["no_background"] = entry["no_background"]
        body.update(tool["style"])
        return body

    # Retro Diffusion. Both tools land on /v1/inferences; the difference is the
    # style, and the style is what the size limits hang off.
    style = entry.get("prompt_style", tool["style"].get("prompt_style", "rd_plus__low_res"))
    if style not in RD_SMALL_STYLES:
        raise FactoryError(
            "%s: prompt_style %r is a mainline style — at %dx%d it returns a "
            "downscaled 64 px image with a broken grid. Use one of: %s"
            % (entry["id"], style, w, h, ", ".join(RD_SMALL_STYLES)))
    body = {"prompt": prompt, "prompt_style": style, "width": w, "height": h,
            "seed": seed}
    if entry.get("remove_bg"):
        body["remove_bg"] = True
    if pal_b64:
        body["input_palette"] = pal_b64
    body.update(tool["style"])
    body["prompt_style"] = style
    return body


# --- price estimation -------------------------------------------------------

def rd_price_usd(body):
    """Retro Diffusion's published formulas (llms.txt, "Costs")."""
    style = body.get("prompt_style", "")
    n = int(body.get("num_images", 1))
    area = int(body.get("width", 0)) * int(body.get("height", 0))
    if style.startswith("rd_tile__tileset"):
        return 0.10
    if style.startswith("rd_pro__"):
        return 0.18 * n
    if style.startswith("rd_advanced_animation__"):
        return 0.25 if style.endswith(("custom_action", "subtle_motion")) else 0.14
    if style.startswith("rd_animation__"):
        return 0.25 if style.endswith(("any_animation", "8_dir_rotation")) else 0.07
    low_res = ("low_res", "mc_item", "mc_texture", "classic", "skill_icon",
               "topdown_item")
    if style.startswith("rd_tile__") or style.endswith(low_res):
        return max(0.02, (area + 13700) / 600000.0) * n
    if style.startswith("rd_plus__"):
        return max(0.025, (area + 50000) / 2000000.0) * n
    return max(0.015, (area + 100000) / 6000000.0) * n


def estimate_usd(tool_name, body):
    if TOOLS[tool_name]["vendor"] == "rd":
        return rd_price_usd(body)
    return PIXELLAB_PRICE_USD.get(tool_name, 0.01)


def usage_cost(tool_name, body, response):
    """What the call actually cost, or the formula's guess flagged as one."""
    if TOOLS[tool_name]["vendor"] == "rd":
        spent = response.get("balance_cost")
        if spent is not None:
            return {"usd": round(float(spent), 6),
                    "credits": round(float(spent) * 100.0, 2), "estimated": False}
    else:
        usage = response.get("usage") or {}
        if usage.get("type") == "generations" and usage.get("generations") is not None:
            return {"generations": float(usage["generations"]), "estimated": False}
        if usage.get("usd") is not None:
            return {"usd": round(float(usage["usd"]), 6), "estimated": False}
    return {"usd": round(estimate_usd(tool_name, body), 6), "estimated": True}


# --- calls ------------------------------------------------------------------

def poll_pixellab_job(job_id, ceiling=POLL_CEILING_S):
    url = "%s/background-jobs/%s" % (PIXELLAB_BASE, job_id)
    waited = 0.0
    while True:
        job = request_json("GET", url, pixellab_headers())
        status = (job.get("status") or "").lower()
        if status in ("completed", "succeeded", "success"):
            return job
        if status in ("failed", "error", "cancelled"):
            raise FactoryError(redact("background job %s failed: %s"
                                      % (job_id, json.dumps(job)[:400])))
        if waited >= ceiling:
            raise FactoryError("background job %s still %s after %.0fs"
                               % (job_id, status or "unknown", ceiling))
        time.sleep(POLL_INTERVAL_S)
        waited += POLL_INTERVAL_S


def poll_rd_task(task_id, ceiling=POLL_CEILING_S):
    url = "%s/inferences/tasks/%s" % (RD_BASE, task_id)
    waited = 0.0
    while True:
        task = request_json("GET", url, rd_headers())
        status = (task.get("status") or "").lower()
        if status == "succeeded":
            return task.get("result") or {}
        if status == "failed":
            raise FactoryError(redact("RD task %s failed: %s"
                                      % (task_id, json.dumps(task.get("error"))[:400])))
        if waited >= ceiling:
            raise FactoryError("RD task %s still %s after %.0fs"
                               % (task_id, status or "unknown", ceiling))
        time.sleep(POLL_INTERVAL_S)
        waited += POLL_INTERVAL_S


def collect_b64(node, out):
    """Every base64 image in a response, in document order.

    PixelLab's completed jobs report their result under `last_response`, whose
    shape differs per endpoint. Walking for the one thing they all agree on —
    a Base64Image object — beats hard-coding four container names that the next
    endpoint version can rename.
    """
    if isinstance(node, dict):
        if isinstance(node.get("base64"), str) and node["base64"]:
            out.append(node["base64"])
            return
        for k in sorted(node):
            collect_b64(node[k], out)
    elif isinstance(node, list):
        for item in node:
            collect_b64(item, out)


def merge_usage(response, *completed):
    """Keep the first usage record reported across submit/final responses."""
    out = dict(response)
    if out.get("usage"):
        return out
    for node in completed:
        if not isinstance(node, dict):
            continue
        usage = node.get("usage")
        if not usage and isinstance(node.get("last_response"), dict):
            usage = node["last_response"].get("usage")
        if usage:
            out["usage"] = usage
            break
    return out


def run_call(tool_name, body):
    """Make the call; return (response, [(suffix, base64png), ...]).

    Suffixes are what the file names hang off, so they are decided here and
    never later: "" for a single image, "-<direction>" for a character,
    "-f<NN>" for animation frames, "-t<NN>" for tileset tiles.
    """
    tool = TOOLS[tool_name]
    if tool["vendor"] == "rd":
        url = RD_BASE + tool["endpoint"]
        resp = request_json("POST", url, rd_headers(), body)
        if resp.get("status") == "accepted" and resp.get("task_id"):
            resp = poll_rd_task(resp["task_id"])
        images = resp.get("base64_images") or []
        if not images:
            raise FactoryError(redact("RD returned no image: %s"
                                      % json.dumps(resp)[:400]))
        return resp, [("", images[0])]

    url = PIXELLAB_BASE + tool["endpoint"]
    resp = request_json("POST", url, pixellab_headers(), body)

    if tool_name == "pixellab.image":
        b64 = ((resp.get("image") or {}).get("base64"))
        if not b64:
            raise FactoryError(redact("PixelLab returned no image: %s"
                                      % json.dumps(resp)[:400]))
        return resp, [("", b64)]

    job_id = resp.get("background_job_id")
    if not job_id:
        raise FactoryError(redact("PixelLab returned no background_job_id: %s"
                                  % json.dumps(resp)[:400]))
    job = poll_pixellab_job(job_id)

    if tool_name == "pixellab.tileset":
        tileset_id = resp.get("tileset_id")
        detail = request_json("GET", "%s/tilesets/%s" % (PIXELLAB_BASE, tileset_id),
                              pixellab_headers())
        tiles = ((detail.get("tileset") or {}).get("tiles")) or []
        if not tiles:
            raise FactoryError("tileset %s came back with no tiles" % tileset_id)
        out = []
        for i, tile in enumerate(tiles):
            b64 = (tile.get("image") or {}).get("base64")
            if not b64:
                raise FactoryError("tileset %s tile %d came back with no image"
                                   % (tileset_id, i))
            out.append(("-t%02d" % i, b64))
        resp = merge_usage(resp, detail, job)
        resp["tile_names"] = [t.get("name") for t in tiles]
        return resp, out

    if tool_name == "pixellab.character4":
        char_id = resp.get("character_id")
        detail = request_json("GET", "%s/characters/%s" % (PIXELLAB_BASE, char_id),
                              pixellab_headers())
        urls = detail.get("rotation_urls") or {}
        out = []
        for d in DIRECTIONS:
            if urls.get(d):
                out.append(("-" + d, base64.b64encode(download(urls[d])).decode()))
        if not out:
            found = []
            collect_b64(detail, found)
            out = [("-" + DIRECTIONS[i], b) for i, b in enumerate(found[:4])]
        if len(out) != len(DIRECTIONS):
            found = {suffix.lstrip("-") for suffix, _ in out}
            missing = [direction for direction in DIRECTIONS if direction not in found]
            raise FactoryError("character %s came back without rotations: %s"
                               % (char_id, ", ".join(missing)))
        return merge_usage(resp, job), out

    # pixellab.animate
    frames = []
    collect_b64(job.get("last_response"), frames)
    if not frames:
        collect_b64(job, frames)
    if not frames:
        raise FactoryError(redact("animation job %s produced no frames: %s"
                                  % (job_id, json.dumps(job)[:400])))
    return merge_usage(resp, job), [("-f%02d" % i, b) for i, b in enumerate(frames)]


def rd_pixel_fixer(b64_png):
    """RD's free grid reconstruction. Imported by postpass.py.

    The one honest way to repair an off-grid sprite: every home-made pitch
    detector tried on this machine (gradient peaks, FFT, MSE minimum) returned
    a wrong pitch on real art, and a wrong pitch resamples the sprite into
    mush that still passes a naive check.
    """
    resp = request_json("POST", "%s/pixel-fixer/standard" % RD_BASE, rd_headers(),
                        {"input_image": b64_png})
    images = resp.get("base64_images") or []
    if not images:
        raise FactoryError(redact("pixel-fixer returned no image: %s"
                                  % json.dumps(resp)[:300]))
    return images[0]


# --- cache ------------------------------------------------------------------

def body_hash(tool_name, endpoint, body):
    payload = json.dumps({"tool": tool_name, "endpoint": endpoint, "body": body},
                         sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def cache_read(cache_dir, digest):
    meta_path = os.path.join(cache_dir, digest + ".json")
    if not os.path.exists(meta_path):
        return None
    with open(meta_path) as fh:
        meta = json.load(fh)
    images = []
    for item in meta.get("images", []):
        png = os.path.join(cache_dir, item["file"])
        if not os.path.exists(png):
            return None
        with open(png, "rb") as fh:
            images.append((item["suffix"], base64.b64encode(fh.read()).decode()))
    return meta, images


def cache_write(cache_dir, digest, response, images):
    os.makedirs(cache_dir, exist_ok=True)
    entries = []
    for suffix, b64 in images:
        name = "%s%s.png" % (digest, suffix)
        with open(os.path.join(cache_dir, name), "wb") as fh:
            fh.write(base64.b64decode(b64))
        entries.append({"suffix": suffix, "file": name})
    meta = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "response": scrub(response), "images": entries}
    with open(os.path.join(cache_dir, digest + ".json"), "w") as fh:
        json.dump(meta, fh, indent=2, sort_keys=True)
    return meta


# Fields that carry image bytes, by name. Digested by key rather than by length
# because a 32-colour palette encodes to fewer characters than a prompt does,
# so a length rule alone keeps the blob and loses nothing else.
B64_KEYS = frozenset((
    "base64", "input_palette", "first_frame", "last_frame", "init_image",
    "input_image", "mask_image", "base64_images", "reference_images",
))


def scrub(node, field=None):
    """A copy of a request or response with image bytes replaced by digests.

    The manifest is committed and read by people; a palette blob repeated on
    every entry would bury the parameters that actually differ, and an image
    echoed back by a vendor would bloat it by megabytes. The digest is kept so
    "same palette on every call" stays checkable at a glance.
    """
    if isinstance(node, dict):
        return {k: scrub(v, k) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v, field) for v in node]
    if isinstance(node, str) and (field in B64_KEYS or len(node) > 256):
        return "<base64:%s:%dB>" % (hashlib.sha256(node.encode()).hexdigest()[:12],
                                    len(node))
    return node


# --- commands ---------------------------------------------------------------

def cmd_balance(_args):
    """Both vendors, before and after a run — the only spend figure worth quoting."""
    status = 0
    try:
        b = request_json("GET", PIXELLAB_BASE + "/balance", pixellab_headers())
        credits = (b.get("credits") or {}).get("usd")
        sub = b.get("subscription") or {}
        print("pixellab: $%.2f credits, subscription %s, %s/%s generations"
              % (float(credits or 0), sub.get("status") or "none",
                 sub.get("generations"), sub.get("total")))
    except FactoryError as exc:
        print("pixellab: %s" % redact(exc), file=sys.stderr)
        status = 1
    try:
        b = request_json("GET", RD_BASE + "/inferences/credits", rd_headers())
        print("retro-diffusion: %s credits, $%.2f balance"
              % (b.get("credits"), float(b.get("balance") or 0)))
    except FactoryError as exc:
        print("retro-diffusion: %s" % redact(exc), file=sys.stderr)
        status = 1
    return status


def load_assets(path, only):
    with open(path) as fh:
        assets = json.load(fh)
    if not isinstance(assets, list):
        raise FactoryError("%s must be a JSON list of asset entries" % path)
    seen = set()
    for entry in assets:
        if not isinstance(entry, dict):
            raise FactoryError("asset entries must be JSON objects, got %r" % entry)
        for field in ("id", "tool"):
            if field not in entry:
                raise FactoryError("asset entry missing %r: %s"
                                   % (field, json.dumps(entry)[:200]))
        if not valid_output_name(entry["id"]):
            raise FactoryError(
                "asset id %r must start with a letter or digit and contain only "
                "letters, digits, dot, underscore or hyphen" % entry["id"])
        if not isinstance(entry["tool"], str) or entry["tool"] not in TOOLS:
            raise FactoryError("%s: unknown tool %r (known: %s)"
                               % (entry["id"], entry["tool"], ", ".join(sorted(TOOLS))))
        if entry["id"] in seen:
            raise FactoryError("duplicate asset id %r" % entry["id"])
        seen.add(entry["id"])
    # Sorted by id, and animations last: an animation's first frame is another
    # asset's output, so the pass that needs it runs after the pass that makes
    # it. Two ordered phases beat a dependency graph nobody can predict the
    # output filenames of.
    assets.sort(key=lambda e: e["id"])
    if only:
        wanted = set(only)
        assets = [e for e in assets if e["id"] in wanted]
        missing = wanted - {e["id"] for e in assets}
        if missing:
            raise FactoryError("--only names unknown assets: %s"
                               % ", ".join(sorted(missing)))
    return ([e for e in assets if e["tool"] != "pixellab.animate"]
            + [e for e in assets if e["tool"] == "pixellab.animate"])


def cmd_gen(args):
    assets = load_assets(args.assets, args.only)
    pal = None
    if args.palette:
        pal = {"strip": palette_b64(args.palette),
               "square64": palette_b64(args.palette, 64)}
    raw_dir = os.path.join(args.out, "raw")
    cache_dir = os.path.join(args.out, ".cache")
    os.makedirs(raw_dir, exist_ok=True)

    # "<id>" and "<id>#<suffix>" -> base64, the pool pixellab.animate draws its
    # first frame from.
    first_frames = DryFrames() if args.dry_run else {}
    manifest = []
    calls = 0
    estimated_total = 0.0
    stopped = None

    for entry in assets:
        tool_name = entry["tool"]
        tool = TOOLS[tool_name]
        body = build_body(entry, pal, first_frames)
        digest = body_hash(tool_name, tool["endpoint"], body)
        record = {
            "id": entry["id"], "tool": tool_name, "vendor": tool["vendor"],
            "endpoint": tool["endpoint"], "seed": body.get("seed"),
            "params": scrub(body), "cached": False,
        }

        if args.dry_run:
            usd = estimate_usd(tool_name, body)
            estimated_total += usd
            print("would call %-20s %-36s %s  ~$%.4f"
                  % (tool_name, tool["endpoint"], entry["id"], usd))
            record["cost"] = {"usd": round(usd, 6), "estimated": True}
            record["files"] = []
            manifest.append(record)
            continue

        hit = cache_read(cache_dir, digest)
        if hit:
            meta, images = hit
            response = meta.get("response") or {}
            record["cached"] = True
            record["generated_at"] = meta.get("generated_at")
        else:
            if args.max_calls is not None and calls >= args.max_calls:
                stopped = "--max-calls %d reached" % args.max_calls
                break
            response, images = run_call(tool_name, body)
            calls += 1
            meta = cache_write(cache_dir, digest, response, images)
            record["generated_at"] = meta["generated_at"]

        record["cost"] = usage_cost(tool_name, body, response)
        if tool_name == "pixellab.tileset" and response.get("tile_names"):
            record["tile_names"] = response["tile_names"]

        files = []
        for suffix, b64 in images:
            name = "%s%s.png" % (entry["id"], suffix)
            data = base64.b64decode(b64)
            with open(os.path.join(raw_dir, name), "wb") as fh:
                fh.write(data)
            files.append({"file": "raw/" + name,
                          "sha256": hashlib.sha256(data).hexdigest()})
            first_frames["%s#%s" % (entry["id"], suffix.lstrip("-"))] = b64
        if images:
            first_frames[entry["id"]] = images[0][1]
        record["files"] = files
        record["sha256"] = files[0]["sha256"] if files else None
        manifest.append(record)
        print("%-8s %-20s %-24s %d file(s)"
              % ("cached" if record["cached"] else "made", tool_name, entry["id"],
                 len(files)))

    manifest.sort(key=lambda r: r["id"])
    totals = {"calls": calls, "assets": len(manifest),
              "usd": round(sum((r["cost"].get("usd") or 0.0) for r in manifest), 4),
              "generations": round(sum((r["cost"].get("generations") or 0.0)
                                       for r in manifest), 2),
              "credits": round(sum((r["cost"].get("credits") or 0.0)
                                   for r in manifest), 2)}
    if not args.dry_run:
        out = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "palette": args.palette or None, "totals": totals, "assets": manifest}
        with open(os.path.join(args.out, "manifest.json"), "w") as fh:
            json.dump(out, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print("manifest: %s (%d assets, %d call(s), $%.4f, %.0f generation(s))"
              % (os.path.join(args.out, "manifest.json"), len(manifest), calls,
                 totals["usd"], totals["generations"]))
    else:
        print("dry run: %d call(s) would be made, ~$%.4f"
              % (len(manifest), estimated_total))
    if stopped:
        print("stopped: %s" % stopped, file=sys.stderr)
        return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")

    b = sub.add_parser("balance", help="credits at both vendors")
    b.set_defaults(func=cmd_balance)

    g = sub.add_parser("gen", help="generate an asset list")
    g.add_argument("--assets", required=True)
    g.add_argument("--out", required=True)
    g.add_argument("--palette", default="")
    g.add_argument("--only", nargs="*", default=[])
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--max-calls", type=int, default=None)
    g.set_defaults(func=cmd_gen)

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    try:
        return args.func(args)
    except FactoryError as exc:
        sys.stderr.write("factory.py: %s\n" % redact(exc))
        return 1
    except (OSError, TypeError, ValueError, KeyError) as exc:
        sys.stderr.write("factory.py: %s\n" % redact(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
