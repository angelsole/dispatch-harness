#!/usr/bin/env bash
# Evidence recovery through the public CLI, without paid model calls.
set -eu
EVIDENCE_TEST_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$EVIDENCE_TEST_SOURCE/tests/evidence_retry_test.py"
