#!/usr/bin/env python3
"""The post-pass — what turns "a model made a picture" into "a game has an asset".

Nothing a diffusion model emits is game-ready. Palette lock is a bias, not a
guarantee; transparency comes back feathered; an upscaled sprite carries a grid
that is only approximately a grid. So every asset goes through the same four
deterministic steps and is then *asserted*, in that order, and an asset that
cannot pass fails loudly with a reason rather than shipping and being noticed
on a TV three weeks later.

  1. **grid** — with `--pitch N`, an image that is a true N-times upscale (dims
     multiples of N, every NxN block one colour) is block-sampled back to
     native size. If the blocks are not uniform the pitch is NOT guessed: every
     home-made detector tried on this machine returned a wrong pitch on real
     art (gradient peaks said 3 for a true 7, FFT said 44, and reconstruction
     MSE falls monotonically so its global minimum is always 2). `--fix-grid rd`
     hands the image to Retro Diffusion's free Pixel Fixer instead; without it
     the asset fails "off-grid, no fixer".
  2. **palette** — `convert('RGB').quantize(palette=P, dither=NONE)` against a
     P-mode LUT built from the palette PNG. Dithering is the enemy here: it
     buys perceptual accuracy by scattering pixels, which is precisely what a
     16 px sprite cannot afford.
  3. **alpha** — `A = 255 if A >= 128 else 0`, and the RGB of every transparent
     pixel zeroed. The zeroing is not cosmetic: premultiplied edge colour left
     under a transparent pixel is what draws a halo around a sprite the moment
     anything scales it.
  4. **asserts** — alphas within {0, 255}, every opaque pixel exactly on the
     LUT, `--tile` dimensions exact. Then `--atlas NAME` packs everything that
     passed into a Phaser 3 JSON-hash atlas.

The atlas shape is the one `Phaser.Textures.Parsers.JSONHash` reads: a `frames`
OBJECT keyed by frame name, each `{frame:{x,y,w,h}, rotated, trimmed,
spriteSourceSize, sourceSize}`, plus `meta`. Verified against phaser
v3.90.0 `src/textures/parsers/JSONHash.js`, which indexes `frames[key].frame.x`
and only consults `sourceSize`/`spriteSourceSize` when `trimmed` is true — this
packer never trims and never rotates, because trimming destroys the bounding
box stability that per-frame drift checks depend on.

Usage:
  postpass.py --in DIR --out DIR --palette PNG [--pitch N] [--tile WxH]
              [--atlas NAME] [--fix-grid rd] [--report FILE]

Only assets that pass are written to --out. Exit status is 1 if any asset
failed, after every asset has been processed — one run tells you everything
that is wrong, not the first thing.
"""
import argparse
import base64
import io
import json
import os
import sys
import time

import numpy as np
from PIL import Image

# vcheck.py owns this repo's definition of "off-palette"; factory.py owns every
# vendor call and the secret redaction that goes with one. Both sit beside this
# file, so the path insert precedes the imports.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import factory  # noqa: E402
import vcheck  # noqa: E402

ATLAS_APP = "profiles/visual/creative/postpass.py"
ATLAS_VERSION = "1.0"


# --- palette ----------------------------------------------------------------

def load_lut(path):
    """The palette PNG as an (N, 3) uint8 LUT, in file order."""
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8).reshape(-1, 3)
    if a.shape[0] == 0:
        raise ValueError("%s holds no colours" % path)
    if a.shape[0] > 256:
        raise ValueError("%s holds %d colours; a LUT tops out at 256"
                         % (path, a.shape[0]))
    return a


def lut_image(lut):
    """A P-mode image carrying the LUT, padded by REPEATING the last colour.

    Pillow zero-fills a short palette to 256 entries, and a zero entry is
    opaque black — a colour the LUT may not contain, which quantisation is then
    free to pick. Repeating the last real colour makes the padding unreachable
    as a *new* colour: whichever index wins, its RGB is still in the LUT, so
    "100 % palette-conformant" is true by construction rather than by luck.
    """
    flat = []
    for rgb in lut:
        flat.extend(int(c) for c in rgb)
    tail = flat[-3:]
    while len(flat) < 768:
        flat.extend(tail)
    p = Image.new("P", (1, 1))
    p.putpalette(flat[:768])
    return p


