'use strict';
// The wall's inbound half: what runs report about themselves over HTTP.
//
// wall/server.js reads the run dirs on THIS machine. This module is the other
// direction — three POST channels a dispatch can be told to use
// (HARNESS_WALL_URL): the pipeline's own stage handoffs, the worker's Claude
// Code hook events, and the worker's OpenTelemetry metrics. A run on a laptop
// becomes a row on the mini's board; a run that is already on disk gains live
// telemetry beside it.
//
// A fourth route, POST /webhooks/linear, is Linear's own: what it delivers is
// verified against Linear's HMAC signature and kept nowhere — it exists so the
// app may subscribe to Agent session events, not because anything reads them.
//
// Fail-closed: with WALL_INGEST_TOKEN unset every report route below is a 404
// and the wall is the read-only server it has always been; the Linear webhook
// fails closed on WALL_LINEAR_WEBHOOK_SECRET the same way. Same philosophy as
// the disk side — a malformed report is dropped, never thrown.
//
// node:fs and node:crypto only, like the rest of wall/.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_BODY = 1 << 20;            // 1 MiB, then 413
const LINEAR_WINDOW_MS = 60 * 1000;  // a Linear delivery older or newer is a replay
const PRUNE_S = 7 * 24 * 3600;       // an entry nothing has updated for a week
const WRITE_DEBOUNCE_MS = 1000;      // at most one disk write a second
const MAX_SESSIONS = 8;              // session ids kept per run, newest last
const CLIP = 200;                    // every string a report can carry

// Datapoint attributes the CLI ships beside the numbers. They identify the
// human, not the run, and the wall is an unauthenticated LAN dashboard: they
// are dropped here, before anything reaches memory, disk or a payload.
const PII = new Set([
  'user.email', 'user.id', 'user.account_uuid', 'user.account_id',
  'organization.id', 'terminal.type',
]);

// claude_code.token.usage's `type` attribute -> the store's own key.
const TOKEN_KEY = {
  input: 'input', output: 'output',
  cacheRead: 'cache_read', cacheCreation: 'cache_creation',
};

const ROUTES = new Set([
  '/api/ingest/stage', '/api/ingest/hook',
  '/v1/metrics', '/v1/logs', '/v1/traces',
  '/webhooks/linear', '/webhooks/linear/',
]);

const TOKEN = process.env.WALL_INGEST_TOKEN || '';
const LINEAR_SECRET = process.env.WALL_LINEAR_WEBHOOK_SECRET || '';
const RUNS = process.env.WALL_RUNS ||
  path.join(process.env.HOME || '.', '.claude/harness/runs');
const STORE_FILE = process.env.WALL_INGEST_FILE ||
  path.join(path.dirname(RUNS), 'wall-ingest.json');

const enabled = () => TOKEN !== '';

// --- the store ----------------------------------------------------------------

const store = new Map();   // run id -> entry
let loaded = false;
let writePending = false;

function str(value) {
  return typeof value === 'string' ? value.slice(0, CLIP) : '';
}

function epoch(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : Math.floor(Date.now() / 1000);
}

function nano(value) {
  const text = String(value === undefined ? '' : value);
  if (!/^\d+$/.test(text)) return '';
  return text.replace(/^0+(?=\d)/, '');
}

function newerNano(candidate, previous) {
  if (!previous) return true;
  if (!candidate) return false;
  return candidate.length > previous.length ||
    (candidate.length === previous.length && candidate >= previous);
}

const META = ['host', 'owner', 'repo', 'provider', 'model', 'worktree',
  'branch', 'base', 'pr_url', 'status'];

function blank(at) {
  const entry = {
    stage: { text: '', at: 0 },
    first_seen: at, last_seen: at,
    hooks: {
      tools: 0, last_tool: '', last_tool_at: 0, last_at: 0,
      stops: 0, ended: null, sessions: [],
    },
    otel: {
      tokens: { input: 0, output: 0, cache_read: 0, cache_creation: 0 },
      cost_usd: 0, sessions: 0, models: [], last_at: 0,
      // The cumulative sums as last seen, keyed by session and series. Kept —
      // and persisted — because re-sending an OTLP body must not re-add its
      // totals, and a restart must not lose the sessions already counted.
      latest: {},
    },
  };
  for (const key of META) entry[key] = '';
  return entry;
}

