'use strict';
// The Wall's renderer. Subscribes to /api/stream (SSE), falls back to polling
// /api/runs, and paints run panels. Panels are created once and mutated in
// place: a full re-render would restart the CRT animations every second.
// No network call ever leaves this origin.

(function () {
  const MAX_PANELS = 8;   // beyond this the extras go to the overflow ticker
  const POLL_MS = 2000;   // only used when SSE is unavailable

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
  const panels = new Map();

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
    if (run.started) metaChip(p.meta, 'TOTAL', dur((run.state === 'active' || run.state === 'alarm' ? now() : run.since) - run.started));
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
    let note = '';
    if (run.state === 'alarm') note = '⚠ ' + (run.blocked || 'needs your input — see QUESTIONS.md');
    else if (run.state === 'failed') note = '✖ ' + (run.reason || run.outcome || 'failed');
    else if (run.state === 'ready') note = '✔ ' + ([run.prUrl, run.demoUrl].filter(Boolean).join('  ·  ') || 'ready');
    p.note.textContent = note;
    p.note.hidden = note === '';
  }

  function paintTimer(p, run) {
    if (run.state === 'active' || run.state === 'alarm') {
      p.timer.textContent = run.since ? '⧗ ' + dur(now() - run.since) : '';
    } else {
      p.timer.textContent = run.started && run.since ? 'Σ ' + dur(run.since - run.started) : '';
    }
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

  // --- the wall -------------------------------------------------------------

  function layoutFor(n) {
    if (n === 0) return 'idle';
    if (n === 1) return 'hero';
    if (n === 2) return 'duo';
    if (n <= 4) return 'grid';
    return 'dense';
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
      chip.append(mark, el('b', '', run.id), el('span', '', run.outcome || run.state));
      if (run.prUrl) chip.append(el('span', '', '· PR'));
      if (run.demoUrl) chip.append(el('span', '', '· DEMO'));
      history.append(chip);
    }
  }

  function render() {
    const live = runs.filter((r) => r.state === 'active' || r.state === 'alarm');
    const done = runs.filter((r) => r.state === 'ready' || r.state === 'failed');
    const shown = live.slice(0, MAX_PANELS);
    const extra = live.slice(MAX_PANELS);

    deck.dataset.layout = layoutFor(shown.length);
    deck.dataset.n = String(shown.length);   // lets an odd count fill its row
    idle.hidden = shown.length !== 0;

    const keep = new Set(shown.map((r) => r.id));
    for (const [id, p] of panels) {
      if (!keep.has(id)) { p.root.remove(); panels.delete(id); }
    }
    for (const run of shown) {
      let p = panels.get(run.id);
      if (!p) { p = makePanel(); panels.set(run.id, p); }
      paintPanel(p, run);
      deck.append(p.root); // append in sorted order; a no-op when already last
    }

    paintHistory(done);
    overflow.hidden = extra.length === 0;
    if (extra.length) {
      overflowText.textContent = '+' + extra.length + ' MORE RUNNING · ' +
        extra.map((r) => r.id + ' ' + r.actor).join('  ·  ');
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
