'use strict';
// The city's second body. Same scene model (wall/scene.js), same city, drawn on
// a GPU by the vendored Phaser 4 in wall/vendor/ instead of by the browser's
// layout engine. Opened with ?world=canvas; the DOM world is still the default,
// and neither this file nor the engine is fetched unless the query string asked.
//
// The rules it lives by, none of which are negotiable on a screen that runs for
// thirty days without a reload:
//
//   Pre-allocate. Every Graphics and every Text is built once — when a building
//   lands, when a project appears — and after that only its alpha, position,
//   scale or rotation is touched. Geometry is redrawn when a FACT changes (a car
//   reaches a new floor, a run ships, last week rolls over), never once per
//   frame. The single exception is the six-second shipping cascade, which is a
//   travelling mask and says so where it is drawn.
//
//   Nothing periodic keeps its own state. Everything that moves is a pure
//   function of the wall clock — phaseAt() — so a page opened three hours after
//   a ship shows the same resting frame the DOM world shows, and two screens in
//   a room are on the same beat without a byte passing between them.
//
//   Reduced motion is a still frame, not a slower one. phaseAt() pins every
//   cycle to the value wall.css's reduced-motion block leaves the DOM world at
//   — a lit city standing still, not a dark one — and the frame loop stops
//   advancing anything at all.
//
// No image files and no loader: Graphics, Text, and a sky read straight off the
// live <svg class="sky"> in index.html, which stays the one place that painting
// is authored.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallCanvasWorld = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the grid -----------------------------------------------------------------
  // The canvas fills #stage at the viewport's own aspect and draws at device
  // resolution — no base grid, no letterbox — because this is a parity port of
  // a city the DOM draws crisply in vh/rem at native pixels, not a pixel-art
  // sprite game. So every number below is in DEVICE pixels, every one of them
  // is derived from the live stage size, and measure() is the only place any of
  // them is written. A resize re-measures and lays the city out again rather
  // than stretching a frame drawn for the old size.
  let DPR = 1;                        // device pixels per CSS pixel, capped at 2
  let W = 1920;
  let H = 1080;
  let VW = W / 100;
  let VH = H / 100;
  let REM = 20.16;                    // html { font-size } out of wall.css
  let PX = 1;                         // one CSS pixel, in device pixels
  // The sky's viewBox is 1600x900 under `xMidYMid slice`: cover the box, centred
  // — so on a viewport that is not 16:9 the painting is cropped exactly the way
  // the DOM world crops it.
  let SKY = W / 1600;
  let SKY_X = 0;
  let SKY_Y = 0;

  let GROUND = 9 * VH;                // --ground
  let GROUND_Y = H - GROUND;
  let CITY_H = 74 * VH;               // .city
  let HAZE_H = 38 * VH;               // .haze

  let CROWN_H = 2.6 * REM;            // .tower__crown
  let BASE_LINE = 0.88 * REM;         // one line of .tower__base
  let BASE_GAP = 0.3 * REM;           // its margin-top
  const CEREMONY = 6;                 // --ceremony, the shipping beat

  // How big the wall is now, and everything wall.css derives from that. The
  // device-pixel ratio is capped at 2: past that the backing store costs more
  // fill-rate than the sharpness is worth on a panel nobody stands close to.
  function measure(cssWidth, cssHeight, ratio) {
    DPR = Math.min(Math.max(Number(ratio) || 1, 1), 2);
    PX = DPR;
    W = Math.max(1, Math.round(cssWidth * DPR));
    H = Math.max(1, Math.round(cssHeight * DPR));
    VW = W / 100;
    VH = H / 100;
    // html { font-size: clamp(12px, 1.05vw, 26px) } — wall.css, in device px, so
    // a sign glyph is the same size on screen as the DOM's and is rendered at
    // the panel's own resolution rather than upscaled into it.
    REM = Math.min(26, Math.max(12, cssWidth * 0.0105)) * DPR;
    SKY = Math.max(W / 1600, H / 900);
    SKY_X = (W - 1600 * SKY) / 2;
    SKY_Y = (H - 900 * SKY) / 2;
    GROUND = 9 * VH;
    GROUND_Y = H - GROUND;
    CITY_H = 74 * VH;
    HAZE_H = 38 * VH;
    CROWN_H = 2.6 * REM;
    BASE_LINE = 0.88 * REM;
    BASE_GAP = 0.3 * REM;
  }

  // --- the palette --------------------------------------------------------------
  // wall.css's :root, as integers. Alphas travel separately because that is how
  // a Graphics takes them.
  const BG = 0x010306;
  const STONE = 0x0a1220;
  const STONE_LIT = 0x15202e;
  const EDGE = 0x96c3c8;              // --edge, at 0.45
  const WIN_A = 0xffc680;
  const WIN_B = 0xdeeaee;
  const WIN_C = 0x7ad6ec;
  const ALARM = 0xff2f45;
  const DONE = 0x3fd984;
  const DINER = 0xffc27d;
  const SHOP = { noodle: 0xff9a5e, diner: DINER, arcade: 0x7fd4ec, repair: 0x9fe8b8 };
  const ACTOR = {
    opus: 0x4c9dff, codex: 0x3fd984, gate: 0xe0a23c, pr: 0xe6dfc8, demo: 0x7fc9d8,
    setup: 0x3f8f9c, sync: 0x3f8f9c, skipped: 0x6b7a80, deferred: 0xc8a24a,
    done: 0x3fd984, failed: 0xff5a46, unreviewed: 0xff5a46, unknown: 0x7a878f,
  };
  const MONO = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, "DejaVu Sans Mono", Consolas, monospace';
  const CJK = '"PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Source Han Sans SC", "Microsoft YaHei", sans-serif';

  const hex = (n) => '#' + n.toString(16).padStart(6, '0');
  const rgb = (css) => parseInt(String(css || '#e8cfa6').slice(1), 16);

  // --- the silhouettes ----------------------------------------------------------
  // wall.css cuts every building with a clip-path. These are those clip-paths,
  // transcribed: normalised polygons, roof at 0, pavement at 1. A window grid, a
  // floor slab and a shipping cascade are all clipped by scanning one.

  const TOWER_SHAPES = [
    [[0, 0], [1, 0], [1, 1], [0, 1]],
    [[0.22, 0], [0.78, 0], [0.78, 0.06], [0.91, 0.06], [0.91, 0.14], [1, 0.14],
     [1, 1], [0, 1], [0, 0.14], [0.09, 0.14], [0.09, 0.06], [0.22, 0.06]],
    [[0, 0.13], [0.17, 0], [0.83, 0], [1, 0.13], [1, 1], [0, 1]],
    [[0, 0.21], [0.57, 0.21], [0.57, 0], [1, 0], [1, 1], [0, 1]],
    [[0.14, 0], [0.86, 0], [1, 1], [0, 1]],
  ];
  const BOX = [[0, 0], [1, 0], [1, 1], [0, 1]];
  const BLOCK_FORMS = {
    shophouse: [[0, 0.3], [0.18, 0.3], [0.18, 0.14], [0.4, 0.14], [0.4, 0.34],
                [0.62, 0.34], [0.62, 0], [0.84, 0], [0.84, 0.2], [1, 0.2], [1, 1], [0, 1]],
    warehouse: [[0, 0.3], [0, 0], [0.2, 0.3], [0.2, 0], [0.4, 0.3], [0.4, 0],
                [0.6, 0.3], [0.6, 0], [0.8, 0.3], [0.8, 0], [1, 0.3], [1, 1], [0, 1]],
    setback: [[0, 0.3], [0.14, 0.3], [0.14, 0.12], [0.34, 0.12], [0.34, 0],
              [0.72, 0], [0.72, 0.16], [1, 0.16], [1, 1], [0, 1]],
    mast: [[0, 0.18], [0.3, 0.18], [0.3, 0], [0.7, 0], [0.7, 0.18], [1, 0.18], [1, 1], [0, 1]],
    tank: [[0, 0.14], [0.24, 0.14], [0.24, 0.06], [0.4, 0.06], [0.4, 0.14],
           [0.54, 0.14], [0.54, 0], [0.88, 0], [0.88, 0.14], [1, 0.14], [1, 1], [0, 1]],
  };
  const KIND_FORMS = {
    residential: [[0, 0.09], [0.22, 0.09], [0.22, 0], [0.78, 0], [0.78, 0.09],
                  [1, 0.09], [1, 1], [0, 1]],
    industrial: [[0, 0.16], [0.26, 0], [0.26, 0.16], [0.63, 0], [0.63, 0.16],
                 [1, 0.16], [1, 1], [0, 1]],
    spire: [[0.28, 0], [0.72, 0], [1, 0.2], [1, 1], [0, 1], [0, 0.2]],
    infra: BOX,
    midrise: BOX,
    landmark: [[0.34, 0], [0.66, 0], [0.66, 0.05], [0.84, 0.05], [0.84, 0.13],
               [1, 0.13], [1, 1], [0, 1], [0, 0.13], [0.16, 0.13], [0.16, 0.05], [0.34, 0.05]],
  };

  // The district's proportion tables, straight off wall.css.
  const DEPTHS = [{ deep: 0.74, veil: 0.62 }, { deep: 0.92, veil: 0.34 }, { deep: 1.12, veil: 0.12 }];
  const KINDS = {
    residential: { wide: 0.72, tall: 1.16 },
    industrial: { wide: 1.55, tall: 0.74 },
    spire: { wide: 0.58, tall: 1.1 },
    infra: { wide: 1.85, tall: 0.5 },
    midrise: { wide: 1, tall: 1 },
    landmark: { wide: 1.15, tall: 1.25 },
  };
  const FORMS = {
    shophouse: { wide: 1.62, tall: 0.40, floor: 6.5, eaves: 0.24 },
    warehouse: { wide: 1.86, tall: 0.34, floor: 6, eaves: 0.34 },
    tank: { wide: 1.06, tall: 0.66, floor: 8, eaves: 0.18 },
    slab: { wide: 1, tall: 0.88, floor: 9, eaves: 0.12 },
    setback: { wide: 0.94, tall: 1, floor: 11, eaves: 0.20 },
    mast: { wide: 0.42, tall: 1, floor: 12, eaves: 0.22 },
  };
  // Storey pitch and bay width shift with the silhouette, so two towers of the
  // same family still read as two different buildings.
  const TOWER_ROW = [0.44, 0.36, 0.5, 0.4, 0.56];
  const TOWER_COL = [0.3, 0.24, 0.34, 0.42, 0.26];

  // Where a silhouette's edges are, a fraction of the way down: a scanline, so a
  // sawtooth warehouse roof clips its windows as honestly as a plain slab does.
  function spansAt(poly, t) {
    const xs = [];
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const a = poly[i];
      const b = poly[j];
      if ((a[1] > t) !== (b[1] > t)) xs.push(a[0] + (b[0] - a[0]) * (t - a[1]) / (b[1] - a[1]));
    }
    xs.sort((p, q) => p - q);
    const out = [];
    for (let i = 0; i + 1 < xs.length; i += 2) out.push([xs[i], xs[i + 1]]);
    return out;
  }

  const outline = (poly, x, y, w, h) =>
    poly.map((p) => ({ x: x + w * p[0], y: y + h * p[1] }));

  // wall.css lays the skyline out as a flex row with fixed padding and gap.
  // Flex shrink applies to the items, not to the gap between them, so solve the
  // two budgets separately. Treating the gap as shrinkable makes the arithmetic
  // claim everything fits while the full-size gaps rendered below still push a
  // busy skyline past the right edge.
  function towerLayout(towers) {
    const pad = 3 * VW;
    const gap = 1.4 * VW;
    const avail = W - pad * 2;
    const widths = towers.map((tower) => tower.widthRem * REM);
    const widthTotal = widths.reduce((total, width) => total + width, 0);
    const gapTotal = Math.max(0, towers.length - 1) * gap;
    const widthBudget = Math.max(0, avail - gapTotal);
    const squeeze = widthTotal > widthBudget && widthTotal > 0
      ? widthBudget / widthTotal : 1;
    const used = widthTotal * squeeze + gapTotal;
    const slot = towers.length ? Math.max(0, avail - used) / (towers.length + 1) : 0;
    const out = [];
    let x = pad + slot;
    for (let i = 0; i < towers.length; i++) {
      const width = widths[i] * squeeze;
      out.push({ x, w: width });
      x += width + gap + slot;
    }
    return out;
  }

  // --- the wall clock -----------------------------------------------------------
  // Everything that moves in this world is a position in a cycle, and every one
  // of those positions comes out of phaseAt(). Nothing keeps its own state, so a
  // browser opened at any second of any day joins the city mid-beat rather than
  // starting the film over — the join-mid-beat rule --age gives the DOM world.

  // How the painted planes drift, and how far: `5px * --par` out of wall.css's
  // par-drift, on the 1920-wide reference wall.
  const PLANES = [
    { key: 'far', period: 260, par: 1 },
    { key: 'mid', period: 185, par: 2.4 },
    { key: 'near', period: 150, par: 4 },
  ];
  const GHOST_DRIFT = { period: 205, par: 1.6 };
  const HAZE_SLABS = [{ period: 47, delay: 0 }, { period: 71, delay: 22 }];
  const SHIPS = [
    { y: 0.24, z: 1, lum: 0.85, period: 38, delay: 0, back: false },
    { y: 0.38, z: 0.6, lum: 0.55, period: 61, delay: 18, back: true },
    { y: 0.16, z: 0.45, lum: 0.4, period: 83, delay: 47, back: false },
    { y: 0.51, z: 0.8, lum: 0.6, period: 53, delay: 31, back: true },
    { y: 0.30, z: 0.35, lum: 0.34, period: 97, delay: 9, back: false },
  ];
  const STREET_CARS = [
    { bottom: 5.2, width: 4.2, lum: 0.8, period: 143, delay: 0, back: false, warm: true },
    { bottom: 6.4, width: 5.6, lum: 0.5, period: 197, delay: 84, back: true, warm: false },
  ];
  const VENTS = [
    { x: 0.18, w: 2.4, h: 3.6, period: 11, delay: 0 },
    { x: 0.53, w: 1.8, h: 2.8, period: 14, delay: 6 },
    { x: 0.79, w: 2.1, h: 3.2, period: 17, delay: 11 },
  ];
  const PANE_PERIODS = [97, 131, 173];

  // A CSS keyframe list, evaluated. Stops are [position 0..1, value], linear
  // between two of them and flat outside — the stylesheet's own arithmetic.
  function ramp(stops, u) {
    if (u <= stops[0][0]) return stops[0][1];
    for (let i = 1; i < stops.length; i++) {
      if (u <= stops[i][0]) {
        const a = stops[i - 1];
        const b = stops[i];
        return b[0] === a[0] ? b[1] : a[1] + (b[1] - a[1]) * ((u - a[0]) / (b[0] - a[0]));
      }
    }
    return stops[stops.length - 1][1];
  }

  const CROSS_ALPHA = [[0, 0], [0.54, 0], [0.6, 1], [0.96, 1], [1, 0]];
  const STREAK_ALPHA = [[0, 0], [0.964, 0], [0.969, 1], [0.989, 1], [0.994, 0], [1, 0]];
  const STREAK_X = [[0, 0], [0.964, 0], [0.994, 1], [1, 1]];
  const PROWL_ALPHA = [[0, 0], [0.62, 0], [0.66, 0.7], [0.92, 0.7], [1, 0]];
  const PROWL_X = [[0, 0], [0.62, 0], [1, 1]];
  const TRAM_ALPHA = [[0, 0], [0.58, 0], [0.62, 0.62], [0.94, 0.62], [1, 0]];
  const TRAM_X = [[0, 0], [0.58, 0], [1, 1]];
  const STEAM_ALPHA = [[0, 0], [0.24, 0.5], [0.62, 0.26], [1, 0]];
  const OCCUPANCY = [[0, 0], [0.34, 0], [0.42, 0.85], [0.68, 0.85], [0.78, 0], [1, 0]];
  // A tube on a wet night: lit, with the odd stumble. Both signs on this wall
  // use the same shape at different lengths, so it is written twice and no more.
  const HUM = [[0, 1], [0.61, 1], [0.62, 0.25], [0.628, 0.9], [0.636, 0.4], [0.646, 1], [1, 1]];
  const SIGN_HUM = [[0, 1], [0.906, 1], [0.91, 0.3], [0.916, 0.85], [0.922, 0.3],
                    [0.928, 0.55], [0.934, 1], [1, 1]];
  const WIN_LIVE = [[0, 0.9], [0.45, 0.8], [0.62, 0.87], [1, 0.9]];
  const BEACON_ALPHA = [[0, 0], [0.04, 1], [0.16, 0.95], [0.62, 0.6], [1, 0]];
  const BEACON_SCALE = [[0, 0.3], [0.04, 2.6], [0.16, 1], [0.62, 1], [1, 0.75]];
  const HALO_ALPHA = [[0, 0], [0.07, 1], [0.32, 0.66], [0.6, 0.88], [1, 0]];
  const HALO_SCALE = [[0, 0.3], [0.07, 1], [0.32, 0.84], [0.6, 1.12], [1, 1.4]];
  const CASCADE_ALPHA = [[0, 0], [0.06, 1], [0.58, 1], [1, 0]];
  const LIGHTS_OUT = [[0, 1], [0.22, 1], [0.7, 0.34], [1, 0]];
  const FLARE_ALPHA = [[0, 1], [0.05, 1], [0.18, 0.85], [1, 0.25]];
  const FLARE_SCALE = [[0, 1], [0.05, 2.7], [0.18, 1.15], [1, 0.85]];
  const SIGN_COOL = [[0, 0.85], [0.08, 0.85], [1, 0]];
  // The carousel beam, bottom to top: bright where it lands, gone before the
  // cloud ceiling. wall.css's own stops, read the way its 0deg gradient runs.
  const SPOT_BEAM = [[0, 0.62], [0.22, 0.24], [0.52, 0.08], [0.76, 0.02], [0.92, 0], [1, 0]];

  function loop(t, period, delay) {
    const u = (((t + delay) % period) / period);
    return u < 0 ? u + 1 : u;
  }
  // A CSS `alternate` cycle: out over one period and back over the next, 0..1.
  function swing(t, period) {
    const u = ((t / period) % 2 + 2) % 2;
    return u < 1 ? u : 2 - u;
  }
  const once = (age, span) => (span > 0 ? Math.min(1, Math.max(0, age / span)) : 1);

  // Every moving thing on this wall, at one second of the clock. Reduced motion
  // pins the lot to the frame wall.css's reduced-motion block leaves the DOM
  // world standing at, so the two bodies agree when the room asks for stillness
  // as much as when it does not — and a test can call this with
  // `{ reducedMotion: true }` at any two seconds and get the same object.
  function phaseAt(seconds, opts) {
    const frozen = !!(opts && opts.reducedMotion);
    const t = frozen ? 0 : Number(seconds) || 0;
    return {
      still: frozen,
      t,
      planes: PLANES.map((p) => (frozen ? 0 : (swing(t, p.period) * 2 - 1) * 5 * PX * p.par)),
      ghost: frozen ? 0 : (swing(t, GHOST_DRIFT.period) * 2 - 1) * 5 * PX * GHOST_DRIFT.par,
      // The breathing camera. Absent when still: a paused push-in is a crop.
      cam: {
        city: frozen ? 1 : 1 + 0.035 * swing(t, 140),
        sky: frozen ? 1 : 1 + 0.016 * swing(t, 140),
      },
      air: HAZE_SLABS.map((s) => (frozen ? 0 : loop(t, s.period, s.delay) * 70 * VW)),
      // Reduced motion drops .traffic and .street outright: a headlight streak
      // that cannot travel is a scratch on the panel.
      ships: SHIPS.map((s) => (frozen ? { a: 0, x: 0 } : {
        a: ramp(CROSS_ALPHA, loop(t, s.period, s.delay)) * s.lum,
        x: loop(t, s.period, s.delay) * 120 * VW,
      })),
      street: STREET_CARS.map((s) => (frozen ? { a: 0, x: 0 } : {
        a: ramp(STREAK_ALPHA, loop(t, s.period, s.delay)) * s.lum,
        x: ramp(STREAK_X, loop(t, s.period, s.delay)) * 128 * VW,
      })),
      steam: VENTS.map((v) => (frozen ? { a: 0, x: 0, y: 0, s: 1 } : {
        a: ramp(STEAM_ALPHA, loop(t, v.period, v.delay)),
        x: loop(t, v.period, v.delay) * 0.7 * REM,
        y: 0.4 * REM - loop(t, v.period, v.delay) * 3.2 * REM,
        s: 0.5 + loop(t, v.period, v.delay) * 1.05,
      })),
      // The tram sits on its line rather than being deleted: the district is a
      // record, and a record has to stay legible standing still.
      tram: frozen ? { a: 0.62, x: 0 } : {
        a: ramp(TRAM_ALPHA, loop(t, 96, 0)),
        x: (ramp(TRAM_X, loop(t, 96, 0)) * 128 - 12) * VW,
      },
      facade: frozen ? 0.9 : ramp(WIN_LIVE, loop(t, 26, 0)),
      sweep: frozen ? -12 : -34 + 72 * swing(t, 4.4),
      klaxon: frozen ? 0.8 : 0.28 + 0.72 * swing(t, 1.1),
      // klaxon-text: the alarm tower's name plate, and the HUD's own count.
      text: frozen ? 1 : 0.25 + 0.75 * swing(t, 1),
      car: frozen ? 1 : 0.72 + 0.28 * swing(t, 2.6),
      carAlarm: frozen ? 1 : 0.2 + 0.8 * swing(t, 0.9),
    };
  }

  // Per-object beats, every one of them derived from one phase. With a frozen
  // phase each is a constant, which is the whole of reduced motion here: a sign
  // drawn fully lit stays lit, a window keeping its own hours keeps them, and
  // nothing advances.
  const tubeAt = (phase, delay, period) =>
    (phase.still ? 1 : ramp(period === 16 ? SIGN_HUM : HUM, loop(phase.t, period, delay)));
  const paneAt = (phase, slot, delay) =>
    (phase.still ? 0.85 : ramp(OCCUPANCY, loop(phase.t, PANE_PERIODS[slot] || 97, delay)));
  const facadeAt = (phase, drift) =>
    (phase.still ? phase.facade : ramp(WIN_LIVE, loop(phase.t, 26, drift * 1.9)));
  // A walker's crossing, and the machines that do the other half of a night
  // shift going the other way. Parked mid-street when the room asks for
  // stillness, which is what wall.css does with a fixed translate per slot.
  function walkerAt(phase, slot, robot) {
    if (phase.still) return (9 + slot * 15) * VW;
    const u = loop(phase.t, robot ? 176 : 132, slot * 21);
    return (robot ? 108 - u * 216 : -108 + u * 216) * VW;
  }
  function vehicleAt(phase, slot, plan) {
    if (phase.still) return { a: 0, x: 0 };
    const u = loop(phase.t, plan.cycle || 48, slot * (plan.gap || 0));
    return { a: ramp(PROWL_ALPHA, u), x: (ramp(PROWL_X, u) * 122 - 8) * VW };
  }

  // --- drawing helpers ----------------------------------------------------------

  // A vertical gradient, one banded fill per pair of stops. Graphics takes four
  // corner colours, so two stops at a time is exact rather than an approximation.
  function fillGradient(g, stops, x, y, w, h) {
    for (let i = 1; i < stops.length; i++) {
      const a = stops[i - 1];
      const b = stops[i];
      const tall = h * (b.at - a.at);
      if (tall <= 0) continue;
      g.fillGradientStyle(a.colour, a.colour, b.colour, b.colour,
                          a.alpha, a.alpha, b.alpha, b.alpha);
      g.fillRect(x, y + h * a.at, w, tall);
    }
  }

  // A radial glow, as rings. There is no radial fill in Graphics and every one
  // of these is painted exactly once, so concentric ellipses at a fraction of
  // the alpha each is the honest answer rather than a texture nobody can audit.
  function glow(g, colour, cx, cy, rx, ry, alpha, rings) {
    for (let i = rings; i >= 1; i--) {
      g.fillStyle(colour, alpha / rings);
      g.fillEllipse(cx, cy, rx * 2 * (i / rings), ry * 2 * (i / rings), 20);
    }
  }

  // The facade grid: masonry bands over three colours of lit stripe, clipped to
  // whatever silhouette the building has. wall.css builds it out of repeating
  // gradients; this is the same arithmetic landing on the same rectangles.
  function facadeGrid(g, poly, x, y, w, h, row, col) {
    const bands = [[WIN_A, 0.52, 0, col, col * 3.2],
                   [WIN_B, 0.4, col * 1.4, col * 2.3, col * 5.1],
                   [WIN_C, 0.34, col * 2.6, col * 3.4, col * 7.3]];
    for (let ry = 0; ry < h; ry += row * 2) {
      const tall = Math.min(row, h - ry);
      if (tall <= 0.2) continue;
      for (const [l, r] of spansAt(poly, Math.min(1, (ry + row / 2) / h))) {
        const left = x + w * l;
        const right = x + w * r;
        if (right - left < 0.4) continue;
        for (const [colour, alpha, from, to, pitch] of bands) {
          g.fillStyle(colour, alpha);
          for (let rx = left; rx < right; rx += pitch) {
            const a = Math.max(left, rx + from);
            const b = Math.min(right, rx + to);
            if (b > a) g.fillRect(a, y + ry, b - a, tall);
          }
        }
      }
    }
  }

  // --- reading the painted sky --------------------------------------------------
  // The sky is authored exactly once, in index.html, and this world reads it off
  // the live node rather than keeping a second copy: the gradients come out of
  // the <defs>, the silhouettes out of the same <path> elements the DOM world
  // paints, sampled and then reduced back to their own vertices.

  // One point of the sky's viewBox, on the wall.
  const skyX = (x) => SKY_X + Number(x) * SKY;
  const skyY = (y) => SKY_Y + Number(y) * SKY;

  function samplePath(node, step) {
    const total = node.getTotalLength();
    const raw = [];
    for (let d = 0; d < total; d += step) {
      const p = node.getPointAtLength(d);
      raw.push({ x: skyX(p.x), y: skyY(p.y) });
    }
    const end = node.getPointAtLength(total);
    raw.push({ x: skyX(end.x), y: skyY(end.y) });
    // These are straight runs, so anything collinear with its neighbours is a
    // sample rather than a corner. Dropping them takes a few thousand points
    // back to the hundred or so the painting actually has.
    const out = [raw[0]];
    for (let i = 1; i < raw.length - 1; i++) {
      const a = out[out.length - 1];
      const b = raw[i];
      const c = raw[i + 1];
      if (Math.abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) > 0.05) out.push(b);
    }
    out.push(raw[raw.length - 1]);
    return out;
  }

  function inside(points, x, y) {
    let hit = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
      const a = points[i];
      const b = points[j];
      if ((a.y > y) !== (b.y > y) && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) hit = !hit;
    }
    return hit;
  }

  // A <linearGradient> from the page's own defs, as stops this file can fill with.
  function gradientOf(id) {
    const node = document.getElementById(id);
    if (!node) return [];
    return [...node.querySelectorAll('stop')].map((stop) => ({
      at: (parseFloat(stop.getAttribute('offset')) || 0) / 100,
      colour: parseInt((stop.getAttribute('stop-color') || '#000000').slice(1), 16),
      alpha: stop.hasAttribute('stop-opacity') ? parseFloat(stop.getAttribute('stop-opacity')) : 1,
    }));
  }

  // --- the world ----------------------------------------------------------------

  function create(opts) {
    const parent = opts.parent;
    const still = opts.still;
    const clock = opts.clock;
    const Model = window.WallScene;

    // The canvas gets its own box inside the stage. The DOM world's layers stay
    // in the document — index.html's structure is a contract the suite reads by
    // line — but hidden, and nothing ever populates them.
    const host = document.createElement('div');
    host.className = 'world';
    host.id = 'world';
    parent.append(host);

    const ratio = () => Math.min(window.devicePixelRatio || 1, 2);
    const stageSize = () => ({
      w: host.clientWidth || window.innerWidth,
      h: host.clientHeight || window.innerHeight,
    });
    const first = stageSize();
    measure(first.w, first.h, ratio());

    let city = null;          // the running scene, once Phaser has booted it
    let pending = null;       // the last scene handed over before it had
    let pendingSpot = '';

    class CityScene extends Phaser.Scene {
      constructor() { super('city'); }

      create() {
        this.phase = phaseAt(0, { reducedMotion: true });
        this.model = null;          // the wall's scene model, once it arrives
        this.towers = new Map();    // project -> its objects
        this.blocks = new Map();    // run id -> its objects
        this.landmark = null;
        this.ghostKey = '';
        this.walkers = [];
        this.vehicles = [];

        // Back to front, in the z-order wall.css gives the same layers.
        this.skyC = this.add.container(0, 0);
        this.backdrop = this.add.graphics();
        this.ghostG = this.add.graphics();
        this.planes = PLANES.map(() => this.add.container(0, 0));
        this.skyC.add(this.backdrop);
        this.skyC.add(this.ghostG);
        for (const plane of this.planes) this.skyC.add(plane);
        this.districtC = this.add.container(0, 0);
        this.dawnG = this.add.graphics();
        this.trafficC = this.add.container(0, 0);
        this.cityC = this.add.container(0, 0);
        this.hazeC = this.add.container(0, 0);
        this.streetC = this.add.container(0, 0);
        this.lifeC = this.add.container(0, 0);

        this.paintBackdrop();
        this.paintPlanes();
        this.paintDawn();
        this.paintTraffic();
        this.paintHaze();
        this.paintStreet();
        this.paintLife();

        city = this;
        if (pending) this.apply(pending);
        this.spot(pendingSpot);
        this.step(true);
      }

      // --- the painted sky ------------------------------------------------------

      paintBackdrop() {
        const g = this.backdrop;
        // The page's own background first — the warm dome the skyline stands
        // against — then the sky's night gradient over it.
        g.fillStyle(BG, 1);
        g.fillRect(0, 0, W, H);
        fillGradient(g, gradientOf('night'), skyX(0), skyY(0), 1600 * SKY, 900 * SKY);
        glow(g, 0x2a6f66, W / 2, H, W * 0.65, H * 0.78, 0.42, 12);
        // Thin-line cloud, the same ceiling lit from underneath, and the two
        // rules over the horizon — all read off the <g stroke> groups the DOM
        // world paints, so there is one painting rather than two.
        for (const group of document.querySelectorAll('svg.sky > g[stroke]')) {
          const colour = parseInt((group.getAttribute('stroke') || '#000000').slice(1), 16);
          const width = parseFloat(group.getAttribute('stroke-width') || '1') * SKY;
          const alpha = parseFloat(group.getAttribute('opacity') || '1');
          g.lineStyle(Math.max(0.5, width), colour, alpha);
          for (const path of group.querySelectorAll('path')) {
            g.strokePoints(samplePath(path, 6), false, false);
          }
        }
        // Atmospheric perspective: the wet air sitting between the depth planes.
        const veil = document.querySelector('svg.sky > rect[fill="url(#hazeveil)"]');
        if (veil) {
          fillGradient(g, gradientOf('hazeveil'),
            skyX(veil.getAttribute('x')), skyY(veil.getAttribute('y')),
            Number(veil.getAttribute('width')) * SKY, Number(veil.getAttribute('height')) * SKY);
        }
      }

      paintPlanes() {
        PLANES.forEach((plane, i) => {
          const node = document.querySelector('.sky__' + plane.key + ' path');
          if (!node) return;
          const points = samplePath(node, 2);
          const g = this.add.graphics();
          this.planes[i].add(g);
          const stops = gradientOf(plane.key);
          const body = stops.length ? stops[Math.floor(stops.length / 2)] : null;
          g.fillStyle(body ? body.colour : STONE, body ? body.alpha : 1);
          g.fillPoints(points, true, true);
          if (plane.key === 'near') {
            // Wet street: what the back-city leaves smeared on the tarmac.
            const wet = this.add.graphics();
            this.planes[i].add(wet);
            for (const rect of document.querySelectorAll('.sky__near rect')) {
              fillGradient(wet, gradientOf('wet'),
                skyX(rect.getAttribute('x')), skyY(rect.getAttribute('y')),
                Number(rect.getAttribute('width')) * SKY, Number(rect.getAttribute('height')) * SKY);
            }
            wet.setAlpha(0.7);
            return;
          }
          // Distant windows, too small to read as anything but depth. The near
          // plane is pure silhouette on purpose — no pattern reaches it.
          const lit = this.add.graphics();
          this.planes[i].add(lit);
          const top = points.reduce((lo, p) => Math.min(lo, p.y), H);
          const dot = Math.max(0.8, 2 * SKY);
          const alpha = plane.key === 'far' ? 0.32 : 0.42;
          // The pattern is 15x19 in the sky's own units and tiles from its
          // origin, so it stays put against the silhouette at any aspect.
          const first = SKY_Y + Math.floor((top - SKY_Y) / (19 * SKY)) * 19 * SKY;
          for (let y = first; y < GROUND_Y; y += 19 * SKY) {
            for (let x = SKY_X; x < W; x += 15 * SKY) {
              if (inside(points, x + 4 * SKY, y + 5 * SKY)) {
                lit.fillStyle(0xffc98a, 0.45 * alpha);
                lit.fillRect(x + 3 * SKY, y + 4 * SKY, dot, dot);
              }
              if (inside(points, x + 11 * SKY, y + 13 * SKY)) {
                lit.fillStyle(0xa8dcf0, 0.3 * alpha);
                lit.fillRect(x + 10 * SKY, y + 12 * SKY, dot, dot);
              }
            }
          }
        });
      }

      // The cold wash the sky picks up either side of local sunrise. Zero at
      // every other hour, which is the night this city has always been.
      paintDawn() {
        const g = this.dawnG;
        g.fillGradientStyle(0x4a7aa8, 0x4a7aa8, 0x4a7aa8, 0x4a7aa8, 0, 0, 0.14, 0.14);
        g.fillRect(0, H * 0.38, W, H * 0.36);
        g.fillGradientStyle(0x4a7aa8, 0x4a7aa8, 0x6096be, 0x6096be, 0.14, 0.14, 0.28, 0.28);
        g.fillRect(0, H * 0.74, W, H * 0.26);
        g.setAlpha(0);
      }

      // --- the weather between the buildings ------------------------------------

      paintHaze() {
        const base = this.add.graphics();
        this.hazeC.add(base);
        base.fillGradientStyle(0x5aaaaa, 0x5aaaaa, 0x5aaaaa, 0x5aaaaa, 0, 0, 0.09, 0.09);
        base.fillRect(0, H - HAZE_H, W, HAZE_H);
        base.fillGradientStyle(0x010408, 0x010408, 0x010408, 0x010408, 0, 0, 0.92, 0.92);
        base.fillRect(0, H - HAZE_H * 0.72, W, HAZE_H * 0.72);
        this.hazeSlabs = HAZE_SLABS.map((slab, i) => {
          const g = this.add.graphics();
          this.hazeC.add(g);
          const w = (i ? 0.52 : 0.7) * W;
          const h = (i ? 18 : 26) * VH;
          const y = H - (i ? 2 * VH : -6 * VH) - h / 2;
          glow(g, 0x7ec4c4, w / 2, y, w / 2, h / 2, 0.12, 8);
          g.setPosition(-0.3 * W, 0);
          g.setAlpha(i ? 0.7 : 1);
          return g;
        });
      }

      paintTraffic() {
        this.ships = SHIPS.map((ship) => {
          const g = this.add.graphics();
          this.trafficC.add(g);
          const w = 1.1 * REM;
          const h = Math.max(0.6, 0.14 * REM);
          glow(g, 0xaad8ff, w / 2, h / 2, w, h * 4, 0.7, 5);
          g.fillStyle(0xff8c64, 0.3);
          g.fillRect(-1.3 * REM, 0, w, h);
          g.fillStyle(0xd6e9ff, 1);
          g.fillRect(0, 0, w, h);
          // A blinking nav light — what makes a moving dot read as an aircraft
          // rather than as a speck of dust on the panel.
          g.fillStyle(0xff6a5b, 1);
          g.fillCircle(w + 0.3 * REM, h / 2, Math.max(0.5, 0.11 * REM));
          g.setPosition(-0.1 * W, ship.y * H);
          g.setScale(ship.z);
          g.setAlpha(0);
          return g;
        });
      }

      paintStreet() {
        this.streetCars = STREET_CARS.map((car) => {
          const g = this.add.graphics();
          this.streetC.add(g);
          const w = car.width * REM;
          const h = Math.max(0.6, 0.16 * REM);
          const head = car.warm ? 0xfff5e2 : 0xcfe8ff;
          const tail = car.warm ? 0xffd6a8 : 0x96c8ff;
          g.fillGradientStyle(tail, head, tail, head, 0, 1, 0, 1);
          g.fillRect(0, 0, w, h);
          glow(g, head, car.warm ? w : 0, h / 2, w * 0.4, h * 5, 0.5, 5);
          g.setPosition(-0.14 * W, H - car.bottom * VH);
          g.setAlpha(0);
          return g;
        });
      }

      // --- the street, from the first ship --------------------------------------

      paintLife() {
        // The fixtures: the mall a very good week puts up, the tram and its
        // rail, and three vents. The crowd and the road come from the plan.
        this.mall = this.add.graphics();
        this.lifeC.add(this.mall);
        const mallW = 21 * VW;
        const mallH = 4 * VH;
        const mallX = W * 0.97 - mallW;
        const mallY = H - 2.6 * VH - mallH;
        this.mall.fillGradientStyle(STONE_LIT, STONE_LIT, STONE, STONE, 1, 1, 1, 1);
        this.mall.fillRect(mallX, mallY, mallW, mallH);
        this.mall.fillStyle(DINER, 0.5);
        for (let x = mallX; x < mallX + mallW; x += 1.1 * REM) {
          this.mall.fillRect(x, mallY, Math.min(0.5 * REM, mallX + mallW - x), mallH);
        }
        this.mall.fillStyle(EDGE, 0.45);
        this.mall.fillRect(mallX, mallY, mallW, 0.6);
        this.mall.setAlpha(0);

        this.rail = this.add.graphics();
        this.lifeC.add(this.rail);
        this.rail.fillStyle(0x8ccdc8, 0.26);
        this.rail.fillRect(W * 0.12, H - 6 * VH, W * 0.76, 0.6);
        this.rail.setAlpha(0);

        this.tram = this.add.graphics();
        this.lifeC.add(this.tram);
        this.tram.fillGradientStyle(0x78bec8, 0xc8f0f0, 0x78bec8, 0xc8f0f0, 0.45, 0.7, 0.45, 0.7);
        this.tram.fillRoundedRect(0, 0, 5.2 * REM, 0.46 * REM, 0.1 * REM);
        this.tram.setPosition(0, H - 6.1 * VH - 0.46 * REM);
        this.tram.setAlpha(0);

        this.vents = VENTS.map((vent) => {
          const g = this.add.graphics();
          this.lifeC.add(g);
          glow(g, WIN_B, 0, 0, vent.w * REM * 0.5, vent.h * REM * 0.5, 0.5, 8);
          g.setAlpha(0);
          return g;
        });

        this.crowdC = this.add.container(0, 0);
        this.roadC = this.add.container(0, 0);
        this.lifeC.add(this.crowdC);
        this.lifeC.add(this.roadC);
        this.lifeC.setVisible(false);
      }

      // Somebody out at one in the morning: a silhouette, never a character, with
      // the street's own warmth down one edge.
      makeWalker(slot) {
        const robot = slot % 3 === 2;
        const g = this.add.graphics();
        this.crowdC.add(g);
        const w = (robot ? 0.4 : 0.3) * REM;
        const h = (robot ? 0.42 : 0.72) * REM;
        g.fillStyle(BG, 0.95);
        g.fillRect(0, 0, Math.max(0.6, w * 0.55), h);
        g.fillStyle(robot ? SHOP.repair : DINER, robot ? 0.6 : 0.55);
        g.fillRect(w * 0.55, 0, Math.max(0.6, w * 0.45), h);
        g.setPosition(0, H - (1.4 + (slot % 4) * 0.9) * VH - h);
        g.setAlpha(0.62);
        return { g, robot, slot };
      }

      // A car, now and then. The wait is the point: on a quiet week this is
      // nothing for forty seconds and then somebody drives home.
      makeVehicle(slot) {
        const g = this.add.graphics();
        this.roadC.add(g);
        const west = slot % 2 === 1;
        const w = 3.2 * REM;
        const h = Math.max(0.6, 0.14 * REM);
        const tint = west ? SHOP.arcade : DINER;
        g.fillGradientStyle(west ? tint : 0x000000, west ? 0x000000 : tint,
                            west ? tint : 0x000000, west ? 0x000000 : tint, 1, 0, 1, 0);
        g.fillRoundedRect(0, 0, w, h, h / 2);
        glow(g, tint, west ? 0 : w, h / 2, w * 0.35, h * 4, 0.5, 5);
        g.setPosition(0, H - (west ? 4.3 : 3.2) * VH);
        g.setAlpha(0);
        return { g, slot };
      }

      // --- last week, flattened -------------------------------------------------
      // A height and a plot, nothing else. Redrawn only when last week changes,
      // which is once a week at the ledger's roll-over.

      paintGhost(ghosts) {
        const key = ghosts.map((g) => g.x + ':' + g.storeys).join(',');
        if (key === this.ghostKey) return;
        this.ghostKey = key;
        this.ghostG.clear();
        this.ghostG.fillStyle(0x7fb4c0, 1);
        for (const ghost of ghosts) {
          this.ghostG.fillRect(skyX(ghost.x * 1600 - 20), skyY(819 - ghost.height),
                               40 * SKY, ghost.height * SKY);
        }
        this.ghostG.setAlpha(0.14);
      }

      // --- the week's district --------------------------------------------------

      // Where a building stands and how big it is: wall.css's own formula in grid
      // units. A block is measured once, when it lands, and never again.
      measure(block) {
        const band = DEPTHS[block.depth] || DEPTHS[1];
        const kind = KINDS[block.kind] || KINDS.midrise;
        const form = block.shape ? FORMS[block.shape.form] : null;
        const grade = block.shape ? block.shape.grade : 0;
        const jitter = block.shape ? 1 + (grade - 1.5) * 0.1 : 1;
        const shorten = block.shape ? 1 - grade * 0.05 : 1;
        const w = 2.9 * REM * band.deep * kind.wide * (form ? form.wide : 1) * jitter;
        const h = Math.max(
          (3.4 + block.storeys * 1.9) * VH * band.deep * kind.tall * (form ? form.tall : 1) * shorten,
          (form ? form.floor : 7) * VH * band.deep);
        return {
          w,
          h,
          x: block.x * W - w / 2,
          y: GROUND_Y - h,
          veil: band.veil,
          eaves: form ? form.eaves : 0.12,
          poly: (block.shape && BLOCK_FORMS[block.shape.form])
            || KIND_FORMS[block.kind] || KIND_FORMS.midrise,
        };
      }

      makeBlock(block) {
        const box = this.measure(block);
        const root = this.add.container(0, 0);
        this.districtC.add(root);
        const points = outline(box.poly, box.x, box.y, box.w, box.h);
        const body = this.add.graphics();
        root.add(body);
        body.fillGradientStyle(STONE_LIT, STONE_LIT, STONE, STONE, 1, 1, 1, 1);
        body.fillPoints(points, true, true);
        // The facade grid is the towers' own, at the district's finer storey
        // pitch and dimmer: these are the backdrop, and a lit shaft in front of
        // them has to win.
        const grid = this.add.graphics();
        root.add(grid);
        facadeGrid(grid, box.poly, box.x, box.y, box.w, box.h, 0.3 * REM, 0.2 * REM);
        grid.setAlpha(0.46);
        // Atmospheric perspective: the wet air between this building and the room.
        const veil = this.add.graphics();
        root.add(veil);
        veil.fillGradientStyle(0x163840, 0x163840, 0x163840, 0x163840, 1, 1, 1, 1);
        veil.fillPoints(points, true, true);
        veil.setAlpha(box.veil * 0.6);

        const parts = { root, box, block, shop: {} };
        this.roofFurniture(root, block, box);
        this.shopfront(parts, block, box);
        // Occupancy: a fixed handful of windows keeping their own hours, each on
        // its own loop length and from its own seeded phase.
        parts.panes = (block.shop ? block.shop.windows : []).map((win, i) => {
          const g = this.add.graphics();
          root.add(g);
          g.fillStyle(i === 2 ? WIN_C : WIN_A, 1);
          g.fillRect(box.x + box.w * (0.08 + win.col * 0.12),
                     box.y + box.h * (0.7 - win.row * 0.1),
                     Math.max(0.6, box.w * 0.09), Math.max(0.6, box.h * 0.08));
          g.setAlpha(0);
          return { g, phase: win.phase };
        });
        // Attribution, and the whole of it: one small tube on the shoulder in the
        // dispatcher's own crew tint, cooling to neutral within --sign-life.
        parts.sign = this.add.graphics();
        root.add(parts.sign);
        parts.sign.fillStyle(rgb(block.crew), 1);
        parts.sign.fillRect(box.x + box.w - 0.13 * REM, box.y + box.h * box.eaves,
                            Math.max(0.6, 0.24 * REM), 0.76 * REM);
        parts.sign.setAlpha(0);
        return parts;
      }

      // Roof furniture. The silhouette is what the room reads from the sofa, so
      // every typology and every repo family stands its own thing up there —
      // each over a part of the roof its clip-path takes to full height.
      roofFurniture(root, block, box) {
        const g = this.add.graphics();
        root.add(g);
        g.fillStyle(STONE, 1);
        const put = (l, w, h, off) =>
          g.fillRect(box.x + box.w * l, box.y - h - (off || 0), Math.max(0.6, w), h);
        // Never red, which belongs to an alarm, and never green, which belongs
        // to a run that just shipped.
        const lamp = (l, up, r, colour) => {
          glow(g, colour, box.x + box.w * l, box.y - up, r * 3, r * 3, 0.5, 5);
          g.fillStyle(colour, 1);
          g.fillCircle(box.x + box.w * l, box.y - up, r);
          g.fillStyle(STONE, 1);
        };
        const form = block.shape ? block.shape.form : null;
        if (form === 'shophouse') {
          put(0.64, box.w * 0.16, 0.28 * REM);
          put(0.78, 0.09 * REM, 0.62 * REM);
        } else if (form === 'warehouse') {
          put(0.6, 0.22 * REM, 0.92 * REM);
          put(0.2, 0.16 * REM, 0.56 * REM);
        } else if (form === 'setback') {
          put(0.44, 0.1 * REM, 1.1 * REM);
          put(0.36, box.w * 0.3, 0.2 * REM);
        } else if (form === 'tank') {
          put(0.58, box.w * 0.26, 0.66 * REM, 0.28 * REM);
          put(0.61, box.w * 0.2, 0.28 * REM);
        } else if (form === 'mast') {
          put(0.5, 0.1 * REM, 1.4 * REM);
          lamp(0.5, 1.28 * REM, Math.max(0.6, 0.11 * REM), 0x7fc9d8);
        } else if (block.kind === 'residential') {
          put(0.18, box.w * 0.42, 0.5 * REM);
          put(0.76, 0.1 * REM, 1.2 * REM);
        } else if (block.kind === 'industrial') {
          put(0.14, 0.3 * REM, 1.3 * REM);
          put(0.36, 0.3 * REM, 1.3 * REM);
          put(0.58, box.w * 0.32, 0.3 * REM);
        } else if (block.kind === 'spire') {
          put(0.5, 0.1 * REM, 1.5 * REM);
          lamp(0.5, 1.34 * REM, Math.max(0.6, 0.14 * REM), 0x7fc9d8);
        } else if (block.kind === 'infra') {
          put(0.1, box.w * 0.8, 1.2 * REM);
          g.fillStyle(EDGE, 0.45);
          g.fillRect(box.x + box.w * 0.04, box.y - 0.86 * REM, box.w * 0.92, 0.6);
        } else if (block.kind === 'landmark') {
          put(0.5, 0.1 * REM, 1.1 * REM);
          lamp(0.5, 0.98 * REM, Math.max(0.6, 0.12 * REM), DINER);
        } else {
          put(0.06, box.w * 0.88, 0.16 * REM);
        }
      }

      // The ground floor after dark: a row of small warm bays under every
      // building, the one-in-three neon tube over one of them, and the glyph
      // that says in a character what the tube says in light.
      shopfront(parts, block, box) {
        const root = parts.root;
        const shop = block.shop;
        const tint = shop ? SHOP[shop.shop] : DINER;
        const g = this.add.graphics();
        root.add(g);
        const y = GROUND_Y - 0.44 * REM;
        const left = box.x + box.w * 0.04;
        const w = box.w * 0.92;
        for (const [from, to, colour, alpha] of [
          [0, 0.14, WIN_A, 0.52], [0.3, 0.52, tint, 0.42], [0.66, 0.88, WIN_A, 0.52]]) {
          g.fillStyle(colour, alpha);
          g.fillRect(left + w * from, y, Math.max(0.6, w * (to - from)), 0.44 * REM);
        }
        g.setAlpha(0.94);
        if (!shop) return;
        if (shop.neon) {
          const neon = this.add.graphics();
          root.add(neon);
          const nx = left + w * (shop.bay * 0.19);
          const ny = GROUND_Y - 0.52 * REM - 0.15 * REM;
          glow(neon, tint, nx + w * 0.1, ny, w * 0.22, 0.5 * REM, 0.45, 5);
          neon.fillStyle(tint, 1);
          neon.fillRect(nx, ny, Math.max(0.6, w * 0.2), Math.max(0.6, 0.15 * REM));
          parts.shop.neon = neon;
          parts.shop.neonPhase = shop.flicker;
        }
        // A hanging vertical sign in the idiom the towers already use, bracketed
        // to one shoulder of the frontage rather than hung over a bay, so it is
        // bounded by the building paying for it whichever way it hangs.
        const size = Math.max(4, Math.min(0.78 * REM, box.w * 0.3));
        const plate = this.add.graphics();
        root.add(plate);
        const px = shop.side ? box.x + box.w - size * 1.4 : box.x;
        const py = GROUND_Y - 0.62 * REM - size * 1.4;
        plate.fillStyle(0x02060a, 0.55);
        plate.fillRect(px, py, size * 1.4, size * 1.4);
        plate.lineStyle(0.6, tint, 0.34);
        plate.strokeRect(px, py, size * 1.4, size * 1.4);
        const glyph = this.add.text(px + size * 0.7, py + size * 0.7, shop.glyph, {
          fontFamily: CJK, fontSize: size + 'px', color: hex(tint),
        });
        root.add(glyph);
        glyph.setOrigin(0.5, 0.5);
        parts.shop.glyph = glyph;
        parts.shop.glyphPlate = plate;
        parts.shop.glyphPhase = shop.hang;
      }

      renderDistrict(model) {
        // The dedication is what the week arrives into: stood up once, before
        // the week's first building, and left alone after that.
        if (!this.landmark) {
          const ran = model.landmark;
          this.landmark = this.makeBlock({
            id: '·landmark', kind: 'landmark', depth: ran.depth, x: ran.x,
            storeys: ran.storeys, crew: hex(DINER), shop: null, shape: null,
          });
          const box = this.landmark.box;
          const size = Math.max(6, Math.min(1.3 * REM, box.w * 0.52));
          const plate = this.add.graphics();
          this.landmark.root.add(plate);
          const px = box.x + box.w - size * 0.7;
          const py = box.y + box.h * 0.16;
          plate.fillStyle(0x02060a, 0.6);
          plate.fillRect(px, py, size * 1.4, size * 1.7);
          plate.lineStyle(0.6, DINER, 0.4);
          plate.strokeRect(px, py, size * 1.4, size * 1.7);
          const sign = this.add.text(px + size * 0.7, py + size * 0.85, ran.glyph, {
            fontFamily: CJK, fontSize: size + 'px', color: hex(DINER),
          });
          this.landmark.root.add(sign);
          sign.setOrigin(0.5, 0.5);
          this.landmark.dedication = sign;
          this.landmark.plate = plate;
          this.landmark.root.setDepth(0);
        }
        const standing = new Set(model.blocks.map((b) => b.id));
        for (const [id, parts] of this.blocks) {
          // Only the week rolling over takes a building down, and then it takes
          // the whole district with it.
          if (!standing.has(id)) { parts.root.destroy(); this.blocks.delete(id); }
        }
        let landed = false;
        for (const block of model.blocks) {
          if (this.blocks.has(block.id)) continue;
          const parts = this.makeBlock(block);
          parts.root.setDepth(block.depth + 1);
          this.blocks.set(block.id, parts);
          landed = true;
        }
        // Three depth bands, so the district reads as a city with air in it
        // rather than as a row of bars. Re-sorted only when one lands.
        if (landed) this.districtC.sort('depth');
      }

      // --- one project: a tower -------------------------------------------------

      // The skyline's layout: wall.css hands .city a `space-evenly` flex row with
      // a gap and a padding, and this is that row solved.
      layout(towers) {
        return towerLayout(towers);
      }

      makeTower() {
        const root = this.add.container(0, 0);
        this.cityC.add(root);
        const parts = { root, shaftEls: new Map(), key: '' };
        // Back to front inside one tower, matching the stylesheet's stack.
        for (const key of ['pool', 'spot', 'sweep', 'ceiling', 'mirror', 'body',
                           'facade', 'wash', 'cascade']) {
          parts[key] = this.add.graphics();
          root.add(parts[key]);
        }
        parts.shafts = this.add.container(0, 0);
        root.add(parts.shafts);
        for (const key of ['halo', 'beacon', 'signPlate', 'basePlate']) {
          parts[key] = this.add.graphics();
          root.add(parts[key]);
        }
        // Neon signage: the project's name hung off its tower's shoulder,
        // vertical, in that project's own neon.
        parts.sign = this.add.text(0, 0, '', {
          fontFamily: MONO, fontSize: Math.max(4, 0.78 * REM) + 'px',
          color: '#7fd4ec', align: 'center',
        });
        // The name plate at street level, twice: the beam landing on a building
        // is what turns it white, and two Text objects is cheaper than restyling
        // one every time the carousel moves on.
        parts.label = this.add.text(0, 0, '', {
          fontFamily: MONO, fontSize: Math.max(4, 0.72 * REM) + 'px', color: '#96cdbe',
        });
        parts.labelLit = this.add.text(0, 0, '', {
          fontFamily: MONO, fontSize: Math.max(4, 0.72 * REM) + 'px', color: '#e4fff3',
        });
        root.add(parts.sign);
        root.add(parts.label);
        root.add(parts.labelLit);
        parts.sign.setOrigin(0, 0);
        parts.label.setOrigin(0.5, 0);
        parts.labelLit.setOrigin(0.5, 0);
        parts.labelLit.setVisible(false);
        return parts;
      }

      // A tower's geometry is a fact about the snapshot, so it is drawn when one
      // of those facts changes and left entirely alone in between.
      paintTower(T, tower, box, floors) {
        const h = CITY_H * tower.heightPct / 100;
        const top = GROUND_Y - h;
        const massTop = top + CROWN_H;
        const massH = Math.max(4, GROUND_Y - BASE_LINE - BASE_GAP - massTop);
        const poly = TOWER_SHAPES[tower.shape % TOWER_SHAPES.length];
        const row = TOWER_ROW[tower.shape % 5] * REM;
        const col = TOWER_COL[tower.shape % 5] * REM;
        T.mass = { x: box.x, y: massTop, w: box.w, h: massH, poly, row };
        T.ladder = { x: box.x + box.w * 0.14, w: box.w * 0.72,
                     y: massTop + massH * 0.23, h: massH * 0.77 };
        const key = [tower.shape, tower.crown, tower.heightPct, box.x.toFixed(1),
                     box.w.toFixed(1), floors, tower.alarm ? 1 : 0].join('|');
        if (key !== T.key) {
          T.key = key;
          for (const g of ['pool', 'spot', 'sweep', 'ceiling', 'mirror', 'body',
                           'facade', 'wash', 'basePlate']) T[g].clear();
          T.halo.clear();
          T.beacon.clear();
          const points = outline(poly, box.x, massTop, box.w, massH);
          // Wet tarmac: every tower stands in a little of its own light, and it
          // turns red under an alarm like everything else on that building.
          glow(T.pool, tower.alarm ? ALARM : 0x8cc4ce, box.x + box.w / 2, GROUND_Y,
               box.w * 1.1, 2.2 * REM, 0.24, 7);
          T.pool.setAlpha(tower.alarm ? 1 : 0.9);
          T.body.fillGradientStyle(STONE_LIT, STONE_LIT, STONE, STONE, 1, 1, 1, 1);
          T.body.fillPoints(points, true, true);
          // The lit edge along whatever the silhouette leaves as a roofline.
          T.body.fillStyle(EDGE, 0.45);
          for (const [l, r] of spansAt(poly, 0.002)) {
            T.body.fillRect(box.x + box.w * l, massTop, box.w * (r - l), 0.6);
          }
          this.crownOf(T.body, tower.crown, box.x, top, box.w);
          // The ladder a car climbs, drawn as thin rules across the mass.
          T.body.fillStyle(EDGE, 0.26);
          for (let i = 0; i <= floors; i++) {
            T.body.fillRect(T.ladder.x, T.ladder.y + T.ladder.h * (1 - i / floors),
                            T.ladder.w, 0.6);
          }
          facadeGrid(T.facade, poly, box.x, massTop, box.w, massH, row, col);
          // The wet-tarmac reflection: the same lit facade smeared under its own
          // building. Same grid, same pitch — one source of truth for what a lit
          // facade looks like.
          facadeGrid(T.mirror, poly, box.x, GROUND_Y - massH * 0.34, box.w, massH * 0.34, row, col);
          T.mirror.setAlpha(0.2);
          // A run needs a human: the beam, the lamp it comes out of, and the
          // patch it paints on the overcast just above that roof.
          T.sweep.fillStyle(0xff5a5a, 0.45);
          T.sweep.fillTriangle(0, 0, -0.1 * H, -1.5 * H, 0.1 * H, -1.5 * H);
          glow(T.sweep, ALARM, 0, 0, 2.4 * REM, 2.4 * REM, 0.6, 6);
          T.sweep.fillStyle(0xffffff, 1);
          T.sweep.fillCircle(0, 0, 0.55 * REM);
          T.sweep.setPosition(box.x + box.w / 2, massTop + massH * 0.28);
          glow(T.ceiling, 0xff6068, box.x + box.w / 2, top - 1.5 * VH - 9 * VH,
               22 * VH, 9 * VH, 0.3, 8);
          this.washOf(T.wash, poly, box.x, massTop, box.w, massH);
          // The carousel beam, tower half: out of the low cloud onto the building
          // the brief plate is talking about. A beam has no edges — the shape is
          // wide at the pavement and narrow overhead, it is brightest where it
          // lands and gone before the cloud, and it is soft along both sides.
          // wall.css gets all three from a clip-path, a gradient and a mask;
          // here they are stacked slices, which is the same three things.
          const cx = box.x + box.w / 2;
          const foot = GROUND_Y - h * 0.1;
          const rows = 26;
          for (let i = 0; i < rows; i++) {
            const u = i / rows;                        // 0 at the pavement, 1 at the top
            const y = foot - u * foot;
            const half = box.w * (0.46 - 0.315 * u);
            const a = ramp(SPOT_BEAM, u);
            if (a <= 0) continue;
            // Three nested widths rather than one flat wedge: they composite
            // into a bright core with soft sides, which is what wall.css gets
            // from its horizontal mask.
            for (const [inset, share] of [[1, 0.5], [0.7, 0.5], [0.4, 0.5]]) {
              T.spot.fillStyle(0xdef8ff, a * share);
              T.spot.fillRect(cx - half * inset, y - foot / rows, half * 2 * inset, foot / rows + 0.5);
            }
          }
          glow(T.halo, DONE, cx, top, 4.5 * REM, 4.5 * REM, 0.6, 9);
          glow(T.beacon, DONE, 0, 0, 1.4 * REM, 1.4 * REM, 0.8, 6);
          T.beacon.fillStyle(DONE, 1);
          T.beacon.fillCircle(0, 0, Math.max(0.6, 0.25 * REM));
          T.beacon.setPosition(cx, top);
          T.sign.setPosition(box.x + box.w + 0.2 * REM, top + h * 0.12);
          T.label.setPosition(cx, GROUND_Y - BASE_LINE);
          T.labelLit.setPosition(cx, GROUND_Y - BASE_LINE);
          // A tower asking for a human says so at street level too: the name
          // plate goes solid red with the name in white on it, which is the
          // loudest sentence this wall has and the one the room reads first.
          if (tower.alarm) {
            T.basePlate.fillStyle(ALARM, 1);
            T.basePlate.fillRect(box.x - 0.4 * REM, GROUND_Y - BASE_LINE - 0.12 * REM,
                                 box.w + 0.8 * REM, BASE_LINE + 0.24 * REM);
          }
        }
        T.basePlate.setVisible(tower.alarm);
        const stacked = tower.label.split('').join('\n');
        if (T.sign.text !== stacked) {
          T.sign.setText(stacked);
          T.label.setText(tower.label);
          T.labelLit.setText(tower.label);
        }
        // Red never appears on a sign unless the tower is asking for a human.
        const signColour = tower.alarm ? hex(ALARM) : tower.sign;
        if (T.signColour !== signColour || T.signKey !== key) {
          T.signColour = signColour;
          T.signKey = key;
          T.sign.setColor(signColour);
          // The tube is bolted to a dark plate with a hairline in its own
          // colour: that frame is what makes it read as a sign at this size
          // rather than as loose lettering on the facade.
          T.signPlate.clear();
          T.signPlate.fillStyle(0x02060a, 0.6);
          T.signPlate.fillRect(T.sign.x - 0.16 * REM, T.sign.y - 0.3 * REM,
                               T.sign.width + 0.32 * REM, T.sign.height + 0.6 * REM);
          T.signPlate.lineStyle(0.6, rgb(signColour), 0.4);
          T.signPlate.strokeRect(T.sign.x - 0.16 * REM, T.sign.y - 0.3 * REM,
                                 T.sign.width + 0.32 * REM, T.sign.height + 0.6 * REM);
        }
        T.sweep.setVisible(tower.alarm);
        T.ceiling.setVisible(tower.alarm);
        T.wash.setVisible(tower.alarm);
        T.tower = tower;

        const standing = new Set(tower.shafts.map((s) => s.id));
        for (const [id, S] of T.shaftEls) {
          if (!standing.has(id)) { S.root.destroy(); T.shaftEls.delete(id); }
        }
        const wide = T.ladder.w / Math.max(1, tower.shafts.length);
        tower.shafts.forEach((run, i) => {
          let S = T.shaftEls.get(run.id);
          if (!S) {
            S = { root: this.add.container(0, 0), col: this.add.graphics(),
                  halo: this.add.graphics(), car: this.add.graphics(), key: '' };
            S.root.add(S.col);
            S.root.add(S.halo);
            S.root.add(S.car);
            T.shafts.add(S.root);
            T.shaftEls.set(run.id, S);
          }
          this.paintShaft(S, run, { x: T.ladder.x + wide * i, w: wide,
                                    y: T.ladder.y, h: T.ladder.h });
        });
      }

      // The klaxon wash. wall.css does it with one inset box-shadow — 4rem of
      // rgba(190, 0, 20, 0.85) hugging the inside of the mass, plus a 3rem outer
      // glow — and at the peak of the pulse an alarm tower is unmistakably red
      // from the far side of a room. Graphics has no inset shadow, so it is
      // built the way this world already knows how to build a silhouette: the
      // mass at the shadow's ambient strength, then shells that ramp up to it
      // down every edge, scanline-clipped so a setback or a taper wears the
      // wash exactly where its wall is.
      washOf(g, poly, x, y, w, h) {
        const depth = Math.max(1, Math.min(4 * REM, w * 0.5, h * 0.5));
        const rows = 40;
        const band = h / rows;
        const shells = 5;
        for (let i = 0; i < rows; i++) {
          const t = (i + 0.5) / rows;
          const fromEdge = Math.min(t * h, (1 - t) * h);   // roofline or pavement
          for (const [l, r] of spansAt(poly, t)) {
            const left = x + w * l;
            const wide = w * (r - l);
            if (wide <= 0) continue;
            g.fillStyle(0xbe0014, 0.18);
            g.fillRect(left, y + i * band, wide, band + 0.5);
            for (let k = 0; k < shells; k++) {
              const reach = depth * (1 - k / shells);
              g.fillStyle(0xbe0014, 0.08);
              if (fromEdge <= reach) {
                g.fillRect(left, y + i * band, wide, band + 0.5);
              } else {
                const side = Math.min(reach, wide / 2);
                g.fillRect(left, y + i * band, side, band + 0.5);
                g.fillRect(left + wide - side, y + i * band, side, band + 0.5);
              }
            }
          }
        }
        // And the 3rem the glow reaches off the building into the wet air. Kept
        // tight: it is an edge on the mass, not a red fog over the district.
        glow(g, ALARM, x + w / 2, y + h / 2, w / 2 + 3 * REM, h / 2 + 3 * REM, 0.2, 5);
      }

      // Roof furniture: a mast, a water tank, a sign rig. Two hash slices pick
      // the body outline and the crown, so a handful of repos read as different
      // buildings rather than as a bar chart.
      crownOf(g, crown, x, top, w) {
        g.fillStyle(STONE, 1);
        const bottom = top + CROWN_H;
        const put = (l, cw, ch, off) =>
          g.fillRect(x + w * l, bottom - ch - (off || 0), Math.max(0.6, cw), ch);
        if (crown === 0) {
          put(0.5, 0.14 * REM, 2.4 * REM);
        } else if (crown === 1) {
          put(0.22, w * 0.22, 1.1 * REM);
          put(0.68, 0.12 * REM, 2.2 * REM);
        } else if (crown === 2) {
          // A sign rig: two decks on two posts, the second post one box-shadow
          // to the right of the first in the stylesheet and 3.2rem here.
          put(0.18, w * 0.64, 0.14 * REM);
          put(0.18, w * 0.64, 0.14 * REM, 0.9 * REM);
          put(0.24, 0.12 * REM, 1.6 * REM);
          g.fillRect(x + w * 0.24 + 3.2 * REM, bottom - 1.6 * REM,
                     Math.max(0.6, 0.12 * REM), 1.6 * REM);
        } else {
          put(0.08, w * 0.84, 0.5 * REM);
        }
      }

      // One run: a lit car in its shaft, with the storeys it has climbed lit
      // behind it. Redrawn when the car reaches a new floor and not otherwise.
      paintShaft(S, run, box) {
        const tint = run.state === 'alarm' ? ALARM
          : run.state === 'ready' ? DONE
            : run.state === 'failed' ? ACTOR.failed
              : (ACTOR[run.actorKey] || ACTOR.unknown);
        const key = [run.state, run.actorKey, run.level.toFixed(4), run.crew,
                     box.x.toFixed(1), box.w.toFixed(1), box.h.toFixed(1)].join('|');
        if (key !== S.key) {
          S.key = key;
          S.col.clear();
          S.car.clear();
          S.halo.clear();
          const lit = box.h * Math.max(0, Math.min(1, run.level));
          const carY = box.y + box.h - lit;
          // The column of the building this run occupies, lit up to the car —
          // real storeys at the tower's own pitch, not a bar that stretches.
          S.col.fillStyle(tint, 0.3);
          for (let y = box.y + box.h - 0.44 * REM; y > box.y + box.h - lit; y -= 0.88 * REM) {
            S.col.fillRect(box.x, Math.max(box.y, y), box.w, 0.44 * REM);
          }
          S.col.setAlpha(0.8);
          S.col.fillStyle(tint, 0.6);
          S.col.fillRect(box.x + box.w / 2 - 0.07 * REM, box.y, Math.max(0.6, 0.14 * REM), box.h);
          // The floor the car is standing on, lit right across the shaft: this
          // is the line that carries "which stage" to the far side of the room.
          const carW = (run.state === 'alarm' ? 1.1 : 1.3) * REM;
          const carH = (run.state === 'alarm' ? 0.7 : 0.74) * REM;
          S.car.fillStyle(tint, 0.75);
          S.car.fillRect(-box.w / 2 - 0.9 * REM, -0.07 * REM,
                         box.w + 1.8 * REM, Math.max(0.6, 0.14 * REM));
          // Who dispatched this run: a tinted lamp under the car itself.
          glow(S.car, rgb(run.crew), 0, carH * 0.62, 0.4 * REM, 0.2 * REM, 0.9, 5);
          S.car.fillStyle(tint, 1);
          S.car.fillRect(-carW / 2, -carH / 2, carW, carH);
          S.car.fillStyle(0xf2fbff, 0.5);
          S.car.fillRect(-carW / 2, -carH / 2, carW, Math.max(0.6, carH * 0.3));
          // The bloom the carousel beam makes where it lands. It rides with the
          // car, so it is on it at whatever floor the car is on.
          glow(S.halo, 0xe2f8ff, 0, 0, 3 * REM, 3 * REM, 0.45, 7);
          S.car.setPosition(box.x + box.w / 2, carY);
          S.halo.setPosition(box.x + box.w / 2, carY);
          S.halo.setVisible(false);
        }
        S.run = run;
      }

      // --- the seam -------------------------------------------------------------

      apply(model) {
        this.model = model;
        this.paintGhost(model.ghosts);
        this.renderDistrict(model);
        const boxes = this.layout(model.towers);
        const standing = new Set(model.towers.map((t) => t.project));
        for (const [project, T] of this.towers) {
          if (!standing.has(project)) { T.root.destroy(); this.towers.delete(project); }
        }
        model.towers.forEach((tower, i) => {
          let T = this.towers.get(tower.project);
          if (!T) { T = this.makeTower(); this.towers.set(tower.project, T); }
          this.paintTower(T, tower, boxes[i], model.floors);
        });
        // Nightlife never competes with work: the instant anything is climbing,
        // the whole ground floor drops a stop and the skyline keeps the eye.
        this.lifeC.setVisible(model.blocks.length > 0);
        this.lifeC.setAlpha(model.quiet ? 1 : 0.5);
        this.districtC.setAlpha(model.quiet ? 1 : 0.86);
        const plan = model.street;
        while (this.walkers.length > plan.walkers) this.walkers.pop().g.destroy();
        while (this.walkers.length < plan.walkers) this.walkers.push(this.makeWalker(this.walkers.length));
        while (this.vehicles.length > plan.vehicles) this.vehicles.pop().g.destroy();
        while (this.vehicles.length < plan.vehicles) this.vehicles.push(this.makeVehicle(this.vehicles.length));
        this.mall.setData('on', plan.mall);
        this.rail.setData('on', plan.tram);
        this.tram.setData('on', plan.tram);
        this.spot(pendingSpot);
        this.step(true);
      }

      spot(runId) {
        pendingSpot = runId;
        let lit = false;
        for (const T of this.towers.values()) {
          let hit = false;
          for (const [id, S] of T.shaftEls) {
            const on = id === runId;
            S.halo.setVisible(on);
            hit = hit || on;
          }
          T.spot.setVisible(hit);
          // An alarm's own plate is white on red whether or not the beam is on
          // it; the beam is what turns an ordinary tower's name white.
          const white = hit || (T.tower && T.tower.alarm);
          T.label.setVisible(!white);
          T.labelLit.setVisible(!!white);
          if (!white) T.labelLit.setAlpha(1);
          lit = lit || hit;
        }
        // With a beam on one building the rest of the city steps back, which is
        // what turns "brighter" into "that one".
        for (const T of this.towers.values()) {
          const keep = T.spot.visible || (T.tower && T.tower.alarm);
          T.root.setAlpha(lit && !keep ? 0.6 : 1);
        }
      }

      // --- the frame ------------------------------------------------------------

      update() { this.step(false); }

      // One frame. Nothing here draws: it reads the clock once, asks phaseAt()
      // where everything is, and moves what is already on the GPU. Under reduced
      // motion the phase never changes, so the first settled frame is the last
      // and no timer advances any state at all.
      step(force) {
        const frozen = still.matches;
        if (frozen && !force && this.phase.still) return;
        const at = clock();
        const phase = phaseAt(at, { reducedMotion: frozen });
        this.phase = phase;
        const model = this.model;

        this.skyC.setScale(phase.cam.sky);
        this.skyC.setPosition(W * (1 - phase.cam.sky) / 2, H * (1 - phase.cam.sky));
        this.planes.forEach((plane, i) => plane.setX(phase.planes[i]));
        this.ghostG.setX(phase.ghost);
        this.cityC.setScale(phase.cam.city);
        this.cityC.setPosition(W * (1 - phase.cam.city) / 2, GROUND_Y * (1 - phase.cam.city));
        this.hazeSlabs.forEach((slab, i) => slab.setX(-0.3 * W + phase.air[i]));
        this.ships.forEach((ship, i) => {
          ship.setAlpha(phase.ships[i].a);
          ship.setX(-0.1 * W + (SHIPS[i].back ? 120 * VW - phase.ships[i].x : phase.ships[i].x));
        });
        this.streetCars.forEach((car, i) => {
          car.setAlpha(phase.street[i].a);
          car.setX(-0.14 * W
            + (STREET_CARS[i].back ? 128 * VW - phase.street[i].x : phase.street[i].x));
        });
        this.vents.forEach((vent, i) => {
          vent.setAlpha(phase.steam[i].a);
          vent.setPosition(VENTS[i].x * W + phase.steam[i].x,
                           H - 0.6 * VH - VENTS[i].h * REM * 0.5 + phase.steam[i].y);
          vent.setScale(phase.steam[i].s);
        });
        this.mall.setAlpha(this.mall.getData('on') ? 0.9 : 0);
        this.rail.setAlpha(this.rail.getData('on') ? 1 : 0);
        this.tram.setAlpha(this.tram.getData('on') ? phase.tram.a : 0);
        this.tram.setX(phase.tram.x);
        for (const walker of this.walkers) walker.g.setX(walkerAt(phase, walker.slot, walker.robot));
        if (model) {
          for (const vehicle of this.vehicles) {
            const step = vehicleAt(phase, vehicle.slot, model.street);
            vehicle.g.setAlpha(step.a);
            vehicle.g.setX(step.x);
          }
        }
        // The two ambient samples, re-read off this world's own clock exactly
        // like the DOM world re-reads them onto the root element — and left at
        // the static scene under reduced motion, as wall.css leaves them.
        if (frozen || !Model) {
          this.hazeC.setAlpha(1);
          this.dawnG.setAlpha(0);
        } else {
          this.hazeC.setAlpha(0.45 + 0.55 * Model.wetness(at - Model.RAIN_LAG));
          this.dawnG.setAlpha(Model.dawn(new Date(at * 1000)));
        }
        if (this.landmark) this.landmark.dedication.setAlpha(tubeAt(phase, -7, 16));

        for (const parts of this.blocks.values()) this.stepBlock(parts, phase, at, model);
        for (const T of this.towers.values()) this.stepTower(T, phase, at, model);
      }

      stepBlock(parts, phase, at, model) {
        const block = parts.block;
        const shop = parts.shop;
        if (shop.neon) shop.neon.setAlpha(tubeAt(phase, shop.neonPhase, 23));
        if (shop.glyph) {
          const lit = tubeAt(phase, shop.glyphPhase, 23);
          shop.glyph.setAlpha(lit);
          shop.glyphPlate.setAlpha(lit);
        }
        parts.panes.forEach((pane, i) => pane.g.setAlpha(paneAt(phase, i, pane.phase * 13)));
        // A building lands with one settle and is furniture after that — and the
        // age it is fast-forwarded by is the same one --age carries in the DOM
        // world, so a browser opening this afternoon finds this morning's
        // buildings standing rather than the whole week landing at once.
        const age = Math.max(0, at - (block.at || at));
        parts.root.setAlpha(phase.still ? 1 : Math.min(1, age / 0.9));
        parts.root.setY(phase.still ? 0 : Math.max(0, 1 - age / 0.9) * 1.4 * REM);
        // The dispatcher's tint cooling out of the sign, on the server's clock.
        if (model) {
          parts.sign.setAlpha(ramp(SIGN_COOL, once(age, model.signSeconds || 1)));
        }
      }

      stepTower(T, phase, at, model) {
        const tower = T.tower;
        if (!tower) return;
        const drift = model ? at - model.at : 0;
        const completion = (model && model.completionSeconds) || 0;
        T.facade.setAlpha(facadeAt(phase, tower.drift));
        const tube = tubeAt(phase, tower.drift, 16);
        T.sign.setAlpha(tube);
        T.signPlate.setAlpha(tube);
        if (tower.alarm) {
          T.sweep.setRotation(phase.sweep * Math.PI / 180);
          T.ceiling.setX(phase.sweep * 0.14 * VH);
          T.wash.setAlpha(phase.klaxon);
          T.basePlate.setAlpha(phase.text);
          T.labelLit.setAlpha(phase.text);
        }
        if (tower.shipped) {
          const age = tower.shippedAge + drift;
          const u = once(age, completion);
          T.beacon.setVisible(true);
          T.beacon.setAlpha(phase.still ? 1 : ramp(BEACON_ALPHA, u));
          T.beacon.setScale(phase.still ? 1 : ramp(BEACON_SCALE, u));
          const c = once(age, CEREMONY);
          T.halo.setVisible(!phase.still && c < 1);
          T.halo.setAlpha(ramp(HALO_ALPHA, c));
          T.halo.setScale(ramp(HALO_SCALE, c));
          this.paintCascade(T, c, phase);
        } else {
          T.beacon.setVisible(false);
          T.halo.setVisible(false);
          T.cascade.setVisible(false);
        }
        for (const S of T.shaftEls.values()) {
          const run = S.run;
          if (!run) continue;
          if (run.state === 'ready' || run.state === 'failed') {
            // The completion moment: the car flares where it stopped and the
            // shaft goes dark behind it before the run leaves the skyline.
            const u = once(run.age + drift, completion);
            S.col.setAlpha(0.8 * ramp(LIGHTS_OUT, u));
            S.car.setAlpha(ramp(FLARE_ALPHA, u));
            S.car.setScale(ramp(FLARE_SCALE, u));
          } else {
            S.col.setAlpha(0.8);
            S.car.setScale(S.halo.visible ? 1.3 : 1);
            S.car.setAlpha(run.state === 'alarm' ? phase.carAlarm
              : run.state === 'active' ? phase.car : 1);
          }
        }
      }

      // The shipping cascade is the one thing in this world whose GEOMETRY moves:
      // light climbing the facade floor by floor for six seconds, once per ship.
      // It is a travelling glow behind a storey mask that stays put, and there is
      // no way to hold that mask still without redrawing the lit rows — so it is
      // redrawn, only while the beat is running, and only on a shipping tower.
      paintCascade(T, u, phase) {
        if (phase.still || u >= 1 || !T.mass) { T.cascade.setVisible(false); return; }
        const mass = T.mass;
        T.cascade.setVisible(true);
        T.cascade.clear();
        T.cascade.setAlpha(ramp(CASCADE_ALPHA, u));
        const head = mass.y + mass.h - u * mass.h * 2.05;
        for (let y = mass.y; y < mass.y + mass.h; y += mass.row * 2) {
          const near = (y - head) / mass.h;
          if (near > 0.02 || near < -0.6) continue;
          const k = Math.max(0, 1 + near / 0.6);
          T.cascade.fillStyle(0xe8fff4, k * 0.85);
          for (const [l, r] of spansAt(mass.poly, (y - mass.y) / mass.h)) {
            T.cascade.fillRect(mass.x + mass.w * l, y, mass.w * (r - l), mass.row);
          }
        }
      }
    }

    const game = new Phaser.Game({
      type: Phaser.AUTO,
      scale: {
        // The canvas covers #stage at the viewport's own aspect — no fixed
        // grid, no FIT, no letterbox — and its backing store is device pixels.
        // NONE means Phaser leaves the sizing to us, and `zoom` is what puts a
        // device-pixel canvas back at CSS size on screen: the buffer is W x H
        // device pixels, the element is W/DPR x H/DPR CSS pixels, which is
        // exactly the box the DOM world's layers fill.
        mode: Phaser.Scale.NONE,
        parent: host,
        expandParent: false,
        width: W,
        height: H,
        zoom: 1 / DPR,
      },
      render: {
        // smoothPixelArt sets antialias and pixelArt itself; declaring either
        // here would fight it.
        smoothPixelArt: true,
        roundPixels: true,
        powerPreference: 'low-power',
      },
      fps: { limit: 30 },
      audio: { noAudio: true },
      banner: false,
      backgroundColor: BG,
      scene: CityScene,
    });

    // A resized wall is re-measured and laid out again rather than stretched:
    // every size in this world is derived from the stage, so a new stage is a
    // new city, not the old one scaled. Debounced on the same 400 ms the
    // director re-frames on — dragging a window edge across a desktop must not
    // rebuild the district sixty times — and a no-op size change is ignored.
    let relayout = 0;
    window.addEventListener('resize', () => {
      clearTimeout(relayout);
      relayout = setTimeout(() => {
        const size = stageSize();
        const dpr = ratio();
        if (!size.w || !size.h) return;
        if (Math.round(size.w * dpr) === W && Math.round(size.h * dpr) === H) return;
        measure(size.w, size.h, dpr);
        // Order matters: resize() sets the backing store, and setZoom() then
        // refreshes the CSS size off it. The other way round leaves the canvas
        // displayed at whatever size the previous wall was.
        game.scale.resize(W, H);
        game.scale.setZoom(1 / DPR);
        // The whole world is geometry measured off the old stage, so it is
        // rebuilt from the scene model rather than repositioned piecemeal.
        if (city) city.scene.restart();
      }, 400);
    });

    // A room that turns motion off mid-shift gets the still frame without a
    // reload, and one that turns it back on gets the city moving again. The
    // guard is the page's own — there is exactly one matchMedia on this wall.
    still.addEventListener('change', () => { if (city) city.step(true); });

    return {
      render(model) {
        pending = model;
        if (city) city.apply(model);
      },
      spot(runId) {
        pendingSpot = runId;
        if (city) city.spot(runId);
      },
      tick() { if (city) city.step(true); },
      game,
    };
  }

  // What measure() last worked out, so the suite can ask this world how big it
  // thinks a given wall is without standing a GPU up to find out.
  const grid = () => ({
    w: W, h: H, dpr: DPR, vw: VW, vh: VH, rem: REM, px: PX,
    sky: SKY, skyX: SKY_X, skyY: SKY_Y,
    ground: GROUND, groundY: GROUND_Y, cityH: CITY_H, hazeH: HAZE_H,
  });

  return {
    create, measure, grid, phaseAt, tubeAt, paneAt, facadeAt, walkerAt, vehicleAt,
    ramp, spansAt, outline, towerLayout,
  };
}));
