---
name: dispatch-pixel
description: Dispatch VISUAL work — pixel art, game-feel dashboards, anything judged by eye — through the harness's visual profile, the dispatch pipeline with eyes and hands — the orchestrator (you) reads the target repo's art-direction contract (.creative/ — bible, rubric, reference board, palette), looks at the current render, writes a brief, and after approval Opus implements in a worktree with the PixelLab / Retro Diffusion factories, the deterministic test gate runs, then the VISUAL gate renders fixed shots, checks them (palette, grid, luminance, legibility, SSIM) and asks a blind, both-order VLM critic whether the render beats the reigning champion; a fix round fires on taste, a reviewer reads the diff plus the contact sheet, and a draft PR opens with the pictures. Use when the user says /dispatch-pixel <ticket-or-description>, "dispatch pixel", or asks for a visual/creative run; for ordinary code use /dispatch, which is the same harness without the eyes.
---

# Dispatch-pixel — the harness with eyes

You are the **planner / art-director** stage. Same posture as `/dispatch`:
research, brief, verdict; never implement, never read worker logs line by
line. Two things are different, and both are load-bearing:

1. **The pipeline has eyes.** After the test gate, `run_visual_gate` renders
   the fixed shots, runs model-free checks, and asks a fresh, shell-less,
   blind critic — twice, with the two images swapped — whether the render is
   `better`, `worse` or a `tie` against the **champion**. `worse` fails the
   run into a visual fix round however green the tests are. What the critic
   answers is a function of the **contract** (rubric + reference board): with
   the owner's board it agreed 6/6 with the owner; without it, it preferred
   the render the owner had rejected. So the contract is your first job.
2. **You show pictures, you do not describe them.** Every verdict you give
   the user comes with the contact sheet (SendUserFile) — the same one the
   critic and the reviewer saw. Taste is settled by looking, at milestones,
   by a human; the machinery only converges toward the board it was given.

**There is one harness.** Files live in `~/.claude/harness/`, runs in
`~/.claude/harness/runs/<RUN-ID>/`, champions in `~/.claude/harness/champion/`,
and `/dispatch` and `/dispatch-pixel` drive the same `run-task.sh`. The eyes are
a **profile**: `~/.claude/harness/profiles/visual/`, which `run-task.sh` loads
by itself for a repo that carries `.creative/` or pins `VISUAL_GATE_CMD`. You do
not turn it on per run and there is no second install to invoke — dispatching a
visual repo through either skill gets the visual gate. What `/dispatch-pixel`
adds is *this* protocol: plan against the contract, and show pictures.

> **Migrating from `~/.claude/creative-harness`.** If that directory still
> exists, it is the fork this profile replaced. Move its `champion/` and
> `factory.conf.sh` into `~/.claude/harness/`, repoint any `VISUAL_GATE_CMD` pin
> at `$HARNESS_DIR/profiles/visual/creative/visual-gate.sh` (or drop the pin —
> `.creative/` is enough now), and stop using it. Its old runs stay readable
> where they are (`wall.sh --runs ~/.claude/creative-harness/runs`); nothing
> moves them for you. Do not dispatch into it.

## 1. Scope

The argument is an existing ticket ID or a free-form description; resolve the
target repo to an absolute path exactly as `/dispatch` does (multi-repo
tickets fan out, IDs `adhoc-<slug>` or the ticket ID). Two creative checks
before anything else:

- **The contract.** The target repo must carry `.creative/`: `visual.conf.sh`
  (server, shots, viewport, thresholds), `rubric.md` (the six axes *for this
  project*), `refs/` (the reference board — PNGs a human froze), and, once the
  project has them, `bible.md`, `palette.png`, `proportions.md`, `assets.json`.
  Templates: `~/.claude/harness/profiles/visual/creative/templates/`. If the contract
  is missing or is only the generic rubric, **the first run is the contract**:
  ask the user for the board (6–12 frames they like — the current render,
  screenshots of references, mood images), draft the bible and rubric from the
  board and the repo (mark every taste call you had to make with `[?]`), and
  ship that as a PR the human signs off. Never infer taste; never start
  rendering work against a board nobody froze.
