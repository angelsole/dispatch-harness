'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');

// A small DOM fixture tests form behavior without a browser dependency.
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.events = {}; this.value = ''; }
  append(...children) { this.children.push(...children); }
  setAttribute(key, value) { this[key] = value; }
  addEventListener(event, handler) { this.events[event] = handler; }
}
const settle = () => new Promise((resolve) => setImmediate(resolve));

test('live updates preserve drafts; stale tabs cannot submit; lost responses reuse the receipt ID', async () => {
  const nodes = { 'console-access': new Element('p'), 'console-mode': new Element('span') };
  const intervals = [], requests = [];
  let tasks = [{ id: 'TASK-1', revision: 'one', state: 'needs_input', account: 'alice', host: 'local', repo: '/app',
    questions: 'Allow guests?', actions: [{ id: 'answer_resume', label: 'Save answer and resume' }],
    checkpoint: { description: 'Checks saved.' }, reason: '', disabled_reason: '' }];
  let loseResponse = false, responseState = 'running';
  const context = {
    document: { getElementById: (id) => nodes[id], createElement: (tag) => new Element(tag) },
    window: {}, location: { hash: '#control=private', pathname: '/console', search: '' },
    history: { replaceState() {} }, sessionStorage: { setItem() {}, getItem() {} }, URLSearchParams,
    crypto, setInterval: (fn) => intervals.push(fn), navigator: {},
    fetch: async (url, options) => {
      if (!options.body) return { ok: true, json: async () => ({ tasks }) };
      requests.push(JSON.parse(options.body));
      if (loseResponse) { loseResponse = false; throw new Error('Connection lost'); }
      return { ok: true, json: async () => ({ state: responseState, message: 'Request recorded.' }) };
    },
  };
  vm.runInNewContext(fs.readFileSync(require.resolve('../wall/console/control.js'), 'utf8'), context);
  await settle();
  const panel = context.window.DispatchControl.mount('TASK-1');
  assert.equal(panel.submit.disabled, true);
  panel.input.value = 'Keep guest checkout.';
  panel.input.events.input();
  assert.equal(panel.submit.disabled, false);
  const input = panel.input;
  await intervals[0]();
  assert.equal(panel.input, input);
  assert.equal(panel.input.value, 'Keep guest checkout.');
  tasks = [{ ...tasks[0], revision: 'two', questions: 'Allow guest purchases without an email?' }];
  await intervals[0]();
  assert.equal(panel.input.value, 'Keep guest checkout.');
  assert.equal(panel.question.textContent, 'Allow guests?');
  assert.equal(panel.submit.disabled, true);
  panel.reload.events.click();
  assert.equal(panel.question.textContent, tasks[0].questions);
  assert.equal(panel.submit.disabled, false);
  loseResponse = true;
  await panel.submit.events.click();
  await settle();
  assert.equal(panel.input.value, 'Keep guest checkout.');
  assert.ok(panel.retryBody);
  assert.equal(panel.input.disabled, true);
  await panel.submit.events.click();
  await settle();
  assert.deepEqual(requests[1], requests[0]);
  assert.equal(requests[0].revision, 'two');
  assert.equal(panel.input.value, '');
  assert.equal(panel.retryBody, null);
  assert.equal(panel.input.disabled, false);
  // A service interrupted after recording intent must not discard the draft.
  responseState = 'accepted';
  panel.input.value = 'Keep this decision until its outcome is known.';
  panel.input.events.input();
  await panel.submit.events.click();
  await settle();
  assert.equal(panel.input.value, 'Keep this decision until its outcome is known.');
  assert.ok(panel.retryBody);
  assert.equal(panel.reload.hidden, false);
  panel.reload.events.click();
  assert.equal(panel.retryBody, null);
  assert.equal(panel.input.disabled, false);
  tasks.push({ ...tasks[0], id: 'OLD-READY', state: 'ready', actions: [] },
    { ...tasks[0], id: 'OLD-EMPTY', state: 'prepared', actions: [] },
    { ...tasks[0], id: 'NEW-SAVED', state: 'prepared', actions: [{ id: 'resume', label: 'Resume run' }] });
  await intervals[0]();
  const board = context.window.DispatchControl.decorate([]);
  assert.equal(board.map((task) => task.id).join(','), 'TASK-1,NEW-SAVED');
  assert.equal(board.find((task) => task.id === 'NEW-SAVED').state, 'alarm');
});

test('the monitoring page does not request privileged data without a private link', () => {
  let requests = 0;
  const context = { window: {}, document: { getElementById: () => new Element('p') },
    location: { hash: '' }, sessionStorage: { getItem: () => '' }, URLSearchParams,
    fetch: () => { requests += 1; }, setInterval: () => {} };
  vm.runInNewContext(fs.readFileSync(require.resolve('../wall/console/control.js'), 'utf8'), context);
  assert.equal(context.window.DispatchControl.enabled, false);
  assert.equal(requests, 0);
});
