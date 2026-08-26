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
//   GET /console       the ops console (wall/console/), a second frontend over
//                      the same two endpoints — see docs/wall.md
//   GET /api/runs      one snapshot of every run, as JSON
//   GET /api/stream    the same snapshot pushed over SSE whenever it changes
//
// Everything here is best-effort by design: the run dirs are written live by
// run-task.sh, so any file may be missing, empty, or caught mid-write. Same
// philosophy as collect_metrics() — render what is on disk, never throw.

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

// The room's own frame names, so the roster below can be checked against
// exactly the files the renderer will ask for rather than against a second list
// that drifts from it. Required, not run: room.js is a UMD and hands over its
// naming when there is no window to attach to.
const ROOM = require('./room.js');

// The cost half of the console's frame: shapes the pre-computed figures and
// formats every cost string an operator sees. Dual-target (server + browser),
// so it is required here rather than inlined.
const Cost = require('./cost.js');

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
//
// Thirty rather than twenty from this pass on: a ship now gets a film — out of
// the room, down to the plot, and home to the wide, about twenty seconds of it
// (SHIP, world-canvas.js) — and a roof beacon that went out while the camera
// was still on its way back would leave the wall saying nothing happened. A
// design constant, and the only thing it lengthens is how long a finished run
// stands in the skyline it has already left.
const COMPLETION_S = 30;

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

// WHAT DAY IT IS, on the one machine that can answer it: the wall is a panel in
// an office and the office has one date, not one per browser. `MM-DD` and no
// year, because that is what a roster line carries — nobody puts the year they
// were born on the wall.
//
// WALL_TODAY pins it, which is how the suite asks for a day that is not today
// without touching anybody's clock. It has to be a well-formed MM-DD to have
// any effect at all: a pin nobody can read is not a date, and shipping it would
// make the page's answer depend on a typo rather than fall back to the truth.
function todayOf(now) {
  const pinned = ROOM.calendarDayOf(process.env.WALL_TODAY || '');
  if (pinned) return pinned;
  const d = now || new Date();
  return String(d.getMonth() + 1).padStart(2, '0') + '-'
    + String(d.getDate()).padStart(2, '0');
}

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

// A shipped building needs the diff shape promised by result.json. JSON.parse
// accepting a value does not make it a valid result document: `true`, `[]`, or
// an object caught between schema fields must be retried just like truncated
// JSON. Zero-line diffs remain valid (and become the minimum-height building).
function shippedDiffOf(result) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) return null;
  const metrics = result.metrics;
  if (!metrics || typeof metrics !== 'object' || Array.isArray(metrics)) return null;
  const diff = metrics.diff;
  if (!diff || typeof diff !== 'object' || Array.isArray(diff)) return null;
  if (!Object.hasOwn(diff, 'insertions') || !Object.hasOwn(diff, 'deletions')) return null;
  const valid = (value) => value === null ||
    (typeof value === 'number' && Number.isFinite(value) && value >= 0);
  return valid(diff.insertions) && valid(diff.deletions) ? diff : null;
}

// --- the stage-text -> actor contract ----------------------------------------
// CONTRACT: stage-vocab.json beside this file is the machine-readable stage
// vocabulary — the one table mapping the stage strings run-task.sh's stage()
// writes onto who is working (`actor`, plus the `key` the page colours the panel
// with) and what state that leaves the run in. It used to be an array here, and
// separately the case arms in statusline.sh, and status.sh sourcing those:
// three copies of a wire format nothing checked. tests/stage-vocab.test.sh now
// proves the table covers everything run-task.sh emits and that both consumers
// still agree with it; docs/wall-contract.md is the prose.
//
// The entries are DISJOINT by construction — `unless` vetoes a match — so
// exactly one wins for any stage text and the file's order is for reading, not
// for resolution. Required rather than read, like room.js: it ships beside this
// file, and a wall with no vocabulary has nothing to render a run with.
const VOCAB = require('./stage-vocab.json').stages.map((entry) => ({
  actor: entry.actor,
  key: entry.key,
  state: entry.state,
  re: new RegExp(entry.pattern, 'i'),
  veto: entry.unless ? new RegExp(entry.unless, 'i') : null,
}));

function vocabOf(stage) {
  const text = String(stage || '');
  for (const entry of VOCAB) {
    if (entry.re.test(text) && !(entry.veto && entry.veto.test(text))) return entry;
  }
  return null;   // a stage with no row is an honest '?', never a guess
}

function actorOf(stage) {
  const entry = vocabOf(stage);
  return entry
    ? { actor: entry.actor, actorKey: entry.key }
    : { actor: '?', actorKey: 'unknown' };
}

