'use strict';
// Ghost Shift — read-only big-screen dashboard over $HARNESS_DIR/runs, rendered as
// a city: one tower per project, each run a lit car climbing it.
//
// The skyline is LIVE: it carries what is running now, plus a finished run's one
// short completion moment. The city grows and shrinks with the work, which is
// the whole point of putting it on a wall.
//
// The DISTRICT under it accretes instead: every run that reaches `done: ready`
// this week is a permanent building, the week resets to an empty plain on Monday
// 00:00 local, and last week's city stands behind this one as a flat ghost. See
// "the week's city" below.
//
// node:http + node:fs only: no dependencies, no build step, and no runtime
// request that leaves this origin (the TV may only see the tailnet). Launched
// by ../wall.sh, which owns the flags and computes the defaults below.
//
//   GET /              the page (index.html, wall.css, wall.js)
//   GET /api/runs      one snapshot of every run, as JSON
//   GET /api/stream    the same snapshot pushed over SSE whenever it changes
//
// Everything here is best-effort by design: the run dirs are written live by
// run-task.sh, so any file may be missing, empty, or caught mid-write. Same
// philosophy as collect_metrics() — render what is on disk, never throw.

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

// `|| default` would swallow a deliberate 0 — and --port 0 (let the OS pick a
// free port) is how a second wall, and the test suite, stay out of each other's
// way.
function num(value, fallback) {
  const n = Number(value);
  return value === undefined || value === '' || Number.isNaN(n) ? fallback : n;
}

const HERE = __dirname;
const PORT = num(process.env.WALL_PORT, 4711);
const HOST = process.env.WALL_HOST || '0.0.0.0';
const RUNS = process.env.WALL_RUNS ||
  path.join(process.env.HOME || '.', '.claude/harness/runs');
const POLL_MS = Math.max(100, num(process.env.WALL_POLL_MS, 1000));

const MAX_FINISHED = 24;  // compact cap on the JSON feed; live runs are never discarded
const FEED_LINES = 48;    // tail of feed.log shipped per run
const TAIL_BYTES = 16384; // how far back we read for those lines
const SILHOUETTES = 5;    // tower body outlines the page can draw
const CROWNS = 4;         // roof furniture (mast, water tank, sign rig) per body

// How long a finished run holds its place in the skyline: one completion moment
// — the rooftop flare, or the burnout — and then it is gone, and a tower with
// nothing left standing in it goes with it. Nobody watching a wall wants
// yesterday's green ticks; they want to see the work move. The page mirrors this
// number as --completion (shipped in every snapshot) to time the animation.
const COMPLETION_S = 20;

// How long a landed building carries its dispatcher's crew tint before cooling
// to the district's own neutral. Long enough that this morning's ships are still
// attributable across a standup, short enough that by tomorrow the week is just
// the week's. The page mirrors this number as --sign-life to time the fade.
const SIGN_S = 6 * 3600;

// A run whose worktree we cannot read still has to stand somewhere, and guessing
// a repo for it would be a lie. It gets an honest tower of its own instead.
const UNCHARTED = 'UNCHARTED';

// The expected roster (--crew / WALL_CREW), still accepted so an existing
// launch script keeps working, and echoed to the page. It no longer shapes the
// wall: crew tints are hashed from the owner name and are stable on their own,
// and a roster that conjured up empty crew furniture is exactly what the city
// replaced. A project with nothing running is simply not in the skyline.
const CREW = (process.env.WALL_CREW || '').split(',')
  .map((s) => s.trim().toLowerCase()).filter(Boolean);
// Automated dispatcher accounts: the ship's synthetics. Not people, and the
// wall says so rather than quietly listing them as crew.
const SYNTHETIC = new Set(['bot']);

// --- disk reads (never throw) -------------------------------------------------

function readChunk(file, bytes, fromEnd) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, bytes);
    const start = fromEnd ? size - len : 0;
    const buf = Buffer.alloc(len);
    const n = fs.readSync(fd, buf, 0, len, start);
    return { text: buf.subarray(0, n).toString('utf8'), clipped: start > 0 };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* already gone */ } }
  }
}

