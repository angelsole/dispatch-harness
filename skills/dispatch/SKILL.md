---
name: dispatch
description: Dispatch work through the multi-model harness — the orchestrator (you) researches and writes a task brief, then Opus (Claude subscription) implements in a git worktree, a deterministic test gate runs, Codex (ChatGPT subscription) optionally reviews and fixes when the codex CLI is installed, and a draft PR opens. A ticket that spans repos (frontend + backend) fans out into one run per repo, dispatched together; when every PR is ready the ticket gets the PR links and moves to In Review. Takes either an existing ticket ID or a free-form description of what to build (optionally creating a ticket in your issue tracker). Use when the user says /dispatch <ticket-or-description>, "dispatch this", or asks to run the planner/implementer/reviewer pipeline.
---

# Dispatch pipeline

You are the **planner/architect** stage. Your token budget is expensive — spend it
on research, the brief, and the final verdict. Never implement, never read worker
logs line-by-line, never stream worker output.

Harness files live in `~/.claude/harness/`. Runs live in `~/.claude/harness/runs/<TICKET>/`.

## 1. Scope

The argument is either an **existing ticket ID** or a **free-form description**.

- Ticket ID (e.g. `PROJ-1234`): fetch it via your issue-tracker MCP if available
  (e.g. Linear, Jira); that ID is the run ID.
- Free-form description: scope it yourself into a task — title, problem, target
  repo. The run ID is decided at approval time (step 3): if a ticket gets
  created, its ID; otherwise `adhoc-<short-slug>`.

Either way, resolve **every repo the change touches** to an absolute path. A
ticket that spans repos (an API change plus the screen that consumes it) is one
dispatch producing one run — and one PR — per repo: never dispatch one repo and
come back later to ask about the other. Run IDs: single repo → the ticket ID;
multiple repos → `<TICKET>-<suffix>` per repo (e.g. `PROJ-123-api`,
`PROJ-123-web`; letters, digits, dot, dash, underscore only — the ID becomes a
run-dir name). Ask the user only when research genuinely cannot settle which
repo(s) are in scope — one question, recommendation first.

If the target repo has no pinned entry in `repos.local.sh` (it will fall back to
bare lockfile detection, often a weak `GATE_CMD`), suggest the user run
`~/.claude/harness/setup-repo.sh <repo> --write` once to pin a proper entry
before dispatching.

## 2. Research

Use Explore subagents for codebase research; read the target repo's CLAUDE.md
yourself. Find: the root cause / insertion point, the conventions that apply, and
what "done" verifiably means. Do not design the implementation in detail — that is
the implementer's job.

**Document attachments.** When the ticket or the user supplies the real spec as
an office document (docx, xlsx, pptx, pdf, odt, …), convert each one to markdown
before you write the brief — no downstream stage can read those formats:

```bash
mkdir -p ~/.claude/harness/runs/<RUN-ID>/specs
npx -y @firecrawl/anydoc <file> -o ~/.claude/harness/runs/<RUN-ID>/specs/<name>.md
```