// active | alarm | ready | failed, off the same table. `done: <status>` carries
// the outcome, and every failing STATUS in run-task.sh ends in _failed or is
// "rejected"; sync-pr's "done: PR branch synced …" is a success, so the table
// matches the failure words, not a whitelist of the good ones.
const DONE_NEEDS_INPUT = /^done:\s*needs_input\b/i;

function stateOf(stage) {
  const entry = vocabOf(stage);
  return entry ? entry.state : 'active';
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
  codex: 3, skipped: 3, unreviewed: 3,
  demo: 4,
  pr: 5,
};

// The actor whose work each floor represents. Alarm runs deliberately replace
// actorKey with `alarm` for the wide city's status light; workActorKey preserves
// who is sitting inside that floor so interior views do not need their own copy
// of the pipeline ladder.
const FLOOR_ACTOR = ['setup', 'opus', 'gate', 'codex', 'demo', 'pr'];

// A finished run parks at the floor it stopped on, not at the roof: a
// `done: gate_failed` burnout two floors down is the honest picture, and only a
// run that actually shipped lights the rooftop. Anything unrecognised (a future
// status, sync-pr.sh's prose "done: PR branch synced …") made it to the top.
const DONE_FLOOR = [
  [/setup_failed/, 0],
  // The implementer→gate boundary refused a dirty tree: work stopped right
  // after IMPLEMENT, one rung below gate_failed.
  [/dirty_worktree_failed/, 1],
  [/implementer_failed|capacity_failed/, 1],
  // visual_failed is the creative harness's render-and-grade round giving up.
  // Its live stage borrows the gate's rung (stage-vocab.json), so its burnout
  // parks there too rather than on a roof the run never reached.
  [/gate_failed|visual_failed/, 2],
  [/rejected|review_failed/, 3],
];

function floorOf(stage, actorKey) {
  if (/^done:/.test(stage)) {
    const outcome = stage.slice(5).trim();
    for (const [re, floor] of DONE_FLOOR) if (re.test(outcome)) return floor;
    return FLOORS.length - 1;
  }
  return FLOOR_OF[actorKey] ?? 0;
}

// The two terminal statuses that are written AFTER, and on top of, the stage
// that actually stopped: `done: needs_input` (the run asked a question) and
// `done: driver_failed` (the driver was killed mid-stage). Neither names a rung
// of its own, and neither may fall through to the rooftop — a driver killed
// during IMPLEMENT would otherwise render on the PUSH floor reserved for runs
// that shipped. Recover the stage underneath instead; that is the floor the run
// really reached.
const DONE_PRIOR_FLOOR = /^done:\s*(needs_input\b|driver_failed\b)/;

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

// Count completed segments by the CLI's own result value and the currently open
// segment by assistant events. This is the same fallback telemetry uses when a
// result omits num_turns, but it remains useful before result.json exists.
function liveTurnsOf(dir) {
  const stream = head(path.join(dir, 'opus-stream.jsonl'), 32 << 20);
  if (!stream) return null;
  let turns = 0;
  let segment = 0;
  let seen = false;
  for (const line of stream.split('\n')) {
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    if (!event || typeof event !== 'object') continue;
    if (event.type === 'assistant') {
      segment += 1;
      seen = true;
    } else if (event.type === 'result') {
      const reported = event.num_turns;
      turns += typeof reported === 'number' && Number.isFinite(reported) && reported >= 0
        ? reported : segment;
      segment = 0;
      seen = true;
    }
  }
  return seen ? turns + segment : null;
}

// The invocation's final count wins once result.json exists; while it is still
// running, the append-only stream above supplies the count in progress.
function turnsOf(metrics, dir) {
  for (const n of [metrics.usage && metrics.usage.turns, metrics.implementer_num_turns]) {
    if (typeof n === 'number' && Number.isFinite(n) && n >= 0) return n;
  }
  return liveTurnsOf(dir);
}

function providerOf(dir, result) {
  const pin = readChunk(path.join(dir, 'implementer-provider'), 4096, false);
  if (pin) return pin.text.split('\n')[0].trim();
  return result.implementer_provider || '';
}

// result.json, read once per file version. A finished run's result.json never
// changes, and the summary corpus asks about every run on disk every poll —
// without this memo that would be a re-parse of history each second. A missing
// or half-written file is not memoised: it is retried next poll, exactly as a
// direct readJSON would be.
const resultMemo = new Map();   // run dir -> { mtimeMs, result }

function resultOf(dir) {
  const file = path.join(dir, 'result.json');
  let mtimeMs = 0;
  try { mtimeMs = fs.statSync(file).mtimeMs; } catch { return null; }
  const hit = resultMemo.get(dir);
  if (hit && hit.mtimeMs === mtimeMs) return hit.result;
  const result = readJSON(file);
  if (!result) return null;
  resultMemo.set(dir, { mtimeMs, result });
  return result;
}

