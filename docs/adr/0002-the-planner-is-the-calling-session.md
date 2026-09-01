# 0002. The planner is the calling session, not a stage the pipeline pins

- **Status**: Accepted — 2026-07-08

## Context

Every other stage of the pipeline is pinned: a named model, a named effort
level, a named provider. The planning stage — research the repo, write the
brief, decide what the change even is — is the one where a human's judgement is
most load-bearing and most cheaply applied. Pinning it would mean the harness
choosing the model that talks to the operator, and billing it however the
harness decided.

## Decision

The planner is whatever Claude Code session invokes `/dispatch`, billed however
that session is billed. The harness pins only the implementer, the reviewer and
the auxiliary passes. `skills/dispatch/SKILL.md` is a protocol the calling
session follows, not a stage the harness launches.

The one exception is the Quartermaster's overnight self-briefing, which has no
session to borrow: it launches its own confined planner, with a read-only
sandbox, because at 19:00 there is nobody at the desk to be the planner.

## Consequences

- The brief's quality tracks whatever model the operator happens to be running,
  which is the intended coupling: the person choosing the model is the person
  who will approve the brief.
- The harness cannot report a planner cost in `result.json` the way it reports
  implementer and reviewer cost. Planning spend hides in the operator's own
  session, which is precisely where the largest surprise in the 2026-08-30 cost
  diagnosis was found ([0009](0009-context-is-the-cost.md)).
- `/dispatch` has to be written as a protocol for a competent reader rather
  than a prompt tuned against one model. It is longer and more explicit than a
  pinned-stage prompt would need to be.
