# <Concise task title — becomes the PR title>

- **Ticket**: PROJ-XXXX (link to the issue in your tracker, or `adhoc-<slug>`)
- **Repo**: /absolute/path/to/repo
- **Branch**: fix/proj-xxxx-short-slug
- **Base**: staging

## Problem
What is broken or needed, with the concrete evidence found during research
(error messages, Sentry links, code locations as file:line).

## Reproduction
The runnable command or failing test that demonstrates the problem — copy-pasteable,
and expected to fail before the change. `none — greenfield feature` is a legitimate
value and a better one than a command nobody ran.

```bash
npm test -- src/pricing/margin.test.ts   # fails: expects 1250, gets 1249
```

## Interface contract
The names the change must expose, verbatim: signatures, routes, payload shapes,
field names, error semantics, config keys. This is what makes a diff checkable
against the brief instead of against taste, and when a ticket spans repos it is
the workers' only handshake — the same section, word for word, in every brief
that touches it. Write `none — internal change only` rather than inventing one.

## Edit locations
Where the change is expected to land, from the research already done: one line
per file, with the function or symbol when it is known. The implementer may
depart from this list — it is a starting point, not a fence — and anything it
deletes or rewrites *outside* this list is an undeclared blast radius it must
stop and ask about first.

- `src/pricing/margin.ts` — `applyTier()`, the rounding step
- `src/pricing/margin.test.ts` — new cases per the criteria below

## Attached specs
(Only when the task ships source documents the planner converted to markdown —
DELETE this section otherwise.) Everything in the run dir's `specs/` is mounted
at `.harness/specs/` in the worktree, so reference the files by that path. One
line per file: what the implementer should take from it, and where.

- `.harness/specs/margin-rules.md` — the authoritative tier boundaries and
  rounding rules (§3); the Problem section only summarises them.

## Constraints & pointers
Architectural decisions already made by the planner — the implementer designs
the rest. Relevant files/services. Repo invariants that apply (e.g. money in
integer cents, services return {data, error}, DataLoaders use Map lookups).

## Decision points
The forks the implementer will actually hit, declared here so that stopping to
ask is a rule rather than a judgement call. One line each: the fork, then either
the decision — which the implementer follows without asking — or `STOP and ask`,
plus the blast radius if it goes the wrong way. A fork you genuinely have not
resolved is worth more here as `STOP and ask` than as a decision you guessed;
one you have resolved costs the run a stop if you leave it out.

- Tier boundaries inclusive or exclusive at the edge → **inclusive**; the spec's
  §3 table settles it. Blast radius: one test, one line.
- Backfilling existing orders → **STOP and ask**. Blast radius: a migration over
  production rows, not reversible by revert.

## Acceptance criteria
- [ ] Each criterion independently verifiable by reading code or running a command
- [ ] ...

## Verify
```bash
# exact commands the implementer and gate will run
npm run type-check && npm test
```

## Demo storyboard
(Only for user-facing/frontend changes — DELETE this section otherwise.)
Write `.harness/demo.yml`, a shot-scraper storyboard demonstrating THIS feature,
15–30s: navigate → demonstrate → success state. Scenes must assume an
already-authenticated session — never script the login; the pipeline injects a
saved session (`--auth`) automatically. Shape:

The server/url port MUST be the app's normal dev port (whatever DEMO_PORT is
pinned to for this repo) — backend CORS allowlists usually only cover those
origins.

Scene actions — these are the ONLY ones shot-scraper supports; anything else
(e.g. `key`, `type`, `fill`) aborts the recording: `click`, `press` (keyboard
key, e.g. `press: Escape`), `scroll`, `pause`, `wait_for`, `wait_for_url`.
Prefer selectors unique on the page — ambiguous `text=` selectors fail strict
mode. A demo failure never fails the run, so a broken storyboard just means a
silently missing video.

```yaml
output: .harness/demo.webm
server: ["npm", "run", "dev", "--", "--port", "5173", "--strictPort"]
url: http://localhost:5173/route-to-the-feature
viewport: {width: 1280, height: 800}
cursor: true
scenes:
  - name: open the feature
    wait_for: "text=Something visible on load"
    do:
      - pause: 1
      - click: "text=The new button"
      - pause: 2
```

## Out of scope
What must NOT be touched, even if tempting.
