#!/usr/bin/env bash
# Claude Code Stop hook: an implementer session may not end with zero commits.
#
# The failure this closes is real and expensive: an implementer does the whole
# task — edits, notes, staging — and then ends its session NARRATING the last
# step ("everything is staged for the two commits") instead of running
# git commit. Exit 0, no commits, and the run dies as implementer_failed after
# 30-90 minutes of paid work. An LLM check for this is measurably weak (judges
# top out near chance on trajectories that close confidently); a git query is
# exact. So the harness refuses the stop: Claude Code reads this hook's stdout,
# and {"decision":"block","reason":...} sends the session back to work with the
# reason as its instruction. See docs/adr/0014-the-stop-that-must-be-earned.md.
#
# Armed only for implementer segments: run-task.sh exports HARNESS_STOP_GATE=on
# (plus the worktree, the base ref and a state file) into the worker's
# environment, and nothing else does. A reviewer pass, a refute pass, or an
# operator's interactive session never sees the gate. Two stops are legitimate
# even with no commits and are always allowed through: a question for the
# orchestrator (.harness/QUESTIONS.md) and a written rejection of the task
# (.harness/REJECTED.md).
#
# Blocks are capped (HARNESS_STOP_GATE_MAX, default 2, counted in the state
# file) so a worker that cannot or will not commit is nudged, nudged again, and
# then released to die honestly as implementer_failed — the gate exists to
# rescue the run that merely forgot, not to trap the one that is truly stuck.
# Every uncertain path allows the stop: this hook must never be the reason a
# run hangs or a healthy session cannot end.
set -u

# Not an armed implementer session: leave without reading anything.
[ "${HARNESS_STOP_GATE:-}" = on ] || exit 0
WT="${HARNESS_STOP_GATE_WORKTREE:-}"
BASE="${HARNESS_STOP_GATE_BASE:-}"
[ -n "$WT" ] && [ -n "$BASE" ] && [ -d "$WT" ] || exit 0

# A stop the protocol sanctions: questions or a rejection on file.
[ ! -s "$WT/.harness/QUESTIONS.md" ] || exit 0
[ ! -s "$WT/.harness/REJECTED.md" ] || exit 0

# The one fact that matters. Any git failure allows the stop — the gate judges
# commits, it does not diagnose repositories.
commits=$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null) || exit 0
case "$commits" in ''|*[!0-9]*) exit 0 ;; esac
[ "$commits" -eq 0 ] || exit 0

# Nudge budget: past the cap, let the run end and be ruled honestly.
STATE="${HARNESS_STOP_GATE_STATE:-}"
max="${HARNESS_STOP_GATE_MAX:-2}"
case "$max" in ''|*[!0-9]*) max=2 ;; esac
blocks=0
if [ -n "$STATE" ] && [ -f "$STATE" ]; then
  blocks=$(cat "$STATE" 2>/dev/null) || blocks=0
  case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
fi
[ "$blocks" -lt "$max" ] || exit 0
[ -z "$STATE" ] || echo $((blocks + 1)) > "$STATE" 2>/dev/null || true

if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
  reason="You are stopping with ZERO commits on this branch while the worktree holds staged or unstaged changes. Describing or staging a commit is not performing it. Commit your work now (git add -A && git commit with a plain message per your instructions), then finish. If something genuinely blocks the commit, write the question to .harness/QUESTIONS.md and stop."
else
  reason="You are stopping with ZERO commits on this branch and no changes in the worktree. A session may not end with neither commits nor questions: if the task is done, something was never committed - re-check git log against the work you believe you did. If the task cannot or should not be done, write .harness/QUESTIONS.md (questions) or .harness/REJECTED.md (a reasoned rejection) and stop."
fi

printf '{"decision":"block","reason":"%s"}\n' "$reason"
exit 0