// A store loaded off disk is whatever was there; every field is re-derived from
// a blank entry so a hand-edited or older file can never shape what is served.
function adopt(raw, at) {
  const entry = blank(at);
  if (!raw || typeof raw !== 'object') return entry;
  for (const key of META) entry[key] = str(raw[key]);
  if (raw.stage && typeof raw.stage === 'object') {
    entry.stage = { text: str(raw.stage.text), at: Number(raw.stage.at) || 0 };
  }
  entry.first_seen = Number(raw.first_seen) || at;
  entry.last_seen = Number(raw.last_seen) || at;
  const hooks = raw.hooks && typeof raw.hooks === 'object' ? raw.hooks : {};
  entry.hooks = {
    tools: Number(hooks.tools) || 0,
    last_tool: str(hooks.last_tool),
    last_tool_at: Number(hooks.last_tool_at) || 0,
    last_at: Number(hooks.last_at) || 0,
    stops: Number(hooks.stops) || 0,
    ended: typeof hooks.ended === 'string' ? hooks.ended.slice(0, CLIP) : null,
    sessions: Array.isArray(hooks.sessions)
      ? hooks.sessions.filter((s) => typeof s === 'string').slice(-MAX_SESSIONS) : [],
  };
  const otel = raw.otel && typeof raw.otel === 'object' ? raw.otel : {};
  const tokens = otel.tokens && typeof otel.tokens === 'object' ? otel.tokens : {};
  entry.otel = {
    tokens: {
      input: Number(tokens.input) || 0,
      output: Number(tokens.output) || 0,
      cache_read: Number(tokens.cache_read) || 0,
      cache_creation: Number(tokens.cache_creation) || 0,
    },
    cost_usd: Number(otel.cost_usd) || 0,
    sessions: Number(otel.sessions) || 0,
    models: Array.isArray(otel.models) ? otel.models.filter((m) => typeof m === 'string') : [],
    last_at: Number(otel.last_at) || 0,
    latest: {},
  };
  if (otel.latest && typeof otel.latest === 'object') {
    for (const key of Object.keys(otel.latest)) {
      const seen = otel.latest[key];
      if (!seen || typeof seen !== 'object') continue;
      const n = Number(seen.value);
      if (!Number.isFinite(n)) continue;
      entry.otel.latest[key] = {
        kind: str(seen.kind), field: str(seen.field), value: n, at: nano(seen.at),
      };
    }
  }
  return entry;
}

function load() {
  if (loaded) return false;
  loaded = true;
  let text;
  try { text = fs.readFileSync(STORE_FILE, 'utf8'); } catch { return false; }
  let raw;
  try { raw = JSON.parse(text); } catch { return false; }
  if (!raw || typeof raw !== 'object') return false;
  const at = Math.floor(Date.now() / 1000);
  for (const id of Object.keys(raw)) {
    if (!id) continue;
    store.set(id.slice(0, CLIP), adopt(raw[id], at));
  }
  return prune(at);
}

function prune(at) {
  let changed = false;
  for (const [id, entry] of store) {
    if (at - (entry.last_seen || 0) > PRUNE_S) {
      store.delete(id);
      changed = true;
    }
  }
  return changed;
}

function writeNow() {
  load();
  writePending = false;
  const out = {};
  for (const [id, entry] of store) out[id] = entry;
  try {
    fs.mkdirSync(path.dirname(STORE_FILE), { recursive: true });
    const scratch = STORE_FILE + '.tmp';
    fs.writeFileSync(scratch, JSON.stringify(out));
    fs.renameSync(scratch, STORE_FILE);
  } catch { /* an unwritable store never takes the wall down */ }
}

function persist() {
  if (writePending) return;
  writePending = true;
  const timer = setTimeout(writeNow, WRITE_DEBOUNCE_MS);
  timer.unref?.();
}

// `at` is the reporter's own clock and seeds first_seen; last_seen and pruning
// run off this machine's, so a skewed client can neither make its entry
// immortal nor sweep the board clean on arrival.
function entryFor(id, at) {
  load();
  let entry = store.get(id);
  if (!entry) { entry = blank(at); store.set(id, entry); }
  entry.last_seen = Math.floor(Date.now() / 1000);
  return entry;
}

