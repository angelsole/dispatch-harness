#!/usr/bin/env python3
"""Deterministic headless frames for the visual gate.

Runs on the Playwright that already ships inside shot-scraper's uv venv
(~/.local/share/uv/tools/shot-scraper/bin/python) — the gate adds no dependency
of its own. It prefers Playwright's managed Chromium and falls back to an
installed stable Chrome when an upgrade has left that versioned browser cache
empty. shot-scraper's own CLI cannot do this job: it has no hook that runs
before the app boots, so it can neither freeze the clock nor seed Math.random,
and an animated scene captured without those is a different picture every run.

Determinism, in the order it has to happen:
  1. add_init_script seeds Math.random with a fixed xorshift before any page
     script runs — every "random" layout decision is the same one every time.
  2. clock.install() BEFORE goto freezes Date/setTimeout/rAF. A frozen clock
     also stalls the boot of anything driven by rAF (Phaser, our own wall), so
     the clock is then pumped by --settle-ms to let the app come up, and by
     --wait-ms between frames. Both advances are fake time: the wall clock is
     never waited on, so a slow machine renders the same frames as a fast one.
  3. wait_until="load" plus an app-ready predicate. NEVER networkidle: a page
     that polls (the wall polls once a second) never goes idle and goto times
     out at 30 s.
  4. SwiftShader, explicitly. Chrome removed the silent software-GL fallback,
     so headless WebGL needs --use-angle=swiftshader AND
     --enable-unsafe-swiftshader. --disable-gpu is NOT in the list on purpose:
     it kills WebGL on current Chromium.

Even with all of that, two identical runs differ by ~0.02 % of pixels. Nothing
downstream may compare frames for equality — see vcheck.py, which uses SSIM.

Usage:
  frames.py --url URL --out DIR --tag NAME [--frames 6] [--wait-ms 750]
            [--settle-ms 3000] [--width 1280] [--height 720] [--dpr 1]
            [--ready-js 'EXPR'] [--time-ms 1755000000000] [--timeout-ms 20000]
            [--reduced-motion reduce|no-preference] [--color-scheme dark|light]

Prints one JSON object describing what it captured; exits non-zero with a
one-line reason on stderr when it captured nothing.
"""
import argparse
import json
import pathlib
import sys
import time

# A tiny xorshift32 in place of Math.random, installed before any page script
# runs. Same seed, same sequence, same city.
SEED_JS = """(() => {
  let s = %d >>> 0;
  Math.random = () => {
    s ^= s << 13; s >>>= 0;
    s ^= s >> 17;
    s ^= s << 5;  s >>>= 0;
    return s / 4294967296;
  };
})();"""

LAUNCH_ARGS = [
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
    "--hide-scrollbars",
    "--force-color-profile=srgb",
    "--disable-lcd-text",
    "--font-render-hinting=none",
]


