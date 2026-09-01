# 0013. Infrastructure work on the harness does not go through the harness

- **Status**: Accepted — 2026-08-28

## Context

Dispatching the harness's own improvements through the harness is the obvious
move and it was the default for weeks. Three such dispatches in one day took
six to eight hours each. Only 40-65 minutes of that was the implementer; the
rest was this repo's own gate — around 95 minutes per round, two or three
rounds, serialised behind a repo lock — plus an hour waiting on that lock and a
visual gate the repo triggers because it carries an art-direction contract.

Tracing it found a 20-second fixture run of which 18 seconds was a heartbeat
ticker whose foreground sleep blocked its own termination signal, paid by every
one of ~120 fixture runs across the suites. That fix, plus a parallel
lint-first gate, took the full gate from 95 minutes to under 3.

None of that diagnosis could have been done by a dispatched run, for a plain
reason: **the thing being measured was the harness the run was executing in.**
A run cannot profile its own gate, and it cannot safely edit the scripts that
are executing it — bash reads a script by byte offset, so editing
`run-task.sh` in place while drivers are live corrupts running processes.

There is a second, cheaper reason. Turnaround for harness-internal work through
the pipeline was measured in hours, and iteration is the whole activity.

## Decision

Infrastructure, performance and gate work on the harness itself is done
directly, in a separate git worktree, not dispatched. Feature work on the
harness may still be dispatched; the distinction is whether the change alters
the machinery the run itself is standing on.

Two operational rules come from the same day:

- **Dispatch same-hot-spot briefs in waves, smallest first.** Three parallel
  briefs all editing the same function bought lock waits and three-way
  conflicts.
- **Do not run a validation gate on the machine carrying live runs.** Several
  parallel gates plus reviews took a laptop down under load; validation belongs
  on an idle machine, and `GATE_JOBS` should be reduced when runs are in
  flight.

## Consequences

- The harness gets less dogfooding than it otherwise would. Accepted: the
  dogfooding that matters is dispatching *product* work, and that continues.
- Direct changes to the harness get no cross-vendor review from the pipeline
  itself. They still get the gate, and a review is available on request — but
  this is a real reduction in scrutiny on the most sensitive repo in the set,
  and worth remembering when a harness change goes wrong.
- Open follow-up, still unbuilt: stage-resumable re-dispatch. A run killed
  after review currently repeats gate → review → gate, which is what made
  killing a slow run so expensive in the first place.