// --- the three channels -------------------------------------------------------

function ingestStage(report) {
  const id = str(report.run);
  if (!id) return;
  const at = epoch(report.at);
  const entry = entryFor(id, at);
  if (at >= entry.stage.at) {
    entry.stage = { text: str(report.stage), at };
    // An empty field never overwrites what an earlier report established: the
    // stage reports sent before the PR exists must not blank a later pr_url.
    for (const key of META) {
      const value = str(report[key]);
      if (value) entry[key] = value;
    }
  }
  prune(Math.floor(Date.now() / 1000));
  persist();
}

function ingestHook(event) {
  const id = str(event.run);
  if (!id) return;
  const at = epoch(event.at);
  const entry = entryFor(id, at);
  const hooks = entry.hooks;
  if (!entry.host) entry.host = str(event.host);
  const session = str(event.session_id);
  if (session && !hooks.sessions.includes(session)) {
    hooks.sessions.push(session);
    if (hooks.sessions.length > MAX_SESSIONS) hooks.sessions.shift();
  }
  switch (str(event.hook_event_name)) {
    case 'PostToolUse':
      hooks.tools += 1;
      if (at >= hooks.last_tool_at) {
        hooks.last_tool = str(event.tool_name);
        hooks.last_tool_at = at;
      }
      break;
    case 'Stop':
      hooks.stops += 1;
      break;
    case 'SessionEnd':
      hooks.ended = str(event.reason);
      break;
    default:
      break;
  }
  hooks.last_at = Math.max(hooks.last_at, at);
  prune(Math.floor(Date.now() / 1000));
  persist();
}

// --- OTLP/HTTP JSON -----------------------------------------------------------

function attrsOf(list) {
  const out = {};
  if (!Array.isArray(list)) return out;
  for (const attr of list) {
    if (!attr || typeof attr !== 'object') continue;
    const key = typeof attr.key === 'string' ? attr.key : '';
    if (!key || PII.has(key)) continue;
    const value = attr.value && typeof attr.value === 'object' ? attr.value : {};
    if (typeof value.stringValue === 'string') out[key] = value.stringValue.slice(0, CLIP);
    else if (typeof value.intValue === 'string' || typeof value.intValue === 'number') {
      out[key] = String(value.intValue).slice(0, CLIP);
    } else if (typeof value.doubleValue === 'number') out[key] = String(value.doubleValue);
    else if (typeof value.boolValue === 'boolean') out[key] = String(value.boolValue);
  }
  return out;
}

