#!/usr/bin/env bash
# Run the dev server inside a run's worktree to see its changes live.
# Usage: preview.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: preview.sh <RUN-ID>" >&2; exit 2; }
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUN="$HARNESS_DIR/runs/$1"
WT=$(cat "$RUN/worktree" 2>/dev/null || jq -r '.worktree // empty' "$RUN/result.json" 2>/dev/null)
[ -n "$WT" ] && [ -d "$WT" ] || { echo "worktree not found for $1 (already cleaned up?)" >&2; exit 1; }

# shellcheck source=repos.conf.sh
. "$HARNESS_DIR/repos.conf.sh"
repo_config "$WT"
[ -n "${DEV_CMD:-}" ] || DEV_CMD="npm run dev"

echo "[preview] $WT"
echo "[preview] $DEV_CMD  (Ctrl+C to stop; if the port is busy the dev server picks the next one)"
cd "$WT" && exec bash -c "$DEV_CMD"
