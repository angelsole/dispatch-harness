# Benchmark experiment: does the multi-model pipeline beat a single agent?

**Status:** design only. This document specifies a runnable protocol; no
adapter code ships in this repo (see [Out of scope](#out-of-scope)). It is the
experiment the README's quality claims should ultimately rest on, so that
"the pipeline beats a single-model baseline" points at a designed, paired
comparison instead of an anecdote.

---

## 1. Hypothesis

> On a fixed set of real GitHub issues, resolving them through the dispatch
> pipeline (implement → deterministic gate → cross-vendor review) resolves
> **more** instances than a single agent given the same model and the same
> issue text — and the cross-vendor **review** stage, not just the gate,
> accounts for a measurable part of that lift.

Primary metric: **% of instances resolved** under the official SWE-bench
evaluation harness (all `FAIL_TO_PASS` tests pass and all `PASS_TO_PASS` tests
still pass on the generated patch).

Primary comparison: **arm B (full pipeline) vs. arm A (single agent)**, analysed
**paired** — the same instances solved by both arms — so each issue is its own
control for difficulty.

---

## 2. Why paired, and why not the public leaderboard

The tempting shortcut is to run one arm and compare its resolve rate to a
published SWE-bench number. Don't. Two different scaffolds, harness versions,
model snapshots, and sampling draws make an unpaired cross-study delta swing by
roughly **±10 percentage points** before any real effect shows through — larger
than the effect we expect to measure.

A paired design removes almost all of that. Both arms run the **same 100
instances** with the **same implementer model**; the only thing that varies is
the scaffold. We then look only at the **discordant pairs** — instances one arm
solved and the other did not — with **McNemar's test**. At n = 100 with a
plausible discordant-pair count, this design can detect a true difference of
about **5–7 pp**. That is the whole reason to pay for running every instance
multiple times instead of comparing to a leaderboard row.

**Leaderboard submission is explicitly a non-goal.** We are measuring a
*within-harness delta between scaffolds*, not chasing an absolute number or a
ranking. Submitting would demand full leaderboard hygiene (no contamination
controls we can vouch for, exact-image reproduction, a frozen public patch set)
that is irrelevant to the paired question and would distract from it. We report
our own paired delta with its confidence interval and stop there.

---

## 3. Dataset and sampling

- **Source:** [SWE-bench **Verified**](https://www.swebench.com/) — the
  500-instance human-validated subset. Verified is used (not full SWE-bench or
  Lite) because its instances have been checked to be well-specified and
  solvable, which keeps the paired signal about scaffold quality rather than
  about broken or ambiguous tasks.
- **Sample:** a **random 100-instance** subset, drawn once with a **fixed seed**
  and frozen to a checked-in list of instance IDs (`bench/sample-100.txt`) so
  every arm and every re-run uses the identical set. Record the seed and the
  `datasets` revision alongside the results.
- **Rationale for n = 100:** enough discordant pairs for McNemar to resolve a
  ~5–7 pp effect, while keeping total cost and Docker-image build time bounded
  (see [§7](#7-cost-estimate)). Pre-register n; do not grow the sample after
  peeking at results.

---

## 4. Arms

All arms consume the **same instance inputs** (issue text + repo at the
instance's base commit) and produce a patch scored by the **same** evaluation
harness. Only the scaffold between input and patch differs.

| Arm | Scaffold | Review? | In-loop gate? | Purpose |
| --- | --- | --- | --- | --- |
| **A** (control) | Single agent, one pass, no gate loop | no | no | Baseline: model + minimal scaffold |
| **B** (treatment) | Full dispatch pipeline | **yes** (Codex) | yes (repo tests) | The harness as shipped |
| **C** (attribution, optional) | Pipeline with `HARNESS_SKIP_REVIEW=1` | no | yes (repo tests) | Isolates the gate's contribution from the review's |

- **Arm A — plain single-agent scaffold.** The implementer model receives the
  issue text and the repo and is asked to produce a patch in a single agent run
  (the same agent CLI, same tools, same max-turns as the pipeline's implementer
  stage) with **no** deterministic gate loop and **no** second-model review. This
  is the honest "just prompt a good agent" baseline.
- **Arm B — this pipeline.** The exact production flow:
  1. **Issue text → brief.** The instance's `problem_statement` becomes
     `.harness/brief.md`. To avoid a confound, the brief is generated
     **mechanically** (a fixed template wrapping the issue text + acceptance =
     "the repo's test suite passes"), *not* hand-authored per instance and *not*
     by a stronger planner model — otherwise we would be measuring planner
     effort, not the implement/review split.
  2. **Implement** (implementer model) → commit.
  3. **Gate** = the repo's **existing** test suite (see [§5](#5-the-in-loop-gate-is-regression-only)).
  4. **Codex review + fix rounds** (cross-vendor), exactly as in `run-task.sh`.
  5. **Patch** = `git diff <base_commit>..HEAD`, with `.harness/` and any
     non-source scaffolding stripped, submitted as the instance prediction.
- **Arm C — gate-only (no review).** Arm B with the review stage skipped via the
  shipped `HARNESS_SKIP_REVIEW=1` knob. B − C attributes lift to the **review**
  stage; C − A attributes lift to the **gate loop**. Arm C is optional: run it
  only if B beats A, to explain *where* the lift comes from.

**Held constant across all arms** (pre-registered):

- **Implementer model** — identical snapshot in A, B, and C (e.g. one pinned
  Opus build). The experiment is about scaffold, not model choice.
- Model temperature / reasoning effort, max-turns/token ceiling per implement
  pass, tool allow-list, and the per-instance wall-clock cap.
- The evaluation harness version and the Docker image set.
- The instance sample (§3) and the mechanical brief template.

The only reviewer model is Codex (arm B); that cross-vendor split is the
treatment, so it is deliberately *not* held constant between A and B.

---

## 5. The in-loop gate is regression-only

SWE-bench scores each instance on **hidden** `FAIL_TO_PASS` tests (the tests
that encode the fix) plus `PASS_TO_PASS` tests (regressions). Those evaluation
tests are **withheld from the solver** — the whole point of the benchmark. So
the pipeline's in-loop gate in arms B and C **cannot** run them. It runs the
repo's **existing** visible test suite (and any tests the implementer itself
writes).

Consequence: the gate is **regression-oriented**. It can catch a patch that
breaks the repo's existing tests, but it cannot *confirm* the patch fixes the
issue, because the fail-to-pass test is invisible. In a normal dispatch run the
planner writes a failing test into the brief; here we cannot. **This makes the
measured lift conservative** — the pipeline is running with a weaker gate signal
than it has in real use, so any advantage it shows is a lower bound on its
real-world advantage. State this explicitly whenever the result is quoted.

---

## 6. Scoring and analysis

### 6.1 Scoring

Score every arm's predictions with the **official
[`swebench`](https://github.com/SWE-bench/SWE-bench) evaluation harness** (the
`swebench.harness.run_evaluation` runner over the frozen instance set), in the
canonical per-instance Docker images. An instance is **resolved** iff the
harness reports all `FAIL_TO_PASS` and `PASS_TO_PASS` tests passing. Output per
arm: a boolean resolved/unresolved vector over the 100 instance IDs. Archive the
raw harness run logs.

### 6.2 Paired statistics (McNemar)

For the primary A-vs-B comparison, build the 2×2 discordant table:

|                | B resolved | B unresolved |
| -------------- | ---------- | ------------ |
| **A resolved** | a          | b            |
| **A unresolved** | c        | d            |

- `b` = A solved, B did not; `c` = B solved, A did not.
- Concordant cells `a` and `d` carry no information about the difference.
- **McNemar's test** on `(b, c)` gives the p-value. Use the **exact binomial**
  version (binomial test of `c` successes in `b + c` trials at p = 0.5) rather
  than the χ² approximation, because the discordant count is small at n = 100.
- Report the paired difference `(c − b) / 100` in points, a **95% CI** for the
  paired proportion (e.g. Wilson/exact on the discordant split), and the exact
  p-value. The headline is the CI, not just "significant / not".

Repeat the same paired procedure for **B vs C** (isolating review) and **C vs A**
(isolating the gate) only as secondary, clearly-labelled analyses.

### 6.3 Power / detectable effect

At n = 100, McNemar's sensitivity is driven by the number of **discordant**
pairs, not n directly. With a realistic discordant fraction, this design
resolves a true effect on the order of **5–7 pp** at α = 0.05 with ~80% power.
That is the ceiling of what n = 100 buys; a smaller true effect needs a larger
paired sample. Pre-register the target effect and do not re-sample to chase
significance.

### 6.4 Confounds to log per instance

Alongside resolved/unresolved, record for each instance and arm: implementer
`num_turns` and token `usage`, gate round outcomes, patch size (files / ± lines),
and wall-clock — the same fields `metrics.sh` already tabulates for live runs.
Non-resolution has failure modes worth separating: empty patch, patch that
breaks `PASS_TO_PASS`, gate never went green, run hit the wall-clock cap, or
harness/image error. Tag each unresolved instance with its mode.

---

## 7. Cost estimate

Two ways to pay for the implement + review token volume:

- **Metered API (Opus pricing, with prompt caching).** A single implement pass
  over one instance (repo context + iterative edits) plus, in arm B, a review
  pass lands on the order of **$3–6 per instance per arm** with caching on the
  large, reused repo/context prefix (caching is what keeps repeated reads of the
  same repo from dominating the bill). Rough envelope:
  - Arm A: ~$3–5 / instance × 100 ≈ **$300–500**.
  - Arm B: implement + review ≈ **$5–8 / instance** × 100 ≈ **$500–800**.
  - Arm C: between A and B.
  - **Full A + B + C run: ≈ $1.1k–1.8k** in tokens, plus re-runs.
- **Subscription-paced.** Run the implementer on a Claude subscription and the
  reviewer on a ChatGPT subscription — the same economics the harness uses in
  production. Token cost is then ~$0, traded for **rate-limit-paced wall-clock**
  (a 100-instance × 3-arm sweep spread over days). Best for a first pass; switch
  to metered API only if you need the sweep to finish on a deadline.

Non-token costs: building/pulling 100 per-instance Docker images (tens of GB,
hours of first-run build) and the evaluation compute. Budget disk and time for
images separately from tokens.

---

## 8. Threats to validity / honest caveats

1. **Regression-only gate (conservative bias).** As in [§5](#5-the-in-loop-gate-is-regression-only):
   the in-loop gate can't see the fail-to-pass tests, so the pipeline runs
   weaker here than in real use. The measured lift is a **lower bound**.
2. **macOS-local harness vs. per-instance Linux Docker images.** `run-task.sh`
   is a macOS-local harness (worktrees, `perl` alarm timeouts, `osascript`
   notifications); SWE-bench evaluation runs each instance in a pinned **Linux
   Docker image**. The main adapter work is getting the **`claude` and `codex`
   CLIs plus their auth** to run *inside* (or driving) those containers, and
   reconciling the worktree/branch mechanics with an ephemeral per-instance
   checkout. This is deliberately left as adapter work, not shipped here.
3. **Mechanical brief vs. planner brief.** We generate the brief mechanically to
   avoid smuggling planner effort into the treatment. This *understates* the
   real pipeline, which normally gets a researched brief with a failing test.
   The experiment therefore measures the implement/gate/review machinery, not
   the planner.
4. **Contamination.** SWE-bench Verified instances predate current model
   cutoffs and may be partially memorised. Because the design is **paired and
   within-model**, contamination inflates *both* A and B roughly equally and
   largely cancels in the A−B delta — but it caps the absolute numbers, so do
   not read arm A's rate as a general single-agent capability figure.
5. **Reviewer non-determinism.** Codex fixes are stochastic; a single run is one
   sample. If budget allows, run arm B (and C) **twice** and report the pair of
   deltas, or at minimum flag that the review arm carries run-to-run variance
   the single-pass arm A does not.
6. **Multiple comparisons.** A-vs-B is primary. B-vs-C and C-vs-A are secondary;
   treat their p-values as descriptive (or apply a correction) rather than as
   independent confirmatory tests.

---

## 9. Runnable protocol (procedure)

1. **Freeze the sample.** Draw 100 instance IDs from SWE-bench Verified with a
   fixed seed → `bench/sample-100.txt`. Record seed + `datasets` revision.
2. **Pin the config.** Choose and pin: implementer model snapshot, temperature /
   effort, max-turns, per-instance wall-clock cap, `swebench` harness version,
   image set. Record all of it in a run manifest.
3. **Build the mechanical brief** per instance from `problem_statement` via the
   fixed template (issue text + "acceptance = repo test suite passes").
4. **Run arm A** (single agent) over all 100 → collect patches.
5. **Run arm B** (full pipeline) over all 100 → collect `git diff` patches.
6. **Run arm C** (`HARNESS_SKIP_REVIEW=1`) over all 100 → collect patches
   *(optional; only if B > A)*.
7. **Score** each arm with the official `swebench` harness in Docker → per-arm
   resolved/unresolved vectors + logs.
8. **Analyse** paired: McNemar (exact) for A-vs-B, with CI and effect size;
   secondary B-vs-C and C-vs-A. Tabulate per-instance confounds (§6.4).
9. **Report** the paired delta with its CI and every caveat in §8. Do **not**
   submit to the leaderboard.

---

## Out of scope

- Any SWE-bench **adapter implementation** — this file is a design. The
  container/CLI-auth adapter (caveat §8.2) is the main build task and is not in
  this repo.
- Leaderboard submission and absolute-number chasing (§2).
- Changing the production pipeline to fit the benchmark. The knobs the
  experiment needs (`IMPLEMENTER_MODEL`, `HARNESS_SKIP_REVIEW`) already exist;
  the benchmark adapts to them, not the reverse.
