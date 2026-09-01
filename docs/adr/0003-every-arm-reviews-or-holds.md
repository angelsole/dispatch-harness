# 0003. Every arm reviews or holds

- **Status**: Accepted — 2026-08-08 (PR #27)

## Context

By early August the pipeline had grown enough branches — reviewer missing,
reviewer authentication dead mid-run, review process killed, gate green on the
first round, a second gate skipped as redundant — that the interesting question
stopped being "does the review work" and became "how many ways can a run reach
a PR without anything having read the diff". Auditing the paths found several.
Each was individually defensible and collectively they hollowed out the
guarantee the whole harness is sold on.

A pipeline that *usually* reviews is worth much less than one that either
reviews or refuses, because the operator cannot tell the two cases apart at the
moment they matter: when a green PR is sitting there asking to be merged.

## Decision

Every arm of the pipeline either reviews the diff or holds it. Concretely:

- No path opens a PR on a diff that nothing read.
- A review that fell back to a same-vendor cold read is recorded as
  `claude_only` and reported as such, in `result.json` and in the PR body.
- A run that could get no review at all ends `review_failed` with
  `review: failed_silent`, and **pushes nothing**.
- The gate is deterministic and runs on both sides of the review stage; when
  the second gate is skipped, the run record says why.
- The pipeline never marks a PR ready and never merges.

The failure names are part of the contract: `gate_failed`, `review_failed`,
`capacity_failed` each name their stage rather than collapsing into "error".

## Consequences

- Some runs now fail loudly that previously produced a PR. That is the point,
  and it was the single largest source of new red in the metrics when it
  shipped.
- Every new arm added to the pipeline since has had to answer this question
  before it merges, which is a real tax on new stages — the visual profile and
  the escalation router both paid it.
- `tests/review-truth.test.sh` and `tests/gate-integrity.test.sh` exist to keep
  this honest, and they are the suites most likely to break when the pipeline
  is restructured. Breaking them is a signal, not an inconvenience.
