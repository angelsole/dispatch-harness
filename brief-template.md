# <Concise task title — becomes the PR title>

- **Ticket**: PROJ-XXXX (link to the issue in your tracker, or `adhoc-<slug>`)
- **Repo**: /absolute/path/to/repo
- **Branch**: fix/proj-xxxx-short-slug
- **Base**: staging

## Problem
What is broken or needed, with the concrete evidence found during research
(error messages, Sentry links, code locations as file:line).

## Constraints & pointers
Architectural decisions already made by the planner — the implementer designs
the rest. Relevant files/services. Repo invariants that apply (e.g. money in
integer cents, services return {data, error}, DataLoaders use Map lookups).

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
