'use strict';
// What a run spent, read — never priced. The pipeline's own telemetry
// (run-task.sh) writes the figures into every run's result.json: the
// à-la-carte-on-Opus list price (whatever the provider) and, on a zai run, the
// z.ai Coding-Plan credits. Both subscriptions are flat-rate, so neither
// number is money out of a bank account; it is the comparison unit that makes
// "GLM vs Opus" a number instead of a vibe. The rates and the credit formula
// live once, in run-task.sh — a second copy here is forbidden.
//
// Loaded twice: required by wall/server.js and loaded as window.Cost by the
// ops console, which is why it touches no Node API and does its own arithmetic
// on already-parsed objects only. Every string an operator sees comes from
// here, so the shell gate can test the display without rendering DOM.
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.Cost = api;               // window.Cost in the console page
})(typeof self !== 'undefined' ? self : this, function () {

  const SUMMARY_WINDOW_DAYS = 7;

  // metrics.total_cost_usd is written as `… // null`, so "present but null" is
  // a real shape (a run the stream could not price), not a bug.
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : null);

  // --- data ----------------------------------------------------------------------

  // The caller resolves the provider (server.js's providerOf — the pin file
  // wins); runCost echoes it and never re-derives it. Whole null only when
  // there is no metrics object at all: a run that far predates telemetry.
  function runCost(result, provider) {
    const r = obj(result);
    const metrics = r && obj(r.metrics);
    if (!metrics) return null;
    const usage = obj(metrics.usage) || {};
    const impl = obj(metrics.implementer_usage);
    return {
      provider: provider == null ? '' : String(provider),
      opusListUsd: num(metrics.total_cost_usd),
      zaiCredits: num(usage.zai_credits_est),
      tokens: impl ? {
        input: num(impl.input_tokens),
        output: num(impl.output_tokens),
        cacheRead: num(impl.cache_read_input_tokens),
        cacheCreate: num(impl.cache_creation_input_tokens),
      } : null,
    };
  }

  // The console frame's summary. Pure: the caller injects the clock, so the
  // same entries always summarise to the same frame. Only finished runs
  // (ready|failed) count; a null opusListUsd is excluded from every USD sum
  // and average — the NaN guard — while its run still counts in run counts
  // and the ship rate.
  function summarize(entries, opts) {
    const o = opts || {};
    const nowMs = typeof o.nowMs === 'number' && Number.isFinite(o.nowMs) ? o.nowMs : 0;
    const windowDays = typeof o.windowDays === 'number' && Number.isFinite(o.windowDays)
      && o.windowDays > 0 ? o.windowDays : SUMMARY_WINDOW_DAYS;
    const inWindow = (Array.isArray(entries) ? entries : [])
      .filter((e) => obj(e) && typeof e.mtimeMs === 'number' && Number.isFinite(e.mtimeMs)
        && e.mtimeMs >= nowMs - windowDays * 864e5 && e.mtimeMs <= nowMs);

    const byProvider = { zai: 0, anthropic: 0 };
    const listUsdByProvider = { zai: 0, anthropic: 0 };
    const samples = { zai: { usd: [], turns: [] }, anthropic: { usd: [], turns: [] } };
    let shipped = 0;
    let failed = 0;
    let listUsdAll = 0;
    let zaiCredits = 0;
    let runs = 0;
    for (const e of inWindow) {
      if (e.state !== 'ready' && e.state !== 'failed') continue;
      runs += 1;
      if (e.state === 'ready') shipped += 1; else failed += 1;
      const usd = num(e.opusListUsd);
      const turns = num(e.turns);
      if (usd !== null) listUsdAll += usd;
      if (e.provider === 'zai' || e.provider === 'anthropic') {
        byProvider[e.provider] += 1;
        if (usd !== null) { listUsdByProvider[e.provider] += usd; samples[e.provider].usd.push(usd); }
        if (turns !== null) samples[e.provider].turns.push(turns);
      }
      const credits = num(e.zaiCredits);
      if (e.provider === 'zai' && credits !== null) zaiCredits += credits;
    }

    const mean = (list) => (list.length ? list.reduce((a, b) => a + b, 0) / list.length : null);
    const avgOf = (p) => (byProvider[p] === 0 ? null : {
      listUsd: mean(samples[p].usd),
      turns: mean(samples[p].turns),
    });

    return {
      windowDays,
      runs,
      byProvider,
      shipped,
      failed,
      shipRate: runs === 0 ? null : shipped / runs,
      prsPerDay: shipped / windowDays,
      listUsdAll,
      listUsdByProvider,
      zaiCredits,
      avg: { zai: avgOf('zai'), anthropic: avgOf('anthropic') },
    };
  }

  // --- display -------------------------------------------------------------------

  // '3,112' — hand-rolled grouping: toLocaleString answers to the runtime's
  // ICU, and the gate's expectations should not.
  function group(n) {
    return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  }

  const usd = (v) => (v == null ? '—' : '$' + v.toFixed(2));
  // Totals carry more dollars than cents; per-run figures do not.
  const usdTotal = (v) => (v == null ? '—'
    : v >= 100 ? '$' + group(v) : '$' + v.toFixed(2));
  const round1 = (v) => (v == null ? '—' : String(Math.round(v * 10) / 10));

  const count = (n) => {
    if (n == null) return '—';
    if (n >= 1e6) return Math.round(n / 1e5) / 10 + 'M';
    if (n >= 1e3) return Math.round(n / 100) / 10 + 'k';
    return String(Math.round(n));
  };

  function formatCostCell(cost) {
    const c = obj(cost);
    if (!c) return '—';
    if (c.provider === 'zai') return num(c.zaiCredits) == null ? '—' : group(c.zaiCredits) + ' cr';
    if (c.provider === 'anthropic') return num(c.opusListUsd) == null ? '—' : usd(c.opusListUsd);
    return '—';
  }

  function formatCostTooltip(cost) {
    const c = obj(cost);
    if (!c) return '—';
    const parts = ['à la carte ' + usd(num(c.opusListUsd))];
    if (num(c.zaiCredits) != null) parts.push(group(c.zaiCredits) + ' zai credits');
    if (obj(c.tokens)) {
      parts.push('in ' + count(num(c.tokens.input)) + ' out ' + count(num(c.tokens.output)));
      parts.push('cache ' + count(num(c.tokens.cacheRead)) + ' read / '
        + count(num(c.tokens.cacheCreate)) + ' write');
    }
    return parts.join(' · ');
  }

  function summaryTiles(summary) {
    const s = obj(summary);
    const empty = !s || Object.keys(s).length === 0;
    const perRun = (p) => {
      const avg = s && s.avg && s.avg[p];
      if (!avg) return { value: '—', turns: '—' };
      return { value: usd(avg.listUsd == null ? null : avg.listUsd), turns: round1(avg.turns) };
    };
    const zai = perRun('zai');
    const anthropic = perRun('anthropic');
    return [
      {
        label: 'ship rate',
        value: empty || s.shipRate == null ? '—' : Math.round(s.shipRate * 100) + '%',
        sub: empty || s.runs === 0 ? 'no finished runs'
          : s.shipped + ' shipped · ' + s.failed + ' failed',
      },
      {
        label: 'prs / day',
        value: empty ? '—' : round1(s.prsPerDay),
        sub: empty ? '—' : s.shipped + ' shipped in ' + s.windowDays + 'd',
      },
      {
        label: 'finished runs',
        value: empty ? '—' : String(s.runs),
        sub: empty ? '—' : s.byProvider.zai + ' glm · ' + s.byProvider.anthropic + ' opus',
      },
      {
        label: 'list price',
        value: empty || s.runs === 0 ? '—' : usdTotal(s.listUsdAll),
        sub: empty || !(s.zaiCredits > 0) ? 'à la carte — both plans flat'
          : 'à la carte · glm ' + group(s.zaiCredits) + ' cr',
      },
      {
        label: 'glm vs opus',
        value: zai.value + ' vs ' + anthropic.value,
        sub: 'per run, list price · ' + zai.turns + ' vs ' + anthropic.turns + ' turns',
      },
    ];
  }

  return {
    runCost, summarize, formatCostCell, formatCostTooltip, summaryTiles,
    SUMMARY_WINDOW_DAYS,
  };
});