function readRun(id, current) {
  const dir = path.join(RUNS, id);
  const { since, stage } = current || currentStage(dir);
  if (since === null && stage === '') return null; // not a run dir (yet)
  const result = resultOf(dir) || {};
  const metrics = result.metrics || {};
  const started = Number(firstLine(path.join(dir, 'started'))) || since;
  const state = stateOf(stage);
  const gateRounds = tailLines(path.join(dir, 'gate-rounds.log'), 8)
    .map((l) => l.split(/\s+/))
    .filter((p) => p.length >= 2)
    .map(([round, verdict]) => ({ round, verdict }));

  const owner = ownerOf(dir, result);
  const project = projectOf(id, dir, result);
  const provider = providerOf(dir, result);
  let { actor, actorKey } = actorOf(stage);
  const terminalNeedsInput = DONE_NEEDS_INPUT.test(stage);
  // driver_failed parks on the floor it died on, like needs_input — but it is
  // a burnout, not an alarm, so it keeps its own actor rather than becoming
  // "needs input" below.
  const floor = (terminalNeedsInput || DONE_PRIOR_FLOOR.test(stage))
    ? previousFloor(dir)
    : floorOf(stage, actorKey);
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
    workActorKey: state === 'alarm' ? FLOOR_ACTOR[floor] || 'unknown' : actorKey,
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
    // The pin file, not the stage text: `implementing — Opus (Claude sub)` is
    // written verbatim on a zai run too, so the words on the wall cannot tell an
    // operator which subscription is being spent. The file exists from the first
    // stage and is rewritten when an escalation changes the answer.
    provider,
    // What the run spent, as the pipeline recorded it. Null while result.json
    // has not landed; a record with null figures once it has and telemetry
    // could not price it. à-la-carte list price, never money spent: the plan
    // is flat whatever the provider.
    cost: Cost.runCost(result, provider),
    turns: turnsOf(metrics, dir),
    diff: metrics.diff || null,
    verifier: metrics.verifier || null,
    blocked: state === 'alarm' ? firstProse(path.join(dir, 'QUESTIONS.md')) : '',
    reason: state === 'failed' ? firstProse(path.join(dir, 'REJECTED.md')) : '',
    feed: feedOf(dir),
  };
}

// Newest-first by the mtime of `status` (what stage() touches). The finished
// cap is applied in snapshot(), after each cheap stage read: capping IDs here
// could let a burst of completed runs hide an older run that is still active.
// The mtime rides along because the summary windows on it — every run is
// already statSynced here, and windowing is a second question about the same
// fact.
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
    .sort((a, b) => b.mtime - a.mtime);
}

const ORDER = { alarm: 0, active: 1, failed: 2, ready: 2 };

