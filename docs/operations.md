# Operations

Running the harness when nobody is at the desk: arming a run for later, what a
run does when the subscription window empties, how attempts are counted, the
overnight Quartermaster, ticket sync, mirroring to another machine's wall, and
what the review stage does when a reviewer dies mid-run.

The pipeline's `HARNESS_*` tables are in [the reference](reference.md); the
Quartermaster's `QM_*` variables stay beside its operational narrative below
and are repeated in the reference for lookup. The incidents that shaped these
behaviours are in [the design notes](design-notes.md).

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

**It runs as the shell that scheduled it.** The wrapper carries a snapshot of
the scheduling shell's harness environment — every `HARNESS_*` variable
(`HARNESS_OWNER`, notification settings, …), `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
`GH_CONFIG_DIR`, `GH_TOKEN`, the model/effort knobs and `PATH` — because launchd
hands a job an almost empty environment. That snapshot can therefore contain a
token, so the wrapper is written **mode 600** and lives in the run dir with the
rest of the run's metadata. Anything you would `export` before `run-task.sh`,
export before `schedule.sh` instead.

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

Before the worktree, it asks the launching identity's *own* Claude logs
(`CLAUDE_CONFIG_DIR`, through the same
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
itself, the deferred dispatch fires with the identity, config dirs and knobs it
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
assignee alone is not enough — the pair is the handshake. Crew members are
directories under `~/accounts/` (`QM_ACCOUNTS_DIR`), one per station, each with
`claude/`, `codex/` and `gh/` inside it; an assignee's email maps to a station
by its local part up to the first dot, so `dana.reyes@example.com` is
`~/accounts/dana`. An assignee with no station on this machine is reported,
never guessed at.

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
briefs under *Self-briefed* — no human has read those plans, which is the trade
the default makes; set `QM_AUTOBRIEF=0` to restore the stricter contract where
unbriefed tickets are listed under *needs a brief* and left alone. `--report`
never briefs. Knobs: `QM_AUTOBRIEF_TIMEOUT` (planner seconds, default 1200),
`QM_AUTOBRIEF_MODEL` (empty = the station's default), `QM_AUTOBRIEF_MAX_BODY`
(ticket-description bytes fed to the planner), and `QM_REPO_ROOTS` /
`QM_REPO_DEPTH` (where repos may be discovered). Tickets already armed,
already running, or already delivered (a `result.json` with a `pr_url`) are
skipped with the reason, which is what makes a second run at 19:05 arm nothing
at all.

**Capacity, honestly estimated.** Per station,
`CLAUDE_CONFIG_DIR=~/accounts/<name>/claude npx -y ccusage@latest blocks --json
--offline` reads that station's *own log files* — no endpoint is contacted, by
anyone, anywhere in this script. Headroom is measured in output tokens, the
only unit available on both sides of the sum: the ceiling is the busiest
completed five-hour block ccusage can still see (or `QM_TOKEN_LIMIT` when you
know your real one), and what is left of it in the current block is the proxy
for tonight's capacity. One run costs the median
`metrics.implementer_usage.output_tokens` over the last `QM_HISTORY` runs, so
the estimate is this machine's own history rather than a guess. Then
`N = floor(remaining × QM_SAFETY / median cost)`, capped at `QM_MAX_PER_CREW`.
It is an estimate, and the safety factor is there because it is one — when
ccusage cannot account for a station at all, the report says so and falls back
to `QM_FALLBACK_N` rather than inventing a number.

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
to `schedule.sh` with that station's environment exported — `CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `GH_CONFIG_DIR`, `HARNESS_OWNER`, `IMPLEMENTER_EFFORT=high` — so
the snapshot `schedule.sh` writes carries the right identity to 02:00. A
`GH_TOKEN` exported in the invoking shell is *unset* for that call: `gh` prefers
a token over its config dir, and one would quietly make every crew member's PR
come out of the same account. Each armed ticket then gets a Linear comment
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
| `QM_ACCOUNTS_DIR` | Where the crew's stations live | `~/accounts` |
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
`QM_AUTOBRIEF_MAX_BODY`, `QM_REPO_ROOTS` and `QM_REPO_DEPTH` are described in
the self-briefing paragraph above.

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

**Processes.** Any process whose name exactly matches `JANITOR_PROC_MATCH`
(`flutter_tester`) and whose `ps` elapsed time is over `JANITOR_PROC_AGE` (two
hours) is reaped: `TERM`, then `KILL` if it is still there a couple of seconds
later. Nothing legitimate keeps a detached test runner alive for hours, so age
is the whole test. Younger ones are counted and left.

