'use strict';
// SPIKE (spike/topdown-city). The city's third body: a 3/4 top-down pixel-art
// night city, built from the bought 16x16 art packs in wall/private/ and drawn
// by the same vendored Phaser 4 the canvas world uses. Opened with
// ?world=topdown (the block) and ?world=topdown&scene=office (the floor the
// agents work on). The DOM world is still the default and world-canvas.js is
// untouched — this file is a THIRD option, not a replacement.
//
// What this is for: the owner judged the side-elevation canvas city as "not a
// videogame", picked a different direction, and wants to see THAT direction
// rendered by the real pipeline at TV scale before any wall data is wired into
// it. So the two compositions below are hand-composed set dressing. They read
// exactly two facts off the scene model — how many project buildings the block
// has (`scene.towers.length`) and which one is in alarm (`towers[i].alarm`) —
// and invent everything else. That is deliberate and temporary.
//
// The rules that are NOT temporary, and that this file keeps:
//
//   Integer pixels. The world is a 480x270 logical grid drawn at an INTEGER
  //   camera zoom (4x on a 1920x1080 TV, 6 device pixels on a 1440x900@2x
  //   Retina laptop).
//   A tile is never scaled by a fraction, and the camera lands on whole
//   logical pixels.
//
//   Nothing periodic keeps its own state. Every moving thing is a pure
//   function of the wall clock through phaseAt(), so two screens in a room are
//   on the same beat and reduced motion is a STILL frame rather than a slow
//   one. No Math.random anywhere: the scatter that a city needs comes out of
//   hash01(), which is murmur3's finaliser over an integer.
//
//   Nothing loads that is not declared. PACK_FILES is the entire list of bytes
//   this world will ever ask for, all of it served by wall/server.js's guarded
//   /private/ route off local disk. No off-origin URL exists in this file.
//
//   No pure black (the depth playbook's palette rule). Night is a per-plane
//   MULTIPLY tint on the art plus one additive ambient lift, so the darkest
//   pixel on the wall sits around #1c2544 rather than at zero, and the neon and
//   the warm windows are the only things that are allowed to be bright.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallTopdownWorld = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the grid -----------------------------------------------------------------
  // Unlike the canvas world — which is a parity port of a city drawn in vh/rem
  // at native resolution — this one is sprite art with a fixed pixel size, so it
  // gets the treatment sprite art needs: a logical grid, and an INTEGER scale up
  // to the panel. 480x270 is the reference (the art-direction doc's authoring
  // size); a stage that is not exactly 4x that shows a little more world rather
  // than a letterbox or a half-pixel tile.

  const TILE = 16;
  const REF_W = 480;
  const REF_H = 270;

  let DPR = 1;      // device pixels per CSS pixel, capped at 2
  let W = 1920;     // backing store, device px
  let H = 1080;
  let SCALE = 4;    // device pixels per logical pixel — always a whole number
  let LW = 480;     // the logical world the camera shows
  let LH = 270;
  let COLS = 30;    // ...as whole tiles, rounded up so the frame is covered
  let ROWS = 17;

  function measure(cssWidth, cssHeight, ratio) {
    DPR = Math.min(Math.max(Number(ratio) || 1, 1), 2);
    W = Math.max(1, Math.round(cssWidth * DPR));
    H = Math.max(1, Math.round(cssHeight * DPR));
    SCALE = Math.max(1, Math.floor(Math.min(W / REF_W, H / REF_H)));
    LW = Math.round(W / SCALE);
    LH = Math.round(H / SCALE);
    COLS = Math.ceil(LW / TILE);
    ROWS = Math.ceil(LH / TILE);
  }

  const grid = () => ({ w: W, h: H, dpr: DPR, scale: SCALE, lw: LW, lh: LH, cols: COLS, rows: ROWS });

  // --- the packs ----------------------------------------------------------------
  // The whole of what this world loads. Every entry is a file under
  // wall/private/ served by the guarded /private/ route; nothing else is ever
  // requested, and there is no absolute or off-origin URL in this file at all.
  // `cols` is the sheet's width in frames, which is all the frame arithmetic
  // below needs.

  const SHEETS = {
    terrain: { url: 'private/beezeebox-exterior/CyberPunk_Terrains.png', fw: 16, fh: 16, cols: 16 },
    build: { url: 'private/beezeebox-exterior/CyberPunk_Buildings_V2.png', fw: 16, fh: 16, cols: 16 },
    props: { url: 'private/beezeebox-exterior/CyberPunk_Objects_V2.png', fw: 16, fh: 16, cols: 16 },
    signs: { url: 'private/beezeebox-exterior/CyberPunk_SignsGrafitti_V2.png', fw: 16, fh: 16, cols: 16 },
    anim: { url: 'private/beezeebox-exterior/Animations/CyberPunk_Animations.png', fw: 16, fh: 16, cols: 16 },
    walk1: { url: 'private/beezeebox-exterior/Characters/Char1.png', fw: 16, fh: 16, cols: 4 },
    walk2: { url: 'private/beezeebox-exterior/Characters/Char2.png', fw: 16, fh: 16, cols: 4 },
    walk3: { url: 'private/beezeebox-exterior/Characters/Char3.png', fw: 16, fh: 16, cols: 4 },
    walk4: { url: 'private/beezeebox-exterior/Characters/Char4.png', fw: 16, fh: 16, cols: 4 },
    walk5: { url: 'private/beezeebox-exterior/Characters/Char5.png', fw: 16, fh: 16, cols: 4 },
    inside: { url: 'private/beezeebox-interior/Cyberpunk_Interiors.png', fw: 16, fh: 16, cols: 16 },
    floors: { url: 'private/beezeebox-interior/Cyberpunk_Interiors_Floors.png', fw: 16, fh: 16, cols: 16 },
    room: { url: 'private/limezu-free/Interiors_free/16x16/Room_Builder_free_16x16.png', fw: 16, fh: 16, cols: 17 },
    lz: { url: 'private/limezu-free/Interiors_free/16x16/Interiors_free_16x16.png', fw: 16, fh: 16, cols: 16 },
    // LimeZu's seated poses are 16px sprites on a 32px pitch, so the frame is
    // the 32px cell and the body sits 6px in from its left edge (SIT_INSET).
    sitA: { url: 'private/limezu-free/Characters_free/Adam_sit_16x16.png', fw: 32, fh: 32, cols: 12 },
    sitB: { url: 'private/limezu-free/Characters_free/Alex_sit_16x16.png', fw: 32, fh: 32, cols: 12 },
    sitC: { url: 'private/limezu-free/Characters_free/Amelia_sit_16x16.png', fw: 32, fh: 32, cols: 12 },
    sitD: { url: 'private/limezu-free/Characters_free/Bob_sit_16x16.png', fw: 32, fh: 32, cols: 12 },
    phone: { url: 'private/limezu-free/Characters_free/Bob_phone_16x16.png', fw: 16, fh: 32, cols: 9 },
    run: { url: 'private/limezu-free/Characters_free/Amelia_run_16x16.png', fw: 16, fh: 32, cols: 24 },
  };

  const CITY_SHEETS = ['terrain', 'build', 'props', 'signs', 'anim',
    'walk1', 'walk2', 'walk3', 'walk4', 'walk5'];
  const OFFICE_SHEETS = ['floors', 'room', 'lz', 'inside', 'anim', 'props',
    'sitA', 'sitB', 'sitC', 'sitD', 'phone', 'run'];

  // Flat, for the suite: every byte this world can pull in, in one list.
  const PACK_FILES = Object.keys(SHEETS).map((key) => SHEETS[key].url);

  const SIT_INSET = 6;   // where the body starts inside LimeZu's 32px sit cell

  // Frame index of tile (col, row) on a sheet. Every sheet in here is a plain
  // grid, so this is the only atlas arithmetic the file needs.
  const fr = (sheet, col, row) => row * SHEETS[sheet].cols + col;

  // --- the palette --------------------------------------------------------------
  // Night is applied as a MULTIPLY tint per depth plane (the art direction's
  // rule 4: each step back converges toward the sky and loses contrast), plus
  // one additive ambient lift over the whole frame so the darkest pixel never
  // reaches black. The neon, the windows and the lamps are drawn untinted on
  // top — they are the only warm mass in the composition.

  const NIGHT_FAR = 0x46538a;      // the roofs beyond the back road
  const NIGHT_GROUND = 0x6472a8;   // road and pavement
  const NIGHT_MID = 0x7d8ac0;      // the hero block — the sharp, detailed plane
  const NIGHT_SHOP = 0x8c96c6;     // the shops between the projects, a shade up
  const NIGHT_PROP = 0x99a3cf;     // street furniture, nearest plane
  const NIGHT_PEOPLE = 0x929ecb;
  const NIGHT_ROOM = 0x7a87bd;     // the office floor and its furniture
  const WALL_TINT = 0x56649c;      // its back wall, a stop darker than the floor
  const AMBIENT = 0x131a30;        // the additive floor: no pure black, ever
  const ALARM = 0xff4436;
  const WARM = 0xffc27d;
  const COOL = 0x7ad6ec;
  const LAMP = 0x9fe3ff;

  // --- the wall clock -----------------------------------------------------------
  // Same doctrine as the canvas world: everything that moves is a position in a
  // cycle, every position comes out of phaseAt(), and asking for a reduced-motion
  // phase at any second of any day returns the same object.

  // murmur3's finaliser over an integer, mapped to [0, 1). This is the ONLY
  // source of scatter in the file — a city needs variety and `Math.random` is
  // banned, so variety is a pure function of an index.
  function hash01(n) {
    let v = Math.imul((n | 0) ^ ((n | 0) >>> 16), 0x85ebca6b) >>> 0;
    v = Math.imul(v ^ (v >>> 13), 0xc2b2ae35) >>> 0;
    return ((v ^ (v >>> 16)) >>> 0) / 4294967296;
  }
  const pick = (list, n) => list[Math.floor(hash01(n) * list.length) % list.length];

  // Two tints, blended. Used for the alarm building's breath, which is a tint
  // moving between the block's night colour and the wall's own red.
  function mixColour(from, to, k) {
    const u = Math.max(0, Math.min(1, k));
    const ch = (shift) => {
      const a = (from >> shift) & 0xff;
      const b = (to >> shift) & 0xff;
      return Math.round(a + (b - a) * u) & 0xff;
    };
    return (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  function loop(t, period, delay) {
    const u = (((t + delay) % period) / period);
    return u < 0 ? u + 1 : u;
  }
  function swing(t, period) {
    const u = ((t / period) % 2 + 2) % 2;
    return u < 1 ? u : 2 - u;
  }

  function phaseAt(seconds, opts) {
    const frozen = !!(opts && opts.reducedMotion);
    const t = frozen ? 0 : Number(seconds) || 0;
    return {
      still: frozen,
      t,
      // The alarm building's slow red breath. A still wall keeps it lit at the
      // top of the swing rather than dark: an alarm you cannot see is a bug.
      alarm: frozen ? 1 : 0.45 + 0.55 * swing(t, 1.3),
      // The city's own drifting brightness — window banks and neon spill.
      glow: frozen ? 0.8 : 0.72 + 0.28 * swing(t, 17),
      // Rain: gone entirely when the room asks for stillness, exactly as the
      // DOM wall drops .rain. A streak that cannot travel is a scratch.
      rain: frozen ? 0 : 1,
    };
  }

  // Which frame of an n-frame loop is showing. Reduced motion pins every
  // animation to frame 0, which is a LIT frame on every strip in the pack.
  const cycleAt = (phase, period, count, delay) =>
    (phase.still ? 0 : Math.floor(loop(phase.t, period, delay) * count) % count);

  // A tube that mostly holds and occasionally stumbles. Same shape as the
  // canvas world's HUM, expressed as an on/off multiplier.
  function tubeAt(phase, delay) {
    if (phase.still) return 1;
    const u = loop(phase.t, 23, delay);
    if (u > 0.61 && u < 0.65) return u < 0.625 ? 0.3 : 0.85;
    return 1;
  }

  // A walker's crossing: pure position, pure walk-cycle frame. `plan` carries
  // the lane and the direction so the same function serves both pavements.
  function walkerAt(phase, i, plan) {
    const span = plan.span + 48;
    const speed = plan.speed;
    const u = phase.still
      ? (0.12 + 0.76 * hash01(i * 7 + 3))
      : loop(phase.t * speed / span, 1, hash01(i * 7 + 3));
    const x = plan.right ? -24 + u * span : plan.span + 24 - u * span;
    return {
      x: Math.round(x),
      dir: plan.right ? 3 : 2,
      step: phase.still ? 0 : Math.floor(loop(phase.t, 0.72, i * 0.19) * 4) % 4,
    };
  }

  // One rain streak. Seeded off its own index so the field is the same field on
  // two screens, and re-derived per frame rather than integrated — nothing here
  // keeps state, so a browser opened at any second joins the same weather.
  function rainAt(phase, i) {
    const speed = 150 + hash01(i * 5 + 1) * 130;
    const len = 3 + Math.floor(hash01(i * 5 + 2) * 5);
    const x0 = hash01(i * 5 + 3) * (LW + 80) - 40;
    const y = ((phase.t * speed + hash01(i * 5 + 4) * 400) % (LH + 40)) - 20;
    return {
      x: Math.round(x0 + y * 0.18),
      y: Math.round(y),
      len,
      a: (0.16 + 0.2 * hash01(i * 5 + 5)) * (i % 3 === 0 ? 1.5 : 1),
      near: i % 3 === 0,
    };
  }

  // --- the block plan -----------------------------------------------------------
  // Where everything stands, as data, so the composition is inspectable without
  // a GPU. Two facts come from the wall (how many project buildings, and which
  // one is shouting); the rest is the fixed set dressing this spike is for.

  // Roof blocks on CyberPunk_Buildings_V2 that are big enough to nine-slice: a
  // rim on all four sides and at least one interior tile. [col, row, w, h].
  const ROOFS = [
    [0, 2, 3, 3],    // slate
    [0, 8, 3, 3],    // maroon
    [3, 8, 3, 3],    // orange brick
    [0, 11, 4, 3],   // pale blue
    [4, 11, 4, 3],   // bone
    [8, 11, 5, 3],   // navy, red strip along the parapet
    [11, 0, 5, 4],   // tan
    [11, 4, 5, 4],   // red brick
    [6, 0, 5, 3],    // white rim
    [0, 16, 4, 3],   // teal slab
    [4, 16, 3, 3],   // violet slab
    [0, 19, 4, 3],   // amber slab
    [4, 19, 3, 3],   // cobalt slab
    [3, 0, 3, 4],    // corrugated
  ];
  // The two-row facade bands on the same sheet: a wall face with its fittings —
  // neon strips, shutters, lit windows, doors. Stacking these is what makes a
  // project building visibly taller than the shop next door.
  const FACADES = [
    [0, 14, 4], [4, 14, 4], [8, 14, 4], [12, 14, 4],
  ];
  // Latin neon off the signs sheet: one column, three tiles tall.
  // CLUB FOOD GUNS SHOP HAIR HOTEL POLICE, then BANK CLOTHES HEALTH.
  const VERT_SIGNS = [[0, 6], [1, 6], [2, 6], [3, 6], [4, 6], [5, 6], [6, 6],
    [0, 10], [1, 10], [2, 10]];
  // INN, EAT, BAR — two tiles tall, for the shops between the projects.
  const SHOP_SIGNS = [[3, 12], [4, 12], [5, 12]];
  // Roof billboards on posts, and the two horizontal fascia signs: HOT,
  // EAT 24/7, FREE, RESIST, then MARKET and SHOPPING. [col, row, w, h].
  const BILLBOARDS = [[8, 0, 2, 2], [10, 0, 2, 2], [12, 0, 3, 2], [8, 2, 6, 2]];
  const FASCIA = [[0, 9, 3, 1], [3, 9, 3, 1]];
  // Spray-can Latin off the same sheet, for the bottom of a facade: POWER,
  // FIGHT, GANG, PEACE, FREEDOM.
  const GRAFFITI = [[0, 0, 3, 1], [0, 1, 3, 1], [0, 2, 3, 1], [0, 4, 3, 1], [0, 5, 4, 1]];

  // The rows the city is laid out against. Bottom-up, because the composition
  // rule that matters is the art direction's: the lower third is street and
  // life, the middle is the hero block, the top is the district falling away.
  // Derived from the measured frame so a taller stage shows more district
  // rather than stretching a tile.
  function cityRows(rows) {
    const base = rows - 6;             // where every hero building's wall meets the ground
    return {
      farBase: Math.max(2, base - 7),  // rows 0..farBase are the far roof band
      backRoad: Math.max(3, base - 6),
      backPave: Math.max(4, base - 5),
      base,
      frontPave: rows - 5,
      road: [rows - 4, rows - 3],
      nearPave: [rows - 2, rows - 1],
    };
  }

  const PROJECT_W = 4;
  const PROJECT_H = 8;   // 4 rows of roof over 4 rows — two stacked facade bands
  const SHOP_W = 3;
  const SHOP_H = 5;      // 3 rows of roof over one band. Three rows shorter, and
                         // that gap is the whole point: the projects are the
                         // towers of this block.

  // The hero row, left to right: every project building the wall reported, with
  // shops packed into the gaps between them until the block is full. A terrace,
  // not a set of islands — a city block's buildings share walls.
  const ALLEY_W = 2;

  function shopBlock(slot, x, w) {
    return {
      kind: 'shop', x, w, h: SHOP_H,
      roof: Math.floor(hash01(slot * 31 + 5) * ROOFS.length),
      facade: Math.floor(hash01(slot * 31 + 9) * FACADES.length),
      sign: Math.floor(hash01(slot * 31 + 13) * SHOP_SIGNS.length),
    };
  }

  // A quiet wall still has a district, just no project buildings. Fill its
  // hero row with shops and keep the same alley the busy composition uses.
  function districtRow(cols) {
    const width = Math.max(1, Math.floor(Number(cols) || 1));
    const hasAlley = width >= SHOP_W * 2 + ALLEY_W;
    const shopSpace = width - (hasAlley ? ALLEY_W : 0);
    const shopCount = Math.max(1, Math.floor(shopSpace / SHOP_W));
    const extra = shopSpace - shopCount * SHOP_W;
    const alleyAt = Math.floor(shopCount / 2);
    const out = [];
    let x = 0;
    for (let i = 0; i < shopCount; i++) {
      if (hasAlley && i === alleyAt) {
        out.push({ kind: 'alley', x, w: ALLEY_W });
        x += ALLEY_W;
      }
      const w = SHOP_W + (i === 0 ? extra : 0);
      out.push(shopBlock(i, x, w));
      x += w;
    }
    return out;
  }

  function frontRow(count, alarmAt, cols) {
    const requested = Math.max(0, Math.floor(Number(count) || 0));
    if (requested === 0) return districtRow(cols);
    // Four tiles is the hero width, but a crowded wall may report more projects
    // than fit at that size. Narrow them by whole tiles rather than dropping
    // model entries or scaling the art by a fraction.
    const n = Math.min(requested, cols);
    const projectW = Math.max(1, Math.min(PROJECT_W, Math.floor(cols / n)));
    const gaps = new Array(n + 1).fill(0);
    let spare = cols - n * projectW;
    // One gap is kept as an alley rather than filled with a shop: the lane
    // between two buildings is what tells the room this is a BLOCK seen from
    // above and not a painted backdrop.
    const alley = Math.floor(gaps.length / 2);
    if (spare >= ALLEY_W + SHOP_W) { gaps[alley] = ALLEY_W; spare -= ALLEY_W; }
    for (let i = 0; i < gaps.length && spare >= SHOP_W; i++) {
      if (i === alley && gaps[i]) continue;
      gaps[i] = SHOP_W;
      spare -= SHOP_W;
    }
    for (let i = 0; spare > 0; i++, spare--) gaps[i % gaps.length] += 1;

    const out = [];
    let x = 0;
    for (let i = 0; i <= n; i++) {
      if (gaps[i] >= SHOP_W && i !== alley) {
        out.push(shopBlock(i, x, SHOP_W));
      } else if (gaps[i] >= 2) {
        out.push({ kind: 'alley', x, w: gaps[i] });
      }
      x += gaps[i];
      if (i < n) {
        out.push({
          kind: 'project', index: i, x, w: projectW, h: PROJECT_H,
          alarm: i === alarmAt,
          roof: Math.floor(hash01(i * 17 + 2) * ROOFS.length),
          facade: Math.floor(hash01(i * 17 + 6) * FACADES.length),
          sign: i % VERT_SIGNS.length,
          // Two of the projects carry a roof billboard; one carries a fascia.
          board: hash01(i * 17 + 11) > 0.45 ? Math.floor(hash01(i * 29) * BILLBOARDS.length) : -1,
          fascia: hash01(i * 17 + 23) > 0.6 ? Math.floor(hash01(i * 37) * FASCIA.length) : -1,
          tag: hash01(i * 17 + 31) > 0.55 ? Math.floor(hash01(i * 41) * GRAFFITI.length) : -1,
        });
        x += projectW;
      }
    }
    return out;
  }

  // The band of roofs beyond the back road: flat, detail-free, heavily hazed,
  // and never a straight edge. The playbook's rule 7 — the far plane gets a
  // silhouette and nothing else — and rule 8: no two edges may line up.
  function backRow(cols, rows) {
    const out = [];
    const bottom = cityRows(rows).farBase;
    for (let x = 0; x < cols;) {
      const w = 3 + Math.floor(hash01(x * 13 + 41) * 3);
      const h = 3 + Math.floor(hash01(x * 13 + 77) * 3);
      out.push({
        x, w: Math.min(w, cols - x), h,
        top: Math.max(0, bottom - h + 1),
        roof: Math.floor(hash01(x * 13 + 5) * ROOFS.length),
      });
      x += w;
    }
    return out;
  }

  function cityPlan(scene, cols, rows) {
    const towers = (scene && Array.isArray(scene.towers)) ? scene.towers : [];
    const alarmAt = towers.findIndex((tower) => tower && tower.alarm);
    return {
      rows: cityRows(rows),
      front: frontRow(towers.length, alarmAt, cols),
      back: backRow(cols, rows),
      towers,
    };
  }

  // --- the office plan ----------------------------------------------------------
  // Six zones left to right, in the pipeline's own order — the same ladder the
  // server publishes as FLOORS and the wall's cars climb.
  const ZONES = ['SETUP', 'IMPLEMENT', 'GATE', 'REVIEW', 'DEMO', 'PUSH'];

  // A 3x5 pixel face, drawn as rectangles. Vendoring a bitmap font for a
  // throwaway spike would mean a licence, a manifest row and a hash pin for six
  // words; Phaser text would be resampled by the camera zoom and stop being
  // pixel art. Twenty-six letters of geometry is the smaller thing.
  const FONT = {
    A: '010101111101101', B: '110101110101110', C: '011100100100011',
    D: '110101101101110', E: '111100110100111', F: '111100110100100',
    G: '011100101101011', H: '101101111101101', I: '111010010010111',
    J: '001001001101010', K: '101101110101101', L: '100100100100111',
    M: '101111111101101', N: '101111111111101', O: '010101101101010',
    P: '110101110100100', Q: '010101101110011', R: '110101110101101',
    S: '011100010001110', T: '111010010010010', U: '101101101101011',
    V: '101101101101010', W: '101101111111101', X: '101101010101101',
    Y: '101101010010010', Z: '111001010100111', '?': '110001010000010',
    '0': '111101101101111', '1': '010110010010111', '2': '110001010100111',
    '3': '110001010001110', '4': '101101111001001', '5': '111100110001110',
    '6': '011100110101010', '7': '111001010010010', '8': '010101010101010',
    '9': '010101011001110', '.': '000000000000010', ' ': '000000000000000',
  };
  const GLYPH_W = 4;   // 3 pixels plus one of letter-spacing
  const GLYPH_H = 5;

  const textWidth = (text, scale) => Math.max(0, String(text).length * GLYPH_W * (scale || 1) - 1);

  function drawText(g, text, x, y, colour, alpha, scale) {
    const s = scale || 1;
    g.fillStyle(colour, alpha === undefined ? 1 : alpha);
    const chars = String(text).toUpperCase().split('');
    for (let i = 0; i < chars.length; i++) {
      const bits = FONT[chars[i]];
      if (!bits) continue;
      for (let row = 0; row < GLYPH_H; row++) {
        for (let col = 0; col < 3; col++) {
          if (bits[row * 3 + col] === '1') {
            g.fillRect(x + (i * GLYPH_W + col) * s, y + row * s, s, s);
          }
        }
      }
    }
  }

  // --- the world ----------------------------------------------------------------

  function create(opts) {
    const parent = opts.parent;
    const still = opts.still;
    const clock = opts.clock;
    const query = typeof window !== 'undefined'
      ? new URLSearchParams(window.location.search) : new URLSearchParams('');
    const office = query.get('scene') === 'office';
    // The lens, off. A spike is a thing the owner compares against itself, and
    // "what does it look like without the depth of field" is the first question
    // they will ask. It is one branch and it is worth it here.
    const NO_FX = query.get('fx') === '0';

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

    let live = null;        // the running scene, once Phaser has booted it
    let pending = null;     // the last scene model handed over before Phaser booted

    class TopdownScene extends Phaser.Scene {
      constructor() { super('topdown'); }

      preload() {
        // The declared list, and nothing else. A missing pack is a dark wall
        // and one line in the console, never a broken page.
        this.load.on('loaderror', (file) => {
          console.error('wall: cannot load ' + (file && file.src));
        });
        for (const key of (office ? OFFICE_SHEETS : CITY_SHEETS)) {
          const sheet = SHEETS[key];
          this.load.spritesheet(key, sheet.url, {
            frameWidth: sheet.fw, frameHeight: sheet.fh,
          });
        }
      }

      create() {
        this.phase = phaseAt(0, { reducedMotion: true });
        this.planKey = '';
        this.neons = [];      // animated strips: {img, sheetFrames, period, delay}
        this.screens = [];
        this.walkers = [];
        this.sitters = [];
        this.alarmParts = [];
        this.alarmGlow = null;
        this.raindrops = office ? 0 : 90;

        const cam = this.cameras.main;
        cam.setZoom(SCALE);
        cam.centerOn(Math.round(LW / 2), Math.round(LH / 2));
        cam.setBackgroundColor(0x121a2e);
        if (typeof cam.setRoundPixels === 'function') cam.setRoundPixels(true);

        // Back to front. Every layer is a container so a whole plane can be
        // tinted, hidden or depth-sorted as one thing.
        this.ground = this.add.container(0, 0).setDepth(0);
        this.far = this.add.container(0, 0).setDepth(1);
        // Life on the far pavement rides BEHIND the hero block: a walker on the
        // back street who draws over a project building is a walker on a roof.
        this.backLife = this.add.container(0, 0).setDepth(1.5);
        this.mid = this.add.container(0, 0).setDepth(2);
        this.trim = this.add.container(0, 0).setDepth(3);
        this.people = this.add.container(0, 0).setDepth(4);
        this.near = this.add.container(0, 0).setDepth(5);
        this.ambient = this.add.graphics().setDepth(6);
        this.lights = this.add.graphics().setDepth(7);
        this.weather = this.add.graphics().setDepth(8);

        this.paintAmbient();
        if (office) this.buildOffice(); else this.buildCity(pending);

        live = this;
        this.step(true);
        this.installFilters();
      }

      // One additive lift over the whole frame. Everything under it has been
      // multiplied down to night, and this is what stops the darks bottoming
      // out at black — the palette rule the research doc is emphatic about.
      paintAmbient() {
        this.ambient.clear();
        this.ambient.fillStyle(AMBIENT, 1);
        this.ambient.fillRect(0, 0, LW, LH);
        this.ambient.setBlendMode(Phaser.BlendModes.ADD);
      }

      // Tilt-shift is what turns a flat tile map into a diorama, and it is the
      // one HD-2D device that works on a fixed camera. A vignette under it
      // closes the frame. Both run on the camera, so they cost one pass over
      // the composited image rather than anything per sprite.
      installFilters() {
        const cam = this.cameras.main;
        if (!cam.filters || NO_FX) return;
        // Light. The HD-2D recipe is depth of field over sprites, not a soft
        // photograph: the hero band has to stay pin-sharp at 4x or the whole
        // point of drawing pixel art at an integer scale is thrown away, so
        // this is a narrow, weak bokeh and a shallow vignette and no more.
        // ?fx=0 turns both off for a side-by-side.
        if (cam.filters.external.addTiltShift) {
          cam.filters.external.addTiltShift(0.22, 0.55, 1.05, 0.55, 0.55, 0.5);
        } else if (cam.filters.external.addBlur) {
          cam.filters.external.addBlur(0, 1, 1, 0.4);
        }
        if (cam.filters.external.addVignette) {
          cam.filters.external.addVignette(0.5, 0.52, 0.82, 0.4);
        }
      }

      // --- shared drawing -------------------------------------------------------

      // One tile. Everything in both compositions is built out of this.
      tile(layer, sheet, col, row, x, y, tint) {
        const img = this.add.image(x, y, sheet, fr(sheet, col, row)).setOrigin(0, 0);
        if (tint !== undefined) img.setTint(tint);
        layer.add(img);
        return img;
      }

      // A rectangle of tiles, blitted as-is. Used for props that are drawn as
      // one object across several cells — a street lamp, a whole storefront.
      stamp(layer, sheet, col, row, w, h, x, y, tint) {
        const out = [];
        for (let dy = 0; dy < h; dy++) {
          for (let dx = 0; dx < w; dx++) {
            out.push(this.tile(layer, sheet, col + dx, row + dy,
              x + dx * TILE, y + dy * TILE, tint));
          }
        }
        return out;
      }

      // A roof block scaled to any footprint by nine-slicing it: the rim tiles
      // stay put and the interior repeats. This is what lets fourteen hand-drawn
      // roofs cover a block of any width without stretching a pixel.
      roof(layer, spec, cx, cy, w, h, tint) {
        const [sc, sr, sw, sh] = spec;
        const out = [];
        for (let y = 0; y < h; y++) {
          for (let x = 0; x < w; x++) {
            const col = x === 0 ? sc
              : x === w - 1 ? sc + sw - 1
                : sc + 1 + ((x - 1) % Math.max(1, sw - 2));
            const row = y === 0 ? sr
              : y === h - 1 ? sr + sh - 1
                : sr + 1 + ((y - 1) % Math.max(1, sh - 2));
            out.push(this.tile(layer, 'build', col, row,
              (cx + x) * TILE, (cy + y) * TILE, tint));
          }
        }
        return out;
      }

      // A facade: the two-row band repeated down and across. Stacking bands is
      // the whole trick — the project buildings get two, the shops get one, and
      // that difference is what reads as height from the sofa.
      facade(layer, spec, cx, cy, w, h, tint) {
        const [sc, sr, sw] = spec;
        const out = [];
        for (let y = 0; y < h; y++) {
          for (let x = 0; x < w; x++) {
            out.push(this.tile(layer, 'build', sc + (x % sw), sr + (y % 2),
              (cx + x) * TILE, (cy + y) * TILE, tint));
          }
        }
        return out;
      }

      // A soft radial pool of light, as rings on the additive layer. There is no
      // radial fill in Graphics and every one of these is painted once.
      glow(g, colour, cx, cy, rx, ry, alpha, rings) {
        const n = rings || 7;
        for (let i = n; i >= 1; i--) {
          const k = i / n;
          g.fillStyle(colour, (alpha / n) * (1.15 - k * 0.55));
          g.fillEllipse(cx, cy, rx * 2 * k, ry * 2 * k);
        }
      }

      // --- composition 1: the block ---------------------------------------------

      buildCity(model) {
        const plan = cityPlan(model, COLS, ROWS);
        this.plan = plan;
        this.planKey = planKeyOf(model);
        const R = plan.rows;

        this.paintGround(R);
        for (const block of plan.back) {
          this.roof(this.far, ROOFS[block.roof], block.x, block.top, block.w, block.h, NIGHT_FAR);
          // One lit window bank per far roof and nothing else: at this distance
          // the plane is a silhouette with warmth in it, never a facade.
          if (hash01(block.x * 3 + 1) > 0.45) {
            this.tile(this.far, 'props', 2, 13, (block.x + 1) * TILE + 3,
              (block.top + 1) * TILE + 4, 0xb98a4e);
          }
        }
        // The wet air between the far roofs and the hero block: the haze quad
        // the depth playbook asks for between every plane pair, in the light-
        // pollution colour rather than in grey.
        this.far.add(this.add.rectangle(0, 0, LW, (R.backPave + 1) * TILE, 0x2c3d70, 0.26)
          .setOrigin(0, 0));

        for (const block of plan.front) this.paintBlock(block, R);
        this.paintStreet(R);
        this.paintWalkers(R);
        this.paintLights();
      }

      paintGround(R) {
        const ASPHALT = [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0], [5, 0],
          [0, 1], [1, 1], [2, 1], [3, 1], [4, 1], [5, 1], [0, 2], [1, 2], [2, 2]];
        const PAVE = [[8, 8], [9, 8], [8, 9], [9, 9]];
        const KERB = [[8, 6], [9, 6]];
        const paveRows = new Set([R.backPave, R.frontPave].concat(R.nearPave));
        const kerbRows = new Set([R.frontPave, R.nearPave[0]]);

        for (let r = 0; r < ROWS; r++) {
          for (let c = 0; c < COLS; c++) {
            const seed = r * 97 + c * 31;
            const t = paveRows.has(r)
              ? pick(kerbRows.has(r) ? KERB : PAVE, seed)
              : pick(ASPHALT, seed);
            this.tile(this.ground, 'terrain', t[0], t[1], c * TILE, r * TILE, NIGHT_GROUND);
          }
        }
        // Centre lines: the pack's own painted bar, laid on alternate columns so
        // it reads as a dash. Left near white — road paint under a sodium lamp
        // is the brightest thing at street level and cannot be tinted to night
        // with everything else or the carriageway disappears.
        for (let c = 1; c < COLS; c += 2) {
          this.tile(this.ground, 'terrain', 1, 3, c * TILE, R.road[1] * TILE, 0xbfc8dd);
          this.tile(this.ground, 'terrain', 1, 3, c * TILE, R.backRoad * TILE, 0x8892ad);
        }
        // A lit crossing, in the pack's own blue light strips.
        const cross = Math.floor(COLS * 0.58);
        for (let dy = 0; dy < 2; dy++) {
          for (let dx = 0; dx < 2; dx++) {
            this.tile(this.ground, 'terrain', 8 + dx, 1 + dy,
              (cross + dx) * TILE, (R.road[0] + dy) * TILE, 0xa8b6d8);
          }
        }
        // Drain covers and grates, because a street with no punctuation reads
        // as wallpaper.
        for (let i = 0; i < 5; i++) {
          const c = 2 + Math.floor(hash01(i * 61 + 9) * (COLS - 4));
          this.tile(this.ground, 'terrain', 8 + (i % 2), 3, c * TILE,
            (i % 2 ? R.road[0] : R.road[1]) * TILE, NIGHT_GROUND);
        }
      }

      // One building: roof, then facade under it, then whatever is bolted to
      // the front — a Latin neon sign, an animated tube, warm windows — and
      // the two things that stop a terrace reading as one long wall: a party
      // wall down each side and a shadow where it meets the pavement.
      paintBlock(block, R) {
        if (block.kind === 'alley') return this.paintAlley(block, R);
        const top = R.base - block.h + 1;
        const roofH = block.kind === 'project' ? 4 : 3;
        const facadeH = block.h - roofH;
        const tint = block.kind === 'project' ? NIGHT_MID : NIGHT_SHOP;

        const roofParts = this.roof(this.mid, ROOFS[block.roof],
          block.x, top, block.w, roofH, tint);
        const wallParts = this.facade(this.mid, FACADES[block.facade],
          block.x, top + roofH, block.w, facadeH, tint);

        // Rooftop plant, off the pack's own roof clutter — an unbroken roof
        // slab is the tell that a building is a rectangle.
        if (block.w >= 3) {
          const clutter = pick([[6, 6, 2, 2], [8, 6, 3, 2], [11, 4, 2, 2]], block.x * 7 + 3);
          this.stamp(this.mid, 'build', clutter[0], clutter[1], clutter[2], clutter[3],
            (block.x + 1) * TILE - 2, (top + 1) * TILE, tint);
        }

        // Party walls, a rim light along the parapet and the contact shadow at
        // the pavement. Four rectangles, and between them the difference
        // between "a terrace of buildings" and "wallpaper".
        this.mid.add(this.add.rectangle(block.x * TILE, top * TILE, 2, block.h * TILE,
          0x070b18, 0.8).setOrigin(0, 0));
        this.mid.add(this.add.rectangle((block.x + block.w) * TILE - 1, top * TILE, 1,
          block.h * TILE, 0x070b18, 0.5).setOrigin(0, 0));
        this.mid.add(this.add.rectangle(block.x * TILE + 2, top * TILE,
          block.w * TILE - 3, 1, 0x9fb6e8, 0.35).setOrigin(0, 0));
        this.mid.add(this.add.rectangle(block.x * TILE, (R.base + 1) * TILE,
          block.w * TILE, 5, 0x0b1024, 0.6).setOrigin(0, 0));

        const wallTop = (top + roofH) * TILE;
        if (block.kind === 'project') {
          const sign = VERT_SIGNS[block.sign];
          const sx = (block.x + block.w - 1) * TILE + 3;
          const parts = this.stamp(this.trim, 'signs', sign[0], sign[1], 1, 3, sx, wallTop + 3);
          this.neons.push({ parts, delay: block.x * 1.7 });
          block.sign3 = { x: sx + 8, y: wallTop + 3 };
          // Two lit windows, not twenty. The warm mass has to be the rarest
          // thing in the frame or it stops reading as "somebody is still in
          // there" and starts reading as texture.
          for (let y = 1; y < facadeH; y += 2) {
            const x = Math.floor(hash01(block.x * 19 + y) * (block.w - 1));
            this.tile(this.trim, 'props', 2, 13,
              (block.x + x) * TILE + 3, (top + roofH + y) * TILE + 2, WARM);
          }
          block.lit = { x: (block.x + block.w / 2) * TILE, y: wallTop + facadeH * TILE * 0.5 };
          if (block.alarm) {
            this.alarmParts = roofParts.concat(wallParts);
            this.alarmGlow = block;
          }
        } else {
          const sign = SHOP_SIGNS[block.sign];
          const sx = (block.x + block.w - 1) * TILE + 4;
          this.stamp(this.trim, 'signs', sign[0], sign[1], 1, 2, sx, wallTop + 4);
          block.sign3 = { x: sx + 6, y: wallTop + 4 };
          // An animated neon tube over the shopfront.
          const strip = STRIPS[block.sign % STRIPS.length];
          const img = this.add.image(block.x * TILE + 2, wallTop + 2,
            'anim', fr('anim', strip[0], strip[1])).setOrigin(0, 0);
          this.trim.add(img);
          this.screens.push({ img, strip, period: 1.1, delay: block.x * 0.4 });
          block.lit = { x: (block.x + block.w / 2) * TILE, y: wallTop + 14 };
        }
        // Roof furniture that carries type: a billboard on posts, a fascia sign
        // along the parapet, a tag sprayed where the wall meets the pavement.
        if (block.board >= 0) {
          const b = BILLBOARDS[block.board];
          this.stamp(this.trim, 'signs', b[0], b[1], Math.min(b[2], block.w), b[3],
            block.x * TILE + 2, (top + 1) * TILE - 6);
        }
        if (block.fascia >= 0) {
          const f = FASCIA[block.fascia];
          this.stamp(this.trim, 'signs', f[0], f[1], Math.min(f[2], block.w), f[3],
            block.x * TILE + 1, wallTop - 8);
        }
        if (block.tag >= 0) {
          const t = GRAFFITI[block.tag];
          this.stamp(this.trim, 'signs', t[0], t[1], Math.min(t[2], block.w), t[3],
            block.x * TILE + 3, R.base * TILE + 2, 0xa9b6d6);
        }

        block.top = top;
        block.roofH = roofH;
      }

      // The lane between two buildings: nothing but dark asphalt going back,
      // one dumpster, a tag, and a single lamp deep in it. Overlap and a hole
      // in the terrace are the two cheapest depth cues there are.
      paintAlley(block, R) {
        const x = block.x * TILE;
        const w = block.w * TILE;
        this.mid.add(this.add.rectangle(x, (R.backPave + 1) * TILE, w,
          (R.base - R.backPave) * TILE, 0x0d1428, 0.55).setOrigin(0, 0));
        this.stamp(this.near, 'props', 4, 2, 1, 1, x + 2, (R.base - 1) * TILE, NIGHT_PROP);
        this.stamp(this.near, 'props', 9, 6, 1, 1, x + 2, R.base * TILE, NIGHT_PROP);
        this.stamp(this.trim, 'signs', 0, 3, 2, 1, x, (R.base - 3) * TILE, 0x8f9cc4);
        block.lit = { x: x + w / 2, y: (R.base - 2) * TILE };
        block.alley = true;
      }

      // The street: lamps along the pavement, the furniture that makes a
      // pavement look walked on, and the wet smears that are the cheapest
      // "night city" cue there is — every sign reflected down the tarmac.
      paintStreet(R) {
        const lampTop = R.frontPave - 4;
        this.lampSpots = [];
        for (let c = 2; c < COLS - 1; c += 7) {
          this.stamp(this.near, 'props', 6, 9, 3, 5, (c - 1) * TILE, lampTop * TILE, NIGHT_PROP);
          this.lampSpots.push({ x: (c - 1) * TILE + 10, y: lampTop * TILE + 12 });
          this.lampSpots.push({ x: (c + 1) * TILE + 6, y: lampTop * TILE + 12 });
        }
        const FURNITURE = [
          [4, 2, 1, 1], [5, 2, 1, 1], [6, 2, 1, 1],       // bins
          [9, 6, 2, 2],                                    // crates
          [11, 7, 3, 1],                                   // bench
          [7, 1, 1, 2], [9, 1, 1, 2], [10, 1, 1, 2],       // vending machines
          [9, 12, 1, 1],                                   // cone
        ];
        for (let i = 0; i < 14; i++) {
          const f = pick(FURNITURE, i * 11 + 3);
          const c = 1 + Math.floor(hash01(i * 23 + 7) * (COLS - 4));
          const row = i % 4 === 0 ? R.nearPave[0] : R.frontPave;
          this.stamp(this.near, 'props', f[0], f[1], f[2], f[3],
            c * TILE, (row + 1) * TILE - f[3] * TILE, NIGHT_PROP);
        }
        // Reflections. A vertical smear per sign, stretched down the wet road
        // at a fraction of the alpha — the depth playbook's rule 11, and the
        // thing that stops the tarmac reading as a black bar.
        const wet = this.add.graphics().setDepth(2.5);
        wet.setBlendMode(Phaser.BlendModes.ADD);
        for (const block of this.plan.front) {
          if (!block.sign3) continue;
          const cx = block.sign3.x;
          const top = R.frontPave * TILE;
          const tall = (R.road[1] + 1) * TILE - top;
          for (let i = 0; i < 9; i++) {
            wet.fillStyle(i % 2 ? COOL : WARM, 0.05 * (1 - i / 9));
            wet.fillRect(cx - 3 - (i % 3), top + i * (tall / 9), 6 + (i % 3) * 2, tall / 9);
          }
        }
      }

      paintWalkers(R) {
        const lanes = [
          { row: R.frontPave, right: true, speed: 13, span: LW },
          { row: R.frontPave, right: false, speed: 9, span: LW },
          { row: R.nearPave[0], right: false, speed: 16, span: LW },
          { row: R.backPave, right: true, speed: 7, span: LW, behind: true },
        ];
        for (let i = 0; i < 9; i++) {
          const lane = lanes[i % lanes.length];
          const sheet = 'walk' + (1 + (i % 5));
          const img = this.add.image(0, (lane.row + 1) * TILE - 2, sheet, 0)
            .setOrigin(0.5, 1)
            .setTint(lane.behind ? NIGHT_FAR : NIGHT_PEOPLE);
          (lane.behind ? this.backLife : this.people).add(img);
          this.walkers.push({ img, lane, i });
        }
      }

      // Warm light where warm light belongs: under every lamp head, over every
      // lit window bank, and a red wash on whichever project is in alarm. Rule
      // 9 — a practical lights its own facade and the ground beneath it, and
      // nothing further.
      paintLights() {
        this.lights.setBlendMode(Phaser.BlendModes.ADD);
        this.staticLights = () => {
          const g = this.lights;
          const glow = this.phase.glow;
          g.clear();
          for (const spot of (this.lampSpots || [])) {
            // The pool the lamp throws on the pavement, then the lamp itself.
            // Rule 9: a practical lights its own patch of ground and nothing
            // further, so the falloff is short and the cone is wide.
            this.glow(g, LAMP, spot.x, spot.y + 62, 26, 15, 0.34 * glow, 7);
            this.glow(g, LAMP, spot.x, spot.y, 7, 5, 0.6, 4);
          }
          for (const block of this.plan.front) {
            if (!block.lit) continue;
            if (block.alley) { this.glow(g, COOL, block.lit.x, block.lit.y, 14, 24, 0.2, 6); continue; }
            this.glow(g, WARM, block.lit.x, block.lit.y, 24, 15, 0.17 * glow, 6);
            if (block.sign3) this.glow(g, COOL, block.sign3.x, block.sign3.y + 20, 12, 22, 0.24, 5);
          }
          if (this.alarmGlow) {
            const b = this.alarmGlow;
            this.glow(g, ALARM, (b.x + b.w / 2) * TILE, (b.top + 3) * TILE,
              b.w * TILE * 0.8, 6 * TILE, 0.22 * this.phase.alarm, 7);
          }
        };
      }

      // --- composition 2: the office floor --------------------------------------

      buildOffice() {
        const zoneW = LW / ZONES.length;
        const WALL_H = 2;               // rows 0-1: the back wall
        const DESK = 4;                 // rows 4-5: the desk bank
        const PROP = 9;                 // rows 9-10: each zone's own kit
        const LABEL = ROWS - 4;         // the bay name, painted on the floor
        const FRONT = ROWS - 2;         // the foreground counter
        const zx = (z) => Math.round(z * zoneW);
        const zc = (z) => Math.round(z * zoneW + zoneW / 2);
        const cell = (z, dx) => Math.round(zc(z) / TILE) + dx;

        // Floor and back wall, both from the packs. The floor is the interior
        // pack's pale slab (LimeZu's own is drawn for daylight and fights the
        // night); the wall is LimeZu's room builder, which has the ceiling
        // return that makes a room read as a room from above.
        for (let r = WALL_H; r < ROWS; r++) {
          for (let c = 0; c < COLS; c++) {
            const t = pick([[3, 6], [4, 6], [5, 6], [4, 7], [3, 8], [4, 8]], r * 41 + c * 17);
            this.tile(this.ground, 'floors', t[0], t[1], c * TILE, r * TILE, NIGHT_ROOM);
          }
        }
        for (let c = 0; c < COLS; c++) {
          this.tile(this.ground, 'room', 8, 17, c * TILE, 0, WALL_TINT);
          this.tile(this.ground, 'room', 8, 18, c * TILE, TILE, WALL_TINT);
        }
        this.ground.add(this.add.rectangle(0, WALL_H * TILE, LW, 3, 0x0a1024, 0.55).setOrigin(0, 0));

        // Wall furniture: server racks, a wall screen, LimeZu's world map.
        for (let c = 1; c < COLS - 2; c += 4) {
          this.tile(this.mid, 'inside', 7 + (c % 8), 5, c * TILE, (WALL_H - 1) * TILE, NIGHT_ROOM);
        }
        this.stamp(this.mid, 'lz', 11, 66, 2, 2, 3 * TILE, 0, NIGHT_ROOM);
        this.stamp(this.mid, 'inside', 12, 11, 2, 1, (COLS - 12) * TILE, 6, NIGHT_ROOM);

        // Bay partitions: a low cubicle wall between zones, seen from above as
        // a lit top edge and the shadow it throws. Without them six desks in a
        // row are six desks in a row, not six stages of a pipeline.
        const floor = this.add.graphics().setDepth(1);
        for (let z = 1; z < ZONES.length; z++) {
          floor.fillStyle(0x2b3557, 1);
          floor.fillRect(zx(z) - 2, WALL_H * TILE + 3, 4, (LABEL - WALL_H) * TILE);
          floor.fillStyle(0x9fb2e0, 0.5);
          floor.fillRect(zx(z) - 2, WALL_H * TILE + 3, 4, 1);
          floor.fillStyle(0x0a1024, 0.45);
          floor.fillRect(zx(z) + 2, WALL_H * TILE + 4, 3, (LABEL - WALL_H) * TILE);
        }
        // A cable run along the floor, zone to zone.
        floor.fillStyle(0x1b2440, 0.9);
        floor.fillRect(0, (PROP - 1) * TILE + 6, LW, 2);

        // The bay names, painted on the floor at the front of each bay where
        // nothing on the wall's own chrome can cover them.
        const labels = this.add.graphics().setDepth(3);
        for (let z = 0; z < ZONES.length; z++) {
          const w = textWidth(ZONES[z]);
          const x = Math.round(zc(z) - w / 2);
          const y = LABEL * TILE + 5;
          labels.fillStyle(0x0d1730, 0.5);
          labels.fillRect(x - 4, y - 3, w + 8, GLYPH_H + 6);
          labels.fillStyle(z === 2 ? 0xffd166 : 0x7ad6ec, 0.35);
          labels.fillRect(x - 4, y + GLYPH_H + 2, w + 8, 1);
          drawText(labels, ZONES[z], x, y, z === 2 ? 0xffd166 : 0xa8e8ff, 0.95);
        }

        // The desks, and the agents at them. LimeZu's seated pose is drawn from
        // behind and above, so the desk in front hides the legs and the pose
        // needs nothing but a two-frame breath.
        const SITTERS = ['sitA', 'sitB', 'sitC', 'sitD', 'sitA', 'sitB'];
        for (let z = 0; z < ZONES.length; z++) {
          const dx = cell(z, -1);
          // A rack against the wall behind, the console desk in front of it,
          // and the agent seated at that console with the desk over their legs.
          this.stamp(this.mid, 'inside', 11, 6, 2, 2, dx * TILE, (DESK - 2) * TILE - 4, NIGHT_ROOM);
          this.stamp(this.mid, 'inside', 11, 12, 2, 2, dx * TILE, DESK * TILE + 4, NIGHT_ROOM);
          // PUSH is between shifts: its desk is lit and empty, which is a fact
          // about the pipeline and not an omission.
          if (z === ZONES.length - 1) continue;
          const img = this.add.image(dx * TILE + TILE - SIT_INSET, (DESK + 1) * TILE - 3,
            SITTERS[z], 0).setOrigin(0, 0).setTint(NIGHT_PEOPLE);
          this.people.add(img);
          this.sitters.push({ img, delay: z * 0.7 });
        }

        // Each bay's own kit, so the six read as six different jobs.
        this.stamp(this.mid, 'lz', 1, 62, 3, 2, zx(0) + 12, (PROP - 1) * TILE, NIGHT_ROOM);
        this.stamp(this.mid, 'inside', 11, 12, 2, 2, zx(1) + 14, PROP * TILE - 8, NIGHT_ROOM);
        this.stamp(this.mid, 'inside', 13, 3, 2, 2, zx(3) + 14, PROP * TILE - 8, NIGHT_ROOM);
        this.stamp(this.mid, 'lz', 12, 44, 1, 3, zx(5) + 20, (PROP - 1) * TILE, NIGHT_ROOM);
        this.stamp(this.mid, 'inside', 10, 6, 1, 2, zx(5) + 52, PROP * TILE, NIGHT_ROOM);

        // The GATE bench: a row of green lamps and one red. Drawn rather than
        // stamped — no pack ships a pass/fail rig, and this is the one prop the
        // whole room is about.
        const gate = this.add.graphics().setDepth(3);
        const gx = zx(2) + 12;
        const gy = PROP * TILE;
        const gw = Math.round(zoneW) - 24;
        gate.fillStyle(0x0a1024, 0.5);
        gate.fillRect(gx + 2, gy + 15, gw, 4);
        gate.fillStyle(0x323e63, 1);
        gate.fillRect(gx, gy, gw, 13);
        gate.fillStyle(0x9fb2e0, 0.55);
        gate.fillRect(gx, gy, gw, 1);
        gate.fillStyle(0x1a2340, 1);
        gate.fillRect(gx, gy + 11, gw, 4);
        this.gateLamps = [];
        for (let i = 0; i < 6; i++) {
          this.gateLamps.push({ x: gx + 7 + i * Math.floor((gw - 12) / 5), y: gy + 5, bad: i === 4 });
        }

        // The DEMO screen: the pack's own six-frame wall monitor, on a stand.
        const sx = zx(4) + Math.round(zoneW / 2) - TILE;
        this.demo = this.add.image(sx, PROP * TILE - 10, 'anim', fr('anim', 0, 8)).setOrigin(0, 0);
        this.mid.add(this.demo);
        this.screens.push({ img: this.demo, strip: [0, 8, 2, 6], period: 0.9, delay: 0 });

        // The door, the agent on the phone at it, and the question over their
        // head — the wall's `waiting` state, staged.
        const doorX = (COLS - 4) * TILE;
        this.stamp(this.mid, 'props', 10, 13, 1, 1, doorX, TILE, NIGHT_ROOM);
        this.phoneImg = this.add.image(doorX, WALL_H * TILE + 1, 'phone', 2)
          .setOrigin(0, 0).setTint(NIGHT_PEOPLE);
        this.people.add(this.phoneImg);
        this.question = this.add.graphics().setDepth(5);

        // ...and one agent crossing the floor, so the room is not a photograph.
        this.roamer = this.add.image(0, (FRONT - 1) * TILE, 'run', 0)
          .setOrigin(0.5, 1).setTint(NIGHT_PEOPLE);
        this.people.add(this.roamer);

        // The foreground: a counter along the bottom of the frame with a plant
        // and a bench on it. The depth playbook's rule 12 — every shot gets a
        // near-black-but-not-black occluder crossing the bottom of the frame,
        // and it is what stops a floor plan reading as a floor plan.
        const front = this.add.graphics().setDepth(6);
        front.fillStyle(0x0d1428, 0.5);
        front.fillRect(0, FRONT * TILE - 6, LW, 6);
        front.fillStyle(0x27314e, 1);
        front.fillRect(0, FRONT * TILE, LW, LH - FRONT * TILE);
        front.fillStyle(0x94a8d8, 0.45);
        front.fillRect(0, FRONT * TILE, LW, 1);
        this.stamp(this.near, 'lz', 1, 51, 3, 2, 2 * TILE, FRONT * TILE - 22, NIGHT_ROOM);
        this.stamp(this.near, 'lz', 14, 44, 1, 3, (COLS - 8) * TILE, FRONT * TILE - 44, NIGHT_ROOM);
        this.stamp(this.near, 'lz', 12, 53, 1, 1, (COLS - 15) * TILE, FRONT * TILE - 14, WARM);
        this.stamp(this.near, 'lz', 4, 51, 3, 2, (COLS - 24) * TILE, FRONT * TILE - 22, NIGHT_ROOM);
        // The aisle between the bays and the counter, dressed: a spare chair
        // per bay and a couple of crates, so the walk plane is not an empty
        // field of floor tiles.
        for (let z = 0; z < ZONES.length; z++) {
          this.tile(this.mid, 'inside', 7 + (z % 4), 11, zx(z) + 20, (LABEL - 2) * TILE, NIGHT_ROOM);
        }
        this.stamp(this.mid, 'inside', 9, 6, 2, 2, zx(1) + 44, (LABEL - 2) * TILE - 6, NIGHT_ROOM);
        this.stamp(this.mid, 'lz', 12, 44, 1, 3, zx(3) + 48, (LABEL - 3) * TILE, NIGHT_ROOM);

        this.lights.setBlendMode(Phaser.BlendModes.ADD);
        this.staticLights = () => {
          const g = this.lights;
          g.clear();
          for (let z = 0; z < ZONES.length; z++) {
            // A warm desk lamp per bay against the room's cool wash: the one
            // warm mass in the composition, exactly as on the street.
            this.glow(g, WARM, zc(z), (DESK + 1) * TILE + 4, 40, 26, 0.34 * this.phase.glow, 8);
            this.glow(g, COOL, zc(z), DESK * TILE + 8, 14, 9, 0.42, 5);
          }
          for (const lamp of this.gateLamps) {
            const a = lamp.bad ? 0.45 + 0.55 * this.phase.alarm : 0.8;
            this.glow(g, lamp.bad ? ALARM : 0x4ee08a, lamp.x, lamp.y, 6, 5, a, 4);
          }
          this.glow(g, COOL, this.demo.x + TILE, this.demo.y + TILE, 30, 20, 0.30, 6);
          this.glow(g, WARM, (COLS - 15) * TILE + 8, FRONT * TILE - 8, 16, 10, 0.35, 5);
        };
      }

      // --- the frame ------------------------------------------------------------

      apply(model) {
        if (office) return;
        const key = planKeyOf(model);
        if (key === this.planKey) return;
        // The block's shape is a fact about the wall, so a new fact rebuilds it
        // rather than nudging what is standing. It happens once per change.
        this.scene.restart();
      }

      spot() { /* the carousel does not reach into this world yet */ }

      step() {
        const at = clock ? clock() : 0;
        const phase = phaseAt(at, { reducedMotion: still.matches });
        // A frozen wall is drawn once and then left alone: same phase, same
        // frame, no work.
        if (phase.still && this.phase.still && this.painted) return;
        this.phase = phase;
        this.painted = true;

        for (const neon of this.neons) {
          const a = tubeAt(phase, neon.delay);
          for (const part of neon.parts) part.setAlpha(a);
        }
        for (const screen of this.screens) {
          const [col, row, w, frames] = [screen.strip[0], screen.strip[1],
            screen.strip[2] || 1, screen.strip[3] || 3];
          const f = cycleAt(phase, screen.period * frames, frames, screen.delay);
          screen.img.setFrame(fr('anim', col + f * w, row));
        }
        for (const walker of this.walkers) {
          const w = walkerAt(phase, walker.i, walker.lane);
          walker.img.setX(w.x);
          walker.img.setFrame(w.dir * 4 + w.step);
        }
        for (const sitter of this.sitters) {
          sitter.img.setFrame(cycleAt(phase, 3.2, 2, sitter.delay) * 6);
        }
        if (this.alarmParts.length) {
          const tint = mixColour(NIGHT_MID, ALARM, 0.35 + 0.45 * phase.alarm);
          for (const part of this.alarmParts) part.setTint(tint);
        }
        if (office) this.stepOffice(phase);
        if (this.staticLights) this.staticLights();
        this.paintWeather(phase);
      }

      stepOffice(phase) {
        // The phone call: LimeZu's own nine-frame loop, and a drawn "?" that
        // bobs with it.
        this.phoneImg.setFrame(cycleAt(phase, 3.6, 9, 0));
        const bob = phase.still ? 0 : Math.round(swing(phase.t, 1.4) * 2);
        const qx = this.phoneImg.x + 18;
        const qy = this.phoneImg.y + 6 - bob;
        this.question.clear();
        this.question.fillStyle(0x101c38, 0.7);
        this.question.fillRect(qx - 2, qy - 2, 10, 14);
        drawText(this.question, '?', qx, qy, 0xffd166, 1, 2);
        // The roamer walks the aisle and turns round at each end.
        const span = LW - 80;
        const u = phase.still ? 0.35 : swing(phase.t, 26);
        this.roamer.setX(Math.round(40 + u * span));
        const right = phase.still ? true : swing(phase.t + 0.01, 26) > u;
        const step = phase.still ? 0 : Math.floor(loop(phase.t, 0.72, 0) * 6) % 6;
        this.roamer.setFrame((right ? 18 : 12) + step);
      }

      paintWeather(phase) {
        const g = this.weather;
        g.clear();
        if (!this.raindrops || !phase.rain) return;
        for (let i = 0; i < this.raindrops; i++) {
          const drop = rainAt(phase, i, this.raindrops);
          g.fillStyle(drop.near ? 0xbcd8ff : 0x8fb4e6, drop.a);
          g.fillRect(drop.x, drop.y, 1, drop.len);
        }
      }
    }

    const game = new Phaser.Game({
      type: Phaser.AUTO,
      scale: {
        mode: Phaser.Scale.NONE,
        parent: host,
        expandParent: false,
        width: W,
        height: H,
        zoom: 1 / DPR,
      },
      render: {
        // Match the established canvas-world renderer config. The camera still
        // scales by a whole number and every draw lands on a whole device pixel.
        smoothPixelArt: true,
        roundPixels: true,
        powerPreference: 'low-power',
      },
      fps: { limit: 30 },
      audio: { noAudio: true },
      banner: false,
      backgroundColor: 0x121a2e,
      scene: TopdownScene,
    });

    let relayout = 0;
    window.addEventListener('resize', () => {
      clearTimeout(relayout);
      relayout = setTimeout(() => {
        const size = stageSize();
        const dpr = ratio();
        if (!size.w || !size.h) return;
        if (Math.round(size.w * dpr) === W && Math.round(size.h * dpr) === H) return;
        measure(size.w, size.h, dpr);
        game.scale.resize(W, H);
        game.scale.setZoom(1 / DPR);
        if (live) live.scene.restart();
      }, 400);
    });

    still.addEventListener('change', () => { if (live) { live.painted = false; live.step(true); } });

    return {
      render(model) {
        pending = model;
        if (live) live.apply(model);
      },
      spot(runId) {
        if (live) live.spot(runId);
      },
      tick() { if (live) live.step(true); },
      game,
    };
  }

  // Animated neon strips on the animations sheet: [col, row, frameWidth,
  // frames]. Every one of them is a three-frame tube except the wall screen.
  const STRIPS = [
    [0, 0, 1, 3], [3, 0, 1, 3], [6, 0, 1, 3],
    [0, 2, 1, 3], [3, 2, 1, 3], [3, 4, 1, 3], [0, 4, 1, 3],
  ];

  // The only two facts this world reads off the wall: how many project
  // buildings the block has, and which of them is shouting. A change in either
  // is what rebuilds the block; anything else about a run is ignored here.
  function planKeyOf(model) {
    const towers = (model && Array.isArray(model.towers)) ? model.towers : [];
    return towers.length + ':' + towers.map((t) => (t && t.alarm ? 1 : 0)).join('');
  }

  return {
    create, measure, grid, phaseAt, cycleAt, tubeAt, walkerAt, rainAt,
    hash01, cityPlan, cityRows, frontRow, backRow, planKeyOf,
    textWidth, PACK_FILES, SHEETS, ZONES, TILE, REF_W, REF_H,
  };
}));