// One read of every run's status line per poll, shared by the live skyline and
// by the week's city below — they ask different questions of the same fact, and
// reading the file twice would double the wall's disk traffic for nothing.
function scan() {
  const seen = [];
  for (const { name, mtime } of listRunIds()) {
    try {
      const dir = path.join(RUNS, name);
      const current = currentStage(dir);
      if (current.since === null && current.stage === '') continue;
      seen.push({ id: name, dir, current, mtimeMs: mtime });
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

// The console frame's summary, over the windowed SCAN rather than the emitted
// run list: snapshot() caps finished runs at MAX_FINISHED, so a summary read
// off frame.runs would silently undercount any week that shipped more than
// that. Only in-window runs are entered at all, so a wall watching years of
// history does not re-read a pin file per ancient run per poll. Live runs
// carry null figures: counting an active run's turns means reading its stream
// a second time in a poll that already read it, and a moving number is not
// one to total.
function summaryOf(scanned, nowMs) {
  const floor = nowMs - Cost.SUMMARY_WINDOW_DAYS * 864e5;
  const entries = [];
  for (const { dir, current, mtimeMs } of scanned) {
    if (mtimeMs < floor || mtimeMs > nowMs) continue;
    const state = stateOf(current.stage);
    const finished = state === 'ready' || state === 'failed';
    const result = resultOf(dir) || {};
    const provider = providerOf(dir, result);
    const cost = finished ? Cost.runCost(result, provider) : null;
    entries.push({
      state,
      provider,
      mtimeMs,
      opusListUsd: cost ? cost.opusListUsd : null,
      zaiCredits: cost ? cost.zaiCredits : null,
      turns: finished ? turnsOf(result.metrics || {}, dir) : null,
    });
  }
  return Cost.summarize(entries, { nowMs, windowDays: Cost.SUMMARY_WINDOW_DAYS });
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
// PERMANENT is the contract, and it is the reason this reads a ledger rather
// than the run dirs. A run dir is not permanent: cleanup.sh promotes a run and
// mirror_remove() deletes the mirrored copy off this very machine, so a city
// derived from what is on disk would demolish a building the moment somebody
// tidied up after it. Run dirs are therefore the DISCOVERY source and the ledger
// is the MEMORY — a building survives cleanup, mirror removal and a reboot,
// which is what "permanent for the week" has to mean.
//
// The ledger is one append-only JSONL file the wall owns, one line per run id
// ever. Everything a building looks like is derived from that line at render
// time, so the mapping below can change without rewriting history.

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

// The exclusive far edge of that local-time window. Advancing the calendar is
// deliberate: adding seven lots of 24 hours would be wrong across a DST change.
function weekEndOf(epoch) {
  const d = new Date(weekStartOf(epoch) * 1000);
  d.setDate(d.getDate() + 7);
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
// dwarfing the block it stands in. A run whose result.json recorded no diff at
// all is the shortest building there is — a run whose result.json could not be
// read is not a building, and never reaches this.
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

// A building, entirely from its ledger line. Pure: the run dir it came from may
// have been cleaned up weeks ago, and the city has to stand anyway.
function buildingOf(record) {
  const plot = plotOf(record.id);
  return {
    id: record.id,
    project: record.repo,
    kind: kindOf(record.repo),
    storeys: storeysOf(record),
    x: plot.x,
    depth: plot.depth,
    owner: record.owner,
    ownerKind: ownerKindOf(record.owner),
    at: record.epoch,
  };
}

// --- the ledger -----------------------------------------------------------------
// One append-only JSONL file, one line per run id ever, first observation wins.
// That last rule is what makes a mirrored run harmless: HARNESS_MIRROR copies a
// run dir onto this machine under its own id, so the same ship can be discovered
// twice — a second sighting of an id already in the ledger is simply not a new
// building.
//
// Every read and every write here is best-effort, like the rest of this file. A
// missing or unreadable ledger is an empty plain and one line on stderr, a
// corrupt LINE is skipped rather than fatal, and a write that fails is retried
// on later polls — nothing about the city may take the wall down.

const CITY_FILE = process.env.WALL_CITY || path.join(path.dirname(RUNS), 'wall-city.jsonl');

const ledger = new Map();   // run id -> record, in the order the wall saw them
const pending = new Map();  // records visible now whose append needs retrying
let loaded = false;
let prunedFor = 0;          // the week start the ledger was last pruned for
let writeWarned = false;

// A line is only a record if it carries the two fields the city cannot invent:
// which run it was, and when it landed. The rest is coerced — an old line with a
// field missing should cost that building a detail, not its place in the city.
function recordOf(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (typeof raw.id !== 'string' || typeof raw.epoch !== 'number' ||
      !Number.isFinite(raw.epoch)) return null;
  const id = raw.id.trim();
  const epoch = raw.epoch;
  if (id === '') return null;
  const count = (v) => Math.max(0, Number(v) || 0);
  return {
    id,
    epoch: Math.floor(epoch),
    repo: String(raw.repo || '').trim().toLowerCase(),
    owner: String(raw.owner || '').trim().toLowerCase().slice(0, 24),
    insertions: count(raw.insertions),
    deletions: count(raw.deletions),
  };
}

// Text in, records out, first line per id winning. Separated from the file read
// so the tolerance rules are testable without a filesystem.
function parseLedger(text) {
  const records = new Map();
  let skipped = 0;
  for (const line of String(text).split('\n')) {
    if (line.trim() === '') continue;
    let record = null;
    try { record = recordOf(JSON.parse(line)); } catch { /* half a line, or junk */ }
    if (!record) { skipped += 1; continue; }
    if (!records.has(record.id)) records.set(record.id, record);
  }
  return { records, skipped };
}

function loadLedger() {
  if (loaded) return;
  loaded = true;
  let text;
  try {
    text = fs.readFileSync(CITY_FILE, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') {
      console.error('[wall] city ledger missing — starting from an empty plain');
    } else {
      console.error(`[wall] city ledger unreadable (${err.message}) — starting from an empty plain`);
    }
    return;
  }
  const { records, skipped } = parseLedger(text);
  for (const [id, record] of records) ledger.set(id, record);
  if (skipped) console.error(`[wall] city ledger: skipped ${skipped} unreadable line(s)`);
}

function appendRecord(record) {
  try {
    fs.mkdirSync(path.dirname(CITY_FILE), { recursive: true });
    fs.appendFileSync(CITY_FILE, JSON.stringify(record) + '\n');
    return true;
  } catch (err) {
    if (!writeWarned) {
      writeWarned = true;
      console.error(`[wall] city ledger not writable (${err.message}) — will retry`);
    }
    return false;
  }
}

function remember(record) {
  if (ledger.has(record.id)) return;   // one line per run id, ever
  ledger.set(record.id, record);
  // Keep the city correct in memory during an I/O failure, but do not mistake
  // that for permanence: later polls retry until the record reaches disk.
  if (!appendRecord(record)) pending.set(record.id, record);
}

function flushPending() {
  for (const [id, record] of pending) {
    if (!appendRecord(record)) break;
    pending.delete(id);
  }
}

// Monday's rollover, on disk. Only the two windows the wall can draw are worth
// keeping, so anything older goes — rewritten through a temp file and renamed,
// because a half-written ledger is a razed city. Nothing to drop means nothing
// is rewritten: a wall left up for a month touches this file once a week.
function pruneLedger(before) {
  const keep = [...ledger.values()].filter((record) => record.epoch >= before);
  if (keep.length === ledger.size) return true;
  const scratch = CITY_FILE + '.tmp';
  try {
    fs.mkdirSync(path.dirname(CITY_FILE), { recursive: true });
    fs.writeFileSync(scratch, keep.map((record) => JSON.stringify(record) + '\n').join(''));
    fs.renameSync(scratch, CITY_FILE);
  } catch (err) {
    try { fs.unlinkSync(scratch); } catch { /* never existed */ }
    if (!writeWarned) {
      writeWarned = true;
      console.error(`[wall] city ledger not writable (${err.message}) — will retry`);
    }
    return false;
  }
  ledger.clear();
  for (const record of keep) ledger.set(record.id, record);
  // The rewrite persisted the complete kept map, including any record whose
  // earlier append was pending, so none of those records needs a later append.
  pending.clear();
  return true;
}

// --- the fixtures' own memory ---------------------------------------------------
// `wall.sh --runs wall/fixtures/runs` is the demo, and the scene the visual gate
// renders. The staged run dirs give it a full skyline; the district under them
// comes from the ledger instead, and the fixtures contain exactly one
// `done: ready` — so the one thing the demo could never show was the half of the
// wall that accretes. When this server is serving the repo's OWN fixtures and
// has no ledger yet, it lays a week of memory down before it listens.
//
// Both halves of that condition are the guard. A real deployment is any other
// --runs, and a wall that already has a ledger has its own history: neither is
// ever touched, and there is no flag to make them be. The seed goes in through
// the ordinary append, so every later rule — one line per run id, Monday's
// rollover, a restart reading the city back off disk — applies to it unchanged,
// and a demo restarted on the same ledger finds the district it left.
const FIXTURE_RUNS = path.join(HERE, 'fixtures', 'runs');

function realPath(file) {
  try { return fs.realpathSync(file); } catch { return ''; }
}

// Resolved rather than compared as text: --runs is commonly relative (the visual
// gate passes `wall/fixtures/runs`), and $TMPDIR on macOS is a symlink, so two
// spellings of one directory must not read as two directories.
function samePath(a, b) {
  return (realPath(a) || path.resolve(a)) === (realPath(b) || path.resolve(b));
}

function seedFixtureCity(at) {
  if (!samePath(RUNS, FIXTURE_RUNS) || fs.existsSync(CITY_FILE)) return;
  let records;
  try {
    records = require('./fixtures/city.js').cityRecords(at, weekStartOf)
      .map(recordOf)
      .filter(Boolean);
  } catch (err) {
    // A fixture module that is missing or broken costs the demo its district,
    // never the wall its start.
    console.error(`[wall] fixtures: no city to seed (${err.message})`);
    return;
  }
  // appendRecord has already said why it could not write; a half-laid district
  // is loaded off the file like any other ledger on the first poll.
  for (const record of records) if (!appendRecord(record)) return;
  console.error(`[wall] fixtures: seeding the city's memory (${records.length} buildings)`);
}

// Discovery. A run dir is how the wall FINDS a ship; the ledger is how it
// remembers one. Only this week's finishes are ever recorded — the ledger is
// what the wall witnessed, and it does not backfill a history it did not see.
//
// A result.json that is missing, caught mid-write, or does not have the result
// schema is skipped silently and retried on the next poll: a building is a
// record of a real diff, and inventing one from a file we could not read would
// be worse than waiting a second for it.
function observe(scanned, weekStart, weekEnd) {
  for (const { id, dir, current } of scanned) {
    if (current.since === null || !DONE_READY.test(current.stage)) continue;
    if (current.since < weekStart || current.since >= weekEnd) continue;
    if (ledger.has(id)) continue;
    try {
      const result = readJSON(path.join(dir, 'result.json'));
      const diff = shippedDiffOf(result);
      if (!diff) continue;
      remember(recordOf({
        id,
        epoch: current.since,
        repo: projectOf(id, dir, result),
        owner: ownerOf(dir, result),
        insertions: diff.insertions,
        deletions: diff.deletions,
      }));
    } catch { /* one broken run dir never blanks the wall */ }
  }
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
function buildCity(records, at) {
  const start = weekStartOf(at);
  const end = weekEndOf(at);
  const before = weekStartOf(start - 1);
  const city = [];
  const ghost = [];
  for (const record of records) {
    if (record.epoch >= start && record.epoch < end) city.push(buildingOf(record));
    else if (record.epoch >= before && record.epoch < start) ghost.push(buildingOf(record));
  }
  city.sort(plotRank);
  ghost.sort(plotRank);
  return {
    week: { start, ships: city.length, life: lifeOf(city.length) },
    city,
    ghost: ghost.map((b) => ({ x: b.x, storeys: b.storeys })),
  };
}

// The city, once per poll: catch up with the disk, drop what has aged out of
// both windows, and draw what is left.
function cityNow(scanned, at) {
  loadLedger();
  const start = weekStartOf(at);
  flushPending();
  observe(scanned, start, weekEndOf(at));
  if (prunedFor !== start && pruneLedger(weekStartOf(start - 1))) prunedFor = start;
  return buildCity([...ledger.values()], at);
}

// --- http ---------------------------------------------------------------------

const STATIC = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/wall.css': ['wall.css', 'text/css; charset=utf-8'],
  '/wall.js': ['wall.js', 'text/javascript; charset=utf-8'],
  '/scene.js': ['scene.js', 'text/javascript; charset=utf-8'],
  // The canvas world, and the engine it draws with. Named rows rather than a
  // directory route: /vendor/ is one pinned file, and a route that walked a
  // directory is the path traversal this server has never had.
  '/world-canvas.js': ['world-canvas.js', 'text/javascript; charset=utf-8'],
  '/room.js': ['room.js', 'text/javascript; charset=utf-8'],
  '/vendor/phaser.min.js': [path.join('vendor', 'phaser.min.js'), 'text/javascript; charset=utf-8'],
  // The ops console: a second, functional frontend over /api/runs and
  // /api/stream, sharing nothing with the city above it. Named rows for the
  // same reason /vendor/ has one — a directory route is a path traversal this
  // server has never had, and three files do not need one.
  '/console': [path.join('console', 'console.html'), 'text/html; charset=utf-8'],
  '/console/': [path.join('console', 'console.html'), 'text/html; charset=utf-8'],
  '/console/console.html': [path.join('console', 'console.html'), 'text/html; charset=utf-8'],
  '/console/console.css': [path.join('console', 'console.css'), 'text/css; charset=utf-8'],
  '/console/console.js': [path.join('console', 'console.js'), 'text/javascript; charset=utf-8'],
  '/console/cost.js': ['cost.js', 'text/javascript; charset=utf-8'],
};

// The room's sprites. A directory rather than a named row per file, because the
// room is a set that grows a frame at a time and a table of forty rows is a
// table nobody updates — but a directory route is the path traversal this
// server has never had, so it is fenced on all four sides: the path must be a
// plain relative one under wall/assets, every segment must be an ordinary name
// (no dots, no separators, no encoded ones), the extension must be on the list,
// and the resolved file must still be inside ASSETS after resolve() AND the
// filesystem have both had their say. Anything else is a 404, never a read.
//
// Through the real filesystem because a string fence only ever sees strings: a
// symlink committed under wall/assets is a perfectly ordinary segment with a
// perfectly ordinary extension whose contents are somewhere else entirely, and
// `..` is not the only way out of a directory.
// The root itself is resolved once, so a checkout under a symlinked path (a
// /tmp worktree on macOS, say) is not a checkout whose sprites all 404.
const ASSETS = realPath(path.join(HERE, 'assets')) || path.join(HERE, 'assets');
const ASSET_TYPES = {
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
};
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9]+)?$/;

// The url path under /assets/, or '' when it is not one this server will read.
function assetOf(url) {
  if (!url.startsWith('/assets/')) return '';
  const rest = url.slice('/assets/'.length);
  // Decoding first is the point: %2e%2e is the traversal a raw string compare
  // waves through. A malformed escape is not a path.
  let decoded;
  try { decoded = decodeURIComponent(rest); } catch { return ''; }
  const parts = decoded.split('/');
  if (!parts.length || !parts.every((part) => SEGMENT.test(part))) return '';
  const type = ASSET_TYPES[path.extname(parts[parts.length - 1]).toLowerCase()];
  if (!type) return '';
  const full = path.resolve(ASSETS, ...parts);
  if (full !== path.join(ASSETS, ...parts)) return '';
  if (!full.startsWith(ASSETS + path.sep)) return '';
  // And the same question once more of the file that is actually there. A path
  // that does not exist has no real path and is refused here rather than in
  // readFile, which is the same 404 one syscall earlier.
  const real = realPath(full);
  if (!real || !real.startsWith(ASSETS + path.sep)) return '';
  return real;
}

// Who sits at the desk, by owner — and only the ones this disk can actually
// draw. wall/crew.json is the authored roster; what goes over the wire is the
// part of it the room is allowed to believe.
//
// The check is not that the name looks like a path. `crew/angl` looks exactly
// like `crew/angel`, and a room that took it at its word would ask for six
// sprites that are not there, take six 404s, and hold an empty chair — which is
// a typo in a hand-edited file costing the whole room its worker. So every
// frame the renderer will ask for is put through the SAME guard the sprites
// themselves come down, and an entry whose set does not survive that keeps its
// owner's name and loses their character: a missing set is one person, never
// the room.
const CREW_FILE = path.join(HERE, 'crew.json');
function roster() {
  const table = readJSON(CREW_FILE) || {};
  const out = {};
  for (const owner of Object.keys(table)) {
    const entry = table[owner];
    if (!entry || typeof entry !== 'object') continue;
    const set = ROOM.setOf(table, owner);
    const whole = ROOM.FRAMES.every((frame) => assetOf('/' + ROOM.fileOf(set, frame)) !== '');
    out[owner] = { ...entry, set: whole ? set : ROOM.FALLBACK };
  }
  return out;
}

// The half of the roster the CITY needs, and only that half: whose name goes on
// a building and what colour it is written in. It rides every snapshot because
// wall/scene.js is pure arithmetic over one — a renderer that fetched crew.json
// for itself would be a second opinion about who somebody is, and the district,
// the skyline and the room would drift apart the first time one of them was
// slow. The sprite guard `roster()` runs is deliberately not repeated here: a
// name and a hex are facts about a person, not files this server has to prove
// it can read, and this runs on every poll.
function crewSigns() {
  const table = readJSON(CREW_FILE) || {};
  const out = {};
  for (const owner of Object.keys(table)) {
    const entry = table[owner];
    if (!entry || typeof entry !== 'object') continue;
    out[owner] = {
      label: typeof entry.label === 'string' ? entry.label : '',
      tint: typeof entry.tint === 'string' ? entry.tint : '',
    };
  }
  return out;
}

function serveAsset(res, file, type) {
  fs.readFile(file, (err, buf) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('wall: no such asset\n');
    }
    // Committed, content-addressed by the manifest and never rewritten in
    // place, so the TV may keep them for a shift.
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'max-age=3600' });
    return res.end(buf);
  });
}

