# creative/ — the harness's eyes

**A model may not grade its own work; the critic has no shell; pairwise beats
absolute; humans promote champions.** Everything in this directory follows from
those four sentences. The critic runs in a fresh `claude -p` session that had no
hand in the render, under a profile that allows `Read` and `Glob` and nothing
else — the rubric is untrusted repo text and the frames were made by the worker
being graded, so neither may reach a command line. Its per-axis scores are
advisory, because a VLM's absolute aesthetic score is noisy and calibrated by
nothing; the verdict the gate acts on is *is this better than the champion*. The
critic is **blind** to which of the two sheets is the champion, it is asked in
**both presentation orders**, and a verdict it will not repeat is a **tie** —
because a judge that answers "worse" whichever sheet you call the incumbent has
not told you anything about the pictures. And the champion only ever changes
when a person runs `champion.sh promote`, because a champion that auto-updates
on every green run ratchets toward whatever the critic liked this week, and six
green rounds later the picture is worse than where it started.

## The files

| File | What it is |
|---|---|
| `visual-gate.sh` | The stage entry — what a repo's `VISUAL_GATE_CMD` runs. Starts the server, renders the shots, runs the checks, builds the sheet, asks the critic, writes `visual-score.json`, returns pass/fail. |
| `frames.py` | Deterministic capture on the Playwright inside shot-scraper's venv: revision-pinned managed Chromium, SwiftShader, frozen clock, seeded `Math.random`, an app-ready predicate. |
| `vcheck.py` | The model-free checks: palette conformance, grid pitch and off-grid share, pure-black share and luminance floor, TV-distance legibility, frame-to-frame continuity, 8×8-block SSIM against the champion. |
| `contact-sheet.sh` | The frames as one sheet, kept under 500 KB (above that the Read tool recompresses PNGs to JPEG and smears every hard edge the checks care about). |
| `critic.sh` | The critic calls: fresh session, no shell, `--json-schema`, reference board → image A → image B, asked twice with A and B swapped. |
| `critic-settings.json` | That profile. |
| `rubric.md` | The default six axes, used when the repo ships no `.creative/rubric.md`. |
| `champion.sh` | `promote <repo> <run-id\|dir>` / `show [repo]`. The only way a champion changes. |
| `critic-eval.sh` | The critic's own test: known pairs through the real critic, scored on accuracy, order-concordance and repeat-agreement. Live only. |
| `eval/` | `pairs.json` and the sheets it names — the pairs a human has already ranked. |
| `factory.py` | The bulk asset factory: PixelLab and Retro Diffusion, frozen prompt templates, derived seeds, a body-hash cache, a provenance manifest. |
| `postpass.py` | The mandatory post-pass: grid, palette, alpha, asserts, Phaser 3 atlas. |
| `palette.py` | `extract` / `show` / `check` the palette LUT — the single lock artefact. |
| `factory.mcp.json` | The two vendors as MCP servers, for a repo whose `MCP_CONFIG` points here. |
| `factory-demo.sh` | Generate → post-pass → contact sheet, in one re-runnable command. |
| `templates/` | `bible.md`, `rubric.md`, `proportions.md` — the skeletons a repo copies into its own `.creative/`. |

## Turning it on for a repo

One thing: `.creative/visual.conf.sh` in the repo itself — the contract. What to
serve, which shots, viewport and dpr, the palette LUT (optional), the reference
board (optional), and one threshold per check. **A threshold you do not set is
measured and reported but not enforced**, which is the honest default: the same
off-grid figure means "correct" for a pixel-art tile set and "fine" for an
anti-aliased dashboard. This repo's own `.creative/visual.conf.sh` is the worked
example, and every number in it is annotated with what the shipped wall
measures.

`run-task.sh` loads this profile for any repo carrying `.creative/`, and the
gate below is what it runs. A repo with a gate of its own says so in
`repos.local.sh` instead, which is the other way in:

```sh
VISUAL_GATE_CMD="bash $HARNESS_DIR/profiles/visual/creative/visual-gate.sh"
```

Neither, and the profile never loads: no `visual` field in `result.json`, no
stage, no hook, nothing else changed.

## The factory

