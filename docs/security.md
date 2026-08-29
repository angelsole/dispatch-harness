# Security

What it means to point an unattended, code-executing pipeline at your
repositories, and the two boundaries that contain it: the worker's deny list
and the reviewer's sandbox.

## The threat model

This harness runs frontier models **unattended, with the ability to execute
code**, against your repositories. Be clear-eyed about what that means.

- **Arbitrary code execution is the design, not a bug.** The worker installs
  dependencies and runs your gate (`npm ci`, `npm test`, `uv run pytest`, …).
  Any of those can run arbitrary code — that is inherent to building and testing
  software. Only dispatch against repos you trust to build and test on your
  machine.
- **Prompt-injection surface.** Workers are allowed `WebFetch` and `WebSearch`,
  and they read repository contents and dependency code. Any of that text can
  contain instructions crafted to subvert the agent. For the Claude-side
  workers the deny list (`git push`/`checkout`/`switch`, `gh`, plus any
  destructive MCP tools you add) is the containment boundary: even a fully
  hijacked worker cannot push, switch branches, open/merge PRs, or hit a denied
  MCP tool. For the Codex reviewer that file does not apply at all — its
  boundary is the sandbox it runs in and the harness-owned `CODEX_HOME` that
  gives it no rules, plugins or MCP servers of yours, and no route off
  loopback. Either way the harness — not the model — owns every outward-facing
  action.
- **Deny-list philosophy.** Allow the worker the minimum it needs to implement
  and self-check; deny anything that reaches outside the worktree or is
  irreversible. When in doubt, deny — a blocked tool call surfaces as a prompt,
  a missed one can push to production. Review `worker-settings.json` before
  first use and extend its `deny` list for your environment.
- **Keep secrets out of briefs and worktrees.** The brief and the diff are
  handed to two different vendors' models and end up in a PR body. Do not paste
  credentials, tokens, or private URLs into a brief. Real `.env` files are
  copied into the worktree so the gate can run, but they are gitignored and must
  never be committed — the harness strips any `.harness/` metadata that slips
  into the index as a backstop, but treat secret hygiene as your responsibility.
- **Local only.** Database and MCP tools operate against your **local**
  environment. The worker is instructed never to switch environments or touch
  staging/production, and destructive environment-switch tools should be denied
  outright (see above).

## Credentials, and how they travel

Every credential the harness reads is a file you create by hand, mode 600, in
`HARNESS_DIR` — never a value in a config file the repo ships, never an argument.
[Local config files](reference.md#local-config-files) lists them all; the Linear
set is:

- **`linear-api-key`** — your personal Linear key. Reads the ticket, comments the
  PR link, moves the ticket to In Review.
- **`linear-agent-credentials`** — the `client_id` / `client_secret` of the
  workspace's Linear OAuth app, present only where ticketed runs are dispatched.
  Its blast radius is the whole workspace, so it lives on one machine and is
  registered by an admin ([Ticket sync](operations.md#ticket-sync)).
- **`linear-agent-token`** — written by the harness, not by you: the 30-day app
  actor token minted from those credentials, re-minted on expiry or a `401`. It
  is a cache; deleting it costs one round trip.

Two rules hold for all of them:

- **Never on argv.** `ps` is world-readable, so a secret handed to `curl` as
  `-u id:secret` or `-H "Authorization: …"` is visible to every process on the
  machine. Secrets are written to a mode-600 header file under `umask 077`,
  passed as `-H @file`, and deleted after the call. GraphQL bodies carry no
  secret and stay on argv, which is what makes the request logs readable.
  [`tests/linear-agent.test.sh`](../tests/linear-agent.test.sh) records the full
  argv of every `curl` the pipeline makes and asserts no credential appears in it.
- **Never in a log.** `runs/<RUN-ID>/ticket-sync.log` holds every Linear request
  and its raw response — but a token-minting response is summarised, never
  echoed. The model stages cannot read any of these files: they are in the `deny`
  list of `planner-settings.json`, `spec-critic-settings.json` and the visual
  critic's settings.

## The worker sandbox and MCP denies

The implementer runs under
[`worker-settings.json`](../worker-settings.json), which allow-lists the tools it
needs (edit/write, `npm`/`npx`/`yarn`/`node`/`uv`, read-only git, common shell
utilities) and **denies the ones that could do damage**: `git push`,
`git checkout`, `git switch` and `gh`. The harness owns pushing and PR creation;
the worker must never touch remotes or switch branches. This file governs the
Claude-side workers only — the Codex reviewer is bounded by its own sandbox and a
harness-owned `CODEX_HOME` carrying none of your rules ([What the reviewer is allowed to reach](design-notes.md#what-the-reviewer-is-allowed-to-reach)).
If your worker loads an MCP server (via `MCP_CONFIG`) exposing destructive tools
— an environment switch, a deploy, a delete — **add those tool names to the
`deny` list in your installed copy**:

```jsonc
"deny": [
  "Bash(git push:*)",
  "Bash(git checkout:*)",
  "Bash(git switch:*)",
  "Bash(gh:*)",
  "mcp__your-db__switch_environment"
]
```

Deny lists are cheap insurance; add to them liberally.