const clients = new Map();
let poller = null;
let lastBody = '';
let lastConsoleBody = '';

// Towers carry ids, not copies: every run travels once, and the page looks the
// run up by id. `runs` is the honest snapshot of the disk (live work plus a
// compact tail of finished runs); `towers` is the skyline, which is live only.
function payload() {
  const now = new Date();
  const at = Math.floor(now.getTime() / 1000);
  const scanned = scan();
  const runs = snapshot(scanned);
  const { week, city, ghost } = cityNow(scanned, at);
  // The date rides on every run as well as on the frame. The page hands the
  // room a RUN and a ladder — that is the whole of what wall/room.js is given —
  // so a top-level field alone would never reach the one thing that draws it.
  // It also puts the date inside fingerprint(), which is what makes midnight a
  // change worth pushing: `at` ticks every second and is deliberately outside
  // it, but a date rolls over once, and when it does the wall has a birthday to
  // put in somebody's room.
  const today = todayOf(now);
  for (const run of runs) run.today = today;
  return {
    at,
    today,
    runsDir: RUNS,
    crew: CREW,
    // Who the wall knows, by lane key: their own spelling and their own colour.
    roster: crewSigns(),
    floors: FLOORS,
    completionSeconds: COMPLETION_S,
    signSeconds: SIGN_S,
    summary: summaryOf(scanned, now.getTime()),
    week,
    city,
    ghost,
    towers: buildTowers(runs, at),
    runs,
  };
}

