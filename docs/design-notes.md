# Design notes

Why some of the pipeline's stranger behaviours exist: the incidents that
produced them, the numbers from the run corpus, and how to read the harness's
report on itself.

Nothing here is needed to use the harness. It is the record of what went wrong
before a rule existed, kept because a rule whose reason is lost gets deleted by
the next person who finds it annoying.

## What the corpus taught the pipeline

Four of the pipeline's self-recovery rules are answers to measured waste:

- **Mid-run session limits were the single biggest sink** in the corpus that
  motivated the [capacity self-resume](operations.md#capacity-preflight-a-run-that-defers-itself):
  25 attempts and 8.6 hours burned, most of them recoverable. A window that
  empties mid-flight now defers and re-arms itself instead of recording
  `implementer_failed`.
- **A turn ceiling pinned at 120 killed eight runs** — nearly always at the
  finish line, mid-wrap-up, writing the notes or staging the diff. The recovery
  was always the same: a human noticed, re-dispatched, and the resumed session
  finished in minutes. So `run-task.sh` [does that itself](operations.md#turn-ceiling-a-run-that-resumes-itself).
- **Re-dispatch used to destroy the evidence it was recovering from.** Every
  invocation truncated `opus-stream.jsonl`, `gate-rounds.log` and `opus.log` on
  the way in; in one 46-run corpus that cost the turn counts and gate detail of
  all 36 failed attempts, unrecoverable. They are
  [rotated now](operations.md#attempts-a-run-is-a-ticket-an-attempt-is-a-dispatch).
- **Five runs in that same corpus were re-armed *after* reaching `done: ready`**,
  burning 3.9 hours on work that was already in a PR — and one of them came back
  `push_failed`, turning a finished run into a broken one. A finished run is
  [not dispatched again](operations.md#attempts-a-run-is-a-ticket-an-attempt-is-a-dispatch)
  without `HARNESS_REDISPATCH=1`.

## Reading the pipeline's own vitals

The harness reports on itself. Everything below comes out of the `result.json`
files and nothing else — no logs, no worktrees — so it works on a mirrored runs
directory and on runs whose worktrees are long cleaned up:

```bash
~/.claude/harness/metrics.sh --report
```

```
pipeline vitals · 179 runs · 2026-08-06 19:04
/Users/you/.claude/harness/runs

STATUS                   RUNS      %
ready                     120   67.0
gate_failed                31   17.3
…
runs reaching ready (last attempt)   120   67.0

REVIEW                   RUNS      %
reviewed                  140   78.2
skipped                    30   16.8
reviewed_claude             7    3.9
failed_silent               2    1.1
pre-telemetry              28   15.6
silent review failures      2   <- these diffs are UNREVIEWED
fallback-account reviews    3   <- the primary Codex account needs topping up
claude-tier reviews         7   <- the review was not cross-vendor
held: review_failed         2   <- no PR opened; re-dispatch once a reviewer works

ATTEMPTS                COUNT      %
attempts total            240
reaching ready            120   50.0
capacity self-resumes       9   <- deaths the run recovered from on its own

ATTEMPT DEATHS          COUNT      %
implementer_failed         48   20.0
gate_failed                31   12.9

PER RUN              MEDIAN       P90      N
attempts                1.0       3.0    179
idle gap mins           1.6     216.0     61
turns                    34        78    147
wall minutes           22.4      58.1    179
output tokens         41200     98000    140
gate seconds            184       402    170
turns vs cap     2 of 147 runs report more CLI turns than their pinned ceiling

GATE FAILURES          FAILED      %
round 1                   134   74.9
round 2                    24   17.9
round 3                     6   25.0

FAILED GATE STEP               ROUNDS
npm run type-check                 18
npm test                            7

RESUMES               12 of 179 runs resumed (6.7%) · 15 resumes total

REPO                     RUNS  MED_MIN  MED_TURNS  READY%
myapp                      80     24.1         36    70.0
```

Read it in this order: **silent review failures** first (those diffs are
unreviewed — see below), then **ATTEMPT DEATHS** and the **idle gap** (what the
machine actually spent, and how long a dead attempt waited to be noticed), then
**GATE FAILURES** and **FAILED GATE STEP** (which round fails, and the step names
what to fix first), then the medians for cost. Medians and p90s are nearest-rank
over the runs that recorded the field — the `N` column says how many those were,
so a partial history is visibly partial instead of silently averaged with zeros.

Three labels earn their length:

- **runs reaching ready (last attempt)** — `result.json` only ever describes the
  attempt that wrote it, so run-level success is a last-attempt number. The
  attempt-level rate in `ATTEMPTS` is the one that counts what was spent.
- **GATE FAILURES, not gate rounds** — a second round is the *design* (gate,
  review, re-gate), so counting rounds made the norm read as an 88.6% retry
  rate. The share here is, of the runs that ran round *N*, how many failed it.
  Base-sync re-gates are recorded in `result.json` but left out.
- **pre-telemetry** — a run whose `result.json` predates the `review` field.
  Reported as "(not reached)" it hid 28 perfectly good reviews behind a label
  that claimed the stage never ran.

**Turns and the ceiling count different things.** `metrics.implementer_num_turns`
is the CLI's own `num_turns`, summed over every
[turn-ceiling segment](operations.md#turn-ceiling-a-run-that-resumes-itself) of
the invocation; `metrics.implementer_max_turns` is the `--max-turns` a single
spawn was given, and a resumed one is given it again. A segment can honestly
report 206 against a pinned 200 — they are the CLI's counters for different
things, not two readings of the same budget. The report reconciles them in one
line (`turns vs cap`) instead of leaving a phantom violation on the table;
`metrics.implementer_segments` is what says how many spawns the sum covers.

### Which gate step failed

Each entry in `metrics.gate_rounds` carries `seconds` and `failed_step`. The
step is captured by the gate's own shell, with two traps that between them
always name the command that actually returned nonzero: a `DEBUG` trap records
each top-level command just before it runs, and an `ERR` trap (under `set -E`,
so it is inherited by functions, subshells and command substitutions the DEBUG
trap never enters) overwrites it with the command that failed. DEBUG alone once
blamed a chain's *previous* step for a failure inside a subshell; `set -T` would
have mis-blamed the helpers bash runs while expanding a step's arguments.
Nothing about how your `GATE_CMD` runs changes, the gate log is byte-identical
(the traps write nowhere near it), and no test output is parsed. Only failing
rounds record a step. The side file the traps write to is
[`HARNESS_GATE_STEP`](reference.md#not-a-knob-harness_gate_step), which is not
yours to set.

## When the review stage does not happen

A review that leaves *no* fix commits, *no* `findings.json`, *no*
`review-notes.md` and *no* `REJECTED.md` has proven nothing about the diff. The
findings file counts for the same reason the notes do — since
[find, refute, fix](reference.md#find-refute-fix) the review pass changes nothing
by design, and a review that reported five defects and touched no code is the
most engaged review there is. Evidence decides, never
duration: a fast "everything is sound" review that writes its notes is a real
review. Duration only decides whether a *Codex retry* is worth paying for — a
stage that produced no evidence at all in less time than the diff takes to read
is the signature of a reviewer that never started (auth prompt, CLI crash, empty
context), so the review is run **once more** on the Codex side. What duration
never decides is whether the diff ships: an empty review that spent real time
(or that ran on a diff too small for the floor to mean anything) buys no second
Codex pass, but the
[Claude tier](operations.md#when-codex-dies-mid-run-out-of-credits) still gets
it.

Only when *that* also produces nothing does the run stop, and then it says so
everywhere it can: `review: failed_silent` in `result.json`, the pinned arm left
unchanged, a `review failed silently — diff is unreviewed` stage line, the
same words in the macOS/ntfy notification, and the terminal `done: review_failed`
push naming the last tier to fail. The pinned arm in the run dir is left alone,
so a re-dispatch still attempts a real review.

The floor and the trivial-diff exemption are
[`HARNESS_REVIEW_MIN_SECONDS` and `HARNESS_REVIEW_TRIVIAL_LINES`](reference.md#the-review-stage).

## When the post-review gate is skipped

Gate #2 re-ran the entire suite on a byte-identical tree in 16 of 46 runs — the
reviewer had committed nothing, so the round verified exactly what round 1 had
verified minutes earlier, at a couple of wasted minutes per run. A gate is a
function of the tree, so that round's verdict is knowable without spending it.

The stage is not going anywhere (it caught its first real reviewer-introduced
regression the same week). Only the provably-redundant case goes: `HEAD` is
captured when the review stage starts — before the *first* tier, so it counts a
commit from Codex, its retry or the Claude reviewer alike — and if it is
unchanged when the round comes due, the round is recorded rather than run:

```
test gate #2 skipped — review committed nothing
```

— with a `2 skipped 0` row in `gate-rounds.log` (the same additive shape, a
third value beside `pass`/`fail`) and `{"round":"2","result":"skipped",...}` in
`metrics.gate_rounds`. **The verdict that stands is round 1's**, so a gate that
was already failing still reaches the fix round exactly as before. Any commit at
all — any tier's, or an earlier fix round's — and the round runs as it always
has.

## What the reviewer is allowed to reach

`codex` runs under its `workspace-write` sandbox, which denies network — and
denies **loopback** with it. That is not academic: Flutter's test harness could
not bind its socket and DB-backed jest suites could not reach a local Postgres,
so on those repos the reviewer argued about the code instead of running it, on a
pipeline whose review is the only defect detection after the implementer.

The Codex reviewer gets loopback, and nothing else. Two things, together:

**Sandboxed networking, scoped to the loopback destinations.** Not
`sandbox_workspace_write.network_access`, which is all-or-nothing and would hand
an unattended reviewer the LAN and the internet. Instead
`features.network_proxy` with a permission profile whose domain map allows
exactly `localhost`, `127.0.0.1` and `::1`. Everything else is denied because
nothing allows it — there is no `"*"` entry, and an absent allow rule already
denies. `allow_local_binding` is on because allowlisting a loopback target is
[not sufficient on its own](https://github.com/openai/codex/issues/33227) and
Flutter's runner has to *bind* a socket rather than merely reach one; that
widens the sandbox to local and private ranges and no further. The enabled arm
drops the explicit `-s workspace-write` selector, which codex 0.145 treats as
authoritative and which would otherwise silently override the profile.

**A harness-owned `CODEX_HOME` per account and run.** `codex` reads rules,
plugins and MCP servers out of `CODEX_HOME`, and a developer's
`rules/default.rules` records every command they ever approved — `git push` and
`gh` among them. Note what that means: `worker-settings.json` is a *Claude*
settings file and no `codex` invocation consumes it, so its deny list has never
been the Codex reviewer's boundary. So each attempt runs out of
`<account home>/harness-review/<run-id>/`, a directory the harness writes: the
policy above and nothing else. No rules, no plugins, no MCP servers. Per run, so
parallel tickets never overwrite each other's filesystem policy while a `codex`
process is starting. Auth is the one thing inherited, through a symlink to that
account's own `auth.json` — nothing is copied, nothing leaves the account's
tree, nothing is logged, and a token the attempt refreshes is moved back to the
account's own file. Per account, so this composes with
[`HARNESS_CODEX_HOME_FALLBACK`](operations.md#a-second-codex-account-for-a-dry-primary).

The cost of that isolation is the thing to know before you turn it on: the
review also stops inheriting the *benign* half of your `config.toml` — a custom
model provider, say, or a proxy. The harness passes the model and effort knobs
itself, so a stock ChatGPT-subscription setup needs nothing else; if yours does,
[`HARNESS_REVIEW_NETWORK=0`](reference.md#the-review-stage) puts the reviewer
back on your own config.

**It fails closed.** The network can only ever come from the profile; nothing
sets `network_access`. A `codex` build that ignores the profile therefore leaves
the reviewer with today's sandbox rather than an open one. If the isolated home
cannot be built, Codex is not started on the operator's ambient config: the
isolated fallback account gets its attempt, or the Claude review tier takes it.

None of this touches the [Claude reviewer tier](operations.md#when-codex-dies-mid-run-out-of-credits):
that one runs under `worker-settings.json`, which confines it already.

The same posture applies to `sync-pr.sh`'s conflict resolver, a deliberate
mirror of `run-task.sh`'s `codex` invocation: it is told to re-run the tests
relevant to the conflicted files, and it had the same problem — and the same
inherited `git push` rule.

What is *not* pinned here: whether your `codex` build enforces the profile it is
handed. `tests/review-truth.test.sh` pins the policy the harness assembles and
the argv that selects it, then probes a real `codex sandbox` when one is on the
machine — binding loopback under the profile, refusing a public host, and
running the same bind under a bare `CODEX_HOME` as a control so a build that
allowed loopback all along cannot read as this feature working. Where the CLI is
absent or will not run the probe, the suite prints `skip` rather than a pass.

## The verifier: why a third vendor

The operational metrics say how long, how many turns, how many rounds, how many
lines. None of it says how well a run satisfied its brief, so the corpus could
not be sorted by quality and the paired experiment in
[`bench/DESIGN.md`](../bench/DESIGN.md) had no cheap proxy. Hence the
[verifier](reference.md#the-verifier).

The verifier runs on DeepSeek, on Gemini via Vertex (as a service-account
principal), or on any OpenAI-compatible server, which enforces the rule the
review stage already follows: no model grades its own homework. It is not enough
on its own — self-preference bias is capability-independent and survives being
asked politely for impartiality — so the evidence is anonymised on the way out:
every vendor and model name becomes the `IMPLEMENTER`/`REVIEWER` role that wore
it, and the judge cannot tell whose work it is grading.

**A vector, not a scalar.** One number over a whole trajectory is close to
uninterpretable: judges are noisy on long agentic-coding outputs, they prefer
their own family, and they reward length — which would make the score rise with
exactly the bloat it should be penalising. So five fixed rubric items are scored
independently, one call each, K samples apiece aggregated by median; every
sample must quote the diff hunk or trajectory line that decides it, and one that
cannot is worth 0 however confident its number; and the headline is the plain
MEAN of the items, an aggregate nothing about trajectory length can move. Four
of the five items read the DIFF against the brief's acceptance criteria as a
pre-stated spec, which is the regime that measures the fewest false positives;
only resume coherence reads the trajectory, and only when the run actually
resumed.

**It is advisory, and it never gates.** No status, no gate verdict, no PR
decision, no ready-promotion and no notification priority depends on the number.
A verifier that is off, unkeyed, uninstalled, timed out, crashed or writing
garbage leaves the run byte-for-byte what it would have been — same `status`,
same `pr_url`, same PR body. It is data.

**What it costs.** `items × K` calls: 15 with the defaults, 12 for a run that
never resumed. The prompts are a few hundred characters and each answer is one
small JSON object, so the bill is the evidence — a diff item carries at most a
quarter of `HARNESS_VERIFY_MAX_CHARS` and the one trajectory item all of it,
which is ~600k input tokens in the worst case against the ~2.7M of the
single-scalar design it replaced. `HARNESS_VERIFY_EVALS=1` and a smaller
`HARNESS_VERIFY_MAX_CHARS` are the dials, in that order of effect.

## The public-benchmark experiment

[`bench/DESIGN.md`](../bench/DESIGN.md) specifies a **paired** comparison on a
100-instance sample of SWE-bench Verified — arm A (single agent) vs. arm B
(this pipeline) vs. optional arm C (gate-only) — scored by the official
`swebench` harness and analysed with McNemar's test on the discordant pairs.
It is a design document (no adapter code ships here); the ablation knobs it
relies on are [in the reference](reference.md#ablation-knobs).
