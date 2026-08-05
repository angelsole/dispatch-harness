#!/usr/bin/env bash
# Remove a run's worktree and local branch once its PR is safely on origin.
# Usage: cleanup.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: cleanup.sh <RUN-ID>" >&2; exit 2; }
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUN="$HARNESS_DIR/runs/$1"

# A run dispatched with HARNESS_MIRROR left a copy of its run dir on another
# machine's wall. Promoting the run should free that disk too — best-effort,
# and before the early exit below, so it happens even when there is no worktree
# left to remove.
# Loading is conditional so cleanup remains unchanged on old installs and when
# mirroring is not configured.
if [ -n "${HARNESS_MIRROR:-}" ] && [ -r "$HARNESS_DIR/mirror.sh" ]; then
  # shellcheck source=mirror.sh
  . "$HARNESS_DIR/mirror.sh"
  if mirror_safe_id "$1"; then
    mirror_remove "$1"
    echo "cleared mirrored copy at ${HARNESS_MIRROR%/}/$1 (best-effort)"
  fi
fi

WT=$(cat "$RUN/worktree" 2>/dev/null || jq -r '.worktree // empty' "$RUN/result.json" 2>/dev/null)
BRANCH=$(jq -r '.branch // empty' "$RUN/result.json" 2>/dev/null)
[ -n "$WT" ] && [ -d "$WT" ] || { echo "nothing to clean for $1"; exit 0; }

REPO=$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")
git -C "$REPO" worktree remove --force "$WT" && echo "removed worktree $WT"
git -C "$REPO" worktree prune

# Delete the local branch only if it exists on origin (i.e. the PR push succeeded).
if [ -n "$BRANCH" ] && git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git -C "$REPO" branch -D "$BRANCH" >/dev/null 2>&1 && echo "deleted local branch $BRANCH (still on origin)"
fi
echo "run logs kept at $RUN"