// The city API predates the ops console and its run-object schema is a public
// contract. Console-only telemetry is available only when that frontend opts
// into the enriched representation; plain requests retain the original shape.
function publicPayload(frame) {
  const out = {
    ...frame,
    runs: frame.runs.map(({ provider: _provider, turns: _turns, cost: _cost, ...run }) => run),
  };
  delete out.summary;
  return out;
}

// Everything a viewer can see, and nothing that ticks on its own: `at` moves
// every second, and pushing a frame for it would repaint an idle wall forever.
// The skyline is in here because a completion moment ending is a real change
// even when no run on disk moved — and so is the week rolling over at Monday
// 00:00, which empties the district with nothing on disk having changed at all.
// Buildings carry their finish epoch rather than their age for the same reason:
// an age would tick, and the wall would never be quiet. The summary is in here
// for the same reason the week is: a run ageing out of the window changes the
// console's frame with nothing on disk changing — and on the public body,
// where publicPayload has deleted it, it contributes nothing at all.
function fingerprint(frame) {
  return JSON.stringify([frame.towers, frame.runs, frame.week, frame.city, frame.ghost, frame.summary]);
}

// One poll for all viewers; a frame is only pushed when something actually
// changed, so an idle wall is silent and a busy one repaints at POLL_MS.
function tick() {
  let body;
  try { body = payload(); } catch { return; }
  const publicBody = publicPayload(body);
  const publicFp = fingerprint(publicBody);
  const consoleFp = fingerprint(body);
  const publicChanged = publicFp !== lastBody;
  const consoleChanged = consoleFp !== lastConsoleBody;
  if (!publicChanged && !consoleChanged) return;
  lastBody = publicFp;
  lastConsoleBody = consoleFp;
  const frames = new Map();
  for (const [res, enriched] of clients) {
    if (enriched ? !consoleChanged : !publicChanged) continue;
    try {
      if (!frames.has(enriched)) {
        const view = enriched ? body : publicBody;
        frames.set(enriched, `event: snapshot\ndata: ${JSON.stringify(view)}\n\n`);
      }
      res.write(frames.get(enriched));
    } catch { /* dropped */ }
  }
}

