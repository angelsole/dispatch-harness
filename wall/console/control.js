'use strict';
// Task controls are separate from the ambient/read-only monitoring transport.
(function () {
  let token = '';
  try {
    const supplied = new URLSearchParams(location.hash.slice(1)).get('control');
    if (supplied) {
      token = supplied;
      history.replaceState(null, '', location.pathname + location.search);
      sessionStorage.setItem('dispatch-control', token);
    } else token = sessionStorage.getItem('dispatch-control') || '';
  } catch { /* Session storage may be disabled; a supplied token still works. */ }
  let tasks = new Map(), listener = () => {}, polling = false, connected = false;
  const panels = new Map();
  const access = document.getElementById('console-access');

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text) node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  async function request(url, body) {
    const response = await fetch(url, {
      method: body ? 'POST' : 'GET', cache: 'no-store',
      headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const value = await response.json();
    if (!response.ok) throw new Error(value.error || 'The console request failed.');
    return value;
  }

  async function refresh() {
    if (!token || polling) return;
    polling = true;
    try {
      const result = await request('/api/control/runs');
      if (!Array.isArray(result.tasks)) throw new Error('Could not read the current tasks.');
      tasks = new Map(result.tasks.map((task) => [task.id, task]));
      connected = true;
      access.textContent = 'Local recovery controls · saved task accounts';
      for (const [id, panel] of panels) update(panel, tasks.get(id));
      listener();
    } catch (error) {
      connected = false;
      access.textContent = error.message + ' Your unsent answers are still here.';
      for (const panel of panels.values()) update(panel, tasks.get(panel.runId));
    } finally { polling = false; }
  }

  function update(panel, task) {
    if (!task) {
      panel.message.textContent = 'This task is unavailable. Refresh before taking action.';
      panel.submit.disabled = true;
      return;
    }
    panel.latest = task;
    if (!panel.task || (!panel.input.value && !panel.pending && !panel.retryBody)) panel.task = task;
    const shown = panel.task;
    const stale = shown.revision !== task.revision || shown.state !== task.state;
    panel.context.textContent = 'Account: ' + task.account + ' · Machine: ' + task.host;
    panel.checkpoint.textContent = task.checkpoint.description;
    panel.reason.textContent = task.reason || task.disabled_reason;
    panel.question.textContent = shown.questions;
    panel.answer.hidden = !shown.questions;
    const action = shown.actions[0];
    panel.submit.hidden = !action;
    panel.submit.textContent = panel.pending ? 'Saving…' : panel.retryBody ? 'Check submitted action' : action ? action.label : '';
    panel.submit.disabled = !connected || panel.pending || (stale && !panel.retryBody) ||
      (!panel.retryBody && action && action.id === 'answer_resume' && !panel.input.value.trim());
    // An unresolved receipt refers to the submitted answer. Keep that answer
    // fixed until its outcome is known or the operator refreshes the details.
    panel.input.disabled = panel.pending || !!panel.retryBody;
    panel.reload.hidden = (!stale && !panel.retryBody) || panel.pending;
    panel.stale.textContent = stale ? 'This task changed. Refresh the details and review the question before submitting.' : '';
    panel.login.hidden = !task.login;
    panel.loginCode.textContent = task.login ? task.login.map(shellQuote).join(' ') : '';
  }

  function shellQuote(value) { return "'" + String(value).replace(/'/g, "'\"'\"'") + "'"; }

  function mount(id) {
    if (panels.has(id)) return panels.get(id);
    const panel = element('section', '', 'control-panel');
    panel.runId = id;
    panel.context = element('p', '', 'control-context');
    panel.reason = element('p', '', 'control-reason');
    panel.checkpoint = element('p', '', 'checkpoint');
    panel.answer = element('div', '', 'answer');
    panel.question = element('pre', '', 'question');
    panel.input = element('textarea');
    panel.input.id = 'answer-' + id;
    panel.input.rows = 4;
    panel.input.maxLength = 16000;
    panel.input.placeholder = 'Record the decision the worker needs to continue…';
    const label = element('label', 'Your answer');
    label.htmlFor = panel.input.id;
    panel.answer.append(element('h3', 'Question from this run'), panel.question, label, panel.input,
      element('p', 'Your answer is saved to the task brief before recovery starts.', 'answer-help'));
    panel.submit = element('button', 'Resume run', 'control-primary');
    panel.submit.type = 'button';
    panel.reload = element('button', 'Refresh details', 'control-secondary');
    panel.reload.type = 'button';
    panel.stale = element('p', '', 'control-stale');
    panel.message = element('p', '', 'control-message');
    panel.message.setAttribute('role', 'status');
    panel.message.setAttribute('aria-live', 'polite');
    panel.login = element('div', '', 'login-handoff');
    panel.loginCode = element('code');
    const copy = element('button', 'Copy sign-in command', 'control-secondary');
    copy.type = 'button';
    copy.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(panel.loginCode.textContent); copy.textContent = 'Copied'; }
      catch { panel.message.textContent = 'Select and copy the sign-in command below.'; }
    });
    panel.login.append(element('p', 'Sign in with the saved account in your terminal, then retry recovery.'),
      panel.loginCode, copy);
    const buttons = element('div', '', 'control-buttons');
    buttons.append(panel.submit, panel.reload);
    panel.append(panel.context, panel.reason, panel.checkpoint, panel.answer, panel.login,
      panel.stale, buttons, panel.message);
    panel.input.addEventListener('input', () => update(panel, panel.latest));
    panel.reload.addEventListener('click', () => {
      panel.task = panel.latest;
      panel.retryBody = null;
      update(panel, panel.latest);
    });
    panel.submit.addEventListener('click', async () => {
      if (panel.submit.disabled) return;
      const task = panel.task;
      // A network retry reuses the SAME operation and answer, including when
      // the first response was lost after Dispatch already saved the decision.
      const body = panel.retryBody || {
        id, action: task.actions[0].id, revision: task.revision,
        operation_id: crypto.randomUUID().replace(/-/g, ''),
        ...(task.actions[0].id === 'answer_resume' ? { answer: panel.input.value } : {}),
      };
      panel.pending = true;
      panel.retryBody = body;
      update(panel, panel.latest);
      try {
        const result = await request('/api/control/actions', body);
        panel.message.textContent = result.message;
        // An intent receipt can survive an interrupted service before it has
        // confirmed the save/launch. Keep the draft until there is an outcome.
        if (result.state !== 'accepted') panel.retryBody = null;
        if (!['failed', 'accepted'].includes(result.state) || result.answer_saved) panel.input.value = '';
      } catch (error) {
        panel.message.textContent = error.message + ' Your answer has been kept. Check the submitted action or refresh details.';
      } finally {
        panel.pending = false;
        update(panel, panel.latest);
        refresh();
      }
    });
    panels.set(id, panel);
    update(panel, tasks.get(id));
    return panel;
  }

  function decorate(runs) {
    const ids = new Set();
    const result = runs.map((run) => {
      if (run.remote) return run;
      ids.add(run.id);
      return merge(run, tasks.get(run.id));
    });
    for (const [id, task] of tasks) {
      // Keep the wall's bounded history. Add saved blockers that have no wall
      // stage yet, without flooding the board with every archived directory.
      if (!ids.has(id) && (task.actions.length > 0 || task.state === 'running')) result.push(merge({ id, projectLabel: task.repo.split('/').pop() || '—',
        actorKey: 'unknown', actor: '', feed: [] }, task));
    }
    return result;
  }

  function merge(run, task) {
    if (!task) return run;
    const attention = task.state === 'needs_input' || task.state === 'waiting_for_auth' ||
      task.state === 'blocked' || task.actions.length > 0;
    const state = task.state === 'running' || task.state === 'deferred_capacity' ? 'active' :
      attention ? 'alarm' : task.state.startsWith('ready') ? 'ready' : 'failed';
    return { ...run, state, title: task.title, host: task.host, owner: task.account,
      stage: task.state === 'running' ? task.stage : task.state.replace(/_/g, ' '),
      prUrl: task.pr_url || run.prUrl, outcome: task.state,
      actorKey: state === 'alarm' ? 'alarm' : run.actorKey,
      blocked: task.reason || task.disabled_reason || run.blocked || run.reason,
      controlRevision: task.revision };
  }

  window.DispatchControl = { enabled: !!token, mount, decorate, subscribe: (fn) => { listener = fn; } };
  if (token) {
    document.getElementById('console-mode').textContent = 'Local recovery controls. ';
    access.textContent = 'Connecting local recovery controls…';
    refresh();
    setInterval(refresh, 4000);
  } else {
    access.textContent = 'Monitoring only. Run dispatch ui on the execution machine for recovery controls.';
  }
}());