def launch_chromium(playwright):
    """Launch Playwright's Chromium, or stable Chrome when its cache is absent.

    uv can update shot-scraper (and therefore Playwright) independently of the
    browser bundle in Playwright's versioned cache.  An installed stable Chrome
    is a safe fallback for that one state: it is still driven by Playwright with
    the same context, clock and SwiftShader flags.  Do not hide a real browser
    crash behind the fallback; unless Playwright explicitly reports a missing
    executable, preserve its launch error verbatim.
    """
    try:
        return playwright.chromium.launch(headless=True, args=LAUNCH_ARGS)
    except Exception as managed_error:  # noqa: BLE001 — Playwright wraps launch errors
        if "Executable doesn't exist at " not in str(managed_error):
            raise
        try:
            return playwright.chromium.launch(
                headless=True, channel="chrome", args=LAUNCH_ARGS)
        except Exception as chrome_error:  # noqa: BLE001 — retain both useful causes
            raise RuntimeError(
                "%s; the installed Chrome fallback could not launch: %s"
                % (str(managed_error).splitlines()[0],
                   str(chrome_error).splitlines()[0])
            ) from managed_error


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--frames", type=int, default=6)
    ap.add_argument("--wait-ms", type=int, default=750)
    ap.add_argument("--settle-ms", type=int, default=3000)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--dpr", type=float, default=1)
    ap.add_argument("--ready-js", default="")
    ap.add_argument("--time-ms", type=int, default=1755000000000)
    ap.add_argument("--seed", type=int, default=0x2F6E2B1)
    ap.add_argument("--timeout-ms", type=int, default=20000)
    ap.add_argument("--reduced-motion", default="reduce",
                    choices=["reduce", "no-preference"])
    ap.add_argument("--color-scheme", default="dark", choices=["dark", "light"])
    # Motion arrives by two different clocks and only one of them is fakeable.
    # requestAnimationFrame is JS, so the frozen clock drives it and --wait-ms
    # advances it deterministically. CSS keyframes run on the compositor's own
    # timeline, which page.clock does not touch — and animations="disabled"
    # pins them to their initial state on top of that. A page whose ambience is
    # CSS therefore renders six identical tiles unless it is captured with
    # --animations allow and given real milliseconds to move in. That trade is
    # deliberate and it is the caller's: determinism by default, real motion on
    # request.
    ap.add_argument("--animations", default="disabled",
                    choices=["disabled", "allow"])
    ap.add_argument("--real-wait-ms", type=int, default=0)
    a = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.stderr.write(
            "frames.py: playwright is not importable by %s — install shot-scraper "
            "(uv tool install shot-scraper) and re-run\n" % sys.executable)
        return 2

    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    started = time.time()
    errors = []
    shots = []

    with sync_playwright() as p:
        browser = launch_chromium(p)
        ctx = browser.new_context(
            viewport={"width": a.width, "height": a.height},
            device_scale_factor=a.dpr,
            reduced_motion=a.reduced_motion,
            color_scheme=a.color_scheme,
        )
        page = ctx.new_page()
        # Page-side failures are evidence for the fix round: a scene that threw
        # on boot renders black, and "it is black" is a far worse bug report
        # than the exception that made it black.
        page.on("pageerror", lambda e: errors.append(str(e)[:300]))
        page.on("console", lambda m: m.type == "error" and errors.append(m.text[:300]))
        page.add_init_script(SEED_JS % a.seed)
        page.clock.install(time=a.time_ms)
        try:
            page.goto(a.url, wait_until="load", timeout=a.timeout_ms)
            # Settle AFTER ready, not after load. Ready is "the app has come up";
            # an app that comes up late (a WebGL world booting on a software
            # renderer, a room arming its sprites) would otherwise get none of
            # the settle, and whatever it does in its first seconds — a lens that
            # starts with the shot — lands inside the capture window, where the
            # continuity check reads every step of it as a cut. Without a ready
            # predicate, load is the only "up" there is, so the settle follows it.
            if a.ready_js:
                page.wait_for_function("() => (%s)" % a.ready_js, timeout=a.timeout_ms)
            page.clock.run_for(a.settle_ms)
            for i in range(a.frames):
                page.clock.run_for(a.wait_ms)
                if a.real_wait_ms:
                    time.sleep(a.real_wait_ms / 1000.0)
                path = out / ("%s-f%02d.png" % (a.tag, i))
                page.screenshot(path=str(path), animations=a.animations, scale="device")
                shots.append(str(path))
        except Exception as exc:  # noqa: BLE001 — the reason is the product here
            browser.close()
            sys.stderr.write("frames.py: %s failed on %s: %s\n"
                             % (a.tag, a.url, str(exc).splitlines()[0][:300]))
            if errors:
                sys.stderr.write("frames.py: page errors: %s\n" % " | ".join(errors[:3]))
            return 1
        browser.close()

    json.dump({
        "tag": a.tag,
        "url": a.url,
        "frames": shots,
        "viewport": [a.width, a.height],
        "dpr": a.dpr,
        "seconds": round(time.time() - started, 1),
        "page_errors": errors[:5],
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
