# Operations

Running the harness when nobody is at the desk: arming a run for later, what a
run does when the subscription window empties, how attempts are counted, the
overnight Quartermaster, ticket sync, mirroring to another machine's wall, and
what the review stage does when a reviewer dies mid-run.

The pipeline's `HARNESS_*` tables are in [the reference](reference.md); the
Quartermaster's `QM_*` variables stay beside its operational narrative below
and are repeated in the reference for lookup. The incidents that shaped these
behaviours are in [the design notes](design-notes.md).

## Local tasks and recovery

`dispatch` starts a local Astra planner in the current directory. It uses the
existing Codex login, requires no tmux, and preserves the CLI's configured
sandbox and approval settings. Choose the orchestrator for each conversation:

```bash
dispatch --planner codex   # Astra in Codex
dispatch --planner claude  # Fable in Claude Code
```

Both commands start with the same harness planner instructions, even without a
task argument. The planner asks for a task, handles routine repository setup,
follows the run, and assesses its reviewed output. `--model` remains an explicit
override; `DISPATCH_MODEL` can set an operator default. Switching opens a separate
conversation in the selected CLI; saved harness
runs remain accessible through `dispatch status`. The worker and reviewer
keep their repository settings regardless of which planner you choose.

For unattended orchestration, use `dispatch --hands-off "task description"`,
optionally with `--planner claude`. This is an explicit launch
choice: Claude Code gets `--dangerously-skip-permissions`; Codex gets
`--dangerously-bypass-approvals-and-sandbox`, disabling both permission prompts
and the Codex sandbox. The launch banner shows the selected mode. Existing
CLI settings apply when the flag is absent. It does not change background
worker/reviewer permissions, skip gates, supply missing logins, or authorize
work outside the request. `run`, `resume`, and diagnostic commands reject the
flag because they do not launch a planner conversation.

Tracking remains a user choice in hands-off mode. For a free-text task, the
planner asks once whether to create a tracker ticket or run ad hoc unless the
request already specifies that choice. A supplied ticket is reused. A missing
tracker connection is reported before offering an ad-hoc fallback.

The local launcher preserves unset provider config variables. This matters
for Claude: native configuration is `~/.claude.json`, while explicitly setting
`CLAUDE_CONFIG_DIR=~/.claude` selects `~/.claude/.claude.json`. Forcing that
seemingly equivalent path can produce another onboarding/login flow and hide
project MCP connections. A station never sets it: a station runs as the seat's
own OS account, whose native configuration is the right one.
Saved tasks suggest `dispatch login <provider> --for-run <ID>` for repair.
That command runs in the task's seat on its execution host; a task owned by
another seat names the ssh command instead, because its login belongs to that
seat. Add `--on mini`
for a remote task; the context is resolved on the Mini.

`dispatch doctor` checks only the selected planner; `--pipeline --repo <repo>`
also checks the dependencies needed to start a task. Neither performs a paid
model request or proves remaining credits.

The planner runs `dispatch init` for an unconfigured repository. It saves detected
settings through the existing setup tool. The planner checks the printed gate
against the project; repository-specific services still need
their existing preflight configuration. The engine currently expects an origin
remote even for a local-only branch (a local Git remote also works).

`dispatch run --brief <file>` saves a durable request, generates a branch and
run ID, then starts an independent process session. It accepts `--id`,
`--branch`, `--repo`, and `--no-publish`. Closing the planner, terminal, or SSH
connection does not stop the task. Submission is atomic per run ID; a second
client cannot start another copy. The CLI's driver output is `launcher.log`.

`dispatch status [ID] --json` is the conversation recovery interface. It reports
state, stage, selected account, host, worktree, result, and any required action.
`dispatch wait ID --timeout 60 --json` waits for a terminal state or returns the
current snapshot with exit 124. A finished draft PR is `ready`; a reviewed
local branch is `ready_local`. A stopped process is reported as interrupted,
not left with an indefinitely growing stage timer.

