'use strict';
// Stage the wall's fixture runs: five run dirs shaped exactly as run-task.sh
// writes them (active implement, active review, needs_input, done: ready,
// done: rejected), with timestamps relative to now.
//
// The generated runs/ directory is committed, so `wall.sh --runs
// wall/fixtures/runs` and the demo storyboard work straight out of a clone.
// Re-run this to make the elapsed times read fresh again — it rewrites tracked
// files, so commit or discard the result. tests/wall.test.sh seeds its own copy
// into a temp dir instead of touching the repo.
//
// Usage: node wall/fixtures/seed.js [TARGET-DIR]   (default: ./runs beside this)

const fs = require('node:fs');
const path = require('node:path');

const DEST = process.argv[2] || path.join(__dirname, 'runs');
const NOW = Math.floor(Date.now() / 1000);

const at = (ago) => String(NOW - ago);                                   // epoch, N seconds ago
const clk = (ago) => new Date((NOW - ago) * 1000).toTimeString().slice(0, 8); // local HH:MM:SS

function write(id, name, body) {
  fs.writeFileSync(path.join(DEST, id, name), body.endsWith('\n') ? body : body + '\n');
}

// The files every run dir has, whatever stage it is in.
function run({ id, stageAge, totalAge, stage, activity, title }) {
  fs.mkdirSync(path.join(DEST, id), { recursive: true });
  write(id, 'status', `${at(stageAge)} ${stage}`);
  write(id, 'started', at(totalAge));
  write(id, 'stages.log', `${at(totalAge)} __invocation__\n${at(stageAge)} ${stage}`);
  write(id, 'timeline', `${clk(stageAge)} ${stage}`);
  write(id, 'activity', activity);
  write(id, 'brief.md', `# ${title}\n\n- **Ticket**: ${id}\n`);
  write(id, 'worktree', `/tmp/dispatch-fixture/${id}`);
  write(id, 'base', 'origin/main');
}

function feed(id, lines) {
  write(id, 'feed.log', lines.map(([ago, text]) => `${clk(ago)} ${text}`).join('\n'));
}

fs.rmSync(DEST, { recursive: true, force: true });
fs.mkdirSync(DEST, { recursive: true });

// --- 1. mid-implement: the newest thing on the wall ---------------------------
run({
  id: 'OLYX-1631', stageAge: 145, totalAge: 1320,
  stage: 'implementing — Opus (Claude sub)',
  activity: '⏺ Edit src/invoices/export.ts',
  title: 'Invoice export endpoint — CSV + XLSX',
});
feed('OLYX-1631', [
  [900, '🧠 Reading the existing report handlers before touching the router'],
  [840, '⏺ Read src/invoices/report.ts'],
  [700, '⏺ Grep createWorkbook'],
  [610, '💬 Reusing the sheet builder from reports instead of writing a second one'],
  [520, '⏺ Write src/invoices/export.ts'],
  [430, '⏺ Edit src/invoices/router.ts'],
  [300, '⏺ Bash npm run test -- invoices'],
  [210, '🧠 The XLSX golden file wants the amounts as numbers, not strings'],
  [145, '⏺ Edit src/invoices/export.ts'],
]);

// --- 2. reviewer stage: the second neon signature -----------------------------
run({
  id: 'OLYX-1655', stageAge: 95, totalAge: 2460,
  stage: 'review — Codex (ChatGPT sub)',
  activity: '◆ codex reviewing the diff against origin/main',
  title: 'Broker payout ledger — split by desk',
});
write('OLYX-1655', 'gate-rounds.log', '1 pass');
feed('OLYX-1655', [
  [700, '⏺ Bash npm run gate'],
  [640, '🏁 success'],
  [420, '◆ codex Reading .harness/brief.md and the diff against origin/main'],
  [330, '◆ codex Checkpoint 1 — no tests weakened, fixtures untouched'],
  [240, '◆ codex ledger.ts duplicates roundToCents from money.ts — folding it back'],
  [150, '◆ codex Applying patch to src/ledger/split.ts'],
  [95, '◆ codex Re-running the gate after the refactor'],
]);

