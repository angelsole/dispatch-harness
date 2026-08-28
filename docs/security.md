# Security

What it means to point an unattended, code-executing pipeline at your
repositories, the two boundaries that contain it — the worker's deny list and
the reviewer's sandbox — and the one secret the harness hands a worker that is
not a vendor credential.

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

## The wall ingest token

`HARNESS_WALL_TOKEN` ([Ingest](wall.md#ingest)) is the one secret the harness
puts in a worker's environment on purpose. It has to be there: the CLI's
OpenTelemetry exporter takes its headers from `OTEL_EXPORTER_OTLP_HEADERS` and
has no file form, so there is no path-and-permissions dance to do here of the
kind the z.ai key and the Linear key get.

Size it accordingly. It is a **shared LAN-dashboard secret**, not a vendor
credential: the only thing holding it buys is the ability to post run rows to a
board on your own network, and the wall's GET routes have no auth at all. Use a
value you are willing to have in the environment of every worker on every
machine that dispatches, do not reuse a token that means anything else, and keep
the wall off the public internet — which was already the rule.

**What the wall refuses to keep.** The worker's metrics carry the operator's
identity beside the numbers: `user.email`, `user.id`, `user.account_uuid`,
`user.account_id`, `organization.id`, `terminal.type`. All six are dropped at
the ingest boundary and never reach the wall's memory, its `WALL_INGEST_FILE`,
or any payload it serves. OTel **logs** — which carry prompt and response text —
are never enabled by the harness at all: `OTEL_LOGS_EXPORTER=none` is part of
the worker environment, and the wall's `/v1/logs` route accepts a body only to
discard it.
