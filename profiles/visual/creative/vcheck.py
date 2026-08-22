#!/usr/bin/env python3
"""Model-free visual checks — the free, instant half of the visual gate.

Runs on the system python3 (Pillow + numpy), not on shot-scraper's venv: that
one has Playwright and nothing else. No scikit-image (not installed, 28 MB) and
no ImageMagick subprocess — the SSIM here is a pure-numpy 8x8 block SSIM, and
frame-to-frame continuity is an RMSE over the same arrays we already loaded.

Every number is reported; only the thresholds a repo actually sets are enforced,
and each enforced failure carries a one-line human reason, because that reason
is what the fix round is handed. A check with no threshold is measurement, not
policy — which is the honest default, since the same number means opposite
things for pixel art and for an anti-aliased dashboard.

Usage:  vcheck.py --spec spec.json  [--out checks.json]

spec.json:
  {"shots": [{"name": "wide",
              "frames": ["a-f00.png", "a-f01.png"],
              "champion": "champion-wide.png" or null}],
   "palette": "palette.png" or null,
   "thresholds": {"max_offpalette_pct": 2.0, "max_offgrid_pct": null,
                  "max_pure_black_pct": 60.0, "min_luma": null,
                  "min_legibility": null, "max_frame_rmse": null,
                  "min_ssim": 0.5}}

Exit status is 0 whenever the checks ran — the verdict is `pass` in the JSON,
not the exit code, so the caller can log the numbers either way.
"""
import argparse
import json
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)


def srgb_to_lin(c):
    """sRGB 0..255 -> linear light.

    Masked, not np.where, and that is not a style choice. The obvious

        np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

    is WRONG on any array over ~256 KB, silently, on this numpy: `c` is a
    temporary with one reference, so numpy elides the temporary and computes
    `c / 12.92` IN PLACE over it, and the power branch — evaluated afterwards —
    then runs on the already-divided values. Small arrays stay under the
    elision threshold and come out right, which is what makes it so easy to
    ship: a unit test on a swatch passes and every real frame is off by an
    order of magnitude. It reported the wall as 88 % pure black when the true
    figure is 13 %, and the same expression is in the research prototype this
    file grew from.
    """
    c = np.asarray(c, dtype=np.float64) / 255.0
    lin = np.empty_like(c)
    low = c <= 0.04045
    lin[low] = c[low] / 12.92
    hi = ~low
    lin[hi] = ((c[hi] + 0.055) / 1.055) ** 2.4
    return lin


def luma(a):  # relative luminance, WCAG
    lin = srgb_to_lin(a)
    return 0.2126 * lin[..., 0] + 0.7152 * lin[..., 1] + 0.0722 * lin[..., 2]


def palette_conformance(a, pal, tol=8.0):
    """% of pixels farther than `tol` (euclidean RGB) from the nearest entry.

    Chunked over rows: a full-frame (pixels x entries x 3) distance tensor is
    tens of MB for a 16-colour LUT and grows with the palette.
    """
    px = a.reshape(-1, 3)
    off = 0
    total = 0.0
    n = px.shape[0]
    step = 200000
    for i in range(0, n, step):
        block = px[i:i + step]
        d = np.sqrt(((block[:, None, :] - pal[None, :, :]) ** 2).sum(-1)).min(1)
        off += int((d > tol).sum())
        total += float(d.sum())
    return 100.0 * off / n, total / n


def grid_pitch(a, maxp=64):
    """Pixel-art cell pitch, from the autocorrelation of column-edge energy."""
    g = luma(a)
    e = np.abs(np.diff(g, axis=1)).sum(0)
    e = e - e.mean()
    ac = np.correlate(e, e, mode="full")[len(e) - 1:]
    ac = ac / (ac[0] + 1e-9)
    lags = np.arange(2, min(maxp, len(ac)))
    if len(lags) == 0:
        return 1, 0.0
    best = int(lags[np.argmax(ac[2:len(lags) + 2])])
    return best, float(ac[best])


