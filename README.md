# Dispatch Harness

A multi-model pipeline for shipping code: **one model plans, a second
implements, a deterministic gate runs, a third — from a different vendor —
reviews and fixes, and a draft PR opens.** You approve at the ends; the middle
runs unattended in a git worktree.

The design principle is simple: **no model grades its own homework.** The agent
that writes the code is never the agent that reviews it, and they come from
different vendors (Anthropic and OpenAI), so a blind spot in one model's
training is unlikely to be shared by the other. Between them sits a gate no
model can talk its way past.

```
you → planner → [ implementer → gate → reviewer → gate ] → draft PR → you
  (your session)  (Claude sub)  (free)  (ChatGPT sub)
```

The planner isn't pinned by the harness: it is whatever Claude Code session
invokes `/dispatch`, billed however that session is billed — API credits or a
subscription. We've gotten the best results with **Claude Fable 5** as the
planner (sharper briefs up front mean fewer `needs_input` stops and review
fixes downstream); an Opus session on a Claude subscription also works, and
then the whole pipeline runs on flat-rate plans. Only the implementer and
reviewer are fixed by the pipeline.

---

## Why it's built this way

**Cross-vendor implement/review split.** The implementer (Anthropic's Opus —
`claude-opus-5` by default, via a Claude subscription) writes and commits. The
reviewer (OpenAI's Codex — `gpt-5.6-sol` by default, via a ChatGPT
subscription) reads the diff cold and fixes what it finds. Neither
sees the other's reasoning — only the committed result. A self-review by the
same model tends to rationalize its own choices; a different model from a
different lab does not.

**A deterministic gate between the models.** Between implement and review runs a
plain test gate — your repo's own `lint`/`type-check`/`test` commands, no model
in the loop. It is the objective checkpoint: green or red, no narrative. Because
a model *could* make the gate green by weakening the tests, the reviewer's
**first and highest-priority checklist item is anti-gate-gaming**: it hunts for
weakened or deleted tests, skipped cases, loosened assertions, hardcoded
expected values, and edited fixtures — and restores proper tests and fixes the
code instead. A green gate only counts if the tests earning it weren't touched.

**Subscription economics.** The expensive, low-volume work — research and the
brief — runs in your orchestrator session, billed however that session is
billed (in our experience Claude Fable 5 on API credits earns its price here;
a subscription session works too). The expensive, *high-volume* work —
implementing and reviewing, which burn the most tokens — runs on flat-rate
**subscriptions** (Claude and ChatGPT) that you already pay for. The glue between stages (worktrees, the gate, the PR)
is deterministic shell and costs nothing. You get frontier models on the
token-heavy stages without metered token bills for them.

**`needs_input`: stop, don't guess.** When the implementer hits a fork the brief
doesn't resolve — a genuine product or priority decision — it does **not**
guess. It writes the specific question(s) to `QUESTIONS.md` and stops the run
with status `needs_input`. Worker sessions are **resumable**: the planner (or
you) appends answers to the brief and re-dispatches the exact same command, and
the worker continues with its full context intact — it does not start over. You
can also step into the live session interactively at any time.

**Per-model commit attribution.** Every run records `opus_head` — the commit SHA
that marks the boundary between the implementer's work and the reviewer's fixes.
Commits up to it are the implementer's; commits after it are the reviewer's.
Attribution lives only in the run's metadata, never in the commit messages
themselves (the commits stay clean — no AI or agent mentions), so you always
know which model wrote what without polluting the history.

---

## Architecture

The full pipeline, stage by stage (source: [`FLOW.md`](FLOW.md); a printable
one-page version is in [`harness-flow.html`](harness-flow.html)):

