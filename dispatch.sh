#!/usr/bin/env bash
# Local-first entry point. See dispatch --help for task and station commands.
set -eu
DISPATCH_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
exec python3 "$DISPATCH_SCRIPT_DIR/lib/dispatch_cli.py" "$@"
