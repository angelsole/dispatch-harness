# Ghost Shift

The big-screen run dashboard: what the wall draws, what each thing on it means,
and how to run one.

`wall.sh` is the same picture as the statusline for a room instead of a
terminal: a read-only web page for an office TV showing what every agent is
doing right now. It reads the same run dirs as
[everything else](reference.md#monitoring-surfaces) and never dispatches
anything.

This page is what the wall *means*. What it **reads** — every run-dir file,
every `result.json` field, the exact tolerance for a file caught mid-write, and
the stage-text vocabulary all three monitoring surfaces parse — is its own
page: [the wall's data contract](wall-contract.md).

## The city

The wall is a **city at night**. Each project is a tower; each run is a lit car
climbing it; the floor the car has reached is the run's pipeline stage — street
level is setup, then implement, gate, review, demo, and the roof is the PR. The
car carries the neon of whichever model owns that stage, so a glance across the
room reads as *which repos are busy, how far along, and who is driving*:

| On the wall | What it means |
| --- | --- |
| A tower | One project. It stands only while it has live work — a repo nobody is working in right now is simply not in the skyline. Its silhouette is stable, so the room learns the city as a place. |
| A lit car | One run, at the floor of its current stage, in its actor's neon. |
| A rooftop beacon flare | A run reached `done: ready` and its PR is open. |
| A tower lighting up floor by floor | The same run, celebrating: six seconds of light climbing the facade, the rooftop lamp thrown wide and the ticker printing what shipped, before the run leaves the skyline the normal way. Once per run — a browser opening halfway through joins the beat in progress rather than replaying it. |
| A searchlight + red tower | A run wrote `QUESTIONS.md` and is waiting on a human. It is the loudest thing on the screen, and it pins the brief plate until you answer it. |
| A red flare, then dark | A rejected or failed run, burning out at the floor it stopped on. |
| A beam out of the cloud | The run the brief plate is currently featuring — its building lights up and the rest of the city steps back, so the plate and the skyline are never two separate stories. |
| A tinted light on the car | Who dispatched that run, in their own stable tint; the name itself is on the plate and in the ticker. `bot` gets the milk-white synthetic tint. |
| `UNCHARTED` | Runs whose worktree cannot be read — honest about the gap rather than filed under a repo they may not belong to. |

**The skyline is live.** A finished run gets one short completion moment — the
rooftop flare, or the burnout — and is then gone, and a tower with nothing left
standing in it goes with it. The city grows and shrinks with the work, which is
the only thing worth putting on a wall; yesterday's green ticks are in
`status.sh` and in the PR list, where you can act on them. `/api/runs` still
carries the finished runs (it is the honest snapshot of the run dirs) — the
skyline is the part that is live only.

## The district

**The district accretes.** Under the live towers, the week builds up. Monday
00:00 local the plain is empty; every run that reaches `done: ready` pours one
**permanent building** into it; by Friday the city *is* the week's shipped work,
with whatever is still being built rising among it. Last week's city stands
behind this one as a single flat ghost silhouette — the name finally earning
itself — and Monday 00:00 empties the plain again.

| In the district | What it means |
| --- | --- |
| A building | One run that shipped this week. It never leaves before Monday. |
| Its family | The repo. Repo names are matched, in order, against a small table of families — residential, industrial blocks, an observatory spire, infrastructure — and anything unmatched is an honest mid-rise. The mapping is in `wall/server.js`; edit it there for your own repos. |
| Its type | What kind of building the street put up: a **shophouse** (low, wide, a terrace of bays), a sawtooth-roofed **warehouse**, a **tank** carrying a water tower, a **slab** (the family's own roofline), a stepped **setback** tower, or a thin **mast** with an antenna. Hashed from the run id on its own draw, and weighted low — the district is a city with a couple of towers in it, not a bar chart standing up. The type owns the footprint and the roofline; it never raises a building above what its family and depth band could already ship. |
| Its height | The run's diff (insertions + deletions), log-scaled and capped — a monster PR reads big without dwarfing the block — then reshaped by the type, so a 2000-line shophouse is still a shophouse. A recorded zero-line diff is the shortest building there is; an unreadable or structurally malformed `result.json` is *not a building*, because a height invented from a result the wall could not trust is the one thing that would make the city lie. |
| Where it stands | Hashed from the run id, so the skyline is identical on every screen and after every reload. |
| A small lit sign | Who dispatched it, in the same crew tint as their runs' cars — cooling to the district's neutral within six hours of landing. That is the whole of the attribution. |
| A lit shopfront row, and sometimes a neon | The ground floor, from the week's **first** ship. Which shop is under a building — a noodle bar, a diner, an arcade, a repair shop — and whether it carries a sign is hashed from the run id, so it is the same on both screens and the same tomorrow. |
| A few windows fading on and off | Occupancy: three windows per facade keeping their own hours, each on its own loop length and its own seeded phase. Nothing on this street blinks in unison. |
| Steam, somebody walking, a car going past | Nightlife, present whenever anything is standing. The week only sets the **tempo**: more people out (up to six), more vehicles (up to three), and the gap between passes falling from 48 seconds on the first ship to 11 on the twenty-fifth. |
| A mall block, a tram | The milestones, and now only that: extra texture at twelve and twenty ships, on top of a street that was already alive. |
| A pale flat outline behind | Last week. A height and a plot, nothing else — no windows, no signs, no types. An empty last week draws nothing. |

## The ledger is the city's memory

*Permanent* is the contract, and a run dir is not permanent: `cleanup.sh`
promotes a run and mirror removal deletes the mirrored copy off the wall's own
machine, so a city derived from what happens to be on disk would demolish a
building the moment somebody tidied up after it. Run dirs are therefore how the
wall **discovers** a ship; one append-only JSONL file is how it **remembers**
one:

```bash
wall.sh --city /var/wall/city.jsonl   # default: beside --runs, as wall-city.jsonl
export WALL_CITY=/var/wall/city.jsonl # same thing
```

The first time the server sees a run at `done: ready` with a finish epoch in the
current week, it appends one line — `{id, epoch, repo, owner, insertions,
deletions}` — and never writes that run again. Everything a building *looks
like* is derived from that line at render time, so the mapping above can change
without rewriting history. One line per run id is also what makes a run mirrored
from another machine
([`HARNESS_MIRROR`](operations.md#runs-from-any-machine-harness_mirror))
harmless: the same ship discovered twice is still one building, and the first
sighting is the one that stands.

Monday's rollover prunes anything older than the two windows the wall can draw,
rewriting the file through a temp file and a rename. A missing or unreadable
ledger is an empty plain and one line on stderr; a corrupt *line* is skipped
rather than fatal. Nothing about the city can take the wall down — but
**deleting the ledger razes the city**, and nothing else does.
It is the only file the wall writes; it is not a schema, and nothing else in the
harness reads it.

One consequence worth knowing: the ledger records what the wall *witnessed*. A
wall started midweek picks up this week's ships whose run dirs are still on disk,
but a ship that was already cleaned up before the wall came up is not
backfilled — and last week's ghost is whatever last week's wall recorded.

Because a full district is normal on a Thursday evening, "nothing live" no
longer means "nothing happened": the `SHIFT STANDING BY` plate now appears only
when the week has **no buildings and no live runs**, and a week that shipped
work with nothing currently climbing gets one quiet `DISTRICT AT REST` line
instead. The wall never looks broken on a week that delivered.

**Rest is a mood, not a shutdown.** At rest the construction glow is gone and
the nightlife is not: a city is alive because somebody is eating noodles at one
in the morning, not because a crane is moving. All of it lives in the
ground-floor band, and every part of it drops a stop the instant something is
climbing — the skyline owns the room's eye whenever there is work on it.

## The plate and the ticker

Towers cannot carry type you can read from four metres, so two surfaces do:
a Blade Runner **brief plate** cycling the live runs in big letters (ticket,
project, stage, actor, dispatcher, the blocking question), and a green-phosphor
**comms ticker** along the bottom carrying the tail of every live `feed.log`.
The plate is chrome around the words and never instead of them — cut corners, a
hairline frame with registration ticks, and an edge lit in the featured run's
own actor neon, which goes red the moment that run is the one asking for a
human. Moving on to the next run is a hand-over rather than a cut: the old
contents ease out, and the new ones are not written until the plate is empty.

## Running one

```bash
wall.sh                             # ~/.claude/harness/runs on http://0.0.0.0:4711
wall.sh --port 8080 --host 100.x.y.z
wall.sh --runs wall/fixtures/runs   # staged demo data, no live runs needed
wall.sh --city /var/wall/city.jsonl # keep the district's memory somewhere else
```

Each flag has an environment equivalent: `WALL_PORT`, `WALL_HOST`, `WALL_RUNS`,
`WALL_CITY`.

`--runs` is not only for the fixtures: it takes **any** directory of run dirs
written to [the contract](wall-contract.md), which is how one screen serves a
second harness living beside this one.

```bash
wall.sh --runs ~/.claude/creative-harness/runs   # a sibling harness's runs
```

The city ledger defaults to *beside the runs dir*, so that second harness
accretes its own district rather than sharing this one's — pass `--city` if you
want them somewhere else.

Then point a browser on the TV at `http://<this-machine>:4711/` and put it in
fullscreen (Chrome: `--kiosk --app=http://<host>:4711/`). With nothing running
you get the empty city in the rain and no text at all — the wall reports work,
it does not report people. It is one dependency-free `node` (≥ 20) server and
one static page, and **everything the page loads ships in this repo**: the
DOM/CSS world (the default, drawn in CSS, inline SVG and one small canvas for
the rain) and, behind `?world=canvas`, a WebGL world drawn with a vendored,
pinned Phaser 4 (`wall/vendor/`, MIT, licence and sha256 beside it, listed in
[`wall/THIRD_PARTY.md`](../wall/THIRD_PARTY.md)). No build step, no npm at
runtime, no CDN, and no request that leaves the machine, so it is happy on a
tailnet-only screen. Everything that moves moves by `transform` or `opacity` on
one of two easing curves, and `prefers-reduced-motion` stops the rain, the
traffic and the searchlight's travel and leaves the same city standing still —
in either world. There is no auth: keep it off the public internet.
`wall/fixtures/seed.js` regenerates the staged fixture runs, and serving *those*
fixtures with no ledger yet seeds a week's district to stand under them
(`wall/fixtures/city.js`) — so the demo opens on a city that has shipped rather
than on an empty plain. Any other `--runs`, or a ledger that already exists, is
never seeded into.

**The query string.** Two switches, both read once at load:

```
?world=canvas   draw the city with the vendored Phaser 4 instead of with CSS.
                Same scene, same skyline, same street — the DOM world's layers
                are left in the page and hidden, and the 1.4 MB engine is only
                requested by a wall that asked for it. The DOM world is the
                default and nothing about it changes.
?cinema=1       start the ambient camera immediately (`?cinema=0` never lets it
                run); the `c` key toggles it either way, and any other input
                dismisses it. Both are outranked by prefers-reduced-motion.
```

**The weather is not a loop.** Rain drifts over tens of minutes between
near-dry spells and downpours, the street haze thickens and clears several
minutes behind it, and the sky cools toward dawn on the browser's own clock —
so a wall in another timezone is right without the server knowing where the
room is. The weather state is a pure function of the wall clock, and individual
drops use a coarse wall-clock seed, which is what makes two screens opened side
by side show the same night.
`prefers-reduced-motion` leaves the whole drift unwritten and keeps the static
scene.

## The ops console

The city is for a room. `http://<this-machine>:4711/console` is for the person
operating the runs: a dark flight board, dense and tabular, with no city in it
at all.

One row per run — id, repo, the **provider badge** (GLM or OPUS, off the run's
`implementer-provider` pin rather than off the stage text, which says
"Opus (Claude sub)" whatever is actually being spent), the stage and its actor,
the **activity** line (the tool and file the worker is touching right now),
time in stage, total elapsed, `+/−`, turns, **cost** (z.ai credits for a GLM
run, list-price dollars for an Opus one, `—` when telemetry could not price it)
and a pip per gate round. Runs that
`needs_input` are pinned to the top in red, because they are the only thing on
the board that is waiting on a human. Finished runs collapse underneath,
newest first.

Above the boards sits the **last 7 days** header — ship rate, PRs a day,
finished runs, the summed list price, the GLM-vs-Opus per-run comparison —
taken over every run whose status moved inside the window, not just the capped
recent feed. Every cost figure is a list-price counterfactual (`wall/cost.js`
reads what `run-task.sh` already recorded and re-prices nothing): both plans
are flat-rate, so none of it is money spent.

Click a row and it opens: the run's title, why it is blocked when it is, the
tail of `feed.log`, and the one control the console has —

```bash
~/.claude/harness/attach.sh <RUN-ID>
```

— as a copy-able command. Everything the console can *do* is that paste. It
never mutates a run, and it draws this machine's `WALL_RUNS` plus whatever other
machines have [reported in](#ingest). A reported run wears a dashed host chip
and a hatched row, and where its paste would be it carries the machine's name
instead: `attach.sh` opens a session here, and that run is not here. To follow
its files rather than its stages, use the
[mirror](operations.md#runs-from-any-machine-harness_mirror) as well; the two
compose.

It is live over `/api/stream` and falls back to polling `/api/runs` every few
seconds when the stream drops (the dot in the top-right says which). A snapshot
that does not parse leaves the previous board standing rather than blanking it.

**Why it is worth knowing this exists.** `wall/server.js` is not a city server
that happens to expose JSON — it is **the run-data layer**, and `/api/runs` and
`/api/stream` are its interface. The city is one frontend over it; the console
is the second, and shares not a line of code with the first. Lifting that layer
into its own directory so N frontends (web, mobile, pixel) hang cleanly off it
is deferred work and nothing here does it — this is only the proof that the
seam is real.

## Ingest

**Two commands, no secrets typed.** On the machine that runs the team's wall:

```bash
~/.claude/harness/wall.sh --init-token        # writes wall-ingest-token (600) + wall-url, then exits
launchctl kickstart -k gui/$(id -u)/<label>   # or re-run wall.sh: it reads the token file itself
```

On each laptop that should report there:

```bash
~/.claude/harness/install.sh --team <ssh host>   # reads both files over ssh, writes notify.conf
```

`wall-url` defaults to the machine's Tailscale IPv4 and the wall's port; pass
`--url http://…` to override. `WALL_INGEST_TOKEN` in the environment still wins
over the file.

The wall reads run dirs, and run dirs are on one disk. **Ingest** is the other
direction: a run POSTs what it is doing to a wall, so four people on four
machines watch one board. It is off unless the wall is started with a token:

```bash
WALL_INGEST_TOKEN=a-long-random-string wall.sh          # on the machine with the screen
export HARNESS_WALL_URL=http://mini:4711                # in every dispatching shell,
export HARNESS_WALL_TOKEN=a-long-random-string          # or in that machine's notify.conf
```

With `HARNESS_WALL_URL` unset a dispatch sends nothing and sets nothing. With it
set, a run opens three channels, all of them best-effort and none of them able to
delay or fail a run:

| Channel | Who sends it | What it carries |
| --- | --- | --- |
| `POST /api/ingest/stage` | `run-task.sh`, on every stage handoff | the stage text and the run's identity: host, owner, repo, provider, model, worktree, branch, base, PR URL, status |
| `POST /api/ingest/hook` | `lib/wall-hook.sh`, from the worker's `PostToolUse` / `Stop` / `SessionEnd` hooks | the event name, the session, and the tool name plus its command / file path / description, each capped at 200 characters |
| `POST /v1/metrics` | the worker's own OpenTelemetry exporter | `claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.session.count` |

A run the wall has never seen on disk becomes a **row of its own**, marked
remote. A run that is *both* on disk (mirrored) and reporting is **one row** —
the disk record wins and the telemetry attaches to it. Either way the numbers
land in the row's cost and turns cells while the run is still live, which is
sooner than `result.json` can answer.

`/v1/logs` and `/v1/traces` answer `200 {}` and discard the body, so an exporter
somebody pointed here by hand stops retrying instead of filling a run's stderr.
The harness never turns either of them on: one single-tool session produced a
63 KB log body, and every log record carries the operator's identity.

**What the wall drops on the way in.** The CLI's metric datapoints carry
`user.email`, `user.id`, `user.account_uuid`, `user.account_id`,
`organization.id` and `terminal.type` beside the numbers. None of them is
stored, written to disk, or served — they are dropped at the ingest boundary,
before anything reaches memory. What is kept is the session id, the model name
and the token type.

**Where it lives.** In memory, keyed by run id, persisted to `WALL_INGEST_FILE`
(by default beside the runs dir, like the city ledger) at most once a second, and
reloaded at boot — a launchd restart on the office machine must not blank the
board. An entry nothing has updated for seven days is pruned.

**The privacy boundary is unchanged.** Everything above is **console view only**.
`/api/runs` and `/api/stream` without `?view=console` return exactly what they
returned before ingest existed: no telemetry on any run, and no remote rows at
all. The city, the towers, the district and the summary are computed from the
disk alone. There is still no auth on any GET route, and the token is a
LAN-dashboard secret, not a vendor credential — see
[Security](security.md#the-wall-ingest-token).

## Which tower a run stands in

`run-task.sh` builds each worktree as `<repo-dir>-<ticket>` beside the repo and
records that absolute path in the run dir (and in `result.json`); the wall
reverses the construction to recover the repo name. Nothing new is pinned for
the wall's sake, and a run whose worktree is unreadable goes to `UNCHARTED`
rather than being guessed at.

## Who dispatched a run

`run-task.sh` pins `HARNESS_OWNER` into the run dir on the first dispatch (and
into `result.json`), the same way it pins the arm and the model knobs — a resume
from someone else's session never re-attributes a run. Export it wherever you
dispatch from:

```bash
export HARNESS_OWNER=you        # e.g. in the station session's shell
```

That name only ever becomes the tint of the light under a run's car, the small
sign on the building that run left behind, and the name on that run's brief
plate and ticker line. There are no lanes, no districts, no per-person counts
and no idle states anywhere on the wall: an empty slot beside a colleague's
three lit floors is social pressure, not information. The building sign cools to
neutral within six hours, so by the next morning the week is simply the week's.
`--crew` (or `WALL_CREW`) is still accepted so existing launch scripts keep
working, but a declared roster no longer puts anything on screen.

## The look is a contract

How the wall is allowed to look lives in `.creative/`: `bible.md` is what the
city is and its do/don'ts, `rubric.md` the six axes a render is graded on,
`proportions.md` the module and every measured element, `palette.png` the
32-colour lock, `refs/` the frozen reference board, and `visual.conf.sh` what to
serve, which shots, and one threshold per check. Renders are graded against it
by the creative harness (`/dispatch-pixel`, `~/.claude/creative-harness`);
changing the contract is its own PR signed off by the owner, never a side effect
of a feature.
