'use strict';
// The Wall's renderer. Subscribes to /api/stream (SSE), falls back to polling
// /api/runs, and paints run panels. Panels are created once and mutated in
// place: a full re-render would restart the CRT animations every second.
// No network call ever leaves this origin.

(function () {
  const POLL_MS = 2000;   // only used when SSE is unavailable

  // Two colour systems, deliberately kept apart: the ACTOR neon (which model
  // owns the current stage) accents the run panels, and the CREW tint (who
  // dispatched them) only ever paints lane chrome — header bar, name, spine.
  // Muted on purpose, so a lane never competes with a live panel for attention.
  // Deliberately desaturated: pastels read as identity paint, neon reads as
  // live state, and the eye never mistakes a lane for a working panel.
  // Five well-separated hues rather than many near-neighbours: two crew members
  // sharing a tint is survivable, two crew members with tints you cannot tell
  // apart from the sofa is not.
  const CREW_TINTS = ['#e8cfa6', '#a9c9de', '#e5b3c2', '#b3d4bd', '#c6bce0'];
  const SYNTHETIC_TINT = '#f2eee2';   // milk-white. Synthetics do not bleed red.
  const UNOWNED_TINT = '#7c8b96';
  const RANK = {
    human: 'DISPATCH CREW',
    synthetic: 'HYPERDYNE 120-A/2',
    unowned: 'NO OWNER PINNED',
  };
  const CREW_GLYPH = { human: 'g-crew', synthetic: 'g-synthetic', unowned: 'g-unregistered' };

  const deck = document.getElementById('deck');
  const idle = document.getElementById('idle');
  const counts = document.getElementById('counts');
  const clock = document.getElementById('clock');
  const link = document.getElementById('link');
  const history = document.getElementById('history');
  const overflow = document.getElementById('overflow');
  const overflowText = document.getElementById('overflowText');
  const boot = document.getElementById('boot');

  const GLYPH = {
    opus: 'g-opus', codex: 'g-codex', gate: 'g-gate', pr: 'g-pr', demo: 'g-demo',
    setup: 'g-setup', sync: 'g-sync', skipped: 'g-skipped', alarm: 'g-alarm',
    done: 'g-done', failed: 'g-failed', unknown: 'g-unknown',
  };
  const STATE_GLYPH = { alarm: 'g-alarm', ready: 'g-done', failed: 'g-failed' };

  let skew = 0;        // server epoch minus ours, so timers agree with the harness
  let runs = [];
  let lanes = [];
  const panels = new Map();
  const laneEls = new Map();

  // A crew member keeps the same tint whoever else is on the wall, so the room
  // learns "amber is Emre" — an index into the sorted lanes would reshuffle
  // every time someone's queue empties.
  function crewTint(lane) {
    if (lane.kind === 'synthetic') return SYNTHETIC_TINT;
    if (lane.kind === 'unowned') return UNOWNED_TINT;
    let h = 0;
    for (let i = 0; i < lane.owner.length; i++) h = (h * 31 + lane.owner.charCodeAt(i)) >>> 0;
    return CREW_TINTS[h % CREW_TINTS.length];
  }

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

  function glyph(cls) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', cls);
    svg.appendChild(document.createElementNS('http://www.w3.org/2000/svg', 'use'));
    return svg;
  }

  function setGlyph(svg, id) {
    const use = svg.firstChild;
    const ref = '#' + id;
    if (use.getAttribute('href') === ref) return;
    use.setAttribute('href', ref);
    use.setAttributeNS('http://www.w3.org/1999/xlink', 'xlink:href', ref);
  }

  function glyphFor(run) {
    return STATE_GLYPH[run.state] || GLYPH[run.actorKey] || GLYPH.unknown;
  }

  function runLink(label, rawUrl) {
    const link = el('a', 'chip__link', label);
    try {
      const url = new URL(rawUrl);
      if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('unsupported URL');
      link.href = url.href;
      link.title = rawUrl;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
    } catch {
      // A partial result.json should not turn an otherwise healthy history chip
      // into a dangerous or broken link. The marker still conveys availability.
      link.removeAttribute('href');
    }
    return link;
  }

  // --- panels ---------------------------------------------------------------

  function makePanel() {
    const root = el('article', 'panel');
    const wash = glyph('panel__wash');   // the actor's pictogram, ghosted, as the panel's backdrop
    const head = el('div', 'panel__head');
    const id = el('div', 'panel__id');
    const badge = el('div', 'panel__badge');
    const mark = glyph('panel__glyph');
    const actor = el('span');
    badge.append(mark, actor);
    head.append(id, badge);

    const title = el('div', 'panel__title');
    const stage = el('div', 'panel__stage');
    const stageText = el('span', 'panel__stageText');
    const timer = el('span', 'panel__timer');
    stage.append(stageText, timer);

    const meta = el('div', 'panel__meta');
    const note = el('div', 'panel__note');
    const feed = el('pre', 'panel__feed');
    root.append(wash, head, title, stage, meta, note, feed);
    return { root, wash, id, mark, actor, title, stageText, timer, meta, note, feed };
  }

  function metaChip(parent, label, value, cls) {
    const chunk = el('span', cls || '');
    chunk.append(label + ' ', el('b', '', value));
    parent.append(chunk);
  }

  function paintMeta(p, run) {
    p.meta.textContent = '';
    if (run.diff && run.diff.insertions !== null && run.diff.insertions !== undefined) {
      metaChip(p.meta, 'DIFF', '+' + run.diff.insertions + ' -' + (run.diff.deletions || 0));
    }
    if (run.gate) metaChip(p.meta, 'GATE', String(run.gate).toUpperCase(), run.gate === 'pass' ? 'ok' : 'bad');
    if (run.gateRounds && run.gateRounds.length > 1) metaChip(p.meta, 'ROUNDS', String(run.gateRounds.length));
    if (run.started) metaChip(p.meta, 'TOTAL', dur(now() - run.started));
    if (run.implementer) metaChip(p.meta, 'IMPL', run.implementer);
    if (run.reviewer) metaChip(p.meta, 'REV', run.reviewer);
    if (run.branch) metaChip(p.meta, 'BRANCH', run.branch);
  }

  function paintFeed(p, run) {
    p.feed.textContent = '';
    for (const line of run.feed) {
      const row = el('div', 'feed__line');
      row.dataset.src = line.src || 'opus';
      if (line.t) row.append(el('span', 'feed__t', line.t));
      row.append(el('span', 'feed__body', line.text));
      p.feed.append(row);
    }
    p.feed.hidden = run.feed.length === 0;
  }

  function paintNote(p, run) {
    const note = run.state === 'alarm'
      ? '⚠ ' + (run.blocked || 'needs your input — see QUESTIONS.md')
      : '';
    p.note.textContent = note;
    p.note.hidden = note === '';
  }

  function paintTimer(p, run) {
    p.timer.textContent = run.since ? '⧗ ' + dur(now() - run.since) : '';
  }

  function paintPanel(p, run) {
    p.root.dataset.state = run.state;
    p.root.dataset.actor = run.actorKey;
    p.id.textContent = run.id;
    p.actor.textContent = run.actor.toUpperCase();
    setGlyph(p.mark, glyphFor(run));
    setGlyph(p.wash, glyphFor(run));
    p.title.textContent = run.title || '(no brief title)';
    p.stageText.textContent = run.activity && run.state === 'active'
      ? run.stage + '  ·  ' + run.activity
      : run.stage || '(no stage yet)';
    paintTimer(p, run);
    paintMeta(p, run);
    paintNote(p, run);
    paintFeed(p, run);
  }

  // --- crew lanes -------------------------------------------------------------

  function makeLane() {
    const root = el('section', 'lane');
    const head = el('header', 'lane__head');
    const mark = glyph('lane__glyph');
    const idBlock = el('div', 'lane__idBlock');
    const name = el('div', 'lane__name');
    const rank = el('div', 'lane__rank');
    idBlock.append(name, rank);
    const alarm = el('div', 'lane__alarm');
    const counts = el('div', 'lane__counts');
    head.append(mark, idBlock, alarm, counts);
    const runsBox = el('div', 'lane__runs');
    const standby = el('div', 'lane__standby', '— STANDBY —');
    root.append(head, runsBox, standby);
    return { root, mark, name, rank, alarm, counts, runs: runsBox, standby };
  }

  function paintLane(L, lane) {
    L.root.dataset.kind = lane.kind;
    L.root.dataset.n = String(lane.runIds.length);
    L.root.style.setProperty('--crew', crewTint(lane));
    setGlyph(L.mark, CREW_GLYPH[lane.kind] || CREW_GLYPH.human);
    L.name.textContent = lane.label;
    L.rank.textContent = RANK[lane.kind] || RANK.human;
    L.counts.textContent = '';
    L.counts.append(el('b', '', String(lane.active)), document.createTextNode(' / ' + lane.total));
    L.alarm.textContent = lane.alarm ? '⚠ ' + lane.alarm : '';
    L.alarm.hidden = lane.alarm === 0;
    L.standby.hidden = lane.active !== 0;
  }

  function paintHistory(done) {
    history.textContent = '';
    if (done.length === 0) {
      history.append(el('span', 'rail__empty', 'NO COMPLETED RUNS ON RECORD'));
      return;
    }
    for (const run of done.slice(0, 8)) {
      const chip = el('span', 'chip');
      chip.dataset.state = run.state;
      const mark = glyph('');
      setGlyph(mark, glyphFor(run));
      chip.append(mark, el('b', '', run.id));
      if (run.owner) chip.append(el('span', 'chip__owner', run.owner.toUpperCase()));
      chip.append(el('span', 'chip__state', run.outcome || run.state));
      if (run.prUrl) chip.append(runLink('PR ↗', run.prUrl));
      if (run.demoUrl) chip.append(runLink('DEMO ↗', run.demoUrl));
      if (run.title) chip.append(el('span', 'chip__title', run.title));
      history.append(chip);
    }
  }

  function render() {
    const byId = new Map(runs.map((r) => [r.id, r]));
    const live = runs.filter((r) => r.state === 'active' || r.state === 'alarm');
    const done = runs.filter((r) => r.state === 'ready' || r.state === 'failed');
    // Nothing running anywhere: the Moebius idle screen takes the whole deck
    // rather than a row of empty lanes.
    const shownLanes = live.length ? lanes : [];

    deck.dataset.layout = shownLanes.length ? 'lanes' : 'idle';
    deck.dataset.lanes = String(shownLanes.length);
    // Lanes split the width evenly, so type scales with how many there are.
    deck.style.setProperty('--scale',
      String(Math.max(0.5, Math.min(1.45, 3.6 / (shownLanes.length || 1)))));
    idle.hidden = shownLanes.length !== 0;

    for (const [owner, L] of laneEls) {
      if (!shownLanes.some((lane) => lane.owner === owner)) { L.root.remove(); laneEls.delete(owner); }
    }
    const keep = new Set(shownLanes.flatMap((lane) => lane.runIds));
    for (const [id, p] of panels) {
      if (!keep.has(id)) { p.root.remove(); panels.delete(id); }
    }

    for (const lane of shownLanes) {
      let L = laneEls.get(lane.owner);
      if (!L) { L = makeLane(); laneEls.set(lane.owner, L); }
      paintLane(L, lane);
      for (const id of lane.runIds) {
        const run = byId.get(id);
        if (!run) continue;
        let p = panels.get(id);
        if (!p) { p = makePanel(); panels.set(id, p); }
        paintPanel(p, run);
        L.runs.append(p.root);  // append in lane order; a no-op when already last
      }
      deck.append(L.root);
    }

    paintHistory(done);
    const extra = shownLanes.flatMap((lane) =>
      lane.hiddenIds.map((id) => lane.label + ' ' + id));
    overflow.hidden = extra.length === 0;
    if (extra.length) {
      overflowText.textContent = '+' + extra.length + ' MORE RUNNING · ' + extra.join('  ·  ');
    }

    counts.textContent = '';
    const tally = [
      ['active', live.filter((r) => r.state === 'active').length],
      ['alarm', live.filter((r) => r.state === 'alarm').length],
      ['ready', done.filter((r) => r.state === 'ready').length],
      ['failed', done.filter((r) => r.state === 'failed').length],
    ];
    for (const [kind, n] of tally) {
      const box = el('span', 'hud__count');
      box.dataset.kind = kind;
      if (kind === 'alarm' && n > 0) box.dataset.hot = '1';
      box.append(el('b', '', String(n)), document.createTextNode(kind.toUpperCase()));
      counts.append(box);
    }
  }

  function tickClock() {
    const d = new Date((Date.now() / 1000 + skew) * 1000);
    clock.textContent = [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, '0')).join(':');
    for (const run of runs) {
      const p = panels.get(run.id);
      if (p) { paintTimer(p, run); }
    }
  }

  function apply(snapshot) {
    skew = (snapshot.at || 0) - Math.floor(Date.now() / 1000);
    runs = Array.isArray(snapshot.runs) ? snapshot.runs : [];
    lanes = Array.isArray(snapshot.lanes) ? snapshot.lanes : [];
    render();
    tickClock();
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
  setInterval(tickClock, 1000);
  setTimeout(() => { boot.hidden = true; }, 3100);
})();
