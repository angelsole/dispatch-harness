'use strict';
// The city's third body, and a spike: a straight-on synthwave skyline built out
// of the bought pixel-art packs in wall/private/, drawn by the same vendored
// Phaser 4 the ?world=canvas city uses. Opened with ?world=sideview, and — for
// the second composition — ?world=sideview&scene=room.
//
// This is a LOOK TEST, not a port. It implements the renderer seam (render /
// spot / tick) so it can hang off wall.js unchanged, but it reads only two
// things off the scene model: how many project towers the block has
// (scene.towers.length) and which one is shouting (scene.towers[i].alarm).
// Everything else is a hand-composed still that exists to be screenshotted and
// judged. When the verdict is in, this file goes in the bin — so it is written
// for legibility of the picture, not for the thirty-day uptime world-canvas.js
// is written for.
//
// The rules it does keep, because they are the wall's and not this spike's:
//
//   Nothing periodic keeps its own state. Every drifting plane, stepping frame,
//   climbing car, falling drop and flickering screen is a pure function of the
//   wall clock — phaseAt() — so two screens in a room are on the same beat with
//   no byte passing between them, and reduced motion is a still frame rather
//   than a slow one. There is no Math.random in here: variation comes out of
//   jitter(), an integer hash, so the same wall draws the same city twice.
//
//   Nothing loads that is not on the list. FILES below is every byte this world
//   can ask for, all of it through the one guarded /private/ route in
//   wall/server.js, all of it same-origin. The packs themselves are gitignored
//   (see wall/private/README.md): they are licensed to this machine and they do
//   not travel.
//
//   The grid is 480x270 logical pixels at an INTEGER camera zoom — 4x on the
//   1920x1080 TV. Pixel art scaled by 3.7 is mush, so the zoom is floored and
//   the leftovers are letterbox, never a fractional stretch.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallSideviewWorld = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the frame ----------------------------------------------------------------
  // Everything below is in these units. The packs' parallax planes are 480x270
  // themselves, which is why the frame is: one plane is one screen.
  const GW = 480;
  const GH = 270;
  const HORIZON = 216;       // where the near buildings meet the water
  const MAX_ZOOM = 8;        // past this a 480x270 frame is bigger than any panel

  // --- the declared list --------------------------------------------------------
  // The pack directory names are the artist's own, misspellings and all, because
  // wall/private/ is a verbatim copy of what was bought — see its README.
  const PACK = 'cyberpunk-rooftops';
  const FRAMES = 16;         // planes 1 and 4 are animated; the rest are stills
  const planeFile = (n, f) =>
    `${PACK}/Backgroud/BACKGROUND (${n})/Backgroud (${n}) ${f}.png`;

  // key -> path under wall/private/. Nothing else is ever fetched.
  const FILES = (() => {
    const list = [
      ['sky', planeFile(6, 1)],      // dusk gradient and clouds
      ['far', planeFile(5, 1)],      // the flat far silhouette
      ['mid', planeFile(3, 1)],      // the neon district — the hero plane
      ['near', planeFile(2, 1)],     // the dark near row
      ['terrain', `${PACK}/Terrain/Terrain.png`],
      ['crew-a', `${PACK}/character/Player 96X96 (1).png`],
      ['crew-b', `${PACK}/Character (2)/Player 96X96 (1).png`],
    ];
    for (let i = 0; i < FRAMES; i++) list.push([`road-${i}`, planeFile(4, i + 1)]);
    for (let i = 0; i < FRAMES; i++) list.push([`water-${i}`, planeFile(1, i + 1)]);
    return list;
  })();

  // One guarded route, one encoded segment at a time: the packs' spaces and
  // parentheses survive, and a slash in a name could never smuggle itself
  // through as a path separator.
  const url = (rel) => '/private/' + rel.split('/').map(encodeURIComponent).join('/');

  // --- the palette --------------------------------------------------------------
  // Sampled off the packs, floored above pure black on purpose: the darkest
  // value in either composition is the room's own shadow, not #000.
  const NIGHT = 0x241d38;      // the letterbox and the sky behind everything
  const HAZE = 0x7a5670;       // light-pollution violet — the tint between planes
  const TEAL = 0x36d6c8;
  const PINK = 0xd86ab0;
  const WARM = 0xf2a05a;
  const WINDOW_WARM = 0xffc27d;
  const ALARM = 0xff5a5a;
  const GREEN = 0x6ee7a0;
  const ROOM_WALL = 0x4a4260;   // the room's cool ambient
  const ROOM_FLOOR = 0x2e2743;
  const MONO = 'ui-monospace, "SF Mono", Menlo, "DejaVu Sans Mono", monospace';

  const hex = (n) => '#' + n.toString(16).padStart(6, '0');
  const rgb = (css) => parseInt(String(css || '#7fd4ec').slice(1), 16) || 0x7fd4ec;

  // --- variation without randomness ---------------------------------------------
  // Every "pick one" and "nudge this a bit" below comes through here. It is an
  // integer hash, so a wall that reloads redraws the same city, and two screens
  // in the same room draw the same one.
  function jitter(seed, salt) {
    let h = Math.imul((seed | 0) + 0x9e3779b9, 0x85ebca6b);
    h = Math.imul(h ^ (h >>> 13) ^ ((salt | 0) + 0x165667b1), 0xc2b2ae35);
    return ((h ^ (h >>> 16)) >>> 8) / 0x1000000;
  }
  function seedOf(text) {
    let h = 2166136261;
    for (let i = 0; i < String(text).length; i++) {
      h = Math.imul(h ^ String(text).charCodeAt(i), 16777619);
    }
    return h >>> 0;
  }
  const mod = (v, n) => ((v % n) + n) % n;

  // --- the clock ----------------------------------------------------------------
  // 0..1 across one period, and a there-and-back over two, exactly as
  // world-canvas.js defines them — the two bodies share an idiom even where they
  // share nothing else.
  const loop = (t, period, delay) => mod((t - (delay || 0)) / period, 1);
  function swing(t, period) {
    const u = mod(t / period, 2);
    return u < 1 ? u : 2 - u;
  }

  // How far each plane wanders, and how slowly: ±1 px at the back, ±6 at the
  // front, every period a different prime-ish number of seconds so no two planes
  // ever return to their start together and the drift never reads as a loop.
  const PLANES = [
    { key: 'sky', reach: 1, period: 190 },
    { key: 'far', reach: 2, period: 151 },
    { key: 'road', reach: 3, period: 127 },
    { key: 'mid', reach: 4, period: 103 },
    { key: 'near', reach: 5.5, period: 79 },
    { key: 'water', reach: 6, period: 61 },
  ];

  // Everything that moves in either composition, at one second of the clock.
  // Reduced motion pins the lot to t = 0, which is a lit city standing still.
  function phaseAt(seconds, opts) {
    const frozen = !!(opts && opts.reducedMotion);
    const t = frozen ? 0 : Number(seconds) || 0;
    return {
      still: frozen,
      t,
      drift: PLANES.map((p) => (frozen ? 0 : Math.round((swing(t, p.period) * 2 - 1) * p.reach))),
      // The two animated planes step their 16 frames off the clock rather than
      // off a Phaser animation, for the same reason everything else here does:
      // a page opened mid-shift joins the same frame every other page is on.
      road: Math.floor(loop(t, 2.4) * FRAMES) % FRAMES,
      water: Math.floor(loop(t, 3.2) * FRAMES) % FRAMES,
      idle: Math.floor(loop(t, 1.6) * 10) % 10,
      klaxon: frozen ? 0.55 : 0.2 + 0.8 * swing(t, 1.1),
      ask: frozen ? 1 : (swing(t, 1.4) > 0.35 ? 1 : 0.15),
    };
  }

  // A lit car on a shaft: 0 at the street, 1 at the roof, and a hold at each
  // end so it reads as stopping rather than bouncing.
  function carAt(phase, delay, period) {
    if (phase.still) return 0.62;
    const u = swing(phase.t - delay, period);
    return u < 0.12 ? 0 : u > 0.88 ? 1 : (u - 0.12) / 0.76;
  }
  // One screen's flicker: mostly on, with a shallow dip on its own beat.
  const flickerAt = (phase, delay) =>
    (phase.still ? 0.88 : 0.7 + 0.3 * swing(phase.t + delay, 1.3 + (delay % 7) * 0.31));

  // --- the cuts -----------------------------------------------------------------
  // Sub-rectangles of the pack sheets, added to the loaded textures as named
  // frames — which is what an atlas is, minus the JSON. Nothing is repacked and
  // nothing is written to disk: the source pixels are the ones the artist drew.

  // Eight buildings lifted out of the district plane, each as a CROWN (roof,
  // spire, top floors) and a BODY (a clean band of storeys). A project tower is
  // its crown with its body stacked under it as many times as it needs to be
  // taller than the district — the same trick the plane itself is drawn with.
  const KINDS = [
    { crown: [36, 28, 26, 34], body: [36, 64, 26, 26] },
    { crown: [127, 45, 19, 31], body: [127, 78, 19, 24] },
    { crown: [200, 77, 18, 31], body: [200, 110, 18, 24] },
    { crown: [456, 62, 24, 32], body: [456, 96, 24, 24] },
    { crown: [352, 81, 12, 31], body: [352, 114, 12, 22] },
    { crown: [328, 113, 14, 25], body: [328, 140, 14, 22] },
    { crown: [391, 111, 16, 27], body: [391, 140, 16, 22] },
    { crown: [84, 118, 12, 24], body: [84, 142, 12, 20] },
  ];

  // The terrain sheet: walls, decks, girders, terminals, machines. Names are
  // what they are in the picture, not what they are in the sheet.
  const TERRAIN = {
    wall: [0, 12, 96, 126],
    trim: [0, 0, 96, 12],
    deck: [0, 140, 96, 19],
    pane: [139, 22, 78, 54],       // a window frame with a transparent opening
    girder: [2, 173, 158, 52],
    rail: [32, 238, 96, 17],
    cableA: [96, 30, 34, 18],
    cableB: [96, 63, 34, 20],
    termA: [197, 175, 22, 52],
    termB: [227, 177, 24, 50],
    termC: [330, 178, 30, 46],
    console: [366, 155, 44, 70],
    screen: [289, 161, 32, 30],
    shelf: [287, 200, 34, 24],
    rackA: [419, 192, 24, 33],
    rackB: [443, 192, 38, 29],
    vent: [261, 254, 60, 36],
    tank: [332, 246, 38, 45],
    pipes: [161, 247, 64, 44],
  };
  // Where the lit glass is inside each terminal, so a flicker lands on the
  // screen rather than washing the whole cabinet.
  const GLASS = {
    termA: [3, 6, 15, 12], termB: [4, 5, 15, 11], termC: [5, 6, 19, 12],
    console: [4, 4, 36, 34], screen: [4, 4, 24, 22],
    rackA: [4, 5, 15, 21], rackB: [4, 4, 30, 18],
  };
  const PANE_HOLE = [5, 8, 67, 37];   // the transparent opening inside `pane`

  // The hero sheets are a 10x19 grid of 96x96 cells; row 0 is a ten-frame idle.
  // These are the tight bounds of the figure inside a cell, so a person can be
  // placed by their feet instead of by an empty box.
  const CREW_CELL = 96;
  const CREW_CUT = [34, 54, 30, 42];
  const CREW_IDLE = 10;

  // --- the world ----------------------------------------------------------------

  function create(opts) {
    const parent = opts.parent;
    const still = opts.still;
    const clock = opts.clock;
    const room = new URLSearchParams(window.location.search).get('scene') === 'room';

    const host = document.createElement('div');
    host.className = 'world';
    host.id = 'world';
    parent.append(host);

    const ratio = () => Math.min(window.devicePixelRatio || 1, 2);
    const size = () => ({
      w: host.clientWidth || window.innerWidth,
      h: host.clientHeight || window.innerHeight,
    });

    const first = size();
    let DPR = Math.min(Math.max(ratio(), 1), 2);
    let W = Math.max(1, Math.round(first.w * DPR));
    let H = Math.max(1, Math.round(first.h * DPR));
    // The whole point of the grid: a whole number of device pixels per art
    // pixel. 1920x1080 at dpr 1 is exactly 4; a Retina laptop at 1440 CSS px is
    // 6. Anything that does not divide is letterbox in NIGHT, not a stretch.
    const zoomFor = (w, h) =>
      Math.min(MAX_ZOOM, Math.max(1, Math.floor(Math.min(w / GW, h / GH))));
    let ZOOM = zoomFor(W, H);

    let live = null;
    let pending = null;
    let pendingSpot = '';

    // Draw the shared furniture of both compositions: the loader, the frames cut
    // out of the sheets, the camera.
    class PackScene extends Phaser.Scene {
      preload() {
        for (const [key, rel] of FILES) this.load.image(key, url(rel));
      }

      // A named frame over an already-loaded texture. Phaser calls this an
      // atlas frame; here it is a cookie cutter over the artist's own sheet.
      cut(texture, name, rect) {
        const tex = this.textures.get(texture);
        if (tex && !tex.has(name)) tex.add(name, 0, rect[0], rect[1], rect[2], rect[3]);
      }

      cutAll() {
        KINDS.forEach((kind, i) => {
          this.cut('mid', `crown-${i}`, kind.crown);
          this.cut('mid', `body-${i}`, kind.body);
        });
        for (const name of Object.keys(TERRAIN)) this.cut('terrain', name, TERRAIN[name]);
        for (const sheet of ['crew-a', 'crew-b']) {
          for (let i = 0; i < CREW_IDLE; i++) {
            this.cut(sheet, `idle-${i}`,
              [i * CREW_CELL + CREW_CUT[0], CREW_CUT[1], CREW_CUT[2], CREW_CUT[3]]);
          }
        }
      }

      // The camera is the only thing that knows about device pixels. Everything
      // a composition draws is in the 480x270 frame, centred, at a whole zoom.
      frameCamera() {
        const cam = this.cameras.main;
        cam.setZoom(ZOOM);
        cam.centerOn(GW / 2, GH / 2);
        cam.setBackgroundColor(NIGHT);
        // How much of the frame is actually on the panel: on a 16:9 wall this is
        // exactly 480x270, and on anything else it is a little more, which the
        // backdrops below are sized to cover rather than leave bare.
        this.view = {
          w: Math.ceil(W / ZOOM), h: Math.ceil(H / ZOOM),
          x: Math.round((GW - Math.ceil(W / ZOOM)) / 2),
          y: Math.round((GH - Math.ceil(H / ZOOM)) / 2),
        };
        return cam;
      }

      // One parallax plane: three copies of a 480-wide painting side by side, so
      // a plane can drift six pixels either way (or sit on a wall wider than
      // 16:9) without ever showing its edge. Cheaper and more predictable than a
      // TileSprite, and setTexture on it is how the animated planes step.
      band(key, depth) {
        const parts = [-1, 0, 1].map((k) =>
          this.add.image(k * GW, 0, key).setOrigin(0, 0).setDepth(depth));
        return {
          parts,
          x(v) { parts.forEach((p, i) => p.setX((i - 1) * GW + v)); },
          set(next) { for (const p of parts) p.setTexture(next); },
          blur(strength) {
            for (const p of parts) {
              p.enableFilters();
              p.filters.internal.addBlur(0, strength, strength, 1);
            }
          },
        };
      }

      // Small pixel type. Authored at an integer size and left to the camera's
      // nearest-neighbour zoom, which is what makes it read as pixel type at all.
      label(x, y, text, colour, size) {
        return this.add.text(x, y, text, {
          fontFamily: MONO,
          fontSize: `${size || 6}px`,
          color: hex(colour),
          resolution: 1,
        }).setOrigin(0.5, 0);
      }
    }

    // --- composition one: the skyline -------------------------------------------

    class SkylineScene extends PackScene {
      constructor() { super('skyline'); }

      create() {
        this.cutAll();
        this.frameCamera();
        this.phase = phaseAt(0, { reducedMotion: true });
        this.towers = [];
        // wall.js can identify the featured run before the pack textures finish
        // loading. Carry that queued choice into the first live scene instead
        // of waiting for the plate to rotate before highlighting any tower.
        this.spotId = pendingSpot;
        const v = this.view;

        // Back to front. The project towers go in FRONT of the district and
        // BEHIND the near row, so their bases are swallowed by the dark
        // buildings on the waterfront and only the part that matters — the mass
        // standing above the skyline — is ever seen.
        this.sky = this.band('sky', 0);
        this.haze(1, 0, 150, 0.18);
        this.far = this.band('far', 2);
        this.haze(3, 90, 130, 0.22);
        this.road = this.band('road-0', 4);
        this.mid = this.band('mid', 6);
        this.haze(7, 120, 110, 0.14);
        this.blockC = this.add.container(0, 0).setDepth(8);
        this.near = this.band('near', 10);
        this.water = this.band('water-0', 12);
        this.wetC = this.add.container(0, 0).setDepth(13);
        this.rainG = this.add.graphics().setDepth(20);
        this.foreground(24);

        // Rule 14, selective sharpness: the two planes behind the district go
        // soft, the district itself stays pin sharp, and the camera's tilt-shift
        // takes the top and bottom of the frame down with it.
        this.sky.blur(0.7);
        this.far.blur(1.2);
        const cam = this.cameras.main;
        // The page this canvas is mounted in already ends with wall.css's .crt
        // layer: scanlines at 26% black over a third of the rows, and a radial
        // that reaches 58% black in the corners. That was tuned against a city
        // drawn in CSS out of near-black stone, and it eats a bought pack that
        // was painted for daylight-ish dusk. So this world grades UP into it
        // rather than adding a second vignette of its own — no bars, no corner
        // darkening, just the lift the overlay is about to take back.
        const grade = cam.filters.internal.addColorMatrix();
        grade.colorMatrix.brightness(1.16).saturate(0.12);
        cam.filters.external.addTiltShift(0.42, 1.1, 0.3, 0.85, 0.85, 0.6);

        live = this;
        if (pending) this.apply(pending);
        this.step(true);
      }

      // Rule 5: a slab of light-pollution violet between plane pairs. It is what
      // stops six paintings of the same city from reading as one flat sticker.
      haze(depth, top, height, alpha) {
        const g = this.add.graphics().setDepth(depth);
        g.fillGradientStyle(HAZE, HAZE, HAZE, HAZE, 0, 0, alpha, alpha);
        g.fillRect(-GW, top, GW * 3, height);
        return g;
      }

      // Rule 12: something near and out of focus crossing the bottom of the
      // frame. The pack's own rooftop girder, tinted into the haze and blurred
      // until it is a shape rather than a detail.
      foreground(depth) {
        const c = this.add.container(0, 0).setDepth(depth);
        for (let i = -1; i < 4; i++) {
          const g = this.add.image(i * 152 - 24, 244, 'terrain', 'girder')
            .setOrigin(0, 0).setTint(0x3a2c52);
          c.add(g);
        }
        c.enableFilters();
        c.filters.internal.addBlur(0, 2.4, 2.4, 1);
        return c;
      }

      // --- the project towers ---------------------------------------------------
      // scene.towers.length of them, drawn out of the district's own buildings
      // and stacked until they stand over it. Everything about one tower — which
      // building it is cut from, how tall, how far along the waterfront, which
      // way its sign leans — comes out of its project name, so a tower keeps its
      // identity between reloads.

      apply(model) {
        this.model = model;
        const towers = (model && model.towers) || [];
        const key = towers.map((t) => `${t.project}:${t.alarm ? 1 : 0}`).join('|');
        if (key === this.key) return;
        this.key = key;
        this.blockC.removeAll(true);
        this.wetC.removeAll(true);
        this.towers = towers.map((tower, i) => this.raise(tower, i, towers.length));
        this.spot(this.spotId);
      }

      raise(tower, i, total) {
        const seed = seedOf(tower.project || `slot-${i}`);
        const kind = seed % KINDS.length;
        const cut = KINDS[kind];
        const w = cut.crown[2];
        const bodyH = cut.body[3];
        // Spread along the waterfront with a nudge each, because a row of towers
        // on even centres is the single loudest tell that a skyline was
        // generated rather than drawn.
        const span = GW - 88;
        const at = total > 1 ? 44 + (span * i) / (total - 1) : GW / 2;
        const x = Math.round(at + (jitter(seed, 3) - 0.5) * 26);
        // Taller than the district by construction: the plane's own mass tops
        // out around y=90, and the shortest of these tops out at y=64.
        const floors = 4 + Math.floor(jitter(seed, 5) * 3);
        const top = HORIZON - cut.crown[3] - floors * bodyH;
        const tint = rgb(tower.sign);
        const c = this.add.container(0, 0);
        this.blockC.add(c);

        const skin = [];
        const crown = this.add.image(x, top, 'mid', `crown-${kind}`).setOrigin(0.5, 0);
        skin.push(crown);
        for (let f = 0; f < floors; f++) {
          const band = this.add.image(x, top + cut.crown[3] + f * bodyH, 'mid', `body-${kind}`)
            .setOrigin(0.5, 0);
          skin.push(band);
        }
        for (const part of skin) c.add(part);

        // A rim of the tower's own sign colour down the lit edge: rule 9, light
        // carries a tower-width and then dies. Two pixels is the whole effect.
        const rim = this.add.graphics();
        rim.fillStyle(tint, 0.5);
        rim.fillRect(x - w / 2, top + 2, 1, HORIZON - top - 2);
        c.add(rim);

        // The vertical neon plate, which is what makes it a PROJECT tower rather
        // than one more building: an outlined box in the pack's sign idiom with
        // the label set one letter per row inside it.
        const name = String(tower.label || tower.project || '').slice(0, 8).toUpperCase();
        const letters = name.split('').join('\n');
        const plateH = name.length * 7 + 6;
        const plateY = top + cut.crown[3] + 6;
        const plate = this.add.graphics();
        plate.fillStyle(0x241d38, 0.86);
        plate.fillRect(x - 5, plateY, 11, plateH);
        plate.lineStyle(1, tint, 0.95);
        plate.strokeRect(x - 5.5, plateY - 0.5, 12, plateH + 1);
        c.add(plate);
        const type = this.label(x + 0.5, plateY + 2, letters, tint, 6).setLineSpacing(1);
        c.add(type);

        // The service shaft, and two lit cars climbing it. Pre-allocated: only
        // their y moves, ever.
        const shaftX = x + w / 2 - 3;
        const shaft = this.add.graphics();
        shaft.fillStyle(0x241d38, 0.55);
        shaft.fillRect(shaftX - 1, top + cut.crown[3], 3, HORIZON - top - cut.crown[3]);
        c.add(shaft);
        const cars = [0, 1].map((k) => {
          const halo = this.add.rectangle(shaftX, HORIZON, 7, 6, WINDOW_WARM, 0.28);
          const car = this.add.rectangle(shaftX, HORIZON, 3, 3, 0xfff2d8, 1);
          c.add(halo); c.add(car);
          return {
            car, halo,
            delay: jitter(seed, 11 + k) * 40,
            period: 16 + jitter(seed, 21 + k) * 14,
          };
        });

        // The alarm: the whole mass tinted, plus a wash that breathes. One tower
        // in a skyline going red is meant to be visible from the far side of the
        // room, so it is the loudest thing in the composition on purpose.
        const wash = this.add.graphics().setVisible(false);
        wash.fillStyle(ALARM, 0.3);
        wash.fillRect(x - w / 2 - 3, top - 4, w + 6, HORIZON - top + 4);
        c.add(wash);
        if (tower.alarm) {
          for (const part of skin) part.setTint(0xff8f8f);
          wash.setVisible(true);
        }

        // Rule 11: the wet plane in front gets a smeared, stretched copy of the
        // tower. Alpha low, scaleY long, and it lives over the water so it reads
        // as reflection rather than as a second building.
        const wet = this.add.container(0, 0).setAlpha(0.22);
        for (const part of skin) {
          const echo = this.add.image(part.x, HORIZON + (HORIZON - part.y), 'mid', part.frame.name)
            .setOrigin(0.5, 1).setFlipY(true).setScale(1, 1.4);
          if (tower.alarm) echo.setTint(0xff8f8f);
          wet.add(echo);
        }
        this.wetC.add(wet);

        return { tower, container: c, skin, wash, cars, wet, alarm: !!tower.alarm };
      }

      // The wall's spotlight, kept honest but cheap: the project being talked
      // about stays lit, the rest of the block steps back.
      spot(runId) {
        this.spotId = runId || '';
        const model = this.model;
        const of = model && model.towers
          ? (model.towers.find((t) => (t.runIds || []).includes(this.spotId)) || {}).project
          : '';
        for (const T of this.towers) {
          const keep = !of || T.alarm || T.tower.project === of;
          T.container.setAlpha(keep ? 1 : 0.62);
          T.wet.setAlpha(keep ? 0.22 : 0.12);
        }
      }

      update() { this.step(false); }

      step(force) {
        const frozen = still.matches;
        if (frozen && !force && this.phase.still) return;
        const phase = phaseAt(clock(), { reducedMotion: frozen });
        this.phase = phase;

        this.sky.x(phase.drift[0]);
        this.far.x(phase.drift[1]);
        this.road.x(phase.drift[2]);
        this.mid.x(phase.drift[3]);
        this.near.x(phase.drift[4]);
        this.water.x(phase.drift[5]);
        this.wetC.setX(phase.drift[5]);
        if (phase.road !== this.roadFrame) {
          this.roadFrame = phase.road;
          this.road.set(`road-${phase.road}`);
        }
        if (phase.water !== this.waterFrame) {
          this.waterFrame = phase.water;
          this.water.set(`water-${phase.water}`);
        }

        for (const T of this.towers) {
          if (T.alarm) T.wash.setAlpha(0.16 + 0.26 * phase.klaxon);
          for (const c of T.cars) {
            const u = carAt(phase, c.delay, c.period);
            const y = Math.round(HORIZON - 6 - u * (HORIZON - T.skin[0].y - 14));
            c.car.setY(y);
            c.halo.setY(y);
          }
        }
        this.paintRain(phase);
      }

      // The one thing in this composition whose geometry is redrawn per frame,
      // and it is a hundred two-pixel lines. Three speeds, so the near drops
      // outrun the far ones and the curtain has depth of its own; under reduced
      // motion it is the t=0 frame, which is rain standing still rather than a
      // dry city.
      paintRain(phase) {
        const g = this.rainG;
        g.clear();
        for (let i = 0; i < 110; i++) {
          const lane = i % 3;
          const speed = 78 + lane * 46;
          const len = 4 + lane * 2.5;
          const y = mod(jitter(i, 1) * GH + phase.t * speed, GH + 40) - 24;
          const x = mod(jitter(i, 2) * (GW + 40) + y * 0.2, GW + 40) - 20;
          g.lineStyle(1, lane === 2 ? 0xe4efff : 0xb8ccea, 0.14 + lane * 0.08);
          g.lineBetween(x, y, x - len * 0.2, y - len);
        }
      }
    }

    // --- composition two: the control room --------------------------------------
    // A side elevation of one room, built from the same packs: terrain for the
    // shell, the prop row for the machines, the hero sheets for the people. Six
    // stations because the pipeline has six floors, and the wall has said so
    // since the first tower was drawn.

    // The room's elevation, top to bottom.
    const STATIONS = ['SETUP', 'IMPLEMENT', 'GATE', 'REVIEW', 'DEMO', 'PUSH'];
    const STATION_X = [64, 132, 200, 268, 336, 404];
    const STATION_KIT = ['termA', 'termB', 'console', 'termC', 'termA', 'termB'];
    const WALL_TOP = 26;        // where the metal panelling starts
    const LEDGE_Y = 100;        // the mezzanine beam that breaks the back wall
    const NAME_Y = 126;         // the station name plates, hung under it
    const FLOOR_Y = 208;        // where feet and cabinets stand
    const DOOR_X = 438;

    class RoomScene extends PackScene {
      constructor() { super('room'); }

      create() {
        this.cutAll();
        this.frameCamera();
        this.phase = phaseAt(0, { reducedMotion: true });
        this.screens = [];
        this.crew = [];
        this.lamps = [];
        const v = this.view;

        // The page's weather is a <canvas> over every world, because every world
        // the wall has had so far has been outdoors. This one is a room, and
        // rain falling through its ceiling is the single fastest way to lose an
        // interior. Hidden rather than removed, and only for this composition.
        const weather = document.querySelector('canvas.rain');
        if (weather) weather.setAttribute('hidden', '');

        this.shell(v);
        this.pane();
        this.bench();
        this.stations();
        this.people();
        this.door();
        this.light(v);

        const cam = this.cameras.main;
        const grade = cam.filters.internal.addColorMatrix();
        grade.colorMatrix.brightness(1.14).saturate(0.08);
        cam.filters.external.addTiltShift(0.5, 0.8, 0.25, 0.7, 0.7, 0.5);

        live = this;
        this.step(true);
      }

      // Walls, ceiling trim, mezzanine beam, floor deck — all of it the pack's
      // own 96-wide metal panelling tiled across. The mezzanine is what stops
      // the back wall from being one flat grey field above the machines.
      shell(v) {
        const g = this.add.graphics().setDepth(-2);
        g.fillStyle(ROOM_WALL, 1);
        g.fillRect(v.x, v.y, v.w, v.h);
        g.fillStyle(0x241d38, 1);
        g.fillRect(v.x, v.y, v.w, WALL_TOP - 12 - v.y);
        g.fillStyle(ROOM_FLOOR, 1);
        g.fillRect(v.x, FLOOR_Y, v.w, GH - FLOOR_Y);
        for (let x = -96; x < v.x + v.w + 96; x += 96) {
          this.add.image(x, WALL_TOP, 'terrain', 'wall').setOrigin(0, 0).setDepth(-1);
          this.add.image(x, WALL_TOP - 12, 'terrain', 'trim').setOrigin(0, 0).setDepth(-1);
          this.add.image(x, LEDGE_Y, 'terrain', 'deck').setOrigin(0, 0).setDepth(3);
          this.add.image(x, FLOOR_Y - 8, 'terrain', 'deck').setOrigin(0, 0).setDepth(6);
        }
        // Floor plates, so the ground is a surface rather than a colour.
        g.lineStyle(1, 0x3d3358, 0.8);
        for (let x = v.x - 24; x < v.x + v.w + 24; x += 24) {
          g.lineBetween(x, FLOOR_Y + 8, x - 10, GH);
        }
        // Cable runs and wall gear, hung on the panelling above the mezzanine.
        for (const [x, name] of [[112, 'cableA'], [252, 'cableB'], [386, 'cableA']]) {
          this.add.image(x, WALL_TOP + 4, 'terrain', name).setOrigin(0, 0).setDepth(0);
        }
        this.add.image(48, 58, 'terrain', 'screen').setOrigin(0, 0).setDepth(1);
        this.screens.push({ g: this.glow(52, 62, 24, 22, TEAL, 2), delay: 17 });
        this.add.image(160, 60, 'terrain', 'rackA').setOrigin(0, 0).setDepth(1);
        this.screens.push({ g: this.glow(164, 65, 15, 21, PINK, 2), delay: 23 });
        this.add.image(196, 64, 'terrain', 'rackB').setOrigin(0, 0).setDepth(1);
        this.screens.push({ g: this.glow(200, 68, 30, 18, PINK, 2), delay: 29 });
        this.add.image(288, 76, 'terrain', 'shelf').setOrigin(0, 0).setDepth(2);
        // Plant, so the room reads as a place that runs on something.
        this.add.image(8, FLOOR_Y - 45, 'terrain', 'tank').setOrigin(0, 0).setDepth(4);
        // A foreground catwalk crossing the bottom of the shot, blurred: the
        // same occluder the skyline gets, doing the same job — telling the eye
        // there is room between it and the wall of machines.
        const fore = this.add.container(0, 0).setDepth(28);
        for (let x = -26; x < GW + 40; x += 152) {
          fore.add(this.add.image(x, 236, 'terrain', 'girder').setOrigin(0, 0).setTint(0x453a66));
        }
        fore.enableFilters();
        fore.filters.internal.addBlur(0, 2.2, 2.2, 1);
      }

      // The window, and the city through it: the same six planes this world
      // draws outside, stamped into a render texture the size of the opening and
      // blurred, so the skyline is out there and out of focus at once.
      pane() {
        const x = 300;
        const y = 40;
        const [ox, oy, ow, oh] = PANE_HOLE;
        const view = this.add.renderTexture(x + ox, y + oy, ow, oh).setOrigin(0, 0).setDepth(0);
        // The opening is a 67x37 hole onto a 480x270 painting, so the arithmetic
        // below picks WHICH 67x37 of it: a stretch of the district's own
        // roofline with dusk over it, rather than the water under it or the
        // empty sky above. draw() puts a texture's CENTRE at the coordinate it
        // is given, which is why the corner we want is subtracted from it.
        const [sx, sy] = [120, 74];
        for (const key of ['sky', 'far', 'mid']) view.draw(key, GW / 2 - sx, GH / 2 - sy);
        view.render();
        view.enableFilters();
        view.filters.internal.addBlur(0, 0.6, 0.6, 1);
        this.add.image(x, y, 'terrain', 'pane').setOrigin(0, 0).setDepth(1);
        // Cold light falling in off it, against everything else in here.
        const spill = this.add.graphics().setDepth(2).setBlendMode(Phaser.BlendModes.ADD);
        spill.fillStyle(TEAL, 0.05);
        spill.fillRect(x + 2, y + 4, 74, 56);
        spill.fillTriangle(x + 8, y + 52, x + 72, y + 52, x + 104, FLOOR_Y);
      }

      // The gate bench: the one station in the pipeline that is a verdict, so it
      // gets its own object in the middle of the room with a row of lamps and
      // one of them red.
      bench() {
        const x = 152;
        const w = 96;
        const top = FLOOR_Y - 15;
        const g = this.add.graphics().setDepth(14);
        g.fillStyle(0x352c50, 1);
        g.fillRect(x, top, w, 15);
        g.fillStyle(0x4b3f70, 1);
        g.fillRect(x, top, w, 3);
        g.lineStyle(1, 0x6a5a92, 0.9);
        g.strokeRect(x + 0.5, top + 0.5, w - 1, 14);
        // Six lamps along its lip: five green and one red, which is the whole
        // story of a gate, told without a word.
        for (let i = 0; i < 6; i++) {
          const lamp = this.add.graphics().setDepth(15);
          const colour = i === 4 ? ALARM : GREEN;
          lamp.fillStyle(colour, 0.24);
          lamp.fillRect(x + 8 + i * 15, top + 3, 8, 8);
          lamp.fillStyle(colour, 1);
          lamp.fillRect(x + 10 + i * 15, top + 5, 4, 4);
          this.lamps.push({ lamp, red: i === 4, delay: i * 2.3 });
        }
      }

      // A pool of additive light. Every warm thing in this room is one of these
      // over a cool one, which is the only reason the room reads warm at all.
      glow(x, y, w, h, colour, depth) {
        const g = this.add.graphics().setDepth(depth).setBlendMode(Phaser.BlendModes.ADD);
        g.fillStyle(colour, 0.34);
        g.fillRect(x, y, w, h);
        g.fillStyle(colour, 0.09);
        g.fillRect(x - 5, y - 4, w + 10, h + 9);
        return g;
      }

      // The bank: one machine per pipeline floor, left to right, each with its
      // name on a plate hung off the mezzanine above it.
      stations() {
        STATIONS.forEach((name, i) => {
          const cx = STATION_X[i];
          const piece = STATION_KIT[i];
          const rect = TERRAIN[piece];
          const y = FLOOR_Y - rect[3];
          const x = Math.round(cx - rect[2] / 2);
          this.add.image(x, y, 'terrain', piece).setOrigin(0, 0).setDepth(5);
          const glass = GLASS[piece];
          this.screens.push({
            g: this.glow(x + glass[0], y + glass[1], glass[2], glass[3],
              piece === 'console' || piece === 'termB' ? GREEN : TEAL, 9),
            delay: i * 5 + 1,
            // The gate console's glass is ten times the area of a terminal's,
            // and an additive pool that size stops being a lit screen and starts
            // being a hole in the wall. Big glass gets less of it.
            gain: piece === 'console' ? 0.5 : 1,
          });
          // The name plate: a hanging strap, a dark plate, the word. Six of
          // these is what turns a machine room into THIS pipeline's room.
          const plate = this.add.graphics().setDepth(8);
          plate.fillStyle(0x6a5a92, 0.8);
          plate.fillRect(cx - 1, LEDGE_Y + 17, 2, 5);
          plate.fillStyle(0x241d38, 0.9);
          plate.fillRect(cx - 27, NAME_Y - 4, 54, 13);
          plate.lineStyle(1, 0x7d6aa8, 0.85);
          plate.strokeRect(cx - 27.5, NAME_Y - 4.5, 55, 14);
          this.label(cx, NAME_Y, name, 0xd8caf2, 6).setDepth(9);
          // Warm spill on the deck under each machine — rule 9 again, and the
          // only warm mass in a cool room.
          this.glow(x - 6, FLOOR_Y - 5, rect[2] + 12, 7, WARM, 6).setAlpha(0.5);
        });
      }

      // Four people, from the two hero sheets, standing at their machines on the
      // pack's own ten-frame idle. The fourth has turned away from the bank and
      // is looking at the door.
      people() {
        const at = [
          { x: 92, sheet: 'crew-a', flip: false, delay: 0 },
          { x: 236, sheet: 'crew-b', flip: true, delay: 3 },
          { x: 306, sheet: 'crew-a', flip: true, delay: 6 },
          { x: 414, sheet: 'crew-b', flip: false, delay: 8, asks: true },
        ];
        for (const spot of at) {
          const body = this.add.image(spot.x, FLOOR_Y, spot.sheet, 'idle-0')
            .setOrigin(0.5, 1).setDepth(12).setFlipX(spot.flip);
          // A contact shadow, or the figure is a sticker on a photograph.
          this.add.graphics().setDepth(11)
            .fillStyle(0x241d38, 0.42).fillRect(spot.x - 10, FLOOR_Y - 2, 20, 3);
          const ask = spot.asks
            ? this.label(spot.x + 8, FLOOR_Y - 60, '?', WINDOW_WARM, 12).setDepth(13)
            : null;
          this.crew.push({ body, ask, delay: spot.delay, sheet: spot.sheet });
        }
      }

      // The door the fourth one is watching: shut, lit from the far side, and
      // the only warm rectangle in the room that is not a screen.
      door() {
        const x = DOOR_X;
        const top = FLOOR_Y - 62;
        const g = this.add.graphics().setDepth(2);
        g.fillStyle(0x241d38, 1);
        g.fillRect(x - 4, top - 4, 42, 66);
        g.lineStyle(1, 0x7d6aa8, 1);
        g.strokeRect(x - 4.5, top - 4.5, 43, 67);
        g.fillStyle(0x2a2244, 1);
        g.fillRect(x, top, 34, 62);
        g.fillStyle(WINDOW_WARM, 0.55);
        g.fillRect(x + 16, top + 2, 2, 60);
        g.fillStyle(0x3d3358, 1);
        g.fillRect(x + 3, top + 5, 12, 30);
        g.fillRect(x + 19, top + 5, 12, 30);
        this.glow(x + 14, top + 6, 6, 54, WINDOW_WARM, 3).setAlpha(0.4);
      }

      // Cool haze over the whole room, and two volumetric cones off the ceiling
      // strip. Rule 10: one cone per three machines, additive, barely there.
      light(v) {
        const cones = this.add.graphics().setDepth(20).setBlendMode(Phaser.BlendModes.ADD);
        for (const cx of [98, 234, 370]) {
          cones.fillStyle(WINDOW_WARM, 0.05);
          cones.fillTriangle(cx - 9, WALL_TOP - 6, cx + 9, WALL_TOP - 6, cx + 52, FLOOR_Y + 6);
          cones.fillTriangle(cx - 9, WALL_TOP - 6, cx + 9, WALL_TOP - 6, cx - 52, FLOOR_Y + 6);
          const bulb = this.add.graphics().setDepth(20);
          bulb.fillStyle(WINDOW_WARM, 0.85);
          bulb.fillRect(cx - 7, WALL_TOP - 8, 14, 3);
        }
        const haze = this.add.graphics().setDepth(21);
        haze.fillGradientStyle(HAZE, HAZE, HAZE, HAZE, 0.16, 0.16, 0.05, 0.05);
        haze.fillRect(v.x, v.y, v.w, v.h);
      }

      spot() { /* the room is one shot; nothing in it is a run */ }

      update() { this.step(false); }

      step(force) {
        const frozen = still.matches;
        if (frozen && !force && this.phase.still) return;
        const phase = phaseAt(clock(), { reducedMotion: frozen });
        this.phase = phase;
        for (const s of this.screens) s.g.setAlpha(flickerAt(phase, s.delay) * (s.gain || 1));
        for (const c of this.crew) {
          c.body.setTexture(c.sheet, `idle-${(phase.idle + c.delay) % CREW_IDLE}`);
          if (c.ask) c.ask.setAlpha(phase.ask);
        }
        for (const l of this.lamps) {
          l.lamp.setAlpha(l.red ? phase.klaxon : 0.55 + 0.45 * swing(phase.t + l.delay, 3.1));
        }
      }
    }

    const game = new Phaser.Game({
      type: Phaser.AUTO,
      scale: {
        // Same deal as world-canvas.js: NONE hands the sizing to us, the backing
        // store is device pixels, and `zoom` puts that buffer back at CSS size.
        // What differs is what happens inside it — the camera, not the canvas,
        // carries the 4x that makes an art pixel four device pixels wide.
        mode: Phaser.Scale.NONE,
        parent: host,
        expandParent: false,
        width: W,
        height: H,
        zoom: 1 / DPR,
      },
      render: {
        smoothPixelArt: true,
        roundPixels: true,
        powerPreference: 'low-power',
      },
      fps: { limit: 30 },
      audio: { noAudio: true },
      banner: false,
      backgroundColor: NIGHT,
      scene: room ? RoomScene : SkylineScene,
    });

    // A resized wall is re-measured and rebuilt, not stretched — the zoom is an
    // integer and a new panel may want a different one.
    let relayout = 0;
    window.addEventListener('resize', () => {
      clearTimeout(relayout);
      relayout = setTimeout(() => {
        const next = size();
        if (!next.w || !next.h) return;
        DPR = Math.min(Math.max(ratio(), 1), 2);
        const w = Math.max(1, Math.round(next.w * DPR));
        const h = Math.max(1, Math.round(next.h * DPR));
        if (w === W && h === H) return;
        W = w; H = h; ZOOM = zoomFor(W, H);
        game.scale.resize(W, H);
        game.scale.setZoom(1 / DPR);
        if (live) live.scene.restart();
      }, 400);
    });

    still.addEventListener('change', () => { if (live) live.step(true); });

    return {
      render(model) {
        pending = model;
        if (live && live.apply) live.apply(model);
      },
      spot(runId) {
        pendingSpot = runId;
        if (live && live.spot) live.spot(pendingSpot);
      },
      tick() { if (live) live.step(true); },
      game,
    };
  }

  return { create, phaseAt, carAt, flickerAt, jitter, seedOf, KINDS, TERRAIN, FILES, url };
}));
