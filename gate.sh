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

# git ls-files emits sorted paths, so suites run in filename order. Only a
# failing suite prints its transcript; a green one is worth exactly one line.
for t in $(git ls-files 'tests/*.test.sh'); do
  started=$SECONDS
  if out=$(bash "$t" 2>&1); then verdict=ok; else verdict=FAIL; status=1; fi
  printf 'gate: %-24s %-4s %3ds  %s\n' "$t" "$verdict" "$((SECONDS - started))" \
    "$(printf '%s\n' "$out" | grep -E '[0-9]+ passed, [0-9]+ failed' | tail -1)"
  [ "$verdict" = ok ] || printf '%s\n' "$out"
done

exit $status
