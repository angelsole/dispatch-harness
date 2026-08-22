#!/usr/bin/env bash
# Run the dev server inside a run's worktree to see its changes live.
# Usage: preview.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: preview.sh <RUN-ID>" >&2; exit 2; }
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
RUN="$HARNESS_DIR/runs/$1"
WT=$(harness_worktree "$RUN")
[ -n "$WT" ] && [ -d "$WT" ] || { echo "worktree not found for $1 (already cleaned up?)" >&2; exit 1; }

# shellcheck source=repos.conf.sh
. "$HARNESS_DIR/repos.conf.sh"
repo_config "$WT"
[ -n "${DEV_CMD:-}" ] || DEV_CMD="npm run dev"

echo "[preview] $WT"
echo "[preview] $DEV_CMD  (Ctrl+C to stop; if the port is busy the dev server picks the next one)"
cd "$WT" && exec bash -c "$DEV_CMD"
