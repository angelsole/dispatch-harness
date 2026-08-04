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

# Bash expands the glob in filename order and includes new suites before their
# first commit. Only a failing suite prints its transcript; a green one is worth
# exactly one line.
for t in tests/*.test.sh; do
  [ -e "$t" ] || continue
  started=$SECONDS
  if out=$(bash "$t" 2>&1); then verdict=ok; else verdict=FAIL; status=1; fi
  counts=$(printf '%s\n' "$out" | awk '
    /^  ok /   { passed++ }
    /^  FAIL / { failed++ }
    END { printf "%d passed, %d failed", passed, failed }
  ')
  printf 'gate: %-24s %-4s %3ds  %s\n' "$t" "$verdict" "$((SECONDS - started))" \
    "$counts"
  [ "$verdict" = ok ] || printf '%s\n' "$out"
done

exit $status
