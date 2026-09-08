---
name: dispatch
description: Research and delegate a coding task to the dispatch harness, then assess its reviewed result. Use for $dispatch, /dispatch, a request to dispatch a task, or to reconnect to a dispatch run. Supports local execution and explicitly selected remote stations.
---

# Dispatch

You are the planner. Research the task, write its brief, submit it, and assess
the result. The runner owns implementation, gates, independent review, process
lifetime, and checkpoint recovery. Use the user's existing authorization.

`dispatch` is installed in `~/.local/bin`. If it is not on PATH, use
`$HARNESS_DIR/dispatch.sh` (default `~/.claude/harness/dispatch.sh`). Run records
live at `$HARNESS_DIR/runs/<ID>/`; credentials never belong in a brief or record.

## 1. Scope and research

Accept a description or an existing ticket. A tracker and a Mini are optional.
Use the current repository locally unless the user selected a remote host.
Inside a Mini station, run locally on that Mini and keep its selected account.
Never choose another person's account automatically or renew a peer's login
as yourself. `dispatch stations --on mini` reports configured login status,
not remaining credits. `--owner NAME` explicitly selects a saved account.

Read applicable AGENTS.md and CLAUDE.md, relevant code, and the reproduction.
Use `lessons.sh --show <repo>` for known defects relevant to this scope. Decide
which repos are involved before launching; each gets a separate run and branch.
For an unconfigured repository, `dispatch init --repo <repo>` detects and saves
its settings. Check that its proposed test gate actually verifies this project.

For a free-text request, ask once whether to create a tracker ticket (Linear
when available) or run ad hoc before submitting. An existing ticket or an
explicit tracking choice already answers this question. Hands-off mode skips
tool permission prompts; it does not choose tracking. If the tracker is
unavailable, explain that and confirm an ad-hoc run instead of silently falling
back. For a new ticket, follow the placement rules in the detailed protocol.

For document attachments, multi-repo interface contracts, ticket creation,
visual work, and post-PR repairs, read the relevant part of
[the detailed protocol](references/pipeline.md). Do not load it for an ordinary
task unless its extra procedure applies.

## 2. Brief

Write a brief using `$HARNESS_DIR/brief-template.md`. State the problem,
acceptance criteria, reproduction, interface contract, edit locations, and
decision points. Record known decisions; reserve questions for unresolved
product choices or irreversible actions. An omitted, ordinary reversible fork
does not itself require a question; an undeclared irreversible action still
stops the run. Do not prescribe the implementation
beyond what correctness requires. Show the scope for approval only if it has
not already been authorized. Combine any needed scope approval with the tracking
question; do not ask again after the user has chosen an ad-hoc run.

For user-facing frontend changes, include the template's **Demo storyboard**:
a short interaction with a visible success-state wait and screenshots, plus a
video when motion helps review. Establish the app's dev command, free port,
and demo authentication during research. Use data suitable for the PR audience.
If evidence cannot be captured, report the reason; do not claim a visual check.

## 3. Submit

```bash
dispatch run --repo /path/to/repo --brief /path/to/brief.md --json
```

The runner generates a run ID and branch. Supply `--id` and `--branch` when
tracking or repository conventions require specific names. Use `--no-publish`
when the user wants a reviewed local branch without a push or draft PR.

From a laptop, remote execution uses the same command with `--on mini`, an
explicit `--owner NAME` if borrowing a saved station account, and a remote
`--repo /path/to/repo`. The brief is transferred through SSH. For attachments,
prepare their specs on the execution host as the detailed protocol describes.
The local brief remains local; the task record belongs to the execution host.

Submission returns immediately. Do not add another background shell or tmux
layer. The task survives the planner closing. Report its ID and execution host.

## 4. Observe and recover

```bash
dispatch status <ID> --json
dispatch wait <ID> --timeout 60 --json
dispatch resume <ID> --json
```

Use the same `--on` host for remote records. `wait` returns a snapshot after its
timeout (exit 124 while running); use a host completion event when available.
Avoid continuous log polling. Desktop notifications do not resume an agent turn.

When the user says “resume dispatch”, first read `status`, the result, and the
brief to recover conversation context. `dispatch resume` restarts a stopped
runner; it only reports status for a live or finished run. It retains the saved
account and reuses stages only when their checkpoint inputs still match.

- `ready`: read the brief, implementer/review notes, and relevant diff before
  reporting the draft PR. For frontend work, also inspect `result.evidence`, its
  capture status, and the media; report missing capture/upload explicitly.
  Promote or clean up only within the user's authorization.
- `ready_local`: assess the same evidence and report the worktree; keep it.
- `waiting_for_auth` / `blocked`: report the saved record's reason and repair
  action. The task is saved. Authentication requires the account holder.
- `needs_input`: read QUESTIONS.md, answer from available context where possible,
  append decisions to the brief, then resume. Ask only for unresolved user choices.
- `deferred_capacity`: report its scheduled retry; do not launch a competing one.
- `rejected` / `visual_failed`: read the rejection or visual evidence before
  deciding whether the brief needs revision. Do not change a visual threshold.
- `review_failed`: no adequate review evidence; diagnose the failed review tier.
- `gate_failed`, `implementer_failed`, `setup_failed`, `push_failed`, `pr_failed`,
  `capacity_failed`, `dirty_worktree_failed`, `driver_failed`, `interrupted`:
  inspect the relevant log tail, fix the cause within scope, then resume.

Independent review is required by the normal workflow. A `claude_only` run uses
a fresh Claude reviewer. `failed_silent` means no review evidence and must hold.
Never label the explicit `no_review` experiment as reviewed. Do not restart a
finished run just to reconnect; `HARNESS_REDISPATCH=1` is an explicit operator
override for revised, already-shipped work, described in the detailed protocol.
