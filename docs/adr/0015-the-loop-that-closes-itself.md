# 0015. Past runs teach the next one, and no model does the teaching

- **Status**: Accepted — 2026-09-01

## Context

The pipeline has always produced exactly two honest signals about whether a run
was any good, and it read back neither.

The first is `promoted.json`: the review findings that survived
[refutation](0004-findings-must-survive-refutation.md). A reviewer from a
different vendor claimed a defect, a second session that had not seen the diff
failed to disprove it, and the fix pass committed for it. Nothing else the
harness produces is that well attested — it is not a reviewer's opinion, it is
a mistake an implementer made and the pipeline caught, on a specific file, in a
specific repo.

The second is `outcome.json`, which the janitor has been writing since it
learned to poll: what the world then did with the PR — merged, reverted, how
many humans had to comment, how many commits landed on those files afterwards.
[ADR 0005](0005-the-verifier-is-advisory.md) called the verifier "any measure of
whether a finished run was good"; the outcome is the only *ground truth* the
pipeline ever gets, and its sole consumer was a table in `metrics.sh --report`
that a human had to remember to run.

So the harness kept re-learning the same repo. Two runs a week apart wrote the
same defect in the same file, each caught by its own review at the cost of a
round, and neither the planner writing the second brief nor the implementer
executing it had any way to know the first had happened.

The tempting design was to have a model read the corpus and write the lessons.
It fails twice. A daily pass that needs a vendor, a key and a quota is a loop
that stops the first week the key expires — the same reason
[0014](0014-the-stop-that-must-be-earned.md) refused a judge for a check a
lexical test could make. And a paraphrase of a finding is one more artefact that
can be confidently wrong, in a file whose whole value is that it is attested.

## Decision

`lib/lessons.sh` distils both signals into one short file per repo, and
**findings supply the text while outcomes supply the weight.** The entries are
the reviewer's own words, verbatim; what the world charged for that PR only
decides where they rank. Nothing here calls a model.

A trap scores one point per run that hit its file, plus what the world charged
for those PRs: a reverted PR is worth 3, one argued over 1, one patched after
merge 1. Recurrence is the base — the third time a file bites is when it becomes
a rule — and a revert outranking three quiet repeats is the intended order: a PR
that had to be undone is the loudest thing this pipeline can learn about a file.
A run counts once per file however many findings it filed there, so one chatty
review cannot impersonate a recurrence.

Three evictions bound it, because a page nobody reads teaches nothing
([0009](0009-context-is-the-cost.md)): runs older than 60 days, one-run traps
older than 21, and any trap whose file is no longer tracked — which also drops
findings that cited a path the reviewer imagined, since a finding's `file` is
free-form model text nothing upstream validates. Findings the refuter marked
`doubted` never enter: those are the ones it could not confirm.

Two consumers, both **advisory**. The planner reads `lessons.sh --show` during
research and folds anything relevant into the brief in its own words; every
dispatch mounts the file at `.harness/lessons.md` and tells the implementer to
avoid repeating what is in it. Neither may widen a run's scope: a trap is a
place to be careful, never a task, and the brief is still the task.

The reviewer is deliberately **not** given it. Its find pass is the one stage
whose value depends on reading the diff cold, and a list of known traps is an
invitation to hunt for them.

## Consequences

- The harness now has a compounding surface it did not have: every confirmed
  defect makes the next brief in that repo slightly better informed, at the cost
  of no model call and no key.
- It is worthless on a fresh repo and stays worthless until that repo has
  produced confirmed findings. A repo with none has no file at all, so nothing
  is mounted and nothing is said — the fresh-install behaviour is byte-for-byte
  what it was before this existed.
- It inherits the review stage's blind spots wholesale. A defect class the
  reviewer never catches will never appear here, and this file will make it look
  like it does not exist. It is a record of what was *caught*, not of what was
  *written*, and nothing about its ranking should be read as a defect
  distribution.
- The janitor gained a pass, and a dispatch gained a stat plus — at most once
  every 12 hours per repo — one distillation, so an operator who never installed
  the janitor still gets the loop.
- `run-task.sh` now writes `<run>/repo` at setup in git's canonical spelling.
  The janitor already wrote that file for runs with a PR; two spellings of one
  repo would have been two repos to anything keying on the string.