```mermaid
sequenceDiagram
    autonumber
    actor U as You
    participant F as Planner<br/>API
    participant S as run-task.sh<br/>script · free
    participant O as Implementer<br/>Opus · Claude sub
    participant C as Reviewer<br/>Codex · ChatGPT sub

    U->>F: /dispatch PROJ-1234 or free-form idea
    F->>F: research repo (Explore subagents)
    F->>U: brief.md — criteria + verify commands
    U->>F: approve (± create a ticket)
    F->>S: launch run (background)
    S->>S: worktree from origin/<base><br/>copy .env · install deps
    S->>O: brief.md
    O->>O: design + implement + commit<br/>(cheaper subagents explore)

    alt brief doesn't resolve a fork
        O->>F: QUESTIONS.md — needs_input ⏸
        F->>U: product forks only (arch: answers itself)
        U->>F: decisions
        F->>O: brief + answers — session resumes
    end

    S->>S: test gate #1 (per-repo cmds)
    S->>C: diff + brief + gate log
    C->>C: checklist: gate-gaming · business logic<br/>reuse · hardcoding · quality

    alt fundamental flaw
        C->>F: REJECTED.md
        F->>O: sharpened brief — re-dispatch
    else fixes / refactors in branch footprint
        C->>S: fix commits + review-notes.md<br/>(gate re-runs, max 2 rounds)
    end

    S->>S: push + draft PR (notes in body)
    S->>F: result.json — ready
    F->>U: verdict · preview.sh if frontend
    U->>F: approve
    F->>S: gh pr ready + cleanup.sh
    S->>U: PR ready for review · worktree cleaned
```

Each run gets its own git worktree (`<repo>-<ticket>`), so multiple tickets run
in parallel without colliding. The brief and all metadata live in a
`.harness/` directory inside the worktree that is git-excluded — it never ships
in a commit or PR.

---

## Prerequisites

Required:

