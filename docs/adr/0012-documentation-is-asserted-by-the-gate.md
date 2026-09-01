# 0012. Documentation is asserted by the gate

- **Status**: Accepted — 2026-08-04 (PR #4)

## Context

This repo's documentation is not decoration: the harness is configured through
it, workers are prompted from templates that live in it, and a reader deciding
whether to trust an unattended code-executing pipeline has nothing else to go
on. It also drifts faster than most, because the pipeline that edits the code
is a model reading the same pages.

Three families of drift had already happened here: a hard dependency the
scripts need that the prerequisites never named; the installer's file list
diverging from the files in the repo; and — the one that stings — the front
page promising a script the repo did not ship.

Documentation review by goodwill catches none of these reliably, because they
are all invisible unless you go and check.

## Decision

Documentation is asserted by the same gate that runs the code suites.
`tests/docs.test.sh` treats the pages as claims about shipped reality and
checks them: every backtick-quoted script name resolves to a file that exists;
the installer's list matches the repo; the prerequisites cover what the scripts
actually invoke; the two copies of the pipeline diagram are identical; every
docs page is reachable from the front page; every internal anchor resolves; and
no team-internal identifier has leaked back into a public page.

A documentation claim that cannot be asserted mechanically is still allowed —
but the distinctive ones are pinned by name, so a rewrite that quietly drops a
section fails rather than merges.

## Consequences

- Restructuring the docs means updating the suite, which is friction by design:
  the decision log added in 2026-08 had to extend the reachability rule rather
  than slip past it, and does — an ADR is reachable from the log's index, and
  the index from the front page.
- The suite encodes a particular shape of documentation (a front page plus
  `docs/`), so it constrains future layouts. Judged worth it.
- It cannot check whether a page is *true*, only whether it is consistent with
  the repo. Prose that describes behaviour the code no longer has still passes.
