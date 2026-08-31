# 0005. The verifier scores and never gates

- **Status**: Accepted — 2026-08-18 (PR #53)

## Context

The pipeline had two kinds of judgement — a deterministic gate that is always
right about what it measures and blind to everything else, and a reviewer that
sees everything and is sometimes confidently wrong. Missing was any measure of
whether a finished run was *good*: whether the change answered the brief,
whether the implementer flailed, whether the diff is the size the task
deserved.

The obvious source is the run's own trajectory, which the harness already keeps
in full (the implementer's stream, every attempt, the brief's acceptance
criteria as a ready-made rubric). An exploration of trajectory-scoring
techniques found one hard constraint: the technique considered needed token
logprobs, which Anthropic's API does not expose. That decided the vendor before
anything else did.

The tempting design was to let a bad score fail the run.

## Decision

A third vendor scores the finished trajectory against a fixed five-item rubric,
with every answer quoting the line that decides it. The score lands in
`result.json`, on the wall, in the PR body and in `metrics.sh`.

**It is advisory. It never gates, and it never blocks a push.** It is
best-effort: no key, no library, no network, or a failed call all leave the run
otherwise untouched.

## Consequences

- Three vendors are now in the pipeline, and the verifier is the only one
  requiring a cloud key rather than a subscription — which is why
  `install.sh --verifier` exists and why the verifier is the most commonly
  unconfigured stage.
- Because it never gates, a wrong verifier score costs nothing but a wrong
  number in a table. That is what makes it safe to run an unvalidated judge at
  all, and it should stay that way until someone has measured the score against
  human judgement on a real corpus of runs.
- The score's real use is longitudinal: comparing pipeline configurations
  against each other over many runs, not adjudicating any single run.
- A known bias, already corrected once: the verifier scored generated churn as
  if the implementer had authored it. Scoring a trajectory means constantly
  re-checking *what* is being scored.