For browser-based recovery, `dispatch ui` prints a private local console link.
It shows questions, saves answers to the brief, and offers the applicable resume
or frontend-evidence action. Accounts stay pinned to the saved task. See
[Local recovery console](wall.md#local-recovery-console) for sign-in handoffs,
checkpoint behavior, and the boundary between local controls and shared monitoring.

`dispatch resume ID` keeps the saved account configuration and restarts a
stopped task. On a finished run with missing frontend evidence, it selects
capture or upload-only recovery automatically. A captured local-only run and a
run with published evidence are already complete. A `needs_input` run needs
answers appended to its brief first;
`--brief <file>` can supply an updated brief. Merely reconnecting to a live or
finished run never starts another coding attempt. Scheduled capacity deferrals should
be allowed to fire through their existing scheduler.

The runner writes checkpoints after implementation, the initial passing gate,
and a successful review plus final gate. Reuse requires the same clean commit,
base commit, brief/specs, effective gate/configuration, account paths, and
runtime code; final review evidence must still match. Changed inputs run the
normal pipeline. Setup and service preflights still execute. Optional profile
stages conservatively run again; they do not reuse these checkpoints. This
preserves their outcome policy. A checkpoint does not assert that external
services can never change between runs.

Publishing tasks check GitHub login after review. A missing login produces a
saved `waiting_for_auth` state and a repair command. After the account holder
signs in, `dispatch resume ID` can finish publication using the validated work.
`--no-publish` ends with a reviewed local worktree and performs no push or PR.
It is pinned for that run; a finished local-only run is not auto-published by
resuming it.

For remote execution add `--on <ssh-alias>`. The CLI sends the brief through
SSH stdin, never through an interpolated shell command. `--repo` is a remote
path; if omitted for `run`/`init`, the default is `~/Projects/<local-repo-name>`
on the target. The repository must already exist there. Converted attachment
specs must already be in the remote run's specs directory; only the brief is
transferred by this command. Run `status`, `wait`, and `resume` on the same host.
By default the remote command reads the shared runtime pointer written by
`station.sh setup` at `~/.claude/harness-dir`; it never assumes the runtime is
installed in the SSH user's home. `--remote-harness /absolute/path` selects a
custom remote installation or bootstraps access before setup has written that
pointer.

## Shared stations and seat selection

A station is a planner attached to a seat, and a seat is an OS user on the
execution machine. Connecting to the Mini and running work under a teammate's
subscriptions while that person is away means SSHing in as them — there is no
way to do it from your own account, by design:

```bash
dispatch stations --on mini        # which seats have logins configured
dispatch station --on teammate@mini
```

`dispatch station --on mini` opens or reconnects your own planner on the Mini;
the SSH user is the identity there. `--hands-off` opens a hands-off planner in
a separate tmux session from the corresponding ordinary station, and repeating
the same command — including the flag — reconnects it. Direct SSH entry through
`station.sh start` or `station.sh setup` accepts the flag too; doctor and login
do not. Choosing hands-off does not edit another user's default settings.

Use `dispatch run --on mini` to send a prepared brief from a local planner to
your own seat on the Mini. The service account — the one that owns the shared
runtime and runs the wall — may additionally pass `--owner <seat>` to
`dispatch run`: the run records that seat and executes as it, which is how the
Linear bridge and the Quartermaster dispatch for the crew. For everybody else
`--owner` names an account they cannot act for, and is refused with the SSH
command to use instead. The GitHub login in the seat's own `~/.config/gh`
determines the PR identity; ambient API tokens never cross the account
boundary. The selected seat is stored with the run and restored on resume.
No provider credentials are copied to the laptop or saved in the request.

`stations` lists the seats named by the machine's `linear-dispatch.json`
accounts mapping — or `QM_CREW` when no mapping is installed — and reports each
one's login state by asking from inside that account. It checks configured
logins, not entitlement or remaining quota. It never selects a peer
automatically or logs anyone out, and renewing an expired login is the account
holder's to do, over SSH.

## Station setup and login repair

`station.sh` launches GPT-6 Astra in Codex by default. The existing worker,
reviewer, spec critic and overnight Quartermaster keep their own providers;
changing the interactive planner does not change those stages. The operator
installs the current checkout once per execution host with
`./install.sh --no-statusline`: it installs
the shared planner protocols for both Claude Code and Codex, without changing
either CLI's model configuration. The installed runtime is shared with the
whole crew through the machine's dispatch group; the one-time group and
sudoers setup for that lives in
[Migration: seats become OS users](#migration-seats-become-os-users).

**Seat onboarding: one command.** A seat is created by the operator (an OS
user account; see the migration notes). From then on the person owns their own
logins, and their laptop needs neither the harness nor the model CLIs. With
SSH access to `mini` already configured, they run:

```bash
ssh -t you@mini '/Users/dispatchsvc/.claude/harness/station.sh setup'
```

`setup` acts for whoever is logged in. It checks the shared tools, stores a
Claude token (step 1), walks the GitHub and Codex device logins (steps 2 and
3), links the planner skills into `~/.claude` (step 4), and writes one
`HARNESS_DIR` line into the shell profile plus a private runtime pointer for
non-login SSH commands (step 5), then runs `doctor`. Every
step is idempotent: an existing login is kept, a skipped or cancelled login
stops setup with the completed ones intact, a repeated run replaces the single
profile line instead of stacking another, and re-running continues where it
left off. It never writes a person's name into the shared machine's
environment. Use `login <provider>` below to explicitly renew credentials
that are cached but rejected when the CLI starts.

Direct launches and troubleshooting use the same script as your own login:

```bash
"$HARNESS_DIR/station.sh" --dir /path/to/repos
dispatch station --on you@mini --dir /remote/path/to/repos --planner claude
```

`mini` is an SSH alias you configure normally; the user in `you@mini` is the
seat there, and `--host you@mini` reaches the same commands from a laptop. The
wrapper supplies SSH keepalives and the usual user/Homebrew binary paths; it
does not require a login shell or a GUI session to find the CLIs. `--dir`
refers to a path on the machine running the planner. Omit it to use that
machine's `DISPATCH_STATION_DIR`, or its home directory.
`--remote-harness /absolute/path` selects a custom install on the remote host;
a local `HARNESS_DIR` is never sent to that host.

**Identity.** The station acts for the OS user that runs it. Credentials live
in that user's own `~/.claude`, `~/.codex` and `~/.config/gh`; no config
directory is re-exported, and ambient provider API keys and GitHub tokens are
cleared before the planner starts, including in an existing tmux server. The
old `--owner` selected a credentials directory under a shared account — that
model is gone, so the flag is refused with the SSH command that reaches the
named person's station (`ssh <name>@<host>`).

**First login and renewal.** Run the command for the provider that needs
repair, as the seat:

```bash
dispatch login codex --on you@mini
dispatch login claude --on you@mini
dispatch login gh --on you@mini
```

Codex uses `codex login --device-auth`. Enable device login in your ChatGPT
security settings or workspace permissions, then open the printed link in your
own browser and enter its code. If device login is unavailable, `--browser`
uses the normal callback flow: open a separate `ssh -N -L 1455:localhost:1455 mini`
tunnel first, then run `station.sh login codex --host you@mini --browser`.
Claude over SSH is a token file first: run `claude setup-token` on any machine
with a browser, paste it when `login claude` asks (it is not echoed), and it
lands in `~/.claude/oauth-token` mode 600 — the station, `seat_exec` and every
script that sources the harness library export it as `CLAUDE_CODE_OAUTH_TOKEN`.
`login claude --browser` uses the subscription browser flow instead. GitHub
uses its device flow for github.com, or `--browser` for the web flow.
Credentials remain in the seat's own home. See the
[official Codex authentication guide](https://learn.chatgpt.com/docs/auth).

**Health.** `station.sh doctor` (as the seat, or `--host you@mini` from a
laptop) checks the binaries, harness/skill installation, working directory and
the three account logins. It prints the repair command for a missing login and
exits nonzero if a check fails; it does not log credential contents. Login
status confirms configured credentials; model entitlement and token refresh
are checked by Codex when it starts. `doctor --repo /remote/path/to/repo` also
checks origin read access and runs that repo's configured `PREFLIGHT_CMD` with
a 30-second cap. That command can start services if the repo pin says to; the
doctor runs no install or test gate and does not push a branch.

**Reconnect.** Detach with your tmux prefix, then **d** (the default prefix is
**Ctrl-b**). Run the same station command to
reattach after closing SSH. Each seat, planner and model has its own tmux
session. A different working directory or planner is refused on reattach, so
it cannot connect you to an unexpected account. Existing legacy `dispatch`
sessions remain available with `tmux attach -t dispatch`.

Use `$dispatch`, `$briefed-dispatch` or `$dispatch-pixel` in Codex, and the
corresponding slash commands in Claude Code. The visual skill retains the
installer's `--pixel` opt-in. `DISPATCH_PLANNER` changes the launcher default;
`--model` or `DISPATCH_MODEL` changes only the planner model. Astra is the Codex
default; Claude uses Fable unless explicitly overridden. New station conversations
receive the same planner instructions as local launches. Reconnecting retains the
existing conversation; it does not inject a new task into a running planner.
Codex gets write access to the harness's `runs/` directory through `--add-dir`,
and keeps its configured sandbox and approval policy. A detached worker's
desktop notification does not itself wake the planner: use `resume dispatch
<RUN-ID>` in a conversation to continue from the persisted run state.

## Scheduling a run for later

`schedule.sh` takes the same arguments as `run-task.sh` plus a time, and fires
that run for you — the planner writes the brief tonight, the pipeline works
while nobody is at the desk, and the reviewed PR is open when the office
arrives.

```bash
~/.claude/harness/schedule.sh <TICKET> <repo-path> <branch-name> 08:10
~/.claude/harness/schedule.sh <TICKET> <repo-path> <branch-name> "2026-08-06 08:10"
~/.claude/harness/schedule.sh --list             # what is pending, soonest first
~/.claude/harness/schedule.sh --cancel <TICKET>  # disarm (the brief is kept)
```

The brief must already exist at `runs/<TICKET>/brief.md` — scheduling arms a
prepared run, it never writes a brief. A bare `HH:MM` means the next occurrence
(today if that is still ahead, tomorrow otherwise); the absolute form is local
time too. A time in the past, a date that does not exist, or a missing brief is
refused on the spot rather than at 08:10.

**How it fires.** Arming writes a one-shot wrapper into the run dir and loads a
per-user launchd LaunchAgent — one label per ticket, built from the
`LABEL_PREFIX` in `schedule.sh` — with a single `StartCalendarInterval` for
that minute. launchd has no `Year` field, so for a far-future absolute date the
wrapper ignores earlier annual calendar matches and stays armed until the
marker's fire epoch. At or after that epoch, it deletes its own plist, wrapper
and marker *before* dispatching, then runs `run-task.sh` with output in
`runs/<TICKET>/scheduled.log` and boots its own agent out of launchd last — so a
crash, a reboot or a calendar rollover can never turn one schedule into two runs.
While a schedule is armed, `runs/<TICKET>/scheduled` holds its fire epoch;
`--cancel` removes the agent, the plist, the wrapper and that marker, and leaves
the brief alone.

**It fires as a seat.** The wrapper carries a snapshot of the scheduling
shell's harness environment — every `HARNESS_*` variable, the model/effort
knobs and `PATH` — plus `HARNESS_SEAT`, the OS user the run dispatches as
(taken from `HARNESS_OWNER`, so the service user scheduling on someone's
behalf pins the seat explicitly). At fire time it launches `run-task.sh`
through `seat_exec`, so although the wrapper is written **mode 600** and lives
in the run dir with the rest of the run's metadata, it holds no credential of
any kind: the seat reads its own logins from its own home. launchd hands a job
an almost empty environment, which is why the snapshot exists at all; anything
you would `export` before `run-task.sh`, export before `schedule.sh` instead.

**Sleep, honestly.** launchd does not wake the machine for a
`StartCalendarInterval`; a fire time missed while the Mac was asleep is
coalesced into the next wake. The promise is therefore
"08:10, or as soon as the machine wakes after that" — good enough for a laptop
opened in the morning, and exact only on a machine that stays awake. For a hard
08:10, arm it on the always-on office Mac — schedules do not travel, a run fires
on the machine it was scheduled on. (`station.sh` already runs under
`caffeinate`.)

macOS only — `launchctl` is the mechanism, and on any other platform
`schedule.sh` says so and exits instead of arming something that will never
fire.

To point the whole harness somewhere other than `~/.claude/harness`, set
`HARNESS_DIR` (every script honors it) and install with
`HARNESS_DIR=/path ./install.sh`.

## Capacity preflight: a run that defers itself

A dispatch launched into an exhausted subscription window is pure waste. It
pays for a worktree, a deps install and an implementer spawn, dies instantly on
*"You've hit your session limit · resets 1:30pm"*, and records
`implementer_failed` — indistinguishable from a real failure, and recovered by
a human re-arming it. So `run-task.sh` checks first.

Before the worktree, it asks the launching seat's *own* Claude logs
(through the same
[local-file accountant the quartermaster uses](#the-quartermaster) —
`capacity.sh`, `ccusage … --offline`, no endpoint contacted from anywhere) how
much of the current five-hour block is left. If the block is exhausted, or
fewer than `HARNESS_MIN_SESSION_TOKENS` output tokens remain, the run does not
spawn. It hands *itself* to `schedule.sh` for the block's reset time plus
`HARNESS_DEFER_BUFFER_SECS`, writes a status line the wall and `status.sh`
show —

```
deferred: capacity, armed for 13:35
```

— pushes it through the usual notification path, and exits 0. Nothing was
built, nothing was installed, no model was called. Because `schedule.sh`
snapshots the environment of the shell that arms it, and that shell is the run
itself, the deferred dispatch fires with the seat and knobs it
was launched with; on disk it is indistinguishable from a human-armed one
(`runs/<TICKET>/scheduled`, `schedule.sh --list`, and the quartermaster's
`already armed` skip all just work).

**Belt to the braces: the mid-run self-resume.** A window can also empty
*during* a run — [the single biggest sink in the corpus that motivated
this](design-notes.md#what-the-corpus-taught-the-pipeline). When the implementer
exits non-zero and the session-limit message appears in the live feed, its
stderr, or its final result message, the run is classified as capacity rather
than `implementer_failed` and takes the same path: `deferred: capacity`, one
one-shot armed for the reset, and the scheduled dispatch resumes the pinned
implementer session exactly as a human re-dispatch would. Nobody has to notice.
The phone push says so in a sentence — *"session limit — self-resuming at
13:35"* — and `metrics.sh --report` counts these under `capacity self-resumes`.

A mid-run limit therefore always defers, because it always has a reset time to
aim at:

1. ccusage's block reset, the authority whenever it can answer at all;
2. failing that, the wall-clock time the limit message itself names (*"resets
   1:30pm"*, read in the operator's timezone) — prose, so it is the fallback
   rather than the source;
3. failing both, one hour, written into `capacity.log` as the guess it is.

**Advisory, never a blocker.** ccusage missing or erroring, and a `schedule.sh`
that refuses to arm, log one line and dispatch anyway. `HARNESS_PREFLIGHT=off`
disables the preflight and the mid-run classifier together. With capacity in
hand, a run behaves exactly as it did before this existed — the check writes its
verdict to `runs/<TICKET>/capacity.log` and says nothing on the console.

**And it stops.** A run auto-defers at most `HARNESS_MAX_DEFERRALS` times —
preflight and mid-run self-resumes counted together in
`runs/<TICKET>/deferrals`. After that it fails as `capacity_failed` — a status
of its own, so the honest outcome is never dressed up as a broken implementer,
and no run can reschedule itself forever.

The four knobs are in
[the reference](reference.md#capacity-and-deferral).

## Turn ceiling: a run that resumes itself

The implementer is spawned with `--max-turns`, a guard rail against a worker
that loops forever — and a ceiling set too low
[killed runs at the finish line](design-notes.md#what-the-corpus-taught-the-pipeline)
until the run learned to resume itself.

The ceiling is `HARNESS_MAX_TURNS` (default **200**), **pinned at first
dispatch** into `runs/<TICKET>/max-turns` like the model and effort knobs, so
every later resume spends the ceiling the run was dispatched with rather than
whatever the resuming shell exports. A value that is not a positive integer
falls back to the default with one line on the console — and the fallback is
re-pinned, so it says it once, not on every resume.

When the implementer stops on turn exhaustion (the CLI's `error_max_turns`
result — a structured outcome, not a message we parse), the run does **not**
fail. It spawns the implementer again, in the same worktree, with the same
ceiling, and says so:

```
resuming: turn ceiling (1/2)
```

`HARNESS_MAX_RESUMES` (default **2**) bounds it, counted in
`runs/<TICKET>/turn-resumes`. Only once that budget is spent does the run
surface `implementer_failed`.

**What the next segment is handed: `HARNESS_RESUME_MODE`.** Pinned into
`runs/<TICKET>/resume-mode` at first dispatch, like the model knobs, because it
is an experimental condition and not a per-shell preference.

- `report` (**default**) — the harness writes
  `runs/<TICKET>/segment-report-<n>.md`: a fixed template (goal, decisions taken
  and why, files touched, gate status, open questions, dead ends, and the
  segment's tool trail) extracted mechanically from that segment's own
  trajectory and from git. The next segment is then a **fresh session** whose
  prompt is that report, explicitly labelled *a previous session's report* — an
  external artifact to be checked against the repository, not a memory —
  followed by the full task contract. Nothing is asked of the exhausted session:
  it has no turns left to write a handover, so the report may not depend on its
  cooperation.
- `transcript` — the original behavior, kept as the comparison arm: `--resume`
  back into the exhausted session with a short "you ran out of turns"
  continuation, byte for byte what a human re-dispatch does.

An agent re-reading its own prior reasoning as its own thoughts is the framing
that suppresses self-correction, and long-horizon failures are overwhelmingly
process-level, with history error accumulation among the named causes.
Re-labelling the same content as somebody else's account is a prompt-level
change with a large measured effect on whether a model corrects course — and a
knob rather than a rewrite, so both arms stay measurable.

**Only the turn ceiling.** A capacity deferral resumes a run whose *window*
emptied, and there the intact context is exactly what you want back: that path
stays on `--resume` whatever `resume-mode` says.

**A resume appends to the stream; it does not replace it.** In both modes — a
fresh session is still a segment of the same attempt. Each segment of a
resumed attempt writes into the same `opus-stream.jsonl`, exhausted one first,
and the file is truncated exactly once per *invocation* — up with the
[attempt rotation](#attempts-a-run-is-a-ticket-an-attempt-is-a-dispatch), never
per spawn. It used to be truncated per spawn, which threw away every event of
the segment that ran out of turns: the verifier scored a trajectory with most of
the implementer's work missing, and the telemetry described only the last
segment. So `metrics.implementer_num_turns` and `metrics.implementer_usage` are
now **summed over every segment** of the invocation, with
`metrics.implementer_segments` saying how many there were (`1` for a run that
never resumed) — without which a resumed run, the expensive kind, was recorded
as cheaper than one that finished in a single go, and the
[Quartermaster](#the-quartermaster) sized the next dispatch off that number.
What the failure classifiers want is narrower — the segment that just ended —
and they get it by reading the stream's **last** result event, so a ceiling hit
followed by a clean segment is not another ceiling hit.

Two things outrank the turn budget. A **session limit** is classified first, so
a run whose window emptied mid-flight takes the
[capacity deferral](#capacity-preflight-a-run-that-defers-itself) instead of
burning resumes on a session that cannot spawn anyway. And a pending
`.harness/QUESTIONS.md` still pauses the run as `needs_input`: a worker that
stopped to ask is never talked over.

**Commit hygiene that survives a resume.** A resumed session carries its
original instructions far behind it in a long context, and resumes have
re-added `Co-Authored-By: Claude` trailers their first pass never wrote. So
every continuation message restates the binding commit rules, and — because a
prompt is not a guarantee — the implementer stage ends with a deterministic
backstop on **every** arm, review or not: `base..HEAD` is scanned for AI
attribution (`Co-Authored-By:`/`Generated with …` naming Claude or Anthropic,
any `Claude-*:` trailer), and any that is found is stripped mechanically. Only
commit *messages* are rewritten — each commit is re-created against its
original tree object, so the diff, the working copy and the commit count are
untouched, a genuine human `Co-Authored-By:` is left alone, and a range with
nothing to strip keeps its shas.

The three knobs are in
[the reference](reference.md#turn-ceiling-and-resumes).

## Attempts: a run is a ticket, an attempt is a dispatch

A run gets re-dispatched — after a question, after a failure, after a session
limit — and everything below distinguishes the two.

**Per-attempt telemetry survives the attempt.** Every invocation used to
truncate `opus-stream.jsonl`, `gate-rounds.log` and `opus.log` on the way in, so
each re-dispatch [destroyed the evidence of the attempt it was recovering
from](design-notes.md#what-the-corpus-taught-the-pipeline). They are now
**rotated**, not truncated:

```
runs/<TICKET>/
  opus-stream.jsonl      the live attempt, exactly where it has always been
  gate-rounds.log
  opus.log
  attempts/1/{opus-stream.jsonl,gate-rounds.log,opus.log}   attempt 1's own
  attempts/2/…                                              attempt 2's own
  attempts.log           <n> <status> <started> <ended>, one row per attempt
```

The live filenames never move, so everything reading the current attempt — the
wall, the classifiers, `metrics.sh`, the reviewer — is untouched. The attempt
number is the count of `__invocation__` markers in the append-only `stages.log`.
`result.json` gains `attempt` (this invocation's ordinal), `attempts_total`, and
`metrics.attempts` (the ledger), all additive; `metrics.turn_resumes` now counts
**this invocation's** resumes rather than the run's lifetime total.

**A finished run is not dispatched again.** Re-arming a run that already reached
`done: ready` [burned hours on work that was already in a
PR](design-notes.md#what-the-corpus-taught-the-pipeline), and turned one
finished run into a broken one. So a dispatch of a run whose status is
`done: ready` refuses before anything is touched (no worktree, no marker, no
`result.json` rewrite), printing the PR it already produced. Every other status
keeps today's behaviour: re-dispatching after a failure, a question or a
deferral is the normal path. The deliberate override — a revised brief on a
shipped branch, a PR closed by hand — is `HARNESS_REDISPATCH=1`
([reference](reference.md#dispatch-and-identity)).

## The Quartermaster

Subscription capacity that is still unused at the end of the day expires
worthless, while dispatchable work sits in the tracker. `schedule.sh` can fire a
prepared run at 02:00 — but somebody has to decide, every evening, *which* runs
and *how many*. `quartermaster.sh` is that decision, made at 19:00:

```bash
~/.claude/harness/quartermaster.sh              # --report: the plan, arms nothing
~/.claude/harness/quartermaster.sh --arm        # actually arm it
~/.claude/harness/quartermaster.sh --install    # a daily 19:00 agent that reports
~/.claude/harness/quartermaster.sh --uninstall  # remove that agent
```

**The crew convention is the consent.** A Linear issue labelled `overnight`
**and assigned to somebody** is a ticket that person is happy to have run
overnight, under their own identity. The label alone is not enough and the
assignee alone is not enough — the pair is the handshake. The crew is the set
of seats in the `accounts` mapping of `linear-dispatch.json` (or `QM_CREW` when
no mapping is installed): one seat per station, a seat being an OS user whose
own `~/.claude`, `~/.codex` and `~/.config/gh` hold its logins. An assignee's
email maps to a seat by its local part up to the first dot, so
`dana.reyes@example.com` is the seat `dana`. An assignee whose seat is not a
user on this machine is reported under *Unknown stations*, never guessed at.

**A brief is still the contract — and the evening can now write one.** A
tagged ticket is armable only when `runs/<TICKET>/brief.md` exists — the same
brief `schedule.sh` demands. By default (`QM_AUTOBRIEF=1`) an `--arm` run
self-briefs the tagged tickets that lack one, in queue order and only up to
the night's remaining headroom: a planner session on the owning station's own
subscription, confined by `planner-settings.json` (read-only research minus the
harness's own secrets — no Bash, no network, no subagents, no git writes), turns
the ticket text into the brief. It writes that brief into a scratch directory
minted for the call and handed to it as its working directory, and the harness
copies the result into `runs/`: Claude Code refuses edits under `~/.claude` as a
protected path and refuses edits outside the session's cwd tree, so a planner
pointed straight at `runs/<TICKET>/` cannot write at all — which is precisely how
self-briefing shipped broken and stayed broken until 2026-08-10, invisible behind
machines that were only ever in `--report` mode. The scratch dir is also the
whole of its write reach, which is tighter than the rule it replaced, and
`planner-settings.json` denies edits under `~/.claude` by policy on top of that,
so the harness's own tree stays shut even if that cwd wall ever moves. The ticket
text reaches that planner inside a fence whose marker is minted per call, so a
description that types its own `END` marker and then gives orders is still just
quoted data. The planner writes a uniquely named, non-armable candidate; after
validation, the quartermaster publishes it as `brief.md` with an atomic
no-clobber link, so a brief that appeared meanwhile is never replaced. Every
existing `brief.md` under `runs/` is also checkpointed before the planner
starts: anything it wrote elsewhere is put back byte for byte, the planner's
version quarantined beside it, and the ticket left unarmed — a steered planner
cannot plant an armable brief in a sibling ticket's directory or overwrite one
a human approved. The report lists self-written
briefs under *Self-briefed*, each with what the critic below made of it — no
human has read those plans, which is the trade
the default makes; set `QM_AUTOBRIEF=0` to restore the stricter contract where
unbriefed tickets are listed under *needs a brief* and left alone. `--report`
never briefs. Knobs: `QM_AUTOBRIEF_TIMEOUT` (planner seconds, default 1200),
`QM_AUTOBRIEF_MODEL` (empty = the station's default), `QM_AUTOBRIEF_MAX_BODY`
(ticket-description bytes fed to the planner), and `QM_REPO_ROOTS` /
`QM_REPO_DEPTH` (where repos may be discovered). Tickets already armed,
already running, or already delivered (a `result.json` with a `pr_url`) are
skipped with the reason, which is what makes a second run at 19:05 arm nothing
at all.

**Capacity, honestly estimated.** A home directory is closed to everybody but
its seat, so per seat the quartermaster runs `capacity.sh --seat-json` *as that
seat* — `seat_exec <seat> -- capacity.sh --seat-json`, the sudoers fragment's
one capacity door — which reads ccusage over the seat's *own log files* in
`~/.claude`: no endpoint is contacted, by anyone, anywhere in this script.
Headroom is measured in output tokens, the only unit available on both sides of
the sum: the ceiling is the busiest completed five-hour block ccusage can still
see (or `QM_TOKEN_LIMIT` when you know your real one), and what is left of it
in the current block is the proxy for tonight's capacity. One run costs the
median `metrics.implementer_usage.output_tokens` over the last `QM_HISTORY`
runs, so the estimate is this machine's own history rather than a guess. Then
`N = floor(remaining × QM_SAFETY / median cost)`, capped at `QM_MAX_PER_CREW`.
It is an estimate, and the safety factor is there because it is one — when
ccusage cannot account for a seat at all, the report says so and falls back to
`QM_FALLBACK_N` rather than inventing a number.

**A second reading, by something that did not write it.** A self-written brief
is the only specification the night has, and by 02:00 there is nobody to ask
about it. So before the quartermaster publishes one, `spec-critic.sh` reads it
against the repo it names — a second confined session, read-only, on the same
station's subscription — and returns `{contradictions,
criteria_not_testing_problem, conflicts_with_current_behavior, questions}`; the
full contract is in [The spec critic](reference.md#the-spec-critic). Only
`contradictions` hold a brief back: it is quarantined to `brief.rejected.md`
like every other rejected brief, the ticket is listed under *Could not
self-brief* with the count and the path to its candidate-specific
`runs/<TICKET>/spec-critic.<FENCE>.json`, and nothing is armed. A candidate that
wins publication promotes its matching clean verdict to
`runs/<TICKET>/spec-critic.json`. The other three lists are advice for whoever
reads the run afterwards — an untested criterion still builds something, and a
question is a question. A critic that produced no verdict at all (unreachable
model, timeout, turn ceiling) leaves the brief deferred too: not because the
outage is evidence against the brief, but because the required pre-dispatch
reading did not happen.
The ticket stays under *Could not self-brief* and points to its critic log.
`QM_SPEC_CRITIC=0` drops the pass entirely.

**No brief arms unchecked.** Before a brief is handed to `schedule.sh` —
self-written or hand-written, it makes no difference — its `Repo` must be one
of the repos actually discovered under `QM_REPO_ROOTS`, verbatim, and its
`Branch` must be a ref `git check-ref-format` accepts. `feat/x (suggested)` arms fine
and then burns a 02:00 run on `setup_failed` with nobody awake to see it, and a
repo this machine does not have does the same. A brief that fails is listed
under *Rejected briefs* and moved aside to `brief.rejected.md` — never deleted,
never armed, and never left at the path tomorrow's pass would read as approved.
`--report` names the same briefs and moves nothing. When no repo can be
discovered at all the roots are wrong rather than the briefs, so nothing is
quarantined and nothing is armed.

**What `--arm` does.** Eligible tickets take the fire times in `QM_TIMES` in
queue order (priority first, oldest first within a priority), and each is handed
to `schedule.sh` under that ticket's seat — `HARNESS_OWNER` names the seat, and
the snapshot `schedule.sh` writes carries `HARNESS_SEAT` plus the `HARNESS_*`
knobs (with `IMPLEMENTER_EFFORT` from `QM_EFFORT`) to 02:00, where the launch
goes through `seat_exec` as that seat. A `GH_TOKEN` exported in the invoking
shell is *unset* for that call: `gh` prefers a token over its config dir, and
one would quietly make every crew member's PR come out of the same account.
Each armed ticket then gets a Linear comment
saying when it was armed; a failed comment is reported and never unarms a run.
Slots already spent tonight count against `N`, so reruns neither double-arm nor
hand out a fire time twice.

**The report.** Every run writes `runs/quartermaster/<YYYY-MM-DD>.md` — per crew
member: estimated headroom, median run cost, `N`, what was armed (or would be),
what needs a brief, and every skip with its reason — and pushes a compact
summary to your phone through the same `HARNESS_NTFY_TOPIC` in `notify.conf`
that stage handoffs use. No topic configured means the report file only.
`--report` is side-effect-free outside that file: it arms nothing, comments on
nothing, and exits 0 even when Linear is unreachable or ccusage fails, because
a partial report at 19:00 is worth more than a crash.

**The trust dial.** `--install` writes a daily launchd agent — one fixed label,
the `LABEL_ID` in `quartermaster.sh`, with `QM_AT` to move it off 19:00 —
running `--report`, on the same conventions as `schedule.sh`: a mode-600 wrapper
carrying an environment snapshot, because launchd hands a job almost nothing. It
only reports until you decide otherwise; `--install --arm` (or editing the mode
argument in the plist) is the one-line flip to letting it act. macOS only, like
`schedule.sh` — `--report` itself runs anywhere.

| Env var | What it does | Default |
| --- | --- | --- |
| `QM_SAFETY` | Fraction of the estimated headroom to spend | `0.5` |
| `QM_MAX_PER_CREW` | Hard ceiling on runs per crew member per night | `3` |
| `QM_FALLBACK_N` | Runs to allow when capacity is unknowable | `1` |
| `QM_TIMES` | Fire times, handed out in queue order | `"23:30 02:00 04:30"` |
| `QM_LABEL` | The consent label | `overnight` |
| `QM_CREW` | The crew's seats, space-separated, when no `linear-dispatch.json` accounts mapping is installed | unset |
| `QM_HISTORY` | Runs sampled for the median cost | `20` |
| `QM_DEFAULT_COST` | Median cost when there is no history yet | `40000` |
| `QM_TOKEN_LIMIT` | Pin the block ceiling instead of inferring it | unset |
| `QM_AT` | When `--install` fires | `19:00` |
| `QM_PAGE` | Issues fetched per Linear request (all pages are followed) | `100` |
| `QM_CCUSAGE_TIMEOUT` | Seconds allowed for each local ccusage read | `120` |
| `QM_LINEAR_TIMEOUT` | Seconds allowed for each Linear request | `20` |
| `QM_NTFY_TIMEOUT` | Seconds allowed for the ntfy report push | `10` |
| `QM_EFFORT` | `IMPLEMENTER_EFFORT` for armed runs | `high` |
| `LINEAR_API_KEY_FILE` | The Linear key (mode 600, never echoed anywhere) | `$HARNESS_DIR/linear-api-key` |

`QM_AUTOBRIEF`, `QM_AUTOBRIEF_TIMEOUT`, `QM_AUTOBRIEF_MODEL`,
`QM_AUTOBRIEF_MAX_BODY`, `QM_SPEC_CRITIC`, `QM_REPO_ROOTS` and `QM_REPO_DEPTH`
are described in the self-briefing paragraphs above.

## The Janitor

`cleanup.sh` runs when the orchestrator promotes a PR in session. Every other
road to a merged PR leaves the run's worktree on disk forever, because nothing
else ever looked back: a PR merged from the web UI, merged by a teammate,
promoted in a session that died, or a `push_failed` run whose branch shipped
anyway. On the machine this was written for that was twenty-two worktrees and
thirteen gigabytes, the oldest merged two weeks earlier — one of them belonging
to a run still recorded as `push_failed` whose PR had long since landed.
`flutter test` compounds it: it leaves detached `flutter_tester` processes
behind, and removing the worktree they ran in does not kill them.

`janitor.sh` is the pass that closes both loops.

**What may be swept.** A run's worktree goes only when every one of these holds:
its `result.json` carries a `pr_url`, `gh pr view` says that PR is `MERGED`, the
worktree is still on disk, and `git status --porcelain` inside it is empty.
Everything else is listed with its reason and left exactly as it was — an
**OPEN** PR above all, whose worktree is where post-PR review fixes land (the
redispatch trap in [`skills/dispatch/SKILL.md`](../skills/dispatch/SKILL.md) is
the same lesson from the other end). So is a dirty tree, a run that has not
reached a `done:` stage, a run that never opened a PR, and a **CLOSED** PR that
was never merged. A PR whose state could not be read at all is `unknown`, never
"probably merged": `gh` missing, unauthenticated or failing degrades the whole
pass to a report, because a state nobody could read is not evidence of anything.

**How it sweeps.** By calling `cleanup.sh <RUN-ID>`, which already knows how to
remove the worktree, delete the local branch *only* when it is on origin, and
drop a mirrored copy. The janitor decides; `cleanup.sh` acts. Afterwards each
repo it touched gets a `git worktree prune`. Run directories under
`runs/<RUN-ID>/` are never deleted — briefs, feeds, worker logs and
`result.json` all stay, which is what keeps `metrics.sh` honest about runs whose
worktree is long gone.

**What it records.** Before deciding anything about a worktree, every run whose
`result.json` carries a `pr_url` gets an `outcome.json` written beside it:
`pr_url`, `pr_state`, `merged_at`, `time_to_merge_s` (PR created → merged),
`review_comment_count` (inline review comments, bots excluded),
`follow_up_commits` (commits on the base branch after the merge that touch
files the PR changed), `reverted` (a later commit whose message names the merge
SHA), and `checked_at`. The comment count costs one extra read-only `gh api`
call per PR; everything else rides the `gh pr view` the sweep already makes,
plus local git in the run's repo. Once a PR is terminal (`MERGED` or `CLOSED`)
and its outcome is `JANITOR_OUTCOME_MAX_AGE` days old, the file stops being
refreshed — provided it still names the run's current PR. Capture never fails a
sweep: a PR whose state cannot be read keeps the previous file as it was.
`metrics.sh --report` summarizes the block as merge rate, median minutes to
merge and revert count.

**Zombies.** A run whose process died without ever writing a terminal `done:`
status stays "in progress" on every surface forever — the wall, the console and
the statusline all key liveness on the `done:` prefix, so the run renders as
active for as long as nobody looks behind the status file. Between the sweep and
the process reap, a second reap pass flips those: a run whose status is
non-terminal, older than `JANITOR_ZOMBIE_HOURS` (twelve hours), and served by no
live `run-task.sh <RUN-ID>` / `sync-pr.sh <RUN-ID>` process — `pgrep -f`, the
load-bearing guard, and without `pgrep` the pass reaps nothing rather than reap
on an unprovable absence — gets `done: reaped (stale — no live process, was:
<the stage it died on>)` written over its status, with the same line appended to
`stages.log` and `timeline` so the history stays honest. A run whose PR the
sweep's own poll already recorded as merged in `outcome.json` is reaped as
`done: ready (reaped — PR merged)` instead — it did ship, and its worktree
becomes the sweep's to take on a later pass. Reaping deletes nothing and
decides nothing about worktrees: run dirs, code and worktrees are exactly as
the pass found them, an already-`done:` run is never reaped, and a run a live
process is still serving is never touched however stale its status looks.

**Processes.** Any process whose name exactly matches `JANITOR_PROC_MATCH`
(`flutter_tester`) and whose `ps` elapsed time is over `JANITOR_PROC_AGE` (two
hours) is reaped: `TERM`, then `KILL` if it is still there a couple of seconds
later. Nothing legitimate keeps a detached test runner alive for hours, so age
is the whole test. Younger ones are counted and left.

**What it teaches the next run.** After the outcome poll, the pass distils each
repo's confirmed review findings — the ones that survived refutation — into a
short per-repo file the next dispatch mounts for its implementer and the planner
reads before writing a brief. It is derived data, rewritten whole every pass and
removed for a repo with no traps left, so it destroys nothing and never fails a
sweep. `lessons.sh` is the front door; the rules, the weights and the evictions
are in [the feedback loop](reference.md#the-feedback-loop).

**The two modes.** `janitor.sh` and `janitor.sh --report` produce the same
listing of every worktree the harness still holds and what would happen to it.
Report mode never removes a worktree or reaps a process or a zombie status, but
it does perform the read-only PR/base refreshes described above, create or
update `outcome.json` and the cached run `repo` path, and refresh the lessons
files. `janitor.sh --clean`
additionally carries out the reported cleanup. `--install` writes a daily launchd agent — one fixed
label, the `LABEL_ID` in `janitor.sh`, with `JANITOR_AT` to move it off 09:00 —
on the quartermaster's conventions: a mode-600 wrapper carrying an environment
snapshot, because launchd hands a job almost nothing. `GH_CONFIG_DIR` rides
along in that snapshot, since it decides which account can read a PR's state;
`GH_TOKEN` deliberately does not. It only reports until you decide otherwise,
and `--install --clean` is the one-line flip to letting it sweep. macOS only,
like `schedule.sh` — `--report` and `--clean` themselves run anywhere.
`install.sh` does *not* arm the schedule: installing it stays an explicit act.

| Env var | What it does | Default |
| --- | --- | --- |
| `JANITOR_AT` | When `--install` fires | `09:00` |
| `JANITOR_PROC_AGE` | Seconds a matching process may live | `7200` |
| `JANITOR_PROC_MATCH` | Process name to reap (empty is refused, not defaulted) | `flutter_tester` |
| `JANITOR_GH_TIMEOUT` | Seconds allowed for each `gh` call | `20` |
| `JANITOR_OUTCOME_MAX_AGE` | Days after which a terminal PR's `outcome.json` stops being refreshed | `14` |
| `JANITOR_ZOMBIE_HOURS` | Hours after which a non-terminal status with no live process is reaped | `12` |
| `JANITOR_DEAD_ZOMBIE_MINS` | Minutes after which a run **proven** dead is reaped — its `driver.pid` names no live process *and* its `heartbeat` is cold. `JANITOR_ZOMBIE_HOURS` stays long because `pgrep` alone cannot tell "no process" from "not started yet"; two independent liveness signals can, so that run needs no twelve-hour grace. The reap now also writes a `result.json` with status `driver_failed`, so metrics and the wall see a terminated attempt rather than an attempt that never ended | `10` |

What leaves the machine: one read-only `gh pr view` per run that has a PR, plus
— while that PR's outcome is still being refreshed — one read-only `gh api` call
for its review comments, and nothing else. `--clean` exits non-zero only when a
sweep it decided on could not be carried out, so a nightly agent's log is quiet
until something is actually wrong.

## Ticket sync

To start tasks by delegating them to the Mini app in Linear, and answer the
agent's questions there, enable [Dispatch from Linear](linear-dispatch.md).
It consumes signed agent-session events and reuses the outbound layers below.

An overnight run has no orchestrator watching for its result, and a teammate
looking at Linear used to have no way to tell that a ticket was being built at
all — the pipeline's whole footprint was one comment at the very end. Now the
ticket carries the run while it runs, in three layers you switch on
independently. All three are gated by the same two things: a run id that starts
with a `TEAM-123` identifier (ad-hoc runs are skipped automatically) and
`HARNESS_TICKET_SYNC` left at `1`. All three are best-effort in the strongest
sense — no Linear failure ever changes a run's status or exit code.

**1. The comment and the state move** (needs `linear-api-key`, the same file the
quartermaster reads). On `ready`, the draft-PR link is commented on the ticket
and the ticket moves to its team's **In Review** state — matched against the
team's real state names, "In Review" by name first, else the `started`-type
state mentioning "review". This is what the harness has always done.

**2. The attachment card** (needs `linear-api-key` **and**
`HARNESS_RUN_LINK_BASE`). One attachment on the issue, re-sent on every stage:
title `Dispatch run <RUN-ID>`, subtitle the stage the run is in right now, and
provider/owner/branch/host as attributes. Its URL — the run's deep link on the
wall, `$HARNESS_RUN_LINK_BASE/console#<RUN-ID>` — is also its identity: Linear
updates the original attachment when the same URL comes back on the same issue,
so the card tracks the run with no bookkeeping and never accumulates.

**3. The agent session** (needs `linear-agent-credentials`). The run becomes a
Linear *agent session* on its issue: every stage is an activity on a timeline
rendered as the app, not as you. Stages map to Linear's five activity shapes —
an ordinary handoff is an `action`, the implementer's pause is an `elicitation`
carrying `QUESTIONS.md` (the session shows as awaiting input), a capacity
deferral is a `thought`, `rejected` and every other failing outcome is an
`error`, and `ready` is a `response` carrying the PR link, with the PR added to
the session as an external URL labelled "Pull Request". While a stage runs long,
the driver's heartbeat posts an *ephemeral* thought carrying the run's current
activity line at most once per `HARNESS_LINEAR_HEARTBEAT_SECS` (default 300), so
a long implementer never reaches the 30 minutes after which Linear marks a
session stale. Agents do not count as billable users.

When layers 2 and 3 are both on, both run: the card is the always-visible
summary, the session is the timeline. The end-of-run comment is *not* duplicated
— with a session open the PR link is the session's `response`, which Linear
mirrors as a comment. If that response is rejected, the old comment goes out
instead, because a ticket must never end without its PR link.

Everything every layer sends, and everything Linear answers, lands in
`runs/<RUN-ID>/ticket-sync.log`. A failure adds a line starting
`LINEAR ERROR <mutation>:` — that grep is the operator's live test:

```bash
grep 'LINEAR ERROR' ~/.claude/harness/runs/<RUN-ID>/ticket-sync.log
```

### Registering the agent

Layer 3 needs a Linear OAuth app; layers 1 and 2 do not. The app authenticates
with the `client_credentials` grant, which returns a 30-day app actor token
with no browser step — the harness mints it, caches it in
`linear-agent-token`, and re-mints it on expiry or a `401`. Agent sessions are
gated behind a webhook, though: Linear answers `agentSessionCreateOnIssue`
with *"Agent sessions are not enabled for this application"* until the app
enables webhooks and selects **Agent session events**. The wall receives that
webhook — its one path on the public internet, signed by Linear and answered
with a 200 and nothing else ([Exposing the webhook
path](#exposing-the-webhook-path)).

1. A workspace admin opens `https://linear.app/settings/api/applications/new`.
   The name and icon are how the agent appears in Linear (the name may not
   contain "Linear" or "http"). One redirect URI is required even though nothing
   uses it — `http://localhost/unused` is fine. Distribution: private.
2. Toggle on **client credentials tokens**. Enable **Webhooks** on the same
   app: URL `https://<wall-host>.<tailnet>.ts.net/webhooks/linear`, and tick
   **Agent session events**. Copy the signing secret the page shows into
   `~/.claude/harness/linear-webhook-secret` (first line, mode 600) **on the
   wall machine**, then restart the wall so it reads the file. Do this only
   after the Funnel subsection below — the URL should already answer when
   Linear first delivers to it (Linear does not document validating the URL on
   save, so the order is caution, not requirement).
3. Put the client id and secret in `~/.claude/harness/linear-agent-credentials`,
   mode 600, on the machine that dispatches ticketed runs — two `key=value`
   lines and nothing else:

   ```
   client_id=<Linear OAuth app client id>
   client_secret=<Linear OAuth app client secret>
   ```

4. Set `HARNESS_RUN_LINK_BASE` to the team wall's base URL, no trailing slash
   (e.g. `http://mini:4711`), so sessions and cards link back to the run.
5. Dispatch a real ticket and look at the issue: the session renders, and
   `runs/<RUN-ID>/ticket-sync.log` has no `LINEAR ERROR
   agentSessionCreateOnIssue` line. Without the webhook that mutation is
   refused with *"Agent sessions are not enabled for this application"* —
   observed 29 Aug 2026 on the first ticketed run, one refusal per stage while
   it retried. The attachment card works either way; only the session needs
   the webhook.

#### Exposing the webhook path

Linear delivers to a public HTTPS URL that must answer within 5 s. The wall
has exactly one such path: `/webhooks/linear`, published with Tailscale
Funnel on the wall machine. Everything else — the console, `/api/runs`, the
ingest routes, every GET that has never had auth — stays on the tailnet
exactly as before: Funnel is granted per path, not per machine.

Prerequisites, once per tailnet: the `funnel` node attribute on the wall
machine in the tailnet policy file, MagicDNS, and HTTPS certificates (the
Tailscale Funnel guide covers all three). On macOS the CLI is not on `PATH`
by default — it is
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`. Then:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale funnel --bg \
  --set-path /webhooks/linear http://127.0.0.1:4711/webhooks/linear
```

The listener is 443 (Funnel allows 443, 8443 and 10000 only); the target is
the wall's matching route because Funnel removes the configured mount prefix
before proxying. A request for the exact mount therefore reaches
`/webhooks/linear`, while the route also tolerates the trailing slash Funnel
may re-join onto it. `funnel status` lists what is published; `funnel off`
unpublishes all of it. The command above follows the Tailscale KB and is
written unverified against a live client — check `tailscale funnel --help` on
the wall machine if it is rejected.

The proof the mapping reached the route is a `curl` from anywhere:

```bash
curl -si https://<wall-host>.<tailnet>.ts.net/webhooks/linear -X POST -d '{}'
```

**401** is the answer wanted: the route was reached and refused an unsigned
body. **404** means the request did not arrive as `/webhooks/linear` — or the
wall was restarted before the secret file existed — and a timeout means
Funnel itself is not up.

## Runs from any machine (`HARNESS_MIRROR`)

The wall reads the run dirs of the machine that serves it, so a run dispatched
on a laptop is invisible on the office screen. Set `HARNESS_MIRROR` wherever you
dispatch and the run mirrors its own run dir to that machine for as long as it
runs — no rsync loop of your own, nothing to start or stop:

```bash
export HARNESS_MIRROR=mini:.claude/harness/runs   # an ssh target (has a colon)
export HARNESS_MIRROR=/mnt/wall/runs              # a local path (no colon)
```

The copy lands at `<target>/<RUN-ID>/` and is refreshed every two seconds, with
deletions included — an answered `QUESTIONS.md` clears the wall's alarm the same
way it clears your own. Only the run dir travels: never the worktree, never the
code. The last pass happens after the final stage, so the wall gets the run's
`done:` line and `result.json` too, and the loop dies with the invocation.

It is best-effort in the strongest sense — an unreachable target, a dead
tailnet or a machine without `rsync` never fails, slows or blocks a run, and
never says anything in the run's output. The last error, if any, sits in
`mirror.log` in the run dir. `sync-pr.sh` mirrors on the same terms for its own
short lifecycle, and `cleanup.sh` removes the mirrored copy when it promotes a
run, so the wall's disk empties with yours. With the variable unset, none of
this exists: no loop, no extra file, byte-identical behaviour.

Both knobs can be **per-repo pins** in `repos.local.sh` rather than exports —
`repo_config` runs before the mirror starts, so a repo can say
`HARNESS_MIRROR=mini:.claude/harness/runs` for itself while every other repo on
the machine stays unmirrored, and `cleanup.sh` resolves the same pin off the
run's worktree when nothing is exported. `HARNESS_PROVIDER_PRIVATE=1` beside
it keeps the vendor out of what the wall and the ticket see — the card and the
activity line say `—`, the stage reports carry no provider, and the mirrored run
dir carries a `provider-private` marker the wall honours before it reads the
pin files. What a machine's own `result.json` and `status.sh` say is unchanged.

The target is a machine you already trust with the run dir: mirroring copies
briefs, feeds and worker logs onto it, and gives it whatever your ssh key gives
it. Point it at your own wall, not at a shared box.

### Mirror or ingest?

Joining a laptop to the team's wall is `wall.sh --init-token` once on the wall's
machine and `install.sh --team <ssh host>` on the laptop — see
[the wall's ingest section](wall.md#ingest).

There are two ways a run on your laptop reaches a wall on another machine, and
they answer different questions.

| | `HARNESS_MIRROR` | `HARNESS_WALL_URL` ([ingest](wall.md#ingest)) |
| --- | --- | --- |
| What travels | the whole run dir — brief, feed, logs, `result.json` | a small JSON report per stage, per tool call, per metrics flush |
| How | `rsync` over ssh, every two seconds | `POST` to one HTTP route on the wall |
| Needs | an ssh key on the target and `rsync` | a token both sides share |
| What the wall can then draw | everything, including the city, the district and the feed | the console's row: stage, actor, host, live cost and tool count |
| Costs the target | your ssh key's access, and disk | nothing but the row |

Mirroring is the richer picture and the bigger trust: the target gets your
briefs and your worker logs. Ingest is the cheaper one, and it is the one that
scales to a team — a shared token, no ssh keys, and a board that shows every
run's *stage* the moment it moves.

**They compose.** A run that both mirrors and reports appears once: the wall
matches them by run id, the mirrored run dir wins, and the reported telemetry
attaches to that same row. Nothing is duplicated, and turning one of them off
never leaves a stale twin behind.

## Re-merging the base into a pushed PR

A PR branch that has been open for a while stops merging cleanly. `sync-pr.sh`
re-merges the latest base into an already-pushed branch and hands the conflicted
files to the same reviewer backend the run used — Codex where it is installed,
a Claude worker otherwise — told to resolve them and re-run the tests relevant
to the conflicted files. It mirrors its run dir on the same terms as a run
([`HARNESS_MIRROR`](#runs-from-any-machine-harness_mirror)), and it escalates to
a human rather than force-anything: a conflict it cannot resolve is reported,
not guessed at. A base-sync merge whose only Codex attempt died on credits gets
one more on [the fallback account](#a-second-codex-account-for-a-dry-primary)
first.

## Demo recordings

Frontend briefs include a **Demo storyboard**. The worker writes
`.harness/demo.json`, and the harness runs it through
[agent-browser](https://agent-browser.dev/commands) after the final test gate
and base sync. Each capture has its own browser session and dev server in the
worktree. Screenshots are the default; `video: true` also records an MP4.
The [brief template](../brief-template.md#demo-storyboard) is the format reference.
Neither capture nor publication calls a model.

On each execution host, install the optional browser tool once:

```bash
npm install -g agent-browser
agent-browser install
```

Screenshots need no object storage or FFmpeg. Video requires `ffmpeg` on PATH;
if it is missing, the harness saves screenshots and records that video was
skipped. `AGENT_BROWSER_BIN` selects a nonstandard CLI location, and
`AGENT_BROWSER_EXECUTABLE_PATH` can select a browser binary. Other ambient
agent-browser profiles, CDP connections, and saved-session overrides are not
inherited. Capture does not attach to someone's personal browser session.

For apps requiring login, run `demo-auth.sh /path/to/repo` once on the execution
host; it uses the existing Python/Playwright capture helper. The default state
is `auth/<repo-name>.json`. For separate seats or repositories with
the same basename, pin `DEMO_AUTH_FILE` to the intended account's saved state
in `repo_config_local`. This file stays on that host and is never uploaded.
Use demo accounts and fixture data appropriate for the PR audience. A missing
or expired session normally fails the storyboard's success-state wait; the
result reports the failure rather than attaching a login-screen recording.

A run keeps `evidence.json` plus immutable capture directories under
`runs/<ID>/evidence/<commit>-<capture>/`. The manifest records the commit,
attempt, provider, media hashes, and capture/publication status. It is also
included as `result.evidence`, visible through `dispatch status <ID> --json`.
Ordinary `dispatch status <ID>` shows the evidence status, reason, and media folder.
`--no-publish` keeps the same local evidence without contacting GitHub or R2.
A failed scene publishes no partial media. Media hashes and the PR's current
commit must match the capture before upload. Capture remains advisory:
a run can be code-ready while its evidence is `failed` or `publish_failed`.

For publishing runs, the harness checks whether `gh pr edit --help` supports
`--attach`. Current [GitHub CLI](https://cli.github.com/manual/gh_pr_edit) can
upload the media directly using the run's GitHub account. The harness updates
one marked **Frontend evidence** section and preserves the rest of the PR body.
Older GitHub CLI versions can use the existing `demo.conf.sh` settings:
`R2_REMOTE` for an rclone destination and `R2_PUBLIC` for its HTTPS serving URL.
Uploads use a separate repo/run/commit/capture path, so another run cannot
replace media already linked from a PR. If neither upload method is available,
the files remain local and the PR explains how to enable uploads.

The planner handles evidence recovery with `dispatch resume ID` after addressing
the reported cause. It records again when capture failed and uploads existing
media when only publication is missing. No worker or reviewer is repeated.

The following commands are operator tools for inspecting or explicitly rerunning
evidence once the run is `ready` or `ready_local`:

```bash
dispatch evidence ID                         # inspect the saved manifest
dispatch evidence ID --json                  # machine-readable evidence
dispatch evidence ID --capture               # capture again, save locally
dispatch evidence ID --publish               # upload existing files only
dispatch evidence ID --capture --publish     # capture, then upload
dispatch evidence ID --publish --on mini     # use the run's saved seat
```

These commands run no implementer, reviewer, or gate. The code verdict, attempt,
metrics, and checkpoints remain intact. Each capture gets a new directory;
previous media stays available. Capture requires the original worktree to be
clean and still at the completed run's commit. Fixing browser setup, saved login
state, or the ignored `.harness/demo.json` storyboard is enough to retry. Changed
product code needs a new reviewed run. Upload-only recovery also works after
worktree cleanup, using the saved repository, media hashes, and live PR commit.

Retries run on the original execution host under its saved seat.
An expired GitHub login leaves the files in place and prints
`dispatch login gh --for-run ID`, followed by `dispatch resume ID`; remote commands
include `--on`. A run started with `--no-publish` remains local. Upload needs an
existing PR and never creates one or pushes code. Older runs without a saved
account and commit-bound evidence record remain readable but cannot be retried.

Capture and upload run in the foreground. `dispatch status ID` shows the active
evidence operation. The existing CLI run lock prevents duplicate retries and
pipeline launches; an already-running legacy driver or `sync-pr.sh` also blocks
the retry. Interruptions keep the code verdict and any previous captures. The
operation's local diagnostics are in `demo.log` and `demo-driver.log`.

Legacy `.harness/demo.yml` shot-scraper storyboards remain supported. They
require `shot-scraper` and a repo-pinned `DEMO_PORT`; the newer JSON storyboard
takes the port from its URL. `DEMO_DEV_CMD` still configures the server used by
`demo-auth.sh`. A busy port is a capture failure, and cleanup terminates only
process groups created by the capture; it never kills an unrelated listener.

## Claude-only mode

Every run detects the `codex` CLI at startup, so one codebase serves both
setups — there is no separate install variant or flag:

- **codex present** — nothing changes: full arm, review and fix rounds, Codex
  resolves base-sync conflicts.
- **codex absent** — the run pins the `claude_only` arm and reviews on the
  [Claude tier](#when-codex-dies-mid-run-out-of-credits): the same review
  prompt, a fresh Claude session (never the implementer's own, so it is still a
  cold read of the diff), the same evidence check, and the same hold if it
  produces nothing — `review_failed`, no PR. `result.json` records
  `review: reviewed_claude` and `review_account: claude`, and `reviewer_model` /
  `reviewer_effort` name the model that actually reviewed. Base-sync conflict
  resolution (PR mechanics, not quality review) falls back to a Claude worker on
  your subscription — same prompt, fresh session, logged to
  `claude-<label>.log`.

This arm used to skip the stage and ship every PR unreviewed by design. Same
vendor as the implementer is a real cost — it is why the Claude tier comes last
everywhere else and is recorded apart — but it is a smaller one than nothing
reading the diff at all, and the session is fresh, so no model grades its own
homework either way. The only arm that still ships without a review is the
`no_review` ablation (`HARNESS_SKIP_REVIEW=1`), which is an operator asking for
that baseline on purpose.

Everything else is identical: worktree, deterministic gate, `needs_input`
escalation, PR, demo recording. Install `codex` later and the next dispatch gets
the cross-vendor review back; runs already pinned to an arm keep it — a
Claude-only run resumed on a machine that now has `codex` keeps its blank
*pinned* reviewer knobs (the experimental condition is not retro-fitted) and
uses codex only for the mechanical base-sync conflict step.

## When Codex dies mid-run (out of credits)

A review that produced no evidence — a ChatGPT workspace out of credits is the
shape that actually happened, ten runs shipping unreviewed overnight — must not
be treated as a clean review. Cross-vendor is the preference; **a review is the
requirement**. The guarantee this stage carries is that
**every arm reviews or holds**: no path in `run-task.sh` opens a PR when
nothing produced review evidence. The stage runs in tiers, every decision made
from evidence (notes, a rejection, or reviewer commits), never exit codes and
never durations:

1. the **primary Codex account** reviews;
2. on a credits-certain death (or one silent no-op below the review floor) the
   **fallback Codex account** takes a retry, when
   `HARNESS_CODEX_HOME_FALLBACK` is configured — still cross-vendor;
3. when the Codex side is done — both accounts empty, a dry primary with no
   fallback configured (a retry on a certainly-dry account buys nothing, and
   credits outrank the trivial-diff shortcut), a sandbox that would not start, a
   review that spent real time and left nothing behind, or [no `codex` CLI on
   the machine at all](#claude-only-mode) — the same review prompt runs in a
   **fresh Claude session** (never the implementer's own — still a cold read of
   the diff, just not cross-vendor). Recorded loudly: the stage line
   (`review — Codex unavailable (…) → Claude reviewer`), a `review-fallback`
   marker in the run dir naming the reason, `review: reviewed_claude` and
   `review_account: claude` in `result.json`, and one sentence on the run's own
   phone push saying the review was not cross-vendor and why;
4. if even that produces no evidence, the run ends **`review_failed`** and
   pushes nothing — an unreviewed diff never ships looking reviewed — and the
   phone push goes out at high priority naming the last tier to fail and what
   sent the run to it, since only a human can top up the credits.

The pipeline never marks a PR ready and never merges, in any arm; opening a
draft PR is as far as automation goes.

The tiers decide *who* reviews. Whichever one takes it then runs the same three
passes — find, refute, fix — so what it reports is disproved before it is
edited; that half is [Find, refute, fix](reference.md#find-refute-fix).

How an empty review is told apart from a fast, honest one — and what
`HARNESS_REVIEW_MIN_SECONDS` and `HARNESS_REVIEW_TRIVIAL_LINES` are for — is in
[the design notes](design-notes.md#when-the-review-stage-does-not-happen).

## A second Codex account for a dry primary

The day the primary ChatGPT workspace ran out of credits, every review for six
hours was an honestly-flagged no-op — the detection above working exactly as
designed, and six hours of unreviewed diffs anyway. `codex` auth is entirely
`CODEX_HOME`-directory-scoped, so a second account is one more directory plus a
rule about when to reach for it:

```bash
export HARNESS_CODEX_HOME_FALLBACK=~/.codex-fallback   # unset = no fallback, ever
```

Two things send the retry to the fallback:

1. **Credits-certain.** The attempt's log carries the workspace-credits error
   (`Your workspace is out of credits`, matched case-insensitively on
   whitespace-flattened output). Retrying the same account cannot possibly
   work, so the switch happens immediately and *regardless* of
   `HARNESS_REVIEW_MIN_SECONDS` — the floor asks whether a second pass is worth
   paying for, and a second pass on a different account always is.
2. **Silent no-op** (the classification above, cause unknown). The single retry
   the harness already buys runs on the fallback when one is configured, on the
   primary when none is.

If the fallback attempt also produces no evidence, the review does not
downgrade and ship anymore — the Claude tier takes the same prompt, and only
when that too leaves no evidence does the run end `review_failed` (see
[When Codex dies mid-run](#when-codex-dies-mid-run-out-of-credits)). A
fallback account is a second chance, never a second opinion; the Claude tier
is the last resort — same vendor as the implementer, which is exactly why it
comes last and is recorded apart (`reviewed_claude`).

**One attempt, one account.** `CODEX_HOME` is chosen before an attempt starts
and never changes while it runs. The switch is sticky and only ever moves the
*next* attempt, so the fix round and base-sync conflict resolution follow
wherever the review ended up — and a base-sync merge whose only Codex attempt
died on credits gets one more, on the fallback, before it escalates to a human
(`sync-pr.sh` too). Nothing anywhere records more than the label: each
attempt's `codex-<round>.log` opens with `codex account: primary|fallback`,
`result.json` carries `review_account`, and no path, directory or account
identity is written to any log, report or notification.

What you see when it fires: the retry's stage line reads
`review retry — Codex (ChatGPT sub) (fallback account)`, `metrics.sh --report`
counts **fallback-account reviews**, and the run's finishing push to your phone
appends one sentence — *review ran on the fallback Codex account — primary is
out of credits* — so the account gets topped up without anyone reading a log.
Scheduled runs need nothing extra: `schedule.sh` snapshots every `HARNESS_*`
variable into the wrapper it arms, so the knob travels to 02:00 on its own.

**One-time operator setup.** Log the second account in, in its own directory:

```bash
CODEX_HOME=~/.codex-fallback codex login --device-auth
```

Device authentication lets you complete login in your laptop's browser. If it
is unavailable, use `codex login` with the callback forwarded over SSH:

```bash
ssh -t -L 1455:localhost:1455 mini
```

`HARNESS_CODEX_HOME_FALLBACK` is the only knob this adds
([reference](reference.md#the-review-stage)); unset, behaviour is
byte-identical to a single-account harness.

One global knob, deliberately: with [crew stations](#the-quartermaster) every
station's runs share the same fallback account, and rotation beyond two accounts
is not something this does. Two accounts and one rule is the whole feature.

## Migration: seats become OS users

Stations used to be directories under one service account's `~/accounts/`, with
each stage re-exporting `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `GH_CONFIG_DIR`
to point a shared login at the right directory. Seats replace that: a seat *is*
an OS user, its name matching `^[a-z_][a-z0-9_-]{0,31}$`, and its logins live in
its own `~/.claude`, `~/.codex` and `~/.config/gh`. Nothing is re-exported
anymore — identity is the account you run as, and crossing to it goes through
`sudo` ([seat_exec](reference.md#dispatch-and-identity)). This section is the
one-time move for a machine that already runs the directory model.

**1. Create a user per seat.** On macOS:

```bash
sudo sysadminctl -addUser dana
```

(Linux: `sudo useradd -m dana`.) The username is the seat name everywhere:
`linear-dispatch.json` values, `HARNESS_OWNER`, wall lanes, Quartermaster
reports. Create one user per person who dispatches on this machine.

**2. Create the group, and put the runtime in it.** The shared runtime — one
`HARNESS_DIR` for the whole crew — is shared through a Unix group the harness
reads as `HARNESS_GROUP` (default `dispatch`). The harness deliberately does not
create groups or edit membership itself; once, as the operator:

```bash
sudo dseditgroup -o create dispatch                 # macOS; Linux: sudo groupadd dispatch
sudo dseditgroup -o edit -a dispatchsvc -t user dispatch   # the service account that owns the runtime
sudo dseditgroup -o edit -a dana -t user dispatch          # ...and every seat
sudo chgrp -R dispatch "$HARNESS_DIR"
sudo chmod -R g+rX "$HARNESS_DIR"
sudo find "$HARNESS_DIR" -type d -exec chmod g+wXs {} \;   # runs/, locks/, and friends
```

The repo roots need the same treatment — worktrees are created as siblings of
the repo, and the seats' runs write into them: `chgrp -R dispatch` each repo
*and the directory holding it*, `chmod -R g+rX` the repos, and `g+wXs` on the
directories seats create siblings in. Root-owned secrets (`linear-api-key`, the
wall's ingest token) keep mode 600: sharing a runtime is not sharing
credentials. Every path the pipeline writes must be group-safe — if one cannot
be, that is a defect to report, not a permission to widen.

**3. Move each account directory into its seat's home.** For each
`~/accounts/<name>/` under the service account:

```bash
sudo mkdir -p ~dana/.config
sudo mv ~/accounts/<name>/claude ~dana/.claude
sudo mv ~/accounts/<name>/codex   ~dana/.codex
sudo mv ~/accounts/<name>/gh      ~dana/.config/gh
sudo chown -R dana:dispatch ~dana/.claude ~dana/.codex ~dana/.config/gh
```

The directories are *moved, not deleted*: `~/accounts/` keeps whatever remains,
and the rollback below depends on that. A station that shared another person's
identity (a symlink or a copied directory) cannot be moved — its seat logs in
again, in its own home, as itself. The borrow check stays exactly as it was: a
credential that resolves outside the seat's home is reported as borrowing, so a
half-migrated station fails safely rather than silently running as somebody
else.

**4. Run `station.sh setup` once per seat.**

```bash
ssh -t dana@mini '/Users/dispatchsvc/.claude/harness/station.sh setup'
```

That is the whole per-seat onboarding: the five idempotent steps — Claude token
file, gh device login, Codex device login, planner skills, the `HARNESS_DIR`
profile line — plus `doctor`. Repeat for every seat; repeating for one seat
changes nothing for the others.

**5. Install the sudoers fragment.** The service account (the one running the
wall, the Linear bridge and the Quartermaster) reaches seats through exactly
three harness-owned commands. Copy `examples/sudoers-dispatch-crew.example`
from the checkout, replacing its placeholders — `<service user>` for the
runtime's owning account, every seat in the runas list, `<HARNESS_DIR>` for the
resolved runtime path (sudo matches command paths literally, so no symlink
components) — and install it through visudo so the syntax is checked before
anything takes effect:

```bash
sudo visudo -f /etc/sudoers.d/dispatch-crew
sudo visudo -c
```

The fragment is `NOPASSWD:SETENV` over `run-task.sh`, `capacity.sh` and
`seat-probe.sh`, and nothing else — widening it to more commands or a shell
hands the service account every seat's identity, which is precisely what seats
exist to prevent.

**6. Check the two rosters.** `linear-dispatch.json` keeps its exact shape; only
the wording of its values changes meaning — each `accounts` value is now a seat
name, which must be the OS username created in step 1. And the wall's roster
must list every seat: pass them as `wall.sh --crew dana,reinier,...` (or
`WALL_CREW`) and add a lane each in `wall/crew.json`, so a seat's runs show on
the skyline under their own name.

**7. Retire the hand-written launchers.** The per-person wrapper scripts on the
Mini — the ones that exported `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/`GH_CONFIG_DIR`
and called the harness — are dead weight now: each seat starts its station with
`station.sh start`, and the service account dispatches as a seat through
`--owner`. Delete them once the crew has run on seats for a night or two.

**Rollback.** Until the crew confirms seats work, nothing irreversible has
happened: the account directories were moved, not deleted. Move
`~<seat>/.claude`, `~<seat>/.codex` and `~<seat>/.config/gh` back under
`~/accounts/<name>/`, restore the old launchers, and remove the sudoers
fragment — the directory model reads what it always read.