**The two modes.** `janitor.sh` and `janitor.sh --report` are the same
side-effect-free listing of every worktree the harness still holds and what
would happen to it; `janitor.sh --clean` is the one that acts. `--install`
writes a daily launchd agent — one fixed label, the `LABEL_ID` in `janitor.sh`,
with `JANITOR_AT` to move it off 09:00 — on the quartermaster's conventions: a
mode-600 wrapper carrying an environment snapshot, because launchd hands a job
almost nothing. `GH_CONFIG_DIR` rides along in that snapshot, since it decides
which account can read a PR's state; `GH_TOKEN` deliberately does not. It only
reports until you decide otherwise, and `--install --clean` is the one-line flip
to letting it sweep. macOS only, like `schedule.sh` — `--report` and `--clean`
themselves run anywhere. `install.sh` does *not* arm the schedule: installing it
stays an explicit act.

| Env var | What it does | Default |
| --- | --- | --- |
| `JANITOR_AT` | When `--install` fires | `09:00` |
| `JANITOR_PROC_AGE` | Seconds a matching process may live | `7200` |
| `JANITOR_PROC_MATCH` | Process name to reap (empty is refused, not defaulted) | `flutter_tester` |
| `JANITOR_GH_TIMEOUT` | Seconds allowed for each `gh` call | `20` |
| `JANITOR_OUTCOME_MAX_AGE` | Days after which a terminal PR's `outcome.json` stops being refreshed | `14` |

What leaves the machine: one read-only `gh pr view` per run that has a PR, plus
— while that PR's outcome is still being refreshed — one read-only `gh api` call
for its review comments, and nothing else. `--clean` exits non-zero only when a
sweep it decided on could not be carried out, so a nightly agent's log is quiet
until something is actually wrong.

## Ticket sync

An overnight run has no orchestrator watching for its result. When a run
reaches `ready` and its run id starts with a `TEAM-123` identifier, the
pipeline comments the draft-PR link on the Linear ticket and moves the ticket
to its team's **In Review** state (matched against the team's real state
names, "In Review" by name first, else the `started`-type state mentioning
"review"). It reads the same `linear-api-key` file the quartermaster uses,
logs everything to `runs/<RUN-ID>/ticket-sync.log`, and is strictly
best-effort — a Linear hiccup never fails a run. `HARNESS_TICKET_SYNC=0`
disables it. Ad-hoc runs (no ticket-shaped id) are skipped automatically.

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

The target is a machine you already trust with the run dir: mirroring copies
briefs, feeds and worker logs onto it, and gives it whatever your ssh key gives
it. Point it at your own wall, not at a shared box.

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

On a frontend run whose brief includes a Demo storyboard, the implementer writes
the shot-scraper file and the pipeline can record it against a dev server inside
the worktree — so the PR body carries a video of the change instead of a
description of it. `DEMO_DEV_CMD` pins the command used by `demo-auth.sh`, and
`DEMO_PORT` pins the storyboard origin and lets the recording stage reject a
busy port; both live in [the repo pin](reference.md#the-repo-pin). Recording is
enabled only when `shot-scraper` is installed and `demo.conf.sh` names a valid
`rclone` remote. Then `shot-scraper` records, `ffmpeg` transcodes and builds the
preview GIF, and `rclone` uploads both before the PR body is updated. Without
that upload configuration the stage is skipped, and the run is otherwise
unaffected. A site behind a login gets its session captured once, by hand, with
`demo-auth.sh` — which falls back to `python3` running `auth-capture.py` when
`shot-scraper` was installed outside uv's default tool directory. Every part of
this is guarded: a missing binary or a failed recording never fails a run.

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
CODEX_HOME=~/.codex-fallback codex login
```

On a headless machine, the login callback lands on `localhost:1455`, so forward
that port over the ssh session you run the command in (the same tunnel the
onboarding docs use) and open the printed URL on your laptop:

```bash
ssh -t -L 1455:localhost:1455 mini
```

`HARNESS_CODEX_HOME_FALLBACK` is the only knob this adds
([reference](reference.md#the-review-stage)); unset, behaviour is
byte-identical to a single-account harness.

One global knob, deliberately: with [crew stations](#the-quartermaster) every
station's runs share the same fallback account, and rotation beyond two accounts
is not something this does. Two accounts and one rule is the whole feature.
