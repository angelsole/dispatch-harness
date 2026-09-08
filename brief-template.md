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
stop and ask about first. When research cannot identify a target file, write
`unknown — research did not identify the edit location` and say what remains
to locate; an honest unknown is better than an invented path.

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

## Tests
The tests this change actually needs, named. An implementer left to its own
judgement writes a suite around the whole module — unit, integration and
fixtures for behaviour nobody asked it to touch — and the diff arrives three
times the size it should be, with the real change buried in it. So state the
cases the acceptance criteria imply and nothing beyond them, and say where they
go. `none — the existing suite already covers this` is a legitimate value and
the right one for a change whose behaviour is already asserted somewhere. Never
ask for a test framework the repo does not already have; if the change needs
one, that is a decision point, not a test.

- `src/pricing/margin.test.ts` — the two tier-edge cases from the criteria.
  Nothing else in this file changes.

## Verify
```bash
# the suites/checks that cover THIS change — what the implementer runs before
# each commit. The pipeline's gate runs the repo's full suite afterwards; the
# implementer must not spend its turns re-running all of it.
npm run type-check && npm test -- src/pricing
```

## Demo storyboard
(Only for user-facing/frontend changes — DELETE this section otherwise.)
Write `.harness/demo.json` for agent-browser. Show THIS feature using fixture
or demo data suitable for the PR's audience. Use stable CSS/text selectors,
never session refs such as `@e1`. End the interaction with a `wait` for its
visible success state. Keep a screenshot for a static change; set `video: true`
for a short interaction recording. The harness always captures `result.png`.

The server runs in the task worktree. Pin its port strictly, choose a free port
allowed by the app's backend CORS configuration, and use the same localhost
origin in `url`. The harness refuses a busy port and stops only its own server.
For authenticated apps, use the host's saved demo session (`demo-auth.sh` or a
repo-pinned `DEMO_AUTH_FILE`); never put credentials or login actions here.

```json
{
  "server": ["npm", "run", "dev", "--", "--port", "5173", "--strictPort"],
  "url": "http://localhost:5173/route-to-the-feature",
  "viewport": {"width": 1280, "height": 800},
  "video": true,
  "steps": [
    ["wait", "#feature-form"],
    ["screenshot", "before.png"],
    ["fill", "#name", "Demo item"],
    ["click", "#save"],
    ["wait", "#save-success"],
    ["wait", "1500"]
  ]
}
```

Steps support `click selector`, `fill selector value`, `press key`,
`wait selector-or-milliseconds`, and `screenshot filename.png` as arrays.
Screenshot names are simple filenames; at most ten named screenshots and fifty
steps. Total capture time is bounded to ten minutes. Capture happens after the
final gate and base sync. Media and a commit-bound manifest stay in the run
folder, including with `--no-publish`. The PR receives the media when uploads
are available, or an explicit capture/upload status. Evidence does not replace
tests or visual review. Existing shot-scraper `.harness/demo.yml` storyboards
remain supported; their repo must set `DEMO_PORT`.

## Out of scope
What must NOT be touched, even if tempting.
