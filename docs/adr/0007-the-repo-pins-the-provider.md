# 0007. The repo decides the implementer's provider, not the machine

- **Status**: Accepted — 2026-08-23 (PR #73); extended 2026-08-30 (PR #96)

## Context

Once a second implementer provider existed
([0008](0008-cheap-model-first-gate-escalates.md)), the provider had to be
chosen somewhere. The path of least resistance is the environment: export
`IMPLEMENTER_PROVIDER` in a shell profile and every dispatch from that machine
inherits it.

That is exactly backwards, and it cost two wasted implementer passes to prove
it. A repo's provider is a property of the *code*, not of the laptop that
happens to dispatch it: whether a third-party API may see this source, which
model has been shown to work on this codebase, and whose name ends up on the
diff. A machine-level default silently answers all three questions for repos it
knows nothing about — including, on one occasion, sending a repo through a
provider the operator would not have chosen, invisibly, because the export was
in a shell profile nobody re-reads.

## Decision

The repo pin decides. `repos.local.sh` names the provider for each repo, and it
overrides the environment rather than deferring to it. A dispatch may still be
overridden explicitly at the command line — an intentional, visible act — but
an inherited export must never decide a repo's implementer.

Two rules follow from the same principle:

- The stage label names the **real** implementer. A GLM run does not call
  itself Opus, on the console, on the wall or in the PR (PR #80).
- A repo may hide the fact rather than falsify it: `HARNESS_PROVIDER_PRIVATE`
  omits the provider from the wall and the ticket. The harness will conceal a
  provider; it will never report a different one.

## Consequences

- `repos.local.sh` becomes load-bearing configuration, and a repo that is not
  pinned falls back to auto-detection, which is the case worth auditing when a
  run uses an unexpected model.
- Every stage that displays a provider needs the private-provider branch, which
  is friction on new surfaces — accepted, because the alternative was lying in
  a field the operator uses to decide whether to trust a diff.
- What this does not fix: a provider inherited by something *outside* the
  harness's control. The pin protects dispatches, not every process on the box.
