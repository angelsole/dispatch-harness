#!/usr/bin/env bash
# Remove a run's worktree and local branch once its PR is safely on origin.
# Usage: cleanup.sh <RUN-ID>
set -u
[ $# -eq 1 ] || { echo "usage: cleanup.sh <RUN-ID>" >&2; exit 2; }
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH
RUN="$HARNESS_DIR/runs/$1"

# The mirror target may be a repo pin (repos.local.sh) rather than an exported
# variable, so resolve it the way run-task.sh did, off the worktree the run named.
if [ -z "${HARNESS_MIRROR:-}" ] && [ -r "$HARNESS_DIR/repos.conf.sh" ]; then
  _wt=$(jq -r '.worktree // empty' "$RUN/result.json" 2>/dev/null)
  if [ -n "$_wt" ]; then
    # shellcheck source=repos.conf.sh
    . "$HARNESS_DIR/repos.conf.sh"
    repo_config "$_wt" >/dev/null 2>&1 || true
  fi
  unset _wt
fi

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

WT=$(harness_worktree "$RUN")
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
