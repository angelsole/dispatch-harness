#!/usr/bin/env python3
"""Deterministic headless frames for the visual gate.

Runs on the Playwright that already ships inside shot-scraper's uv venv
(~/.local/share/uv/tools/shot-scraper/bin/python) — the gate adds no dependency
of its own. It requires Playwright's revision-pinned managed Chromium; using a
machine's independently updated browser would make identical frames depend on
the runner. shot-scraper's own CLI cannot do this job: it has no hook that runs
before the app boots, so it can neither freeze the clock nor seed Math.random,
and an animated scene captured without those is a different picture every run.

Determinism, in the order it has to happen:
  1. add_init_script seeds Math.random with a fixed xorshift before any page
     script runs — every "random" layout decision is the same one every time.
  2. clock.install() BEFORE goto pins the page's epoch, so every run reads the
     same Date, and gives --settle-ms/--wait-ms a clock to advance without
     waiting on the wall clock: a slow machine and a fast one get the same fake
     milliseconds between frames. What install() does NOT do, measured on the
     Playwright this runs against, is pause the page — rAF, setTimeout and
     performance.now go on ticking in real time and run_for() adds fake time on
     top of that. An app whose first painted frame is the end of an rAF chain
     (a Flutter web / CanvasKit boot; tests/fixtures/visual/raf-boot.html) is
     therefore ready under both clocks. `--clock real` skips install()
     altogether, for an engine that must see the machine's own Date and for
     motion that only real milliseconds can drive; settle and wait then sleep.
  3. wait_until="load" plus an app-ready predicate. NEVER networkidle: a page
     that polls (the wall polls once a second) never goes idle and goto times
     out at 30 s. Readiness is a JS expression (--ready-js), a one-shot window
     event (--ready-event), or both — an engine that announces itself by
     dispatching an event has nothing left to poll for by the time anyone
     asks, so the listener goes in through add_init_script before any page
     script runs.
  4. SwiftShader, explicitly. Chrome removed the silent software-GL fallback,
     so headless WebGL needs --use-angle=swiftshader AND
     --enable-unsafe-swiftshader. --disable-gpu is NOT in the list on purpose:
     it kills WebGL on current Chromium.

Even with all of that, two identical runs differ by ~0.02 % of pixels. Nothing
downstream may compare frames for equality — see vcheck.py, which uses SSIM.

Usage:
  frames.py --url URL --out DIR --tag NAME [--frames 6] [--wait-ms 750]
            [--settle-ms 3000] [--width 1280] [--height 720] [--dpr 1]
            [--ready-js 'EXPR'] [--ready-event NAME] [--clock frozen|real]
            [--time-ms 1755000000000] [--timeout-ms 20000]
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

# The other half of --ready-event: a one-shot window event has already been
# dispatched by the time a poller could look for it, so the flag it leaves
# behind is what readiness actually waits on.
READY_EVENT_JS = """(() => {
  window.addEventListener(%s, () => { window.__visualGateReady = true; },
                          {once: true});
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
    """Launch Playwright's revision-pinned managed Chromium."""
    return playwright.chromium.launch(headless=True, args=LAUNCH_ARGS)


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
    ap.add_argument("--ready-event", default="")
    # `real` is the escape hatch for an app whose boot needs animation frames
    # to happen at all; see the docstring. Math.random stays seeded either way.
    ap.add_argument("--clock", default="frozen", choices=["frozen", "real"])
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
        try:
            browser = launch_chromium(p)
        except Exception as exc:  # noqa: BLE001 — one actionable render error
            sys.stderr.write("frames.py: browser launch failed: %s\n" % exc)
            return 2
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
        if a.ready_event:
            page.add_init_script(READY_EVENT_JS % json.dumps(a.ready_event))
        if a.clock == "frozen":
            page.clock.install(time=a.time_ms)

        def advance(ms):
            """Let `ms` pass — in fake time under the frozen clock, in real time
            without it. clock.run_for is only valid after clock.install."""
            if a.clock == "frozen":
                page.clock.run_for(ms)
            elif ms:
                time.sleep(ms / 1000.0)

        # Both predicates when both are given: an app can paint its first frame
        # (the event) some way before the thing being photographed is on screen
        # (the expression).
        ready_terms = []
        if a.ready_event:
            ready_terms.append("window.__visualGateReady === true")
        if a.ready_js:
            ready_terms.append("(%s)" % a.ready_js)
        try:
            page.goto(a.url, wait_until="load", timeout=a.timeout_ms)
            # Settle AFTER ready, not after load. Ready is "the app has come up";
            # an app that comes up late (a WebGL world booting on a software
            # renderer, a room arming its sprites) would otherwise get none of
            # the settle, and whatever it does in its first seconds — a lens that
            # starts with the shot — lands inside the capture window, where the
            # continuity check reads every step of it as a cut. Without a ready
            # predicate, load is the only "up" there is, so the settle follows it.
            if ready_terms:
                page.wait_for_function("() => (%s)" % " && ".join(ready_terms),
                                       timeout=a.timeout_ms)
            advance(a.settle_ms)
            for i in range(a.frames):
                advance(a.wait_ms)
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
