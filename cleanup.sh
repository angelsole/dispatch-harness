#!/usr/bin/env bash
# Remove a run's worktree and local branch once its PR is safely on origin.
# Usage: cleanup.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: cleanup.sh <RUN-ID>" >&2; exit 2; }
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUN="$HARNESS_DIR/runs/$1"
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
