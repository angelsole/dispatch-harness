#!/usr/bin/env bash
# Deterministic capture/publishing tests: local git and HTTP, fake external CLIs.
set -eu
DEMO_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$DEMO_TEST_ROOT/tests/demo_test.py"
