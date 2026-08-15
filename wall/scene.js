'use strict';
// Ghost Shift's SCENE MODEL: what the city is, with no opinion about how it is
// drawn. Everything in here is arithmetic over a snapshot and a clock — no
// document, no window, no Math.random, no Date.now — so it loads under
// `require()` in a test and as a plain <script> on the wall, and two calls with
// the same arguments are the same city.
//
// This is the file both bodies of the world read. The DOM/CSS renderer in
// wall.js and the WebGL renderer in world-canvas.js are handed the same object
// and asked to paint it; nothing about a run id, a shop, a typology or a
// storey count is decided twice.
//
// Sizes in here are SEMANTIC — storeys, run counts, a plot as a fraction of the
// street, a height as a percentage of the skyline's own band. Never pixels: a
// renderer owns its coordinate system, and bodies drawing at different live
// stage sizes have to be able to agree without conversion.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallScene = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the city's numbers -------------------------------------------------------
  // The street's ceiling. A wall that runs for a month must never let an
  // exceptional week put ten thousand walkers on a compositor.
  const MAX_WALKERS = 6;
  const MAX_VEHICLES = 3;
  const PER_WALKER = 4;    // one more silhouette every four ships
  const PER_VEHICLE = 9;
  const GAP_QUIET = 48;    // vehicle-cycle length on the week's first ship
  const GAP_BUSY = 11;
  const BUSY_AT = 25;      // where the vehicle tempo tops out
  const MALL_AT = 12;
  const TRAM_AT = 20;
  const OCCUPIED = 3;      // windows per building keeping their own hours
  const MAX_TOWER_WIDTH_RUNS = 8; // later shafts still render without widening the tower
  const DEFAULT_FLOORS = 6;
  const RAIN_LAG = 420;    // the haze trails the rain by seven minutes
  const DAWN_H = 6.5;      // local hour the sky is coldest at
  const DAWN_RAMP = 2.5;   // hours either side of it that the cooling spans
  const WEATHER_SEED_MS = 15 * 60 * 1000; // nearby screens share a rain field

  // The ghost lives inside the sky's 1600x900 viewBox so the parallax skyline
  // can genuinely paint in front of it. Both renderers adopt that box for this
  // one layer, which is why the numbers are here rather than in either of them.
  const GHOST = {
    viewW: 1600,
    groundY: 819,
    w: 40,
    baseH: 31,
    storeyH: 17,
  };

  // Two colour systems, deliberately kept apart: the ACTOR neon (which model
  // owns the current stage) lights the car and the brief plate, and the CREW
  // tint (who dispatched the run) only ever lights the lamp under the car and
  // the name on the plate and the ticker. Desaturated on purpose — a crew tint
  // must never read as live state. Five well-separated hues rather than many
  // near-neighbours: two crew members sharing a tint is survivable, two crew
  // members with tints you cannot tell apart from the sofa is not.
  const CREW_TINTS = ['#e8cfa6', '#a9c9de', '#e5b3c2', '#b3d4bd', '#c6bce0'];
  const SYNTHETIC_TINT = '#f2eee2';   // milk-white. Synthetics do not bleed red.
  const UNOWNED_TINT = '#7c8b96';

  // A crew member keeps the same tint whoever else is on the wall, so the room
  // learns "the pale blue lamp is Reinier" — an index into the current runs
  // would repaint everyone every time somebody's queue emptied.
  function crewTint(run) {
    if (run.ownerKind === 'synthetic') return SYNTHETIC_TINT;
    if (run.ownerKind === 'unowned') return UNOWNED_TINT;
    const owner = run.owner || '';
    let h = 0;
    for (let i = 0; i < owner.length; i++) h = (h * 31 + owner.charCodeAt(i)) >>> 0;
    return CREW_TINTS[h % CREW_TINTS.length];
  }

  // --- weather --------------------------------------------------------------------
  // The weather drifts instead of looping: identical rain at 09:00 and at 21:00
  // is a screensaver, and a room stops seeing a screensaver by week two.
  // Everything here is a pure function of the wall clock, so two TVs opened side
  // by side read the same sky without a byte crossing the network to agree on
  // it, and an hour later they have drifted together. A wall-clock-seeded
  // generator places individual drops; it never decides how hard it is raining.

  function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

  // Two slow sines whose periods do not divide each other (~69 and ~181
  // minutes), so the sky takes most of a day to come back round. The clamp is
  // the point rather than a safety rail: it is what gives the city sustained
  // downpours and sustained near-dry spells instead of a sine that never rests.
  function wetness(t) {
    return clamp01(0.5 + 0.4 * Math.sin(t / 660) + 0.2 * Math.sin(t / 1730 + 2.1));
  }

  // Individual drops use a small deterministic generator too. The coarse
  // wall-clock seed makes nearby screens opened together share the same rain
  // field, while a later visit does not replay one permanent arrangement.
  function weatherSeed(ms) { return Math.floor(ms / WEATHER_SEED_MS) >>> 0; }

  function seededRandom(seed) {
    let state = seed >>> 0;
    return () => {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      return state / 4294967296;
    };
  }

  // How near the local clock is to dawn, 0 to 1. Read off the browser and never
  // the server: the harness has no idea which room the screen is in, and a wall
  // in another timezone still has to cool at its own sunrise.
  function dawn(d) {
    const hour = d.getHours() + d.getMinutes() / 60 + d.getSeconds() / 3600;
    const gap = Math.abs(hour - DAWN_H);
    return clamp01(1 - Math.min(gap, 24 - gap) / DAWN_RAMP);
  }

  // --- nightlife ----------------------------------------------------------------
  // What is under a building at one in the morning. Every one of these is a pure
  // function of the run id, planned the way the server plans a plot: a polynomial
  // over the id put through murmur3's finaliser, so OLYX-1631 and OLYX-1632 do
  // not end up with the same shop, and the noodle bar is on the same corner after
  // a reload, on the second TV and on a colleague's laptop.
  //
  // The whole vocabulary of the street is four signs. More would be a theme park;
  // fewer would be a pattern the room notices.
  const SHOP_KINDS = ['noodle', 'diner', 'arcade', 'repair'];
  // And what each of those signs actually says, one character each: 麵 noodles,
  // 食 a place that feeds you, 樂 an arcade, 修 a repair bench. Four glyphs, each
  // the shop it hangs over — a sign that means nothing is texture, and this city
  // does not do texture. Nothing outside this map is ever lettered.
  const SHOP_GLYPH = { noodle: '麵', diner: '食', arcade: '樂', repair: '修' };
  const BAYS = 5;            // shopfronts along a building's base
  const FLICKER_SPREAD = 89; // seconds of stagger, so no two neons ever stutter together

  // This is deliberately page-owned. `week.life` is an established API shape;
  // nightlife is presentation, and the existing ship count is all the page
  // needs to plan it without changing the server contract.
  function nightlifeOf(ships) {
    const n = Math.max(0, Math.floor(Number(ships) || 0));
    if (n === 0) return { walkers: 0, vehicles: 0, gap: 0, mall: false, tram: false };
    const busy = Math.min(1, (n - 1) / (BUSY_AT - 1));
    return {
      walkers: Math.min(MAX_WALKERS, 1 + Math.floor(n / PER_WALKER)),
      vehicles: Math.min(MAX_VEHICLES, 1 + Math.floor(n / PER_VEHICLE)),
      gap: Math.round(GAP_QUIET - (GAP_QUIET - GAP_BUSY) * busy),
      mall: n >= MALL_AT,
      tram: n >= TRAM_AT,
    };
  }

  function seedOf(text) {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (Math.imul(h, 31) + text.charCodeAt(i)) >>> 0;
    let v = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
    v = Math.imul(v ^ (v >>> 13), 0xc2b2ae35) >>> 0;
    return (v ^ (v >>> 16)) >>> 0;
  }

  // Who is behind one of those lit windows. Its own seed per pane, because a
  // building's hours and its tenants are not the same fact: a window that is on
  // is not a window with somebody in it, and about a third of them should be.
  // Five archetypes and no sixth — through a blind at fifty metres a person is a
  // posture, and a sixth posture is one nobody could tell from the other five.
  const OCCUPANT_KINDS = ['stand', 'sit', 'lean', 'pace', 'desk'];
  const OCCUPANT_SPREAD = 53;  // seconds of stagger, so a street does not move as one

  function occupantOf(id, i) {
    const draw = seedOf(id + '·pane' + i);
    return {
      home: draw % 3 === 0,
      kind: OCCUPANT_KINDS[(draw >>> 5) % OCCUPANT_KINDS.length],
      phase: (draw >>> 11) % OCCUPANT_SPREAD,
    };
  }

  // What is bolted to the front of the building besides its own shop sign. The
  // four shop kinds stay four kinds — the DRESSING is what varies, so a street of
  // four signs still reads as a street rather than as four repeated buildings.
  // Nought to two per block, and `pick` is a draw rather than an index: a
  // renderer takes it modulo whatever catalogue of banners it happens to own, and
  // this file never learns the name of a sprite.
  const BANNER_SLOTS = 3;      // 0 high on the facade, 1 off the shoulder, 2 on the roof
  const BANNER_COUNTS = [0, 1, 1, 2];
  const BANNER_SPREAD = 71;

  function bannersOf(id) {
    const out = [];
    const domain = id + '·dressing';
    const count = BANNER_COUNTS[seedOf(domain + '·count') % BANNER_COUNTS.length];
    for (let i = 0; i < count; i++) {
      out.push({
        // Separate draws, not overlapping slices of one word: what the prop is,
        // where it hangs and when it changes are three unrelated facts.
        pick: seedOf(domain + '·pick' + i) % 251,
        slot: seedOf(domain + '·slot' + i) % BANNER_SLOTS,
        drift: seedOf(domain + '·drift' + i) % BANNER_SPREAD,
      });
    }
    return out;
  }

  // Four draws, because a facade's hours have nothing to do with what is selling
  // downstairs, nor with how the sign over it is hung, nor with what else got
  // bolted to the front — and one 32-bit word cannot carry them all without the
  // slices sharing bits, which is how a district ends up with every arcade lit on
  // floor three.
  function storefrontOf(id) {
    const street = seedOf(id);
    const hours = seedOf(id + '·hours');
    const signage = seedOf(id + '·signage');
    const pick = (seed, shift, mod) => (seed >>> shift) % mod;
    const windows = [];
    for (let i = 0; i < OCCUPIED; i++) {
      windows.push({
        col: pick(hours, i * 9, 7),
        row: pick(hours, i * 9 + 3, 5),
        phase: pick(hours, i * 9 + 6, 8),
        who: occupantOf(id, i),
      });
    }
    const shop = SHOP_KINDS[pick(street, 0, SHOP_KINDS.length)];
    return {
      shop,
      // What the sign says is the shop, never a draw: the glyph is a translation
      // of the row underneath it, not a second opinion about what is down there.
      glyph: SHOP_GLYPH[shop],
      // One building in three carries the extra neon tube. All of them would be
      // Piccadilly; the small glyph identifying each shop is separate.
      neon: pick(street, 2, 3) === 0,
      bay: pick(street, 4, BAYS),
      flicker: pick(street, 7, FLICKER_SPREAD),
      // Which shoulder of the frontage the sign is bracketed to, and when its
      // own tube stumbles: a street where every sign hangs the same way and
      // blinks on the same beat is a wallpaper sample.
      side: pick(signage, 0, 2),
      hang: pick(signage, 3, FLICKER_SPREAD),
      banners: bannersOf(id),
      windows,
    };
  }

  // --- building typologies ------------------------------------------------------
  // How much shipped is the storey count, and it always was. What KIND of
  // building that is, is this: a district where the diff only ever moves one
  // number reads as a picket fence of identical slabs, however carefully the
  // storeys are scaled. So every block also draws a typology — and the draw is
  // weighted, because a real city is mostly low and wide with a few towers
  // standing in it, not a chart sorted by height.
  //
  // Six types and no seventh, on their own domain-separated seed, exactly like
  // the shop underneath: same id, same building, on both screens and tomorrow.
  // The shape is the page's business — the server has never heard of it.
  //
  // The draw is spelled as shares rather than as probabilities, because what is
  // in this list IS the skyline's distribution and it should be readable as one:
  //   shophouse  low and wide, two to four floors over a shopfront row
  //   warehouse  short, wide, sawtooth roof
  //   tank       mid-rise carrying a water tower
  //   slab       the district's existing look, family roofline and all
  //   setback    a tower that steps in as it climbs
  //   mast       thin, tall, one antenna
  const FORM_SHARES = [
    'shophouse', 'shophouse', 'shophouse', 'shophouse',
    'warehouse', 'warehouse',
    'tank', 'tank',
    'slab', 'slab',
    'setback',
    'mast',
  ];
  const FORM_GRADES = 4;   // footprint nudges inside one type

  function formOf(id) {
    const draw = seedOf(id + '·form');
    return {
      form: FORM_SHARES[draw % FORM_SHARES.length],
      // A second slice off the same word, taken high so it cannot shadow the
      // type itself: two shophouses side by side are not the same shophouse.
      grade: (draw >>> 12) % FORM_GRADES,
    };
  }

  // --- the street ---------------------------------------------------------------
  // The population, planned from the week's ship count. Every lane and phase a
  // renderer needs comes from the slot index alone — two screens standing side
  // by side have the same street — so the plan is a count and a tempo, and what
  // a walker looks like is the renderer's business.
  //
  // Each car shares a cycle long enough to keep consecutive pass starts one
  // planned gap apart. Merely giving every car a `gap`-long loop would turn
  // three cars at the cap into a pass every few seconds.
  function streetOf(ships) {
    const plan = nightlifeOf(ships);
    return {
      walkers: plan.walkers,
      vehicles: plan.vehicles,
      gap: plan.gap,
      mall: plan.mall,
      tram: plan.tram,
      cycle: plan.vehicles ? plan.gap * plan.vehicles : GAP_QUIET,
    };
  }

  // --- the landmark -------------------------------------------------------------
  // One building in this district is not a ship. Ran pays for the subscription
  // every run on this wall is spent from, so the city carries the name in the
  // idiom the street already speaks: a tall back-band tower with a vertical tube
  // down its shoulder reading 冉.
  //
  // It is a fixture, not a fact about the week: never in wall-city.jsonl, never
  // in an /api/runs payload, never counted by the HUD. Both worlds stand it up
  // themselves — on an empty Monday as much as on a full Friday — and then leave
  // it alone, exactly like every building around it.
  const RAN = {
    glyph: '冉',
    dedication: '冉 — For Ran, who keeps the lights on',
    x: 0.19,       // off the centre, where the towers cluster and the quiet line sits
    storeys: 16,   // matches --storeys on .block--landmark in wall.css
  };

  // --- the noodle bar -------------------------------------------------------------
  // And one building in this district is not a ship either. A city you can watch
  // for a minute needs somewhere something is HAPPENING — not a lit window, not a
  // sign that stutters, but a person doing a job — and on a street of four shop
  // signs the noodle bar is the one everybody already understands.
  //
  // So it is a fixture on exactly the landmark's terms: never in the ledger,
  // never in a payload, never counted by the HUD, standing on an empty Monday as
  // much as on a full Friday. Its plot is fixed and well clear of the dedication
  // at 0.19 — far enough to the right that the two never share a frontage, near
  // enough to the middle that a camera holding the street has it in shot. A
  // `noodle`-kind block the week happens to ship keeps its ordinary shopfront:
  // this is THE noodle bar, not a second opinion about a shop.
  const NOODLE_BAR = {
    glyph: '麵',
    x: 0.62,
    storeys: 3,      // a shophouse: two floors of somebody's flat over the bar
    depth: 2,        // the nearest band: the one thing on this wall meant to be watched
    kind: 'noodle',  // its wider hero frontage and awning are renderer-owned
  };

  // --- one project: a tower -----------------------------------------------------

  // Neon stock for the vertical project signs: cold noir hues only — red stays
  // reserved for alarms. Which sign a project gets rides the same hash slices
  // that pick its silhouette, so the colour is stable run to run.
  const SIGN_TINTS = ['#7fd4ec', '#ffc27d', '#9fe8b8', '#e8e2cf', '#8fb0ff'];

  // A tower, with every run standing in it already resolved: a renderer never
  // has to go back to the snapshot to find out what a shaft is doing.
  function towerOf(tower, byId, floors, at) {
    const n = tower.runIds.length;
    const shafts = [];
    for (const id of tower.runIds) {
      const run = byId.get(id);
      if (!run) continue;
      shafts.push({
        id,
        state: run.state,
        actorKey: run.actorKey,
        stage: run.stage,
        floor: run.floor,
        // Half a floor up from the slab it stopped on, so a car reads as
        // standing on that floor rather than balancing on the line between two.
        level: (run.floor + 0.55) / floors,
        crew: crewTint(run),
        since: run.since || at,
        age: Math.max(0, at - (run.since || at)),
      });
    }
    // The rooftop beacon and the shipping ceremony both belong to a run that has
    // just shipped: which run that is, and how far into its moment the wall is
    // joining, are facts about the snapshot rather than about a renderer.
    const shipped = tower.runIds.find((id) => (byId.get(id) || {}).state === 'ready') || '';
    const shippedRun = shipped ? byId.get(shipped) : null;
    return {
      project: tower.project,
      label: tower.label,
      known: !!tower.known,
      shape: tower.shape,
      crown: tower.crown,
      alarm: !!tower.alarm,
      live: tower.live || 0,
      runIds: tower.runIds.slice(),
      shipped,
      shippedAge: shippedRun ? Math.max(0, at - (shippedRun.since || at)) : 0,
      // A tower grows gently with the work standing in it — enough that a busy
      // repo reads as the tall one, not enough to turn the skyline into a chart.
      // A percentage of the skyline's own band, so both bodies can honour it.
      heightPct: Math.min(94, 48 + n * 8),
      // How many run-widths across, in the same em-ish unit both worlds scale by.
      widthRem: 3.4 + Math.min(n, MAX_TOWER_WIDTH_RUNS) * 2.2,
      sign: SIGN_TINTS[(tower.shape * 7 + tower.crown) % SIGN_TINTS.length],
      // Seconds of stagger on this tower's neon, so no two tubes stutter together.
      drift: (tower.shape * 3.1 + tower.crown * 5.7) % 17,
      shafts,
    };
  }

  // A building, with its typology and its ground floor already drawn from the
  // run id — the same two draws both worlds would otherwise make separately.
  function blockOf(record, at) {
    return {
      id: record.id,
      project: record.project || '',
      kind: record.kind,
      depth: record.depth,
      x: record.x,
      storeys: record.storeys,
      at: record.at,
      owner: record.owner || '',
      ownerKind: record.ownerKind,
      crew: crewTint(record),
      // Same idiom as the completion moment: a browser opening this afternoon
      // fast-forwards a building that landed this morning to where it already
      // is, rather than replaying every settle in the week at once.
      age: Math.max(0, at - (record.at || at)),
      shape: formOf(record.id),
      shop: storefrontOf(record.id),
    };
  }

  // --- the scene ----------------------------------------------------------------
  // One snapshot and one clock in; the whole city out. Everything a renderer can
  // ask about the wall is in here, and nothing in here knows what a pixel is.

  function buildScene(snapshot, at) {
    const snap = snapshot && typeof snapshot === 'object' ? snapshot : {};
    const when = Math.floor(Number(at) || 0);
    const runs = Array.isArray(snap.runs) ? snap.runs : [];
    const byId = new Map(runs.map((run) => [run.id, run]));
    const floors = Array.isArray(snap.floors) && snap.floors.length
      ? snap.floors.length : DEFAULT_FLOORS;
    const week = snap.week && typeof snap.week === 'object' ? snap.week : { ships: 0, life: {} };
    const towers = (Array.isArray(snap.towers) ? snap.towers : [])
      // The server's stable skyline order is itself a scene fact. Carry the
      // rank explicitly so a renderer never has to infer it from mutable DOM or
      // display-list position after objects have already been created.
      .map((tower, rank) => ({ ...towerOf(tower, byId, floors, when), rank }));
    const blocks = (Array.isArray(snap.city) ? snap.city : [])
      .map((record) => blockOf(record, when));
    const ghosts = (Array.isArray(snap.ghost) ? snap.ghost : []).map((g) => ({
      x: g.x,
      storeys: g.storeys,
      // Its height inside the sky's own reference box, which is the only frame
      // last week's silhouette has ever been expressed in.
      height: GHOST.baseH + g.storeys * GHOST.storeyH,
    }));
    const plan = nightlifeOf(week.ships);
    const quiet = towers.length === 0;
    return {
      at: when,
      floors,
      completionSeconds: Number(snap.completionSeconds) || 0,
      signSeconds: Number(snap.signSeconds) || 0,
      week: { ships: Math.max(0, Math.floor(Number(week.ships) || 0)) },
      // Nothing climbing. Both worlds step the ground floor back when there is,
      // and the page decides what the chrome says about it.
      quiet,
      // The page chrome distinguishes a genuinely empty week from a district
      // at rest. That distinction belongs to the same scene facts as `quiet`,
      // not to a second count performed by one renderer's caller.
      idle: quiet ? (blocks.length ? 'rest' : 'empty') : 'off',
      towers,
      blocks,
      ghosts,
      // The dedication is what the week arrives into: it is in the scene on an
      // empty ledger exactly as it is on a full one.
      landmark: {
        glyph: RAN.glyph,
        dedication: RAN.dedication,
        x: RAN.x,
        storeys: RAN.storeys,
        kind: 'landmark',
        depth: 0,
      },
      // The other fixture, and on the same terms: in the scene on an empty
      // ledger exactly as it is on a full one.
      noodleBar: {
        glyph: NOODLE_BAR.glyph,
        x: NOODLE_BAR.x,
        storeys: NOODLE_BAR.storeys,
        kind: NOODLE_BAR.kind,
        depth: NOODLE_BAR.depth,
      },
      street: streetOf(week.ships),
      // The two ambient samples the sky reads. A renderer re-reads them off its
      // own clock between snapshots — these are this frame's, and the resting
      // value a test can pin.
      weather: {
        haze: 0.45 + 0.55 * wetness(when - RAIN_LAG),
        dawn: dawn(new Date(when * 1000)),
      },
    };
  }

  return {
    buildScene,
    // The pure fabric, exported because both worlds and the suite draw on it.
    seedOf, storefrontOf, occupantOf, bannersOf, formOf, nightlifeOf, streetOf,
    crewTint, towerOf, blockOf,
    clamp01, wetness, weatherSeed, seededRandom, dawn,
    SHOP_KINDS, SHOP_GLYPH, BAYS, FLICKER_SPREAD, FORM_SHARES, FORM_GRADES,
    OCCUPANT_KINDS, OCCUPANT_SPREAD, BANNER_SLOTS, BANNER_SPREAD,
    SIGN_TINTS, CREW_TINTS, SYNTHETIC_TINT, UNOWNED_TINT, RAN, NOODLE_BAR, GHOST,
    MAX_WALKERS, MAX_VEHICLES, PER_WALKER, PER_VEHICLE, GAP_QUIET, GAP_BUSY,
    BUSY_AT, MALL_AT, TRAM_AT, OCCUPIED, MAX_TOWER_WIDTH_RUNS, DEFAULT_FLOORS,
    RAIN_LAG, DAWN_H, DAWN_RAMP, WEATHER_SEED_MS,
  };
}));
