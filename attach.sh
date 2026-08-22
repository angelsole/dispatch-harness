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

cd "$WT" && exec env -u ANTHROPIC_API_KEY claude --resume "$(cat "$RUN/opus-session")"