function startPolling() {
  if (poller) return;
  poller = setInterval(tick, POLL_MS);
  poller.unref?.();
}

function stopPolling() {
  if (poller && clients.size === 0) { clearInterval(poller); poller = null; }
}

function stream(req, res, enriched) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });
  const body = payload();
  res.write(`retry: 2000\nevent: snapshot\ndata: ${JSON.stringify(enriched ? body : publicPayload(body))}\n\n`);
  clients.set(res, enriched);
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
    const requestUrl = new URL(req.url || '/', 'http://wall.local');
    const url = requestUrl.pathname;
    const consoleView = requestUrl.searchParams.get('view') === 'console';
    if (url === '/api/stream') return stream(req, res, consoleView);
    if (url === '/api/runs') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      const body = payload();
      return res.end(JSON.stringify(consoleView ? body : publicPayload(body)));
    }
    // Computed rather than a static row: the roster is crew.json filtered by
    // what is on this disk, and the disk can change under a wall that is up.
    if (url === '/crew.json') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end(JSON.stringify(roster()));
    }
    const entry = STATIC[url];
    if (entry) return serveStatic(res, entry);
    const asset = assetOf(url);
    if (asset) return serveAsset(res, asset, ASSET_TYPES[path.extname(asset).toLowerCase()]);
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
  seedFixtureCity(Math.floor(Date.now() / 1000));
  server.listen(PORT, HOST, () => {
    // The bound port, not the requested one: --port 0 asks the OS for a free one,
    // which is how tests and a second wall on the same box stay collision-free.
    const bound = server.address().port;
    console.log(`[wall] serving ${RUNS}`);
    console.log(`[wall] city ledger ${CITY_FILE}`);
    console.log(`[wall] http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${bound}/  (ctrl-c to stop)`);
  });

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => { server.close(); process.exit(0); });
  }
}

module.exports = {
  weekStartOf, weekEndOf, kindOf, storeysOf, plotOf, lifeOf, buildCity, parseLedger, recordOf,
  shippedDiffOf, CITY_FILE, SIGN_S, STOREYS_MIN, STOREYS_MAX, PER_MOVER, SHOPS_AT, TRAM_AT,
  assetOf, ASSETS, roster, crewSigns, todayOf,
  // The console's enriched view and its cost summary, callable without a port:
  // the suites ask publicPayload and summarize the same questions a poll does.
  publicPayload, summarize: Cost.summarize,
  // The stage vocabulary, resolved by the real code: tests/stage-vocab.test.sh
  // asks these the same questions a poll does, without staging a run dir per row.
  actorOf, stateOf, floorOf, FLOOR_OF, FLOORS,
};
