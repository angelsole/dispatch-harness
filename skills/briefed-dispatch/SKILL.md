---
name: briefed-dispatch
description: Dispatch a well-detailed ticket through the multi-model harness with no approval pause — the ticket itself is the approved artefact. The orchestrator (you) researches, writes one brief per repo the ticket touches (frontend + backend = two runs, dispatched together), launches every run immediately, answers the workers' questions itself where the ticket or the codebase answers them, and when all PRs are ready it attaches them to the ticket and moves it to In Review. Use when the user says /briefed-dispatch <ticket>, "briefed dispatch", or asks to dispatch a ticket without brief approval. For free-form work or thin tickets, use /dispatch instead.
---

# Briefed dispatch — ticket in, PRs out

Same pipeline as `/dispatch`, one contract change: **the ticket is the
approval.** There is no brief sign-off pause, and there is no "which repo?"
question halfway through. The user's involvement is meant to be two moments:
they say the ticket ID, and they read the PRs on the ticket.

You are still the **planner/architect** stage. Your token budget is expensive —
spend it on research, the briefs, and the verdicts. Never implement, never read
worker logs line-by-line, never stream worker output.

Harness files live in `~/.claude/harness/`. Runs live in
`~/.claude/harness/runs/<RUN-ID>/`. Where this file is silent (document
attachments, monitoring, attach/resume, post-PR conflicts, worker settings),
`~/.claude/skills/dispatch/SKILL.md` applies verbatim.

## 1. Scope — a ticket, and a fitness check

The argument must be an **existing ticket ID**. Free-form descriptions go to
`/dispatch` — its approval step exists precisely because there is no reviewed
ticket behind the words.

Fetch the ticket via the issue-tracker MCP (e.g. Linear, Jira). Then judge it
honestly: can you write a brief from it without inventing product decisions? A
detailed ticket names the behavior, the surfaces it touches, and what done
means. If it does not — say what is missing in two or three lines and offer
`/dispatch` instead. One early refusal is cheaper than an overnight run built
on a guess.

## 2. Repos — all of them, decided now

Determine **every** repo the ticket touches: read the ticket's text, then
verify against the code (Explore subagents). A ticket that changes an API and
the screen that consumes it is **one dispatch producing two PRs** — never
dispatch one repo and come back to ask about the other.

- Resolve each repo to its pinned entry in `repos.local.sh`; suggest
  `setup-repo.sh <repo> --write` first when an entry is missing.
- Run IDs: single repo → the ticket ID. Multiple repos → `<TICKET>-<suffix>`
  per repo (e.g. `PROJ-123-api`, `PROJ-123-web`) — letters, digits, dot, dash,
  underscore only, since the ID becomes a run-dir name.

## 3. Briefs — one per repo, decisions written down

Research each repo as `/dispatch` prescribes (Explore subagents for the
codebase, the repo's CLAUDE.md yourself), then write each run's brief to
`~/.claude/harness/runs/<RUN-ID>/brief.md` following
`~/.claude/harness/brief-template.md`.

Two rules specific to this skill:

- **Cross-repo contract.** When runs span repos, the workers never meet — the
  briefs are their only handshake. Decide the interface yourself (routes,
  payload shapes, field names, error semantics) and write the *identical*
  contract section into every brief that touches it.
- **Decisions taken.** What the ticket leaves genuinely open, you close as the
  architect and record in a `## Decisions taken` section of the brief — the
  premise of this skill is that a `needs_input` stop, not a wrong guess on
  conventions, is the failure mode to avoid. Only a product/priority fork that
  could waste the whole run goes to the user before dispatch (one
  AskUserQuestion, recommendation first); everything answerable from the
  ticket, the codebase, or team convention is yours to answer.

## 4. Dispatch — every run, immediately

No pause. Launch each run in the background (never foreground), all repos in
parallel — worktrees are separate:

```bash
~/.claude/harness/run-task.sh <RUN-ID> <repo-path> <branch-name>
```

Tell the user what was dispatched — one line per run: run ID, repo, branch —
and how to watch (statusline if wired, else
`~/.claude/harness/status.sh --watch`). Do not poll; you are notified when
each run exits.

## 5. Verdicts — per run, without the user where possible

Triage each finished run exactly as `/dispatch`'s Verdict section, with the
autonomy dialed up:

- **ready** — verify against the brief (implementer/review notes, `git diff
  --stat`, then only risky files). If it satisfies the brief: `gh pr ready
  <pr_url>` and `cleanup.sh <RUN-ID>`. If not: sharpen the brief and
  re-dispatch — the worktree is reused.
- **needs_input** — read `QUESTIONS.md` and answer everything the ticket, your
  research, or repo convention answers; append `## Answers` to the brief and
  re-dispatch the same command (the worker resumes, it does not start over).
  Only a genuine product fork reaches the user.
- **rejected / gate_failed / other failures** — tail the relevant log, fix the
  environment or the brief, re-dispatch.

Budget: **two re-dispatches per run** without user input. After that, stop and
escalate with a one-paragraph diagnosis — a run that keeps bouncing is telling
you the ticket was not as detailed as it looked.

## 6. Close the loop on the ticket

When **every** run's PR is ready:

1. Put the PR links on the ticket — as attachments if the issue-tracker MCP
   supports it, otherwise one comment listing `repo — PR URL` per run. Never
   with AI attribution.
2. Move the ticket to the team's **In Review** state (fetch the team's actual
   status names rather than assuming the label).
3. Summarize for the user: per run — repo, PR, which model did what, anything
   the reviewer flagged but left alone.

If some runs succeeded and one is stuck at the escalation budget: put the
finished PR links on the ticket with a comment naming what is still missing,
**leave the ticket state alone**, and escalate the stuck run. A ticket in In
Review with half its PRs is a lie the reviewer discovers later.

## Invariants

- The ticket is the approval — never pause to have a brief signed off.
- All repos a ticket touches are dispatched together, or the fitness check
  fails loudly — never one now and a question later.
- Never implement in this session; the sub-billed workers do it.
- Workers run with prod-env MCP tools denied; do not weaken
  `~/.claude/harness/worker-settings.json` without asking the user.
- No AI attribution anywhere in commits, PRs, or ticket comments.
- The ticket moves to In Review only when every run's PR is ready.
- Cleanup policy as `/dispatch`: worktrees of rejected/failed/needs_input runs
  are kept for iteration; `cleanup.sh` runs when a PR is promoted.
