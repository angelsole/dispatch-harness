'use strict';
// Signed Linear events enter here only after ingest.js verifies the delivery.
// Python acknowledges each event after committing it to SQLite; execution and
// Linear API calls happen off the HTTP request, and survive a wall restart.
const { spawn } = require('node:child_process');
const path = require('node:path');
const crypto = require('node:crypto');

function create(options = {}) {
  const config = options.config || process.env.WALL_LINEAR_DISPATCH_CONFIG;
  const enabled = Boolean(config && process.env.WALL_LINEAR_WEBHOOK_SECRET &&
    process.env.WALL_CONTROL !== '1');
  const pending = new Map();
  let child, retry, stopped = false;
  function start() {
    if (!enabled || child || stopped) return;
    const runtime = options.runtime || process.env.HARNESS_DIR ||
      path.join(process.env.HOME || '.', '.claude/harness');
    child = spawn('python3', [path.join(__dirname, '../lib/linear_dispatch.py'),
      'serve', '--runtime', runtime, '--config', config], {
      stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, PYTHONUNBUFFERED: '1' },
    });
    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 65536) { child.kill(); return; }
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        try {
          const reply = JSON.parse(line), resolve = pending.get(reply.id);
          if (resolve) resolve(reply.code);
        } catch { /* A broken worker cannot acknowledge an event. */ }
      }
    });
    // Never relay payloads, credentials, or worker tracebacks over HTTP.
    child.stderr.on('data', () => {});
    child.stdin.on('error', () => {});
    child.on('error', () => {});
    child.on('close', () => {
      child = undefined;
      for (const resolve of pending.values()) resolve(503);
      if (!stopped) {
        console.error('[wall] Linear dispatcher unavailable; retrying in 5 seconds. Check its configuration.');
        retry = setTimeout(start, 5000);
      }
    });
  }
  function receive(payload) {
    if (!enabled) return Promise.resolve(200);
    start();
    if (pending.size >= 100) return Promise.resolve(503);
    return new Promise(resolve => {
      const id = crypto.randomUUID();
      const timer = setTimeout(() => finish(503), 3500);
      const finish = code => {
        clearTimeout(timer); pending.delete(id); resolve(code);
      };
      pending.set(id, finish);
      try { child.stdin.write(JSON.stringify({ id, payload }) + '\n'); }
      catch { finish(503); }
    });
  }
  function close() {
    stopped = true; clearTimeout(retry);
    for (const resolve of pending.values()) resolve(503);
    if (child) child.kill();
  }
  return { enabled, start, receive, close };
}
module.exports = { create };