def offgrid_pct(a, pitch):
    """% of vertical-edge energy that does NOT sit on a multiple of `pitch`.

    e[i] is the step between column i and column i+1, so a cell boundary at
    x = pitch shows up at e[pitch-1], not at e[pitch]. Sampling e[::pitch] —
    as the prototype did — therefore reads the columns BESIDE every edge and
    calls a perfectly aligned scene 100 % off-grid.
    """
    g = luma(a)
    e = np.abs(np.diff(g, axis=1)).sum(0)
    on = e[pitch - 1::pitch].sum()
    return 100.0 * (1 - on / (e.sum() + 1e-9))


def contrast_at_distance(a, w=480, h=270):
    """The across-the-room test: how much edge energy survives a TV-size downscale.

    Normalised by the scale factor — an unnormalised ratio is not a ratio at
    all, it is the downscale factor in disguise.
    """
    im = Image.fromarray(a.astype(np.uint8)).resize((w, h), Image.LANCZOS)
    small = luma(np.asarray(im, dtype=np.float32))
    big = luma(a)
    scale = a.shape[1] / float(w)
    retained = (np.abs(np.diff(small, axis=1)).mean()
                / (np.abs(np.diff(big, axis=1)).mean() + 1e-9)) / scale
    lo, hi = float(np.percentile(small, 5)), float(np.percentile(small, 95))
    return float(retained), float((hi + 0.05) / (lo + 0.05))


def black_floor(a):
    g = luma(a)
    return 100.0 * float((g < 0.002).mean()), float(g.min())


