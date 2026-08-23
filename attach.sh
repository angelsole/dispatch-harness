#!/usr/bin/env bash
# Step into a worker's session interactively (full context, bills the Claude sub).
# Usage: attach.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: attach.sh <RUN-ID>" >&2; exit 2; }
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH
RUN="$HARNESS_DIR/runs/$1"
[ -f "$RUN/opus-session" ] || { echo "no worker session recorded for $1" >&2; exit 1; }
WT=$(cat "$RUN/worktree" 2>/dev/null || true)
[ -n "$WT" ] && [ -d "$WT" ] || { echo "worktree not found for $1" >&2; exit 1; }

# Attaching while the headless worker is still running forks its context —
# the fork won't see what the worker does afterwards, and vice versa.
if [ -f "$RUN/status" ]; then
  read -r _ stagetext < "$RUN/status"
  case "$stagetext" in
    done:*|waiting*) ;;
    *) printf 'Worker looks ACTIVE (stage: %s). Attaching now forks its session. Continue? [y/N] ' "$stagetext"
       read -r ans; [ "$ans" = "y" ] || exit 0 ;;
  esac
fi

# A z.ai session cannot be resumed before this process starts with the provider
# environment. Stop with an actionable command instead of immediately opening
# the session against Anthropic. Only the key's path is printed.
IMPLEMENTER_PROVIDER="$(cat "$RUN/implementer-provider" 2>/dev/null || echo anthropic)"
if [ "$IMPLEMENTER_PROVIDER" = zai ]; then
  zai_env_missing=0
  [ "${ANTHROPIC_BASE_URL:-}" = https://api.z.ai/api/anthropic ] \
    && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] \
    && [ "${API_TIMEOUT_MS:-}" = 3000000 ] \
    && [ "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" = glm-4.7 ] \
    && [ "${CLAUDE_CODE_SUBAGENT_MODEL:-}" = glm-4.7 ] \
    || zai_env_missing=1
  compact_export=""
  case "$(cat "$RUN/implementer-model" 2>/dev/null || true)" in
    *'[1m]')
      compact_export=" CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000"
      [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" = 1000000 ] || zai_env_missing=1
      ;;
  esac
  if [ "$zai_env_missing" = 1 ]; then
    echo "This run's implementer is pinned to z.ai. Export its environment, then rerun attach.sh:"
    echo "  export ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic API_TIMEOUT_MS=3000000 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 CLAUDE_CODE_SUBAGENT_MODEL=glm-4.7${compact_export} ANTHROPIC_AUTH_TOKEN=\"\$(cat \"${ZAI_API_KEY_FILE:-$HARNESS_DIR/zai-api-key}\")\""
    exit 2
  fi
fi

cd "$WT" || exit 1
if [ "$IMPLEMENTER_PROVIDER" = zai ]; then
  exec env -u ANTHROPIC_API_KEY claude --resume "$(cat "$RUN/opus-session")"
fi

# An Anthropic-pinned session must not inherit a station's z.ai defaults. The
# run pin is the policy boundary here just as it is on first dispatch.
exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
  -u API_TIMEOUT_MS -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
  -u CLAUDE_CODE_SUBAGENT_MODEL -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
  claude --resume "$(cat "$RUN/opus-session")"
