'use strict';
// The ops console — the functional half of the wall. It reads /api/runs once for
// the first paint and then lives on /api/stream, and it draws a board: what each
// agent is in the middle of, how long it has been there, and what is blocked.
//
// It shares no code with the city (wall.js, scene.js, world-canvas.js, room.js,
// Phaser). Its whole dependency is the two endpoints above, which is the point:
// wall/server.js is the run-data layer, and this is its second frontend.
//
// Read-only, like everything else that reads a run dir. The one control it
// offers is a command to paste: attach.sh steps into the session, from a
// terminal, where an operator can be asked to confirm.

(function () {
  const POLL_MS = 4000;
  const MAX_FEED = 48;

  // Actor -> hue, one entry per `key` in wall/stage-vocab.json. The colours are
  // the CSS custom properties; tests/wall.test.sh holds this list against the
  // table so a new actor cannot arrive here as an unstyled blank.
  const ACTORS = [
    'alarm', 'opus', 'codex', 'gate', 'pr', 'demo', 'setup', 'sync',
    'deferred', 'skipped', 'unreviewed', 'failed', 'done',
  ];

  // What the operator is spending. The stage text says "Opus (Claude sub)" on
  // every run whatever the provider, so this comes off the run's pin file.
  const PROVIDERS = { zai: 'GLM', anthropic: 'OPUS' };

  function providerLabel(provider) {
    const key = String(provider || '');
    return Object.prototype.hasOwnProperty.call(PROVIDERS, key) ? PROVIDERS[key] : null;
  }

  const $ = (id) => document.getElementById(id);

  function h(tag, props, children) {
    const node = document.createElement(tag);
    for (const key of Object.keys(props || {})) {
      if (key === 'text') node.textContent = props[key];
      else if (key === 'class') node.className = props[key];
      else node.setAttribute(key, props[key]);
    }
    for (const child of children || []) if (child) node.appendChild(child);
    return node;
  }

  function pad(n) { return n < 10 ? '0' + n : String(n); }

  // Short enough for a column, exact enough to act on.
  function since(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return '—';
    if (seconds < 90) return Math.floor(seconds) + 's';
    const m = Math.floor(seconds / 60);
    if (m < 60) return m + 'm';
    return Math.floor(m / 60) + 'h' + pad(m % 60);
  }

  // --runs identifies data, not an installation. The documented local harness
  // command remains valid even when the wall reads an arbitrary mounted path.
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
  }

  function attachCommand(id) {
    return '~/.claude/harness/attach.sh ' + shellQuote(id);
  }

  // Everything a row draws except the clocks, which tick on their own. A run
  // whose signature moved is a run that did something, and gets the flash.
  function signature(run) {
    return JSON.stringify([
      run.state, run.stage, run.actor, run.actorKey, run.provider, run.activity,
      run.projectLabel, run.title, run.diff, run.turns, run.cost, run.gateRounds,
      run.gate, run.outcome, run.prUrl, run.demoUrl, run.branch, run.blocked,
      run.reason, run.remote, run.host, run.telemetry, (run.feed || []).length,
      (run.feed || []).map((f) => f.text).join('\\u0000'),
    ]);
  }

  function actorKey(run) {
    return ACTORS.indexOf(run.actorKey) === -1 ? 'unknown' : run.actorKey;
  }

  function clock(cls, epoch) {
    const node = h('span', { class: 'elapsed ' + cls, text: '—' });
    if (Number.isFinite(epoch) && epoch > 0) node.setAttribute('data-epoch', String(epoch));
    return node;
  }

  function diffCell(diff) {
    if (!diff || (diff.insertions == null && diff.deletions == null)) {
      return h('span', { class: 'diff nil', text: '—' });
    }
    return h('span', { class: 'diff' }, [
      h('span', { class: 'plus', text: '+' + (diff.insertions || 0) }),
      document.createTextNode(' '),
      h('span', { class: 'minus', text: '−' + (diff.deletions || 0) }),
    ]);
  }

  function gateCell(rounds) {
    if (!Array.isArray(rounds) || !rounds.length) return h('span', { class: 'pips' });
    return h('span', { class: 'pips' }, rounds.map((r) => h('span', {
      class: 'pip',
      'data-verdict': String(r && r.verdict || ''),
      title: 'round ' + String(r && r.round || '?') + ': ' + String(r && r.verdict || '?'),
    })));
  }

  // What the run spent. Cost owns every figure and every string; this file
  // only places the span, so the board cannot disagree with the header.
  //
  // A live run has no result.json yet, so Cost has nothing to price. When the
  // run is reporting OpenTelemetry the CLI's own running cost stands in until
  // it does — marked `live`, because it is a figure still moving.
  function costCell(run) {
    const text = Cost.formatCostCell(run.cost);
    if (text !== '—') {
      return h('span', { class: 'cost', text, title: Cost.formatCostTooltip(run.cost) });
    }
    const live = Number(run.telemetry && run.telemetry.cost_usd);
    if (Number.isFinite(live) && live > 0) {
      return h('span', {
        class: 'cost live',
        text: '$' + live.toFixed(2),
        title: 'live, from the worker\'s own telemetry',
      });
    }
    return h('span', { class: 'cost nil', text, title: Cost.formatCostTooltip(run.cost) });
  }

  // Turns, or — while the run is live and reporting — how many tools its worker
  // has run, which is the same shape of number and the only one there is yet.
  function turnsCell(run) {
    if (run.turns != null) {
      return h('span', { class: 'turns', text: String(run.turns), title: 'turns' });
    }
    const tools = Number(run.telemetry && run.telemetry.tools);
    if (Number.isFinite(tools) && tools > 0) {
      return h('span', { class: 'turns live', text: String(tools), title: 'tool calls so far' });
    }
    return h('span', { class: 'turns nil', text: '—', title: 'turns' });
  }

  // The implementer's stage string hardcodes "Opus" whatever subscription is
  // pinned, so this row takes its actor word from the pin and drops the stage's
  // redundant " — …" suffix. Gated on the actor VALUE, not actorKey: the Claude
  // reviewer rows share the 'opus' key, and the pin says nothing about who
  // reviewed — relabelling them would misattribute the review.
  function implementerLabel(run) {
    if (run.actor !== 'Opus') return null;
    return {
      actor: providerLabel(run.provider) || run.actor,
      stage: String(run.stage || '').split(' — ')[0],
    };
  }

  function line(run) {
    const provider = String(run.provider || '');
    const implementer = implementerLabel(run);
    // A finished run's activity is usually the very `done:` line the stage
    // column already carries; echoing it again adds nothing. Distinct last
    // words — a sync failure, say — stay.
    const finished = (run.state === 'ready' || run.state === 'failed') && actorKey(run) === 'done';
    const activity = finished && run.activity === run.stage ? '' : String(run.activity || '');
    return [
      h('span', { class: 'id mono', text: run.id, title: run.id }),
      h('span', { class: 'repo mono', text: run.projectLabel || '—', title: run.projectLabel || '' }),
      h('span', {
        class: 'badge',
        'data-provider': provider,
        text: providerLabel(provider) || '—',
        title: provider ? 'implementer: ' + provider : 'implementer provider not pinned',
      }),
      h('span', { class: 'stage' }, [
        // Which machine this run is on. Only ever drawn for a row that is not
        // on this disk, so the board says where to go rather than implying the
        // run is here.
        run.remote ? h('span', {
          class: 'host mono',
          text: String(run.host || '?'),
          title: 'reported from ' + String(run.host || 'an unnamed machine'),
        }) : null,
        // The hue is looked up rather than written out per actor: the key is
        // always one of ACTORS, so `--a-<key>` is always a property console.css
        // defines, and adding an actor is one line in each file.
        h('span', {
          class: 'actor',
          'data-actor': actorKey(run),
          style: 'color: var(--a-' + actorKey(run) + ')',
          text: implementer ? implementer.actor : (run.actor || '?'),
        }),
        h('span', {
          class: 'stage-label',
          text: implementer ? implementer.stage : (run.stage || ''),
          title: run.stage || '',
        }),
      ]),
      h('span', {
        class: activity ? 'activity mono' : 'activity mono none',
        text: activity || 'idle',
        title: activity,
      }),
      clock('in-stage', Number(run.since)),
      clock('total', Number(run.started)),
      diffCell(run.diff),
      turnsCell(run),
      costCell(run),
      gateCell(run.gateRounds),
    ];
  }

  function feedBlock(run) {
    const lines = Array.isArray(run.feed) ? run.feed.slice(-MAX_FEED) : [];
    if (!lines.length) return h('div', { class: 'feed' }, [h('div', { class: 'none', text: 'no feed yet' })]);
    return h('div', { class: 'feed' }, lines.map((f) => h('div', { 'data-src': String(f && f.src || '') }, [
      h('span', { class: 't mono', text: String(f && f.t || '') }),
      h('span', { class: 'text mono', text: String(f && f.text || '') }),
    ])));
  }

  function safeLink(label, value) {
    let url;
    try { url = new URL(String(value)); } catch { return null; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    return h('a', { href: url.href, rel: 'noopener noreferrer', text: label });
  }

  function detail(run) {
    // attach.sh opens a session on THIS machine, so a run reported from another
    // one gets the machine's name where the paste would be — the next thing an
    // operator needs is to go there, not to run a command that cannot work.
    const command = run.remote ? String(run.host || '') : attachCommand(run.id);
    const copy = h('button', { type: 'button', text: 'copy' });
    copy.addEventListener('click', (event) => {
      event.stopPropagation();
      const done = () => {
        copy.textContent = 'copied';
        copy.setAttribute('data-copied', '1');
      };
      // A page served over plain http on a tailnet address is not a secure
      // context, so the clipboard API is not there at all — select the text
      // instead and let the operator take it with the keyboard.
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(command).then(done, () => select(code));
      } else {
        select(code);
      }
    });
    const code = h('code', { class: 'mono', text: command });

    const meta = [];
    if (run.branch) meta.push(h('span', { class: 'mono', text: run.branch }));
    if (run.owner) meta.push(h('span', { text: 'dispatched by ' + run.owner }));
    if (run.gate) meta.push(h('span', { text: 'gate ' + run.gate }));
    if (run.outcome) meta.push(h('span', { text: run.outcome }));
    const pr = safeLink('PR', run.prUrl);
    const demo = safeLink('demo', run.demoUrl);
    if (pr) meta.push(pr);
    if (demo) meta.push(demo);

    const why = run.blocked || run.reason;
    return h('div', { class: 'detail' }, [
      run.title ? h('p', { class: 'title', text: run.title }) : null,
      why ? h('p', { class: 'why', text: why }) : null,
      h('div', { class: 'attach' }, [code, copy]),
      meta.length ? h('p', { class: 'meta' }, meta) : null,
      feedBlock(run),
    ]);
  }

  function select(node) {
    const range = document.createRange();
    range.selectNodeContents(node);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  // --- the board ---------------------------------------------------------------

  const nodes = new Map();   // run id -> {article, button, sig}
  const open = new Set();    // run ids the operator has expanded
  let runsDir = '';
  // The server's own clock, and the moment it arrived here, so the columns tick
  // between snapshots without trusting this machine's idea of the time.
  let serverAt = 0;
  let serverGot = 0;

  function nodeFor(id) {
    let entry = nodes.get(id);
    if (entry) return entry;
    const button = h('button', { class: 'line', type: 'button' });
    const article = h('article', { class: 'run' }, [button]);
    // Removing a node cancels its animations and re-inserting one starts them
    // again, so a flash left on the class would replay on every reorder. The
    // class lives exactly as long as the flash does.
    article.addEventListener('animationend', () => article.classList.remove('touched'));
    button.addEventListener('click', () => {
      if (open.has(id)) open.delete(id); else open.add(id);
      const run = entry.run;
      if (run) paintDetail(entry, run);
    });
    entry = { article, button, sig: '', run: null };
    nodes.set(id, entry);
    return entry;
  }

  function paintDetail(entry, run) {
    const existing = entry.article.querySelector('.detail');
    if (existing) existing.remove();
    entry.button.setAttribute('aria-expanded', open.has(run.id) ? 'true' : 'false');
    if (open.has(run.id)) entry.article.appendChild(detail(run));
  }

  function paint(run, first) {
    const entry = nodeFor(run.id);
    const sig = signature(run);
    const moved = entry.sig !== '' && entry.sig !== sig;
    entry.run = run;
    if (entry.sig !== sig) {
      entry.sig = sig;
      entry.button.replaceChildren(...line(run));
      paintDetail(entry, run);
    }
    entry.article.setAttribute('data-state', String(run.state || ''));
    entry.article.setAttribute('data-waiting', run.actorKey === 'deferred' ? '1' : '0');
    if (run.remote) entry.article.classList.add('remote');
    else entry.article.classList.remove('remote');
    if (moved && !first) {
      entry.article.classList.remove('touched');
      void entry.article.offsetWidth;  // restart the animation on a row that flashed a moment ago
      entry.article.classList.add('touched');
    }
    return entry.article;
  }

  // Reordering detaches nodes, which loses the scroll position of an expanded
  // feed and cancels a flash in flight, so the board is only rebuilt when the
  // order actually changed — which on a busy wall is rarely.
  function fill(container, runs, first) {
    const want = runs.map((run) => paint(run, first));
    const have = container.children;
    if (have.length === want.length && want.every((node, i) => have[i] === node)) return;
    container.replaceChildren(...want);
  }

  // The header's tiles, straight from Cost: DOM insertion only, so a wrong
  // number here is a wrong number in cost.js, where the gate can see it.
  function paintSummary(summary) {
    $('summary-tiles').replaceChildren(...Cost.summaryTiles(summary).map((tile) => h('div', { class: 'tile' }, [
      h('span', { class: 'label', text: tile.label }),
      h('span', { class: 'value', text: tile.value }),
      h('span', { class: 'sub', text: tile.sub }),
    ])));
  }

  $('summary-window').textContent = 'Last ' + Cost.SUMMARY_WINDOW_DAYS + ' days';

  let firstPaint = true;

  function render(frame) {
    const runs = Array.isArray(frame.runs) ? frame.runs.filter((r) => r && typeof r.id === 'string') : [];
    runsDir = typeof frame.runsDir === 'string' ? frame.runsDir : runsDir;
    serverAt = Number(frame.at) || Math.floor(Date.now() / 1000);
    serverGot = Date.now();

    const alarms = runs.filter((r) => r.state === 'alarm');
    const active = runs.filter((r) => r.state === 'active');
    const recent = runs.filter((r) => r.state === 'ready' || r.state === 'failed');

    paintSummary(frame.summary);

    fill($('alarm-rows'), alarms, firstPaint);
    fill($('active-rows'), active, firstPaint);
    fill($('recent-rows'), recent, firstPaint);

    $('alarms').hidden = alarms.length === 0;
    $('n-alarm').hidden = alarms.length === 0;
    $('n-alarm').querySelector('b').textContent = String(alarms.length);
    $('n-active').textContent = String(active.length);
    $('n-done').textContent = String(recent.length);
    $('active-empty').hidden = active.length > 0;
    $('runs-dir').textContent = runsDir || '—';

    // A run that left the snapshot leaves its node behind; drop it so the map
    // does not grow for as long as the console is open.
    const live = new Set(runs.map((r) => r.id));
    for (const id of [...nodes.keys()]) if (!live.has(id)) { nodes.delete(id); open.delete(id); }

    firstPaint = false;
    ticks();
  }

  function ticks() {
    if (!serverAt) return;
    const now = serverAt + (Date.now() - serverGot) / 1000;
    for (const node of document.querySelectorAll('.elapsed[data-epoch]')) {
      node.textContent = since(now - Number(node.getAttribute('data-epoch')));
    }
  }
  setInterval(ticks, 1000);

  // --- the wire ------------------------------------------------------------------

  function link(state, text) {
    $('link').setAttribute('data-state', state);
    $('link-text').textContent = text;
  }

  // A snapshot caught mid-write, a truncated SSE frame, a run dir the server
  // could only half read: none of them may take the board down. Anything that
  // does not parse into a frame with a runs array is simply the previous frame
  // standing until the next one.
  let frameGeneration = 0;

  function accept(text, expectedGeneration) {
    // A fetch started before a stream frame cannot be allowed to roll that
    // newer frame back when its older response arrives later.
    if (expectedGeneration !== undefined && expectedGeneration !== frameGeneration) return false;
    let frame;
    try { frame = JSON.parse(text); } catch { return false; }
    if (!frame || typeof frame !== 'object' || !Array.isArray(frame.runs)) return false;
    try { render(frame); } catch { return false; }
    frameGeneration += 1;
    return true;
  }

  let polling = null;

  function poll() {
    const expectedGeneration = frameGeneration;
    fetch('/api/runs?view=console', { cache: 'no-store' })
      .then((res) => res.text())
      .then((text) => {
        if (accept(text, expectedGeneration) && polling) link('polling', 'polling');
      })
      .catch(() => link('down', 'no server'));
  }

  function startPolling() {
    if (polling) return;
    link('polling', 'polling');
    polling = setInterval(poll, POLL_MS);
    poll();
  }

  function stopPolling() {
    if (!polling) return;
    clearInterval(polling);
    polling = null;
  }

  poll();

  if (typeof EventSource === 'function') {
    const es = new EventSource('/api/stream?view=console');
    es.addEventListener('open', () => { stopPolling(); link('live', 'live'); });
    es.addEventListener('snapshot', (event) => {
      stopPolling();
      link('live', 'live');
      accept(event.data);
    });
    // EventSource reconnects on its own (the server sends `retry: 2000`); the
    // poll covers the gap, and stops itself the moment a frame arrives again.
    es.addEventListener('error', startPolling);
  } else {
    startPolling();
  }
}());