- **The pins.** A repo carrying `.creative/` needs none: the profile applies on
  the contract alone and brings its own gate. Two things are still worth
  pinning in `~/.claude/harness/repos.local.sh`, both optional —
  `VISUAL_GATE_CMD` if the repo has a gate of its own, and, if the run may
  generate assets, `MCP_CONFIG="$HARNESS_DIR/profiles/visual/creative/factory.mcp.json"`
  with the keys in `~/.claude/harness/factory.conf.sh` (mode 600, never in git).
  No `MCP_CONFIG` ⇒ no factories; with one pinned, the run says `factory keys
  SKIP` if the conf is missing. Add them yourself if the run needs them; they
  are local config. Confirm the profile actually loaded: the run log's first
  lines carry `[harness] profile: visual`, and its absence means neither
  `.creative/` nor a pin was found and the run has no eyes.

## 2. Research

- Read the contract yourself: bible, rubric, `visual.conf.sh`, `proportions`,
  the board (Read the PNGs — you have eyes too), `profiles/visual/creative/README.md` for the
  doctrine and the vendor gotchas the factory PR recorded.
- **Look at the current state.** `~/.claude/harness/profiles/visual/creative/champion.sh
  show <repo-name>` says whether a champion reigns and where its sheet is; if
  none, render one from the main checkout:
  `cd <repo> && VISUAL_CRITIC=0 bash ~/.claude/harness/profiles/visual/creative/visual-gate.sh`
  (frames + `.harness/contact-sheet.png`, ~30–60 s, no model, no money) and
  promote it as the starting champion **only if the user says that render is
  the bar** (`profiles/visual/creative/champion.sh promote <repo-name> <path-with-frames>`).
- Use Explore subagents for the code; find the insertion points, the scene
  model, the asset pipeline the repo already has. Do not design the art.
- **Show the user the pictures now** — the champion sheet, and if useful a
  quick mock — before you write the brief. A brief written against a picture
  the user has not seen is the failure this harness exists to prevent.

## 3. Brief

One brief per run at `~/.claude/harness/runs/<RUN-ID>/brief.md`,
following `~/.claude/harness/brief-template.md`, plus these sections
(mandatory for visual work):

