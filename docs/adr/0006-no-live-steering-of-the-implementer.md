# 0006. The implementer runs unattended and cannot be steered

- **Status**: Accepted — 2026-08-03

## Context

The obvious feature request for any pipeline like this is a chat box: watch the
implementer work, and nudge it when it goes wrong. Every cockpit product in the
category offers it.

It is the wrong feature for this harness, for a reason that is structural
rather than aesthetic. The brief is the contract. The gate measures the diff
against the repo, the reviewer against the diff, the verifier against the
brief. A mid-run instruction that exists only in a chat window is a change to
the contract that no downstream stage can see, so every claim the pipeline
makes about the finished run silently stops being true. Worse, the operator who
nudges is now the operator who approves — the independence that
[0001](0001-no-model-grades-its-own-homework.md) buys is spent.

There is also a plain mechanical fact: the implementer runs `claude -p` with
stdin closed. There is no channel to steer through.

## Decision

The implementer runs unattended. Live steering is an explicit anti-goal.

The three sanctioned interventions are all outside the run:

- **Answer the brief.** A run that stops with `needs_input` is answered by
  editing the brief and re-dispatching — the contract changes in the one place
  every stage reads.
- **`attach.sh`** steps into the worker's session with its context intact. It
  **forks** rather than joins, and says so: what the operator does there is a
  new session, not an edit to the run.
- **Kill it.** A run that has gone wrong is cheaper to abandon than to rescue.

## Consequences

- `needs_input` has to be a good experience, because it is the only supported
  way for a run to ask a question. `Decision points` in the brief exists to
  make stopping a rule rather than a judgement call.
- No cockpit that offers live steering can be adopted as the team surface
  without breaking this — see [0010](0010-no-third-party-cockpit.md).
- Re-dispatch after a stop currently repeats stages the run had already passed.
  That is a real cost of this decision and the most-requested fix in the
  harness; stage-resumable re-dispatch is the open follow-up.
