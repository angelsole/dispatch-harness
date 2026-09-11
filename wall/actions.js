'use strict';
// Local, authenticated control adapter. Monitoring/ingest credentials never
// authorize execution. Only fixed Python operations receive structured input.
const crypto = require('node:crypto');
const path = require('node:path');
const { spawn } = require('node:child_process');

function create({ enabled, host, runs, runtime }) {
  if (enabled && (host !== '127.0.0.1' || path.resolve(runs) !== path.resolve(runtime, 'runs'))) {
    throw new Error('console control requires 127.0.0.1 and the execution installation’s runs directory');
  }
  const token = enabled ? crypto.randomBytes(32).toString('hex') : '';
  let active = 0;
  function json(res, code, value) {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
      'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff' });
    res.end(JSON.stringify(value));
  }
  function bridge(operation, body, res) {
    if (active >= 4) return json(res, 429, { error: 'Console is busy. Try again shortly.' });
    active += 1;
    const env = { ...process.env, HARNESS_DIR: runtime };
    // These describe this web server, not the resumed task or its test servers.
    for (const key of ['WALL_CONTROL', 'WALL_HOST', 'WALL_PORT', 'WALL_RUNS']) delete env[key];
    const child = spawn('python3', [path.join(__dirname, '../lib/dispatch_actions.py'), operation], {
      env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    let output = '', finished = false;
    const finish = (code, value) => {
      if (finished) return;
      finished = true;
      active -= 1;
      clearTimeout(timer);
      json(res, code, value);
    };
    // A detached recovery retains its own lock. A browser disconnect does not
    // cancel the accepted action; its durable receipt answers a retry.
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      finish(504, { error: 'The request timed out. Refresh the task before retrying.' });
    }, 45000);
    child.on('error', () => finish(503, { error: 'Could not start the Dispatch service. Check Python is installed.' }));
    child.stdout.on('data', (data) => {
      output += data;
      if (Buffer.byteLength(output) > 16 * 1024 * 1024) {
        child.kill('SIGTERM');
        finish(503, { error: 'The run listing is too large. Use Dispatch from the terminal.' });
      }
    });
    child.stderr.resume(); // Internal commands/credentials never enter HTTP errors.
    child.stdin.on('error', () => {});
    child.on('close', (code) => {
      let value;
      try { value = JSON.parse(output); }
      catch { return finish(503, { error: 'Dispatch could not read this run. Refresh and try again.' }); }
      finish(code === 0 ? 200 : 409, value);
    });
    child.stdin.end(JSON.stringify(body));
  }
  function handles(url) { return url.startsWith('/api/control/'); }
  function handle(req, res, url) {
    if (!enabled) return json(res, 404, { error: 'Run dispatch ui on this machine to open the local control console.' });
    const origin = 'http://127.0.0.1:' + req.socket.localPort;
    const local = req.socket.remoteAddress === '127.0.0.1' || req.socket.remoteAddress === '::ffff:127.0.0.1';
    const supplied = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
    const expected = Buffer.from(token);
    if (!local || req.headers.host !== origin.slice(7) || supplied.length !== expected.length ||
        !crypto.timingSafeEqual(supplied, expected)) {
      return json(res, 401, { error: 'Open the private console link printed by dispatch ui.' });
    }
    if ((req.headers.origin && req.headers.origin !== origin) ||
        (req.headers['sec-fetch-site'] && req.headers['sec-fetch-site'] !== 'same-origin') ||
        (req.method === 'POST' && req.headers.origin !== origin)) {
      return json(res, 403, { error: 'Console actions must come from this console.' });
    }
    if (url === '/api/control/runs' && req.method === 'GET') return bridge('list', {}, res);
    if (url !== '/api/control/actions' || req.method !== 'POST') {
      return json(res, 405, { error: 'Unsupported console operation.' });
    }
    if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || '')) {
      return json(res, 415, { error: 'Expected a JSON action.' });
    }
    let size = 0, chunks = [], rejected = false;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 65536) {
        if (!rejected) json(res, 413, { error: 'The answer is too large.' });
        rejected = true; chunks = [];
      } else if (!rejected) chunks.push(chunk);
    });
    req.on('end', () => {
      if (rejected) return;
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString()); }
      catch { return json(res, 400, { error: 'Invalid action JSON.' }); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        return json(res, 400, { error: 'Expected an action object.' });
      }
      bridge('apply', body, res);
    });
  }
  return { handles, handle, enabled, url: (port) => `http://127.0.0.1:${port}/console#control=${token}` };
}

module.exports = { create };
