#!/usr/bin/env bash
# Example PREFLIGHT_CMD for a repo whose test gate needs a Postgres test DB.
#
# The pipeline runs the preflight BEFORE handing the brief to the implementer,
# so a run fails fast on a broken environment instead of burning an implementer
# pass the gate could never pass in. Wire it up in repos.local.sh:
#
#   PREFLIGHT_CMD="${HARNESS_DIR:-$HOME/.claude/harness}/preflight-postgres.sh"
#
# Copy this file to $HARNESS_DIR/preflight-postgres.sh and adapt the container
# name, port, and env file to your project. Runs inside the worktree (cwd) and
# exits non-zero with a clear reason.
#
# Lesson worth keeping: provision the test DB with `prisma migrate deploy`, never
# `db push`. Constructs that live only in raw SQL migrations — e.g. partial
# unique indexes — are absent under `db push`, so tests that rely on them (unique
# constraints, ON CONFLICT paths) fail in ways that look like app bugs. Bit us in
# production; the preflight makes the environment match CI.
set -euo pipefail

CONTAINER="${TEST_DB_CONTAINER:-app_test_postgres}"
PORT="${TEST_DB_PORT:-5434}"
ENV_FILE="${TEST_ENV_FILE:-.env.test}"

if ! nc -z localhost "$PORT" 2>/dev/null; then
  echo "[preflight] test DB not listening on :$PORT — trying: docker start $CONTAINER"
  if ! docker start "$CONTAINER" >/dev/null 2>&1; then
    echo "[preflight] FAILED: container '$CONTAINER' does not exist. Create it with:"
    echo "  docker run -d --name $CONTAINER -p $PORT:5432 \\"
    echo "    -e POSTGRES_USER=<user> -e POSTGRES_PASSWORD=<pass> -e POSTGRES_DB=<db> postgres:16"
    echo "  (credentials/db name should match DATABASE_URL in $ENV_FILE)"
    exit 1
  fi
  for _ in $(seq 1 20); do
    nc -z localhost "$PORT" 2>/dev/null && break
    sleep 1
  done
  nc -z localhost "$PORT" 2>/dev/null || { echo "[preflight] FAILED: :$PORT still down after docker start"; exit 1; }
fi

[ -f "$ENV_FILE" ] || { echo "[preflight] FAILED: no $ENV_FILE in $(pwd)"; exit 1; }
URL=$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')
[ -n "$URL" ] || { echo "[preflight] FAILED: no DATABASE_URL in $ENV_FILE"; exit 1; }

echo "[preflight] applying migrations (idempotent)"
if ! DATABASE_URL="$URL" npx prisma migrate deploy; then
  echo "[preflight] FAILED: migrate deploy errored. If this DB was ever provisioned"
  echo "with 'prisma db push', drop and recreate it, then rerun:"
  echo "  docker exec $CONTAINER psql -U <user> -d postgres -c 'DROP DATABASE <db>;' -c 'CREATE DATABASE <db>;'"
  exit 1
fi
echo "[preflight] test DB ready on :$PORT"
