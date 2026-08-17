'use strict';
// The city's second body — and, from this pass on, a game rather than a
// transcription. Same scene model (wall/scene.js), same city, same light
// language; drawn by the vendored Phaser 4 in wall/vendor/ out of pixel art
// generated for this repo (wall/assets/city/) instead of out of the browser's
// layout engine. Opened with ?world=canvas; the DOM world is still the default,
// and neither this file nor the engine is fetched unless the query string
// asked.
//
// The three rules this rewrite is built on:
//
//   THE WORLD'S PIXEL IS THE CONTRACT'S PIXEL. .creative/proportions.md states
//   every size at 1280x720: a person ~10 px, a storey ~14, a street car ~43, a
//   16 px district tile, a 32 px facade panel. So the world is ALWAYS 1280
//   world-pixels wide, whatever the wall is, and the engine scales it to the
//   panel — exactly 3x on the office 4K TV, exactly 1:1 at the visual gate's
//   viewport. Nothing is authored in vh/rem-of-the-moment any more; a sprite
//   drawn at 32 px is 32 px of the city everywhere.
//
//   SOLIDS ARE SPRITES, LIGHT IS DRAWN. Every façade, shopfront, crown, prop,
//   vehicle and walker is committed pixel art on the 32-colour lock, packed in
//   one atlas, stamped into a RenderTexture per building at the moment that
//   building's geometry changes — so the frame loop moves objects and never
//   redraws geometry. Everything that is LIGHT — sky, haze, lamp pools, shop
//   spill, window bloom, the alarm beam, the carousel spot, wet reflections —
//   is Graphics and additive blending on the GPU, because light is the half of
//   this picture that has to change colour at runtime. Alarm red and shipped
//   green are never baked into a PNG: they are a tint or a lamp, always.
//
//   ONE CLOCK, AND NOTHING KEEPS ITS OWN STATE. Every moving thing is a pure
//   function of one monotonic time source — phaseAt() — anchored ONCE to the
//   wall clock at boot. Never Date.now()+skew per frame: the skew is
//   re-measured on every snapshot and steps sideways, which is a city that
//   jumps every time the server speaks. Reduced motion pins that function to a
//   single lit frame, provable in Node without a browser.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallCanvasWorld = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the grid -----------------------------------------------------------------
  // One number decides everything below it: the world is GRID_W world-pixels
  // wide, always. The backing store is the wall in device pixels (capped at
  // dpr 2, past which the fill rate costs more than the sharpness is worth on a
  // panel nobody stands close to), and PIX — device pixels per world pixel — is
  // what the engine's camera zooms by. On the office TV that lands on exactly 3
  // and every authored pixel is a clean 3x3 block; at 1440x900 it lands on 2.25
  // and roundPixels/smoothPixelArt carry it.
  const GRID_W = 1280;
  // html { font-size: clamp(12px, 1.05vw, 26px) } resolved at 1280 — the module
  // .creative/proportions.md states every measurement against. It is a
  // CONSTANT here, unlike the DOM's, because the world does not change width.
  const REM = 13.44;
  const PANEL = 32;        // one façade panel
  const TILE = 16;         // one district tile
  const GROUND_H = 32;     // the ground floor: the storey the street reads
  const CEREMONY = 6;      // --ceremony, the shipping beat
  // The config every sprite in this world is stamped with: top-left origin, so
  // a world coordinate is the pixel the sprite lands on.
  const STAMP0 = { originX: 0, originY: 0 };

  let DPR = 1;
  let W = GRID_W;          // backing store, device pixels
  let H = 720;
  let PIX = 1;             // device pixels per world pixel
  let GW = GRID_W;         // the world, in its own pixels
  let GH = 720;
  let VW = GW / 100;
  let VH = GH / 100;
  let TXT = 1;             // how many device pixels a lettering pixel is drawn at

  let GROUND = 9 * VH;     // --ground
  let GROUND_Y = GH - GROUND;
  let CITY_H = 74 * VH;    // .city — the skyline band
  let DISTRICT_H = 56 * VH;
  // The sky's viewBox is 1600x900 under `xMidYMid slice`: cover the box,
  // centred, so a wall that is not 16:9 crops the painting exactly as the DOM
  // world crops it.
  let SKY = GW / 1600;
  let SKY_X = 0;
  let SKY_Y = 0;

  function measure(cssWidth, cssHeight, ratio) {
    DPR = Math.min(Math.max(Number(ratio) || 1, 1), 2);
    W = Math.max(1, Math.round(cssWidth * DPR));
    H = Math.max(1, Math.round(cssHeight * DPR));
    PIX = W / GRID_W;
    GW = GRID_W;
    GH = Math.max(1, H / PIX);
    VW = GW / 100;
    VH = GH / 100;
    TXT = Math.max(1, Math.min(4, Math.round(PIX)));
    GROUND = 9 * VH;
    GROUND_Y = GH - GROUND;
    CITY_H = 74 * VH;
    DISTRICT_H = 56 * VH;
    SKY = Math.max(GW / 1600, GH / 900);
    SKY_X = (GW - 1600 * SKY) / 2;
    SKY_Y = (GH - 900 * SKY) / 2;
  }

  // --- the palette --------------------------------------------------------------
  // wall.css's :root and .creative/palette.png, as integers. The sprites carry
  // the lock; these are what the LIGHT is drawn with, and light is allowed to
  // blend past the lock exactly as the DOM's gradients do.
  const BG = 0x010306;
  const STONE = 0x0a1220;
  const EDGE = 0x96c3c8;
  const WIN_A = 0xffc680;
  const WIN_B = 0xdeeaee;
  const WIN_C = 0x7ad6ec;
  const ALARM = 0xff2f45;
  const DONE = 0x3fd984;
  const DINER = 0xffc27d;
  const LAMP = 0xffc27d;
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

  // --- the set ------------------------------------------------------------------
  // What the atlas carries and which building wears it. Every name here is a
  // frame in wall/assets/city/atlas.json, which is a row in
  // wall/assets/MANIFEST.md, which is an entry in .creative/assets.json.
  const ATLAS = 'city';
  const SKIN = {
    concrete: 'city-facade-concrete-lit',
    glass: 'city-facade-glass-lit',
    brick: 'city-facade-brick-lit',
    shophouse: 'city-block-shophouse',
    warehouse: 'city-block-warehouse',
    setback: 'city-block-setback',
    slab: 'city-block-slab',
    tenement: 'city-block-tenement',
  };
  // There is no unlit sprite of anything, and there is not going to be. A floor
  // with nobody on it is the SAME wall with the light taken out of it — one
  // multiply tint, applied by the renderer — which is the bible's own rule (a
  // sprite is authored once at full value) and also the only version the
  // generator would agree to: every roll asking for "every window dark" came
  // back with the windows lit.
  const UNLIT = 0x39434c;
  const STAMP_DARK = { originX: 0, originY: 0, tint: UNLIT, tintFill: false };
  // A tower's material rides the same hash slice its silhouette does, so a
  // project keeps its own building run to run.
  const TOWER_SKIN = ['concrete', 'glass', 'brick', 'concrete', 'glass'];
  // Six typologies, six walls — the whole point of the typology draw is that
  // the district is not a picket fence of one wall at different heights.
  const FORM_SKIN = {
    shophouse: 'shophouse', warehouse: 'warehouse', tank: 'slab',
    slab: 'slab', setback: 'setback', mast: 'tenement',
  };
  const KIND_SKIN = {
    residential: 'slab', industrial: 'warehouse', spire: 'setback',
    infra: 'warehouse', midrise: 'slab', landmark: 'concrete',
  };
  // One ground floor, and one only: a shop that is open. A shop that is SHUT is
  // the same strip with the light taken out of it, same as an empty floor
  // upstairs. Three separate rolls of a shutter and a lobby came back with
  // invented lettering across them and were thrown away rather than retouched,
  // which is the rule the room's first batch set (wall/assets/MANIFEST.md).
  const GROUND_FRAME = 'city-ground-shop';
  const GROUND_W = 64;     // the ground strip is two panels wide
  // What stands on a roof, by typology. The silhouette is what the room reads
  // from the sofa, so every family stands its own thing up there.
  const ROOF = {
    shophouse: ['city-crown-deck'], warehouse: ['city-prop-ac'],
    tank: ['city-crown-tank'], slab: ['city-prop-ac'],
    setback: ['city-crown-rig'], mast: ['city-prop-antenna'],
  };
  const CROWN = ['city-crown-deck', 'city-crown-rig', 'city-crown-tank', 'city-crown-mast'];
  const WALKERS = ['city-walker', 'city-walker-b'];

  // --- the silhouettes ----------------------------------------------------------
  // wall.css cuts every building with a clip-path. A clip-path is what CSS does
  // instead of architecture; pixel art does it with MASS. Each entry is a stack
  // of rectangles, all of them standing on the pavement, given as a fraction of
  // the building's box: {x, w} across, {top} down. The union is the silhouette,
  // and because every rectangle is axis-aligned on the world grid there is not
  // one off-grid edge in the city.
  const TOWER_MASSES = [
    [{ x: 0, w: 1, top: 0 }],
    [{ x: 0, w: 1, top: 0.14 }, { x: 0.09, w: 0.82, top: 0.06 }, { x: 0.22, w: 0.56, top: 0 }],
    [{ x: 0, w: 1, top: 0.13 }, { x: 0.17, w: 0.66, top: 0 }],
    [{ x: 0, w: 1, top: 0.21 }, { x: 0.57, w: 0.43, top: 0 }],
    [{ x: 0, w: 1, top: 0.6 }, { x: 0.07, w: 0.86, top: 0.3 }, { x: 0.14, w: 0.72, top: 0 }],
  ];
  const FORM_MASSES = {
    shophouse: [{ x: 0, w: 1, top: 0.3 }, { x: 0.18, w: 0.22, top: 0.14 },
                { x: 0.62, w: 0.22, top: 0 }],
    warehouse: [{ x: 0, w: 1, top: 0.34 }, { x: 0.06, w: 0.2, top: 0.14 },
                { x: 0.4, w: 0.2, top: 0.14 }, { x: 0.74, w: 0.2, top: 0.14 }],
    tank: [{ x: 0, w: 1, top: 0.14 }],
    slab: [{ x: 0, w: 1, top: 0.09 }],
    setback: [{ x: 0, w: 1, top: 0.2 }, { x: 0.2, w: 0.6, top: 0.06 }],
    mast: [{ x: 0, w: 1, top: 0.18 }],
  };
  const KIND_MASSES = {
    residential: [{ x: 0, w: 1, top: 0.09 }, { x: 0.22, w: 0.56, top: 0 }],
    industrial: [{ x: 0, w: 1, top: 0.16 }],
    spire: [{ x: 0, w: 1, top: 0.2 }, { x: 0.28, w: 0.44, top: 0 }],
    infra: [{ x: 0, w: 1, top: 0 }],
    midrise: [{ x: 0, w: 1, top: 0 }],
    landmark: [{ x: 0, w: 1, top: 0.13 }, { x: 0.16, w: 0.68, top: 0.05 },
               { x: 0.34, w: 0.32, top: 0 }],
  };
  function massesOf(block) {
    if (block.shape && FORM_MASSES[block.shape.form]) return FORM_MASSES[block.shape.form];
    return KIND_MASSES[block.kind] || KIND_MASSES.midrise;
  }

  // The district's proportion tables, straight off wall.css.
  const DEPTHS = [{ deep: 0.74, veil: 0.62 }, { deep: 0.92, veil: 0.34 },
                  { deep: 1.12, veil: 0.12 }];
  const KINDS = {
    residential: { wide: 0.72, tall: 1.16 }, industrial: { wide: 1.55, tall: 0.74 },
    spire: { wide: 0.58, tall: 1.1 }, infra: { wide: 1.85, tall: 0.5 },
    midrise: { wide: 1, tall: 1 }, landmark: { wide: 1.15, tall: 1.25 },
  };
  const FORMS = {
    shophouse: { wide: 1.62, tall: 0.40, floor: 6.5 },
    warehouse: { wide: 1.86, tall: 0.34, floor: 6 },
    tank: { wide: 1.06, tall: 0.66, floor: 8 },
    slab: { wide: 1, tall: 0.88, floor: 9 },
    setback: { wide: 0.94, tall: 1, floor: 11 },
    mast: { wide: 0.42, tall: 1, floor: 12 },
  };
  // The veil is the RENDERER's, never a hazier PNG: one multiply tint per depth
  // band, so the same sprite is a near wall in front and a far mass behind.
  const VEIL_TINT = [0x6e8794, 0xa8bac1, 0xe2ecee];

  // --- the skyline's own arithmetic ---------------------------------------------
  // wall.css lays .city out as a `space-evenly` flex row with a fixed padding
  // and gap. Flex shrink applies to the items and not to the gap, so the two
  // budgets are solved separately — and every result is rounded to a whole
  // world pixel, because a tower standing on x.5 is a tower whose windows are
  // half a pixel off their own rhythm at every zoom the wall is ever shown at.
  function towerLayout(towers) {
    const pad = Math.round(3 * VW);
    const gap = Math.round(1.4 * VW);
    const avail = GW - pad * 2;
    const widths = towers.map((tower) => tower.widthRem * REM);
    const widthTotal = widths.reduce((total, width) => total + width, 0);
    const gapTotal = Math.max(0, towers.length - 1) * gap;
    const widthBudget = Math.max(0, avail - gapTotal);
    const squeeze = widthTotal > widthBudget && widthTotal > 0
      ? widthBudget / widthTotal : 1;
    const used = widthTotal * squeeze + gapTotal;
    const slot = towers.length ? Math.max(0, avail - used) / (towers.length + 1) : 0;
    const out = [];
    let cursor = pad + slot;
    for (let i = 0; i < towers.length; i++) {
      const w = Math.max(PANEL, Math.round(widths[i] * squeeze));
      const x = Math.round(cursor);
      out.push({ x, w: Math.min(w, GW - x) });
      cursor += widths[i] * squeeze + gap + slot;
    }
    // Live work is never capped by the server. Once the row is crowded enough
    // that a 32 px minimum would overlap, divide the usable skyline into
    // one-pixel-gutter cells instead. Losing façade detail is preferable to
    // merging two projects into one silhouette or hiding either of them.
    if (!out.some((box, i) => i > 0 && box.x < out[i - 1].x + out[i - 1].w)) return out;
    const cell = avail / towers.length;
    return towers.map((_, i) => {
      const x = Math.round(pad + i * cell);
      const next = Math.round(pad + (i + 1) * cell);
      return { x, w: Math.max(1, next - x - (i < towers.length - 1 ? 1 : 0)) };
    });
  }

  // Where a building stands and how big it is: wall.css's own formula, landed
  // on whole pixels.
  function blockBox(block) {
    const band = DEPTHS[block.depth] || DEPTHS[1];
    const kind = KINDS[block.kind] || KINDS.midrise;
    const form = block.shape ? FORMS[block.shape.form] : null;
    const grade = block.shape ? block.shape.grade : 0;
    const jitter = block.shape ? 1 + (grade - 1.5) * 0.1 : 1;
    const shorten = block.shape ? 1 - grade * 0.05 : 1;
    const w = Math.max(PANEL,
      Math.round(2.9 * REM * band.deep * kind.wide * (form ? form.wide : 1) * jitter));
    const h = Math.max(GROUND_H + TILE, Math.round(Math.max(
      (3.4 + block.storeys * 1.9) * VH * band.deep * kind.tall * (form ? form.tall : 1) * shorten,
      (form ? form.floor : 7) * VH * band.deep)));
    const x = Math.round(block.x * GW - w / 2);
    return { x, y: Math.round(GROUND_Y) - h, w, h, veil: band.veil, depth: block.depth };
  }

  // --- the wall clock -----------------------------------------------------------
  // Everything that moves in this world is a position in a cycle and every one
  // of those positions comes out of phaseAt(), so a browser opened at any
  // second of any day joins the city mid-beat rather than starting the film
  // over — and two frames a second apart show the same car further along rather
  // than a new one somewhere else.

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
  // The near lane, in front of everything: two passes, both rarer than the
  // slowest thing in the air above them.
  const STREET_CARS = [
    { lum: 0.9, period: 143, delay: 0, back: false, warm: true },
    { lum: 0.7, period: 197, delay: 84, back: true, warm: false },
  ];
  const VENTS = [
    { x: 0.18, period: 11, delay: 0 },
    { x: 0.53, period: 14, delay: 6 },
    { x: 0.79, period: 17, delay: 11 },
  ];
  const PANE_PERIODS = [97, 131, 173];
  // The alarm beacon turns, and only ever one way. A beam that swings back is a
  // windscreen wiper; a beam that goes round is a building asking for help.
  const BEAM_PERIOD = 8.8;

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
  const STREAK_ALPHA = [[0, 0], [0.9, 0], [0.92, 1], [0.99, 1], [1, 0]];
  const STREAK_X = [[0, 0], [0.9, 0], [1, 1]];
  const PROWL_ALPHA = [[0, 0], [0.62, 0], [0.66, 1], [0.94, 1], [1, 0]];
  const PROWL_X = [[0, 0], [0.62, 0], [1, 1]];
  const TRAM_ALPHA = [[0, 0], [0.58, 0], [0.62, 1], [0.94, 1], [1, 0]];
  const TRAM_X = [[0, 0], [0.58, 0], [1, 1]];
  const STEAM_ALPHA = [[0, 0], [0.24, 0.5], [0.62, 0.26], [1, 0]];
  const OCCUPANCY = [[0, 0], [0.34, 0], [0.42, 0.85], [0.68, 0.85], [0.78, 0], [1, 0]];
  // A tube on a wet night: lit, with the odd stumble.
  const HUM = [[0, 1], [0.61, 1], [0.62, 0.25], [0.628, 0.9], [0.636, 0.4], [0.646, 1], [1, 1]];
  const SIGN_HUM = [[0, 1], [0.906, 1], [0.91, 0.3], [0.916, 0.85], [0.922, 0.3],
                    [0.928, 0.55], [0.934, 1], [1, 1]];
  const WIN_LIVE = [[0, 0.9], [0.45, 0.72], [0.62, 0.84], [1, 0.9]];
  const BEACON_ALPHA = [[0, 0], [0.04, 1], [0.16, 0.95], [0.62, 0.6], [1, 0]];
  const BEACON_SCALE = [[0, 0.3], [0.04, 2.6], [0.16, 1], [0.62, 1], [1, 0.75]];
  const HALO_ALPHA = [[0, 0], [0.07, 1], [0.32, 0.66], [0.6, 0.88], [1, 0]];
  const HALO_SCALE = [[0, 0.3], [0.07, 1], [0.32, 0.84], [0.6, 1.12], [1, 1.4]];
  const CASCADE_ALPHA = [[0, 0], [0.06, 1], [0.58, 1], [1, 0]];
  const LIGHTS_OUT = [[0, 1], [0.22, 1], [0.7, 0.34], [1, 0]];
  const FLARE_ALPHA = [[0, 1], [0.05, 1], [0.18, 0.85], [1, 0.25]];
  const FLARE_SCALE = [[0, 1], [0.05, 2.7], [0.18, 1.15], [1, 0.85]];
  const SIGN_COOL = [[0, 0.85], [0.08, 0.85], [1, 0]];
  // The lighthouse: bright where it faces the room, gone round the back.
  const BEAM_FACE = [[0, 0], [0.06, 1], [0.44, 1], [0.5, 0], [1, 0]];

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

  // Every moving thing on this wall at one second of the clock. Reduced motion
  // pins the lot to a LIT still — the frame wall.css's reduced-motion block
  // leaves the DOM world standing at — so a test can call this with
  // `{ reducedMotion: true }` at any two seconds and get the same object back.
  function phaseAt(seconds, opts) {
    const frozen = !!(opts && opts.reducedMotion);
    const t = frozen ? 0 : Number(seconds) || 0;
    return {
      still: frozen,
      t,
      // The painted planes drift against each other; ±5 world pixels, which is
      // ±15 on the TV. Depth you feel rather than notice.
      planes: PLANES.map((p) => (frozen ? 0 : (swing(t, p.period) * 2 - 1) * 5 * p.par)),
      ghost: frozen ? 0 : (swing(t, GHOST_DRIFT.period) * 2 - 1) * 5 * GHOST_DRIFT.par,
      air: HAZE_SLABS.map((s) => (frozen ? 0 : loop(t, s.period, s.delay) * 70 * VW)),
      // Reduced motion drops the aircraft and the near lane outright: a
      // headlight streak that cannot travel is a scratch on the panel.
      ships: SHIPS.map((s) => (frozen ? { a: 0, x: 0 } : {
        a: ramp(CROSS_ALPHA, loop(t, s.period, s.delay)) * s.lum,
        x: loop(t, s.period, s.delay) * 120 * VW,
      })),
      street: STREET_CARS.map((s) => (frozen ? { a: 0, x: 0 } : {
        a: ramp(STREAK_ALPHA, loop(t, s.period, s.delay)) * s.lum,
        x: ramp(STREAK_X, loop(t, s.period, s.delay)) * 130 * VW,
      })),
      steam: VENTS.map((v) => (frozen ? { a: 0, y: 0, s: 1 } : {
        a: ramp(STEAM_ALPHA, loop(t, v.period, v.delay)),
        y: -loop(t, v.period, v.delay) * 2.6 * REM,
        s: 0.5 + loop(t, v.period, v.delay) * 1.05,
      })),
      // The tram sits on its line rather than being deleted: the district is a
      // record, and a record has to stay legible standing still.
      tram: frozen ? { a: 1, x: 12 * VW } : {
        a: ramp(TRAM_ALPHA, loop(t, 96, 0)),
        x: (ramp(TRAM_X, loop(t, 96, 0)) * 122 - 8) * VW,
      },
      facade: frozen ? 0.9 : ramp(WIN_LIVE, loop(t, 26, 0)),
      // The rooftop beacon, in degrees, one way for ever. `face` is how much of
      // it the room can see; at rest it is parked where the DOM parks it,
      // pointing a little left of the room and fully lit.
      beam: frozen
        ? { angle: -14, face: 1 }
        : { angle: -180 + 360 * loop(t, BEAM_PERIOD, 0),
            face: ramp(BEAM_FACE, loop(t, BEAM_PERIOD, 0)) },
      klaxon: frozen ? 0.8 : 0.28 + 0.72 * swing(t, 1.1),
      // klaxon-text: the alarm tower's name plate.
      text: frozen ? 1 : 0.25 + 0.75 * swing(t, 1),
      car: frozen ? 1 : 0.72 + 0.28 * swing(t, 2.6),
      carAlarm: frozen ? 1 : 0.2 + 0.8 * swing(t, 0.9),
    };
  }

  // Per-object beats, every one of them derived from that one phase. With a
  // frozen phase each is a constant, which is the whole of reduced motion here.
  const tubeAt = (phase, delay, period) =>
    (phase.still ? 1 : ramp(period === 16 ? SIGN_HUM : HUM, loop(phase.t, period, delay)));
  const paneAt = (phase, slot, delay) =>
    (phase.still ? 0.85 : ramp(OCCUPANCY, loop(phase.t, PANE_PERIODS[slot] || 97, delay)));
  const facadeAt = (phase, drift) =>
    (phase.still ? phase.facade : ramp(WIN_LIVE, loop(phase.t, 26, drift * 1.9)));
  // CSS removes the completion and sign-cooling animations under reduced
  // motion, and their resting states are not the last keyframes: a finished
  // shaft stays fully present until the server takes it down, and a crew sign
  // stays at 0.85 until its server-owned lifetime expires, then switches off.
  function signAt(phase, age, span) {
    if (phase.still) return age < span ? 0.85 : 0;
    return ramp(SIGN_COOL, once(age, span || 1));
  }
  function shaftAt(phase, age, span, spotted) {
    if (phase.still) {
      return { root: 1, column: spotted ? 1 : 0.8, car: 1, scale: spotted ? 1.3 : 1 };
    }
    const u = once(age, span);
    return {
      root: ramp(LIGHTS_OUT, u),
      column: spotted ? 1 : 0.8,
      car: ramp(FLARE_ALPHA, u),
      scale: ramp(FLARE_SCALE, u),
    };
  }
  // Somebody walking home, and the machines that do the other half of a night
  // shift going the other way. Parked on the pavement when the room asks for
  // stillness, which is what wall.css does with a fixed translate per slot.
  function walkerAt(phase, slot, robot) {
    if (phase.still) return (9 + slot * 15) * VW;
    const u = loop(phase.t, robot ? 176 : 132, slot * 21);
    return (robot ? 108 - u * 216 : -108 + u * 216) * VW;
  }
  function vehicleAt(phase, slot, plan) {
    if (phase.still) return { a: 0, x: 0 };
    const u = loop(phase.t, plan.cycle || 48, slot * (plan.gap || 0));
    return { a: ramp(PROWL_ALPHA, u), x: (ramp(PROWL_X, u) * 124 - 10) * VW };
  }

  // --- drawing helpers ----------------------------------------------------------

  // A vertical gradient, one banded fill per pair of stops.
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
  // of these is painted exactly once into a texture, so concentric ellipses at
  // a fraction of the alpha each is the honest answer.
  function glow(g, colour, cx, cy, rx, ry, alpha, rings) {
    for (let i = rings; i >= 1; i--) {
      g.fillStyle(colour, alpha / rings);
      g.fillEllipse(cx, cy, rx * 2 * (i / rings), ry * 2 * (i / rings), 20);
    }
  }

  // --- reading the painted sky --------------------------------------------------
  // The sky is authored exactly once, in index.html, and this world reads it off
  // the live node rather than keeping a second copy: the gradients come out of
  // the <defs> and the silhouettes out of the same <path> elements the DOM world
  // paints, sampled and reduced back to their own vertices. Nothing leaves the
  // machine; it is the wall's own painting either way.

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
    // sample rather than a corner.
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

    const ratio = () => Math.min(window.devicePixelRatio || 1, 2);
    const wallSize = () => ({
      w: parent.clientWidth || window.innerWidth,
      h: parent.clientHeight || window.innerHeight,
    });
    const first = wallSize();
    measure(first.w, first.h, ratio());

    let city = null;          // the running scene, once Phaser has booted it
    let pending = null;       // the last scene handed over before it had
    let pendingSpot = '';
    let baked = 0;            // texture keys are unique for the life of the page

    class CityScene extends Phaser.Scene {
      constructor() { super('city'); }

      preload() {
        // The only thing this world loads, and it never leaves the machine:
        // one atlas of art generated for this repo, hashed in
        // wall/assets/MANIFEST.md and quantised to .creative/palette.png.
        this.load.atlas(ATLAS, 'assets/city/atlas.png', 'assets/city/atlas.json');
      }

      create() {
        // One monotonic clock, anchored to the wall clock once. `clock()` is
        // Date.now()+skew and the skew is re-measured on every snapshot, so
        // reading it per frame steps the whole city sideways every time the
        // server speaks. Read it here, and run on the loop's own time after.
        this.origin = (Number(clock()) || 0) - this.time.now / 1000;
        this.phase = phaseAt(0, { reducedMotion: true });
        this.model = null;
        this.towers = new Map();      // project -> its objects
        this.blocks = new Map();      // run id -> its objects
        this.landmark = null;
        this.ghostKey = '';
        this.walkers = [];
        this.vehicles = [];
        this.keys = [];               // saved textures, dropped on a restart

        const cam = this.cameras.main;
        cam.setZoom(PIX);
        cam.centerOn(GW / 2, GH / 2);
        cam.setRoundPixels(true);

        this.events.once('shutdown', () => {
          for (const key of this.keys) {
            if (this.textures.exists(key)) this.textures.remove(key);
          }
          this.keys.length = 0;
        });

        // Back to front, in the order wall.css stacks the same layers.
        this.skyC = this.add.container(0, 0);
        this.districtC = this.add.container(0, 0);
        this.trafficC = this.add.container(0, 0);
        this.hazeC = this.add.container(0, 0);
        this.streetC = this.add.container(0, 0);
        this.cityC = this.add.container(0, 0);
        this.nearC = this.add.container(0, 0);

        this.glyphScale = 1 / TXT;
        this.glyphCell = 13;
        this.makeGlow();
        this.paintSky();
        this.paintDawn();
        this.paintHaze();
        this.paintTraffic();
        this.paintStreet();

        city = this;
        if (pending) this.apply(pending);
        this.spot(pendingSpot);
        this.step(true);
      }

      // --- the set --------------------------------------------------------------

      // The bottom-left corner of a frame, as its own frame. Tiling a 32 px
      // panel across a 47 px building has to stop at 47, and a stamp cannot be
      // cropped — so the partial column and the partial top row get a frame of
      // their own in the same texture. Nothing is scaled and nothing bleeds.
      cut(name, offX, offY, w, h) {
        const tex = this.textures.get(ATLAS);
        if (w >= PANEL * 4 || h >= PANEL * 4) return name;
        const id = name + '#' + offX + ',' + offY + ',' + w + ',' + h;
        if (!tex.has(id)) {
          const f = tex.get(name);
          if (!f) return name;
          tex.add(id, f.sourceIndex, f.cutX + offX, f.cutY + offY, w, h);
        }
        return id;
      }

      // A glyph, in the wall's own CJK stack. It is drawn at the panel's own
      // resolution and shown back down at 1/TXT, so the four shopfront
      // characters and the dedication stay crisp when the world is scaled 3x
      // onto the office TV instead of turning into five soft blocks.
      glyph(x, y, character, size, colour) {
        const text = this.add.text(x, y, character, {
          fontFamily: CJK, fontSize: Math.max(6, Math.round(size * TXT)) + 'px',
          color: colour,
        });
        text.setOrigin(0.5, 0.5);
        text.setScale(this.glyphScale);
        return text;
      }

      // Lettering that stays crisp when the world is scaled 3x onto the TV:
      // drawn at the panel's own resolution and shown back down at 1/TXT.
      label(x, y, string, size, colour) {
        const text = this.add.text(x, y, string, {
          fontFamily: MONO, fontSize: Math.max(6, Math.round(size * TXT)) + 'px',
          color: colour, align: 'center',
        });
        text.setScale(this.glyphScale);
        return text;
      }

      // --- the painted sky ------------------------------------------------------

      paintSky() {
        const g = this.make.graphics({}, false);
        g.fillStyle(BG, 1);
        g.fillRect(0, 0, GW, GH);
        fillGradient(g, gradientOf('night'), skyX(0), skyY(0), 1600 * SKY, 900 * SKY);
        // The glow the city throws back at its own cloud ceiling.
        glow(g, 0x2a6f66, GW / 2, GH + 6 * VH, GW * 0.5, GH * 0.54, 0.34, 10);
        for (const group of document.querySelectorAll('svg.sky > g[stroke]')) {
          const colour = parseInt((group.getAttribute('stroke') || '#000000').slice(1), 16);
          const width = parseFloat(group.getAttribute('stroke-width') || '1') * SKY;
          const alpha = parseFloat(group.getAttribute('opacity') || '1');
          g.lineStyle(Math.max(0.6, width), colour, alpha);
          for (const path of group.querySelectorAll('path')) {
            g.strokePoints(samplePath(path, 6), false, false);
          }
        }
        const veil = document.querySelector('svg.sky > rect[fill="url(#hazeveil)"]');
        if (veil) {
          fillGradient(g, gradientOf('hazeveil'),
            skyX(veil.getAttribute('x')), skyY(veil.getAttribute('y')),
            Number(veil.getAttribute('width')) * SKY, Number(veil.getAttribute('height')) * SKY);
        }
        this.skyC.add(this.bake(g, 0, 0, GW, GH));
        g.destroy();

        // Last week, flattened: a height and a plot and nothing else.
        this.ghostG = this.add.graphics();
        this.skyC.add(this.ghostG);

        // The three painted planes, each on its own slow drift. They are
        // silhouette and distant window and nothing more — the near one is not
        // even that, because no pattern reaches it.
        this.planes = PLANES.map((plane) => {
          const node = document.querySelector('.sky__' + plane.key + ' path');
          const holder = this.add.container(0, 0);
          this.skyC.add(holder);
          if (!node) return holder;
          const points = samplePath(node, 2);
          const top = points.reduce((lo, p) => Math.min(lo, p.y), GH);
          const pg = this.make.graphics({}, false);
          const stops = gradientOf(plane.key);
          const body = stops.length ? stops[Math.floor(stops.length / 2)] : null;
          pg.fillStyle(body ? body.colour : STONE, body ? body.alpha : 1);
          pg.fillPoints(points.map((p) => ({ x: p.x + 24, y: p.y - top })), true, true);
          if (plane.key === 'near') {
            for (const rect of document.querySelectorAll('.sky__near rect')) {
              fillGradient(pg, gradientOf('wet'),
                skyX(rect.getAttribute('x')) + 24, skyY(rect.getAttribute('y')) - top,
                Number(rect.getAttribute('width')) * SKY,
                Number(rect.getAttribute('height')) * SKY);
            }
          } else {
            const dot = Math.max(1, Math.round(2 * SKY));
            const alpha = plane.key === 'far' ? 0.32 : 0.42;
            const first = SKY_Y + Math.floor((top - SKY_Y) / (19 * SKY)) * 19 * SKY;
            for (let y = first; y < GROUND_Y; y += 19 * SKY) {
              for (let x = SKY_X; x < GW; x += 15 * SKY) {
                if (inside(points, x + 4 * SKY, y + 5 * SKY)) {
                  pg.fillStyle(0xffc98a, 0.45 * alpha);
                  pg.fillRect(Math.round(x + 3 * SKY) + 24, Math.round(y + 4 * SKY - top), dot, dot);
                }
                if (inside(points, x + 11 * SKY, y + 13 * SKY)) {
                  pg.fillStyle(0xa8dcf0, 0.3 * alpha);
                  pg.fillRect(Math.round(x + 10 * SKY) + 24, Math.round(y + 12 * SKY - top), dot, dot);
                }
              }
            }
          }
          holder.add(this.bake(pg, -24, top, GW + 48, Math.max(1, GH - top)));
          pg.destroy();
          return holder;
        });
      }

      // The cold wash the sky picks up either side of local sunrise. Zero at
      // every other hour, which is the night this city has always been.
      paintDawn() {
        this.dawnG = this.add.graphics();
        this.skyC.add(this.dawnG);
        this.dawnG.fillGradientStyle(0x4a7aa8, 0x4a7aa8, 0x4a7aa8, 0x4a7aa8, 0, 0, 0.14, 0.14);
        this.dawnG.fillRect(0, GH * 0.38, GW, GH * 0.36);
        this.dawnG.fillGradientStyle(0x4a7aa8, 0x4a7aa8, 0x6096be, 0x6096be, 0.14, 0.14, 0.28, 0.28);
        this.dawnG.fillRect(0, GH * 0.74, GW, GH * 0.26);
        this.dawnG.setAlpha(0);
      }

      // --- the weather between the buildings ------------------------------------

      paintHaze() {
        const base = this.make.graphics({}, false);
        const hazeH = 38 * VH;
        base.fillGradientStyle(0x5aaaaa, 0x5aaaaa, 0x5aaaaa, 0x5aaaaa, 0, 0, 0.05, 0.05);
        base.fillRect(0, 0, GW, hazeH);
        base.fillGradientStyle(0x010408, 0x010408, 0x010408, 0x010408, 0, 0, 0.9, 0.9);
        base.fillRect(0, hazeH * 0.28, GW, hazeH * 0.72);
        this.hazeBase = this.bake(base, 0, GH - hazeH, GW, hazeH);
        this.hazeC.add(this.hazeBase);
        base.destroy();
        this.hazeSlabs = HAZE_SLABS.map((slab, i) => {
          const g = this.make.graphics({}, false);
          const w = (i ? 0.52 : 0.7) * GW;
          const h = (i ? 18 : 26) * VH;
          glow(g, 0x7ec4c4, w / 2, h / 2, w / 2, h / 2, 0.12, 8);
          const img = this.bake(g, -0.3 * GW, GH - (i ? 2 * VH : -6 * VH) - h, w, h);
          g.destroy();
          img.setAlpha(i ? 0.7 : 1);
          this.hazeC.add(img);
          return img;
        });
      }

      paintTraffic() {
        this.ships = SHIPS.map((ship) => {
          const g = this.make.graphics({}, false);
          const w = Math.round(1.1 * REM);
          const h = 2;
          glow(g, 0xaad8ff, 12 + w / 2, 8, w, h * 4, 0.7, 5);
          g.fillStyle(0xff8c64, 0.3);
          g.fillRect(12 - 1.3 * REM, 8 - h / 2, w, h);
          g.fillStyle(0xd6e9ff, 1);
          g.fillRect(12, 8 - h / 2, w, h);
          g.fillStyle(0xff6a5b, 1);
          g.fillCircle(12 + w + 3, 8, 1.5);
          const img = this.bake(g, 0, 0, w + 32, 16);
          g.destroy();
          img.setPosition(-0.1 * GW, ship.y * GH);
          img.setScale(ship.z);
          img.setAlpha(0);
          this.trafficC.add(img);
          return img;
        });
      }

      // --- the street ------------------------------------------------------------
      // The ground floor of the whole city, baked once: roadway, kerb, lamps,
      // tram stop, and the pools of light they throw. Nothing here is redrawn
      // per frame — the only things that move on this plane are the cars, the
      // walkers, the tram and the steam.

      paintStreet() {
        const y = Math.round(GROUND_Y);
        const deep = Math.max(1, GH - y);
        const kerb = Math.min(GROUND_H, deep);
        // A panel of headroom over the kerb, the same as a building's, because
        // a lamp stands on the pavement and its head is the half of it that
        // matters: clipped at the ground line it is a post with no light in it.
        const stone = this.blank(GW, deep + PANEL);
        // The roadway is a value, not a surface: dark tarmac with the lamp
        // pools laid on it. Only the pavement the city stands on is tiled.
        stone.fill(0x060b12, 1, 0, PANEL + kerb, GW, deep - kerb);
        stone.fill(0x0b141c, 1, 0, PANEL + deep - 3, GW, 3);
        for (let x = 0; x < GW; x += GROUND_W) {
          const w = Math.min(GROUND_W, GW - x);
          stone.stamp(ATLAS, this.cut('city-tile-kerb', 0, 0, w, kerb), x, PANEL, STAMP0);
        }
        // The lamps down the near kerb, standing over it.
        const lampGap = Math.round(11 * VW);
        this.lamps = [];
        for (let x = Math.round(4 * VW); x < GW; x += lampGap) {
          stone.stamp(ATLAS, 'city-prop-lamp', x - 16, PANEL - 22, STAMP0);
          this.lamps.push(x);
        }
        // The kerb line: the one hard horizontal the whole picture hangs on.
        stone.fill(EDGE, 0.5, 0, PANEL, GW, 1);
        stone.fill(EDGE, 0.12, 0, PANEL + 1, GW, 2);
        stone.render();
        this.streetC.add(this.add.image(0, y - PANEL, stone.key).setOrigin(0, 0));

        // A big week earns the same wide arcade the DOM world shows at the far
        // kerb. It is one subdued block with uneven open bays, not another row
        // of decorative signs; the plan's `mall` bit is the only thing that may
        // make it appear.
        const mallW = Math.round(21 * VW);
        const mallH = Math.max(TILE, Math.round(4 * VH));
        const mallTexture = this.blank(mallW, mallH);
        const shopH = Math.min(GROUND_H, mallH);
        for (let x = 0, bay = 0; x < mallW; x += GROUND_W, bay++) {
          const w = Math.min(GROUND_W, mallW - x);
          mallTexture.stamp(ATLAS, this.cut(GROUND_FRAME, 0, GROUND_H - shopH, w, shopH),
                            x, mallH - shopH, bay % 3 === 1 ? STAMP_DARK : STAMP0);
        }
        for (let y = mallH - shopH; y > 0; y -= PANEL) {
          const h = Math.min(PANEL, y);
          for (let x = 0; x < mallW; x += PANEL) {
            const w = Math.min(PANEL, mallW - x);
            mallTexture.stamp(ATLAS, this.cut(SKIN.slab, 0, PANEL - h, w, h),
                              x, y - h, STAMP_DARK);
          }
        }
        mallTexture.fill(EDGE, 0.46, 0, 0, mallW, 2);
        mallTexture.render();
        this.mall = this.add.image(
          GW - Math.round(3 * VW) - mallW,
          Math.round(GH - 7.6 * VH) - mallH,
          mallTexture.key).setOrigin(0, 0);
        this.mall.setTint(VEIL_TINT[1]);
        this.mall.setAlpha(0.68);
        this.mall.setVisible(false);
        this.streetC.add(this.mall);

        // And the light those lamps throw. Pools on the wet pavement and the
        // bulb inside each hood: the one thing on this wall that reads from
        // three metres before anything else does.
        for (const x of this.lamps) {
          this.streetC.add(this.light(x, y + 26, 104, 40, LAMP, 0.5));
          this.streetC.add(this.light(x, y - 12, 26, 26, LAMP, 0.85));
        }

        // The tram, and the rail it sits on whether or not it is running.
        this.rail = this.add.image(0, y + 16, '__WHITE').setOrigin(0, 0);
        this.rail.setDisplaySize(GW, 1).setTint(0x8ccdc8).setAlpha(0);
        this.streetC.add(this.rail);
        this.tram = this.add.image(0, y + 16, ATLAS, 'city-tram').setOrigin(0, 1);
        this.tram.setAlpha(0);
        this.streetC.add(this.tram);
        this.tramLight = this.light(36, y + 8, 84, 22, WIN_B, 0);
        this.streetC.add(this.tramLight);

        // The steam off three vents, the only soft thing at street level.
        this.vents = VENTS.map((vent) => {
          const img = this.light(vent.x * GW, y + 6, 26, 34, WIN_B, 0);
          img.setOrigin(0.5, 1);
          this.streetC.add(img);
          return img;
        });

        this.crowdC = this.add.container(0, 0);
        this.roadC = this.add.container(0, 0);
        this.streetC.add(this.crowdC);
        this.nearC.add(this.roadC);
        this.streetC.setVisible(false);

        // The near lane: two headlight passes in front of the whole city, both
        // rarer than the slowest thing in the air.
        this.streetCars = STREET_CARS.map((car) => {
          const g = this.make.graphics({}, false);
          const head = car.warm ? 0xfff5e2 : 0xcfe8ff;
          glow(g, head, car.warm ? 88 : 8, 8, 48, 7, 0.6, 6);
          g.fillGradientStyle(head, head, head, head, 0, 0.8, 0, 0.8);
          g.fillRect(8, 7, 80, 2);
          const img = this.bake(g, 0, GH - 8 * VH, 96, 16);
          g.destroy();
          img.setBlendMode(Phaser.BlendModes.ADD);
          img.setAlpha(0);
          this.nearC.add(img);
          return img;
        });
      }

      // Somebody out at one in the morning. A sprite, a crew-warm rim, and the
      // pavement's own light under them.
      makeWalker(slot) {
        const robot = slot % 3 === 2;
        const holder = this.add.container(0, 0);
        this.crowdC.add(holder);
        const body = this.add.image(0, 0, ATLAS, WALKERS[0]);
        body.setOrigin(0.5, 1);
        body.setTint(robot ? 0x9fb6c0 : 0xc9d6d8);
        body.setFlipX(robot);
        holder.add(body);
        holder.setPosition(0, Math.round(GROUND_Y) + 24 + (slot % 3) * 3);
        holder.setAlpha(0.94);
        return { g: holder, body, robot, slot, frame: -1 };
      }

      // A car, now and then. The wait is the point: on a quiet week this is
      // nothing for forty seconds and then somebody drives home.
      makeVehicle(slot) {
        const holder = this.add.container(0, 0);
        this.roadC.add(holder);
        const west = slot % 2 === 1;
        const body = this.add.image(0, 0, ATLAS, 'city-car').setOrigin(0.5, 1);
        body.setFlipX(west);
        holder.add(body);
        // Headlights, which is what a car is on this wall: the body is the
        // sprite, the light is the tint, and the tint is which way it is going.
        holder.add(this.light(west ? -26 : 26, -6, 52, 16,
                              west ? 0xcfe8ff : DINER, 0.7));
        holder.setPosition(0, GH - 4 - (west ? 8 : 0));
        holder.setAlpha(0);
        return { g: holder, slot };
      }

      // --- last week, flattened -------------------------------------------------

      paintGhost(ghosts) {
        const key = ghosts.map((g) => g.x + ':' + g.storeys).join(',');
        if (key === this.ghostKey) return;
        this.ghostKey = key;
        this.ghostG.clear();
        this.ghostG.fillStyle(0x7fb4c0, 1);
        for (const ghost of ghosts) {
          this.ghostG.fillRect(Math.round(skyX(ghost.x * 1600 - 20)),
                               Math.round(skyY(819 - ghost.height)),
                               Math.round(40 * SKY), Math.round(ghost.height * SKY));
        }
        this.ghostG.setAlpha(0.14);
      }

      // --- baking ----------------------------------------------------------------

      // A blank texture on the GPU, of this world's own. Phaser 4 batches every
      // draw into a DynamicTexture and only commits it on render(), so that
      // call is not optional decoration: without it a stamp is a no-op that
      // throws nothing and shows nothing.
      blank(w, h) {
        const key = 'bake#' + (baked++);
        this.keys.push(key);
        return this.textures.addDynamicTexture(key, Math.max(1, Math.ceil(w)),
                                               Math.max(1, Math.ceil(h)));
      }

      // A Graphics, once, into a texture — and then never again. Everything
      // static in this world goes through here, which is what keeps the frame
      // loop free of geometry: after this returns there is a texture on the GPU
      // and no command list left to replay.
      bake(g, x, y, w, h) {
        const dt = this.blank(w, h);
        dt.draw(g, 0, 0);
        dt.render();
        return this.add.image(x, y, dt.key).setOrigin(0, 0);
      }

      // One soft round falloff, drawn once, white. Every point light in this
      // city is that texture tinted, stretched and blended additively — one
      // texture and one batch for the whole street, and a lamp that can go red
      // under an alarm without a pixel being redrawn.
      makeGlow() {
        const g = this.make.graphics({}, false);
        glow(g, 0xffffff, 32, 32, 31, 31, 1, 16);
        const dt = this.blank(64, 64);
        dt.draw(g, 0, 0);
        dt.render();
        g.destroy();
        this.glowTex = dt.key;
      }

      light(x, y, w, h, colour, alpha) {
        const img = this.add.image(x, y, this.glowTex).setOrigin(0.5, 0.5);
        img.setDisplaySize(w, h);
        img.setTint(colour);
        img.setAlpha(alpha);
        img.setBlendMode(Phaser.BlendModes.ADD);
        return img;
      }

      // A building, stamped out of the set: masses from the bottom up, the
      // ground floor the street actually reads, a lit edge along every roofline
      // and whatever that typology stands on its roof.
      stamp(dt, box, masses, skin, open, rnd, litShare, roofProps) {
        // The texture carries one panel of headroom over the roofline, because
        // what stands on a roof is what the room reads the building by from the
        // sofa and a mast clipped at the parapet is a flat top.
        const bottom = box.h + PANEL;
        for (const mass of masses) {
          const mx = Math.round(mass.x * box.w);
          const mw = Math.max(PANEL / 2, Math.round(mass.w * box.w));
          const my = Math.round(mass.top * box.h) + PANEL;
          if (mx >= box.w) continue;
          const w = Math.min(mw, box.w - mx);
          let floor = bottom;
          const gh = Math.min(GROUND_H, bottom - my);
          if (gh > 0) {
            for (let gx = mx; gx < mx + w; gx += GROUND_W) {
              const gw = Math.min(GROUND_W, mx + w - gx);
              dt.stamp(ATLAS, this.cut(GROUND_FRAME, 0, GROUND_H - gh, gw, gh),
                       gx, bottom - gh, open ? STAMP0 : STAMP_DARK);
            }
            floor = bottom - gh;
          }
          // The wall above it, tiled from the floor UP so the storey bands land
          // on the ground floor and the part-panel is the one under the roof.
          let cursor = floor;
          while (cursor > my) {
            const ph = Math.min(PANEL, cursor - my);
            for (let px = mx; px < mx + w; px += PANEL) {
              const pw = Math.min(PANEL, mx + w - px);
              dt.stamp(ATLAS, this.cut(skin, 0, PANEL - ph, pw, ph),
                       px, cursor - ph, rnd() < litShare ? STAMP0 : STAMP_DARK);
            }
            cursor -= ph;
          }
          // The roofline and the shaded return: what turns a wall into a mass.
          // Both are two pixels rather than one on purpose — a one-pixel rule is
          // gone by the time the wall has been downscaled to the size it is on
          // the far side of the room, which is the only size that counts.
          dt.fill(EDGE, 0.55, mx, my, w, 2);
          dt.fill(BG, 0.55, mx + Math.max(0, w - 2), my + 2, 2, bottom - my - 2);
          if (roofProps && roofProps.length && w >= 24) {
            const prop = roofProps[Math.floor(rnd() * roofProps.length)];
            const at = mx + Math.round((w - PANEL) * (0.2 + 0.6 * rnd()));
            dt.stamp(ATLAS, prop, Math.max(mx, Math.min(at, mx + w - PANEL)),
                     my - PANEL, STAMP0);
          }
        }
      }

      // --- the week's district --------------------------------------------------

      makeBlock(block) {
        const box = blockBox(block);
        const root = this.add.container(0, 0);
        this.districtC.add(root);
        const rnd = Model ? Model.seededRandom(Model.seedOf(block.id + '·skin')) : (() => 0.5);
        const form = block.shape ? block.shape.form : null;
        const skin = SKIN[(form && FORM_SKIN[form]) || KIND_SKIN[block.kind] || 'slab'];
        const shop = block.shop;
        // A shop is open or it is shut, and that is one draw off the run id —
        // the same draw the DOM world lights its bays from. Shut is the same
        // strip with its light off, which is a tint.
        const open = !shop || shop.neon || shop.bay % 3 !== 0;
        const dt = this.blank(box.w, box.h + PANEL);
        this.stamp(dt, box, massesOf(block), skin, open, rnd,
                   0.3 + box.depth * 0.1, ROOF[form] || ['city-prop-ac']);
        dt.render();
        const body = this.add.image(box.x, box.y - PANEL, dt.key).setOrigin(0, 0);
        // The veil is the renderer's, never a hazier PNG: one multiply tint per
        // depth band, so the same wall is a near building in front and a far
        // mass behind.
        body.setTint(VEIL_TINT[box.depth] || VEIL_TINT[1]);
        root.add(body);

        const parts = { root, box, block, body, shop: {} };

        // The ground floor after dark: the shop's own light on the pavement in
        // front of it, and the warm bay behind the glass that throws it.
        const tint = shop ? SHOP[shop.shop] : DINER;
        if (open) {
          const cx = box.x + box.w / 2;
          const foot = box.y + box.h;
          root.add(this.light(cx, foot + 3, box.w * 1.5, 26, tint,
                              box.depth >= 1 ? 0.34 : 0.2));
          root.add(this.light(cx, foot - GROUND_H * 0.5, box.w * 1.1, GROUND_H,
                              WIN_A, box.depth >= 1 ? 0.26 : 0.16));
        }
        if (open && box.w >= 40) {
          const awning = this.add.image(box.x + Math.round(box.w / 2), box.y + box.h - 18,
                                        ATLAS, 'city-prop-awning');
          awning.setOrigin(0.5, 0.5);
          awning.setTint(0xd9c6a8);
          root.add(awning);
        }

        // Occupancy: a fixed handful of windows keeping their own hours, each on
        // its own loop length and from its own seeded phase.
        parts.panes = (shop ? shop.windows : []).map((win, i) => {
          const w = Math.max(2, Math.round(box.w * 0.08));
          const img = this.add.image(
            box.x + Math.round(box.w * (0.1 + win.col * 0.12)),
            box.y + Math.round((box.h - GROUND_H) * (0.65 - win.row * 0.12)),
            '__WHITE').setOrigin(0, 0);
          img.setDisplaySize(w, Math.max(2, Math.round(w * 0.8)));
          img.setTint(i === 2 ? WIN_C : WIN_A);
          img.setBlendMode(Phaser.BlendModes.ADD);
          img.setAlpha(0);
          root.add(img);
          return { g: img, phase: win.phase };
        });

        // The shop's own sign: the tube, and the character that says in a glyph
        // what the tube says in light. Nothing else in this city is lettered.
        if (shop) {
          const size = this.glyphCell * this.glyphScale;
          const px = shop.side ? box.x + box.w - size : box.x;
          const py = box.y + box.h - GROUND_H - size;
          // The plate the tube is bolted to. A dark rectangle, because that is
          // all it is: what makes it read as a sign at this size is the glyph
          // and the light behind it, not a frame the generator would have put
          // lettering on.
          const plate = this.add.image(px, py, '__WHITE').setOrigin(0, 0);
          plate.setDisplaySize(size, size);
          plate.setTint(0x02060a);
          root.add(plate);
          root.add(this.light(px + size / 2, py + size / 2, size * 2.6, size * 2.6,
                              tint, 0.42));
          const glyph = this.glyph(px + size / 2, py + size / 2, shop.glyph,
                                   this.glyphCell - 1, hex(tint));
          root.add(glyph);
          parts.shop.glyph = glyph;
          parts.shop.plate = plate;
          parts.shop.glyphPhase = shop.hang;
          // One building in three carries the extra tube over its frontage.
          if (shop.neon) {
            parts.shop.neon = this.light(box.x + Math.round(box.w * (0.2 + shop.bay * 0.12)),
                                         box.y + box.h - GROUND_H - 6,
                                         Math.max(18, box.w * 0.5), 16, tint, 0.55);
            parts.shop.neonPhase = shop.flicker;
            root.add(parts.shop.neon);
          }
        }

        // Attribution, and the whole of it: one small tube on the shoulder in
        // the dispatcher's own crew tint, cooling to neutral within --sign-life.
        parts.sign = this.add.image(box.x + box.w - 3, box.y + Math.round(box.h * 0.16),
                                    '__WHITE').setOrigin(0, 0);
        parts.sign.setDisplaySize(2, Math.max(4, Math.round(0.76 * REM)));
        parts.sign.setTint(rgb(block.crew));
        parts.sign.setBlendMode(Phaser.BlendModes.ADD);
        parts.sign.setAlpha(0);
        root.add(parts.sign);
        return parts;
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
          const size = Math.round(this.glyphCell * this.glyphScale * 1.4);
          const px = box.x + box.w - size;
          const py = box.y + Math.round(box.h * 0.2);
          const plate = this.add.image(px, py, ATLAS, 'city-prop-signtall').setOrigin(0, 0);
          plate.setDisplaySize(size, size * 3);
          plate.setTint(0x4a5a60);
          this.landmark.root.add(plate);
          const glyph = this.glyph(px + size / 2, py + size * 1.5, ran.glyph,
                                   this.glyphCell + 4, hex(DINER));
          this.landmark.root.add(glyph);
          this.landmark.lit = this.light(px + size / 2, py + size * 1.5,
                                        size * 3.4, size * 5, DINER, 0.5);
          this.landmark.root.add(this.landmark.lit);
          this.landmark.dedication = glyph;
          this.landmark.root.setDepth(0);
        }
        const standing = new Set(model.blocks.map((b) => b.id));
        for (const [id, parts] of this.blocks) {
          // Only the week rolling over takes a building down, and then it takes
          // the whole district with it.
          if (!standing.has(id)) {
            const texture = parts.body.texture.key;
            parts.root.destroy();
            if (this.textures.exists(texture)) this.textures.remove(texture);
            this.blocks.delete(id);
          }
        }
        let landed = false;
        for (const block of model.blocks) {
          if (this.blocks.has(block.id)) continue;
          const parts = this.makeBlock(block);
          parts.root.setDepth(block.depth + 1);
          this.blocks.set(block.id, parts);
          landed = true;
        }
        if (landed) this.districtC.sort('depth');
      }

      // --- one project: a tower -------------------------------------------------

      makeTower() {
        const root = this.add.container(0, 0);
        this.cityC.add(root);
        const parts = { root, shaftEls: new Map(), key: '' };
        parts.mirror = null;
        parts.body = null;
        parts.bloom = null;
        // Four of this tower's lights are the shared glow, tinted: the wet
        // tarmac it stands in, the patch its beacon puts on the cloud, and the
        // two greens a ship lights. A tint is state; a PNG never is.
        parts.pool = this.light(0, 0, 2, 2, 0x8cc4ce, 0);
        parts.column = this.light(0, 0, 2, 2, 0xff4050, 0);
        parts.ceiling = this.light(0, 0, 2, 2, 0xff6068, 0);
        parts.halo = this.light(0, 0, 2, 2, DONE, 0);
        parts.beacon = this.light(0, 0, 2, 2, DONE, 0);
        parts.spot = this.add.graphics();
        parts.sweep = this.add.graphics();
        parts.wash = this.add.graphics();
        parts.cascade = this.add.graphics();
        parts.basePlate = this.add.graphics();
        for (const key of ['pool', 'spot']) root.add(parts[key]);
        parts.shafts = this.add.container(0, 0);
        root.add(parts.shafts);
        for (const key of ['column', 'sweep', 'ceiling', 'wash', 'cascade', 'halo',
                           'beacon', 'basePlate']) root.add(parts[key]);
        for (const key of ['spot', 'sweep', 'wash']) {
          parts[key].setBlendMode(Phaser.BlendModes.ADD);
        }
        // Neon signage: the project's name hung off its tower's shoulder,
        // vertical, in that project's own neon.
        parts.sign = this.label(0, 0, '', 8, '#7fd4ec');
        parts.signPlate = this.add.graphics();
        parts.label = this.label(0, 0, '', 8, '#96cdbe');
        parts.labelLit = this.label(0, 0, '', 8, '#e4fff3');
        root.add(parts.signPlate);
        root.add(parts.sign);
        root.add(parts.label);
        root.add(parts.labelLit);
        parts.sign.setOrigin(0, 0);
        parts.label.setOrigin(0.5, 0);
        parts.labelLit.setOrigin(0.5, 0);
        parts.labelLit.setVisible(false);
        return parts;
      }

      // A tower's geometry is a fact about the snapshot, so it is stamped when
      // one of those facts changes and left entirely alone in between.
      paintTower(T, tower, box, floors) {
        const h = Math.round(CITY_H * tower.heightPct / 100);
        const top = Math.round(GROUND_Y) - h;
        const shape = tower.shape % TOWER_MASSES.length;
        const masses = TOWER_MASSES[shape];
        T.mass = { x: box.x, y: top, w: box.w, h };
        T.ladder = { x: box.x + Math.round(box.w * 0.16), w: Math.round(box.w * 0.68),
                     y: top + Math.round(h * 0.22), h: Math.round(h * 0.62) };
        const key = [shape, tower.crown, h, box.x, box.w, floors,
                     tower.alarm ? 1 : 0, tower.live].join('|');
        if (key !== T.key) {
          T.key = key;
          for (const g of ['spot', 'sweep', 'wash', 'basePlate']) T[g].clear();
          if (T.bloom) T.bloom.destroy();
          if (T.mirror) T.mirror.destroy();
          if (T.body) T.body.destroy();
          if (T.texture && this.textures.exists(T.texture)) {
            this.textures.remove(T.texture);
          }
          const rnd = Model ? Model.seededRandom(Model.seedOf(tower.project + '·skin'))
            : (() => 0.5);
          // A busy tower is a lit tower: the share of panels with somebody
          // still in them rides the work standing in the building.
          const lit = Math.min(0.72, 0.3 + tower.runIds.length * 0.07);
          const dt = this.blank(box.w, h + PANEL);
          this.stamp(dt, { x: box.x, y: top, w: box.w, h }, masses,
                     SKIN[TOWER_SKIN[shape]], true, rnd, lit,
                     [CROWN[tower.crown % CROWN.length]]);
          dt.render();
          T.texture = dt.key;
          T.body = this.add.image(box.x, top - PANEL, T.texture).setOrigin(0, 0);
          // The windows breathing: the tower's own lit pixels added back over
          // itself, so the glass glows and the stone does not move.
          T.bloom = this.add.image(box.x, top - PANEL, T.texture).setOrigin(0, 0);
          T.bloom.setBlendMode(Phaser.BlendModes.ADD);
          T.bloom.setAlpha(0.14);
          // Wet tarmac: the same building upside down under its own feet, and
          // the only reflection in this city that is a whole building.
          T.mirror = this.add.image(box.x, Math.round(GROUND_Y), T.texture).setOrigin(0, 0);
          T.mirror.setFlipY(true);
          T.mirror.setScale(1, 0.3);
          T.mirror.setAlpha(0.2);
          T.mirror.setTint(0x5f8f9c);
          T.root.addAt(T.body, 1);
          T.root.addAt(T.bloom, 2);
          T.root.addAt(T.mirror, 0);

          // Every tower stands in a little of its own light, and it turns red
          // under an alarm like everything else on that building.
          T.pool.setPosition(box.x + box.w / 2, Math.round(GROUND_Y) + 8);
          T.pool.setDisplaySize(box.w * 1.7, 34);
          T.pool.setTint(tower.alarm ? ALARM : 0x8cc4ce);
          T.pool.setAlpha(tower.alarm ? 0.42 : 0.3);

          // Non-alarm towers carry no hidden beam command buffer. The alarm
          // bit is part of the geometry key, so becoming one paints it here.
          if (tower.alarm) this.paintBeam(T, box, top, h);
          this.paintSpot(T, box, top, h);
          T.halo.setPosition(box.x + box.w / 2, top);
          T.halo.setDisplaySize(8 * REM, 8 * REM);
          T.haloBase = T.halo.scaleX;
          T.beacon.setPosition(box.x + box.w / 2, top);
          T.beacon.setDisplaySize(2.6 * REM, 2.6 * REM);
          T.beaconBase = T.beacon.scaleX;
          T.sign.setPosition(box.x + box.w + 2, top + Math.round(h * 0.1));
          T.label.setPosition(box.x + box.w / 2, Math.round(GROUND_Y) + 3);
          T.labelLit.setPosition(box.x + box.w / 2, Math.round(GROUND_Y) + 3);
          // A tower asking for a human says so at street level too: the name
          // plate goes solid red with the name in white on it, which is the
          // loudest sentence this wall has.
          if (tower.alarm) {
            T.basePlate.fillStyle(ALARM, 1);
            T.basePlate.fillRect(box.x - 4, Math.round(GROUND_Y) + 1, box.w + 8, 11);
          }
        }
        T.basePlate.setVisible(tower.alarm);
        const stacked = tower.label.split('').join('\n');
        if (T.sign.text !== stacked) {
          T.sign.setText(stacked);
          T.label.setText(tower.label);
          T.labelLit.setText(tower.label);
        }
        const signColour = tower.alarm ? hex(ALARM) : tower.sign;
        if (T.signColour !== signColour || T.signKey !== key) {
          T.signColour = signColour;
          T.signKey = key;
          T.sign.setColor(signColour);
          T.signPlate.clear();
          const pw = T.sign.displayWidth + 4;
          const ph = T.sign.displayHeight + 4;
          T.signPlate.fillStyle(0x02060a, 0.72);
          T.signPlate.fillRect(T.sign.x - 2, T.sign.y - 2, pw, ph);
          T.signPlate.lineStyle(1, rgb(signColour), 0.5);
          T.signPlate.strokeRect(T.sign.x - 2, T.sign.y - 2, pw, ph);
        }
        T.sweep.setVisible(tower.alarm);
        T.column.setVisible(tower.alarm);
        T.ceiling.setVisible(tower.alarm);
        T.wash.setVisible(tower.alarm);
        T.tower = tower;

        const standing = new Set(tower.shafts.map((s) => s.id));
        for (const [id, S] of T.shaftEls) {
          if (!standing.has(id)) { S.root.destroy(); T.shaftEls.delete(id); }
        }
        const wide = Math.max(6, Math.floor(T.ladder.w / Math.max(1, tower.shafts.length)));
        tower.shafts.forEach((run, i) => {
          let S = T.shaftEls.get(run.id);
          if (!S) {
            S = { root: this.add.container(0, 0), col: this.add.graphics(),
                  halo: this.light(0, 0, 2, 2, 0xe2f8ff, 0.55),
                  car: this.add.graphics(), key: '' };
            S.col.setBlendMode(Phaser.BlendModes.ADD);
            S.car.setBlendMode(Phaser.BlendModes.ADD);
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

      // The rooftop beacon: a lamp on the roof, the wedge it throws, the red it
      // washes down its own building and the patch it puts on the cloud. Drawn
      // once, pointing straight up; the frame loop only ever turns it.
      paintBeam(T, box, top, h) {
        const g = T.sweep;
        const reach = 1.15 * GH;
        const bands = 20;
        for (const [spread, alpha] of [[0.085, 0.045], [0.045, 0.07], [0.018, 0.15]]) {
          for (let i = 0; i < bands; i++) {
            const u0 = i / bands;
            const u1 = (i + 1) / bands;
            const fade = Math.max(0, 1 - Math.max(0, (u0 - 0.08) / 0.82));
            if (fade <= 0) continue;
            g.fillStyle(0xff5a5a, alpha * fade);
            g.fillPoints([
              { x: -reach * u0 * spread, y: -reach * u0 },
              { x: -reach * u1 * spread, y: -reach * u1 },
              { x: reach * u1 * spread, y: -reach * u1 },
              { x: reach * u0 * spread, y: -reach * u0 },
            ], true, true);
          }
        }
        glow(g, ALARM, 0, 0, 2 * REM, 2 * REM, 0.6, 6);
        g.fillStyle(0xffffff, 1);
        g.fillCircle(0, 0, 3);
        g.setPosition(box.x + box.w / 2, top + 4);
        // The column the room actually reads the alarm by: a shaft of red
        // standing straight up off the roof, lit whichever way the lamp happens
        // to be pointing. The wedge above turns; this does not go out.
        T.column.setPosition(box.x + box.w / 2, top - 21 * VH);
        T.column.setDisplaySize(Math.max(18, box.w * 0.34), 46 * VH);
        T.ceilingX = box.x + box.w / 2;
        T.ceiling.setPosition(T.ceilingX, top - 10 * VH);
        T.ceiling.setDisplaySize(44 * VH, 20 * VH);
        T.ceiling.setAlpha(0.34);
        // The klaxon wash: 4rem of red hugging the inside of the mass, which is
        // what makes an alarm tower unmistakable from the far side of a room.
        const depth = Math.max(4, Math.min(3 * REM, box.w * 0.5));
        T.wash.fillStyle(0xbe0014, 0.2);
        T.wash.fillRect(box.x, top, box.w, h);
        for (let k = 0; k < 5; k++) {
          const side = depth * (1 - k / 5);
          T.wash.fillStyle(0xbe0014, 0.09);
          T.wash.fillRect(box.x, top, side, h);
          T.wash.fillRect(box.x + box.w - side, top, side, h);
          T.wash.fillRect(box.x, top, box.w, side);
          T.wash.fillRect(box.x, Math.round(GROUND_Y) - side, box.w, side);
        }
        glow(T.wash, ALARM, box.x + box.w / 2, top + h / 2,
             box.w / 2 + 2 * REM, h / 2 + 2 * REM, 0.18, 5);
      }

      // The carousel beam, tower half: out of the low cloud onto the building
      // the brief plate is talking about. A beam has no edges — wide at the
      // pavement, narrow overhead, brightest where it lands, gone before the
      // cloud.
      paintSpot(T, box, top, h) {
        const cx = box.x + box.w / 2;
        const foot = Math.round(GROUND_Y) - h * 0.1;
        const rows = 24;
        const stops = [[0, 0.62], [0.22, 0.24], [0.52, 0.08], [0.76, 0.02], [0.92, 0], [1, 0]];
        for (let i = 0; i < rows; i++) {
          const u = i / rows;
          const y = foot - u * foot;
          const half = box.w * (0.46 - 0.315 * u);
          const a = ramp(stops, u);
          if (a <= 0) continue;
          for (const inset of [1, 0.55]) {
            T.spot.fillStyle(0xdef8ff, a * 0.15);
            T.spot.fillRect(cx - half * inset, y - foot / rows,
                            half * 2 * inset, foot / rows + 0.5);
          }
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
                     box.x, box.w, box.h].join('|');
        if (key !== S.key) {
          S.key = key;
          S.col.clear();
          S.car.clear();
          const lit = box.h * Math.max(0, Math.min(1, run.level));
          const carY = Math.round(box.y + box.h - lit);
          // The column of the building this run occupies, lit up to the car —
          // real storeys at the tower's own pitch, not a bar that stretches.
          S.col.fillStyle(tint, 0.14);
          for (let y = box.y + box.h - 4; y > box.y + box.h - lit; y -= 8) {
            S.col.fillRect(box.x, Math.round(Math.max(box.y, y)), box.w, 3);
          }
          S.col.fillStyle(tint, 0.3);
          S.col.fillRect(box.x + Math.round(box.w / 2) - 1, box.y, 2, box.h);
          // The floor the car is standing on, lit right across the shaft: the
          // line that carries "which stage" to the far side of the room.
          const carW = run.state === 'alarm' ? 12 : 14;
          const carH = 8;
          S.car.fillStyle(tint, 0.7);
          S.car.fillRect(-box.w / 2 - 8, -1, box.w + 16, 2);
          glow(S.car, rgb(run.crew), 0, carH * 0.7, 6, 3, 0.9, 5);
          S.car.fillStyle(tint, 1);
          S.car.fillRect(-carW / 2, -carH / 2, carW, carH);
          S.car.fillStyle(0xf2fbff, 0.5);
          S.car.fillRect(-carW / 2, -carH / 2, carW, 2);
          S.car.setPosition(box.x + box.w / 2, carY);
          S.halo.setDisplaySize(5.4 * REM, 5.4 * REM);
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
        const boxes = towerLayout(model.towers);
        const standing = new Set(model.towers.map((t) => t.project));
        for (const [project, T] of this.towers) {
          if (!standing.has(project)) {
            if (T.texture && this.textures.exists(T.texture)) this.textures.remove(T.texture);
            T.root.destroy();
            this.towers.delete(project);
          }
        }
        model.towers.forEach((tower, i) => {
          let T = this.towers.get(tower.project);
          if (!T) { T = this.makeTower(); this.towers.set(tower.project, T); }
          this.paintTower(T, tower, boxes[i], model.floors);
        });
        // Nightlife never competes with work: the instant anything is climbing,
        // the whole ground floor drops a stop and the skyline keeps the eye.
        this.streetC.setVisible(model.blocks.length > 0);
        this.streetC.setAlpha(model.quiet ? 1 : 0.62);
        this.districtC.setAlpha(model.quiet ? 1 : 0.88);
        const plan = model.street;
        while (this.walkers.length > plan.walkers) this.walkers.pop().g.destroy();
        while (this.walkers.length < plan.walkers) {
          this.walkers.push(this.makeWalker(this.walkers.length));
        }
        while (this.vehicles.length > plan.vehicles) this.vehicles.pop().g.destroy();
        while (this.vehicles.length < plan.vehicles) {
          this.vehicles.push(this.makeVehicle(this.vehicles.length));
        }
        this.rail.setData('on', plan.tram);
        this.tram.setData('on', plan.tram);
        this.mall.setVisible(plan.mall);
        this.spot(pendingSpot);
        this.step(true);
      }

      // The plate and the skyline tell the same story twice, so they are lit
      // together: the featured run's car gets the searchbeam and its building
      // gets named in light.
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
          T.root.setAlpha(lit && !keep ? 0.55 : 1);
        }
      }

      // --- the frame ------------------------------------------------------------

      update() { this.step(false); }

      // One frame. Nothing here draws: it reads the clock once, asks phaseAt()
      // where everything is, and moves what is already on the GPU. Under
      // reduced motion the phase never changes, so the first settled frame is
      // the last and no timer advances any state at all.
      step(force) {
        const frozen = still.matches;
        if (frozen && !force && this.phase.still) return;
        // Monotonic, and anchored to the wall clock once at boot. A snapshot
        // arriving never moves it, so nothing on the wall ever jumps.
        const at = this.origin + this.time.now / 1000;
        const phase = phaseAt(at, { reducedMotion: frozen });
        this.phase = phase;
        const model = this.model;

        this.planes.forEach((plane, i) => plane.setX(phase.planes[i]));
        this.ghostG.setX(phase.ghost);
        this.hazeSlabs.forEach((slab, i) => slab.setX(-0.3 * GW + phase.air[i]));
        this.ships.forEach((ship, i) => {
          ship.setAlpha(phase.ships[i].a);
          ship.setX(-0.1 * GW + (SHIPS[i].back ? 120 * VW - phase.ships[i].x : phase.ships[i].x));
        });
        this.streetCars.forEach((car, i) => {
          car.setAlpha(phase.street[i].a);
          car.setX(-0.15 * GW
            + (STREET_CARS[i].back ? 130 * VW - phase.street[i].x : phase.street[i].x));
        });
        this.vents.forEach((vent, i) => {
          vent.setAlpha(phase.steam[i].a * 0.8);
          vent.setY(Math.round(GROUND_Y) + 6 + phase.steam[i].y);
          vent.setScale(phase.steam[i].s);
        });
        const tramOn = this.tram.getData('on');
        this.rail.setAlpha(tramOn ? 0.5 : 0);
        this.tram.setAlpha(tramOn ? phase.tram.a : 0);
        this.tram.setX(phase.tram.x);
        this.tramLight.setAlpha(tramOn ? phase.tram.a * 0.7 : 0);
        this.tramLight.setX(phase.tram.x + 36);
        for (const walker of this.walkers) {
          walker.g.setX(walkerAt(phase, walker.slot, walker.robot));
          // Two poses alternating on the same clock as everything else, and the
          // feet-together one when the room asks for stillness.
          const frame = phase.still ? 1
            : Math.floor(loop(phase.t, 0.8, walker.slot * 0.13) * 2) % 2;
          if (frame !== walker.frame) {
            walker.frame = frame;
            walker.body.setFrame(WALKERS[frame]);
          }
        }
        if (model) {
          for (const vehicle of this.vehicles) {
            const step = vehicleAt(phase, vehicle.slot, model.street);
            vehicle.g.setAlpha(step.a);
            vehicle.g.setX(step.x);
          }
        }
        // The two ambient samples, re-read off this world's own clock exactly
        // as the DOM world re-reads them onto the root element — and left at
        // the static scene under reduced motion, as wall.css leaves them.
        if (frozen || !Model) {
          this.hazeBase.setAlpha(1);
          this.dawnG.setAlpha(0);
        } else {
          this.hazeBase.setAlpha(0.45 + 0.55 * Model.wetness(at - Model.RAIN_LAG));
          this.dawnG.setAlpha(Model.dawn(new Date(at * 1000)));
        }
        if (this.landmark) {
          const tube = tubeAt(phase, -7, 16);
          this.landmark.dedication.setAlpha(tube);
          this.landmark.lit.setAlpha(tube * 0.9);
        }

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
          shop.plate.setAlpha(0.5 + lit * 0.4);
        }
        parts.panes.forEach((pane, i) => pane.g.setAlpha(paneAt(phase, i, pane.phase * 13)));
        // A building lands with one settle and is furniture after that — and
        // the age it is fast-forwarded by is the same one --age carries in the
        // DOM world, so a browser opening this afternoon finds this morning's
        // buildings standing rather than the whole week landing at once.
        const age = Math.max(0, at - (block.at || at));
        parts.root.setAlpha(phase.still ? 1 : Math.min(1, age / 0.9));
        parts.root.setY(phase.still ? 0 : Math.round(Math.max(0, 1 - age / 0.9) * 14));
        if (model) parts.sign.setAlpha(signAt(phase, age, model.signSeconds));
      }

      stepTower(T, phase, at, model) {
        const tower = T.tower;
        if (!tower) return;
        const drift = model ? at - model.at : 0;
        const completion = (model && model.completionSeconds) || 0;
        if (T.bloom) T.bloom.setAlpha(0.1 + 0.2 * facadeAt(phase, tower.drift));
        const tube = tubeAt(phase, tower.drift, 16);
        T.sign.setAlpha(tube);
        T.signPlate.setAlpha(tube);
        if (tower.alarm) {
          // One way, for ever: the lamp turns, the wedge turns with it, and
          // what the room sees is the half of the revolution facing it.
          T.sweep.setRotation(phase.beam.angle * Math.PI / 180);
          T.sweep.setAlpha(phase.beam.face);
          T.ceiling.setX(T.ceilingX + Math.sin(phase.beam.angle * Math.PI / 180) * 9 * VH);
          T.ceiling.setAlpha(0.12 + 0.3 * phase.beam.face);
          T.column.setAlpha(0.3 + 0.24 * phase.klaxon);
          T.wash.setAlpha(phase.klaxon);
          T.basePlate.setAlpha(phase.text);
          T.labelLit.setAlpha(phase.text);
        }
        if (tower.shipped) {
          const age = tower.shippedAge + drift;
          const u = once(age, completion);
          T.beacon.setVisible(true);
          T.beacon.setAlpha(phase.still ? 0.9 : ramp(BEACON_ALPHA, u));
          T.beacon.setScale(T.beaconBase * (phase.still ? 1 : ramp(BEACON_SCALE, u)));
          const c = once(age, CEREMONY);
          T.halo.setVisible(!phase.still && c < 1);
          T.halo.setAlpha(ramp(HALO_ALPHA, c) * 0.8);
          T.halo.setScale(T.haloBase * ramp(HALO_SCALE, c));
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
            const state = shaftAt(phase, run.age + drift, completion, S.halo.visible);
            S.root.setAlpha(state.root);
            S.col.setAlpha(state.column);
            S.car.setAlpha(state.car);
            S.car.setScale(state.scale);
          } else {
            S.root.setAlpha(1);
            S.col.setAlpha(S.halo.visible ? 1 : 0.8);
            S.car.setScale(S.halo.visible ? 1.3 : 1);
            S.car.setAlpha(run.state === 'alarm' ? phase.carAlarm
              : run.state === 'active' ? phase.car : 1);
          }
        }
      }

      // The shipping cascade is the one thing in this world whose GEOMETRY
      // moves: light climbing the façade storey by storey for six seconds, once
      // per ship. It is only ever drawn while that beat is running, and only on
      // a shipping tower.
      paintCascade(T, u, phase) {
        if (phase.still || u >= 1 || !T.mass) { T.cascade.setVisible(false); return; }
        const mass = T.mass;
        T.cascade.setVisible(true);
        T.cascade.setBlendMode(Phaser.BlendModes.ADD);
        T.cascade.clear();
        T.cascade.setAlpha(ramp(CASCADE_ALPHA, u));
        const head = mass.y + mass.h - u * mass.h * 2.05;
        for (let y = mass.y; y < mass.y + mass.h; y += 8) {
          const near = (y - head) / mass.h;
          if (near > 0.02 || near < -0.6) continue;
          const k = Math.max(0, 1 + near / 0.6);
          T.cascade.fillStyle(0xe8fff4, k * 0.7);
          T.cascade.fillRect(mass.x, Math.round(y), mass.w, 4);
        }
      }
    }

    const game = new Phaser.Game({
      type: Phaser.AUTO,
      scale: {
        // The canvas covers the whole wall at the viewport's own aspect — no
        // fixed grid, no FIT, no letterbox — and its backing store is device
        // pixels. NONE means Phaser leaves the sizing to us, and `zoom` is what
        // puts a device-pixel canvas back at CSS size on screen. What turns
        // that buffer into the world's own 1280-wide grid is the camera, which
        // zooms by PIX — exactly 3 on the office 4K panel.
        mode: Phaser.Scale.NONE,
        parent,
        expandParent: false,
        width: W,
        height: H,
        zoom: 1 / DPR,
      },
      render: {
        // smoothPixelArt sets antialias and pixelArt itself; declaring either
        // here would fight it. roundPixels keeps a 2.25x wall from putting a
        // sprite on a half pixel.
        smoothPixelArt: true,
        roundPixels: true,
        powerPreference: 'low-power',
      },
      // Lifted from the old world's 30. The wall's budget is stated as frames
      // per second at 1920x1080 dpr 2 and a 30 Hz cap makes that unmeasurable;
      // this world draws about a tenth of the geometry the old one did, so the
      // headroom is real rather than borrowed from the frame rate.
      fps: { limit: 60 },
      audio: { noAudio: true },
      banner: false,
      backgroundColor: BG,
      scene: CityScene,
    });

    // A resized wall is re-measured and laid out again rather than stretched:
    // every size in this world is derived from the wall, so a new wall is a new
    // city. Debounced on the same 400 ms the director re-frames on.
    let relayout = 0;
    window.addEventListener('resize', () => {
      clearTimeout(relayout);
      relayout = setTimeout(() => {
        const size = wallSize();
        const dpr = ratio();
        if (!size.w || !size.h) return;
        if (Math.round(size.w * dpr) === W && Math.round(size.h * dpr) === H) return;
        measure(size.w, size.h, dpr);
        // Order matters: resize() sets the backing store and setZoom() then
        // refreshes the CSS size off it. The other way round leaves the canvas
        // displayed at whatever size the previous wall was.
        game.scale.resize(W, H);
        game.scale.setZoom(1 / DPR);
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
    w: W, h: H, dpr: DPR, pix: PIX, gw: GW, gh: GH, vw: VW, vh: VH, rem: REM,
    panel: PANEL, tile: TILE, sky: SKY, skyX: SKY_X, skyY: SKY_Y,
    ground: GROUND, groundY: GROUND_Y, cityH: CITY_H, districtH: DISTRICT_H,
  });

  return {
    create, measure, grid, phaseAt, tubeAt, paneAt, facadeAt, signAt, shaftAt,
    walkerAt, vehicleAt, ramp, towerLayout, blockBox, massesOf,
    TOWER_MASSES, FORM_MASSES, KIND_MASSES,
  };
}));