def quantize_to_lut(rgb, pal_img):
    q = Image.fromarray(rgb, "RGB").quantize(palette=pal_img,
                                             dither=Image.Dither.NONE)
    # np.array, not np.asarray: a view over Pillow's own buffer is read-only,
    # and step 3 writes into this array to zero the transparent pixels.
    return np.array(q.convert("RGB"), dtype=np.uint8)


# --- grid -------------------------------------------------------------------

def blocks_uniform(a, pitch):
    """True when the image is a pixel-exact `pitch`x upscale."""
    h, w = a.shape[0], a.shape[1]
    if pitch <= 1 or h % pitch or w % pitch:
        return False
    b = a.reshape(h // pitch, pitch, w // pitch, pitch, a.shape[2])
    return bool((b == b[:, :1, :, :1, :]).all())


def png_b64(a):
    buf = io.BytesIO()
    Image.fromarray(a, "RGBA").save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def b64_png(b64):
    return np.asarray(Image.open(io.BytesIO(base64.b64decode(b64))).convert("RGBA"),
                      dtype=np.uint8)


class Fixer:
    """RD's Pixel Fixer, rate-limited to the 10 requests/minute it documents."""

    def __init__(self, enabled):
        self.enabled = enabled
        self.last = 0.0

    def available(self):
        return self.enabled and bool(os.environ.get(factory.RD_KEY_NAME, "").strip())

    def fix(self, a):
        gap = factory.FIXER_MIN_INTERVAL_S - (time.time() - self.last)
        if gap > 0:
            time.sleep(gap)
        out = b64_png(factory.rd_pixel_fixer(png_b64(a)))
        self.last = time.time()
        return out


def fix_grid(a, pitch, fixer, reasons):
    """Return the on-grid array, or None if this asset cannot be repaired."""
    if pitch <= 1:
        return a
    if blocks_uniform(a, pitch):
        return a[::pitch, ::pitch]
    if not fixer.available():
        reasons.append("off-grid, no fixer: not a clean %dx upscale and "
                       "--fix-grid rd is unavailable (never guess a pitch)" % pitch)
        return None
    before = (a.shape[1], a.shape[0])
    try:
        fixed = fixer.fix(a)
    except factory.FactoryError as exc:
        reasons.append("off-grid: pixel-fixer failed (%s)" % factory.redact(exc))
        return None
    if blocks_uniform(fixed, pitch):
        return fixed[::pitch, ::pitch]
    if (fixed.shape[1], fixed.shape[0]) != before:
        # The fixer resolved the image to its own native grid; that IS the
        # repair, and re-sampling it again would undo the work.
        return fixed
    reasons.append("off-grid: still not a clean %dx upscale after the RD pixel-fixer"
                   % pitch)
    return None


# --- one asset --------------------------------------------------------------

def measure(a, lut):
    """The numbers the report carries, opaque pixels only.

    Transparent pixels are excluded on purpose: step 3 zeroes their RGB, and
    counting that black against a palette that may not contain it would report
    every correctly-cleaned sprite as off-palette. "Opaque" is the same
    `>= 128` cut step 3 applies, so before and after count the same pixels —
    with an `== 255` cut a feathered sprite would report zero colours before
    and twenty after, which reads as an invention rather than a clean-up.
    """
    alphas = np.unique(a[..., 3])
    opaque = a[a[..., 3] >= 128][:, :3].astype(np.float32)
    if opaque.size:
        off, _ = vcheck.palette_conformance(opaque, lut.astype(np.float32), tol=0.0)
        colors = int(np.unique(opaque.astype(np.uint8).reshape(-1, 3), axis=0).shape[0])
    else:
        off, colors = 0.0, 0
    return {"colors": colors, "alphas": int(alphas.shape[0]),
            "offpalette_pct": round(float(off), 3),
            "size": [int(a.shape[1]), int(a.shape[0])]}


def process(path, lut, pal_img, pitch, tile, fixer):
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)
    reasons = []
    before = measure(a, lut)

    a = fix_grid(a, pitch, fixer, reasons)
    if a is None:
        return None, before, None, reasons

    rgb = quantize_to_lut(np.ascontiguousarray(a[..., :3]), pal_img)
    alpha = np.where(a[..., 3] >= 128, 255, 0).astype(np.uint8)
    rgb[alpha == 0] = 0
    out = np.dstack([rgb, alpha])

    after = measure(out, lut)
    alpha_values = sorted(int(v) for v in np.unique(alpha))
    after["alpha_values"] = alpha_values
    if not set(alpha_values) <= {0, 255}:
        reasons.append("alpha is not binary: %s" % alpha_values)
    if after["offpalette_pct"] > 0:
        reasons.append("%.2f%% of opaque pixels are off the palette after quantisation"
                       % after["offpalette_pct"])
    if tile and (out.shape[1], out.shape[0]) != tile:
        reasons.append("expected %dx%d, got %dx%d"
                       % (tile[0], tile[1], out.shape[1], out.shape[0]))
    return out, before, after, reasons


