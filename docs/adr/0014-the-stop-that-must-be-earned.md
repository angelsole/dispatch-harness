# 0014. An implementer session may not end with zero commits

- **Status**: Accepted — 2026-08-31

## Context

The most expensive silent failure the pipeline had: an implementer does the
whole task — edits, notes, staging — and then ends its session *narrating* the
final step ("everything is staged for the two commits") instead of running
`git commit`. Exit 0, no commits, and 30–90 minutes of paid work dies as
`implementer_failed`. First attributed to the cheap model
([0008](0008-cheap-model-first-gate-escalates.md)); the research done the same
day reframed it.

Three findings, from three directions, converged:

- The failure class has a name in the literature — *false success* — and a
  hard negative result: **no LLM judge configuration exceeded AUROC 0.65** at
  detecting it, across five judges and five prompt strategies, while a trivial
  lexical detector reached 0.83–0.95 (arXiv:2606.09863). The check must be
  mechanical, not a model.
- Three independent vendors converged on the same mechanism: Claude Code's
  Stop hook can *refuse the stop* (`decision: block` with a reason the session
  continues on); the Codex CLI implemented the same hook schema; OpenHands
  scores a finished run 0.0 unless the patch is non-empty, and retries.
- The narrating model itself scores at parity with the frontier on
  agentic-coding benchmarks *when run inside this same CLI* — evidence that
  the failure is a scaffold gap, not a weights defect, and therefore fixable
  in the scaffold.

The harness already had the right check — §4c's commit backstop — running at
the wrong time: after the session was dead, when the only thing left to do was
name the failure.

## Decision

`lib/stop-gate.sh`, wired to `Stop` in `worker-settings.json`: when an
implementer session tries to end with zero commits past the base ref, the stop
is refused and the reason tells it exactly what to do. Three rules bound it:

- **Armed only for implementer segments.** `run-task.sh` exports the arming
  variables inside `opus_attempt` and nowhere else; review, refute and fix
  passes share the settings file but never see the gate.
- **A sanctioned stop always passes**: a question on file
  (`.harness/QUESTIONS.md`) or a reasoned rejection (`.harness/REJECTED.md`)
  is a legitimate zero-commit ending, and remains the escape hatch the block
  reason itself offers.
- **Nudge, nudge, release.** Blocks are capped (`HARNESS_STOP_GATE_MAX`,
  default 2). Past the cap the session may end and the run is ruled honestly —
  the gate exists to rescue the run that merely forgot, not to trap the one
  that is truly stuck. And any uncertainty — missing worktree, unresolvable
  ref, a git error — allows the stop: the hook must never be the reason a run
  hangs.

## Consequences

- The cheapest class of `implementer_failed` should now end in a commit
  instead: the model gets the one instruction it needed, in-session, while its
  context is still alive. Whether the rescue rate justifies the two extra
  turns is measurable — `stop-gate.blocks` in the run dir counts every nudge.
- A model that narrates *and then commits garbage when told to* is a new
  possible behaviour. The gate, the reviewer and the refutation pass sit
  downstream exactly as before; nothing here weakens them.
- The check is commits-since-base, not commits-since-segment, so a resumed run
  whose earlier segment committed can still end a later segment by narrating.
  Accepted for now: the zero-commit run was the expensive case.
- This is the pipeline's first *blocking* hook. The precedent it sets is
  deliberate and narrow: a hook may refuse a model's action only on a fact git
  can state — never on a judgement.