function numberOf(point) {
  if (typeof point.asDouble === 'number') return point.asDouble;
  if (point.asInt !== undefined) {
    const n = Number(point.asInt);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function pointsOf(metric) {
  for (const shape of ['sum', 'gauge']) {
    const body = metric[shape];
    if (body && Array.isArray(body.dataPoints)) return body.dataPoints;
  }
  return [];
}

// The CLI exports cumulative sums, so a later export of the same session repeats
// the running total rather than the delta. Keeping the LATEST value per
// (session, series) and summing those is what makes re-sending a body a no-op
// while a second session is still an addition.
// One series' running total, replacing whatever the same series reported last.
// The key exists only to be unique; nothing ever parses it back apart.
function remember(entry, kind, session, model, field, value, at) {
  const key = [kind, session, model, field].join('|');
  const previous = entry.otel.latest[key];
  if (previous && !newerNano(at, previous.at)) return;
  entry.otel.latest[key] = { kind, field, value, at };
}

function recompute(entry) {
  const otel = entry.otel;
  const tokens = { input: 0, output: 0, cache_read: 0, cache_creation: 0 };
  let cost = 0;
  let sessions = 0;
  for (const key of Object.keys(otel.latest)) {
    const seen = otel.latest[key];
    if (seen.kind === 'token') {
      if (seen.field in tokens) tokens[seen.field] += seen.value;
    } else if (seen.kind === 'cost') cost += seen.value;
    else if (seen.kind === 'session') sessions += seen.value;
  }
  otel.tokens = tokens;
  otel.cost_usd = cost;
  otel.sessions = sessions;
}

function ingestMetrics(body) {
  const resourceMetrics = Array.isArray(body.resourceMetrics) ? body.resourceMetrics : [];
  const touched = new Set();
  const now = Math.floor(Date.now() / 1000);
  for (const rm of resourceMetrics) {
    if (!rm || typeof rm !== 'object') continue;
    const resource = rm.resource && typeof rm.resource === 'object' ? rm.resource : {};
    const runId = str(attrsOf(resource.attributes)['run.id']);
    if (!runId) continue;   // a metric with no run is not this wall's business
    const entry = entryFor(runId, now);
    touched.add(entry);
    const scopes = Array.isArray(rm.scopeMetrics) ? rm.scopeMetrics : [];
    for (const scope of scopes) {
      const metrics = scope && Array.isArray(scope.metrics) ? scope.metrics : [];
      for (const metric of metrics) {
        if (!metric || typeof metric !== 'object') continue;
        const name = typeof metric.name === 'string' ? metric.name : '';
        for (const point of pointsOf(metric)) {
          if (!point || typeof point !== 'object') continue;
          const value = numberOf(point);
          if (value === null) continue;
          const attrs = attrsOf(point.attributes);
          const session = attrs['session.id'] || '';
          const model = attrs.model || '';
          const at = nano(point.timeUnixNano);
          if (model && !entry.otel.models.includes(model)) entry.otel.models.push(model);
          if (name === 'claude_code.token.usage') {
            const field = TOKEN_KEY[attrs.type];
            if (!field) continue;
            remember(entry, 'token', session, model, field, value, at);
          } else if (name === 'claude_code.cost.usage') {
            remember(entry, 'cost', session, model, 'usd', value, at);
          } else if (name === 'claude_code.session.count') {
            remember(entry, 'session', session, model, 'count', value, at);
          }
        }
      }
    }
    entry.otel.last_at = now;
  }
  if (!touched.size) return;
  for (const entry of touched) recompute(entry);
  prune(now);
  persist();
}

// --- what the snapshot asks for -----------------------------------------------

// Nothing is read back on a wall that was never given a token, so a store file
// left over from an earlier configuration cannot put rows on a read-only wall.
function telemetryFor(id) {
  if (!enabled()) return null;
  if (load() || prune(Math.floor(Date.now() / 1000))) persist();
  const entry = store.get(id);
  if (!entry) return null;
  const otel = entry.otel;
  return {
    host: entry.host,
    tokens_in: otel.tokens.input,
    tokens_out: otel.tokens.output,
    cache_read: otel.tokens.cache_read,
    cost_usd: otel.cost_usd,
    tools: entry.hooks.tools,
    last_tool: entry.hooks.last_tool,
    last_event_at: Math.max(entry.hooks.last_at, otel.last_at, entry.stage.at),
    sessions: otel.sessions || entry.hooks.sessions.length,
  };
}

// Every reported run with no run dir on this machine. The caller turns each one
// into a row, because the stage vocabulary that decides its actor and state
// lives in server.js and there may only be one copy of it.
function remoteEntries(localIds) {
  if (!enabled()) return [];
  if (load() || prune(Math.floor(Date.now() / 1000))) persist();
  const out = [];
  for (const [id, entry] of store) if (!localIds.has(id)) out.push({ id, entry });
  return out;
}

// --- the routes ---------------------------------------------------------------

function handles(pathname) {
  return ROUTES.has(pathname);
}

function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'text/plain; charset=utf-8' });
  res.end(body === undefined ? '' : body);
}

function authorised(req) {
  return (req.headers.authorization || '') === 'Bearer ' + TOKEN;
}

// The oversized body is drained rather than the socket destroyed: the reporter
// has to read the 413 to learn to stop, and a connection killed mid-upload
// reaches it as a transport error instead.
function readBody(req, done) {
  let size = 0;
  let over = false;
  let settled = false;
  const chunks = [];
  const settle = (err, text) => { if (!settled) { settled = true; done(err, text); } };
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_BODY) { over = true; chunks.length = 0; return; }
    chunks.push(chunk);
  });
  req.on('end', () => settle(over ? 'too-large' : null, Buffer.concat(chunks).toString('utf8')));
  req.on('error', () => settle('aborted', ''));
  req.on('aborted', () => settle('aborted', ''));
}

