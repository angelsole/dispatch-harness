'use strict';
// Ghost Shift's renderer. Subscribes to /api/stream (SSE), falls back to polling
// /api/runs, and builds the city: one tower per project, one lit car per run.
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
  const POLL_MS = 2000;    // only used when SSE is unavailable
  const BRIEF_MS = 7000;   // how long one run holds the brief plate
  const SWAP_MS = 200;     // the gap the plate is empty for, mid hand-off
  const MAX_TOWER_WIDTH_RUNS = 8; // later shafts still render without widening the tower
  const TILT = 0.2;        // how far off vertical the rain falls
  const CEREMONY_S = 6;    // the shipping beat; must match --ceremony in wall.css
  const RAIN_LAG = 420;    // the haze trails the rain by seven minutes
  const DRY = 0.06;        // a near-dry spell is drips, never a dead canvas
  const DAWN_H = 6.5;      // local hour the sky is coldest at
  const DAWN_RAMP = 2.5;   // hours either side of it that the cooling spans
  const WEATHER_SEED_MS = 15 * 60 * 1000; // nearby screens share a rain field

  const still = window.matchMedia('(prefers-reduced-motion: reduce)');

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

  const GLYPH = {
    opus: 'g-opus', codex: 'g-codex', gate: 'g-gate', pr: 'g-pr', demo: 'g-demo',
    setup: 'g-setup', sync: 'g-sync', skipped: 'g-skipped', alarm: 'g-alarm',
    deferred: 'g-skipped',   // parked, not working — the same stood-down mark

    done: 'g-done', failed: 'g-failed', unknown: 'g-unknown',
  };
  const STATE_GLYPH = { alarm: 'g-alarm', ready: 'g-done', failed: 'g-failed' };

  const city = document.getElementById('city');
  const district = document.getElementById('district');
  const ghostLayer = document.getElementById('ghost');
  const life = document.getElementById('life');
  const movers = document.getElementById('movers');
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
  let runs = [];
  let towers = [];
  let floors = 6;
  let blocks = [];              // this week's buildings, newest included
  let ghosts = [];              // last week's, as bare silhouettes
  let week = { ships: 0, life: {} };
  let signSeconds = 0;           // supplied with the first server snapshot
  let ghostKey = '';            // the silhouette layer is rebuilt only when it changes
  let skyline = new Set();      // the run ids the server is standing in the city
  const towerEls = new Map();   // project -> tower elements (incl. its shafts)
  const blockEls = new Map();   // run id -> building element, built once and left alone
  let plateId = '';             // the run currently holding the brief plate
  let plateSince = 0;
  let swapTimer = 0;            // set while the plate is empty between two runs
  let commsKey = '';            // last ticker text, so it only restarts on change
  const commsSeen = new Map();  // run id -> the line already drawn for it

  const now = () => Math.floor(Date.now() / 1000) + skew;

  // A crew member keeps the same tint whoever else is on the wall, so the room
  // learns "the pale blue lamp is Reinier" — an index into the current runs
  // would repaint everyone every time somebody's queue emptied.
  function crewTint(run) {
    if (run.ownerKind === 'synthetic') return SYNTHETIC_TINT;
    if (run.ownerKind === 'unowned') return UNOWNED_TINT;
    let h = 0;
    for (let i = 0; i < run.owner.length; i++) h = (h * 31 + run.owner.charCodeAt(i)) >>> 0;
    return CREW_TINTS[h % CREW_TINTS.length];
  }

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

  // --- one run: a car in a shaft ---------------------------------------------

  function makeShaft() {
    const root = el('div', 'shaft');
    const col = el('i', 'shaft__col');
    col.append(el('i', 'shaft__lit'));
    const rail = el('i', 'shaft__rail');
    // Everything that rides with the car goes in the lift: one transform moves
    // the car, its crew lamp and the spotlight bloom together.
    const lift = el('i', 'shaft__lift');
    lift.append(el('i', 'shaft__halo'), el('i', 'shaft__car'));
    root.append(col, rail, lift);
    return { root, state: '' };
  }

  function paintShaft(S, run) {
    S.root.dataset.state = run.state;
    S.root.dataset.actor = run.actorKey;
    S.root.title = run.id + ' — ' + run.stage;   // for a desk browser; the TV never hovers
    // Half a floor up from the slab it stopped on, so a car reads as standing
    // on that floor rather than balancing on the line between two. The same
    // number twice: a percentage for the lift, a factor for the lit column.
    const level = (run.floor + 0.55) / floors;
    S.root.style.setProperty('--pos', (level * 100).toFixed(2) + '%');
    S.root.style.setProperty('--lvl', level.toFixed(4));
    S.root.style.setProperty('--crew', crewTint(run));
    // --age fast-forwards the completion animation, so a browser opening
    // halfway through a flare joins the city where it already is. Written once
    // per state change: rewriting it every frame would restart the animation.
    if (S.state !== run.state) {
      S.state = run.state;
      S.root.style.setProperty('--age', String(Math.max(0, now() - (run.since || now()))));
    }
  }

  // --- one project: a tower ---------------------------------------------------

  // Neon stock for the vertical project signs: cold noir hues only — red stays
  // reserved for alarms. Which sign a project gets rides the same hash slices
  // that pick its silhouette, so the colour is stable run to run.
  const SIGN_TINTS = ['#7fd4ec', '#ffc27d', '#9fe8b8', '#e8e2cf', '#8fb0ff'];

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
    // The shipping cascade goes over the facade and under the ladder: the light
    // climbs the windows, never the shafts. Its child is the travelling glow;
    // the wrapper holds the storey mask still while that glow moves behind it.
    const cascade = el('i', 'tower__cascade');
    cascade.append(el('i'));
    const slabs = el('i', 'tower__floors');
    const shafts = el('div', 'tower__shafts');
    mass.append(windows, cascade, slabs, shafts);
    const sign = el('div', 'tower__sign');
    // The wet-tarmac reflection reuses the window-grid styling wholesale (same
    // class, same per-shape storey variables) and restyles itself via the
    // modifier — one source of truth for what a lit facade looks like.
    const mirror = el('i', 'tower__windows tower__mirror');
    const base = el('div', 'tower__base');
    root.append(crown, mass, sign, mirror, base);
    return { root, shafts, base, sign, ready: '', shaftEls: new Map() };
  }

  function paintTower(T, tower, byId) {
    const n = tower.runIds.length;
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
    const shipped = tower.runIds.find((id) => (byId.get(id) || {}).state === 'ready') || '';
    if (shipped !== T.ready) {
      // Dropping the selector before changing --age gives each shipped run its
      // own animation timeline. Without the reflow, a second run shipping from
      // the same tower while the first is still present inherits the first
      // run's completed animation instead of receiving a ceremony.
      T.root.dataset.ready = '0';
      T.ready = shipped;
      const run = byId.get(shipped);
      if (run) T.root.style.setProperty('--age', String(Math.max(0, now() - (run.since || now()))));
      void T.root.offsetWidth;
    }
    T.root.dataset.ready = shipped ? '1' : '0';
    // A tower grows gently with the work standing in it — enough that a busy
    // repo reads as the tall one, not enough to turn the skyline into a chart.
    T.root.style.height = Math.min(94, 48 + n * 8) + '%';
    T.root.style.width = (3.4 + Math.min(n, MAX_TOWER_WIDTH_RUNS) * 2.2).toFixed(1) + 'rem';
    T.root.style.setProperty('--floors', String(floors));
    T.base.dataset.label = tower.label;
    T.sign.textContent = tower.label;
    T.root.style.setProperty('--sign', SIGN_TINTS[(tower.shape * 7 + tower.crown) % SIGN_TINTS.length]);
    T.root.style.setProperty('--drift', ((tower.shape * 3.1 + tower.crown * 5.7) % 17).toFixed(1) + 's');

    for (const [id, S] of T.shaftEls) {
      if (!tower.runIds.includes(id)) { S.root.remove(); T.shaftEls.delete(id); }
    }
    let cursor = null;
    for (const id of tower.runIds) {
      const run = byId.get(id);
      if (!run) continue;
      let S = T.shaftEls.get(id);
      if (!S) { S = makeShaft(); T.shaftEls.set(id, S); }
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
    mass.append(el('i', 'tower__windows block__windows'), el('i', 'block__shop'));
    // The sign is the only thing on a building that names anybody: a small neon
    // in the dispatcher's own crew tint, cooling to the district's neutral
    // within --sign-life of landing. No zones, no lanes, nothing cumulative.
    root.append(el('i', 'block__crown'), mass, el('i', 'block__sign'));
    return { root };
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
    B.root.style.setProperty('--crew', crewTint(b));
    // Same idiom as the completion moment: a browser opening this afternoon
    // fast-forwards a building that landed this morning to where it already is,
    // rather than replaying every settle in the week at once.
    const age = paintStaticSign(B, b);
    B.root.style.setProperty('--age', String(age));
    B.root.title = b.id + (b.project ? ' — ' + b.project : '');
  }

  function renderDistrict() {
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
    district.dataset.shops = week.life && week.life.shops ? '1' : '0';
  }

  // Last week, flattened: a height and a plot, drawn once per change of shape.
  // No windows, no signs, no types — if you can tell what shipped last week from
  // this layer, it is doing too much.
  function renderGhost() {
    const key = ghosts.map((g) => g.x + ':' + g.storeys).join(',');
    if (key === ghostKey) return;
    ghostKey = key;
    ghostLayer.textContent = '';
    ghostLayer.hidden = ghosts.length === 0;
    for (const g of ghosts) {
      const shape = el('i', 'ghost__block');
      shape.style.setProperty('--x', (g.x * 100).toFixed(2) + '%');
      shape.style.setProperty('--storeys', String(g.storeys));
      ghostLayer.append(shape);
    }
  }

  // Ambient life, scaled to the week's ship count by the server. Movers are
  // created and removed rather than hidden, so an empty week costs the page
  // nothing, and their lanes come from their index alone — two screens standing
  // side by side have the same street.
  function renderLife() {
    const plan = week.life || {};
    const want = Math.max(0, Math.floor(Number(plan.movers) || 0));
    while (movers.childElementCount > want) movers.lastElementChild.remove();
    while (movers.childElementCount < want) {
      const slot = movers.childElementCount;
      const mover = el('i', 'life__mover');
      mover.dataset.kind = slot % 2 ? 'robot' : 'car';
      mover.style.setProperty('--lane', ((7 + slot * 23) % 88) + '%');
      mover.style.setProperty('--slot', String(slot));
      mover.append(el('i'));
      movers.append(mover);
    }
    life.dataset.tram = plan.tram ? '1' : '0';
    life.hidden = want === 0 && !plan.tram;
  }

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

  // The plate and the skyline tell the same story twice, so they are lit
  // together: the featured run's car gets the searchbeam and its building gets
  // named in light. One glance has to connect the two.
  function applySpot() {
    let lit = false;
    for (const T of towerEls.values()) {
      let hit = false;
      for (const [id, S] of T.shaftEls) {
        const on = id === plateId;
        S.root.dataset.spot = on ? '1' : '0';
        hit = hit || on;
      }
      T.root.dataset.spot = hit ? '1' : '0';
      lit = lit || hit;
    }
    // With a beam on one building the rest of the city steps back, which is
    // what turns "brighter" into "that one".
    city.dataset.spot = lit ? '1' : '0';
  }

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
    const byId = new Map(runs.map((r) => [r.id, r]));
    city.dataset.empty = towers.length ? '0' : '1';
    document.body.dataset.quiet = towers.length ? '0' : '1';
    // The standby plate used to fire on an empty skyline. With a district that
    // accretes, "nothing live" is a normal Thursday evening on a week that
    // shipped nine things, and the plate would be saying the wrong sentence over
    // a full city. It now needs a genuinely empty week — nothing standing AND
    // nothing climbing; anything else gets the quiet line instead.
    document.body.dataset.idle = towers.length ? 'off' : blocks.length ? 'rest' : 'empty';
    rest.textContent = blocks.length
      ? 'DISTRICT AT REST · ' + blocks.length + (blocks.length === 1 ? ' SHIP' : ' SHIPS')
        + ' THIS WEEK · NOTHING CLIMBING'
      : '';

    renderGhost();
    renderDistrict();
    renderLife();

    for (const [project, T] of towerEls) {
      if (!towers.some((t) => t.project === project)) { T.root.remove(); towerEls.delete(project); }
    }
    let cursor = null;
    for (const tower of towers) {
      let T = towerEls.get(tower.project);
      if (!T) { T = makeTower(); towerEls.set(tower.project, T); }
      paintTower(T, tower, byId);
      cursor = place(city, T.root, cursor);
    }

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
    // Reduced-motion disables the cooling animation. Keep its static state
    // honest by dropping the tint when the same server-owned lifetime expires.
    for (const b of blocks) {
      const B = blockEls.get(b.id);
      if (B) paintStaticSign(B, b);
    }
    paintSky();
  }

  function apply(snapshot) {
    skew = (snapshot.at || 0) - Math.floor(Date.now() / 1000);
    runs = Array.isArray(snapshot.runs) ? snapshot.runs : [];
    towers = Array.isArray(snapshot.towers) ? snapshot.towers : [];
    floors = Array.isArray(snapshot.floors) && snapshot.floors.length ? snapshot.floors.length : 6;
    blocks = Array.isArray(snapshot.city) ? snapshot.city : [];
    ghosts = Array.isArray(snapshot.ghost) ? snapshot.ghost : [];
    week = snapshot.week && typeof snapshot.week === 'object' ? snapshot.week : { ships: 0, life: {} };
    skyline = new Set(towers.flatMap((t) => t.runIds));
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

  render();
  connect();
  rain();
  paintSky();
  // A room that turns motion off mid-shift gets the static sky back too.
  still.addEventListener('change', paintSky);
  setInterval(tick, 1000);
  setTimeout(() => { boot.hidden = true; }, 3100);
})();
