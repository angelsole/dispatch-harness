# 0008. The cheap implementer goes first, and the gate decides the escalation

- **Status**: Accepted — 2026-08-23 (PR #60, #71); amended 2026-08-31, corrected the same day

## Context

The implementer is the most expensive stage in the pipeline, and a large share
of dispatched tickets are not hard: a well-researched brief with named edit
locations and an interface contract does most of the thinking. Paying the top
model for all of them is waste — but choosing per ticket, by hand, at dispatch
time is both a chore and a guess, and the guess is made before anyone knows how
the ticket will actually behave.

There was already an oracle in the pipeline that knows nothing about model
marketing: the gate.

## Decision

A cheap implementer (GLM-5.3, via a third-party API) attempts the ticket first.
The **gate** decides whether that attempt stands. On failure the run escalates
to the strong implementer (Opus) rather than retrying the cheap one, and the
escalation is recorded in `result.json` so the cheap-first policy can be
measured rather than believed.

The router is a policy over a deterministic signal, never a judgement about the
ticket's difficulty made in advance.

## Amendment, 2026-08-31

Two limits found in practice, both now part of the decision:

- **Provenance beats price.** Repos where the diff's authorship matters — work
  that will be attributed to a person or a company, or code that must not reach
  a third-party API — pin the strong provider outright
  ([0007](0007-the-repo-pins-the-provider.md)). The harness does not
  misrepresent which model wrote a diff, so the only honest way to have Opus on
  the PR is to actually run Opus.
- **A cheap model's failures are not always loud.** The observed failure mode
  is a run that does the whole task — edits, notes, staging — and then ends its
  session *narrating* the last step ("everything is staged for the two
  commits") instead of running `git commit`. Exit 0, no commits,
  `implementer_failed`. It is not a gate failure, so the escalation router
  never sees it.

  *Corrected, later the same day:* this was first read as a model defect, with
  "resume on the strong model" as the remedy. The evidence points the other
  way — the same model scores at parity with the frontier on agentic-coding
  benchmarks when run inside this same CLI, so the failure is a **scaffold
  gap**, and the scaffold now closes it:
  [0014](0014-the-stop-that-must-be-earned.md) refuses the zero-commit stop
  in-session, for every provider. Resuming on Opus remains the fallback for a
  run that exhausts the gate's nudges, not the first response.

## Consequences

- The escalation path doubles the wall-clock cost of a ticket the cheap model
  cannot do. The bet is that the saved runs outnumber the doubled ones, and
  `metrics.sh` is where that bet is settled — it has not yet been settled with
  enough runs to be conclusive.
- Two implementer providers means two sets of quirks in every stage that reads
  an implementer's output. The gate is provider-agnostic; the failure taxonomy
  is not, and this amendment is the first entry in it.