# --- atlas ------------------------------------------------------------------

def pack(frames, padding=1):
    """Shelf packing: rows by descending height, ties broken by id.

    No rotation, no trim, one pixel of padding on every side including the
    sheet's edge, and a power-of-two sheet. Deterministic from the id list
    alone, which is the property that lets a committed atlas be diffed.
    """
    order = sorted(frames, key=lambda f: (-f[2], f[0]))
    area = sum((f[1].shape[1] + padding) * (f[2] + padding) for f in order)
    widest = max((f[1].shape[1] for f in order), default=1) + 2 * padding
    side = 1
    while side * side < area or side < widest:
        side *= 2
    while True:
        placed, x, y, row_h, ok = {}, padding, padding, 0, True
        for fid, arr, h in order:
            w = arr.shape[1]
            if x + w + padding > side:
                x = padding
                y += row_h + padding
                row_h = 0
            if y + h + padding > side:
                ok = False
                break
            placed[fid] = (x, y, w, h)
            x += w + padding
            row_h = max(row_h, h)
        if ok:
            return side, placed
        side *= 2


def build_atlas(name, entries, out_dir):
    frames = [(fid, arr, arr.shape[0]) for fid, arr in entries]
    side, placed = pack(frames)
    used_h = max((y + h + 1) for (_, y, _, h) in placed.values())
    height = 1
    while height < used_h:
        height *= 2
    sheet = np.zeros((height, side, 4), dtype=np.uint8)
    out = {}
    for fid, arr in sorted(entries, key=lambda e: e[0]):
        x, y, w, h = placed[fid]
        sheet[y:y + h, x:x + w] = arr
        out[fid] = {
            "frame": {"x": x, "y": y, "w": w, "h": h},
            "rotated": False,
            "trimmed": False,
            "spriteSourceSize": {"x": 0, "y": 0, "w": w, "h": h},
            "sourceSize": {"w": w, "h": h},
        }
    png = os.path.join(out_dir, name + ".png")
    Image.fromarray(sheet, "RGBA").save(png)
    data = {
        "frames": out,
        "meta": {"app": ATLAS_APP, "version": ATLAS_VERSION,
                 "image": name + ".png", "format": "RGBA8888",
                 "size": {"w": side, "h": height}, "scale": 1},
    }
    with open(os.path.join(out_dir, name + ".json"), "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return png, data


# --- main -------------------------------------------------------------------

def parse_tile(s):
    if not s:
        return None
    parts = s.replace("×", "x").replace("X", "x").split("x")
    if len(parts) != 2:
        raise ValueError("--tile wants WxH, got %r" % s)
    tile = int(parts[0]), int(parts[1])
    if min(tile) < 1:
        raise ValueError("--tile dimensions must be positive, got %r" % s)
    return tile


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--in", dest="src", required=True)
    ap.add_argument("--out", dest="dst", required=True)
    ap.add_argument("--palette", required=True)
    ap.add_argument("--pitch", type=int, default=1)
    ap.add_argument("--tile", default="")
    ap.add_argument("--atlas", default="")
    ap.add_argument("--fix-grid", dest="fix_grid", choices=["rd"], default="")
    ap.add_argument("--report", default="")
    args = ap.parse_args()

    try:
        lut = load_lut(args.palette)
        tile = parse_tile(args.tile)
        if args.pitch < 1:
            raise ValueError("--pitch must be a positive integer")
        if args.atlas and not factory.valid_output_name(args.atlas):
            raise ValueError(
                "--atlas must start with a letter or digit and contain only "
                "letters, digits, dot, underscore or hyphen")
    except (OSError, ValueError) as exc:
        sys.stderr.write("postpass.py: %s\n" % exc)
        return 2
    pal_img = lut_image(lut)
    fixer = Fixer(args.fix_grid == "rd")
    os.makedirs(args.dst, exist_ok=True)

    try:
        names = sorted(f for f in os.listdir(args.src) if f.lower().endswith(".png"))
    except OSError as exc:
        sys.stderr.write("postpass.py: %s\n" % exc)
        return 2
    if not names:
        sys.stderr.write("postpass.py: no PNGs in %s\n" % args.src)
        return 2
    if args.atlas and (args.atlas + ".png") in names:
        sys.stderr.write("postpass.py: --atlas %r collides with an input asset\n"
                         % args.atlas)
        return 2

    assets, passing, failed = [], [], 0
    for fname in names:
        asset_id = fname[:-4]
        output_path = os.path.join(args.dst, fname)
        # A failed re-run must not leave yesterday's passing sprite in place.
        # Remove only the exact managed basename; unrelated files stay untouched.
        if os.path.exists(output_path):
            os.remove(output_path)
        try:
            out, before, after, reasons = process(os.path.join(args.src, fname), lut,
                                                  pal_img, args.pitch, tile, fixer)
        except (OSError, ValueError) as exc:
            out, before, after = None, None, None
            reasons = ["invalid PNG: %s" % exc]
        good = out is not None and not reasons
        if good:
            Image.fromarray(out, "RGBA").save(output_path)
            passing.append((asset_id, out))
        else:
            failed += 1
        assets.append({"id": asset_id, "before": before, "after": after,
                       "pass": good, "reasons": reasons})
        print("%-6s %-28s %s" % ("ok" if good else "FAIL", asset_id,
                                 "; ".join(reasons) if reasons else
                                 "%d colours, alphas %s"
                                 % (after["colors"], after["alpha_values"])))

    report = {"palette": args.palette, "palette_entries": int(lut.shape[0]),
              "pitch": args.pitch, "tile": list(tile) if tile else None,
              "assets": assets, "passed": len(passing), "failed": failed,
              "pass": failed == 0}
    if args.atlas:
        for suffix in (".png", ".json"):
            atlas_path = os.path.join(args.dst, args.atlas + suffix)
            if os.path.exists(atlas_path):
                os.remove(atlas_path)
    if args.atlas and passing:
        png, data = build_atlas(args.atlas, passing, args.dst)
        report["atlas"] = {"image": png, "json": png[:-4] + ".json",
                           "frames": len(data["frames"]),
                           "size": data["meta"]["size"]}
        print("atlas: %s (%d frames, %dx%d)"
              % (png, len(data["frames"]), data["meta"]["size"]["w"],
                 data["meta"]["size"]["h"]))

    text = json.dumps(report, indent=2, sort_keys=True)
    if args.report:
        with open(args.report, "w") as fh:
            fh.write(text + "\n")
    print("post-pass: %d passed, %d failed" % (len(passing), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
