#!/usr/bin/env bash
# Local control authorization and recovery use fixtures, never real accounts.
set -eu
CONSOLE_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$CONSOLE_TEST_ROOT/tests/console_actions_test.py"
node --test "$CONSOLE_TEST_ROOT/tests/console-http.test.js" "$CONSOLE_TEST_ROOT/tests/console-control.test.js"
