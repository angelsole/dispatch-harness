'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { create } = require('../wall/actions.js');

test('local HTTP actions require a private token, correct host and same origin', async (t) => {
  const inheritedControl = process.env.WALL_CONTROL;
  const inheritedToken = process.env.GH_TOKEN;
  process.env.WALL_CONTROL = '1';
  process.env.GH_TOKEN = 'other-terminal-fixture';
  t.after(() => {
    if (inheritedControl === undefined) delete process.env.WALL_CONTROL;
    else process.env.WALL_CONTROL = inheritedControl;
    if (inheritedToken === undefined) delete process.env.GH_TOKEN;
    else process.env.GH_TOKEN = inheritedToken;
  });
  const runtime = fs.mkdtempSync(path.join(os.tmpdir(), 'console-http-'));
  const directory = path.join(runtime, 'runs/TASK-1');
  fs.mkdirSync(directory, { recursive: true });
  const write = (name, value) => fs.writeFileSync(path.join(directory, name), JSON.stringify(value));
  write('request.json', { version: 1, id: 'TASK-1', repo: runtime, branch: 'task', account: '',
    operator: os.userInfo().username, host: os.hostname(), publish: false });
  write('result.json', { status: 'needs_input' });
  write('checkpoint.json', { stage: 'gated' });
  fs.writeFileSync(path.join(directory, 'brief.md'), '# Checkout\nKeep these requirements.\n');
  fs.writeFileSync(path.join(directory, 'QUESTIONS.md'), 'Allow guests?');
  fs.writeFileSync(path.join(runtime, 'repos.conf.sh'), 'repo_config() { IMPLEMENTER_PROVIDER=zai; }\n');
  fs.writeFileSync(path.join(runtime, 'run-task.sh'),
    'printf "%s\\n" "${WALL_CONTROL:-unset}" > "$HARNESS_DIR/server-flags"\n' +
    'printf "%s\\n" "${GH_TOKEN:-unset}" > "$HARNESS_DIR/ambient-credentials"\n' +
    'printf "start\\n" >> "$HARNESS_DIR/starts"\n');
  const control = create({ enabled: true, host: '127.0.0.1', runs: path.join(runtime, 'runs'), runtime });
  const server = http.createServer((req, res) => control.handle(req, res, req.url));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(runtime, { recursive: true, force: true });
  });
  const url = new URL(control.url(server.address().port));
  const origin = url.origin;
  const token = new URLSearchParams(url.hash.slice(1)).get('control');
  const headers = { Authorization: 'Bearer ' + token, Origin: origin, 'Content-Type': 'application/json' };
  const call = (route, init = {}) => fetch(origin + route, { headers, ...init });
  assert.equal((await call('/api/control/runs', { headers: {} })).status, 401);
  // fetch may rewrite Host; exercise DNS-rebinding protection on the wire.
  const wrongHost = await new Promise((resolve, reject) => {
    const request = http.get(origin + '/api/control/runs', { headers: { ...headers, Host: 'attacker.test' } }, (response) => {
      response.resume();
      resolve(response.statusCode);
    });
    request.on('error', reject);
  });
  assert.equal(wrongHost, 401);
  assert.equal((await call('/api/control/runs', { headers: { ...headers, Origin: 'https://attacker.test' } })).status, 403);
  assert.equal((await call('/api/control/actions', { method: 'POST', headers: { Authorization: 'Bearer ' + token } })).status, 403);
  assert.equal((await call('/api/control/actions', { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain' } })).status, 415);
  assert.equal((await call('/api/control/actions', { method: 'POST', body: '{' })).status, 400);
  assert.equal((await call('/api/control/actions', { method: 'POST', body: '[]' })).status, 400);
  assert.equal((await call('/api/control/actions', { method: 'POST', body: 'x'.repeat(65537) })).status, 413);
  assert.equal((await call('/api/control/actions')).status, 405);
  assert.equal((await call('/api/control/anything')).status, 405);
  const response = await call('/api/control/runs');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const task = (await response.json()).tasks[0];
  assert.equal(task.questions, 'Allow guests?');
  assert.equal(task.actions[0].id, 'answer_resume');
  const body = { id: task.id, action: 'answer_resume', revision: task.revision,
    operation_id: 'b'.repeat(32), answer: 'Yes, preserve guest checkout.' };
  const first = await call('/api/control/actions', { method: 'POST', body: JSON.stringify(body) });
  assert.equal(first.status, 200);
  const accepted = await first.json();
  assert.equal(accepted.state, 'running', accepted.message);
  const replay = await call('/api/control/actions', { method: 'POST', body: JSON.stringify(body) });
  assert.deepEqual(await replay.json(), accepted);
  assert.equal(fs.readFileSync(path.join(directory, 'brief.md'), 'utf8').split(body.answer).length, 2);
  for (let n = 0; n < 50 && !fs.existsSync(path.join(runtime, 'starts')); n++) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.equal(fs.readFileSync(path.join(runtime, 'starts'), 'utf8'), 'start\n');
  assert.equal(fs.readFileSync(path.join(runtime, 'server-flags'), 'utf8'), 'unset\n');
  assert.equal(fs.readFileSync(path.join(runtime, 'ambient-credentials'), 'utf8'), 'unset\n');
});

test('monitoring wall cannot enable actions on shared interfaces or unrelated runs', () => {
  assert.throws(() => create({ enabled: true, host: '0.0.0.0', runs: '/tmp/runs', runtime: '/tmp' }));
  assert.throws(() => create({ enabled: true, host: '127.0.0.1', runs: '/tmp/mirror/runs', runtime: '/tmp' }));
  const control = create({ enabled: false, host: '0.0.0.0', runs: '/tmp/mirror', runtime: '/tmp' });
  let status;
  control.handle({}, { writeHead: (code) => { status = code; }, end: () => {} }, '/api/control/actions');
  assert.equal(status, 404);
});
