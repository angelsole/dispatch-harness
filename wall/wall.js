'use strict';
// The Wall's renderer. Subscribes to /api/stream (SSE), falls back to polling
// /api/runs, and builds the city: one tower per project, one lit car per run.
// Towers and cars are created once and mutated in place — a full re-render
// would restart every CRT animation, and would teleport a car that is supposed
// to be seen climbing. No network call ever leaves this origin.

(function () {
  const POLL_MS = 2000;    // only used when SSE is unavailable
  const BRIEF_MS = 7000;   // how long one run holds the brief plate
  const FRESH_S = 900;     // a finished run stays fully lit this long
  const COLD_S = 10800;    // ...then dims to a warm ember over this long

  // Two colour systems, deliberately kept apart: the ACTOR neon (which model
  // owns the current stage) lights the car and the brief plate, and the CREW
  // tint (who dispatched the run) only ever paints the little vehicle beside
  // it. Desaturated on purpose — a crew tint must never read as live state.
  // Five well-separated hues rather than many near-neighbours: two crew members
  // sharing a tint is survivable, two crew members with tints you cannot tell
  // apart from the sofa is not.
  const CREW_TINTS = ['#e8cfa6', '#a9c9de', '#e5b3c2', '#b3d4bd', '#c6bce0'];
  const SYNTHETIC_TINT = '#f2eee2';   // milk-white. Synthetics do not bleed red.
  const UNOWNED_TINT = '#7c8b96';
  const SHIP = { human: 'g-spinner', synthetic: 'g-drone', unowned: 'g-unregistered' };

  const GLYPH = {
    opus: 'g-opus', codex: 'g-codex', gate: 'g-gate', pr: 'g-pr', demo: 'g-demo',
    setup: 'g-setup', sync: 'g-sync', skipped: 'g-skipped', alarm: 'g-alarm',
    done: 'g-done', failed: 'g-failed', unknown: 'g-unknown',
  };
  const STATE_GLYPH = { alarm: 'g-alarm', ready: 'g-done', failed: 'g-failed' };

  const city = document.getElementById('city');
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
  const towerEls = new Map();   // project -> tower elements (incl. its shafts)
  let plateId = '';             // the run currently holding the brief plate
  let plateSince = 0;
  let commsKey = '';            // last ticker text, so it only restarts on change

  const now = () => Math.floor(Date.now() / 1000) + skew;

  // A crew member keeps the same tint whoever else is on the wall, so the room
  // learns "the pale blue spinner is Reinier" — an index into the current runs
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

  function svg(tag) { return document.createElementNS('http://www.w3.org/2000/svg', tag); }

  function glyph(cls) {
    const node = svg('svg');
    node.setAttribute('class', cls);
    node.appendChild(svg('use'));
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

  // A finished run leaves its windows warm and then dims — recent work stays
  // visible on the skyline for a while, but never as bright as live work, and
  // never all the way out: its tower is on the wall because of it.
  function fade(run) {
    if (isLive(run)) return 1;
    const age = now() - (run.since || now());
    const t = Math.max(0, Math.min(1, (age - FRESH_S) / (COLD_S - FRESH_S)));
    return Math.round((1 - t * 0.72) * 100) / 100;
  }

  // --- one run: a car in a shaft ---------------------------------------------

  function makeShaft() {
    const root = el('div', 'shaft');
    const col = el('i', 'shaft__col');
    const rail = el('i', 'shaft__rail');
    const car = el('i', 'shaft__car');
    const ship = glyph('shaft__ship');
    root.append(col, rail, car, ship);
    return { root, ship };
  }

  function paintShaft(S, run) {
    S.root.dataset.state = run.state;
    S.root.dataset.actor = run.actorKey;
    S.root.title = run.id + ' — ' + run.stage;   // for a desk browser; the TV never hovers
    // Half a floor up from the slab it stopped on, so a car reads as standing
    // on that floor rather than balancing on the line between two.
    S.root.style.setProperty('--pos', ((run.floor + 0.55) / floors * 100).toFixed(2) + '%');
    S.root.style.setProperty('--crew', crewTint(run));
    S.root.style.setProperty('--fade', String(fade(run)));
    setGlyph(S.ship, SHIP[run.ownerKind] || SHIP.human);
  }

  // --- one project: a tower ---------------------------------------------------

  function makeTower() {
    const root = el('section', 'tower');
    const sweep = el('div', 'tower__sweep');
    const crown = el('div', 'tower__crown');
    const beacon = el('div', 'tower__beacon');
    crown.append(beacon);
    const mass = el('div', 'tower__mass');
    const windows = el('i', 'tower__windows');
    const slabs = el('i', 'tower__floors');
    const shafts = el('div', 'tower__shafts');
    mass.append(windows, slabs, shafts);
    const base = el('div', 'tower__base');
    root.append(sweep, crown, mass, base);
    return { root, shafts, base, shaftEls: new Map() };
  }

  function paintTower(T, tower, byId) {
    const n = tower.runIds.length;
    T.root.dataset.project = tower.project;
    T.root.dataset.shape = String(tower.shape);
    T.root.dataset.crown = String(tower.crown);
    T.root.dataset.known = tower.known ? '1' : '0';
    T.root.dataset.alarm = tower.alarm ? '1' : '0';
    T.root.dataset.ready =
      tower.runIds.some((id) => (byId.get(id) || {}).state === 'ready') ? '1' : '0';
    // A tower grows gently with the work standing in it — enough that a busy
    // repo reads as the tall one, not enough to turn the skyline into a chart.
    T.root.style.height = Math.min(94, 48 + n * 8) + '%';
    T.root.style.width = (3.4 + n * 2.2).toFixed(1) + 'rem';
    T.root.style.setProperty('--floors', String(floors));
    T.base.textContent = tower.label;

    for (const [id, S] of T.shaftEls) {
      if (!tower.runIds.includes(id)) { S.root.remove(); T.shaftEls.delete(id); }
    }
    for (const id of tower.runIds) {
      const run = byId.get(id);
      if (!run) continue;
      let S = T.shaftEls.get(id);
      if (!S) { S = makeShaft(); T.shaftEls.set(id, S); }
      paintShaft(S, run);
      T.shafts.append(S.root);   // a no-op when it is already in this position
    }
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
    plate.root.style.setProperty('--accent', 'var(--' + run.actorKey + ')');
    setGlyph(plate.glyph, glyphFor(run));
    plate.project.textContent = run.projectLabel;
    plate.floor.textContent = run.floorName;
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

  function tickPlate() {
    const queue = plateQueue();
    if (queue.length === 0) { plate.root.hidden = true; plateId = ''; return; }
    let i = queue.findIndex((r) => r.id === plateId);
    if (i === -1) { i = 0; plateSince = Date.now(); }
    else if (queue.length > 1 && Date.now() - plateSince >= BRIEF_MS) {
      i = (i + 1) % queue.length;
      plateSince = Date.now();
    }
    plateId = queue[i].id;
    plate.root.hidden = false;
    paintPlate(queue[i], i, queue.length);
  }

  // --- the comms ticker --------------------------------------------------------
  // The tail of every live run's feed.log, in one line across the bottom: the
  // running commentary the panels used to carry, at a size the room can read.

  function tickComms() {
    const items = [];
    for (const run of runs) {
      if (!isLive(run)) continue;
      const last = run.feed[run.feed.length - 1];
      if (last) items.push({ id: run.id, text: last.text, src: last.src || 'opus' });
    }
    const hidden = towers.reduce((n, t) => n + t.hiddenIds.length, 0);
    const key = items.map((i) => i.id + i.text).join('|') + '#' + hidden;
    if (key === commsKey) return;
    commsKey = key;
    comms.hidden = items.length === 0;
    if (!items.length) return;

    commsText.textContent = '';
    let chars = 0;
    for (const item of items) {
      const line = el('span', 'comms__line');
      line.dataset.src = item.src;
      line.append(el('b', 'comms__id', item.id + ' '), el('span', 'comms__body', item.text));
      commsText.append(line, el('span', 'comms__sep', '·'));
      chars += item.id.length + item.text.length + 4;
    }
    if (hidden) {
      commsText.append(el('span', 'comms__line', '+' + hidden + ' MORE RUNNING'));
      chars += 18;
    }
    // Scroll speed, not scroll duration: a long ticker must not race.
    commsText.style.setProperty('--secs', Math.max(24, Math.round(chars * 0.34)) + 's');
  }

  // --- the whole wall ----------------------------------------------------------

  function render() {
    const byId = new Map(runs.map((r) => [r.id, r]));
    city.dataset.empty = towers.length ? '0' : '1';
    document.body.dataset.quiet = runs.length ? '0' : '1';

    for (const [project, T] of towerEls) {
      if (!towers.some((t) => t.project === project)) { T.root.remove(); towerEls.delete(project); }
    }
    for (const tower of towers) {
      let T = towerEls.get(tower.project);
      if (!T) { T = makeTower(); towerEls.set(tower.project, T); }
      paintTower(T, tower, byId);
      city.append(T.root);
    }

    counts.textContent = '';
    counts.hidden = runs.length === 0;
    const tally = [
      ['active', runs.filter((r) => r.state === 'active').length],
      ['alarm', runs.filter((r) => r.state === 'alarm').length],
      ['ready', runs.filter((r) => r.state === 'ready').length],
      ['failed', runs.filter((r) => r.state === 'failed').length],
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
  }

  // Once a second: the clock, the live timer on the plate, whether the plate
  // should move on, and how far the finished runs have dimmed.
  function tick() {
    const d = new Date((Date.now() / 1000 + skew) * 1000);
    clock.textContent = [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, '0')).join(':');
    for (const run of runs) {
      if (isLive(run)) continue;
      const S = (towerEls.get(run.project) || { shaftEls: new Map() }).shaftEls.get(run.id);
      if (S) S.root.style.setProperty('--fade', String(fade(run)));
    }
    tickPlate();
  }

  function apply(snapshot) {
    skew = (snapshot.at || 0) - Math.floor(Date.now() / 1000);
    runs = Array.isArray(snapshot.runs) ? snapshot.runs : [];
    towers = Array.isArray(snapshot.towers) ? snapshot.towers : [];
    floors = Array.isArray(snapshot.floors) && snapshot.floors.length ? snapshot.floors.length : 6;
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

  render();
  connect();
  setInterval(tick, 1000);
  setTimeout(() => { boot.hidden = true; }, 3100);
})();