// --- 3. blocked: the alarm state ----------------------------------------------
run({
  id: 'OLYX-1642', stageAge: 780, totalAge: 4020,
  stage: 'waiting — implementer needs your input (QUESTIONS.md)',
  activity: 'waiting — implementer needs your input (QUESTIONS.md)',
  title: 'Retire the legacy quote PDF renderer',
});
write('OLYX-1642', 'QUESTIONS.md', `# Questions

Legacy quotes still render through the old PDF pipeline. Keep it behind a
feature flag for existing quotes, or migrate them all in this release?

- Option A: flag it, migrate lazily on the next edit.
- Option B: one-shot backfill, delete the old renderer in this PR.
`);
feed('OLYX-1642', [
  [1500, '⏺ Read src/pdf/legacy-renderer.ts'],
  [1200, '🧠 The two renderers disagree on how historical quotes are stored'],
  [900, '⏺ Write .harness/QUESTIONS.md'],
  [780, '🏁 success'],
]);
write('OLYX-1642', 'result.json', JSON.stringify({
  ticket: 'OLYX-1642', status: 'needs_input', arm: 'full',
  implementer_model: 'opus', reviewer_model: 'gpt-5.6-sol',
  gate: 'not_run', branch: 'feat/retire-legacy-pdf', base: 'main',
  pr_url: '', demo_url: '',
  metrics: {
    wall_seconds: 4020, gate_rounds: [],
    diff: { files_changed: 3, insertions: 88, deletions: 12 },
  },
}, null, 2));

// --- 4. shipped: PR + demo ----------------------------------------------------
run({
  id: 'OLYX-1598', stageAge: 3300, totalAge: 6100,
  stage: 'done: ready', activity: 'done: ready',
  title: 'Cache the dashboard KPI query',
});
write('OLYX-1598', 'gate-rounds.log', '1 fail\n2 pass');
feed('OLYX-1598', [
  [4200, '◆ codex Checkpoint 3 — the TTL belongs in config, not inline'],
  [3900, '◆ codex Moving 300 to CACHE_TTL_SECONDS in src/config/cache.ts'],
  [3600, '⏺ Bash npm run gate'],
  [3400, '🏁 success'],
  [3300, '⏺ Bash gh pr create --draft'],
]);
write('OLYX-1598', 'result.json', JSON.stringify({
  ticket: 'OLYX-1598', status: 'ready', arm: 'full',
  implementer_model: 'opus', reviewer_model: 'gpt-5.6-sol',
  gate: 'pass', branch: 'feat/cache-kpi-query', base: 'main',
  pr_url: 'https://github.com/acme/dashboard/pull/812',
  demo_url: 'https://demo.example.net/OLYX-1598/demo.mp4',
  metrics: {
    wall_seconds: 2800,
    gate_rounds: [{ round: '1', result: 'fail' }, { round: '2', result: 'pass' }],
    opus_commits: 3, codex_commits: 2,
    diff: { files_changed: 7, insertions: 214, deletions: 63 },
  },
}, null, 2));

// --- 5. rejected by the reviewer ----------------------------------------------
run({
  id: 'OLYX-1604', stageAge: 5400, totalAge: 8200,
  stage: 'done: rejected', activity: 'done: rejected',
  title: 'Move session storage to Redis',
});
write('OLYX-1604', 'gate-rounds.log', '1 pass');
write('OLYX-1604', 'REJECTED.md', `# Rejected

Sessions move to Redis but nothing evicts them: the TTL is never set, so a
restart leaks every session forever. That needs a design decision, not a patch.
`);
feed('OLYX-1604', [
  [6000, '◆ codex Reading src/auth/session-store.ts'],
  [5700, '◆ codex No TTL on the Redis keys — unbounded growth'],
  [5400, '◆ codex Writing .harness/REJECTED.md instead of papering over it'],
]);
write('OLYX-1604', 'result.json', JSON.stringify({
  ticket: 'OLYX-1604', status: 'rejected', arm: 'full',
  implementer_model: 'opus', reviewer_model: 'gpt-5.6-sol',
  gate: 'pass', branch: 'feat/redis-sessions', base: 'main',
  pr_url: '', demo_url: '',
  metrics: {
    wall_seconds: 2800, gate_rounds: [{ round: '1', result: 'pass' }],
    opus_commits: 2, codex_commits: 0,
    diff: { files_changed: 5, insertions: 131, deletions: 47 },
  },
}, null, 2));

console.log(`seeded 5 fixture runs in ${DEST}`);
