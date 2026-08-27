# Reference

Every knob and every file: the environment variables the pipeline reads, the
per-repo pin, the local config files, what a run leaves on disk, the monitoring
surfaces, and the metrics a run records.

The narrative for most of these is in [operations](operations.md); the reasoning
behind the odder ones is in [the design notes](design-notes.md).

## Environment variables

`HARNESS_*` is the pipeline. Set them on the `run-task.sh` invocation (or export
them before `schedule.sh`, which snapshots the whole set into the job it arms).
`QM_*` belongs to the overnight quartermaster. Its operational narrative and
primary table live with [The Quartermaster](operations.md#the-quartermaster);
the complete set is repeated here so this page remains the lookup for every
environment variable.

### The Quartermaster

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
| `QM_AUTOBRIEF` | `1` lets `--arm` write a missing brief; `0` requires one already approved | `1` |
| `QM_AUTOBRIEF_TIMEOUT` | Seconds allowed for each self-briefing planner call | `1200` |
| `QM_AUTOBRIEF_MODEL` | Model for self-briefing | the station's default |
| `QM_AUTOBRIEF_MAX_BODY` | Ticket-description bytes handed to the planner | `60000` |
| `QM_SPEC_CRITIC` | `1` requires [the spec critic](#the-spec-critic) to return a verdict for every self-written brief and holds it back on a contradiction; `0` publishes unread | `1` |
| `QM_REPO_ROOTS` | Space-separated roots searched for repos named by briefs | `~/Projects` |
| `QM_REPO_DEPTH` | Maximum discovery depth below each repo root | `3` |
| `LINEAR_API_KEY_FILE` | The Linear key (mode 600, never echoed anywhere) | `$HARNESS_DIR/linear-api-key` |

### Capacity and deferral

See [Capacity preflight](operations.md#capacity-preflight-a-run-that-defers-itself).

| Env var | What it does | Default |
| --- | --- | --- |
| `HARNESS_PREFLIGHT` | `off` disables the capacity preflight *and* the mid-run classifier | `on` |
| `HARNESS_MIN_SESSION_TOKENS` | Output-token headroom a dispatch wants before it will spawn | `20000` |
| `HARNESS_DEFER_BUFFER_SECS` | Clearance added past the block's reset time when arming | `300` |
| `HARNESS_MAX_DEFERRALS` | Auto-deferrals allowed per run before it fails honestly | `2` |

### Turn ceiling and resumes

See [Turn ceiling](operations.md#turn-ceiling-a-run-that-resumes-itself).

| Env var | What it does | Default |
| --- | --- | --- |
| `HARNESS_MAX_TURNS` | Turn ceiling for the implementer's session; pinned at first dispatch | `200` |
| `HARNESS_MAX_RESUMES` | Automatic resumes allowed on turn exhaustion before the run fails (`0` opts out) | `2` |
| `HARNESS_RESUME_MODE` | What a turn-ceiling resume hands the next segment: `report` (fresh session + a written handover) or `transcript` (`--resume` into the exhausted session); pinned at first dispatch | `report` |

### Dispatch and identity

| Env var | What it does | Default |
| --- | --- | --- |
| `HARNESS_DIR` | Where the harness is installed. Every script honors it; install with `HARNESS_DIR=/path ./install.sh` | `~/.claude/harness` |
| `HARNESS_OWNER` | Who dispatched the run. Pinned into the run dir on the first dispatch, so a resume from someone else's session never re-attributes it | your login name |
| `HARNESS_REDISPATCH` | `1` dispatches a run that already reached `done: ready` | unset |
| `HARNESS_SKIP_PUSH_PREFLIGHT` | `1` skips the setup-time push-auth check. Setup does a `git push --dry-run` against `origin` so a missing push credential (`GH_TOKEN`) fails the run in seconds as `setup_failed` instead of after implement → gate → review → verify; an anonymous read (the setup fetch) passes on a public repo, so only the write path proves the credential. Non-auth push errors never block setup — they are left to the real push at the end. Set this for a local-only dispatch whose remote genuinely cannot take a dry-run push. | unset |
| `HARNESS_TICKET_SYNC` | `0` disables the [ticket sync](operations.md#ticket-sync) that comments the PR and moves the ticket to In Review | `1` |
| `HARNESS_MIRROR` | ssh target (`host:path`) or local path a live run dir is mirrored to — see [Runs from any machine](operations.md#runs-from-any-machine-harness_mirror) | unset |

### Notifications and monitoring

`notify.conf` is the usual home for the first three; the shipped
`notify.conf.example` documents them too.

| Env var | What it does | Default |
| --- | --- | --- |
| `HARNESS_NTFY_TOPIC` | ntfy topic every stage handoff is pushed to. Empty disables phone push | empty |
| `HARNESS_NTFY_SERVER` | Self-hosted ntfy server | the public [ntfy](https://ntfy.sh) service |
| `HARNESS_NOTIFY` | `0` silences the local desktop banners (macOS `osascript`) | `1` |
| `HARNESS_WATCH_INTERVAL` | Seconds between redraws in `status.sh --watch` | `2` |
| `HARNESS_STALE_SECS` | How long a run whose status has not moved stays on the statusline | `21600` (6h) |

### The review stage

See [When Codex dies mid-run](operations.md#when-codex-dies-mid-run-out-of-credits),
[Find, refute, fix](#find-refute-fix) and
[What the reviewer is allowed to reach](design-notes.md#what-the-reviewer-is-allowed-to-reach).

| Env var | Effect | Default |
| --- | --- | --- |
| `HARNESS_REVIEW_REFUTE` | `0` skips the refutation pass: every finding is promoted unchecked, which is the single-pass review this replaces. Recorded as `refute: "off"` in `review_findings`, and stated in `review-notes.md` — a run that skipped refutation never looks like one that passed it. | `1` |
| `HARNESS_REFUTE_TIMEOUT` | Seconds the refutation pass may spend. It sits between a review that happened and the fixes that depend on it, so it is time-boxed harder than the review itself; on expiry it leaves no verdicts and every finding is promoted. | `900` |
| `HARNESS_REVIEW_MIN_SECONDS` | Floor below which a review that produced no evidence is treated as a stage that never ran (and retried once on the Codex side). | `60` |
| `HARNESS_REVIEW_TRIVIAL_LINES` | Changed lines vs. base at or below which the floor does not apply — a two-line diff genuinely can be reviewed in seconds. A diff whose size cannot be *read* (a base ref that is not there, a worktree that moved) is unknown rather than small, and gets the retry. | `20` |
| `HARNESS_REVIEW_NETWORK` | `0` restores the old sandbox exactly: no loopback, no isolated config dir, and a `codex` command line and environment byte-identical to what they were before this existed. Anything else (or unset) enables both. | `1` |
| `HARNESS_CODEX_HOME_FALLBACK` | `CODEX_HOME` of a second Codex account the review retry uses when the primary is out of credits (or came up empty). Unset: behaviour is byte-identical to a single-account harness. | unset |

### Ablation knobs

Three of these turn a normal run into a controlled **arm** — the same brief run
*without* the review stage, or with a *different* implementer model, or with a
*different implementer vendor* — so you can measure what each stage buys. All
are **pinned at first dispatch**: the chosen arm, provider, models and efforts
are written into the run dir on the first invocation and reused verbatim on
resume, so a re-dispatch whose environment differs can't silently switch a run
to a different condition. With **none** of them set, control flow is identical
to before — this is instrumentation, not a redesign.

| Env var | Effect | Default |
| --- | --- | --- |
| `IMPLEMENTER_PROVIDER` | Which vendor the implementer bills to: `anthropic` (the Claude subscription) or `zai` ([GLM as the implementer](#glm-as-the-implementer)). Resolved **repo pin → ambient env → default**: a [repo pin](#the-repo-pin) outranks the value this shell exports. Recorded in `result.json` as `implementer_provider`. An unrecognised value falls back to `anthropic`, says so once, and re-pins. | `anthropic` |
| `IMPLEMENTER_MODEL` | Model passed to the implementer's `--model`; recorded in `result.json`. Resolved **repo pin → ambient env → provider default**, independently of the provider setting. Always an explicit model ID — an alias like `opus` silently changes meaning when a new Opus ships. | `claude-opus-5`, or `glm-5.3` on `zai` |
| `IMPLEMENTER_EFFORT` | Effort passed to the implementer's `--effort` (`low`/`medium`/`high`/`xhigh`/`max`). `high` has held quality on our runs; raise to `xhigh` per dispatch where a task proves harder than usual. | `high` |
| `REVIEWER_MODEL` | Model for every `codex exec` call (review, fix rounds, base-sync conflicts); recorded in `result.json`. Pinned here so the pipeline never depends on `~/.codex/config.toml`. Ignored — and recorded blank — when the `codex` CLI is absent. | `gpt-5.6-sol` |
| `REVIEWER_EFFORT` | `model_reasoning_effort` for every `codex exec` call. Sol also accepts `max` and the subagent-spawning `ultra` for harder repos — both cost more per pass. | `high` |
| `HARNESS_ESCALATION` | `on` \| `off` — whether a gate failure on the cheap implementer buys one pass on the Claude subscription ([Escalation](#escalation)). Defaults to `on` wherever the implementer is not already `anthropic`, `off` when it is (there is nothing to escalate to). An unrecognised value falls back to that default, says so once, and re-pins. | `on` on `zai`, `off` on `anthropic` |
| `HARNESS_ESCALATION_STEPS` | Comma-separated classes of failing gate step that may escalate: `test`, `lint`, `type-check`, `build`, `unknown`, or `all`. A value naming a class that does not exist falls back to the default and says which one. | `test,lint,type-check` |
| `HARNESS_SKIP_REVIEW` | `1` skips the review stage **and** its fix rounds — the `no_review` arm, and the only arm that ships without a review. The gate still runs (a failing gate still yields `gate_failed`), and base-sync conflict resolution still runs (it is PR mechanics, not quality review — on codex when it is installed, otherwise on a Claude worker). A machine with no `codex` CLI pins `claude_only` instead and reviews on the Claude tier: see [Claude-only mode](operations.md#claude-only-mode). | unset (`full` arm) |
| `HARNESS_DETACH` | `0` keeps the driver in the foreground. By default `run-task.sh` re-execs itself into its own session (fork + `setsid`) before anything expensive starts, so a stopped or killed launcher can no longer take the pipeline down with it — the failure that used to leave a run dead mid-stage with no verdict and a still-growing `IN STAGE` timer. Set `0` where the caller must stay the parent: `gate.sh` pins it for the suites, and `schedule.sh`'s launchd wrapper needs `launchctl bootout` to keep owning the run. A caller-supplied `HARNESS_DIR` (every test fixture) also suppresses the detach on its own, says so on stderr when it does, and is overridden by an explicit `HARNESS_DETACH=1` — `HARNESS_DIR` is also the documented way to install elsewhere, so a value exported in a shell profile must not silently turn detaching off for every dispatch on the machine. | unset (detach) |
| `HARNESS_DEAD_AFTER` | Seconds of heartbeat silence after which `status.sh` and `statusline.sh` call a run dead rather than slow. The driver touches `heartbeat` every `HARNESS_HEARTBEAT_SECS`, so this only has to outlast one interval plus a stalled disk. A run whose dir predates these files answers "cannot tell" and renders exactly as it always did. | `120` |
| `HARNESS_HEARTBEAT_SECS` | How often the driver's ticker touches `<run>/heartbeat`. The ticker follows the driver's pid, so a driver killed outright leaves nothing behind past one interval. | `20` |
| `HARNESS_GATE_LOCK` | `0` runs the deterministic gate unserialized. By default every gate round takes an exclusive per-repository lock, because two runs on one repo share that repo's test database: gating them concurrently produced Postgres deadlocks, seeder unique-constraint failures and dozens of phantom test failures that belonged to neither branch. Only the gate rounds serialize — implementer and review stages still run in parallel. | unset (serialize) |
| `HARNESS_GATE_LOCK_KEY` | Overrides the lock key, which defaults to the repo directory's basename so that two parallel checkouts of the same repo (`workspace-1/api`, `workspace-2/api`) contend with each other — they share one local database. Set it to separate two checkouts that genuinely have their own, or to join two that share one under different names. | repo basename |
| `HARNESS_GATE_LOCK_WAIT` | Seconds a run waits for a gate lock it cannot make sense of — an unreadable owner, a holder that vanished mid-claim — before giving up and gating unserialized (saying so). It is **not** a licence to barge past a holder that is demonstrably running: gating beside a live gate is the collision the lock exists to prevent, so a live holder is waited on for as long as it lives and the stage text names it throughout. | `3600` |
| `HARNESS_GATE_LOCK_POLL` | Seconds between attempts while waiting for the gate lock. | `5` |

```bash
# Baseline arm: same brief, no cross-vendor review, on Sonnet
HARNESS_SKIP_REVIEW=1 IMPLEMENTER_MODEL=sonnet \
  ~/.claude/harness/run-task.sh <TICKET> <repo-path> <branch-name>
```

### GLM as the implementer

z.ai serves the GLM Coding Plan over an **Anthropic-compatible endpoint that
officially supports the Claude Code CLI** — the same binary, the same
`stream-json`, the same `--resume` — so the whole integration is a key file and
four environment variables. Drop the credential and pin the provider:

```bash
(umask 077; printf '%s' '<your-z.ai-key>' > ~/.claude/harness/zai-api-key)
IMPLEMENTER_PROVIDER=zai \
  ~/.claude/harness/run-task.sh <TICKET> <repo-path> <branch-name>
```

Like `linear-api-key` and `verifier-api-key`, that file is **not seeded by the
installer, because it is a credential** — you create it by hand, mode 600.
`ZAI_API_KEY_FILE` moves it. Only the implementer's own subshell ever gets the
token, and it is exported there rather than passed as an argument, so it appears
in no `ps` listing, no log, no `result.json` and no PR body.

**What moves, and what does not.** The provider is the *implementer's* alone.
`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `API_TIMEOUT_MS` and the small
model used for the CLI's background work and the worker's `Explore` subagents
are applied at one place — the function that spawns an implementer segment — so
every resume path (the turn ceiling, a mid-run capacity deferral, a scheduled
re-dispatch) is billed to the account the run was pinned to. The reviewer, the
Claude review tier, its fix rounds, the conflict resolver and `sync-pr.sh` are
untouched and stay on Anthropic/Codex; the Claude tier spawns with
`claude-opus-5` rather than the implementer's GLM id, which would be a usage
error against Anthropic. An Anthropic implementer also clears these z.ai-only
variables inside its spawn, so a shell used for `attach.sh` cannot leak the
compatible endpoint into a later Anthropic handoff. One nice consequence: with
a `zai` implementer even the *Claude* review tier is a cross-vendor read, so the
fallback described in [the review guarantee](design-notes.md#why-its-built-this-way)
loses nothing.

**Models.** `glm-5.3` is the default; `glm-5.3[1m]` is the 1M-context variant,
and pinning it also sets the CLI's auto-compaction window to match. `glm-4.7` is
the small/fast model. `IMPLEMENTER_EFFORT` is passed through unchanged and maps
server-side: `xhigh`/`max` → max, `medium`/`high` → high, `low` → low.

**Capacity.** The [preflight](operations.md#capacity-preflight-a-run-that-defers-itself)
reads the station's own Claude logs, which say nothing about a z.ai window, so
it is **skipped** — with the reason written to `capacity.log` — rather than
deferring a run that had everything it needed to spend.

**Failures.** z.ai's own vocabulary is classified alongside Claude's: an
exhausted quota, and error `1113` / `Insufficient Balance`, defer the run the
way a session limit does (ccusage is not consulted for the reset, so the wait
falls back to the standing default). The one exception is the failure waiting
cannot cure: `1113` is also what a **wrong base path** returns, so an attempt
on a run that has *never streamed a single token* ends `setup_failed`, naming
the credential and the endpoint to check, instead of re-arming itself in a
circle. Once the run has streamed output, a later first-request rejection is a
mid-run balance event and defers normally.

**Attaching.** When a `zai` run's provider environment is absent, `attach.sh`
prints the exports an interactive resume needs — the key's path, never the key
— and asks you to rerun it after exporting them. It never opens the session
against the wrong endpoint.

### Escalation

The implementer is chosen once per run, and until now that choice was the run's
last word: work that failed the test gate on the cheap tier ended the run on
`gate_failed` and waited for a human. Escalation makes the cheap choice a
**first** choice instead — the gate's own verdict is the evidence that buys one
pass on the Claude subscription.

**When it fires.** After the gate and the [integrity check](#the-gate-integrity-check),
before the review, on a run that would otherwise reach `gate_failed`: the gate
failed, `escalation` is `on`, the implementer is not already `anthropic`, and
this run has not escalated before. The review is deliberately downstream of the
decision — a diff the gate rejects is not worth a reviewer's pass, and the
escalated attempt is gated, integrity-checked and reviewed exactly like the
first one.

**What it does.** It writes the handover the turn ceiling already writes (the
previous session's [segment report](operations.md#turn-ceiling-a-run-that-resumes-itself))
plus the gate's verdict on it — the failing step, the clipped gate extract, the
diff stat — re-pins `implementer-provider` to `anthropic` and
`implementer-model` to that vendor's default, and starts the run again. One
fresh session gets the original brief, the same "this is an external artifact,
the brief is the contract" framing the turn-ceiling handover uses, and the
partial work still standing in the worktree.

The escalation guard, target provider/model, and pending flag are published
together in one atomic `escalation.json` update. A re-dispatch takes its target
from that record rather than from separately-written pins, so an interrupted
handoff remains complete and resumable.

The handover is a **new attempt**, not a second segment of the failing one, so
`attempts/<n>/` keeps the cheap tier's stream, gate rounds and final message and
the escalated attempt's turn counts and token usage are the Claude
subscription's alone. Two things follow for free: the escalated segment pays the
[capacity preflight](operations.md#capacity-preflight-a-run-that-defers-itself),
because it is the Claude window it spends now; and a deferral there defers the
*escalation* — the handover stays armed and the evidence that earned it stays on
disk — rather than losing the run.

**The guards.** Each of them refuses out loud, in the run's log:

- **Never twice.** One escalation per run; a second gate failure ends it on
  `gate_failed` with the escalation recorded.
- **Never on a flagged attempt.** Non-empty integrity `flags` mean the gate's
  verdict is not to be trusted in either direction, and the answer to that is a
  reviewer, not a more expensive implementer. A gamed green must not buy a
  cheap pass.
- **Never without a patch.** An attempt that left no diff against base is the
  shape `implementer_failed` already ends on, and a stronger model recovers
  none of those.
- **Only the step classes the knob names.** Recovery is not uniform across
  failure kinds, so the trigger branches on *what* failed. The failing step
  (the command the gate died on — see
  [which gate step failed](design-notes.md#which-gate-step-failed)) is matched
  case-insensitively into one class:

  | Class | Matched on | In the default set |
  | --- | --- | --- |
  | `type-check` | `tsc`, `typecheck`, `type-check`, `type_check`, `check:types`, `check-types`, `check_types`, `types:check`, `cargo check`, `mypy`, `pyright`, `analyze` | yes |
  | `lint` | `lint`, `rubocop`, `shellcheck`, `ruff`, `flake8`, `clippy` | yes |
  | `test` | `test`, `spec`, `jest`, `cypress` | yes |
  | `build` | `build`, `compile`, `webpack` | no |
  | `unknown` | anything else, and a round whose step was never recorded | no |

  Classes are tried in that order, so `npm run type-check` is a type-check and
  not a test. `HARNESS_ESCALATION_STEPS=all` escalates on any failing step.

**Attribution.** With an escalation the branch carries two implementers' work,
and the boundaries are recorded rather than inferred:

| Range | Whose |
| --- | --- |
| `base..glm_head` | the cheap tier's (`escalation.glm_head`, also `escalation.from_provider`/`from_model`) |
| `glm_head..opus_head` | the escalated session's |
| `opus_head..HEAD` | the reviewer's |

`opus_head` keeps its meaning — everything up to it is the implementer stage's —
so `metrics.opus_commits` counts *both* implementers on an escalated run and
`metrics.codex_commits` is unaffected. Split the two by `glm_head` when you need
them apart. Commit messages stay clean, as everywhere else in this pipeline: the
attribution lives in `result.json`, never in the commits.

### Not a knob: HARNESS_GATE_STEP

`HARNESS_GATE_STEP` is the path of the side file the gate's traps write the
failing step to. It is **not a knob you set** — `run-task.sh` exports it into
the gate subshell for the trap to write to, and a failed write is swallowed
(`|| :`) so it can never be visible to your gate. It is documented here because
it is the one `HARNESS_*` name in `run-task.sh` that a reader may meet without
it being theirs to configure. How the step is captured is in
[the design notes](design-notes.md#which-gate-step-failed).

## The verifier

After the review stage, on **every** arm, the harness hands the run's own
trajectory to
[llm-as-a-verifier](https://github.com/llm-as-a-verifier/llm-as-a-verifier) and
records what comes back. It is advisory, and it never gates; why it exists and
what it costs are in [the design notes](design-notes.md#the-verifier-why-a-third-vendor).

**What it reads.** Two bodies of evidence, and both are **anonymised** before
either leaves the process: every vendor and model name (`opus`, `claude`,
`sonnet`, `codex`, `gpt`, `anthropic`, `openai`, case-insensitive) becomes the
`IMPLEMENTER`/`REVIEWER` role token that wore it, so the judge cannot tell whose
work it is grading. The first is **the diff** — the whole change against base,
lockfiles excluded — which is what four of the five rubric items are judged
from. The second is **the trajectory** `verify.py` builds out of the run, in
order: every attempt's implementer stream (each assistant message a narration
step, each tool call folded together with its observed output into one step),
then the gate rounds, then the reviewer's notes or rejection and the commits it
added, and finally the observed end state. Nothing is invented: a run whose
implementer left no stream, or that has no evidence any item can read, is
skipped rather than scored.

**What it returns.** A rubric vector, and the mean of it. Five fixed items —
brief coverage, no unrequested scope, diff minimality and hygiene, test
integrity, and (only for a run that actually resumed) resume coherence — are
each scored on their **own** call, K independent samples each, against the
acceptance criteria of `brief.md` as a spec stated before the work started.
Every sample has to quote the requirement, diff hunk or trajectory line that
decides it, and a quote the adapter cannot find verbatim in the task spec or
the evidence it sent scores that sample **0**, whatever number came with it.
One known limitation: evidence beyond the per-step, whole-trajectory or diff
budget is clipped, and a genuine citation from past a cut scores 0 —
`verify.json` carries an `evidence_truncated` boolean per item for those cases.
The K samples are aggregated by
median; the headline `score` is the plain **mean** of the item scores, which is
an aggregate no amount of trajectory length can inflate. A call that never
returned is dropped rather than counted zero; if every sample for one item
fails, the whole verifier attempt fails rather than publishing a partial vector
or silently removing that item from the headline mean.

**Turning it on.**

```bash
./install.sh --verifier                    # opt-in: builds the venv, installs the library
(umask 077; printf '%s' 'sk-…' > ~/.claude/harness/verifier-api-key)
```

Like `linear-api-key`, that one file is **not seeded by the installer, because
it is a credential** — you create it by hand, mode 600. Only its *path* is
exported to the adapter (as `HARNESS_VERIFY_KEY_FILE`), which reads the
credential in-process: it never appears in `ps`, in `verify.log`, in
`verify.json` or in `result.json`, and a traceback has both a bare key and a
service account's private-key material scrubbed out of it.

**Vertex, for a corporate account.** Under Google Cloud terms Vertex does not
train on inputs and can be pinned to an EU region, which makes it the
corporate-safe backend where DeepSeek is fine for personal repos. It will not
take an API key: one created with
`gcloud services api-keys create --api-target=service=aiplatform.googleapis.com`
comes back `401 UNAUTHENTICATED: API keys are not supported by this API.
Expected OAuth2 access token or other authentication credentials that assert a
principal`. So the key file holds a **service-account JSON** instead, and the
adapter authenticates as that principal:

```bash
gcloud iam service-accounts create harness-verifier --project "$PROJECT"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:harness-verifier@$PROJECT.iam.gserviceaccount.com" \
  --role roles/aiplatform.user
gcloud iam service-accounts keys create ~/.claude/harness/verifier-api-key \
  --iam-account "harness-verifier@$PROJECT.iam.gserviceaccount.com"
chmod 600 ~/.claude/harness/verifier-api-key
export HARNESS_VERIFY_GCP_LOCATION=europe-west4   # EU residency; default is global
```

Nothing else changes: the file's *shape* selects the backend, so a station goes
corporate-safe by dropping that JSON in place of the DeepSeek key — no export,
no config file. Only the path reaches the environment (as
`GOOGLE_APPLICATION_CREDENTIALS`); the JSON's contents never do.

| Env var | Effect | Default |
| --- | --- | --- |
| `HARNESS_VERIFY` | `0` disables the stage entirely. | `1` |
| `HARNESS_VERIFY_PYTHON` | Interpreter that runs the adapter. Must be executable, or the stage skips. | `$HARNESS_DIR/verifier-venv/bin/python` |
| `VERIFIER_API_KEY_FILE` | The credential file — a one-line API key, or a service-account JSON. Must be readable, or the stage skips. | `$HARNESS_DIR/verifier-api-key` |
| `HARNESS_VERIFY_PROVIDER` | `deepseek` \| `vertex` \| `openai`. **Unset infers it from the credential**: a service-account JSON means `vertex`, anything else `deepseek`. Exactly one backend env var is set from the key file; the others are cleared, so an ambient variable (or a stray `.env`) can never pick a backend the run did not ask for. | inferred |
| `HARNESS_VERIFY_BASE_URL` | `OPENAI_BASE_URL` for the `openai` provider (any OpenAI-compatible server). | unset |
| `HARNESS_VERIFY_GCP_PROJECT` | Vertex project. | the JSON's `project_id` |
| `HARNESS_VERIFY_GCP_LOCATION` | Vertex region — pin an EU one for data residency. Recorded in `verify.json` as `location`. | `global` |
| `HARNESS_VERIFY_MODEL` | Model id; the library's own default for the chosen client when unset (`deepseek-v4-flash`, `gemini-2.5-flash`). | unset |
| `HARNESS_VERIFY_EVALS` | K — independent samples of each rubric item, aggregated by median. The whole bill is `items × K` calls: 15 by default, 12 for a run that never resumed. | `3` |
| `HARNESS_VERIFY_MAX_CRITERIA` | Cap on the acceptance criteria quoted into the task spec every item is judged against. `0` = the `## Problem` section alone. | `8` |
| `HARNESS_VERIFY_STEP_CHARS` | Per-step clip, marker included. | `2000` |
| `HARNESS_VERIFY_MAX_CHARS` | Whole-trajectory clip. Over budget, the head and tail are kept and the middle becomes one `[N agent steps elided]` step, counted in `elided_steps`. The diff evidence gets a **quarter** of this, because it is sent once per diff item while the trajectory is sent at most K times. | `400000` |
| `HARNESS_VERIFY_TIMEOUT` | Seconds the whole stage may take before it is killed (and recorded as a failure that changes nothing). | `900` |
| `HARNESS_VERIFY_EFFORT` | Passed through as `DEEPSEEK_EFFORT` (`off` \| `low` \| `high` \| `max`) and applied through the library's existing DeepSeek request configuration. | `high` |

Two files per run: **`verify.json`** (the score, the rubric vector in `items`
with each item's citation and its K raw samples, the same vector by title in the
legacy `criteria` table, the model, the provider, K, the trajectory size, token
usage, how long it took, and `location` on Vertex — copied verbatim into
`result.json` as `metrics.verifier`) and **`verify.log`** (one line per attempt:
the score, or `skipped (<reason>)`, or `failed (<reason>)`).
Both rotate into `attempts/<n>/` with the rest of an attempt's telemetry.

## The spec critic

Every stage after the planner treats `brief.md` as ground truth: the implementer
builds from it, the gate runs its `Verify` block, the reviewer and the verifier
judge the diff against its acceptance criteria. Nothing checks the specification
itself. `spec-critic.sh` is one confined, read-only pass that does — before
anybody acts on it.

```bash
~/.claude/harness/spec-critic.sh --brief runs/<RUN-ID>/brief.md \
  --repo /path/to/repo --out runs/<RUN-ID>/spec-critic.json
```

**What it returns**, and nothing else — a single JSON object, enforced by the
CLI's `--json-schema` rather than asked for in prose:

| Field | What it holds |
| --- | --- |
| `contradictions` | Statements in the brief that cannot both hold: a criterion the Out of scope section forbids, a `Verify` command that contradicts what `Reproduction` says fails today. |
| `criteria_not_testing_problem` | Acceptance criteria that could all pass with the Problem still there, and criteria no reading or command can settle. |
| `conflicts_with_current_behavior` | `{claim, code_evidence}` — a claim the brief makes about how the repo works today that the code contradicts. `code_evidence` is a repo-relative `file:line` and is **required**: a conflict without a citation to an existing line in the supplied repo is dropped rather than passed on. |
| `questions` | At most 3, batched into one round, ordered by how much they change what gets built. |

Every list may be empty, and an honest empty verdict is the common one. The
critic **reports**; it never edits a brief and it never decides a run. What a
finding is worth is the caller's call: the planner skills fold the answers back
into the brief before dispatch, and the quartermaster holds a self-written brief
back on a contradiction or when the required verdict could not be produced (see
[The Quartermaster](operations.md#the-quartermaster)).

**Confinement.** `spec-critic-settings.json` allows `Read`, `Grep` and `Glob`
and denies everything else by name — no `Bash` (a permission pattern matches the
head of a command line, not what it goes on to run), no `Task`, no network, and
no `Edit`/`Write`, because a critic that can write is a critic that can edit the
brief it is grading. The brief itself is quoted into the prompt inside a fence
whose marker is minted per call, so a brief written from a ticket description
cannot close the quote and give orders. The session's cwd is a disposable
scratch dir and the target repo is reachable only because `--add-dir` names it,
so the write confinement holds whatever the policy file says.

| Env var | What it does | Default |
| --- | --- | --- |
| `SPEC_CRITIC_MODEL` | Model for the pass | the CLI's own default |
| `SPEC_CRITIC_TIMEOUT` | Seconds per call | `600` |
| `SPEC_CRITIC_MAX_TURNS` | Turn ceiling — repo research is most of them | `40` |
| `SPEC_CRITIC_SETTINGS` | The tool policy | `spec-critic-settings.json` beside the script |

Exit 0 means a verdict was produced (read the JSON — passing is the usual
outcome), 1 means the single critic pass could not produce one, 2 is a usage
error. A critic that cannot answer is not evidence against a brief, but the
quartermaster still defers because the required review is missing.

## The gate integrity check

Between the implementer's gate round and the review stage, `lib/gate-integrity.sh`
asks the question a green gate cannot answer about itself: **was it earned?** It
is deterministic (no model), best-effort, and time-boxed. It reports **flags**
rather than rewriting the gate verdict; non-empty flags also veto
[escalation](#escalation), so they can affect provider routing and the run's
eventual outcome.

**Replay.** Every test file this branch adds or changes is run against the
*unpatched base tree* in a scratch worktree, scoped to that one file, with the
repo's own runner (`jest`, `vitest`, an `npm`/`yarn` test script, or `pytest` —
detected, not assumed). A test that **passes there** is non-discriminating: it
cannot have caught the change it travels with. Anything that stops the replay
working — no runner, no scratch worktree, a runner that will not start, the
per-file or whole-stage cap — is recorded as `not_run` with a reason, never as a
clean result.

**Structural.** The diff is read for the signatures of a gate made green rather
than earned: deleted test files, a net-negative assertion count in a touched
test, a `it.only` / `.skip` / `@pytest.mark.xfail` / `t.Skip` marker introduced,
CI/lint/coverage config changed on a branch whose brief never mentions that file,
and an expected value in a changed test that this same diff also introduces in
the source.

**Where it goes.** `gate-integrity.json` in the run dir (embedded verbatim in
`result.json` as `gate_integrity`), the runner transcript in
`gate-integrity-replay.log`, the same block in the worktree at
`.harness/gate-integrity.log` beside `gate-latest.log`, and a
`## Gate integrity flags` section in the review prompt — so the reviewer's
anti-gaming checklist starts from evidence instead of a blank diff. A clean
branch gets an explicit *no flags*, which is stated as absence of evidence, not
as proof.

| Env var | Effect | Default |
| --- | --- | --- |
| `HARNESS_GATE_INTEGRITY` | `0` disables the stage: no file, no `gate_integrity` field, and a review prompt byte-identical to what it was before this existed. | `1` |
| `HARNESS_GATE_INTEGRITY_TIMEOUT` | Seconds the whole replay half may spend. Test files left over when it runs out are `not_run`, and the reason says so. | `300` |
| `HARNESS_GATE_INTEGRITY_FILE_TIMEOUT` | Seconds one replayed test file may take. Whichever cap bites first, a runner killed by one is always reported as a timeout, whatever it had printed by then. | `120` |
| `HARNESS_GATE_INTEGRITY_MAX_FILES` | How many test files are replayed at most; the rest are `not_run` rather than silently dropped. | `10` |

Both halves are heuristics, with false positives and false negatives, which is
why this iteration only flags. Read `flags` as *look here first*, not as a
verdict — and read an empty list as nothing found, not as a gate proven honest.

## Profiles

A **profile** is an optional bundle of pipeline stages that applies to some
repos and not others. `run-task.sh` loads the ones that apply to the run's
target repo and they fill [the six named hooks](design-notes.md#the-extension-points-and-why-there-are-exactly-six);
a repo no profile applies to behaves exactly as it always has, down to
`result.json`'s key set. `profiles/` ships in the install, so a repo's pins can
name paths inside `$HARNESS_DIR/profiles/`.

| Env var | Effect | Default |
| --- | --- | --- |
| `HARNESS_PROFILES` | `0` loads no profile at all, whatever the repo carries. | `1` |

One profile ships: **`profiles/visual/`**, the visual gate, the blind VLM critic
and the PixelLab / Retro Diffusion asset factories — the pipeline for work that
is judged by eye. Its own documentation is
[`profiles/visual/creative/README.md`](../profiles/visual/creative/README.md);
the planner protocol is `/dispatch-pixel`
([`skills/dispatch-pixel/SKILL.md`](../skills/dispatch-pixel/SKILL.md), installed
by `install.sh --pixel`).

It applies to a repo that pins `VISUAL_GATE_CMD` **or** carries a `.creative/`
art-direction contract (bible, rubric, reference board, palette, thresholds).
When it applies, the run gains a render-and-grade stage between the test gate
and the review, up to `HARNESS_VISUAL_ROUNDS` of them with a fix round in
between, a `visual` object in `result.json`
(`{status, rounds, pairwise, worst_axis, score_path}`), a `## Visual gate`
section in the PR body, and one more terminal status — **`visual_failed`**: the
tests pass and the picture does not.

Activation is repo-level, so the stage itself answers two cheaper questions
before it renders anything, and each has its own non-verdict:

- **`skip`** — no file this branch changes is in `VISUAL_SCOPE_GLOBS`. A diff
  with no visual surface cannot have changed the picture, and grading it against
  the reigning champion is noise at best. Nothing renders, no fix round, no
  outcome; `result.json` gets `{status: "skip", reason}`.
- **`not_run`** — the machine could not render: no Playwright or a headless
  browser that will not launch. That is not a taste verdict and no fix round
  can install Chromium, so the run ships and says so — `{status: "not_run",
  rounds, reason, remedy}` in `result.json` and a two-line note in the PR body.
  A gate pinned through `VISUAL_GATE_CMD` opts in by both exiting **3** and
  writing `status: "not_run"` in `.harness/visual-score.json`; requiring both
  preserves nonzero exit meanings used by custom gates that predate this
  protocol.

| Env var | Effect | Default |
| --- | --- | --- |
| `HARNESS_VISUAL_ROUNDS` | Visual gate rounds a run may spend before `visual_failed`. Anything that is not a positive integer falls back. | `2` |
| `VISUAL_GATE_CMD` | The gate command itself, pinned per repo in `repos.local.sh`. Unpinned, a `.creative/` repo gets `profiles/visual/creative/visual-gate.sh`. | (the shipped gate) |
| `VISUAL_SCOPE_GLOBS` | Which paths this repo's picture is made of, as space-separated git pathspec globs. Pinned per repo in `repos.local.sh`; a value REPLACES the defaults, so list every path including `.creative/**`. | `wall/** .creative/** assets/**` |

The factories' two API keys live in `~/.claude/harness/factory.conf.sh` (mode
600, never seeded — copy `profiles/visual/factory.conf.sh.example` and fill it
in). They are applied through the `implementer_env` hook, which means the same
scoping the GLM credential gets: inside the implementer's subshell and nowhere
else, and only when the repo pins `MCP_CONFIG`. No gate, reviewer, PR stage or
log ever holds one. A missing file is one `factory keys SKIP` line.

**Migrating from `~/.claude/creative-harness`.** That fork is what this profile
was: a whole second install with its own `runs/`, `champion/`, `repos.local.sh`
and skill. There is one `HARNESS_DIR` now. Re-run `./install.sh` from this
checkout, move `~/.claude/creative-harness/champion/` to
`~/.claude/harness/champion/` and `factory.conf.sh` beside it, repoint any
`VISUAL_GATE_CMD` pin at `$HARNESS_DIR/profiles/visual/creative/visual-gate.sh`
(or drop the pin — `.creative/` is enough), and the old directory can go. Runs
already in `~/.claude/creative-harness/runs/` stay readable where they are
(`wall.sh --runs`), and nothing moves them for you.

## Find, refute, fix

The review stage is three passes, not one. A reviewer that finds and fixes in
the same breath turns every false positive into an edit to code that already
passed the gate, and about half of what a review reports does not survive
checking — so a finding earns an edit only by surviving a session whose only job
is to disprove it.

**Find.** The reviewer (Codex, or whichever [tier](operations.md#when-codex-dies-mid-run-out-of-credits)
takes the review — unchanged) first writes `.harness/expected-properties.md`
from the brief *before* it opens the diff, then reads the diff and writes
`.harness/findings.json`: `[{file, line, claim, scenario}]`. It changes nothing.
Its checklist keeps gate-gaming at the top and gains an explicit blind-spot item —
concurrency and races, time-of-check-to-time-of-use and timing-dependent
authorization, compositional authorization — because those are the classes a
reviewer misses by waiting for them to catch its eye. It is also told *how* to
read: the changed files first, then the diff in slices of about fifty changed
lines, with the code each slice plugs into read alongside it before moving on.
Recall on a diff read straight through collapses long before its end, and no
amount of refutation recovers a finding nobody made.

**Refute.** A fresh session on the same backend, which has not seen the diff,
reads each finding and tries to establish that it is **wrong**. It writes
`.harness/refuted.json`:

```json
[{"id": "F1", "refuted": true,  "reason": "why it is wrong",
  "evidence": {"file": "src/x.ts", "excerpt": "the verbatim code that contradicts it"}},
 {"id": "F2", "refuted": false, "doubt": true, "reason": "plausible, could not confirm it"},
 {"id": "F3", "refuted": false, "reason": "what was checked"}]
```

`refuted: true` drops a finding only when the harness can **verify the
citation**: `evidence.file` is a git-tracked path in the worktree — never
absolute, never through `..`, never under `.harness/`, so a refuter cannot cite
the findings file it was handed or escape the tree — and `evidence.excerpt` is
at least ten characters of code that appear in that file as one contiguous
verbatim run. The check reads the whole file and tests containment, not line by
line: an excerpt stitched from lines that each exist separately but never touch
is a fabrication and is treated as one. A verdict with no evidence block, a
citation that does not verify, or a blank reason counts as **not refuted** — the
finding is promoted and `review-notes.md` names the discarded verdict and why.

`doubt: true` (with `refuted: false`) is the vocabulary for a finding the refuter
finds plausible but cannot confirm, instead of a refutation it cannot evidence.
It changes nothing about promotion; it marks the promoted entry `doubted: true`
so the fix pass can see it. `refuted` and `doubt` are mutually exclusive, and a
verdict carrying both is read as doubt. A finding the refuter merely doubts,
cannot check, or leaves out is **promoted**. The burden sits on the refutation,
because a wrong promotion costs one unnecessary edit and a wrong refutation ships
a defect — every degradation here falls toward promotion.

**Fix.** Only promoted findings are edited, one commit per finding with the
finding id in the message, and then the post-review gate runs exactly as it
always did. A finding marked `doubted` is the one exception to editing on sight:
the fix pass has to confirm its scenario against the code first, and leave the
code alone with a note when it cannot. Edits address promoted findings and
nothing else — improvements noticed on the way are suggestions in
`review-notes.md`, not commits.

Ids are the harness's, `F1..Fn` in the order the find pass wrote them; it
rewrites `findings.json` with them so every later pass and the ledger name the
same finding the same way. An entry with no claim is dropped and the drop is
printed.

**Degradation.** Each pass falls back to the one before it. A find pass that
leaves no `findings.json` *is* the old single-pass review and nothing else runs.
A refutation pass that leaves no usable verdicts — a crash, a timeout, an empty
file, `HARNESS_REVIEW_REFUTE=0` — promotes **every** finding, which is again
what a single pass would have done; `review_findings.refute` becomes `failed`
(or `off`) and `review-notes.md` says in words that the promoted list is a
reviewer's unchecked claims. Nothing here can hold a run or leave a diff
unreviewed: [every arm reviews or holds](../README.md) is decided before this
stage and untouched by it.

**Where it goes.** `findings.json`, `refuted.json`, `promoted.json` and
`refute-discarded.json` in the run dir; the
`{found, refuted, promoted, doubted, fixed}` counts in `result.json` as
`review_findings`; and a `## Findings` section appended to `review-notes.md`
listing every side — promoted with what was fixed and which of them carried
doubt, refuted with the reason and the verified citation it was dropped on, and
the refutations discarded for unverifiable evidence — so the planner's verdict
step sees what was thrown away and why.

## The repo pin

`repos.conf.sh` (shipped) auto-detects sensible defaults for any repo: install
and gate commands from the lockfile, base branch from the remote's default. To
**pin** settings for a specific repo, add a `repo_config_local()` case arm to
`~/.claude/harness/repos.local.sh` (gitignored — `install.sh` seeds it for you).
It runs *before* auto-detection; any field you leave blank is still
auto-detected.

Keys are the repo's directory name (`basename`). Worktrees are named
`<repo>-<ticket>`, so match both `<repo>` and `<repo>-*`.

| Variable | Purpose | Default |
| --- | --- | --- |
| `BASE_BRANCH` | Base branch PRs target | detected: `staging` → `main` → `master` |
| `INSTALL_CMD` | Install deps in a fresh worktree | from lockfile (`npm ci` / `yarn install` / `uv sync`) |
| `GATE_CMD` | The deterministic test gate | from lockfile (`npm test` / `yarn test` / `uv run pytest`) |
| `IMPLEMENTER_PROVIDER` | Which vendor the implementer bills to (`anthropic` \| `zai`). The pin outranks the machine's ambient `IMPLEMENTER_PROVIDER` | the ambient value, else `anthropic` |
| `VISUAL_GATE_CMD` | The [visual profile's](#profiles) gate. Setting it is one of the two ways a repo opts in | none; the shipped gate once the profile applies |
| `VISUAL_SCOPE_GLOBS` | Git pathspec globs naming the paths that repo's picture is made of; a branch touching none of them skips the [visual gate](#profiles) | none; the profile's `wall/** .creative/** assets/**` |
| `MCP_CONFIG` | Path to an `.mcp.json` the worker loads | none (skipped if the path is missing) |
| `ENV_SUBDIRS` | Extra dirs besides `.` to copy `.env*` into | none |
| `DEV_CMD` | Dev server command for `preview.sh` | `npm run dev` |
| `PREFLIGHT_CMD` | Env check run *before* the implementer (e.g. test DB up + migrated) | none |
| `DEMO_DEV_CMD` | Dev server command for demo recording (must pin the port) | none |
| `DEMO_PORT` | Port `DEMO_DEV_CMD` binds (storyboard origin + post-demo cleanup) | none |
| `PREPROD` | `1` = repo is not in production yet: both worker prompts get the greenfield posture | none |

`GATE_CMD` is the heart of it: it is the objective checkpoint both models are
measured against. Point it at the strictest fast feedback your repo has —
types, lint, and tests.

`IMPLEMENTER_PROVIDER` is the compliance pin: a station whose ambient default
is `zai` pins `anthropic` on the repos it dispatches that are not approved for
third-party model providers, so an exported machine default can never route
that code to one. `IMPLEMENTER_MODEL` independently follows repo pin, ambient
environment, then the selected provider's default.

`PREFLIGHT_CMD` fails a run fast on a broken environment *before* burning an
implementer pass. See
[`examples/preflight-postgres.example.sh`](../examples/preflight-postgres.example.sh)
for a Postgres test-DB check.

### Generating a pin

Hand-writing a pin means reading the repo and getting `GATE_CMD` exactly right
(a wrong one silently weakens the whole pipeline). `setup-repo.sh` does that
inspection instead:

```bash
setup-repo.sh <repo-path>            # print the proposed entry + a rationale
                                     #   per field; writes nothing (dry run)
setup-repo.sh <repo-path> --write    # save it into repos.local.sh
setup-repo.sh <repo-path> --verify   # prove INSTALL_CMD + GATE_CMD pass first
setup-repo.sh <repo-path> --ai       # let a model refine the proposal
setup-repo.sh <repo-path> --provider anthropic --write   # pin the implementer's vendor too
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
docker-compose DB) — it never writes an untested preflight path. Nor does it
ever detect an `IMPLEMENTER_PROVIDER`: that field reaches the arm only through
`--provider`, and an arm that already pins one keeps it through an update.

### PREPROD: the pre-production posture

Both models default to conservative, compatibility-preserving changes. That is
the right instinct for a live system and the wrong one for a repo that has no
users yet, where a compatibility layer is dead weight from the day it lands.
Pin `PREPROD=1` and `run-task.sh` appends a posture block to the implementer
**and** the reviewer prompts: remove obsolete paths instead of adding
compatibility layers, fallbacks or migrations; choose the simplest
implementation that fully meets the current requirements; grow the system in
layers without trading a working product for unfinished complexity; keep
components modular; prefer established libraries, and the dependencies already
in the project, over your own implementation; decide architecture for the long
term rather than accepting a stopgap. The reviewer is told the same thing
explicitly — otherwise it spends its round demanding the back-compat shims the
implementer was told not to write.

It is a pin, never a detection: no heuristic gets to decide a repo is
pre-production. With `PREPROD` unset both prompts are byte-identical to a run
without the feature — [`tests/preprod.test.sh`](../tests/preprod.test.sh)
captures the real prompts from a fabricated run and asserts it.

## Local config files

All gitignored. `install.sh` seeds each of these from its `*.example` the first
time and never overwrites an existing copy:

- **`repos.local.sh`** — per-repo pins (above).
- **`notify.conf`** — desktop + phone (ntfy) notifications on stage handoffs.
- **`demo.conf.sh`** — object-storage remote (`R2_REMOTE`, `R2_PUBLIC`) for
  uploading PR demo videos.

Three more files are **not** seeded, because they are credentials and you should
create them deliberately, mode 600:

- **`linear-api-key`** (`LINEAR_API_KEY_FILE` to move it), read by
  [the Quartermaster](operations.md#the-quartermaster) and by
  [ticket sync](operations.md#ticket-sync). Without it the quartermaster still
  reports capacity and simply says the queue was unreadable.
- **`verifier-api-key`** (`VERIFIER_API_KEY_FILE` to move it), read by
  [the verifier](#the-verifier).
- **`zai-api-key`** (`ZAI_API_KEY_FILE` to move it), read only by runs pinned to
  [GLM as the implementer](#glm-as-the-implementer). A run pinned to `zai`
  without it ends `setup_failed` before it spawns anything.

## The run directory

Each run writes plain files under `~/.claude/harness/runs/<RUN-ID>/`, and every
tool in the harness reads them and nothing else. The paper trail per run:

| File | What it holds |
| --- | --- |
| `brief.md` | The task contract the planner wrote |
| `specs/` | Converted spec attachments, when the task had any (below) |
| `QUESTIONS.md` | The implementer's blocking questions — the run is `needs_input` while it exists |
| `implementer-notes.md` | What the implementer changed and decided (it becomes the PR body) |
| `review-notes.md` / `REJECTED.md` | The reviewer's notes (with the promoted/refuted ledger appended), or its rejection |
| `findings.json`, `refuted.json`, `promoted.json` | [Find, refute, fix](#find-refute-fix): what the review pass reported, what the refutation pass disproved (each with the citation that verified), and what therefore earned an edit (`doubted: true` on the ones the refuter could not confirm). Absent on a review that produced no structured findings |
| `refute-discarded.json` | `[{id, why, reason}]` — refutations thrown away because their evidence did not verify, so the finding was promoted instead. `[]` on a run where every verdict held up |
| `expected-properties.md` | What the review pass said a correct change must do, written from the brief *before* it opened the diff |
| `review-findings.json` | The `{found, refuted, promoted, doubted, fixed, refute}` counts, copied into `result.json` as `review_findings` |
| `feed.log` | Live transcript across both model stages |
| `gate-*.log`, `gate-rounds.log` | Each gate round's output and its one-line verdict |
| `gate-integrity.json`, `gate-integrity-replay.log` | The [integrity check's](#the-gate-integrity-check) findings (copied into `result.json` as `gate_integrity`), and the transcript of replaying this branch's tests against base |
| `result.json` | The run's machine-readable outcome and metrics ([schema](#metrics-schema)) |
| `outcome.json` | What the world did with the PR: `pr_url`, `pr_state`, `merged_at`, `time_to_merge_s`, `review_comment_count`, `follow_up_commits`, `reverted`, `checked_at` — written by the [janitor](operations.md#the-janitor) once the run has a PR. Absent until then, and absent for a PR the janitor could never read |
| `repo` | The repo the janitor resolved the run's PR to, so later sweeps skip the re-derivation |
| `opus-head` | The commit SHA dividing the implementer's commits from the reviewer's. Per-model attribution lives here and in `result.json`, never in the commit messages themselves — the commits stay clean (no AI or agent mentions) and you still know which model wrote what |
| `escalation.json`, `escalation-report.md` | [Escalation](#escalation): what the cheap tier failed on and where its commits end (copied into `result.json` as `escalation`), and the handover the escalated session was given. Only on a run that escalated |
| `capacity.log` | The [preflight's](operations.md#capacity-preflight-a-run-that-defers-itself) verdict |
| `verify.json`, `verify.log` | The [verifier's](#the-verifier) score, and why it did or did not produce one |
| `visual/`, `visual-*.log`, `visual-rounds.log` | The [visual profile's](#profiles) frames, contact sheet and score, one log per round, and the round ledger. Only on a repo the profile applies to |
| `segment-report-<n>.md` | In `report` [resume mode](operations.md#turn-ceiling-a-run-that-resumes-itself), the handover the turn-ceiling resume gave segment `<n>+1` about segment `<n>` |
| `attempts/<n>/`, `attempts.log` | Every earlier attempt's stream, gate rounds, final message and segment reports, kept instead of overwritten ([Attempts](operations.md#attempts-a-run-is-a-ticket-an-attempt-is-a-dispatch)) |
| `scheduled`, `scheduled.log` | An armed schedule's fire epoch, and the output of the run it fired |
| `mirror.log`, `ticket-sync.log` | The last error from mirroring, and the ticket-sync transcript |

That table is the paper trail for a human. The same directory is also a **wire
format**: [Ghost Shift](wall.md) reads it live over the shoulder of a running
pipeline, so which of these files it opens, which `result.json` fields it takes
out of them, and how much half-written-ness each one tolerates is written down
and tested in [the wall's data contract](wall-contract.md) — along with the
stage-text vocabulary (`wall/stage-vocab.json`) that `statusline.sh` and
`status.sh` parse out of `status` too.

### Spec attachments

When the real spec lives in an office document — a Word feature spec, an Excel
rules table, a PDF — the planner converts it to markdown with
[anydoc](https://github.com/firecrawl/anydoc) (`npx -y @firecrawl/anydoc <file>
-o <run-dir>/specs/<name>.md`: 14 formats, auto-detected, nothing to install)
and leaves it in the run dir. Everything under the run dir's `specs/` is mounted
at `.harness/specs/` in the worktree before the implementer starts, and both
workers are told to read it as part of the task contract — so the detail the
brief distils stays consultable instead of being paraphrased away. When the run
dir has a `specs/` directory, re-dispatching replaces the mounted set wholesale
with its current contents, so a revised spec never piles up next to the version
it supersedes. To withdraw every spec from a run in flight, leave that directory
present but empty; an absent source directory is a no-op. The pipeline never
runs `anydoc` itself; conversion is planner-side only.

## Monitoring surfaces

Wire the statusline once and monitoring is ambient; skip it and
`status.sh --watch` gives you the same picture on demand.

- **Statusline** (`statusline.sh`) — a line per active run in every Claude
  session on the machine: run id, which model has it, the tool/file it is
  touching right now, `±lines` against the base, elapsed minutes. A red `⏸`
  line means `needs_input`. Finished runs, and runs whose status hasn't moved
  in 6h, drop off by themselves.

  `install.sh` offers to wire it into `~/.claude/settings.json` for you (only
  with your consent, and it backs the file up first). By hand:

  ```jsonc
  "statusLine": {"type": "command", "command": "~/.claude/harness/statusline.sh"}
  ```

  Already have a statusline command? Keep it and append the run lines:

  ```bash
  <your command>; ~/.claude/harness/statusline.sh --runs-only
  ```

  `--runs-only` emits nothing but run lines and reads no stdin — the session
  JSON can only be consumed once, so your own script keeps it.

- **`status.sh --watch`** — the zero-config alternative: a live dashboard in any
  terminal (run, actor, stage, current activity, time in stage, total),
  redrawn in place every 2s (`HARNESS_WATCH_INTERVAL` to retune).
- **Notifications** — a desktop banner (macOS `osascript`) and/or a phone push
  (ntfy) on every stage handoff. Silence the desktop ones with `HARNESS_NOTIFY=0`.
  The two stages you have to act on carry more than the stage text: a terminal
  `done:` push appends the PR URL and makes the notification tappable (plus an
  **Open PR** button), and `waiting — implementer needs your input` goes out at
  high priority with a warning tag so it survives a silenced phone. Every other
  stage stays a quiet tick.
- **`HARNESS_MIRROR`** — mirror this machine's run dirs onto another machine
  while they run, so its wall shows them too:
  [Runs from any machine](operations.md#runs-from-any-machine-harness_mirror).
- **`status.sh`** — one-shot table of all runs; `status.sh <RUN-ID>` prints a
  run's full timeline and result. A run whose driver is gone carries a `DEAD`
  marker in the `IN STAGE` column instead of a timer that keeps climbing, and
  the table ends with the exact re-dispatch command for each one.
- **`status.sh --doctor`** — only the stalled runs, one line each, followed by
  the command that resumes each of them. Read-only: it never rewrites another
  process's status file, so it is safe to run against live runs. This is the
  fast answer to "is anything stuck?" without reading the whole table. A run is
  listed when it has a non-terminal stage, no live driver process **and** a cold
  heartbeat — never on one signal alone, and never for a run that is legitimately
  paused (`waiting`, `deferred:`, `sync failed`), where no driver is expected.
- **`feed.log`** — a live transcript across both model stages
  (`tail -f ~/.claude/harness/runs/<RUN-ID>/feed.log`): the implementer's tool
  calls and thinking, then the reviewer's output prefixed `◆ codex`.
- **`attach.sh <RUN-ID>`** — step into the worker's session interactively, with
  full context (it warns before forking a still-running worker).
- **`preview.sh <RUN-ID>`** — run the dev server inside the worktree to see the
  change live before approving.
- **[`wall.sh`](wall.md)** — the same picture for a room instead of a terminal.

## Metrics

```bash
~/.claude/harness/metrics.sh          # aligned table across all runs
~/.claude/harness/metrics.sh --csv    # same data as CSV for stats tools
~/.claude/harness/metrics.sh --report # the aggregate health picture
```

Columns: run, arm, implementer model and effort, reviewer model and effort,
status, gate rounds (e.g. `fail,pass`), implementer/reviewer commit counts,
± lines, wall minutes, and the verifier's `score` — so an effort sweep or a
reviewer-model ablation reads straight off the table. Runs predating a field (no
`metrics` object, no verifier score, or written before the model/effort knobs)
render with blanks, not errors.

`--report` is the aggregate health picture across every `result.json`; how to
read it, and what each of its labels means, is in
[the design notes](design-notes.md#reading-the-pipelines-own-vitals). Under
`verify score` it indents one line per [rubric item](#the-verifier) the corpus
carries, each counted over the runs that actually carry that item — the scalar
says how good the corpus is, the vector says what it is bad at. A corpus of runs
scored before the vector existed prints the scalar and nothing under it. Two
later blocks read the same corpus: a `cost usd` line over the runs that recorded
`metrics.total_cost_usd`, and an `OUTCOMES` block — merge rate, median minutes
to merge, reverts — over the runs that have an [outcome.json](#the-run-directory)
(the [janitor's](operations.md#the-janitor) ground truth, so a corpus it has not
visited prints `(none captured yet)` and everything else is unchanged).

A `TOKENS` block sits between them: aggregate rows per `implementer_provider`
plus an `all` row show median, p90 and total turns, median and total cache-read
tokens, total output tokens, and — for `zai` rows — the summed
[credit estimate](#metrics-schema). Turns and cache-read are the pair a runaway
run shows up in, and they are only comparable within one vendor, which is what
the grouping is for. A second table keeps each recorded run's turns, cache-read,
output and estimate visible within those provider groups. Runs recorded before
`metrics.usage` existed carry no row.

### Metrics schema

Alongside the existing fields, each run records `arm`
(`full` | `claude_only` | `no_review`), `implementer_provider`
(`anthropic` | `zai` — see [GLM as the implementer](#glm-as-the-implementer)),
`implementer_model`,
`implementer_effort`, `reviewer_model`, `reviewer_effort` (the last two name
whichever backend actually reviewed — see
[Claude-only mode](operations.md#claude-only-mode)), and a `metrics`
object — populated on **every** exit path, partial on early failures (missing
fields are `null`/empty):

| Field | Meaning |
| --- | --- |
| `review` | How the review stage actually went: `reviewed` \| `reviewed_claude` \| `failed_silent` \| `skipped`, empty when the run never reached it. Runs recorded before this ticket may also carry the retired `no_evidence` — an empty Codex review now falls through to the Claude tier instead of shipping. See [Reading the pipeline's own vitals](design-notes.md#reading-the-pipelines-own-vitals). |
| `review_account` | Which backend the review attempt ran on: `primary` \| `fallback` \| `claude`. Absent (not empty) on the arm that never attempts a review. Set the moment a tier is entered, so it names the attempt, not the outcome — `review` is what says a diff was read. See [A second Codex account](operations.md#a-second-codex-account-for-a-dry-primary). |
| `gate_integrity` | The [integrity check's](#the-gate-integrity-check) own `gate-integrity.json`, verbatim: `{base, head, replay: {status, reason, runner, discriminating, non_discriminating, not_run, files{}}, flags[], flag_count}`. Additive and optional — absent on a run that never reached the stage (or ran with it off), and `flags: []` on a branch it found nothing in. It does not rewrite the gate verdict, but non-empty flags veto [escalation](#escalation) and can therefore affect routing and the eventual outcome. |
| `review_findings` | [Find, refute, fix](#find-refute-fix): `{found, refuted, promoted, doubted, fixed, refute}`. `fixed` is counted from the commit log (the fix pass names the finding id in its message), so a promoted finding nobody committed for reads as promoted-not-fixed rather than as fixed. `doubted` is a subset of `promoted`, not a fourth outcome: the findings the refuter found plausible but could not confirm, which the fix pass had to confirm itself before editing. `refute` is `ok` \| `failed` \| `off`, and on anything but `ok` every finding was promoted unchecked. Additive and optional — absent on a review that produced no structured findings, which is the single-pass review this replaced. |
| `escalation` | [Escalation](#escalation): `{triggered, from_provider, from_model, at_attempt, failed_step, glm_head}` — the vendor and model the run implemented on before it escalated, the attempt and the failing gate step that triggered it, and the commit the cheap tier's work ends at. Additive and optional: absent on every run that did not escalate, which is every run before this existed. |
| `metrics.wall_seconds` | Wall time this invocation (from the `started` file). |
| `metrics.stage_durations` | Seconds per stage label, summed across resumes. |
| `metrics.gate_rounds` | `[{round, result, seconds, failed_step}]` for each gate run (`1`, `2`, `3`, `base-sync`, …). `result` is `pass` \| `fail` \| `skipped` (see [When the post-review gate is skipped](design-notes.md#when-the-post-review-gate-is-skipped)); a skipped round records `0` seconds. `failed_step` is the command a failing round died on, `null` on a passing or skipped round and on rounds recorded before this existed. |
| `metrics.turn_resumes` | How many times the implementer was resumed rather than started fresh **within this invocation** (turn-ceiling resumes plus the re-dispatch's own resume). Segmented by the `__invocation__` markers in `stages.log`, so it is never the run's lifetime total. |
| `attempt` / `attempts_total` | This invocation's ordinal, and how many attempts the run has had. See [Attempts](operations.md#attempts-a-run-is-a-ticket-an-attempt-is-a-dispatch). |
| `metrics.attempts` | The attempt ledger: `[{n, status, started, ended}]`, one row per invocation, which is what makes attempt-level rates and the idle gaps between attempts computable from `result.json` alone. |
| `metrics.self_resumes` | Mid-run session limits this run rescheduled itself out of. |
| `metrics.opus_commits` | Commit count `base..opus_head` (the implementer stage's — both implementers on an [escalated](#escalation) run). |
| `metrics.codex_commits` | Commit count `opus_head..HEAD` (the reviewer's). |
| `metrics.diff` | `{files_changed, insertions, deletions}` vs. base. |
| `metrics.implementer_num_turns` | `num_turns` summed over every result event of this invocation's stream-json — one per [turn-ceiling segment](operations.md#turn-ceiling-a-run-that-resumes-itself). Identical to the CLI's own number on a run that never resumed. |
| `metrics.implementer_max_turns` | The `--max-turns` ceiling this attempt was spawned with. Per *segment*, not per attempt: a resumed attempt gets the whole ceiling again. Recorded beside `num_turns` because the two count different things — see [the turns caveat](design-notes.md#reading-the-pipelines-own-vitals). |
| `metrics.implementer_usage` | Token `usage` summed field-wise over the same result events. Numeric keys (`input_tokens`, `output_tokens`, the cache counters) are added up; a non-numeric one (`service_tier`, the nested counters newer CLIs report) is taken from the last segment. |
| `metrics.implementer_segments` | How many result events those two were summed over: `1` for an attempt that ran straight through, `2`+ for one that hit the turn ceiling and resumed. `0` when the implementer never got as far as a result event. |
| `metrics.total_cost_usd` | `total_cost_usd` summed over the same result events — a resumed attempt carries its whole cost, not just the last segment. `null` when no event reported a cost. The CLI prices it at Anthropic's rates whatever the provider, so on a `zai` run it is **not** what the run cost; `metrics.usage.zai_credits_est` is. |
| `metrics.usage` | The flat spend of the whole invocation: `{input_tokens, cache_read_input_tokens, cache_creation_input_tokens, output_tokens, turns}`, summed over every result event and zero (never `null`) for a field no event reported. `turns` is `num_turns` summed, falling back to the count of `assistant` events when no result event carries one. A stream truncated mid-line by a killed process still contributes every complete event before the cut. On an `anthropic` run these counts *are* the meaningful figure — the subscription is flat — so no cost field is derived from them. |
| `metrics.usage.zai_credits_est` | **`zai` runs only**, absent everywhere else: z.ai Coding-Plan credits by their published formula, `(input * 6.9 + cache_read * 1.7 + output * 24) / 10000`. The stored value is not pre-rounded, so totals retain the formula's precision; reports format it for display. An **estimate** — the off-peak discount is not modelled — and cache-read is typically ~90% of it, which is why it scales with turns. See [GLM as the implementer](#glm-as-the-implementer). |
| `metrics.config_hash` | Short hash over the harness repo HEAD (an empty component when Git or a checkout is unavailable) plus the pinned run configuration (provider, both models and efforts, turn ceiling, resume mode, arm) — the fingerprint two runs must share before their metrics are comparable. `null` when `shasum` is unavailable. |
| `metrics.brief` | The shape of the task contract: `{lines, acceptance_count, has_reproduction, has_interface, has_edit_locations, has_decision_points}`, grepped from `brief.md`'s section headers. An absent section is `false`, not an error; a run with no brief at all carries the all-zero object. |
| `metrics.verifier` | The verifier's own `verify.json`, verbatim: `{score, at_implementer, criteria[], items[], model, provider, evaluations, steps, segments, elided_steps, usage, seconds}` — or `null` on every run the stage did not score (off, no key, no library, timed out, crashed, garbled). `items[]` is the rubric vector, `{id, score, citation, samples[]}` per item; `criteria[]` carries the same vector by title, which is what the PR body's table renders; `at_implementer` belonged to the progress curve the rubric replaced and is now always `null`. Advisory: nothing in the pipeline branches on it. See [The verifier](#the-verifier). |
