# Decision log

Some of this pipeline can be read off the code. Why it is shaped that way
cannot. This log is where a decision goes when the alternative was reasonable,
the choice cost something, and a later reader — human or model — would
otherwise re-litigate it from scratch.

One file per decision, `NNNN-slug.md`, numbered in the order taken and never
renumbered. Each carries a status, the date it was taken, the state of the
project at the time, the decision itself, and what it costs. A decision that
stops being true is not deleted: it is marked **Superseded** and the ADR that
replaced it is named, because the reasoning that was abandoned is half the
value of the record.

This is not a place for how things work — that is
[Design notes](../design-notes.md), [Reference](../reference.md) and
[Operations](../operations.md), which describe the harness as it stands today.
An ADR is dated and does not get quietly rewritten when the code moves.

## The log

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-no-model-grades-its-own-homework.md) | No model grades its own homework: the implementer and the reviewer are different vendors | Accepted, 2026-07-24 |
| [0002](0002-the-planner-is-the-calling-session.md) | The planner is whatever session calls `/dispatch`, not a stage the pipeline pins | Accepted, 2026-07-08 |
| [0003](0003-every-arm-reviews-or-holds.md) | Every arm reviews or holds: no path opens a PR on a diff nothing read | Accepted, 2026-08-08 |
| [0004](0004-findings-must-survive-refutation.md) | A finding is fixed only after a fresh session fails to refute it with checked evidence | Accepted, 2026-08-25 |
| [0005](0005-the-verifier-is-advisory.md) | The verifier scores and never gates, and it is a third vendor | Accepted, 2026-08-18 |
| [0006](0006-no-live-steering-of-the-implementer.md) | The implementer runs unattended and unsteerable; `attach.sh` forks, it does not join | Accepted, 2026-08-03 |
| [0007](0007-the-repo-pins-the-provider.md) | The repo decides the implementer's provider, not the machine that dispatches | Accepted, 2026-08-23 |
| [0008](0008-cheap-model-first-gate-escalates.md) | The cheap implementer goes first and the gate — not a human — decides the escalation | Accepted, 2026-08-23; amended 2026-08-31 |
| [0009](0009-context-is-the-cost.md) | Context is the cost: compact at 300k even on a 1M model, and put the small stages on a small model | Accepted, 2026-08-30 |
| [0010](0010-no-third-party-cockpit.md) | No third-party cockpit: the team surface is the tracker, the wall and the PR | Accepted, 2026-08-28 |
| [0011](0011-the-brief-bounds-the-tests.md) | The brief names the tests; an implementer left to itself writes a suite | Accepted, 2026-08-31 |
| [0012](0012-documentation-is-asserted-by-the-gate.md) | Documentation is asserted by the gate, not reviewed by goodwill | Accepted, 2026-08-04 |
| [0013](0013-the-harness-does-not-build-itself.md) | Infrastructure work on the harness does not go through the harness | Accepted, 2026-08-28 |
| [0014](0014-the-stop-that-must-be-earned.md) | An implementer session may not end with zero commits: the Stop hook refuses it | Accepted, 2026-08-31 |

## Writing one

Copy the shape of any existing entry: a title that states the decision as a
claim, `Status` and the date, then **Context** (what was true when it was
taken, including the numbers if numbers decided it), **Decision** (what is now
true, in the imperative), and **Consequences** (what it costs, what it forbids,
and what would make it wrong). Keep it to a page. If the reasoning fits in a
code comment, it belongs in the code comment.

Two rules the gate enforces, in `tests/docs.test.sh`: every ADR is linked from
the table above, and no ADR names a script that does not ship.
