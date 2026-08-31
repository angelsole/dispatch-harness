# 0001. No model grades its own homework

- **Status**: Accepted — 2026-07-24

## Context

The pipeline's whole claim is that a change can go from a ticket to a draft PR
without a human watching the middle. That claim rests entirely on what checks
the diff. The obvious cheap design — let the implementer review its own work in
a second pass — was tried informally and produces exactly what you would
expect: a model that has just argued itself into an approach is the worst
possible auditor of that approach. It agrees with itself, it repeats its own
misreadings of the repo, and its blind spots are the same blind spots, because
they came from the same training.

At the time the harness was one operator with a Claude subscription and a
ChatGPT subscription already paid for. The second vendor was therefore free at
the margin.

## Decision

The agent that writes the code is never the agent that reviews it, and the two
come from different vendors. The implementer runs on Anthropic models; the
review stage runs on OpenAI models through the `codex` CLI. Between them sits a
deterministic gate that neither can talk its way past — see
[0003](0003-every-arm-reviews-or-holds.md).

Where a second vendor is genuinely unavailable, the review runs as a fresh
Claude session on a cold read of the diff, and the run is recorded as
`claude_only`. It is never dressed up as a cross-vendor review.

## Consequences

- Two subscriptions are effectively a hard requirement for the full pipeline.
  The harness works without the second one but says so, in the run record and
  in the PR body.
- The review stage cannot share context with the implementer. It reads the diff
  cold, which is slower and occasionally makes it ask a question the
  implementer already answered — accepted as the price of independence.
- Vendor coupling is now structural: a stage is defined partly by *whose* model
  runs it. [0007](0007-the-repo-pins-the-provider.md) and
  [0008](0008-cheap-model-first-gate-escalates.md) both had to be written
  around this constraint rather than through it.
- What would make this wrong: evidence that same-vendor review with a fresh
  context decorrelates errors as well as cross-vendor review does. Nobody has
  measured that here. The `claude_only` runs in the metrics are the natural
  A-side of that experiment if it is ever worth running.
- *Evidence note, 2026-08-31:* the literature bounds how much this decision
  buys. Kim et al. (ICML 2025, arXiv:2506.07962, 350+ models) find frontier
  models agree ~60% of the time when both err, *even across vendors*; a
  companion study (arXiv:2605.29800) puts nine judges from seven families at
  roughly two effective votes. Cross-vendor still beats same-session — but
  never add a further vendor for more votes, and never present two stages'
  agreement as independent confirmation. Related mechanism: the refutation
  pass may draw most of its power from role relabeling rather than the vendor
  change — see the evidence note in
  [0004](0004-findings-must-survive-refutation.md).
