# 0004. A finding is fixed only if a fresh session cannot refute it

- **Status**: Accepted — 2026-08-22 (PR #65), tightened 2026-08-25 (PR #84, #86)

## Context

Ask a model to review a diff and it will find something. Ask it to find the
biggest problems and it will find exactly as many as you implied, on a diff
that is fine. The harness saw this constantly: reviewer findings that described
behaviour the repo does not have, invariants it does not hold, and callers that
do not exist. Acting on those is worse than ignoring them — the reviewer stage
has write access, so an invented finding becomes a real, unrequested change to
the diff, and it arrives with the authority of "the reviewer said so".

The naive fix — tell the reviewer to be more careful — does not work, because
the reviewer is confident in exactly the cases where it is wrong.

## Decision

Finding and fixing are separated by a refutation pass:

1. The reviewer produces `findings.json` and fixes nothing.
2. A **fresh session**, with no memory of the review, attempts to refute each
   finding.
3. A refutation is only accepted if it **cites repository code, and the harness
   verifies that citation byte-for-byte** against the file it names. An
   uncheckable refutation is not a refutation.
4. Only findings that survive get fixed.

An empty findings list is a legitimate and common outcome, and is stated as
such in the prompts for both this stage and the spec critic: *an honest empty
list is the answer far more often than not*.

## Consequences

- The review stage costs roughly twice what a single pass costs. Measured
  against the alternative — a fix round on an invented finding, plus the human
  time to notice — this is cheap.
- "Show me" is now enforceable in a way "trust me" never was, and the same
  citation-checking machinery was reused for the spec critic's
  `conflicts_with_current_behavior` entries.
- The evidence rules have their own page,
  [Trust me, said the reviewer](../verified-grounding.md), because they are the
  part of the pipeline most often mistaken for ceremony.
- This decision generalises: **any stage that both judges and edits must have
  the judging and the editing done by different contexts.** New stages should
  be read against that rule.
- *Evidence note, 2026-08-31:* the working assumption behind this split —
  roughly one finding in two is wrong — is now measured at field scale:
  56.3% of 31,073 real agentic-review comments were rejected by developers
  (arXiv:2607.03316), and a production benchmark over ~300k PRs puts reviewer
  precision near 49%. The finding-**survival rate** (raised ÷ surviving
  refutation) is this stage's own health metric: ~50% reproduces the field
  number, ~90% means the refutation is rubber-stamping. One open mechanism
  question: role relabeling — presenting a claim as external input rather
  than the model's own reasoning — raises explicit correction by 23–93pp in
  10 of 12 tested settings (arXiv:2606.05976), which suggests the fresh
  session, not the second vendor, may be the active ingredient. A same-vendor
  refutation A/B on archived findings would settle it cheaply.