function head(file, bytes = 4096) {
  const c = readChunk(file, bytes, false);
  return c ? c.text : '';
}

function firstLine(file) {
  return head(file, 4096).split('\n')[0].trim();
}

// Last `n` non-empty lines. A clipped read starts mid-line, so the first one is
// dropped; a file being appended to right now loses at most its final partial
// line, which the next poll picks up.
function tailLines(file, n) {
  const c = readChunk(file, TAIL_BYTES, true);
  if (!c) return [];
  const lines = c.text.split('\n');
  if (c.clipped) lines.shift();
  return lines.filter((l) => l.trim() !== '').slice(-n);
}

function readJSON(file) {
  try {
    return JSON.parse(readChunk(file, 1 << 20, false).text);
  } catch {
    return null; // absent, or caught mid-rewrite — both are just "not yet"
  }
}

// --- the stage-text -> actor contract ----------------------------------------
// CONTRACT: mirrors harness_actor() in statusline.sh, which is the single source
// of truth for the stage strings run-task.sh's stage() writes. Prefix matching,
// same order — tests/statusline.test.sh pins every literal on the shell side, so
// a new stage lands there first and gets its line here in the same commit.
// `key` is the neon signature the page colours the panel with.
const ACTORS = [
  [/^waiting/, 'needs input', 'alarm'],
  [/^(implementing|resuming)/, 'Opus', 'opus'],
  [/^review skipped/, 'skipped', 'skipped'],
  [/^(review|fix)/, 'Codex', 'codex'],
  [/^test gate/, 'gate', 'gate'],
  [/^push/, 'PR', 'pr'],
  [/^demo/, 'demo', 'demo'],
  [/^(setup|installing)/, 'setup', 'setup'],
  [/^deferred:/, 'deferred', 'deferred'],
  [/^(base sync|already up)/, 'sync', 'sync'],
  [/^sync failed/, 'failed', 'failed'],
  [/^done:/, 'done', 'done'],
];

function actorOf(stage) {
  for (const [re, actor, key] of ACTORS) {
    if (re.test(stage)) return { actor, actorKey: key };
  }
  return { actor: '?', actorKey: 'unknown' };
}

// active | alarm | ready | failed. `done: <status>` carries the outcome, and
// every failing STATUS in run-task.sh ends in _failed or is "rejected"; sync-pr's
// "done: PR branch synced …" is a success, so match the failure words, not a
// whitelist of the good ones.
const DONE_NEEDS_INPUT = /^done:\s*needs_input\b/i;

function stateOf(stage) {
  if (/^waiting/.test(stage) || DONE_NEEDS_INPUT.test(stage)) return 'alarm';
  if (/^done:/.test(stage)) return /fail|reject/i.test(stage.slice(5)) ? 'failed' : 'ready';
  return 'active';
}

// --- the stage -> floor ladder -------------------------------------------------
// The city's other axis: a run is a lit car climbing its tower, and how high it
// has got IS its pipeline stage. Keyed off actorKey rather than the raw stage
// text so there is one stage table in this file, not two.
const FLOORS = ['SETUP', 'IMPLEMENT', 'GATE', 'REVIEW', 'DEMO', 'PUSH'];
const FLOOR_OF = {
  setup: 0, sync: 0, failed: 0, unknown: 0,
  opus: 1, alarm: 1, deferred: 1,
  gate: 2,
  codex: 3, skipped: 3,
  demo: 4,
  pr: 5,
};

// A finished run parks at the floor it stopped on, not at the roof: a
// `done: gate_failed` burnout two floors down is the honest picture, and only a
// run that actually shipped lights the rooftop. Anything unrecognised (a future
// status, sync-pr.sh's prose "done: PR branch synced …") made it to the top.
const DONE_FLOOR = [
  [/setup_failed/, 0],
  [/implementer_failed|capacity_failed/, 1],
  [/gate_failed/, 2],
  [/rejected/, 3],
];

