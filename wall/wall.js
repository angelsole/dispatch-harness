'use strict';
// Ghost Shift's page. Subscribes to /api/stream (SSE), falls back to polling
// /api/runs, turns each snapshot into a scene model (wall/scene.js) and hands
// that to a WORLD: the DOM/CSS city this file has always built, or — behind
// ?world=canvas — the WebGL one in wall/world-canvas.js. The page keeps the
// clock, the HUD, the brief plate, the comms ticker, the rain and the director;
// what a tower looks like belongs to whichever world is drawing.
//
// Towers and cars are created once and mutated in place — a full re-render
// would restart every CRT animation, and would teleport a car that is supposed
// to be seen climbing. No network call ever leaves this origin.
//
// The skyline is whatever the server says is standing: live work, plus a
// finished run's one completion moment. Nothing here keeps a run on screen
// after the server has dropped it.
//
// Behind it, the district ACCRETES: one permanent building per run the server
// reports as shipped this week, plus last week's as a flat ghost. Those are
// facts, not state — they land once, play one settle, and are furniture.

(function () {
  // The city's own truth: pure, renderer-agnostic, loaded before this file and
  // shared byte for byte with the canvas world. Nothing below re-derives a
  // shop, a typology, a storey count or a crew tint for itself.
  const Scene = window.WallScene;
  const {
    crewTint, seededRandom, wetness, weatherSeed, dawn,
    RAN, GHOST, RAIN_LAG, OCCUPIED,
  } = Scene;

  const POLL_MS = 2000;    // only used when SSE is unavailable
  const BRIEF_MS = 7000;   // how long one run holds the brief plate
  const SWAP_MS = 200;     // the gap the plate is empty for, mid hand-off
  const TILT = 0.2;        // how far off vertical the rain falls
  const CEREMONY_S = 6;    // the shipping beat; must match --ceremony in wall.css
  const DRY = 0.06;        // a near-dry spell is drips, never a dead canvas
  // The canvas world and the engine behind it, in load order. Only requested
  // when ?world=canvas asks for them: the DOM wall must never pay 1.4 MB of
  // WebGL for a city it draws in CSS.
  const CANVAS_SCRIPTS = ['vendor/phaser.min.js', 'world-canvas.js'];
  // The director. A room that has not touched anything for this long gets the
  // film; the shot bucket is the wall-clock idiom the weather already uses, so
  // two screens in the same room are cutting roughly together.
  const CINEMA_IDLE_MS = 90 * 1000;
  const SHOT_SEED_MS = 10 * 60 * 1000;
  const MOVE_MIN = 6000, MOVE_MAX = 10000;   // how long the camera takes to arrive
  const HOLD_MIN = 8000, HOLD_MAX = 20000;   // how long it stays once it has
  // The dive holds longer than an ordinary close shot: there is a person in
  // there working on a named ticket, and the room needs long enough to be read
  // rather than glanced at.
  const ROOM_MIN = 15000, ROOM_MAX = 20000;
  const WIDE_HOLD = 20000;  // the establishing shot holds longest of all
  const CUT_MS = 700;       // the ease home when somebody touches the room
  const MAX_ZOOM = 4;       // the lens's ceiling; past this the city is pixels
  const CREEP = 0.05;       // Ken Burns: how far a held frame drifts on

  const still = window.matchMedia('(prefers-reduced-motion: reduce)');

  const GLYPH = {
    opus: 'g-opus', codex: 'g-codex', gate: 'g-gate', pr: 'g-pr', demo: 'g-demo',
    setup: 'g-setup', sync: 'g-sync', skipped: 'g-skipped', alarm: 'g-alarm',
    deferred: 'g-skipped',   // parked, not working — the same stood-down mark
    unreviewed: 'g-failed',  // no tier reviewed the diff — a failure, drawn as one

    done: 'g-done', failed: 'g-failed', unknown: 'g-unknown',
  };
  const STATE_GLYPH = { alarm: 'g-alarm', ready: 'g-done', failed: 'g-failed' };

  const stage = document.getElementById('stage');
  const rest = document.getElementById('rest');
  const counts = document.getElementById('counts');
  const clock = document.getElementById('clock');
  const link = document.getElementById('link');
  const comms = document.getElementById('comms');
  const commsText = document.getElementById('commsText');
  const boot = document.getElementById('boot');
  const plate = {
    root: document.getElementById('brief'),
    glyph: document.getElementById('briefGlyph'),
    project: document.getElementById('briefProject'),
    floor: document.getElementById('briefFloor'),
    owner: document.getElementById('briefOwner'),
    id: document.getElementById('briefId'),
    title: document.getElementById('briefTitle'),
    actor: document.getElementById('briefActor'),
    stage: document.getElementById('briefStage'),
    timer: document.getElementById('briefTimer'),
    note: document.getElementById('briefNote'),
    dots: document.getElementById('briefDots'),
  };

  let skew = 0;        // server epoch minus ours, so timers agree with the harness
  let latest = null;            // the last snapshot the server pushed, verbatim
  let runs = [];
  let signSeconds = 0;          // supplied with the first server snapshot
  let skyline = new Set();      // the run ids the server is standing in the city
  let plateId = '';             // the run currently holding the brief plate
  let plateSince = 0;
  let swapTimer = 0;            // set while the plate is empty between two runs
  let commsKey = '';            // last ticker text, so it only restarts on change
  const commsSeen = new Map();  // run id -> the line already drawn for it

  const now = () => Math.floor(Date.now() / 1000) + skew;

  function dur(secs) {
    if (!isFinite(secs) || secs < 0) return '--';
    if (secs < 60) return secs + 's';
    const m = Math.floor(secs / 60);
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60);
    if (h < 48) return h + 'h' + String(m % 60).padStart(2, '0');
    return Math.floor(h / 24) + 'd';
  }

  function el(tag, cls, text) {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function svgEl(tag, cls) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    if (cls) node.setAttribute('class', cls);
    return node;
  }

  // Put `node` straight after `after` (or first) in `parent`, and touch the DOM
  // only when it is not already there: re-inserting a node restarts its CSS
  // animations, and this runs on every frame the server pushes.
  function place(parent, node, after) {
    const want = after ? after.nextSibling : parent.firstChild;
    if (want !== node) parent.insertBefore(node, want);
    return node;
  }

  function setGlyph(node, id) {
    const use = node.firstChild;
    const ref = '#' + id;
    if (use.getAttribute('href') === ref) return;
    use.setAttribute('href', ref);
    use.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', ref);
  }

  function glyphFor(run) {
    return STATE_GLYPH[run.state] || GLYPH[run.actorKey] || GLYPH.unknown;
  }

  const isLive = (run) => run.state === 'active' || run.state === 'alarm';

  // --- the DOM world ----------------------------------------------------------
  // The city as elements: everything from here down to the seam is ONE renderer
  // — the CSS/SVG body this wall has always had — and it is the default. It is
  // handed a scene and asked to paint it; it decides nothing about the city and
  // reads nothing off the snapshot. The other body (world-canvas.js) implements
  // the same three methods against a GPU.

  const city = document.getElementById('city');
  const district = document.getElementById('district');
  const ghostLayer = document.getElementById('ghost');
  const life = document.getElementById('life');
  const crowd = document.getElementById('crowd');
  const road = document.getElementById('road');
  let landmark = null;          // the one fixture in the district; not a run
  let ghostKey = '';            // the silhouette layer is rebuilt only when it changes
  let blocks = [];              // the scene's buildings, kept so the second hand can age them
  const towerEls = new Map();   // project -> tower elements (incl. its shafts)
  const blockEls = new Map();   // run id -> building element, built once and left alone

  // --- one run: a car in a shaft ---------------------------------------------

  function makeShaft() {
    const root = el('div', 'shaft');
    // The floors this run has already been through, twice. The column is the
    // run's own bay, bright; the band is the tower's windows either side of it,
    // at a third of that — a building is lit as high as its work has climbed,
    // and a building with nothing running in it is dark. Both are the same
    // scaleY the car's height drives, so a stage change lights the next storey
    // without re-inserting a node or restarting an animation.
    const band = el('i', 'shaft__band');
    band.append(el('i', 'shaft__glow'));
    const col = el('i', 'shaft__col');
    col.append(el('i', 'shaft__lit'));
    const rail = el('i', 'shaft__rail');
    // Everything that rides with the car goes in the lift: one transform moves
    // the car, its crew lamp, the storey somebody is working on and the
    // spotlight bloom together.
    const lift = el('i', 'shaft__lift');
    lift.append(el('i', 'shaft__halo'), el('i', 'shaft__work'), el('i', 'shaft__car'));
    root.append(band, col, rail, lift);
    return { root, state: '' };
  }

  function paintShaft(S, run) {
    S.root.dataset.state = run.state;
    S.root.dataset.actor = run.actorKey;
    S.root.title = run.id + ' — ' + run.stage;   // for a desk browser; the TV never hovers
    // Half a floor up from the slab it stopped on, so a car reads as standing
    // on that floor rather than balancing on the line between two. The scene
    // works that out; the same number lands twice here, as a percentage for
    // the lift and as a factor for the lit column.
    S.root.style.setProperty('--pos', (run.level * 100).toFixed(2) + '%');
    S.root.style.setProperty('--lvl', run.level.toFixed(4));
    S.root.style.setProperty('--crew', run.crew);
    // --age fast-forwards the completion animation, so a browser opening
    // halfway through a flare joins the city where it already is. Written once
    // per state change: rewriting it every frame would restart the animation.
    if (S.state !== run.state) {
      S.state = run.state;
      S.root.style.setProperty('--age', String(run.age));
    }
  }

  // --- one project: a tower ---------------------------------------------------

  function makeTower() {
    const root = el('section', 'tower');
    // The searchlight is two halves of one beam: the sweep out of the roof, and
    // the patch it paints on the overcast above.
    root.append(el('div', 'tower__pool'), el('div', 'tower__sweep'),
                el('div', 'tower__ceiling'), el('div', 'tower__spot'));
    const crown = el('div', 'tower__crown');
    crown.append(el('div', 'tower__halo'), el('div', 'tower__beacon'));
    const mass = el('div', 'tower__mass');
    const windows = el('i', 'tower__windows');
    // The two pieces of masonry the window grid cannot draw, because neither of
    // them repeats: the mechanical floor at the height the silhouette steps,
    // and the lobby at the bottom. Both are the building rather than a layer
    // over it, so they sit under the ladder and over the facade.
    const belt = el('i', 'tower__belt');
    const podium = el('i', 'tower__podium');
    // The shipping cascade goes over the facade and under the ladder: the light
    // climbs the windows, never the shafts. Its child is the travelling glow;
    // the wrapper holds the storey mask still while that glow moves behind it.
    const cascade = el('i', 'tower__cascade');
    cascade.append(el('i'));
    const slabs = el('i', 'tower__floors');
    const shafts = el('div', 'tower__shafts');
    mass.append(windows, belt, podium, cascade, slabs, shafts);
    const sign = el('div', 'tower__sign');
    // The wet-tarmac reflection reuses the window-grid styling wholesale (same
    // class, same per-shape storey variables) and restyles itself via the
    // modifier — one source of truth for what a lit facade looks like.
    const mirror = el('i', 'tower__windows tower__mirror');
    const base = el('div', 'tower__base');
    root.append(crown, mass, sign, mirror, base);
    return { root, shafts, base, sign, ready: '', shaftEls: new Map() };
  }

  function paintTower(T, tower, floors) {
    T.root.dataset.project = tower.project;
    T.root.dataset.shape = String(tower.shape);
    T.root.dataset.crown = String(tower.crown);
    T.root.dataset.known = tower.known ? '1' : '0';
    T.root.dataset.alarm = tower.alarm ? '1' : '0';
    // The rooftop beacon and the shipping ceremony both belong to a run that
    // has just shipped, and both flare and die with that run's completion
    // moment — hence the one shared --age, written once when the tower gains a
    // shipped run so a late-joining browser lands mid-beat instead of replaying
    // it, and never rewritten, which is what keeps it to once per run.
    const shipped = tower.shipped;
    if (shipped !== T.ready) {
      // Dropping the selector before changing --age gives each shipped run its
      // own animation timeline. Without the reflow, a second run shipping from
      // the same tower while the first is still present inherits the first
      // run's completed animation instead of receiving a ceremony.
      T.root.dataset.ready = '0';
      T.ready = shipped;
      if (shipped) T.root.style.setProperty('--age', String(tower.shippedAge));
      void T.root.offsetWidth;
    }
    T.root.dataset.ready = shipped ? '1' : '0';
    // How tall and how wide are the scene's, in its own semantic units: a
    // percentage of the skyline band and a count of run-widths.
    T.root.style.height = tower.heightPct + '%';
    T.root.style.width = tower.widthRem.toFixed(1) + 'rem';
    T.root.style.setProperty('--floors', String(floors));
    T.base.dataset.label = tower.label;
    T.sign.textContent = tower.label;
    T.root.style.setProperty('--sign', tower.sign);
    T.root.style.setProperty('--drift', tower.drift.toFixed(1) + 's');

    const standing = new Set(tower.shafts.map((s) => s.id));
    for (const [id, S] of T.shaftEls) {
      if (!standing.has(id)) { S.root.remove(); T.shaftEls.delete(id); }
    }
    let cursor = null;
    for (const run of tower.shafts) {
      let S = T.shaftEls.get(run.id);
      if (!S) { S = makeShaft(); T.shaftEls.set(run.id, S); }
      paintShaft(S, run);
      cursor = place(T.shafts, S.root, cursor);
    }
  }

  // --- the week's district -----------------------------------------------------
  // What the city has accreted since Monday. A building is written ONCE, when it
  // lands: everything about it — its plot, its height, its type, the age its
  // settle and its cooling sign are fast-forwarded by — is fixed the moment the
  // run shipped. Repainting one on every frame would restart both animations and
  // turn a permanent record into a flicker.

  function makeBlock() {
    const root = el('div', 'block');
    const mass = el('i', 'block__mass');
    // The facade grid is the towers' own, wholesale — one source of truth for
    // what a lit facade looks like, at the district's smaller storey pitch.
    mass.append(el('i', 'tower__windows block__windows'));
    // Occupancy: a fixed handful of windows on this facade that keep their own
    // hours, fading on and off over minutes. Fixed, because the element count on
    // a wall that runs for a month is a budget, not a detail.
    const occupancy = el('i', 'block__occupancy');
    const occupants = [];
    for (let i = 0; i < OCCUPIED; i++) {
      const pane = el('i');
      occupants.push(pane);
      occupancy.append(pane);
    }
    // The ground floor: a lit shopfront row and matching glyph under every
    // building, plus the established one-in-three neon tube over a bay.
    const shop = el('i', 'block__shop');
    shop.append(el('i', 'block__neon'));
    mass.append(occupancy, shop);
    // The hanging sign is bracketed to the building, not painted on the shop
    // row inside it — which is also the only way it survives: everything inside
    // .block__mass is cut by the typology's roofline clip-path and washed by
    // the depth veil, and a sign that is hazed like a distant wall is not a
    // sign, it is texture.
    const glyph = el('i', 'block__glyph');
    // What that ground floor puts on the pavement in front of it. It hangs off
    // the building rather than off the shop row inside it because a typology
    // cuts its own roofline out of .block__mass with a clip-path, and a
    // clip-path takes the descendants with it: for every form the district
    // draws, the light this street is lit by was being clipped off at the kerb.
    const spill = el('i', 'block__spill');
    // The sign is the only thing on a building that names anybody: a small neon
    // in the dispatcher's own crew tint, cooling to the district's neutral
    // within --sign-life of landing. No zones, no lanes, nothing cumulative.
    root.append(el('i', 'block__crown'), mass, spill, glyph, el('i', 'block__sign'));
    return { root, glyph, occupants };
  }

  function paintStaticSign(B, b) {
    const age = Math.max(0, now() - (b.at || now()));
    B.root.style.setProperty('--sign-static', age < signSeconds ? '0.85' : '0');
    return age;
  }

  function paintBlock(B, b) {
    B.root.dataset.kind = b.kind;
    B.root.dataset.depth = String(b.depth);
    B.root.style.setProperty('--x', (b.x * 100).toFixed(2) + '%');
    B.root.style.setProperty('--storeys', String(b.storeys));
    B.root.style.setProperty('--crew', b.crew);
    // What kind of building this is, on top of what family it belongs to. The
    // same write-once pass and the same rule as the shop under it: a typology is
    // a fact about the run id, so the district is the same city after a reload.
    const shape = b.shape;
    B.root.dataset.form = shape.form;
    B.root.style.setProperty('--grade', String(shape.grade));
    // Same idiom as the completion moment: a browser opening this afternoon
    // fast-forwards a building that landed this morning to where it already is,
    // rather than replaying every settle in the week at once.
    paintStaticSign(B, b);
    B.root.style.setProperty('--age', String(b.age));
    B.root.title = b.id + (b.project ? ' — ' + b.project : '');
    // And its nightlife, written in the same breath and for the same reason:
    // which shop is under this building and which of its windows are still up is
    // a fact about the run id, so it survives a reload rather than being redealt.
    const night = b.shop;
    B.root.dataset.shop = night.shop;
    B.root.dataset.neon = night.neon ? '1' : '0';
    B.root.style.setProperty('--bay', String(night.bay));
    B.root.style.setProperty('--flicker', String(night.flicker));
    // The lettering rides the same write-once pass as everything else on this
    // building: a glyph is a fact about the shop, so it is set here and never
    // touched again.
    B.glyph.textContent = night.glyph;
    B.root.dataset.side = String(night.side);
    B.root.style.setProperty('--hang', String(night.hang));
    night.windows.forEach((w, i) => {
      const node = B.occupants[i];
      if (!node) return;
      node.style.setProperty('--wx', String(w.col));
      node.style.setProperty('--wy', String(w.row));
      node.style.setProperty('--phase', String(w.phase));
    });
  }

  // --- the landmark -------------------------------------------------------------
  // The dedication the scene carries, as elements. It is a fixture rather than a
  // fact about the week — never in wall-city.jsonl, never in an /api/runs
  // payload, never counted by the HUD — so this world stands it up once, on an
  // empty Monday as much as on a full Friday, and then leaves it alone.

  function makeLandmark() {
    const root = el('div', 'block block--landmark');
    root.dataset.kind = 'landmark';
    root.dataset.depth = '0';      // the back band: the week lands in front of it
    root.style.setProperty('--x', (RAN.x * 100).toFixed(2) + '%');
    // The one hoverable thing on this layer, which is why the district's
    // pointer-events exemption in wall.css exists at all.
    root.title = RAN.dedication;
    const mass = el('i', 'block__mass');
    // The district's own facade grid and its lit ground floor, wholesale: a
    // monument is still a building on this street, not a graphic laid over it —
    // including the light it lays on the pavement in front of it.
    mass.append(el('i', 'tower__windows block__windows'), el('i', 'block__shop'));
    root.append(el('i', 'block__crown'), mass, el('i', 'block__spill'),
                el('i', 'landmark__sign', RAN.glyph));
    return root;
  }

  function renderDistrict(blocks) {
    // Built before the first block and never rebuilt: the dedication is what the
    // week arrives into. Placement leaves it alone too — place() inserts every
    // block ahead of it, so it settles as the last child and never moves again.
    if (!landmark) { landmark = makeLandmark(); district.append(landmark); }
    const standing = new Set(blocks.map((b) => b.id));
    for (const [id, B] of blockEls) {
      // Only the week rolling over takes a building down, and then it takes the
      // whole district with it.
      if (!standing.has(id)) { B.root.remove(); blockEls.delete(id); }
    }
    let cursor = null;
    for (const b of blocks) {
      let B = blockEls.get(b.id);
      if (!B) { B = makeBlock(); blockEls.set(b.id, B); paintBlock(B, b); }
      cursor = place(district, B.root, cursor);
    }
  }

  // Last week, flattened: a height and a plot, drawn once per change of shape.
  // No windows, no signs, no types — if you can tell what shipped last week from
  // this layer, it is doing too much.
  function renderGhost(ghosts) {
    const key = ghosts.map((g) => g.x + ':' + g.storeys).join(',');
    if (key === ghostKey) return;
    ghostKey = key;
    ghostLayer.textContent = '';
    // SVG elements do not consistently reflect the HTML `hidden` property;
    // toggle the attribute that the shared [hidden] rule actually matches.
    ghostLayer.toggleAttribute('hidden', ghosts.length === 0);
    for (const g of ghosts) {
      const shape = svgEl('rect', 'ghost__block');
      shape.setAttribute('x', (g.x * GHOST.viewW - GHOST.w / 2).toFixed(2));
      shape.setAttribute('y', String(GHOST.groundY - g.height));
      shape.setAttribute('width', String(GHOST.w));
      shape.setAttribute('height', String(g.height));
      ghostLayer.append(shape);
    }
  }

  // --- the street ---------------------------------------------------------------
  // The population the scene planned, as elements. Walkers and cars are created
  // and removed rather than hidden, so a plain with nothing on it costs the page
  // nothing, and every phase comes from the slot index alone — two screens
  // standing side by side have the same street.

  function populate(parent, cls, want, dress) {
    while (parent.childElementCount > want) parent.lastElementChild.remove();
    while (parent.childElementCount < want) {
      const slot = parent.childElementCount;
      const node = el('i', cls);
      node.style.setProperty('--slot', String(slot));
      dress(node, slot);
      parent.append(node);
    }
  }

  function renderLife(plan) {
    populate(crowd, 'life__walker', plan.walkers, (node, slot) => {
      // Two in three are people; the rest are the small service robots that do
      // the other half of a night shift. They cross the other way.
      node.dataset.kind = slot % 3 === 2 ? 'robot' : 'person';
      node.style.setProperty('--depth', String(slot % 4));
      node.append(el('i'));
    });
    populate(road, 'life__car', plan.vehicles, (node, slot) => {
      // Which way it is driving, which is also which side of the road it is
      // on: westbound is the far side, smaller and behind the near traffic.
      node.dataset.way = slot % 2 ? 'west' : 'east';
      // The cab itself. The pass is still one transform and one opacity on the
      // element above it; this is the body that transform is carrying.
      node.append(el('i'));
    });
    life.style.setProperty('--vehicle-cycle', plan.cycle + 's');
    // One planned gap between consecutive passes, and half a cycle of head
    // start on top: the same fast-forward the district's buildings and the
    // completion moment get. Without it a freshly opened browser watches an
    // empty road for most of a minute before the first car arrives, which is
    // exactly what every screenshot of this wall has been catching.
    [...road.children].forEach((node, slot) => {
      node.style.setProperty('--vehicle-delay',
        (-(slot * plan.gap + plan.cycle * 0.5)).toFixed(1) + 's');
    });
    life.dataset.tram = plan.tram ? '1' : '0';
    life.dataset.mall = plan.mall ? '1' : '0';
    // The whole point of the pass: nightlife is not gated on a milestone any
    // more. One building standing is all it takes for the ground floor to be lit.
    life.hidden = blocks.length === 0;
  }

  // --- the seam ----------------------------------------------------------------
  // What a world is, and the whole of it. Everything above is one implementation
  // of these three methods; world-canvas.js is the other.
  //
  //   render(scene)  the city, from the scene model
  //   spot(runId)    which run the brief plate is talking about ('' for none)
  //   tick(at)       the second hand: whatever ages on the clock alone

  const domWorld = {
    render(scene) {
      blocks = scene.blocks;
      city.dataset.empty = scene.quiet ? '1' : '0';
      renderGhost(scene.ghosts);
      renderDistrict(scene.blocks);
      renderLife(scene.street);
      for (const [project, T] of towerEls) {
        if (!scene.towers.some((t) => t.project === project)) {
          T.root.remove();
          towerEls.delete(project);
        }
      }
      let cursor = null;
      for (const tower of scene.towers) {
        let T = towerEls.get(tower.project);
        if (!T) { T = makeTower(); towerEls.set(tower.project, T); }
        paintTower(T, tower, scene.floors);
        cursor = place(city, T.root, cursor);
      }
    },

    // The plate and the skyline tell the same story twice, so they are lit
    // together: the featured run's car gets the searchbeam and its building gets
    // named in light. One glance has to connect the two.
    spot(runId) {
      let lit = false;
      for (const T of towerEls.values()) {
        let hit = false;
        for (const [id, S] of T.shaftEls) {
          const on = id === runId;
          S.root.dataset.spot = on ? '1' : '0';
          hit = hit || on;
        }
        T.root.dataset.spot = hit ? '1' : '0';
        lit = lit || hit;
      }
      // With a beam on one building the rest of the city steps back, which is
      // what turns "brighter" into "that one".
      city.dataset.spot = lit ? '1' : '0';
    },

    // Reduced motion disables the cooling animation. Keep its static state
    // honest by dropping the tint when the same server-owned lifetime expires.
    tick() {
      for (const b of blocks) {
        const B = blockEls.get(b.id);
        if (B) paintStaticSign(B, b);
      }
    },
  };

  // --- the brief plate --------------------------------------------------------
  // Towers cannot carry type you can read from meters away, so one run at a
  // time gets big letters. A blocked run pins the plate: it is the only thing
  // on the wall that is asking for something.

  function plateQueue() {
    const alarms = runs.filter((r) => r.state === 'alarm');
    return alarms.length ? alarms : runs.filter((r) => r.state === 'active');
  }

  function paintPlate(run, index, total) {
    plate.root.dataset.state = run.state;
    // The accent edge is the featured run's actor neon, except that a run
    // asking for a human is red down that edge whatever was running when it
    // stopped. Pinned here rather than left to the actor mapping: the alarm
    // must not be one stage rename away from turning blue.
    plate.root.style.setProperty('--accent',
      'var(--' + (run.state === 'alarm' ? 'alarm' : run.actorKey) + ')');
    plate.root.style.setProperty('--crew', crewTint(run));
    setGlyph(plate.glyph, glyphFor(run));
    plate.project.textContent = run.projectLabel;
    plate.floor.textContent = run.floorName;
    plate.owner.textContent = run.owner ? run.owner.toUpperCase() : '';
    plate.id.textContent = run.id;
    plate.title.textContent = run.title || '(no brief title)';
    plate.actor.textContent = run.actor.toUpperCase();
    plate.stage.textContent = run.activity && run.state === 'active'
      ? run.stage + '  ·  ' + run.activity
      : run.stage || '(no stage yet)';
    plate.timer.textContent = run.since ? '⧗ ' + dur(now() - run.since) : '';
    // Only live runs reach the plate, so the note is the blocking question or
    // nothing at all.
    const note = run.state === 'alarm'
      ? '⚠ ' + (run.blocked || 'needs your input — see QUESTIONS.md')
      : '';
    plate.note.textContent = note;
    plate.note.hidden = note === '';
    if (plate.dots.childElementCount !== total) {
      plate.dots.textContent = '';
      for (let i = 0; i < total; i++) plate.dots.append(el('i', 'brief__dot'));
    }
    [...plate.dots.children].forEach((dot, i) => { dot.dataset.on = i === index ? '1' : '0'; });
  }

  // Re-light the plate contents, on the way out or on the way in. The attribute
  // has to leave the DOM and come back for the animation to run a second time,
  // and the read between the two is what makes the browser believe it.
  function relight(phase) {
    plate.root.removeAttribute('data-swap');
    void plate.root.offsetWidth;
    plate.root.dataset.swap = phase;
  }

  function tickPlate() {
    const queue = plateQueue();
    if (queue.length === 0) {
      plate.root.hidden = true;
      if (plateId) {
        plateId = '';
        clearTimeout(swapTimer);
        swapTimer = 0;
        applySpot();
      }
      return;
    }
    let i = queue.findIndex((r) => r.id === plateId);
    if (i === -1) { i = 0; plateSince = Date.now(); }
    else if (queue.length > 1 && Date.now() - plateSince >= BRIEF_MS) {
      i = (i + 1) % queue.length;
      plateSince = Date.now();
    }
    const moved = queue[i].id !== plateId;
    const handing = moved && plateId !== '';
    plateId = queue[i].id;
    plate.root.hidden = false;
    if (handing) {
      // The carousel hands over rather than cutting: the run leaving eases out
      // first, and the one arriving is not written until the plate is empty.
      // The beam travels with the hand-off rather than after it, so the plate
      // and the skyline are never briefly telling two different stories.
      relight('out');
      clearTimeout(swapTimer);
      swapTimer = setTimeout(() => { swapTimer = 0; tickPlate(); }, SWAP_MS);
      applySpot();
      return;
    }
    // Mid hand-off the plate is blank on purpose, and the pending timer owns
    // what gets written next: a snapshot landing inside those milliseconds must
    // not put the outgoing run's words back on screen.
    if (swapTimer) return;
    const arriving = moved || plate.root.dataset.swap === 'out';
    paintPlate(queue[i], i, queue.length);
    if (arriving) {
      relight('in');
      applySpot();
    }
  }

  // Whichever body is drawing gets told which run the plate is on. The plate and
  // the skyline tell the same story twice and are lit together — one glance has
  // to connect the two — but what "lit" looks like is the world's business.
  // The room is the same story a third time, so it moves with the other two:
  // whichever run the beam is on is the run the dive is for.
  function applySpot() { world.spot(plateId); roomPaint(); }

  // --- the comms ticker --------------------------------------------------------
  // The tail of every live run's feed.log, in one line across the bottom: the
  // running commentary the panels used to carry, at a size the room can read.
  // A run in its completion moment gets one last line here — the skyline is
  // done with it, but the room deserves the sentence.

  function commsLines() {
    const items = [];
    const at = now();
    for (const run of runs) {
      const who = { id: run.id, owner: run.owner, tint: crewTint(run) };
      if (isLive(run)) {
        const last = run.feed[run.feed.length - 1];
        if (last) items.push({ ...who, text: last.text, src: last.src || 'opus' });
      } else if (skyline.has(run.id)) {
        const verdict = run.state === 'ready' ? 'SHIPPED' : 'STOPPED';
        const detail = run.prUrl || run.reason || run.outcome || run.stage;
        // The ticker's half of the shipping ceremony: for as long as the tower
        // is celebrating, this run's line is what shipped, in the brightest
        // type the tube has. The line already opens with the ticket id, so the
        // title is what the sentence adds. Aged off the same clock as the
        // tower's beat, which is why a browser joining late gets the settled
        // line rather than a celebration nobody is having any more.
        const shipping = run.state === 'ready' && at - (run.since || at) < CEREMONY_S;
        items.push(shipping
          ? { ...who, text: 'SHIPPED · ' + (run.title || detail), src: 'shipped' }
          : { ...who, text: verdict + ' — ' + detail, src: run.state });
      }
    }
    return items;
  }

  function tickComms() {
    const items = commsLines();
    const key = items.map((i) => i.id + i.text).join('|');
    if (key === commsKey) return;
    commsKey = key;
    comms.hidden = items.length === 0;

    const live = new Set(items.map((i) => i.id));
    for (const id of [...commsSeen.keys()]) if (!live.has(id)) commsSeen.delete(id);
    if (!items.length) return;

    commsText.textContent = '';
    let chars = 0;
    for (const item of items) {
      const line = el('span', 'comms__line');
      line.dataset.src = item.src;
      // Only a line this tube has not drawn before flickers in; a rebuild
      // caused by somebody else's run must not repaint the whole ticker.
      if (commsSeen.get(item.id) !== item.text) line.dataset.new = '1';
      commsSeen.set(item.id, item.text);
      line.append(el('b', 'comms__id', item.id + ' '));
      if (item.owner) {
        const who = el('span', 'comms__who', item.owner);
        who.style.setProperty('--crew', item.tint);
        line.append(who);
      }
      line.append(el('span', 'comms__body', item.text));
      commsText.append(line, el('span', 'comms__sep', '·'));
      chars += item.id.length + item.owner.length + item.text.length + 6;
    }
    // Scroll speed, not scroll duration: a long ticker must not race.
    commsText.style.setProperty('--secs', Math.max(24, Math.round(chars * 0.34)) + 's');
  }

  // --- the whole wall ----------------------------------------------------------

  function render() {
    // One snapshot and one clock in, the whole city out — and then straight into
    // whichever body is drawing it. Nothing below reaches past the scene.
    const scene = Scene.buildScene(latest, now());
    const { towers, blocks } = scene;
    document.body.dataset.quiet = scene.quiet ? '1' : '0';
    // The standby plate used to fire on an empty skyline. With a district that
    // accretes, "nothing live" is a normal Thursday evening on a week that
    // shipped nine things, and the plate would be saying the wrong sentence over
    // a full city. It now needs a genuinely empty week — nothing standing AND
    // nothing climbing; anything else gets the quiet line instead.
    document.body.dataset.idle = scene.idle;
    rest.textContent = blocks.length
      ? 'DISTRICT AT REST · ' + blocks.length + (blocks.length === 1 ? ' SHIP' : ' SHIPS')
        + ' THIS WEEK · NOTHING CLIMBING'
      : '';

    world.render(scene);

    counts.textContent = '';
    counts.hidden = towers.length === 0 && blocks.length === 0;
    // What is happening, plus the one thing that accumulates: the week's ships.
    // Still not a scoreboard — it is the count the district in front of it is
    // already showing, in a number you can read from the far side of the room.
    const tally = [
      ['active', runs.filter((r) => r.state === 'active').length],
      ['alarm', runs.filter((r) => r.state === 'alarm').length],
      ['ships', blocks.length],
      ['projects', towers.length],
    ];
    for (const [kind, n] of tally) {
      const box = el('span', 'hud__count');
      box.dataset.kind = kind;
      if (kind === 'alarm' && n > 0) box.dataset.hot = '1';
      box.append(el('b', '', String(n)), document.createTextNode(kind.toUpperCase()));
      counts.append(box);
    }

    tickComms();
    tickPlate();
    applySpot();
  }

  // Once a second: the clock, the live timer on the plate, and whether the
  // plate should move on.
  function tick() {
    const d = new Date((Date.now() / 1000 + skew) * 1000);
    clock.textContent = [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, '0')).join(':');
    tickPlate();
    // A ceremony ending changes nothing on disk, and neither does the weather:
    // both age on this clock, so both are re-read here rather than waiting for
    // a run somewhere to move.
    tickComms();
    // Whatever ages on the clock alone rather than on something moving on disk.
    world.tick(now());
    paintSky();
  }

  function apply(snapshot) {
    skew = (snapshot.at || 0) - Math.floor(Date.now() / 1000);
    latest = snapshot;
    runs = Array.isArray(snapshot.runs) ? snapshot.runs : [];
    const standing = Array.isArray(snapshot.towers) ? snapshot.towers : [];
    skyline = new Set(standing.flatMap((t) => t.runIds));
    // The completion moment is the server's number; the page only animates it.
    if (snapshot.completionSeconds > 0) {
      document.documentElement.style.setProperty('--completion', snapshot.completionSeconds + 's');
    }
    // Same contract for how long a building keeps its dispatcher's tint.
    if (snapshot.signSeconds > 0) {
      signSeconds = snapshot.signSeconds;
      document.documentElement.style.setProperty('--sign-life', snapshot.signSeconds + 's');
    }
    render();
    tick();
  }

  function setLink(state) { link.dataset.state = state; }

  function poll() {
    fetch('/api/runs', { cache: 'no-store' })
      .then((r) => r.json())
      .then((snap) => { apply(snap); setLink('live'); })
      .catch(() => setLink('lost'));
  }

  function connect() {
    if (!window.EventSource) {
      poll();
      setInterval(poll, POLL_MS);
      return;
    }
    const src = new EventSource('/api/stream');
    src.addEventListener('open', () => setLink('live'));
    src.addEventListener('snapshot', (ev) => {
      try { apply(JSON.parse(ev.data)); setLink('live'); } catch { setLink('lost'); }
    });
    // EventSource reconnects on its own (the server sends retry: 2000); the
    // indicator just tells the room the picture may be stale.
    src.addEventListener('error', () => setLink('lost'));
  }

  // --- the sky's ambient vars -------------------------------------------------
  // The weather model itself lives in scene.js, because both bodies of the world
  // have to read the same sky: it is a pure function of the wall clock, so two
  // TVs opened side by side agree without a byte crossing the network. What is
  // left here is the DOM world's half — two custom properties on the root — and
  // the seeded generator that places individual drops for the rain canvas.

  // The two things the canvas cannot draw: how thick the street haze is — which
  // follows the rain several minutes behind, because wet air clears long after
  // the downpour does — and how cold the sky is. Both are left unwritten under
  // reduced motion, where the fallbacks in wall.css are the city standing still.
  function paintSky() {
    const style = document.documentElement.style;
    if (still.matches) {
      style.removeProperty('--haze');
      style.removeProperty('--dawn');
      return;
    }
    const t = Date.now() / 1000;
    style.setProperty('--haze', (0.45 + 0.55 * wetness(t - RAIN_LAG)).toFixed(3));
    style.setProperty('--dawn', dawn(new Date()).toFixed(3));
  }

  // --- rain ---------------------------------------------------------------------
  // Weather, drawn one drop at a time. A tiled CSS sheet reads as a texture
  // from four metres; these are streaks with their own depth, length and speed,
  // and the canvas is screened over the city (wall.css) so a drop crossing a
  // lit window or the carousel spotlight catches that light and flares.

  function rain() {
    const canvas = document.getElementById('rain');
    const ctx = canvas && canvas.getContext ? canvas.getContext('2d') : null;
    if (!ctx) return;
    const drops = [];
    const random = seededRandom(weatherSeed(Date.now()));
    let w = 0, h = 0, running = false, last = 0;

    function spawn(y) {
      const depth = random();      // 0 = far, slow and faint; 1 = near and fast
      return {
        x: random() * (w + h * TILT) - h * TILT,
        y,
        len: 12 + depth * 46,
        speed: 420 + depth * 900,
        alpha: 0.08 + depth * 0.36,
        width: 0.6 + depth * 1.1,
      };
    }

    // One drop per ~5000 px², clamped: heavy enough to read across a room on a
    // 4K panel, light enough that the stick driving the TV keeps up. What the
    // weather then does is scale that between a downpour and a handful of
    // drips — never nothing, because rain that stops dead reads as a crash.
    function target(wet) {
      const full = Math.max(80, Math.min(420, Math.round((w * h) / 5000)));
      return Math.max(8, Math.round(full * (DRY + (1 - DRY) * wet)));
    }

    function fill(wet) {
      const want = target(wet);
      while (drops.length > want) drops.pop();
      while (drops.length < want) drops.push(spawn(random() * h));
    }

    function size() {
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
      w = canvas.clientWidth;
      h = canvas.clientHeight;
      canvas.width = Math.max(1, Math.round(w * dpr));
      canvas.height = Math.max(1, Math.round(h * dpr));
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      fill(wetness(Date.now() / 1000));
    }

    function draw(dt, wet) {
      const want = target(wet);
      const glow = 0.55 + 0.45 * wet;      // a downpour is denser and brighter
      ctx.clearRect(0, 0, w, h);
      ctx.lineCap = 'round';
      for (let i = drops.length - 1; i >= 0; i--) {
        const drop = drops[i];
        drop.y += drop.speed * dt;
        drop.x += drop.speed * TILT * dt;
        if (drop.y - drop.len > h) {
          // The bottom of the frame is the only place the weather is allowed to
          // change: rain eases off by not recycling a drop that has left, and
          // picks up by adding one above the top edge. Nothing ever pops into
          // existence, or out of it, in front of the room.
          if (drops.length > want) { drops.splice(i, 1); continue; }
          Object.assign(drop, spawn(-drop.len - random() * h * 0.4));
        }
        ctx.strokeStyle = 'rgba(196, 226, 255, ' + (drop.alpha * glow).toFixed(3) + ')';
        ctx.lineWidth = drop.width;
        ctx.beginPath();
        ctx.moveTo(drop.x, drop.y);
        ctx.lineTo(drop.x - drop.len * TILT, drop.y - drop.len);
        ctx.stroke();
      }
      if (drops.length < want) drops.push(spawn(-random() * h * 0.5));
    }

    function frame(t) {
      if (!running) return;
      const dt = Math.min(0.05, (t - last) / 1000) || 0.016;
      last = t;
      draw(dt, wetness(Date.now() / 1000));
      requestAnimationFrame(frame);
    }

    function start() {
      if (running || still.matches) return;
      size();
      running = true;
      last = performance.now();
      requestAnimationFrame(frame);
    }

    function stop() {
      running = false;
      ctx.clearRect(0, 0, w, h);
    }

    window.addEventListener('resize', () => { if (running) size(); });
    // A room that turns motion off mid-shift gets a dry city without a reload.
    still.addEventListener('change', () => (still.matches ? stop() : start()));
    start();
  }

  // --- the room -----------------------------------------------------------------
  // Where the dive lands. The wide city says a job is running; the room says who
  // is running it and how far it has got — one floor of one tower, from the
  // inside, at pixel-art scale.
  //
  // It is a canvas OUTSIDE the stage, like the rain and the plate: the camera's
  // transform is scaling the city underneath while this fades up over it, and a
  // room whose pixels were scaled by that transform would be a blur. wall/room.js
  // owns everything the room looks like; this half only decides WHICH run it is
  // showing and WHEN it is up.
  //
  // Two ways in. ?shot=room is the still: the room at full frame, no camera, for
  // the visual gate and for a human who wants to look at it. The other is the
  // director's own dive, which pushes into the hero run's lit window first — see
  // roomShot() below.

  const Room = window.WallRoom;
  const roomCanvas = document.getElementById('room');
  // Read once at load, in the idiom ?cinema and ?world already use.
  const roomParams = new URLSearchParams(window.location.search);
  const forcedRoom = roomParams.get('shot') === 'room';
  const wantedRun = roomParams.get('run') || '';

  let room = null;      // the renderer, built the first time the wall asks for it
  let roomOn = false;   // whether the room is what this wall is showing now
  // The run the dive chose, held for as long as that dive is on screen. The
  // plate rotates every seven seconds and a dive is a six-to-ten second push
  // followed by a fifteen-to-twenty second hold, so a room that kept asking the
  // plate would enter one run's window and finish on somebody else's ticket.
  // Written by the shot (roomShot below), cleared when it leaves.
  let pinnedRun = '';

  // Which run the dive is for: whichever the query string named, else the one
  // this dive pinned when it chose its window, else the one holding the brief
  // plate — alarms first, then actives, which is the same hero the spotlight is
  // already on out in the city. A pin whose run has since left the snapshot
  // falls through to the plate rather than blanking the room.
  function roomRun() {
    const named = wantedRun && runs.find((r) => r.id === wantedRun);
    const pinned = pinnedRun && runs.find((r) => r.id === pinnedRun);
    return named || pinned || runs.find((r) => r.id === plateId) || plateQueue()[0] || null;
  }

  // Show the room, or take it away. Safe to call before a snapshot has landed:
  // the room simply has nothing to draw yet, and the next one paints it.
  function roomPaint() {
    if (!roomOn || !Room || !roomCanvas) return;
    const run = roomRun();
    if (!run) return;
    if (!room) {
      // No clock is handed over. The city outside runs on the server's epoch
      // plus a skew re-measured on every snapshot; the room runs on the frame
      // clock, because a shot that is one continuous push may not be told the
      // time has moved by a second and a half between two frames.
      room = Room.create({ canvas: roomCanvas, still, random: seededRandom });
    }
    // Re-shown on every snapshot rather than once: the hero can hand over, and
    // the stage under it can climb a floor, while the room is still up. The
    // dispatcher's tint is worked out here rather than in there — the room draws
    // the city's colours, it does not decide any of them.
    room.show({ ...run, crew: crewTint(run) }, latest && latest.floors);
  }

  function roomHold(on) {
    roomOn = on;
    if (on) { roomPaint(); return; }
    if (room) room.hide();
  }

  // --- the director ---------------------------------------------------------
  // The wall can film itself. A slow camera holds the whole skyline, then goes
  // and looks at something living in it — the tower somebody is waiting on, a
  // noodle shopfront with its 麵 sign lit, a window where a light is still on,
  // the 冉 landmark — and comes back out. It is ambient: never fast, never
  // demanding, and gone the instant anybody in the room moves a mouse.
  //
  // The camera is ONE transform on the stage. No layer moves on its own, so the
  // parallax, the weather and the ceremonies keep playing at every zoom, and
  // the HUD — which is outside the stage — never learns any of this happened.
  //
  // Nothing here touches the city's fabric. Where a shot needs a coin flip it
  // comes off a wall-clock bucket, the same idiom the weather uses; the
  // buildings, shops and signs stay pure functions of a run id.

  // Everything that decides whether the director is filming, with no DOM in it,
  // so the whole truth table is one testable function. Reduced motion and an
  // explicit ?cinema=0 are absolute: neither the key nor the idle timer can
  // talk its way past them.
  function wantsCinema(s) {
    if (s.reduced || s.forced === 'off') return false;
    if (s.manual !== null) return s.manual;
    if (s.forced === 'on') return true;
    return s.idle;
  }

  // The toggle acts on what the room is seeing, including a film that the idle
  // timer started. Any other activity releases a manual "on" back to the idle
  // policy, while an explicit manual "off" stays off until `c` changes it.
  function manualAfterActivity(current, filmingNow, toggle) {
    if (toggle) return !filmingNow;
    return current === true ? null : current;
  }

  function between(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  // A shot is a rect in stage coordinates plus how much of the frame it should
  // fill and where in that frame its middle belongs; the answer is the one
  // translate/scale that puts it there. Clamped twice — the zoom to the lens's
  // ceiling, the pan so the frame is always full of city, which at zoom 1
  // collapses to the wide shot and is exactly right.
  function frameFor(rect, view, opts) {
    const o = opts || {};
    const ax = o.ax === undefined ? 0.5 : o.ax;
    const ay = o.ay === undefined ? 0.5 : o.ay;
    const s = between(Math.min(view.w * (o.fillW || 0.6) / Math.max(1, rect.w),
                               view.h * (o.fillH || 0.6) / Math.max(1, rect.h)),
                      1, o.max || MAX_ZOOM);
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    return {
      s,
      x: between(view.w * ax - s * cx, view.w * (1 - s), 0),
      y: between(view.h * ay - s * cy, view.h * (1 - s), 0),
    };
  }

  // Ken Burns. A held frame is never quite still: it creeps a little further in
  // and a little to one side, re-clamped so it cannot creep off the city.
  function creepFrom(cam, view, dx, dy) {
    const s = between(cam.s * (1 + CREEP), 1, MAX_ZOOM * 1.02);
    const cx = (view.w / 2 - cam.x) / cam.s;
    const cy = (view.h / 2 - cam.y) / cam.s;
    return {
      s,
      x: between(view.w * (0.5 + dx) - s * cx, view.w * (1 - s), 0),
      y: between(view.h * (0.5 + dy) - s * cy, view.h * (1 - s), 0),
    };
  }

  // Which tower the camera would rather be looking at: one asking for a human
  // beats one working, which beats one that has only just shipped. A tower with
  // none of those in it is not a shot.
  const SHOT_RANK = { alarm: 3, active: 2, ready: 1 };
  function towerRank(states) {
    let rank = 0;
    for (const state of states) rank = Math.max(rank, SHOT_RANK[state] || 0);
    return rank;
  }

  let filming = false;
  let shotTimer = 0;
  let current = null;       // the shot on screen, and the only thing that can be left
  let wideNext = true;      // the wide shot is what every close shot returns to
  let reel = null;          // the seeded draw this bucket's shot list comes from
  let reelBucket = -1;
  let queue = [];
  let idle = false;
  let idleTimer = 0;
  let manual = null;        // what the `c` key last said, if anything
  const forced = (() => {
    const flag = new URLSearchParams(window.location.search).get('cinema');
    return flag === '1' ? 'on' : flag === '0' ? 'off' : null;
  })();
  // Which body the city is drawn in, read once at load in the same idiom and in
  // the same breath: ?world=canvas hands it to WebGL, anything else keeps the
  // DOM. Nothing else in the page branches on it.
  const wantsCanvas =
    new URLSearchParams(window.location.search).get('world') === 'canvas';

  // Shot variety off the wall clock rather than off a counter, so two screens
  // opened in the same room are cutting roughly the same film without a byte
  // passing between them — and tomorrow's reel is not today's.
  function shotSeed(ms) { return Math.floor(ms / SHOT_SEED_MS) >>> 0; }
  function draw() {
    const bucket = shotSeed(Date.now());
    if (bucket !== reelBucket) { reelBucket = bucket; reel = seededRandom(bucket); }
    return reel();
  }
  const pick = (list) => (list.length ? list[Math.floor(draw() * list.length)] : null);
  function shuffled(list) {
    const out = list.slice();
    for (let i = out.length - 1; i > 0; i--) {
      const j = Math.floor(draw() * (i + 1));
      const swap = out[i]; out[i] = out[j]; out[j] = swap;
    }
    return out;
  }

  // Where a node is on the stage, with whatever the camera is doing divided
  // back out of it. Read in one batch per shot — never per frame.
  function cameraNow() {
    const t = window.getComputedStyle(stage).transform;
    if (!t || t === 'none') return { x: 0, y: 0, s: 1 };
    const n = t.slice(t.indexOf('(') + 1, -1).split(',').map(Number);
    return n.length === 6 && n[0] ? { x: n[4], y: n[5], s: n[0] } : { x: 0, y: 0, s: 1 };
  }

  function stageRect(node, cam) {
    const r = node.getBoundingClientRect();
    return {
      x: (r.left - cam.x) / cam.s, y: (r.top - cam.y) / cam.s,
      w: r.width / cam.s, h: r.height / cam.s,
    };
  }

  // How much clear street there is either side of a rect. Negative means a tower
  // is standing squarely in front of it — the skyline is opaque, so that
  // building is not on screen however lit it is.
  function clearanceOf(rect, towers) {
    let gap = Infinity;
    for (const t of towers) {
      gap = Math.min(gap, Math.max(t.x - (rect.x + rect.w), rect.x - (t.x + t.w)));
    }
    return gap;
  }

  const towerRects = (cam) => [...towerEls.values()].map((T) => stageRect(T.root, cam));

  // The district is a plane BEHIND the skyline, so a shopfront squarely behind a
  // tower is not a shopfront shot, it is a tower shot with a worse frame — and
  // one merely NEXT to a tower spends half its frame on dark mass. So the room
  // either side of a frontage is a score, not just a filter, and the street
  // shots take their pick from the buildings with the most of it. One batch of
  // rects per cut, never per frame.
  function onScreenBlocks(cam) {
    const towers = towerRects(cam);
    const clear = [];
    for (const B of blockEls.values()) {
      const r = stageRect(B.root, cam);
      const gap = clearanceOf(r, towers);
      if (gap > 0) clear.push({ B, r, gap });
    }
    return clear.sort((a, b) => b.gap - a.gap);
  }

  // The roomiest of them, and never fewer than three to choose between: enough
  // that the street shot is not the same corner every night, not so many that it
  // picks a doorway with a tower leaning over it.
  const roomiest = (list) => list.slice(0, Math.max(3, Math.ceil(list.length / 2)));

  const span = (lo, hi) => lo + draw() * (hi - lo);

  // --- the shot vocabulary ----------------------------------------------------
  // Each of these returns a framing, or null when the city is not currently
  // offering that shot: an empty district is skyline and towers only, and the
  // director simply does not cut to a street that is not there.

  function wideShot(view) {
    const cam = { s: 1, x: 0, y: 0 };
    return {
      kind: 'establishing', cam, move: span(MOVE_MIN, MOVE_MAX), hold: WIDE_HOLD,
      // Even the wide shot breathes: a hair of push-in over the longest hold on
      // the wall, which is what stops it reading as a paused video.
      creep: creepFrom(cam, view, draw() * 0.05 - 0.025, 0.01),
    };
  }

  function towerShot(view, cam) {
    let best = null, bestRank = 0;
    for (const T of towerEls.values()) {
      const rank = towerRank([...T.shaftEls.values()].map((S) => S.state));
      if (rank > bestRank || (rank === bestRank && rank > 0 && draw() < 0.35)) {
        best = T; bestRank = rank;
      }
    }
    if (!best) return null;
    const r = stageRect(best.root, cam);
    // The tower's shoulders and its top half — a whole tower framed head to foot
    // is the wide shot with fewer buildings in it. What is worth going in for is
    // up here: the crown, the beacon, the cars near the top of the climb, and
    // the vertical neon sign, which hangs off the mass and so needs the width.
    const rect = { x: r.x - r.w * 0.45, y: r.y - r.h * 0.04, w: r.w * 1.9, h: r.h * 0.58 };
    return shot('tower', frameFor(rect, view, { fillW: 0.6, fillH: 0.8, ax: 0.55, ay: 0.46 }), view);
  }

  function streetShot(view, cam) {
    // A shopfront with a glyph over it, at street level. The tube that only one
    // building in three carries is the better shot, so it is asked for first.
    const shops = roomiest(onScreenBlocks(cam).filter((b) => b.B.root.dataset.shop));
    if (!shops.length) return null;
    const neon = shops.filter((b) => b.B.root.dataset.neon === '1');
    const found = pick(neon.length ? neon : shops);
    // The subject is the sign, not the building: the hanging glyph is the one
    // thing at street level that says what is down there, so the camera goes to
    // it and takes the shopfront row and the wet tarmac in with it. Everything
    // out on that tarmac — a walker, a car, the tram — passes through the
    // bottom of the frame rather than under it.
    const g = stageRect(found.B.glyph, cam);
    const top = g.y - g.h * 1.6;
    const rect = {
      x: g.x + g.w / 2 - 55, w: 110,
      y: top, h: Math.max(24, view.h - top),
    };
    return shot('street', frameFor(rect, view, { fillW: 0.5, fillH: 0.92, ax: 0.5, ay: 0.5 }), view);
  }

  function windowShot(view, cam) {
    // One window with somebody still behind it. The panes keep their own hours,
    // so the shot asks the ones that are lit at this minute — on the largest
    // facade the skyline is not standing in front of, because a close shot wants
    // a wall of building around the light rather than a roofline.
    const facades = onScreenBlocks(cam).sort((a, b) => b.r.w * b.r.h - a.r.w * a.r.h);
    let found = null;
    for (const b of facades) {
      const lit = b.B.occupants
        .map((node) => ({ node, lum: Number(window.getComputedStyle(node).opacity) }))
        .filter((p) => p.lum > 0.45)
        .sort((p, q) => q.lum - p.lum);
      if (lit.length) { found = { b, pane: lit[0].node }; break; }
    }
    if (!found) return null;
    const r = stageRect(found.pane, cam);
    // The facade decides the width and the lit pane decides the height: a window
    // this small is never going to fill a frame, so what the shot frames is the
    // wall it is burning in, with the light itself on the centre line.
    const rect = {
      x: found.b.r.x + found.b.r.w / 2 - found.b.r.w * 1.1, w: found.b.r.w * 2.2,
      y: r.y + r.h / 2 - 34, h: 68,
    };
    return shot('window', frameFor(rect, view, { fillW: 0.55, fillH: 0.42, ax: 0.5, ay: 0.5 }), view);
  }

  function landmarkShot(view, cam) {
    const node = district.querySelector('.block--landmark');
    if (!node) return null;
    const r = stageRect(node, cam);
    // The dedication stands in the back band, so on a busy skyline a tower can
    // be squarely in front of it. Filming that is filming the tower: when the
    // 冉 sign is not on screen there is no landmark shot, and the reel moves on.
    if (clearanceOf(r, towerRects(cam)) <= 0) return null;
    // Its top two thirds — the stepped shoulder, the mast lamp and the sign —
    // held wide enough that the monument has district either side of it.
    const rect = { x: r.x + r.w / 2 - r.w * 1.6, w: r.w * 3.2, y: r.y - r.h * 0.08, h: r.h * 0.66 };
    return shot('landmark', frameFor(rect, view, { fillW: 0.44, fillH: 0.7, ax: 0.5, ay: 0.48 }), view);
  }

  // THE DIVE. Every other shot here stops at the glass. This one goes through
  // it: the camera pushes into the lit storey of the run the wall is already
  // spotlighting, and at the end of that push the room fades up over it at full
  // frame — a person, at a desk, working on the ticket the plate just named.
  // The push underneath keeps creeping while the room holds, so coming back out
  // is a pull-back from where the dive left off rather than a cut.
  //
  // No spotlit run, no dive: on an empty wall, and in the canvas world where
  // there are no storeys to film, this shot simply is not on offer.
  function roomShot(view, cam) {
    const lit = city.querySelector('.shaft[data-spot="1"] .shaft__work');
    if (!lit) return null;
    const r = stageRect(lit, cam);
    if (!(r.w > 0) || !(r.h > 0)) return null;
    // Whose window this is, read HERE and never again. `[data-spot="1"]` is on
    // the shaft the plate is currently pinned to, and the plate hands over
    // every seven seconds — well inside one dive's own push and hold. Pinning
    // the id with the window is what keeps the room showing the run the camera
    // actually went in through instead of whoever holds the plate on arrival.
    const dived = plateId;
    // The storey itself is a few pixels of light. What the push frames is the
    // window around it — enough facade to know which building this is, held on
    // the centre line so the room lands on the same middle.
    const rect = { x: r.x + r.w / 2 - 24, w: 48, y: r.y + r.h / 2 - 14, h: 28 };
    const cell = frameFor(rect, view, { fillW: 0.42, fillH: 0.42, ax: 0.5, ay: 0.5 });
    return {
      kind: 'room', cam: cell,
      move: span(MOVE_MIN, MOVE_MAX),
      hold: span(ROOM_MIN, ROOM_MAX),
      creep: creepFrom(cell, view, 0.01, 0.008),
      enter: () => { pinnedRun = dived; roomHold(true); },
      leave: () => { pinnedRun = ''; roomHold(false); },
    };
  }

  // A close shot's timing, one place: the move eases in over seconds, the hold
  // is long, and the drift across that hold is small and always inward.
  function shot(kind, cam, view) {
    return {
      kind, cam,
      move: span(MOVE_MIN, MOVE_MAX),
      hold: span(HOLD_MIN, HOLD_MAX),
      creep: creepFrom(cam, view, draw() * 0.06 - 0.03, draw() * 0.04 - 0.02),
    };
  }

  const SHOTS = {
    tower: towerShot, street: streetShot, window: windowShot,
    landmark: landmarkShot, room: roomShot,
  };

  function detailShot(view, cam) {
    if (!queue.length) {
      // One rotation of what the city can currently offer, shuffled. The
      // landmark is deliberately not in every rotation — a dedication the camera
      // visits every ninety seconds stops being a dedication.
      const kinds = ['tower', 'street', 'window', 'room'];
      if (draw() < 0.45) kinds.push('landmark');
      queue = shuffled(kinds);
    }
    while (queue.length) {
      const found = SHOTS[queue.shift()](view, cam);
      if (found) return found;
    }
    return null;
  }

  // --- the loop ---------------------------------------------------------------

  function moveCamera(cam, ms, ease) {
    stage.style.transition = 'transform ' + Math.round(ms) + 'ms ' + ease;
    stage.style.transform = 'translate(' + cam.x.toFixed(2) + 'px, ' + cam.y.toFixed(2)
      + 'px) scale(' + cam.s.toFixed(4) + ')';
  }

  // The one way out of a shot, taken by all four exits: the natural cut, a
  // resize that re-frames, the `c` key, and somebody walking in. A shot that
  // put something on the wall the camera cannot take back off it — so far only
  // the dive, whose room is a canvas over the whole stage — is undone here,
  // once, whichever of the four happened. Cancelling the timer without this is
  // how a resize during a hold used to leave the room covering the next shot.
  function leaveShot() {
    clearTimeout(shotTimer);
    shotTimer = 0;
    const next = current;
    current = null;
    if (!next) return;
    if (next.leave) next.leave();
  }

  function nextShot() {
    if (!filming) return;
    const view = { w: stage.clientWidth, h: stage.clientHeight };
    // One read of where the camera currently is, shared by every rect this cut
    // measures: the shot is planned from a single frame of the DOM.
    const cam = cameraNow();
    const next = (wideNext ? null : detailShot(view, cam)) || wideShot(view);
    // Every close shot is bracketed by the wide one; a rotation that ran out of
    // live candidates just gets another establishing hold, which is the right
    // answer for a city with nothing in it.
    wideNext = next.kind !== 'establishing';
    // From here on this is the shot on screen, and the only one leaveShot() can
    // put back. It is set before the move rather than after it so a resize
    // during the push leaves the shot it interrupted.
    current = next;
    document.body.dataset.shot = next.kind;
    // Seconds of easing toward where the camera already is would be seconds of
    // nothing — which is exactly what the first cut of the film would be, since
    // it opens on the wide shot the wall is already showing. Go straight to the
    // hold instead, and let the drift be the first thing that moves.
    const move = Math.abs(cam.s - next.cam.s) < 0.005
      && Math.abs(cam.x - next.cam.x) < 2 && Math.abs(cam.y - next.cam.y) < 2 ? 0 : next.move;
    moveCamera(next.cam, move, 'var(--ease-io)');
    shotTimer = setTimeout(() => {
      if (!filming) return;
      // The push has landed. A shot that has somewhere further to take the wall
      // — so far only the dive — arrives here and goes inside; the drift under
      // it carries on either way.
      if (next.enter) next.enter();
      moveCamera(next.creep, next.hold, 'linear');
      shotTimer = setTimeout(() => {
        leaveShot();
        nextShot();
      }, next.hold);
    }, move);
  }

  function syncCinema() {
    const want = wantsCinema({ reduced: still.matches, forced, manual, idle });
    if (want === filming) return;
    filming = want;
    // Whatever was on screen is over, whichever direction this is going: the
    // shot's own leave hook is on a timer this cancels, so it runs here instead.
    leaveShot();
    document.body.dataset.cinema = want ? '1' : '0';
    if (want) {
      wideNext = true;
      queue = [];
      nextShot();
      return;
    }
    // Somebody is in the room. Come home quickly and get out of the way.
    delete document.body.dataset.shot;
    moveCamera({ s: 1, x: 0, y: 0 }, CUT_MS, 'var(--ease)');
  }

  // Any pointer or key resets the idle clock. Ordinary activity also dismisses
  // a manually-started film; `c` is the one input that toggles instead.
  function stirred(toggle) {
    idle = false;
    manual = manualAfterActivity(manual, filming, toggle === true);
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { idle = true; syncCinema(); }, CINEMA_IDLE_MS);
    syncCinema();
  }

  function director() {
    document.body.dataset.cinema = '0';
    // ?shot=room is the still: the room, at full frame, held, with the camera
    // parked at the wide shot behind it. Nothing on this wall moves except the
    // room's own loop — which is what makes it the frame the gate can measure
    // and a human can stare at. Reduced motion takes the loop, not the room.
    if (forcedRoom) {
      document.body.dataset.shot = 'room';
      roomHold(true);
      return;
    }
    for (const ev of ['pointermove', 'pointerdown', 'wheel', 'touchstart']) {
      window.addEventListener(ev, stirred, { passive: true });
    }
    window.addEventListener('keydown', (ev) => {
      const isToggle = ev.key === 'c' || ev.key === 'C';
      // The two off-switches are absolute — under either one `c` is ordinary
      // activity and cannot leave a manual film waiting to resume later.
      stirred(isToggle && !still.matches && forced !== 'off');
    });
    // A room that turns motion off mid-film gets the wide shot back at once.
    still.addEventListener('change', syncCinema);
    // A resized wall re-frames rather than holding a shot measured for the old
    // one. Resizing is not somebody asking for the wall, so it never disengages.
    let reframe = 0;
    window.addEventListener('resize', () => {
      if (!filming) return;
      clearTimeout(reframe);
      reframe = setTimeout(() => { leaveShot(); nextShot(); }, 400);
    });
    stirred();
  }

  // --- the other body ------------------------------------------------------------
  // The canvas world, and the engine it needs, are fetched only when the query
  // string asked for them: an ordinary wall must not pay 1.4 MB of WebGL for a
  // city it draws in CSS. They load in order, one after the other, because
  // world-canvas.js reads `Phaser` off the window the moment it is parsed.

  function loadScripts(sources, done) {
    let i = 0;
    const next = () => {
      if (i === sources.length) { done(); return; }
      const tag = document.createElement('script');
      tag.src = sources[i++];
      tag.addEventListener('load', next);
      // A missing bundle is a dark city, not a broken page: the wall keeps its
      // clock, its plate and its ticker, and says so in the console once.
      tag.addEventListener('error', () => console.error('wall: cannot load ' + tag.src));
      document.head.append(tag);
    };
    next();
  }

  // The canvas world before its engine has landed: it holds the last scene and
  // hands it straight over the moment world-canvas.js is on the page. One frame
  // of empty stage, and then the city — with the DOM world's nodes hidden from
  // the start, so nothing is ever drawn twice or populated by both.
  function canvasWorld() {
    let live = null;
    let last = null;
    let spotId = '';
    for (const sel of ['svg.sky', '#district', '.dawn', '.haze', '.traffic',
                       '.street', '#life', '#city']) {
      const node = document.querySelector(sel);
      // SVG elements do not consistently reflect the HTML `hidden` property;
      // set the attribute the shared [hidden] rule actually matches.
      if (node) node.setAttribute('hidden', '');
    }
    loadScripts(CANVAS_SCRIPTS, () => {
      const factory = window.WallCanvasWorld;
      if (!factory || !window.Phaser) return;
      live = factory.create({ parent: stage, still, clock: () => Date.now() / 1000 + skew });
      if (last) live.render(last);
      live.spot(spotId);
    });
    return {
      render(scene) { last = scene; if (live) live.render(scene); },
      spot(runId) { spotId = runId; if (live) live.spot(runId); },
      tick(at) { if (live) live.tick(at); },
    };
  }

  // --- start of shift -----------------------------------------------------------

  const world = wantsCanvas ? canvasWorld() : domWorld;

  render();
  connect();
  rain();
  paintSky();
  director();
  // A room that turns motion off mid-shift gets the static sky back too.
  still.addEventListener('change', paintSky);
  setInterval(tick, 1000);
  setTimeout(() => { boot.hidden = true; }, 3100);
})();