def ssim_np(a, b):
    """Global 8x8-block SSIM on luma. No scipy, no skimage.

    A champion captured at another size is resized rather than refused: the
    question this answers is "is the render still the same picture", and a
    viewport change is not an answer to it.
    """
    if a.shape != b.shape:
        b = np.asarray(Image.fromarray(b.astype(np.uint8))
                       .resize((a.shape[1], a.shape[0]), Image.LANCZOS),
                       dtype=np.float32)
    x, y = luma(a) * 255, luma(b) * 255
    h = (x.shape[0] // 8) * 8
    w = (x.shape[1] // 8) * 8
    if h == 0 or w == 0:
        return None
    x = x[:h, :w].reshape(h // 8, 8, w // 8, 8).transpose(0, 2, 1, 3).reshape(-1, 64)
    y = y[:h, :w].reshape(h // 8, 8, w // 8, 8).transpose(0, 2, 1, 3).reshape(-1, 64)
    mx, my = x.mean(1), y.mean(1)
    vx, vy = x.var(1), y.var(1)
    cov = ((x - mx[:, None]) * (y - my[:, None])).mean(1)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    s = ((2 * mx * my + c1) * (2 * cov + c2)) / ((mx ** 2 + my ** 2 + c1) * (vx + vy + c2))
    return float(s.mean())


def rmse(a, b):
    """Frame-to-frame distance, 0..1. Continuity, not equality: a frozen clock
    still leaves ~0.02 % of pixels moving, so this is thresholded, never == 0."""
    if a.shape != b.shape:
        return None
    return float(np.sqrt(((a - b) ** 2).mean()) / 255.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    with open(args.spec) as fh:
        spec = json.load(fh)
    th = spec.get("thresholds") or {}

    def limit(name):
        v = th.get(name)
        if v in (None, ""):
            return None
        return float(v)

    pal = None
    if spec.get("palette"):
        pal = np.asarray(Image.open(spec["palette"]).convert("RGB"),
                         dtype=np.float32).reshape(-1, 3)

    failures = []

    def fail(check, shot, value, threshold, reason):
        failures.append({"check": check, "shot": shot, "value": value,
                         "threshold": threshold, "reason": reason})

    out = {"shots": {}, "palette_entries": (0 if pal is None else int(len(pal)))}
    for shot in spec.get("shots", []):
        name = shot["name"]
        frames = []
        arrays = []
        for path in shot.get("frames", []):
            a = load(path)
            arrays.append(a)
            pitch, autocorr = grid_pitch(a)
            og = offgrid_pct(a, pitch)
            black_pct, min_luma = black_floor(a)
            retained, contrast = contrast_at_distance(a)
            entry = {
                "frame": path,
                "size": [int(a.shape[1]), int(a.shape[0])],
                "grid": {"pitch_px": pitch, "autocorr": round(autocorr, 3),
                         "offgrid_pct": round(og, 2)},
                "luminance": {"pure_black_pct": round(black_pct, 2),
                              "min_luma": round(min_luma, 5)},
                "readability": {"edge_energy_retained_480x270": round(retained, 4),
                                "p95_p5_contrast_ratio": round(contrast, 2)},
            }
            if pal is not None:
                off, mean_dist = palette_conformance(a, pal)
                entry["palette"] = {"offpalette_pct": round(off, 2),
                                    "mean_dist": round(mean_dist, 2)}
                lim = limit("max_offpalette_pct")
                if lim is not None and off > lim:
                    fail("palette", name, round(off, 2), lim,
                         "%s: %.1f%% of pixels are off-palette (max %.1f%%) — the "
                         "render is not using the locked palette" % (path, off, lim))
            lim = limit("max_offgrid_pct")
            if lim is not None and og > lim:
                fail("grid", name, round(og, 2), lim,
                     "%s: %.1f%% of edge energy is off the %d px grid (max %.1f%%) — "
                     "sprites are being scaled or drawn at fractional positions"
                     % (path, og, pitch, lim))
            lim = limit("max_pure_black_pct")
            if lim is not None and black_pct > lim:
                fail("black", name, round(black_pct, 2), lim,
                     "%s: %.1f%% of the frame is pure black (max %.1f%%) — the scene "
                     "has no luminance floor, so it reads as a hole on a TV"
                     % (path, black_pct, lim))
            lim = limit("min_luma")
            if lim is not None and min_luma < lim:
                fail("min_luma", name, round(min_luma, 5), lim,
                     "%s: darkest pixel is %.4f (floor %.4f) — lift the shadows"
                     % (path, min_luma, lim))
            lim = limit("min_legibility")
            if lim is not None and retained < lim:
                fail("legibility", name, round(retained, 4), lim,
                     "%s: only %.3f of the edge energy survives a 480x270 downscale "
                     "(floor %.3f) — detail this fine is invisible across a room"
                     % (path, retained, lim))
            frames.append(entry)

        continuity = {"per_frame_rmse": [], "max_rmse": None}
        for i in range(1, len(arrays)):
            r = rmse(arrays[i - 1], arrays[i])
            continuity["per_frame_rmse"].append(None if r is None else round(r, 5))
        seen = [r for r in continuity["per_frame_rmse"] if r is not None]
        if seen:
            continuity["max_rmse"] = max(seen)
            lim = limit("max_frame_rmse")
            if lim is not None and continuity["max_rmse"] > lim:
                fail("continuity", name, continuity["max_rmse"], lim,
                     "%s: consecutive frames differ by RMSE %.4f (max %.4f) — the "
                     "scene jumps rather than moves" % (name, continuity["max_rmse"], lim))

        vs_champion = {"ssim": None, "champion": shot.get("champion")}
        if shot.get("champion") and arrays:
            champ = load(shot["champion"])
            s = ssim_np(arrays[0], champ)
            vs_champion["ssim"] = None if s is None else round(s, 4)
            lim = limit("min_ssim")
            if lim is not None and s is not None and s < lim:
                fail("ssim", name, round(s, 4), lim,
                     "%s: SSIM %.3f against the champion frame (floor %.3f) — this is "
                     "not a variation on the reigning shot, it is a different picture"
                     % (name, s, lim))

        out["shots"][name] = {"frames": frames, "continuity": continuity,
                              "vs_champion": vs_champion}

    out["failures"] = failures
    out["pass"] = not failures
    text = json.dumps(out, indent=2)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(text + "\n")
    sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