function floorOf(stage, actorKey) {
  if (/^done:/.test(stage)) {
    const outcome = stage.slice(5).trim();
    for (const [re, floor] of DONE_FLOOR) if (re.test(outcome)) return floor;
    return FLOORS.length - 1;
  }
  return FLOOR_OF[actorKey] ?? 0;
}

// A terminal `done: needs_input` is written after the actual stage that
// blocked. Recover that last stage so the alarm stays on the floor where work
// stopped instead of jumping to the rooftop and looking like a successful PR.
function previousFloor(dir) {
  const lines = tailLines(path.join(dir, 'stages.log'), 8);
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = /^\d+\s+(\S.*)$/.exec(lines[i]);
    if (!m || m[1] === '__invocation__' || /^done:/.test(m[1])) continue;
    const prior = actorOf(m[1]);
    return floorOf(m[1], prior.actorKey);
  }
  return FLOOR_OF.alarm;
}

// --- which project a run belongs to --------------------------------------------
// run-task.sh builds the worktree as "<repo-dir>-<ticket-lowercased>" next to
// the repo (run-task.sh:59) and writes that absolute path into the run dir's
// `worktree` file before the first stage, then again into result.json. Reversing
// that construction is the only project identity a run dir carries — there is no
// repo field to read. The file wins: it exists from the very first stage.
function projectOf(id, dir, result) {
  const raw = firstLine(path.join(dir, 'worktree')) || String(result.worktree || '').trim();
  if (!raw) return '';
  const leaf = path.basename(raw.replace(/[/\\]+$/, ''));
  const suffix = '-' + String(id).toLowerCase();
  const repo = leaf.toLowerCase().endsWith(suffix) ? leaf.slice(0, -suffix.length) : leaf;
  return repo.trim().toLowerCase();
}

// --- one run ------------------------------------------------------------------

// `status` is rewritten in place by stage(), so a poll can catch it empty.
// stages.log is append-only with the same "<epoch> <label>" shape: falling back
// to its last real line keeps a panel from blinking to "unknown" for one frame.
function currentStage(dir) {
  const parse = (line) => {
    const m = /^(\d+)\s+(\S.*)$/.exec(line || '');
    return m ? { since: Number(m[1]), stage: m[2].trim() } : null;
  };
  const now = parse(firstLine(path.join(dir, 'status')));
  if (now) return now;
  const log = tailLines(path.join(dir, 'stages.log'), 8)
    .map(parse)
    .filter((s) => s && s.stage !== '__invocation__');
  return log.length ? log[log.length - 1] : { since: null, stage: '' };
}