**Every asset passes the post-pass; palette and grid are asserted, never
eyeballed; provenance is recorded per asset; and the keys reach the worker
only.** A repo whose `MCP_CONFIG` names this directory's `factory.mcp.json` gets
the PixelLab and Retro Diffusion MCP servers in the implementer's session — and
this profile's `implementer_env` hook sources `$HARNESS_DIR/factory.conf.sh`
(mode 600, the two API keys) into that one process, so no other stage can leak
what it never had.
Bulk work goes through `factory.py`, which freezes one prompt template and one
style block per tool (the coherence rule: two hundred sprites stop looking like
one set the moment a prompt drifts), derives every seed from the asset id,
sends the palette on every request and caches on the request body so a re-run
is free. Then `postpass.py`, always: it re-quantises against the LUT with
`dither=NONE`, binarises alpha at 50 % and zeroes the RGB under transparent
pixels, block-downsamples a true N× upscale — and **refuses to guess a pitch**,
because every home-made detector tried here got it wrong on real art, so an
off-grid sprite goes to Retro Diffusion's free Pixel Fixer or fails with a
reason. What survives is packed into a Phaser 3 JSON-hash atlas. Nothing that
skipped the post-pass is an asset; it is just a picture a model made.

## The loop, by hand

Run from the repo being judged; `$P` is `profiles/visual/creative` in this
checkout, `$HARNESS_DIR/profiles/visual/creative` in an install.

```sh
# 1. render the reigning look and crown it
VISUAL_WORLD=dom VISUAL_CRITIC=0 bash "$P/visual-gate.sh"
"$P/champion.sh" promote dispatch-harness .harness

# 2. render the challenger and let the critic compare them
VISUAL_WORLD=canvas bash "$P/visual-gate.sh"
"$P/champion.sh" show dispatch-harness
```

