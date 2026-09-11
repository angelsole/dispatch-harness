#!/usr/bin/env bash
# Durable Linear ingress and the ordinary lifecycle, with fake external services.
set -eu
LINEAR_TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$LINEAR_TEST_ROOT/tests/linear_dispatch_test.py"
