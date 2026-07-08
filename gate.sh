#!/usr/bin/env bash
# Deterministic test gate for this repo: static checks on every shipped shell script.
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
exit $status
