#!/usr/bin/env bash
# Deterministic test gate for this repo: static checks on every shipped shell
# script, then every suite under tests/. Lint and tests both run on every
# invocation — a failure in one never hides the other.
set -u
status=0
scripts=$(git ls-files '*.sh')
for f in $scripts; do
  bash -n "$f" || status=1
done
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -S warning $scripts || status=1
else
  echo "gate: shellcheck is required (brew install shellcheck / apt-get install shellcheck)" >&2
  status=1
fi

# The dispatch knobs a run pins at first dispatch, cleared for every suite.
# The harness dispatches THIS repo, and it selects a provider by exporting
# IMPLEMENTER_PROVIDER — which every fixture run-task.sh a suite spawns then
# inherits, pins, and dies on at the credential check for a vendor the fixture
# never asked for. Eleven suites failed that way, all of them reporting
# setup_failed for reasons nothing in their own fixture explains. A suite that
# wants one of these sets it itself; none of them may inherit one.
GATE_ENV=(env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT
          -u REVIEWER_MODEL -u REVIEWER_EFFORT -u HARNESS_OWNER
          -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES
          -u HARNESS_SKIP_REVIEW -u HARNESS_REDISPATCH
          -u HARNESS_ESCALATION -u HARNESS_ESCALATION_STEPS
          -u HARNESS_PROFILES -u HARNESS_VISUAL_ROUNDS)

# Bash expands the glob in filename order and includes new suites before their
# first commit. Only a failing suite prints its transcript; a green one is worth
# exactly one line — plus its skips, if it has any. A suite that could not test
# a claim on this machine (no codex CLI for the review-sandbox probe, say) says
# so with a `  skip ` line, and a gate summary that swallowed those would read
# as coverage the run does not have.
for t in tests/*.test.sh; do
  [ -e "$t" ] || continue
  started=$SECONDS
  if out=$("${GATE_ENV[@]}" bash "$t" 2>&1); then verdict=ok; else verdict=FAIL; status=1; fi
  counts=$(printf '%s\n' "$out" | awk '
    /^  ok /   { passed++ }
    /^  FAIL / { failed++ }
    /^  skip / { skipped++ }
    END { printf "%d passed, %d failed%s", passed, failed,
            (skipped ? ", " skipped " SKIPPED" : "") }
  ')
  printf '%s\n' "$out" | grep '^  skip ' || true
  printf 'gate: %-24s %-4s %3ds  %s\n' "$t" "$verdict" "$((SECONDS - started))" \
    "$counts"
  [ "$verdict" = ok ] || printf '%s\n' "$out"
done

exit $status