function titleOf(dir) {
  const m = /^#\s+(.+)$/m.exec(head(path.join(dir, 'brief.md'), 8192));
  return m ? m[1].replace(/\s*#*\s*$/, '').trim() : '';
}

// The opening paragraph of a QUESTIONS.md / REJECTED.md — the headline of why a
// run is blocked, big enough to read from the sofa. Headings are skipped (both
// files open with one, and it says nothing), and the paragraph is rejoined:
// these files are hard-wrapped, so one line is half a sentence.
function firstProse(file) {
  const text = head(file, 8192);
  if (!text) return '';
  const para = [];
  for (const raw of text.split('\n')) {
    if (/^\s*#/.test(raw)) continue;
    const line = raw.replace(/^[>*\-\s]+/, '').trim();
    if (line) para.push(line);
    else if (para.length) break;
  }
  return para.join(' ').slice(0, 200);
}

function feedOf(dir) {
  return tailLines(path.join(dir, 'feed.log'), FEED_LINES).map((line) => {
    // "HH:MM:SS ⏺ Edit src/app.ts" (implementer) or "HH:MM:SS ◆ codex …".
    const m = /^(\d\d:\d\d:\d\d)\s+(.*)$/.exec(line);
    const t = m ? m[1] : '';
    let text = (m ? m[2] : line).slice(0, 160);
    let src = 'opus';
    const tagged = /^◆\s+(\S+)\s*(.*)$/.exec(text);
    if (tagged) { src = tagged[1].toLowerCase(); text = tagged[2]; }
    return { t, text, src };
  });
}

// Who dispatched this run. run-task.sh pins `owner` at first dispatch from
// HARNESS_OWNER and copies it into result.json; the file wins because it exists
// from the first stage, while result.json only appears when the run ends or
// pauses. Lowercased into a lane key — ANGEL and angel are one crew member.
function ownerOf(dir, result) {
  const pinned = readChunk(path.join(dir, 'owner'), 4096, false);
  const raw = pinned ? pinned.text.split('\n')[0].trim() : result.owner || '';
  return String(raw).trim().toLowerCase().slice(0, 24);
}

function ownerKindOf(owner) {
  if (owner === '') return 'unowned';
  return SYNTHETIC.has(owner) ? 'synthetic' : 'human';
}

function readRun(id, current) {
  const dir = path.join(RUNS, id);
  const { since, stage } = current || currentStage(dir);
  if (since === null && stage === '') return null; // not a run dir (yet)
  const result = readJSON(path.join(dir, 'result.json')) || {};
  const metrics = result.metrics || {};
  const started = Number(firstLine(path.join(dir, 'started'))) || since;
  const state = stateOf(stage);
  const gateRounds = tailLines(path.join(dir, 'gate-rounds.log'), 8)
    .map((l) => l.split(/\s+/))
    .filter((p) => p.length >= 2)
    .map(([round, verdict]) => ({ round, verdict }));

  const owner = ownerOf(dir, result);
  const project = projectOf(id, dir, result);
  let { actor, actorKey } = actorOf(stage);
  const terminalNeedsInput = DONE_NEEDS_INPUT.test(stage);
  const floor = terminalNeedsInput ? previousFloor(dir) : floorOf(stage, actorKey);
  if (terminalNeedsInput) {
    actor = 'needs input';
    actorKey = 'alarm';
  }

  return {
    id,
    title: titleOf(dir),
    owner,
    ownerKind: ownerKindOf(owner),
    project,
    projectLabel: project ? project.toUpperCase() : UNCHARTED,
    stage,
    state,
    actor,
    actorKey,
    floor,
    floorName: FLOORS[floor] || FLOORS[0],
    activity: firstLine(path.join(dir, 'activity')).slice(0, 160),
    started: started || null,
    since: since || null,
    gate: result.gate || (gateRounds.length ? gateRounds[gateRounds.length - 1].verdict : ''),
    gateRounds,
    outcome: result.status || '',
    prUrl: result.pr_url || '',
    demoUrl: result.demo_url || '',
    branch: result.branch || '',
    implementer: result.implementer_model || '',
    reviewer: result.reviewer_model || '',
    diff: metrics.diff || null,
    blocked: state === 'alarm' ? firstProse(path.join(dir, 'QUESTIONS.md')) : '',
    reason: state === 'failed' ? firstProse(path.join(dir, 'REJECTED.md')) : '',
    feed: feedOf(dir),
  };
}

// Newest-first by the mtime of `status` (what stage() touches). The finished
// cap is applied in snapshot(), after each cheap stage read: capping IDs here
// could let a burst of completed runs hide an older run that is still active.
function listRunIds() {
  let entries;
  try {
    entries = fs.readdirSync(RUNS, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.isDirectory() || e.isSymbolicLink())
    .map((e) => {
      let mtime = 0;
      try { mtime = fs.statSync(path.join(RUNS, e.name, 'status')).mtimeMs; } catch { /* no status */ }
      return { name: e.name, mtime };
    })
    .filter((e) => e.mtime > 0)
    .sort((a, b) => b.mtime - a.mtime)
    .map((e) => e.name);
}

const ORDER = { alarm: 0, active: 1, failed: 2, ready: 2 };

// One read of every run's status line per poll, shared by the live skyline and
// by the week's city below — they ask different questions of the same fact, and
// reading the file twice would double the wall's disk traffic for nothing.
function scan() {
  const seen = [];
  for (const id of listRunIds()) {
    try {
      const dir = path.join(RUNS, id);
      const current = currentStage(dir);
      if (current.since === null && current.stage === '') continue;
      seen.push({ id, dir, current });
    } catch { /* one broken run dir never blanks the wall */ }
  }
  return seen;
}

function snapshot(scanned) {
  const runs = [];
  let finished = 0;
  for (const { id, current } of scanned) {
    try {
      const state = stateOf(current.stage);
      const isFinished = state === 'ready' || state === 'failed';
      if (isFinished && finished >= MAX_FINISHED) continue;
      const run = readRun(id, current);
      if (run) {
        runs.push(run);
        if (isFinished) finished += 1;
      }
    } catch { /* one broken run dir never blanks the wall */ }
  }
  // Alarms shout first, then live runs oldest-first (the one that has been
  // going longest is the one you want to look at), then finished newest-first.
  runs.sort((a, b) => {
    const g = ORDER[a.state] - ORDER[b.state];
    if (g !== 0) return g;
    if (ORDER[a.state] <= 1) return (a.started || 0) - (b.started || 0);
    return (b.since || 0) - (a.since || 0);
  });
  return runs;
}

// --- the skyline ----------------------------------------------------------------
// The wall is organised around the WORK: one tower per project, with that
// project's runs climbing it. A project with nothing live is simply not in the
// skyline — there is no empty tower, no standby, and no per-person aggregate
// anywhere in here. Who dispatched a run survives only as the run's `owner`,
// which the page paints as a tinted light on its car.
//
// Grouping happens here rather than in the page so it is covered by the same
// curl-and-jq tests as everything else.

// A small polynomial hash over the project name: a project keeps the same
// silhouette whoever else is on the wall, so the room learns the skyline as a
// place. An index into the sorted towers would re-shape the whole city every
// time one drained.
function hash(text) {
  let h = 0;
  for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) >>> 0;
  return h;
}

function newTower(project) {
  return {
    project,
    label: project ? project.toUpperCase() : UNCHARTED,
    known: project !== '',
    // Body outline and roof furniture from two slices of the same hash: 20
    // combinations, enough that a handful of repos read as different buildings.
    shape: hash(project || UNCHARTED) % SILHOUETTES,
    crown: (hash(project || UNCHARTED) >>> 8) % CROWNS,
    runIds: [],     // rendered as lit shafts, most urgent first
    live: 0,        // active + alarm: what is climbing right now
    alarm: 0,
  };
}

// What stands in the skyline: everything live, plus a run that has just
// finished, for as long as its completion moment lasts. An alarm is live by
// definition — a run waiting on a human stays pinned up there until somebody
// answers it, however long that takes.
function onSkyline(run, at) {
  if (run.state === 'active' || run.state === 'alarm') return true;
  return at - (run.since || 0) <= COMPLETION_S;
}

// Alphabetical, with the fallback tower last. Deterministic and independent of
// run state: a skyline that re-ordered itself as runs came and went would be
// unreadable as a place.
function towerRank(tower) {
  return tower.known ? [0, tower.project] : [1, ''];
}

function buildTowers(runs, at) {
  const towers = new Map();
  // `runs` arrives in wall order (alarms, then live oldest-first, then finished
  // newest-first), which also gives the shafts a stable urgency order.
  for (const run of runs) {
    if (!onSkyline(run, at)) continue;
    if (!towers.has(run.project)) towers.set(run.project, newTower(run.project));
    const tower = towers.get(run.project);
    if (run.state === 'alarm') tower.alarm += 1;
    if (run.state === 'active' || run.state === 'alarm') tower.live += 1;
    tower.runIds.push(run.id);
  }
  return [...towers.values()].sort((a, b) => {
    const [ga, ka] = towerRank(a);
    const [gb, kb] = towerRank(b);
    return ga - gb || ka.localeCompare(kb);
  });
}

// --- the week's city ------------------------------------------------------------
// The skyline above shows effort and leaves nothing behind. This is the other
// half, and it inverts that: the week ACCRETES. Monday 00:00 local the plain is
// empty; every run that reaches `done: ready` pours one PERMANENT building into
// it; by Friday the district is the week's shipped work, standing under whatever
// is still being built. Last week's city stays behind it as a flat ghost — the
// name finally earning itself.
//
// Zero new storage, and no reset job. cleanup.sh removes the worktree and keeps
// the run's logs, so the evidence outlives the branch, and the week is a pure
// window over the finish epoch already on the status line: nothing is written,
// nothing is rolled over, and Monday empties the plain by arithmetic alone.

// Only `done: ready` builds. stateOf() is deliberately broader — sync-pr.sh's
// prose "done: PR branch synced …" is a success too — but a ship is the
// pipeline's own word for one, and the wall does not infer it from anything else.
const DONE_READY = /^done:\s*ready\b/i;

// Monday 00:00 in the server's own timezone. Walked with Date rather than
// subtracted in seconds so the DST weeks are 23 and 25 hours long, like the
// week everyone in the room actually had.
function weekStartOf(epoch) {
  const d = new Date(epoch * 1000);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return Math.floor(d.getTime() / 1000);
}

// Building type by repo FAMILY, matched in order — legibility over cuteness. The
// room should be able to say "that's three agent towers and a valoryx spire"
// without reading a label. Anything unrecognised is an honest mid-rise rather
// than a guess at what somebody's repo does.
const KINDS = [
  [/^olyx-agents$/, 'residential'],
  [/^olyxbase$/, 'industrial'],
  [/^olyx-?dashboard$/, 'industrial'],
  [/^valoryx(-|$)/, 'spire'],
  [/^dispatch-harness$/, 'infra'],
];

function kindOf(project) {
  for (const [re, kind] of KINDS) if (re.test(project)) return kind;
  return 'midrise';
}

// Height is the diff, log-scaled and capped: a 40-line fix is visibly smaller
// than a 400-line feature, and the 4000-line monster reads as big without
// dwarfing the block it stands in. A run with no readable metrics is the
// shortest building there is — never an invented one.
const STOREYS_MIN = 3;
const STOREYS_MAX = 14;
const DIFF_CAP = 2000;

function storeysOf(diff) {
  const part = (v) => Math.max(0, Number(v) || 0);
  const lines = part(diff && diff.insertions) + part(diff && diff.deletions);
  const scale = Math.log1p(Math.min(lines, DIFF_CAP)) / Math.log1p(DIFF_CAP);
  return STOREYS_MIN + Math.round((STOREYS_MAX - STOREYS_MIN) * scale);
}

// hash() is a polynomial, which is all a tower silhouette needs — but a run id
// is OLYX-1631 next to OLYX-1632, and neighbouring inputs come out of that with
// neighbouring bits. A district planned straight off it piles a whole ticket
// range onto one plot. This is murmur3's finaliser: it decorrelates the bits so
// two consecutive tickets land nowhere near each other, and it is still a pure
// function of the id.
function mix(h) {
  let v = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
  v = Math.imul(v ^ (v >>> 13), 0xc2b2ae35) >>> 0;
  return (v ^ (v >>> 16)) >>> 0;
}

// Where a building stands, from its run id and nothing else: the same ship is on
// the same plot after a reload, on the second TV, and on a colleague's laptop.
// An index into the current week would re-plan the whole district every time
// something shipped.
function plotOf(id) {
  const h = mix(hash(id));
  return { x: (h % 1000) / 1000, depth: (h >>> 22) % 3 };
}

// A landed building never changes again: same id, same finish epoch, same
// building. Memoised on that pair so a week of ships costs its file reads once
// instead of once a second for as long as the wall is up.
const built = new Map();

function buildingOf(ship) {
  const cached = built.get(ship.id);
  if (cached && cached.at === ship.since) return cached;
  const result = readJSON(path.join(ship.dir, 'result.json')) || {};
  const project = projectOf(ship.id, ship.dir, result);
  const owner = ownerOf(ship.dir, result);
  const plot = plotOf(ship.id);
  const building = {
    id: ship.id,
    project,
    kind: kindOf(project),
    storeys: storeysOf((result.metrics || {}).diff),
    x: plot.x,
    depth: plot.depth,
    owner,
    ownerKind: ownerKindOf(owner),
    at: ship.since,
  };
  built.set(ship.id, building);
  return building;
}

// One building per run id. A run dispatched with HARNESS_MIRROR lands its run
// dir on the wall's own machine under that same id, so the same ship can be seen
// twice; the later status is the true one, and the city counts it once.
function dedupe(ships) {
  const seen = new Map();
  for (const ship of ships) {
    const prior = seen.get(ship.id);
    if (!prior || ship.since > prior.since) seen.set(ship.id, ship);
  }
  return [...seen.values()];
}

function shipsOf(scanned) {
  return dedupe(scanned
    .filter((s) => s.current.since !== null && DONE_READY.test(s.current.stage))
    .map((s) => ({ id: s.id, dir: s.dir, since: s.current.since })));
}

// Ambient life is the week's momentum, not decoration: a mover per few ships,
// the shop windows coming on at the tenth, a tram line at the twentieth. Capped
// so a very good week stays a city rather than a traffic jam in front of the
// live runs.
const PER_MOVER = 3;
const MAX_MOVERS = 8;
const SHOPS_AT = 10;
const TRAM_AT = 20;

function lifeOf(ships) {
  return {
    movers: Math.min(MAX_MOVERS, Math.floor(ships / PER_MOVER)),
    shops: ships >= SHOPS_AT,
    tram: ships >= TRAM_AT,
  };
}

// Far buildings first, so the page's DOM order is its painting order and a
// building landing in the middle of the district does not restack the ones
// already standing.
function plotRank(a, b) {
  return a.depth - b.depth || a.x - b.x || (a.id < b.id ? -1 : 1);
}

// This week's buildings, and last week's as bare silhouettes: an outline and a
// height, nothing that could be read as a type, a window or a name. An empty
// last week yields an empty list, and the page draws no ghost at all.
function buildCity(ships, at) {
  const start = weekStartOf(at);
  const before = weekStartOf(start - 1);
  const city = [];
  const ghost = [];
  for (const ship of ships) {
    if (ship.since >= start) city.push(buildingOf(ship));
    else if (ship.since >= before) ghost.push(buildingOf(ship));
  }
  city.sort(plotRank);
  ghost.sort(plotRank);
  // Everything the memo holds that is no longer in either window is a run that
  // has aged out of the city; a wall left up for a month must not accumulate it.
  const standing = new Set([...city, ...ghost].map((b) => b.id));
  for (const id of built.keys()) if (!standing.has(id)) built.delete(id);
  return {
    week: { start, ships: city.length, life: lifeOf(city.length) },
    city,
    ghost: ghost.map((b) => ({ x: b.x, storeys: b.storeys })),
  };
}

// --- http ---------------------------------------------------------------------

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/wall.css': ['wall.css', 'text/css; charset=utf-8'],
  '/wall.js': ['wall.js', 'text/javascript; charset=utf-8'],
};

const clients = new Set();
let poller = null;
let lastBody = '';

// Towers carry ids, not copies: every run travels once, and the page looks the
// run up by id. `runs` is the honest snapshot of the disk (live work plus a
// compact tail of finished runs); `towers` is the skyline, which is live only.
function payload() {
  const at = Math.floor(Date.now() / 1000);
  const scanned = scan();
  const runs = snapshot(scanned);
  const { week, city, ghost } = buildCity(shipsOf(scanned), at);
  return {
    at,
    runsDir: RUNS,
    crew: CREW,
    floors: FLOORS,
    completionSeconds: COMPLETION_S,
    signSeconds: SIGN_S,
    week,
    city,
    ghost,
    towers: buildTowers(runs, at),
    runs,
  };
}

// Everything a viewer can see, and nothing that ticks on its own: `at` moves
// every second, and pushing a frame for it would repaint an idle wall forever.
// The skyline is in here because a completion moment ending is a real change
// even when no run on disk moved — and so is the week rolling over at Monday
// 00:00, which empties the district with nothing on disk having changed at all.
// Buildings carry their finish epoch rather than their age for the same reason:
// an age would tick, and the wall would never be quiet.
function fingerprint(frame) {
  return JSON.stringify([frame.towers, frame.runs, frame.week, frame.city, frame.ghost]);
}

// One poll for all viewers; a frame is only pushed when something actually
// changed, so an idle wall is silent and a busy one repaints at POLL_MS.
function tick() {
  let body;
  try { body = payload(); } catch { return; }
  const fp = fingerprint(body);
  if (fp === lastBody) return;
  lastBody = fp;
  const frame = `event: snapshot\ndata: ${JSON.stringify(body)}\n\n`;
  for (const res of clients) { try { res.write(frame); } catch { /* dropped */ } }
}

function startPolling() {
  if (poller) return;
  poller = setInterval(tick, POLL_MS);
  poller.unref?.();
}

function stopPolling() {
  if (poller && clients.size === 0) { clearInterval(poller); poller = null; }
}

function stream(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });
  res.write(`retry: 2000\nevent: snapshot\ndata: ${JSON.stringify(payload())}\n\n`);
  clients.add(res);
  startPolling();
  // A comment frame every 15s: proxies keep the socket, and the page can tell a
  // dead link from a quiet one.
  const beat = setInterval(() => { try { res.write(': beat\n\n'); } catch { /* dropped */ } }, 15000);
  beat.unref?.();
  const close = () => { clearInterval(beat); clients.delete(res); stopPolling(); };
  req.on('close', close);
  res.on('error', close);
}

