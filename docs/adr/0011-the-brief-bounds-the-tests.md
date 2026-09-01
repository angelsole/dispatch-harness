# 0011. The brief names the tests, and bounds them

- **Status**: Accepted — 2026-08-31

## Context

Told to implement a change, a current model writes tests. Told nothing about
tests, it writes many: unit tests for the function it touched, integration
tests for the module around it, fixtures for behaviour nobody asked about, and
occasionally a whole test framework the repo did not have. The change itself
ends up buried in a diff several times the size it needed to be — which lands
on the two stages least able to absorb it. The reviewer reads a diff mostly
composed of test scaffolding and spends its attention there; the human
approving the PR does the same.

The failure mode is not that the tests are bad. It is that their volume is
unrelated to the size of the change, so the diff stops being a readable
description of what happened.

Telling an implementer "don't add tests" does not work either — it adds some
anyway — but the middle position does: name the cases, and the model writes
those.

## Decision

The brief carries a `## Tests` section that names the tests the change actually
needs and where they go. Like the other load-bearing sections, it makes an
honest empty answer legal and spells it: `none — the existing suite already
covers this`. It forbids introducing a test framework the repo does not have;
a change that needs one is a decision point, not a test.

`tests/brief-contract.test.sh` asserts the section and its framing, on the same
principle as the sections that came before it: a heading a stage greps for is
part of the contract, and a silent rename is a loud failure here.

## Consequences

- One more section for the planner to fill on every brief, and one more thing
  to get wrong by under-specifying. Mitigated by the empty value being both
  legal and common.
- The gate is unaffected: it still runs the repo's full suite, so a brief that
  under-asks for tests does not weaken the checkpoint — it only keeps the diff
  proportionate.
- Not addressed here: whether the tests an implementer writes are any *good*.
  Volume and quality are separate problems, and this decision only bounds
  volume.
