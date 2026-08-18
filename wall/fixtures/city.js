'use strict';
// The week the fixtures remember: a district to stand under the staged skyline.
//
// The run dirs beside this file stage the LIVE half of the wall — eleven runs at
// every floor of the pipeline. The district under them is fed by something else
// entirely: the city ledger, one line per run that ever reached `done: ready`.
// The fixtures ship exactly one of those, so `wall.sh --runs wall/fixtures/runs`
// — the demo, and the scene the visual gate renders — put a lived-in skyline on
// an empty plain, and the one thing neither could show was the half of the wall
// that accretes. The wall as the office sees it on a Thursday is twenty-odd
// buildings across three depth bands, with shopfronts, occupancy and signs. This
// is that Thursday.
//
// Six fields per record and nothing else (`recordOf`, ../server.js) — the plot,
// the family, the height, the sign and the ghost behind it are all derived from
// them at render time, exactly as they are for a real ship. Nothing in here
// knows what a building looks like, and changing what one looks like never
// touches this file.
//
// Deterministic, with no Math.random anywhere: the same minute yields the same
// city, so a demo restart is the demo you recorded and the two renders a blind
// critic is shown in either order are the same street.

// Where a ship lands inside its window, as a share of it. The current week's
// window is Monday 00:00 -> the minute the wall came up, so the district is full
// at nine on Monday and at six on Friday alike; last week's is the whole of last
// week. What the room reads off the street is the ORDER — the freshest sign is
// the brightest — never the wall-clock hour, which nobody on the sofa can check.
//
// Ticket ids are the fixture projects' own ranges and disjoint from the staged
// run dirs: a seeded id that collided with one would shadow it under the ledger's
// first-sighting rule, and the demo would quietly stop showing a real discovery.
// Diffs span the whole of storeysOf(), from a run that recorded no lines at all
// to one that pins the cap; the plots are the ids' own hashes, spread across all
// three depth bands and never closer than a footprint within one of them.

// share  id                       repo                   owner      ins   del
const THIS_WEEK = [
  // olyxbase — the busy tower, and the week's biggest landing
  [0.07, 'OLYX-1566', 'olyxbase', 'emre', 118, 26],
  [0.22, 'OLYX-1579', 'olyxbase', 'angel', 22, 3],
  [0.41, 'OLYX-1587', 'olyxbase', 'reinier', 640, 180],
  [0.58, 'OLYX-1604', 'olyxbase', 'angel', 51, 9],
  [0.73, 'OLYX-1619', 'olyxbase', 'emre', 7, 2],
  [1.00, 'OLYX-1636', 'olyxbase', 'reinier', 1290, 430],
  // olyx-agents — the crew's work and the synthetic's nightly sweeps
  [0.04, 'OLYX-1603', 'olyx-agents', 'angel', 210, 48],
  [0.28, 'OLYX-1625', 'olyx-agents', 'reinier', 35, 11],
  [0.33, 'BOT-2268', 'olyx-agents', 'bot', 14, 6],
  [0.66, 'BOT-2276', 'olyx-agents', 'bot', 96, 240],
  [0.88, 'OLYX-1658', 'olyx-agents', 'emre', 0, 0],
  // olyx-dashboard
  [0.13, 'OLYX-1575', 'olyx-dashboard', 'emre', 74, 18],
  [0.47, 'OLYX-1611', 'olyx-dashboard', 'angel', 380, 95],
  [0.81, 'adhoc-kpi-tiles-dark', 'olyx-dashboard', 'angel', 12, 4],
  // valoryx-graphql-api — the spires
  [0.19, 'OLYX-1583', 'valoryx-graphql-api', 'reinier', 168, 40],
  [0.52, 'OLYX-1630', 'valoryx-graphql-api', 'emre', 3, 1],
  [0.77, 'OLYX-1663', 'valoryx-graphql-api', 'angel', 540, 120],
  // dispatch-harness — the wall working on itself
  [0.36, 'adhoc-wall-ticker', 'dispatch-harness', 'angel', 220, 60],
  [0.61, 'adhoc-gate-rounds', 'dispatch-harness', 'reinier', 46, 8],
  // legacy-importer — the honest mid-rise nobody has a family for
  [0.09, 'LEGACY-0037', 'legacy-importer', 'emre', 1, 0],
  [0.94, 'LEGACY-0046', 'legacy-importer', 'bot', 88, 12],
];

// Last week, which the wall only ever draws as outlines: a height and a plot,
// no family, no sign, no windows. Fewer of them on purpose — a ghost that
// crowded this week's city would stop reading as the week behind it.
const LAST_WEEK = [
  [0.06, 'OLYX-1544', 'valoryx-graphql-api', 'reinier', 26, 5],
  [0.19, 'OLYX-1521', 'olyxbase', 'angel', 300, 64],
  [0.33, 'OLYX-1550', 'olyx-dashboard', 'angel', 9, 2],
  [0.45, 'OLYX-1538', 'olyx-agents', 'emre', 82, 20],
  [0.58, 'OLYX-1509', 'olyxbase', 'reinier', 1100, 240],
  [0.71, 'BOT-2251', 'olyx-agents', 'bot', 140, 300],
  [0.87, 'adhoc-city-ledger', 'dispatch-harness', 'angel', 470, 130],
];

// The minute, not the second, is the quantum. Two walls booted moments apart —
// the second TV in the room, or the pair of renders the visual gate grades
// against each other — have to agree building for building, and an epoch taken
// off the raw clock would put every sign on its own slightly different fade.
const MINUTE = 60;

// And the window stops short of the minute the wall came up. A building now has a
// BIRTH — a scaffold, a façade arriving, a cascade, a beacon, about twenty seconds
// of it from the ship (world-canvas.js, SHIP and BUILD) — so a newest row stamped
// at the boot minute would have the district's freshest plot mid-scaffold at some
// unpredictable point of that twenty seconds, and the visual gate's wide shot would
// catch a building going up on roughly one run in eight. The fixtures stage a
// lived-in Thursday, not a ship happening right now: the newest of them landed
// comfortably before the wall opened its eyes. A run that ships while the wall is
// watching is what `?ship=` and the real pipeline are for.
const SETTLED_S = 30;

// `weekStartOf` is handed in rather than imported. The server owns the
// definition of Monday — local midnight, DST weeks of 23 and 25 hours and all —
// and a second implementation of it here would drift the first time one of them
// learned something. Requiring it back out of ../server.js is not on offer
// either: server.js is what requires this file.
function cityRecords(now, weekStartOf) {
  const minute = Math.floor(now / MINUTE) * MINUTE;
  // Monday is decided by the minute the wall came up, not by the shifted window:
  // a wall booted in the first half-minute of a week would otherwise lay down last
  // week's district as this week's.
  const weekStart = weekStartOf(minute);
  const base = Math.max(weekStart, minute - SETTLED_S);
  const previousStart = weekStartOf(weekStart - 1);
  const spread = (rows, from, span) =>
    rows.map(([share, id, repo, owner, insertions, deletions]) => ({
      id,
      epoch: from + Math.round(Math.max(0, span) * share),
      repo,
      owner,
      insertions,
      deletions,
    }));
  // Oldest first, so the file the wall lays down reads like the chronicle an
  // append-only ledger written live would have been.
  return [
    ...spread(LAST_WEEK, previousStart, weekStart - previousStart),
    ...spread(THIS_WEEK, weekStart, base - weekStart),
  ].sort((a, b) => a.epoch - b.epoch);
}

module.exports = { cityRecords };