// The Linear webhook's whole auth. Linear signs the raw body with the shared
// secret; a delivery that fails any check is answered here, explicitly, so no
// rejection can ever fall through to the catch-below as a 204. Returns
// { code } to answer, or { payload } for a genuine delivery.
function verifyLinear(req, body) {
  const sig = req.headers['linear-signature'];
  // timingSafeEqual throws on unequal lengths, and Buffer.from never rejects
  // bad hex — the shape is pinned before either is called.
  if (typeof sig !== 'string' || !/^[0-9a-f]{64}$/.test(sig)) return { code: 401 };
  const mac = crypto.createHmac('sha256', LINEAR_SECRET).update(body, 'utf8').digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(mac, 'hex'), Buffer.from(sig, 'hex'))) {
    return { code: 401 };
  }
  let payload;
  try { payload = JSON.parse(body); } catch { return { code: 400 }; }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { code: 400 };
  }
  // Only past the HMAC: a forged body must not influence anything, including
  // the log line.
  const at = payload.webhookTimestamp;
  if (typeof at !== 'number' || !Number.isFinite(at) ||
      Math.abs(Date.now() - at) > LINEAR_WINDOW_MS) return { code: 401 };
  return { payload };
}

// One POST. Always answers the request itself; the caller only reaches it for a
// path handles() claimed.
function handle(req, res, pathname) {
  // The Linear webhook is the one route with no bearer: Linear cannot send our
  // token, so its signature is the auth. Its size check also has to come before
  // its signature check (the signature needs the body in hand), so it branches
  // out ahead of the enabled/authorised order the report routes keep.
  if (pathname === '/webhooks/linear' || pathname === '/webhooks/linear/') {
    if (LINEAR_SECRET === '') return send(res, 404, 'wall: no such page\n');
    return readBody(req, (err, text) => {
      if (err === 'too-large') return send(res, 413, 'wall: report too large\n');
      if (err) return undefined;   // the client hung up; there is nobody to answer
      const verdict = verifyLinear(req, text);
      if (verdict.code) {
        return send(res, verdict.code, verdict.code === 400 ? 'wall: bad JSON\n' : '');
      }
      try {
        console.log('[wall] linear webhook: ' + (str(verdict.payload.type) || '?') +
          ' ' + (str(verdict.payload.action) || '?'));
        return send(res, 200, '{}', 'application/json; charset=utf-8');
      } catch {
        return send(res, 204);
      }
    });
  }
  if (!enabled()) return send(res, 404, 'wall: no such page\n');
  if (!authorised(req)) return send(res, 401, 'wall: unauthorised\n');
  return readBody(req, (err, text) => {
    if (err === 'too-large') return send(res, 413, 'wall: report too large\n');
    if (err) return undefined;   // the client hung up; there is nobody to answer
    let body;
    try { body = JSON.parse(text); } catch { return send(res, 400, 'wall: bad JSON\n'); }
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return send(res, 400, 'wall: bad JSON\n');
    }
    // /v1/logs and /v1/traces are accepted and discarded: a misconfigured
    // exporter should stop retrying rather than fill a run's stderr with 404s.
    if (pathname === '/v1/logs' || pathname === '/v1/traces') {
      return send(res, 200, '{}', 'application/json; charset=utf-8');
    }
    try {
      if (pathname === '/api/ingest/stage') { ingestStage(body); return send(res, 204); }
      if (pathname === '/api/ingest/hook') { ingestHook(body); return send(res, 204); }
      ingestMetrics(body);
      return send(res, 200, '{}', 'application/json; charset=utf-8');
    } catch {
      // Read what is there, never throw — the inbound half of the same rule.
      return send(res, 204);
    }
  });
}

module.exports = {
  handles, handle, enabled, telemetryFor, remoteEntries,
  STORE_FILE, MAX_BODY, PRUNE_S, PII,
  // The suites drive the store directly for the aggregation rules: those are
  // arithmetic over a body, and staging a socket per case says nothing extra.
  ingestStage, ingestHook, ingestMetrics, writeNow,
};
