#!/usr/bin/env bash
# Real worktrees and detached drivers, fake model/auth/PR services.
set -eu
DISPATCH_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$DISPATCH_TEST_ROOT/tests/dispatch_cli_test.py"
