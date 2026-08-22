#!/usr/bin/env python3
"""The palette LUT — the single lock artefact of a creative repo.

One file, one job: turn reference images into the fixed list of colours that
every later stage is measured against. The factory sends it to the vendors
(`color_image` / `input_palette`), the post-pass re-quantises against it, the
visual gate's palette check reads it, and the bible links to it. If those four
disagreed about what "the palette" is, none of them would mean anything.

FORMAT — a PNG one row tall, one 1x1 swatch per colour, RGB, in index order.
Deliberately the dumbest thing that works: `creative/vcheck.py` already reads a
palette as `np.asarray(Image.open(p).convert("RGB")).reshape(-1, 3)`, so any
shape would load, and a single row is the one shape a human can also open and
read left to right. Index order is preserved on write and never re-sorted —
Pillow's fixed-LUT quantisation keeps indices, and an index that moves between
runs would silently rewrite every asset already on disk.

Usage:
  palette.py extract IMG... --colors N --out PNG [--hex "#a,#b,..."]
  palette.py show PNG
  palette.py check IMG... --palette PNG [--tol T]

`extract` runs Pillow median cut over every input's pixels at once, so a colour
that is rare in one reference and common in another is weighted by its total
share rather than by which file it came from. `--hex` colours are forced into
the result first and the median cut fills what is left — that is how a token
from a stylesheet (an exact value somebody chose) survives beside colours
sampled from a render (values a compositor happened to produce).

`check` exits 1 when any visible pixel is farther than `--tol` from every entry,
so it is usable as a gate step and not only as a report. RGB beneath transparent
pixels is ignored; the post-pass deliberately zeroes it to prevent scaling halos.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

# vcheck.py is the gate's checks module and sits beside this file; importing it
# rather than re-deriving conformance keeps one definition of "off-palette" in
# the repo. The path insert has to precede the import, so this is not the usual
# import block.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vcheck  # noqa: E402

MAX_COLORS = 256


def parse_hex(s):
    """"#1a2b3c, 1a2b3c" -> [(26, 43, 60), ...]. Order preserved, dupes dropped."""
    out = []
    for raw in s.split(","):
        t = raw.strip().lstrip("#")
        if not t:
            continue
        if len(t) != 6 or any(c not in "0123456789abcdefABCDEF" for c in t):
            raise ValueError("not a 6-digit hex colour: %s" % raw.strip())
        rgb = tuple(int(t[i:i + 2], 16) for i in (0, 2, 4))
        if rgb not in out:
            out.append(rgb)
    return out


def to_hex(rgb):
    return "#%02x%02x%02x" % tuple(int(c) for c in rgb)


def load_pixels(paths):
    """Every input's pixels as one (N, 3) uint8 array."""
    chunks = []
    for p in paths:
        a = np.asarray(Image.open(p).convert("RGB"), dtype=np.uint8)
        chunks.append(a.reshape(-1, 3))
    if not chunks:
        raise ValueError("no input images")
    return np.concatenate(chunks, axis=0)


def as_image(px):
    """(N, 3) pixels -> an Image median cut can chew on.

    Reshaped into rows of 4096 rather than one N-wide strip: a strip of a few
    million pixels is a legal image but an absurd one, and some Pillow builds
    refuse widths that large. The tail is padded by repeating the last pixel —
    at most 4095 duplicates against millions, which median cut cannot see.
    """
    n = px.shape[0]
    w = 4096 if n > 4096 else n
    h = (n + w - 1) // w
    pad = w * h - n
    if pad:
        px = np.concatenate([px, np.repeat(px[-1:], pad, axis=0)], axis=0)
    return Image.fromarray(px.reshape(h, w, 3), "RGB")


def extract(paths, colors, forced):
    """Forced colours first, then median cut fills the remainder."""
    if colors < 1 or colors > MAX_COLORS:
        raise ValueError("--colors must be 1..%d" % MAX_COLORS)
    forced = list(forced)[:colors]
    want = colors - len(forced)
    out = list(forced)
    if want > 0:
        px = load_pixels(paths)
        q = as_image(px).quantize(colors=want, method=Image.Quantize.MEDIANCUT)
        pal = q.getpalette()[:want * 3]
        for i in range(0, len(pal), 3):
            rgb = (pal[i], pal[i + 1], pal[i + 2])
            if rgb not in out:
                out.append(rgb)
    return out


def write_palette(colors, path):
    im = Image.new("RGB", (len(colors), 1))
    im.putdata([tuple(int(c) for c in rgb) for rgb in colors])
    im.save(path)


def read_palette(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)
    return [tuple(int(c) for c in rgb) for rgb in a.reshape(-1, 3)]


def cmd_extract(args):
    forced = parse_hex(args.hex) if args.hex else []
    colors = extract(args.images, args.colors, forced)
    write_palette(colors, args.out)
    print("palette: %s (%d colours)" % (args.out, len(colors)))
    for i, rgb in enumerate(colors):
        print("  %2d %s" % (i, to_hex(rgb)))
    return 0


def cmd_show(args):
    colors = read_palette(args.palette)
    print("palette: %s (%d colours)" % (args.palette, len(colors)))
    for i, rgb in enumerate(colors):
        print("  %2d %s" % (i, to_hex(rgb)))
    return 0


def cmd_check(args):
    pal = np.asarray(read_palette(args.palette), dtype=np.float32)
    worst = 0.0
    for path in args.images:
        a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)
        # Transparent RGB is deliberately zeroed by postpass.py to prevent
        # scaling halos. It is not visible colour and need not be in the LUT.
        # Use the same >=128 opaque cut as postpass.py's report and alpha step.
        opaque = a[a[..., 3] >= 128][:, :3].astype(np.float32)
        if opaque.size:
            off, mean_dist = vcheck.palette_conformance(opaque, pal, tol=args.tol)
        else:
            off, mean_dist = 0.0, 0.0
        worst = max(worst, off)
        print("%s: %.2f%% conformant (%.2f%% off-palette, mean distance %.2f)"
              % (path, 100.0 - off, off, mean_dist))
    return 1 if worst > 0 else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")

    e = sub.add_parser("extract", help="derive a palette from reference images")
    e.add_argument("images", nargs="+")
    e.add_argument("--colors", type=int, default=32)
    e.add_argument("--out", required=True)
    e.add_argument("--hex", default="",
                   help="comma-separated colours forced into the palette first")
    e.set_defaults(func=cmd_extract)

    s = sub.add_parser("show", help="list a palette's colours as hex")
    s.add_argument("palette")
    s.set_defaults(func=cmd_show)

    c = sub.add_parser("check", help="conformance of images against a palette")
    c.add_argument("images", nargs="+")
    c.add_argument("--palette", required=True)
    c.add_argument("--tol", type=float, default=0.0,
                   help="euclidean RGB distance still counted as conformant")
    c.set_defaults(func=cmd_check)

    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    try:
        return args.func(args)
    except (OSError, ValueError) as exc:
        sys.stderr.write("palette.py: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