function serveStatic(res, entry) {
  fs.readFile(path.join(HERE, entry[0]), (err, buf) => {
    if (err) { res.writeHead(500).end('wall: missing asset\n'); return; }
    res.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store' });
    res.end(buf);
  });
}

const server = http.createServer((req, res) => {
  try {
    const url = (req.url || '/').split('?')[0];
    if (url === '/api/stream') return stream(req, res);
    if (url === '/api/runs') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(JSON.stringify(payload()));
    }
    const entry = STATIC[url];
    if (entry) return serveStatic(res, entry);
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('wall: no such page\n');
  } catch (err) {
    try { res.writeHead(500).end(`wall: ${err.message}\n`); } catch { /* client gone */ }
  }
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`wall: port ${PORT} is already in use — pass --port <n>`);
  } else {
    console.error(`wall: ${err.message}`);
  }
  process.exit(1);
});

// Required rather than run: the city's rules are arithmetic over a run id, a
// finish epoch and a diff, so tests/wall.test.sh calls them directly instead of
// staging a run dir per rule. Nothing listens in that mode.
if (require.main === module) {
  server.listen(PORT, HOST, () => {
    // The bound port, not the requested one: --port 0 asks the OS for a free one,
    // which is how tests and a second wall on the same box stay collision-free.
    const bound = server.address().port;
    console.log(`[wall] serving ${RUNS}`);
    console.log(`[wall] http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${bound}/  (ctrl-c to stop)`);
  });

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => { server.close(); process.exit(0); });
  }
}

module.exports = {
  weekStartOf, kindOf, storeysOf, plotOf, dedupe, lifeOf, buildCity,
  SIGN_S, STOREYS_MIN, STOREYS_MAX, PER_MOVER, SHOPS_AT, TRAM_AT,
};
