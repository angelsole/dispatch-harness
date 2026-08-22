# The wall's data contract

[Ghost Shift](wall.md) is a reader. It never dispatches, never edits a run, and
holds no state the pipeline can see — it opens the run dirs `run-task.sh`
already writes and renders what is on disk. That makes the run dir a **wire
format between two programs**, and this page is that format written down: every
file the wall reads, every field it takes out of it, exactly how much
malformedness it tolerates, and the one file it writes.

It exists because the format was, until now, real but unwritten. The stage text
in particular was parsed by three independent copies of one table, none of which
knew about the others. Everything below is either **pinned by a test** — the
suite and the assertion label are in the last column, so `grep -F` finds it — or
explicitly listed under [Not tested](#not-tested) at the end. Nothing here is
documentation of an intention; if it has no pin, the page says so.

Nothing in this document is a promise to a *third* party. It is the contract
between `run-task.sh` and the wall, and the wall is the only thing bound by it:
run-task.sh may add files and fields freely (see
[Additive by policy](#additive-by-policy)).

- [The stage-text vocabulary](#the-stage-text-vocabulary)
- [The run directory, as the wall reads it](#the-run-directory-as-the-wall-reads-it)
- [`result.json`, field by field](#resultjson-field-by-field)
- [Which project a run belongs to](#which-project-a-run-belongs-to)
- [Additive by policy](#additive-by-policy)
- [The one file the wall writes](#the-one-file-the-wall-writes)
- [Serving another harness's runs](#serving-another-harnesss-runs)
- [Not tested](#not-tested)

## The stage-text vocabulary

`run-task.sh`'s `stage()` writes one line of **prose** — `<epoch> <stage text>` —
into the run dir, and three surfaces parse that prose back into *who is working*:
`wall/server.js`, `statusline.sh`, and `status.sh --watch` through
`statusline.sh`. It is the harness's most load-bearing string format and it had
no schema: renaming a literal in `run-task.sh` degraded every reader at once,
silently, and each reader had its own opinion about what the words meant.

**`wall/stage-vocab.json` is now the table**, and it is the only one. Each row is:

| Field | What it is |
| --- | --- |
| `pattern` | The stage text this row claims, as a regex, matched case-insensitively |
| `unless` | A regex that *vetoes* the row — how the table stays disjoint |
| `actor` | Who is working: the name both the wall and the statusline print |
| `key` | The wall's neon signature for that actor, and its rung on the stage→floor ladder |
| `state` | The run state the wall derives: `active` \| `alarm` \| `ready` \| `failed` |
| `color` | `statusline.sh`'s colour for the actor column |
| `example` | A stage string this row must win, and no other row may |
| `inert` | Set when nothing in *this* repo emits the row yet (below) |
| `why` | A note, on the rows that are not self-evident |

Two rules make the table a format rather than a lookup:

- **Exactly one row wins.** The rows are disjoint by construction — that is what
  `unless` is for — so resolution never depends on the file's order, and the
  order is free to be whatever reads best. A stage no row claims resolves to the
  actor `?` and the state `active`: an honest gap, never a guess.
- **A new stage string means a new row, in the same commit.** The test extracts
  every `stage "…"` call site from `run-task.sh` and `sync-pr.sh` (read-only,
  by `grep`) and fails until the table covers it.

| Consumer | How it reads the table | Pinned by |
| --- | --- | --- |
| `wall/server.js` | Reads the file. `actorOf()` and `stateOf()` are a walk over it and nothing else. | `tests/stage-vocab.test.sh` — "server: resolves every row to the actor, key and state it declares" |
| `statusline.sh` | Hardcoded `case` arms. Deliberate: a statusline re-renders on every prompt and must not pay for a `jq` read to name an actor. | `tests/stage-vocab.test.sh` — "statusline: every row resolves to the actor the table names" (and the colour, on the line below) |
| `status.sh --watch` | Sources `statusline.sh`'s `harness_actor`, so it is the same copy. | `tests/statusline.test.sh` — "watch: actor column" |

The test also proves the two directions that matter beyond agreement: no stage
string the pipeline can write is uncovered ("coverage: every stage string the
pipeline writes has a row"), and no row is unreachable ("coverage: every row is
reached by something the pipeline emits"). `stage "done: $STATUS"` is expanded
over the statuses `run-task.sh` can actually write, so the terminal rows are
judged on the real words rather than on a `$`-placeholder.

**Terminal stages.** `done: <status>` carries the outcome. The table matches the
failure *words* — `fail`, `reject` — rather than whitelisting the good ones,
because every failing status ends in `_failed` or is `rejected`, while
`sync-pr.sh`'s prose `done: PR branch synced with main, gate green, pushed` is a
success. Consequences worth knowing, both deliberate:

- A `done:` outcome with neither a failure word nor `needs_input` reads as
  **ready**. That is what lets the base-re-merge line above land as a success
  without the wall knowing anything about `sync-pr.sh`. It is *not* what puts a
  building in the district: only the literal `done: ready` does that, and that
  check lives in `DONE_READY`, not in this table.
- `done: needs_input` is terminal and still an **alarm** — the run stopped on a
  human and stays pinned up until somebody answers. The wall relabels its actor
  and recovers the floor work stopped on from `stages.log`; the terminals hide
  every `done:` line, so the row's `actor` is theirs, not the wall's.

**The inert rows.** Three rows — `^visual fix.*Claude`, `^visual fix.*Codex` and
`^visual gate` — belong to the creative harness's render-and-grade round.
Nothing in this repo emits them, and the test asserts that ("coverage: the rows
flagged inert really are inert in this repo"). They are here because a shared
vocabulary is only shared if both copies already know the whole of it, and the
sibling repo's stale wall exists for no other reason than those rows. `visual
gate` borrows the test gate's neon and its rung rather than inventing a floor,
and `done: visual_failed` therefore burns out on that same rung instead of on a
roof the run never reached.

## The run directory, as the wall reads it

The paper trail itself — every file a run writes, whether the wall reads it or
not — is [the run directory](reference.md#the-run-directory). This is the
subset the wall opens, and the rule for each one is the same: **render what is
on disk, never throw.** The dirs are written live, so any file may be missing,
empty, or caught mid-write, and none of that may blank a wall in a room.

A run dir is *discovered* by having a `status` file: `wall/server.js` lists
`$WALL_RUNS`, keeps directories and symlinks, and orders them newest-first by
that file's mtime. A directory with no `status` is not a run.

| File | What the wall takes | Tolerance | Pinned by |
| --- | --- | --- | --- |
| `status` | First line, `<epoch> <stage text>`. The current stage, and `since`. | Rewritten in place by `stage()`, so a poll can catch it empty or partial: an unparseable first line falls back to the last real line of `stages.log`. Neither ⇒ not a run. | `wall.test.sh` — "partial: an empty status falls back to stages.log/blank, not a crash"; "partial: a status-only run still renders"; "partial: a dir with no status is not a run" |
| `stages.log` | Same `<epoch> <label>` shape, append-only. The `status` fallback, and the floor a terminal `done: needs_input` stopped on (last 8 lines, `__invocation__` markers skipped). | A partial final line is simply the next poll's problem. | `wall.test.sh` — "floor: terminal needs_input stays where work stopped" |
| `started` | First line, epoch. The run's total elapsed. | A non-numeric value degrades to the stage time rather than to nothing. | `wall.test.sh` — "partial: a bad started epoch degrades to the stage time" |
| `worktree` | First line, absolute path. [Which project a run belongs to](#which-project-a-run-belongs-to). | Absent or unreadable ⇒ `result.json`'s copy; neither ⇒ no project, and the run stands in the `UNCHARTED` tower. | `wall.test.sh` — "project: derived from the run dir's worktree pin" |
| `owner` | First line, trimmed, lowercased, capped at 24 chars. The crew tint on the run's car. | **The file wins over `result.json`, including when it is empty** — it exists from the first stage, and an empty pin is a real pin (nobody dispatched this). | `wall.test.sh` — "owner: an empty pin wins over stale result metadata"; "partial: a run with no owner is unowned, not mis-assigned" |
| `brief.md` | The first `# ` heading in the first 8 KiB. The run's title. | No heading ⇒ no title. | `wall.test.sh` — "detail: title comes from brief.md" |
| `activity` | First line, capped at 160 chars. What the worker is touching right now. | Absent ⇒ empty. | `wall.test.sh` — "detail: activity is the worker's last action" |
| `feed.log` | The last 48 non-empty lines of the final 16 KiB. `HH:MM:SS ` is split off as the timestamp; a leading `◆ <src>` attributes the line to the reviewer. | A clipped read starts mid-line, so its first line is dropped. | `wall.test.sh` — "detail: feed tail is shipped"; "detail: feed lines keep their timestamp"; "detail: codex feed lines are attributed" |
| `gate-rounds.log` | Last 8 lines, split on whitespace: **the first two fields only** — round and verdict. | A line with fewer than two fields is dropped. Anything after the second field is ignored on purpose ([below](#additive-by-policy)). | `wall.test.sh` — "detail: gate rounds surface" |
| `QUESTIONS.md` | The opening prose paragraph, headings skipped, hard wraps rejoined, capped at 200 chars. Read only while the run is an alarm. | Absent ⇒ empty. | `wall.test.sh` — "detail: the blocking question surfaces" |
| `REJECTED.md` | The same, read only while the run is `failed`. | Absent ⇒ empty. | `wall.test.sh` — "detail: the rejection reason surfaces" |
| `result.json` | [The fields below](#resultjson-field-by-field). | Missing, empty, half-written or not an object ⇒ treated as absent and retried next poll. Never drops the run. | `wall.test.sh` — "partial: a half-written result.json does not drop the run" |

Two capacity rules are part of the contract because they decide what a busy day
looks like: **live runs are never discarded**, and the JSON feed keeps at most 24
finished ones (`wall.test.sh` — "busy: the older live run survives the history
cap", "busy: only completed history is capped"). A broken run dir is skipped
individually; one of them never blanks the wall.

## `result.json`, field by field

The whole schema is [the metrics schema](reference.md#metrics-schema). The wall
consumes this much of it, and ignores the rest:

| Field | What the wall does with it | Pinned by |
| --- | --- | --- |
| `status` | The run's `outcome`, shown on the brief plate when there is no PR link and no rejection reason. | *untested* |
| `pr_url` | The PR link on a shipped run. | `wall.test.sh` — "detail: pr_url surfaces on a ready run" |
| `demo_url` | The demo recording's link. | `wall.test.sh` — "detail: demo_url surfaces on a ready run" |
| `gate` | The standing gate verdict; falls back to the last verdict in `gate-rounds.log`. | `wall.test.sh` — "detail: gate verdict surfaces" |
| `metrics.diff` | `{insertions, deletions}` — the run's size, and the **height of the building it leaves in the district**. | `wall.test.sh` — "detail: diff size surfaces" |
| `metrics.verifier` | The verifier's advisory score, verbatim, `null` on a run nobody scored. | `wall.test.sh` — "detail: the verifier score surfaces"; "detail: a run from before the verifier carries null, not zero" |
| `owner` | Fallback for the `owner` file. | `wall.test.sh` — "owner: an empty pin wins over stale result metadata" |
| `worktree` | Fallback for the `worktree` file. | `wall.test.sh` — "project: a worktree only in result.json still names the tower" |
| `branch`, `implementer_model`, `reviewer_model` | Carried in the snapshot for a reader of `/api/runs`. Nothing on the page draws them. | *untested* |

**The diff is held to a stricter rule than everything else here,** because it is
the one field the wall turns into a permanent claim. A building's height is a
record of a real diff, so `metrics.diff` supplies one only when `result.json`
parses to an object, `metrics` is an object, `diff` is an object, and both
`insertions` and `deletions` are present and are either `null` or a finite
number ≥ 0. Anything else — a truncated file, a bare `true`, an object caught
between schema fields — is *not a building*, and is retried on the next poll
rather than rendered at a height invented from a file the wall could not trust.
A recorded **zero**-line diff is valid, and is the shortest building there is.

Pinned by `wall.test.sh` — "tolerance: a half-written result.json builds
nothing, and does not crash", "tolerance: neither does a run with no result.json
at all", "tolerance: valid JSON without the result schema is still malformed",
"tolerance: a recorded zero-line diff is the shortest building", and
"tolerance: only a result-shaped JSON value supplies a building diff".

## Which project a run belongs to

There is no repo field in a run dir. `run-task.sh` builds each worktree as
`<repo-dir>-<ticket-lowercased>` beside the repo and records that absolute path;
the wall **reverses the construction** — take the path's basename, strip a
trailing `-<run-id-lowercased>`, lowercase the rest — and that is the tower the
run climbs. It is the only project identity a run dir carries, which is why the
construction on the writing side is pinned too:

| Claim | Pinned by |
| --- | --- |
| `run-task.sh` still builds `<repo>-<ticket>` beside the repo, still writes it to the run dir, and still copies it into `result.json` | `wall.test.sh` — "project: run-task.sh still builds <repo>-<ticket> beside the repo" (and the two checks after it) |
| The `worktree` file wins; `result.json` is the fallback | `wall.test.sh` — "project: a worktree only in result.json still names the tower" |
| An adhoc ticket's suffix comes off the same way | `wall.test.sh` — "project: an adhoc ticket suffix comes off the same way" |
| A long repo name is neither truncated nor merged into another tower | `wall.test.sh` — "project: long repo basenames are not truncated or merged" |
| An unreadable worktree yields **no** project, and the run stands in the honest `UNCHARTED` tower rather than under a repo it may not belong to | `wall.test.sh` — "project: an unreadable worktree yields no project, never a guess" |

Prose version, for a reader who arrived from the wall page:
[Which tower a run stands in](wall.md#which-tower-a-run-stands-in).

## Additive by policy

The contract is one-directional. `run-task.sh` may add files to a run dir and
fields to `result.json` whenever it likes, and the wall will not notice; the
only thing it may not do is change the shape of something listed above without
changing the wall in the same commit.

`gate-rounds.log` is the worked example. It began as `<round> <verdict>` and now
carries `<round> <verdict> <seconds>\t<failed step>`. The wall still splits on
whitespace and takes the first two fields, so it reads new logs and old ones
identically, and the telemetry that needed a third and fourth field got them
without a migration. `run-task.sh` says so at the write site, naming this reader.
The same policy is why the wall reads *first lines* out of `status`, `owner`,
`worktree` and `started` rather than whole files.

## The one file the wall writes

`wall-city.jsonl` — the district's memory, beside the runs dir by default, moved
with `--city` / `WALL_CITY`. It is the **only** file the wall writes, and
**nothing else in the harness reads it**: not `run-task.sh`, not `metrics.sh`,
not `cleanup.sh`. It is not a schema anybody else may depend on, and its rules,
its rollover and what deleting it does are on the wall page under
[The ledger is the city's memory](wall.md#the-ledger-is-the-citys-memory).

The reason it exists at all is this contract's one real asymmetry: a run dir is
**not permanent**. `cleanup.sh` promotes a run and mirror removal deletes the
mirrored copy off the wall's own machine, so run dirs can only ever be how the
wall *discovers* a ship. The ledger is how it *remembers* one.

## Serving another harness's runs

Nothing above is specific to `~/.claude/harness`. `--runs` points the wall at
any directory of run dirs written to this contract — which is how one screen
serves a second harness on the same machine:

```bash
wall.sh --runs ~/.claude/creative-harness/runs   # a sibling harness's runs
wall.sh --runs wall/fixtures/runs                # the repo's staged demo data
```

`--runs` is a thin wrapper over `WALL_RUNS`; either spelling does the same
thing. Two consequences of pointing it elsewhere:

- The city ledger defaults to *beside the runs dir*, so a second harness gets
  its own district rather than sharing one. Pass `--city` to override.
- The fixture district is seeded only when the wall is serving this repo's own
  `wall/fixtures/runs` **and** has no ledger yet. Any other `--runs` is never
  seeded into.

Pinned by `wall.test.sh` — every server in that suite is started through
`wall.sh --runs`, and the seeding guard by "guard: fixtures staged anywhere else
are a plain, exactly as before" and "guard: a ledger that already exists is
never seeded into".

## Not tested

Everything above carries a pin except these, listed here rather than left to be
discovered:

- `result.json`'s `status`, `branch`, `implementer_model` and `reviewer_model`
  reaching `/api/runs`. The last three are carried for a reader of the JSON and
  are drawn nowhere, so nothing would notice their absence.
- The prose in this file about *why* each rule is the way it is. The rules are
  pinned; the reasoning is not, and cannot be.
- The creative harness's own emission of the three inert stage rows. This repo
  can only assert that it does *not* emit them; whether the sibling's
  `run-task.sh` writes exactly those strings is that repo's test to own, and the
  re-unification's job to prove.
