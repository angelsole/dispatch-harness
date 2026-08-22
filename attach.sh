#!/usr/bin/env bash
# Step into a worker's session interactively (full context, bills the Claude sub).
# Usage: attach.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: attach.sh <RUN-ID>" >&2; exit 2; }
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
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

# A session the run billed elsewhere resumes against the wrong endpoint unless
# the shell carries the same env the run injected. Only the key's PATH is
# printed; the credential stays in the file.
if [ "$(cat "$RUN/implementer-provider" 2>/dev/null || echo anthropic)" = zai ]; then
  echo "This run's implementer is pinned to z.ai — resume it there by exporting first:"
  echo "  export ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic API_TIMEOUT_MS=3000000 ANTHROPIC_AUTH_TOKEN=\"\$(cat ${ZAI_API_KEY_FILE:-$HARNESS_DIR/zai-api-key})\""
fi

cd "$WT" && exec env -u ANTHROPIC_API_KEY claude --resume "$(cat "$RUN/opus-session")"
