# 0009. Context is the cost

- **Status**: Accepted — 2026-08-30 (PR #95)

## Context

Subscription usage on the orchestrating account climbed steadily through August
and the intuition in the room was that the pipeline's auxiliary stages — the
spec critic in particular, running the largest model at the highest effort —
were eating it. The intuition was wrong, and the way it was proved wrong is the
part worth keeping.

Aggregating 35 days of session records (deduplicating assistant messages by
message id, bucketing cache-creation tokens by idle gap and by context size)
gave a different picture. Roughly three quarters of the spend on the top model
sat in **orchestrator sessions** — but the cost was the *session*, not the
pipeline: those sessions ran past 600k of context on a 1M-context model, and
nearly two hundred returns after more than an hour idle rewrote the entire
prefix at the cache-write rate. Weekly spend had nearly doubled while cache
writes tripled. The spec critic, the supposed culprit, was about 3%.

The lesson generalises: **in an agentic pipeline the dominant cost is the size
and age of the context you carry, not the cleverness of the stages you run.**

## Decision

- Compact at 300k even on a 1M-context model. The window is a knob
  (`IMPLEMENTER_COMPACT_WINDOW`), not a constant, and non-1M models leave it
  unset rather than inheriting a number meant for something else.
- Reasoning effort defaults to `high`, not the maximum.
- Small, bounded stages run on a small model: the spec critic defaults to
  Sonnet at medium effort, and always passes both `--model` and `--effort`
  explicitly rather than inheriting whatever the ambient session uses.
- Prefer a fresh session for a bounded verdict over continuing a long one.
- **Before changing a pipeline stage in response to a cost complaint, measure
  where the tokens actually are.** The session records are the evidence; the
  stage prompts are the suspect everyone reaches for first.

## Consequences

- A 300k window means some long implementer runs compact where they previously
  would not have. No measured quality regression has been attributed to it, and
  the honest position is that nobody has A/B'd it — the cost evidence was
  overwhelming and the quality evidence is absent. *Corroboration, 2026-08-31:*
  two frontier labs' own model cards (Kimi K3, GLM-5.3) trigger compaction at
  the same 300K in their published agentic-coding evaluations. One caution
  stands: compression can weaken the influence of recent interactions and
  increase repeated exploration (arXiv:2608.06503) — compaction events are
  worth logging next to the stop-gate counter
  ([0014](0014-the-stop-that-must-be-earned.md)) to see whether the two
  correlate.
- The harness's own defaults now diverge from the vendor's, so a Claude Code
  upgrade that changes compaction behaviour is a thing to re-check rather than
  accept.
- The next lever, unpulled: run the implementer itself on a smaller model and
  measure against the verifier score
  ([0005](0005-the-verifier-is-advisory.md)).