- **[`claude`](https://docs.claude.com/en/docs/claude-code) CLI** — runs the
  implementer (and, if you like, the planner) on a Claude subscription.
- **`codex` CLI** (≥ 0.145) — runs the reviewer on a ChatGPT subscription.
  Older versions reject the default reviewer model (`gpt-5.6-sol`).
- **`gh`** (GitHub CLI, authenticated) — pushes branches and opens PRs.
- **`jq`** — reads/writes run metadata.
- **`git`**, **`bash`**, and standard Unix tools: `curl`, `perl`, `lsof`,
  `uuidgen`. macOS ships all of these; on Linux install `uuid-runtime` (for
  `uuidgen`) and `lsof` if missing.

Optional (only for the auto-recorded PR demo videos on frontend runs):

- **[`shot-scraper`](https://shot-scraper.datasette.io/)** — records the
  storyboard.
- **[`rclone`](https://rclone.org/)** — uploads the video to object storage
  (any S3-compatible bucket: Cloudflare R2, AWS S3, Backblaze B2, MinIO).
- **`ffmpeg`** — transcodes the recording and builds the preview GIF.

Portability notes: the scripts target **bash 3.2** (the macOS default). macOS
ships no `timeout(1)`, so the harness uses a `perl -e 'alarm ...'` wrapper as a
process cap. The only hard macOS-specific dependency is `osascript` for local
desktop notifications — it is guarded, so on Linux notifications are simply
skipped (phone push via [ntfy](https://ntfy.sh) still works). CI
([`.github/workflows/gate.yml`](.github/workflows/gate.yml)) runs the gate on
Linux to keep the shipped scripts portable.

---

## Quickstart

```bash
git clone <this-repo> dispatch-harness
cd dispatch-harness

# Symlinks scripts into ~/.claude/harness and the skill into
# ~/.claude/skills/dispatch/. Re-runnable; never clobbers your local config.
./install.sh          # or ./install.sh --copy for detached copies

# Pin a repo onto the pipeline (optional — anything unset is auto-detected).
# setup-repo.sh inspects the repo and writes a complete, pinned entry for you:
~/.claude/harness/setup-repo.sh /path/to/your/repo            # preview the proposal
~/.claude/harness/setup-repo.sh /path/to/your/repo --write    # save it
# ...or hand-edit the file directly: $EDITOR ~/.claude/harness/repos.local.sh

# Enable phone push / tune notifications (optional):
$EDITOR ~/.claude/harness/notify.conf
```

Then, from a Claude session in your orchestrator working directory:

```
/dispatch <TICKET-or-"a description of what to build">
```

The planner researches the repo, writes a brief, and shows it to you for
approval. On approval it launches the run in the background:

```bash
~/.claude/harness/run-task.sh <TICKET> <repo-path> <branch-name>
```

When the run finishes you get a verdict and, if it's `ready`, a draft PR. See
[`skills/dispatch/SKILL.md`](skills/dispatch/SKILL.md) for the full planner
protocol.

To point the whole harness somewhere other than `~/.claude/harness`, set
`HARNESS_DIR` (every script honors it) and install with
`HARNESS_DIR=/path ./install.sh`.

---

## Configuration

### Per-repo config: the `repo_config` contract

`repos.conf.sh` (shipped) auto-detects sensible defaults for any repo: install
and gate commands from the lockfile, base branch from the remote's default. To
**pin** settings for a specific repo, add a `repo_config_local()` case arm to
`~/.claude/harness/repos.local.sh` (gitignored — `install.sh` seeds it for you).
It runs *before* auto-detection; any field you leave blank is still
auto-detected.

Keys are the repo's directory name (`basename`). Worktrees are named
`<repo>-<ticket>`, so match both `<repo>` and `<repo>-*`.

#### `setup-repo.sh` — generate the pin for you

Hand-writing a pin means reading the repo and getting `GATE_CMD` exactly right
(a wrong one silently weakens the whole pipeline). `setup-repo.sh` does that
inspection instead:

```bash
setup-repo.sh <repo-path>            # print the proposed entry + a rationale
                                     #   per field; writes nothing (dry run)
setup-repo.sh <repo-path> --write    # save it into repos.local.sh
setup-repo.sh <repo-path> --verify   # prove INSTALL_CMD + GATE_CMD pass first
setup-repo.sh <repo-path> --ai       # let a model refine the proposal
```

It reads `package.json` scripts, `pyproject.toml` / `uv.lock`,
`.github/workflows`, `.env*` layout, the dev-server port and `.mcp.json` to
compose a complete entry — e.g. a `GATE_CMD` of `npm run type-check && npm test`
rather than a bare `npm test`. It never invents commands: a field it can't
determine is left blank (honestly reported) for runtime auto-detection.

- **`--verify`** runs `INSTALL_CMD` then `GATE_CMD` in a throwaway worktree and
  refuses to `--write` if either fails, so you never pin an entry that doesn't
  actually pass.
- **`--ai`** makes one *read-only* `claude -p` call (model via `SETUP_MODEL`,
  default `sonnet`; set `opus` for a harder look) that can only read the repo,
  validates its JSON, and falls back to the deterministic proposal on any
  failure — it works fine with `claude` absent.
- **`--write`** manages the arms between the `# >>> setup-repo managed >>>`
  markers in `repos.local.sh`; re-running a repo updates its arm in place. A
  hand-written file without those markers is never modified — it prints the
  block for you to paste. New installs get the managed structure from
  `repos.local.sh.example`; existing ones keep working unchanged.

`setup-repo.sh` only *suggests* a `PREFLIGHT_CMD` (e.g. when it spots a
docker-compose DB) — it never writes an untested preflight path.

| Variable | Purpose | Default |
| --- | --- | --- |
| `BASE_BRANCH` | Base branch PRs target | detected: `staging` → `main` → `master` |
| `INSTALL_CMD` | Install deps in a fresh worktree | from lockfile (`npm ci` / `yarn install` / `uv sync`) |
| `GATE_CMD` | The deterministic test gate | from lockfile (`npm test` / `yarn test` / `uv run pytest`) |
| `MCP_CONFIG` | Path to an `.mcp.json` the worker loads | none (skipped if the path is missing) |
| `ENV_SUBDIRS` | Extra dirs besides `.` to copy `.env*` into | none |
| `DEV_CMD` | Dev server command for `preview.sh` | `npm run dev` |
| `PREFLIGHT_CMD` | Env check run *before* the implementer (e.g. test DB up + migrated) | none |
| `DEMO_DEV_CMD` | Dev server command for demo recording (must pin the port) | none |
| `DEMO_PORT` | Port `DEMO_DEV_CMD` binds (storyboard origin + post-demo cleanup) | none |

`GATE_CMD` is the heart of it: it is the objective checkpoint both models are
measured against. Point it at the strictest fast feedback your repo has —
types, lint, and tests.

`PREFLIGHT_CMD` fails a run fast on a broken environment *before* burning an
implementer pass. See
[`examples/preflight-postgres.example.sh`](examples/preflight-postgres.example.sh)
for a Postgres test-DB check.

### Local config files (all gitignored)

`install.sh` seeds each of these from its `*.example` the first time and never
overwrites an existing copy:

- **`repos.local.sh`** — per-repo pins (above).
- **`notify.conf`** — desktop + phone (ntfy) notifications on stage handoffs.
- **`demo.conf.sh`** — object-storage remote for uploading PR demo videos.

### Worker sandbox and MCP denies

The implementer runs under
[`worker-settings.json`](worker-settings.json), which allow-lists the tools it
needs (edit/write, `npm`/`npx`/`yarn`/`node`/`uv`, read-only git, common shell
utilities) and **denies the ones that could do damage**: `git push`,
`git checkout`, `git switch`, and `gh`. The harness itself owns pushing and PR
creation; the worker must never touch remotes or switch branches.

If your worker loads an MCP server (via `MCP_CONFIG`) that exposes destructive
tools — switching a database environment, deploying, deleting records — **add
those tool names to the `deny` list in your installed copy** of
`worker-settings.json`. For example, to forbid an environment switch exposed by
a database MCP:

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

---

## Monitoring

Monitoring is ambient — there's nothing you have to run. Each run writes plain
files under `~/.claude/harness/runs/<RUN-ID>/`, and the tooling reads them:

- **Statusline** — a line per active run in every Claude session on the machine
  (run id, current model, current tool/file, `±lines`, elapsed; refreshes every
  few seconds). A `⏸` segment means `needs_input`.
- **Notifications** — a desktop banner (macOS `osascript`) and/or a phone push
  (ntfy) on every stage handoff. Silence the desktop ones with `HARNESS_NOTIFY=0`.
- **`status.sh`** — one-shot table of all runs; `status.sh <RUN-ID>` prints a
  run's full timeline and result.
- **`feed.log`** — a live, tool-by-tool transcript of the worker
  (`tail -f ~/.claude/harness/runs/<RUN-ID>/feed.log`).
- **`attach.sh <RUN-ID>`** — step into the worker's session interactively, with
  full context (it warns before forking a still-running worker).
- **`preview.sh <RUN-ID>`** — run the dev server inside the worktree to see the
  change live before approving.

The paper trail per run: `brief.md`, `QUESTIONS.md`, `implementer-notes.md`,
`review-notes.md`, `feed.log`, `gate-*.log`, `result.json`, `opus-head`.

---

## Measuring the harness

The pipeline is instrumented so you can move quality claims off anecdote. Every
run records quantitative metrics, and two env knobs turn a normal run into a
controlled **ablation arm** — the same brief run *without* the review stage, or
with a *different* implementer model — so you can measure what each stage buys.

### Ablation knobs (set on the `run-task.sh` invocation)

| Env var | Effect | Default |
| --- | --- | --- |
| `IMPLEMENTER_MODEL` | Model passed to the implementer's `--model`; recorded in `result.json`. Always an explicit model ID — an alias like `opus` silently changes meaning when a new Opus ships. | `claude-opus-5` |
| `IMPLEMENTER_EFFORT` | Effort passed to the implementer's `--effort` (`low`/`medium`/`high`/`xhigh`/`max`). `xhigh` is Anthropic's recommended starting point for agentic coding on Opus 5; drop it where your own runs show quality holds. | `xhigh` |
| `REVIEWER_MODEL` | Model for every `codex exec` call (review, fix rounds, base-sync conflicts); recorded in `result.json`. Pinned here so the pipeline never depends on `~/.codex/config.toml`. | `gpt-5.6-sol` |
| `REVIEWER_EFFORT` | `model_reasoning_effort` for every `codex exec` call. Sol also accepts `max` and the subagent-spawning `ultra` for harder repos — both cost more per pass. | `high` |
| `HARNESS_SKIP_REVIEW` | `1` skips the Codex review stage **and** its fix rounds — the `no_review` arm. The gate still runs (a failing gate still yields `gate_failed`), and base-sync conflict resolution still runs (it is PR mechanics, not quality review). | unset (`full` arm) |

All are **pinned at first dispatch**: the chosen arm, models, and efforts are
written into the run dir on the first invocation and reused verbatim on resume,
so a re-dispatch whose environment differs can't silently switch a run to a
different condition. With **neither** knob set, control flow is identical to before — this
is instrumentation, not a redesign.

```bash
# Baseline arm: same brief, no cross-vendor review, on Sonnet
HARNESS_SKIP_REVIEW=1 IMPLEMENTER_MODEL=sonnet \
  ~/.claude/harness/run-task.sh <TICKET> <repo-path> <branch-name>
```

### Metrics schema (in `result.json`)

Alongside the existing fields, each run now records `arm`
(`full` | `no_review`), `implementer_model`, `implementer_effort`,
`reviewer_model`, `reviewer_effort`, and a `metrics` object — populated
on **every** exit path, partial on early failures (missing fields are
`null`/empty):

| Field | Meaning |
| --- | --- |
| `metrics.wall_seconds` | Wall time this invocation (from the `started` file). |
| `metrics.stage_durations` | Seconds per stage label, summed across resumes. |
| `metrics.gate_rounds` | `[{round, result}]` for each gate run (`1`, `2`, `3`, `base-sync`, …). |
| `metrics.opus_commits` | Commit count `base..opus_head` (the implementer's). |
| `metrics.codex_commits` | Commit count `opus_head..HEAD` (the reviewer's). |
| `metrics.diff` | `{files_changed, insertions, deletions}` vs. base. |
| `metrics.implementer_num_turns` | `num_turns` from the implementer's stream-json result event. |
| `metrics.implementer_usage` | Token `usage` from the same event. |

### `metrics.sh` — tabulate runs

```bash
~/.claude/harness/metrics.sh          # aligned table across all runs
~/.claude/harness/metrics.sh --csv    # same data as CSV for stats tools
```

Columns: run, arm, model, status, gate rounds (e.g. `fail,pass`),
implementer/reviewer commit counts, ± lines, and wall minutes. Runs predating
the instrumentation (no `metrics` object) render with blanks, not errors.

### The public-benchmark experiment

[`bench/DESIGN.md`](bench/DESIGN.md) specifies a **paired** comparison on a
100-instance sample of SWE-bench Verified — arm A (single agent) vs. arm B
(this pipeline) vs. optional arm C (gate-only) — scored by the official
`swebench` harness and analysed with McNemar's test on the discordant pairs.
It is a design document (no adapter code ships here); the ablation knobs it
relies on are the two above.

---

## Security / threat model

This harness runs frontier models **unattended, with the ability to execute
code**, against your repositories. Be clear-eyed about what that means.

- **Arbitrary code execution is the design, not a bug.** The worker installs
  dependencies and runs your gate (`npm ci`, `npm test`, `uv run pytest`, …).
  Any of those can run arbitrary code — that is inherent to building and testing
  software. Only dispatch against repos you trust to build and test on your
  machine.
- **Prompt-injection surface.** Workers are allowed `WebFetch` and `WebSearch`,
  and they read repository contents and dependency code. Any of that text can
  contain instructions crafted to subvert the agent. The deny list
  (`git push`/`checkout`/`switch`, `gh`, plus any destructive MCP tools you add)
  is the containment boundary: even a fully hijacked worker cannot push, switch
  branches, open/merge PRs, or hit a denied MCP tool. The harness — not the
  model — owns every outward-facing action.
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

---

## Repository layout

| Path | What it is |
| --- | --- |
| `run-task.sh` | The pipeline: worktree → implement → gate → review → PR |
| `sync-pr.sh` | Re-merge the latest base into an already-pushed PR branch on conflict |
| `repos.conf.sh` | Generic per-repo detection + sources your `repos.local.sh` |
| `setup-repo.sh` | Inspect a repo and propose/write its pinned `repos.local.sh` entry |
| `worker-settings.json` | The implementer's tool allow/deny list |
| `setup-ai-settings.json` | Read-only tool sandbox for `setup-repo.sh --ai` |
| `brief-template.md` | The contract the planner fills in per task |
| `skills/dispatch/SKILL.md` | The planner protocol (a Claude Code skill) |
| `status.sh` `attach.sh` `preview.sh` `cleanup.sh` `station.sh` | Monitoring & lifecycle helpers |
| `metrics.sh` | Tabulate per-run metrics from `result.json` (table / `--csv`) |
| `demo-auth.sh` `auth-capture.py` | One-time login capture for demo recordings |
| `gate.sh` | This repo's own CI gate (`shellcheck` + `bash -n` on every script) |
| `install.sh` | Idempotent installer |
| `examples/` | Copyable templates (e.g. the Postgres preflight) |
| `bench/DESIGN.md` | Paired public-benchmark experiment design (SWE-bench Verified) |
| `FLOW.md` / `harness-flow.html` | Pipeline diagrams |

---

## Development

This repo's own test gate is [`gate.sh`](gate.sh): it runs `bash -n` and
`shellcheck -x -S warning` over every shipped shell script. Run it before
committing:

```bash
bash gate.sh
```

CI runs the same gate on Linux for every push and pull request.

## License

[MIT](LICENSE) © 2026 Angel Sole