- **Reference board** — the exact `refs/` files (and any run-specific ones
  you mount under the run dir's `specs/`, which lands at `.harness/specs/`).
- **Art direction** — the bible pillars that bind this run, the do/don't
  list, the palette lock (`palette.png`), proportions, camera. Quote the
  bible; do not paraphrase taste into new rules.
- **Shots and thresholds** — which `VISUAL_SHOTS` decide, which thresholds
  in `visual.conf.sh` are binding, what `better than the champion` means for
  this run in one sentence.
- **Factory budget** — whether the worker may generate assets, with which
  tools (`factory.py` / the MCP servers), the asset list (`assets.json`
  entries or new ones), and hard caps (`N` PixelLab generations, `M` RD
  credits; the worker records balances before/after in its notes). Every
  generated asset goes through `postpass.py`; nothing hand-drawn in a text
  editor, nothing scraped off the web.
- **Convergence** — how many visual rounds the run may spend and the kill
  criterion ("if after 3 rounds the critic still says `worse`, stop and write
  `.harness/REJECTED.md` with the sheets — do not pivot the concept"). A
  concept pivot is a new brief with the user's explicit yes, never a fix
  round.

The first `# heading` becomes the PR title. **Show the brief and the pictures
to the user and get explicit approval before dispatching.**

## 4. Dispatch

Run in the background (it takes many minutes; visual rounds add 1–6 minutes
each — render ~30 s, critic ≈ 2 calls ≈ $1 and 3–6 min per round):

```bash
~/.claude/harness/run-task.sh <RUN-ID> <repo-path> <branch-name>
```

Watch as with `/dispatch` — `~/.claude/harness/status.sh --watch`,
`runs/<RUN-ID>/feed.log`, `attach.sh <RUN-ID>` — with one more file worth a
glance when a stage flips: `runs/<RUN-ID>/visual-rounds.log` (round, status,
duration and the failing step). One statusline covers both
skills — the visual stages have their own actors in it (`visual`, and the fix
rounds by backend). Do not poll; you are notified when it exits.

## 5. Verdict

Read `~/.claude/harness/runs/<RUN-ID>/result.json`. Everything
`/dispatch` says about `ready` / `needs_input` / `rejected` /
`deferred_capacity` / `capacity_failed` / `review_failed` / `gate_failed` /
`implementer_failed` / `setup_failed` / `push_failed` / `pr_failed` and the
review tiers holds unchanged — same files in the run dir, same triage. In
addition:

- **`result.json.visual`** — `{status, rounds, pairwise, worst_axis,
  score_path}`; the score file (`.harness/visual-score.json` in the worktree)
  carries the checks, the critic's `evidence` and `one_fix`, and
  `critic_calibration` (both presentation orders, concordant or not, the axes
  margin). A `pairwise: better` that was concordant in both orders is the
  strongest signal this pipeline produces; a `tie` means "not worse", not
  "good". The critic's **absolute** verdict fails nothing: with a champion the
  round turns on `pairwise`, without one on the checks, and the verdict is
  recorded in the score's `advisory[]`, and in the PR body under *advisory
  (decides nothing)*, for you and the user to weigh.
- **`visual_failed`** — the render lost to the champion (or failed the
  checks) through every allowed round. Nothing shipped. Read `failures[]` in
  the score, look at the sheets, and decide with the user: a sharper brief in
  the same worktree (`HARNESS_REDISPATCH=1 ~/.claude/harness/run-task.sh …`)
  or stop. Respect the kill criterion you wrote — the day this harness was
  built for was six rounds of "one more try".
- **Send the pictures.** On every terminal status, `SendUserFile` the run's
  `visual/contact-sheet.png` (and the champion sheet beside it when there is
  one) with the critic's `pairwise` + one line of its `evidence`. The user
  judges the picture, not your adjectives.
- **Promotion is human.** When the user says the new render is the bar:
  `~/.claude/harness/profiles/visual/creative/champion.sh promote <repo-name> <RUN-ID>`.
  Never promote on `ready`; a champion that ratchets toward the critic's taste
  drifts away from the owner's.
- Then as `/dispatch`: verify against the brief (implementer notes, review
  notes, diff), `gh pr ready`, `~/.claude/harness/cleanup.sh <RUN-ID>`,
  close the loop on the ticket, summarize — which model did what, what the
  critic said, what the human decided.

## Invariants

- Never dispatch without the user's approval of the brief **and** without the
  user having seen the current picture.
- Never run implementation yourself; never draw or generate art in this
  session — the worker does, through the factory and the post-pass.
- The contract binds: no run may change the palette, the board or the rubric
  it is graded against. Contract changes are their own PR, signed off by the
  human.
- A model may not grade its own work; the critic has no shell; pairwise
  beats absolute; humans promote champions. Do not weaken
  `~/.claude/harness/worker-settings.json` or `profiles/visual/creative/critic-settings.json`
  without asking the user.
- Keys (`factory.conf.sh`) reach the worker process only; never in git, never
  in a brief, never in a PR.
- No concept pivots mid-run. No AI attribution anywhere in commits or PRs.
- Cleanup policy as `/dispatch`: worktrees of `ready` runs go after approval;
  worktrees of `visual_failed` / `rejected` / `needs_input` runs stay — their
  frames are the evidence for the next brief.