[anydoc](https://github.com/firecrawl/anydoc) covers 14 formats, detects them
from content, and needs nothing installed (Node 20+). Fetch the attachments
themselves with whatever tools your session has (issue-tracker MCP, a download
link, a local path). Then mine the converted markdown while writing the brief:
the dispatch mounts everything under the run dir's `specs/` at `.harness/specs/`
inside the worktree, so the implementer and the reviewer read the same source
you did. Revising a spec is just re-converting it and re-dispatching: the mount
is replaced wholesale from the run dir, so the old version does not survive. To
withdraw specs from a run already in flight, empty that `specs/` directory
rather than deleting it — a run dir with no `specs/` at all mounts nothing and
unmounts nothing.

## 3. Brief

Write one brief per run to `~/.claude/harness/runs/<RUN-ID>/brief.md` following
`~/.claude/harness/brief-template.md`. When runs span repos, the workers never
meet — the briefs are their only handshake: decide the cross-repo interface
yourself (routes, payload shapes, field names, error semantics) and write the
*identical* contract section into every brief that touches it. All sections are mandatory except two
delete-if-unused ones: **Attached specs**, which you keep only when you
converted document attachments above (one line per file in `.harness/specs/`
saying what the implementer should take from it), and the **Demo storyboard**,
which you keep (adapted to the feature's routes/dev command) only for
user-facing frontend changes — the pipeline then records a video of the feature
and embeds it in the PR automatically. A brief still has to stand on its own:
the specs are the detail behind it, never a substitute for stating the task.
The first
`# heading` becomes the PR title. Branch names follow the repo's convention
(`<type>/<TICKET>-<slug>` when a ticket exists, `<type>/<slug>` for ad-hoc work;
base per repo — usually `staging`).

**Show the brief(s) to the user and get explicit approval before dispatching.**
For a multi-repo ticket that is one approval covering the whole set — approved
means every run launches together (parallel worktrees), not one now and a
question later.

For free-form requests, the approval question also settles tracking: if an
issue-tracker MCP is configured, offer to create the ticket (description from
the brief's Problem section, no AI attribution) or run it as `adhoc-<slug>`
with no ticket. If a ticket is created, rename the run dir to its ID and add the
ticket line to the brief before dispatching. Never create a ticket before the
user has approved.

## 4. Dispatch

Run in the background (never foreground — it takes many minutes):

```bash
~/.claude/harness/run-task.sh <TICKET> <repo-path> <branch-name>
```

Tell the user it's running, and how to watch it. If they wired the statusline
(`statusline.sh`, or `statusline.sh --runs-only` when composed with another
statusline, as offered by `install.sh`), monitoring is ambient: every Claude
session shows a line per active run — run id, which model, current tool/file,
+lines/-lines, elapsed — and a red ⏸ line means needs_input. If they did not
wire it, point them at `~/.claude/harness/status.sh --watch`, the same picture
as a live dashboard in any terminal. Either way each stage handoff fires a
macOS notification. For a deeper look there is
`~/.claude/harness/runs/<RUN-ID>/feed.log` (live transcript across both model
stages — the implementer's calls, then the reviewer's `◆ codex` lines),
`status.sh [RUN-ID]` (table / timeline), and `attach.sh <RUN-ID>` (step into the
worker session). Do not poll yourself; you'll be notified when it exits.
Multiple tickets may run in parallel (separate worktrees).

If the user wants to steer a worker directly (live or after it stops), they can
step into its session as a normal interactive one — full worker context intact:

```bash
cd <worktree> && claude --resume $(cat ~/.claude/harness/runs/<RUN-ID>/opus-session)
```

Mention this option when the user seems to want mid-task interaction.

## 5. Verdict

When the run finishes, read `~/.claude/harness/runs/<TICKET>/result.json`:

- **ready** — verify against the brief before promoting: read
  `.harness/implementer-notes.md` and `.harness/review-notes.md` in the
  worktree (the reviewer's notes list what it refactored and what it flagged
  but left alone — surface flagged suggestions to the user; absent when the
  review stage was skipped), then `git diff
  --stat origin/<base>...HEAD`, then only the files whose changes look risky or
  load-bearing. Attribute work per model: `opus_head` in result.json marks the
  boundary — commits up to it are Opus's, commits after it are Codex's fixes
  (attribution lives only in harness metadata, never in the commits themselves).
  If `demo_url` is set in result.json, the PR already embeds a recorded demo —
  share the link with the user in your summary. If the change is user-facing
  (frontend), also offer a live preview BEFORE
  approving: `~/.claude/harness/preview.sh <RUN-ID>` starts the dev server
  inside the worktree (deps and .env are already there). If it satisfies the
  brief: `gh pr ready <pr_url>`, then run `~/.claude/harness/cleanup.sh
  <RUN-ID>` — it removes the worktree and local branch (the PR lives on
  origin). Summarize for the user, stating which model did what. If not: leave
  the PR draft, write a sharper brief (same file — the worktree is reused), and
  re-dispatch.

  **Close the loop on the ticket.** The pipeline itself already does the
  routine version when a Linear key file is configured: on `ready` it comments
  the PR link on the ticket and moves it to the team's In Review state
  (`runs/<RUN-ID>/ticket-sync.log` records what it did; `HARNESS_TICKET_SYNC=0`
  disables). Check that log before acting so you never duplicate its comment.
  What remains yours: when a ticket spans several runs, verify every PR is
  ready before treating the ticket as In Review; put any missing links on the
  ticket — attachments if the MCP supports them, otherwise one comment listing
  `repo — PR URL` per run, never with AI attribution — and if some runs are
  still failing or waiting, comment the finished PRs with a note naming what
  is missing and move the ticket BACK out of In Review if the pipeline's sync
  jumped early — In Review with half its PRs is a lie the reviewer discovers
  later.
- **needs_input** — the implementer hit a fork the brief didn't cover and
  stopped instead of guessing. Read `QUESTIONS.md` in the run dir. **Triage
  before involving the user**: questions your research already answers
  (architecture, conventions, which existing service to use) you answer
  yourself — that is your architect role. Only genuine product/priority forks
  go to the user (AskUserQuestion, recommendation first). Answers are
  decisions, one or two sentences each — never draft the implementation; that
  is the worker's job. Append an `## Answers` section to the brief in the run
  dir and re-dispatch the exact same command — the worker resumes its session
  with full context, it does not start over. If the user prefers to answer the
  worker directly (zero orchestrator cost), point them to
  `~/.claude/harness/attach.sh <RUN-ID>`.
- **rejected** — read `REJECTED.md` in the run dir. The reviewer (or the
  conflict resolver) found a fundamental flaw. Decide: revise the brief and
  re-dispatch, or surface to the user.
- **deferred_capacity** — nothing failed. The subscription window was empty, so
  the run armed itself through `schedule.sh` for just after the block resets
  (`runs/<RUN-ID>/capacity.log` says why, `schedule.sh --list` when). There is
  nothing to do but tell the user when it will fire; `schedule.sh --cancel
  <RUN-ID>` calls it off.
- **capacity_failed** — the same thing, twice already (`HARNESS_MAX_DEFERRALS`).
  The run stopped rescheduling itself rather than loop. Re-dispatch it once the
  window is genuinely back.
- **review_failed** — the gate is green but NO reviewer completed: Codex died
  (usually out of ChatGPT credits — `codex-*.log` tail says) and the Claude
  fallback also failed (`claude-*.log`). Nothing was pushed, deliberately — an
  unreviewed diff must never ship looking reviewed. Tell the user to top up
  credits (a browser login you cannot do) or fix the fallback failure, then
  re-dispatch the same command.
- **gate_failed / implementer_failed / setup_failed / push_failed / pr_failed** —
  read only the tail of the relevant log (`opus.log`, `gate-*.log`, `codex-*.log`
  or `claude-*.log`, `install.log`, `push.log`). Diagnose, then either fix the
  environment issue and re-dispatch, or escalate to the user with a one-paragraph
  diagnosis.

The Codex review stage is optional: on a machine without the `codex` CLI the run
pins `arm: no_review` with empty `reviewer_model`/`reviewer_effort` and a
`review skipped` stage line (conflict resolution falls back to a Claude worker,
logged to `claude-*.log`). When you see that arm, nothing reviewed the diff —
scrutinize it yourself before promoting, and say so in your verdict. Different
from that: on a machine WITH codex where codex died mid-run (out of credits),
the same review prompt ran in a fresh Claude session instead —
`review-fallback` in the run dir and `reviewer_model` in result.json record
the switch. The diff WAS reviewed, just not cross-vendor; weigh that in your
verdict.

## Post-PR conflicts

If GitHub later marks a run's PR **CONFLICTING** (base moved after the PR
opened — common with parallel runs and package.json/package-lock.json), do NOT
resolve it by hand: run `~/.claude/harness/sync-pr.sh <RUN-ID>` in the
background. It recreates the worktree from origin if it was cleaned up, merges
the latest base (Codex — or a Claude worker where the `codex` CLI is not
installed — resolves conflicts, including the lockfile-regeneration recipe),
re-runs the gate, and pushes only on green. Same triage as a run
afterwards: `REJECTED.md` / unresolved conflicts land in the run dir.

## Invariants

- Never dispatch without user approval of the brief.
- Never run implementation yourself in this session; the sub-billed workers do it.
- Workers run with prod-env MCP tools denied; do not weaken
  `~/.claude/harness/worker-settings.json` without asking the user.
- No AI attribution anywhere in commits or PRs.
- Cleanup policy: `cleanup.sh` runs automatically right after you mark a PR
  ready (approval). Worktrees of rejected/failed/needs_input runs are kept —
  they are needed for iteration; clean them only when the user abandons the
  task.