`VISUAL_CRITIC=0` re-renders for free while you calibrate thresholds; the
pipeline never sets it, so a real run always pays for the opinion (~$0.25–0.70
and 90–170 s **per call**, and a round with a champion makes two of them —
most of it the CLI's own cached system prompt).

## Calibration — why the critic is asked twice

The first thing we did after shipping the critic was measure it, and the signal
the gate acts on failed twice:

- **Status-quo bias.** With the DOM wall as champion and a chaotic canvas
  render as challenger, it said `worse` — correct. With the *same two sheets
  swapped*, the chaotic render presented as the champion, it said `worse`
  again. The old prompt told it which image was "the reigning champion, the
  best render of this project so far", which is an invitation to defer to it.
- **Repeat noise.** The same challenger against the same champion, run twice
  with identical inputs, came back `worse`/`fail` once and `better`/`pass`
  once.
- The absolute axes *did* separate those renders where pairwise did not: the
  rejected one averaged **1.8**, the DOM wall **3.2**, both in the same
  position. That gap is what the tiebreak below is scaled against.

So the protocol changed, and the rule is now:

1. Two sheets, called **A** and **B**, with nothing in the prompt — or in the
   file names, which are laundered into `image-a.png` / `image-b.png` in a
   scratch dir — saying which is which. Both are graded on the rubric; the
   critic states which it prefers.
2. The same pair is asked **again with A and B swapped**, in a second fresh
   session. Each answer is un-mapped back onto the challenger.
3. **Concordant** (both orders say the same thing) ⇒ that is the verdict.
4. **Discordant** ⇒ the axes break the tie, as a *margin*: mean of the
   challenger's six axes over both runs minus the champion's. `≥ +0.5` is
   `better`, `≤ −0.5` is `worse`, anything between is a **`tie`**. Never a
   threshold on an absolute score — only the difference between two sheets
   graded side by side, which is the one absolute number this protocol has
   earned.
5. A second call that produces no verdict is a **failed critic**, not a quiet
   fall back to the one order we know is biased.

And that answer is the only one the gate acts on. **With a champion, pairwise
decides: `worse` fails the round, `tie` and `better` do not. With no champion,
the deterministic checks decide alone. Either way the absolute verdict is
recorded, in `visual-score.json`'s `advisory` list, and fails nothing.** It has
to be that way round, because the bar must be one the reigning look itself
clears: the shipped DOM wall — the very city `.creative/refs/` is stills of —
fails its own absolute verdict on `animation_continuity` ("the beacon does not
sweep, it alternates", of a 4.4 s CSS sweep sampled ~2 s apart), so a gate that
enforced it would reject the champion, give no repo a first green round, and
only ever fail challengers. Same rule `.creative/visual.conf.sh` states about
its thresholds.

Everything is in `visual-critic.json`'s `calibration` object (and copied into
`visual-score.json` as `critic_calibration`): both runs in full, which rule
fired, the two axis means and the delta.

| Env var | What it does | Default |
| --- | --- | --- |
| `CRITIC_ORDERS` | Presentation orders per round. `1` is the old single-order behaviour: half the money, none of the concordance guarantee. | `2` |
| `CRITIC_TIEBREAK_MARGIN` | Axes-mean margin that breaks a disagreement. | `0.5` |

**Your rubric is pasted verbatim into a blind call.** So a rubric describes the
target look and never the images being compared: "the champion", "the current
render", "the new one" in a rubric hand back exactly the bias the swap removes.

### Measuring it: `critic-eval.sh`

```sh
VISUAL_LIVE=1 "$P/critic-eval.sh" --repeats 2            # ~$0.5–1.5 per pair-repeat
```

`eval/pairs.json` holds pairs of contact sheets whose ranking a human
already settled; the runner puts each through the real critic N times and
prints, per run, what it answered, whether the two orders agreed and whether the
margin was used — then three numbers: **accuracy** against the human ranking,
**order-concordance**, and **repeat-agreement**. It exits non-zero when a pair a
human judged outright (`expect` of `better` or `worse`) comes out wrong; a pair
expected to `tie` is reported, never failed. `summary.json` lands beside the
verdicts.

The bundled pair set is dispatch-harness's own calibration fixture: its rubric
and reference-board paths resolve from this source checkout. From an installed
profile, pass `--pairs` for the target repo's eval set instead; that set should
name the same rubric and refs its visual gate uses.

Run it **after any model or prompt change**, and **before trusting a new repo's
rubric** — point `--pairs` at that repo's own set, or add `"rubric"` and
`"refs"` keys to the pairs file (or pass `--refs`). Do not tune the prompt
against the eval set and call the result calibration: a judge fitted to three
pairs is a judge that knows three pairs.

**Measure with the contract the gate uses — the numbers depend on it.** The
first live run of this protocol was made *without* a reference board and with
the generic rubric, and the blind critic, concordant in both orders, preferred
the rejected chaotic canvas render to the DOM wall (`better`, delta +1.17) and
the parity port to the DOM wall (2/2) — the opposite of the human ranking:
raw model taste rewards density and pixel-art texture. Re-run with the wall's
own `.creative/rubric.md` and `.creative/refs/` — what the gate actually hands
the critic — the same judge answered 6/6 with the human: `dom-vs-chaotic`
`worse` in both repeats (delta −1.33 concordant; −0.58 by margin),
`dom-vs-parity` `tie` ×2, `dom-vs-dom` `tie` ×2, order-concordance 3/3,
repeat-agreement 3/3, ≈$1 and 3–7 min per pair-repeat. The verdict is a
function of the contract, not of the model: the bible, rubric and board are the
part that carries the owner's taste, and an eval run without them measures
something the gate never sees.

## What it cannot see

- **CSS motion.** The frozen clock drives `requestAnimationFrame`, so canvas and
  WebGL scenes animate deterministically under it. CSS keyframes run on the
  compositor's own timeline, which no clock API reaches, and
  `animations="disabled"` pins them to their first frame besides. A page whose
  ambience is CSS needs `VISUAL_ANIMATIONS=allow` plus `VISUAL_REAL_WAIT_MS`,
  and trades exactness for it — which is fine, because nothing here compares
  frames for equality.
- **Anything at zero tolerance.** Two identical runs differ by ~0.02 % of
  pixels even with everything frozen. SSIM and RMSE thresholds, never `==`.
- **Its own reviewer.** The Codex reviewer cannot launch Chromium: it dies in
  the sandbox on a Mach-port denial with no setting that reaches it. That is why
  the gate hands the reviewer and fix round pre-rendered PNGs, then performs the
  verification render itself outside the model sandbox.
