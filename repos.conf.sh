# shellcheck shell=bash
# The vars below are outputs consumed by the sourcing script (run-task.sh /
# preview.sh / sync-pr.sh), so shellcheck can't see their use from here.
# shellcheck disable=SC2034
# Per-repo pipeline config, sourced by run-task.sh / sync-pr.sh / preview.sh.
# repo_config <repo-or-worktree-path> sets:
#   BASE_BRANCH INSTALL_CMD GATE_CMD VISUAL_GATE_CMD MCP_CONFIG ENV_SUBDIRS \
#   DEV_CMD PREFLIGHT_CMD DEMO_DEV_CMD DEMO_PORT PREPROD
#
# VISUAL_GATE_CMD is the visual profile's gate — the stage that renders the app
# and judges the picture. Never auto-detected here: the profile supplies its own
# default for a repo that carries a .creative/ contract, and a repo that carries
# neither has no visual stage at all.
#
# PREPROD=1 marks a repo that has not shipped yet: run-task.sh then states the
# pre-production posture (delete obsolete paths, no compatibility layers, no
# migrations) to both the implementer and the reviewer. Never auto-detected —
# only a pin can claim a repo is pre-production.
#
# The shipped file is generic: it auto-detects from lockfiles and the remote's
# default branch, so it works for any repo out of the box. To PIN settings for
# a specific repo (a custom gate command, a non-default base branch, an MCP
# config, a DB preflight, a demo port), drop a `repos.local.sh` next to this
# file — see repos.local.sh.example. It is gitignored, so your machine-specific
# paths never ship, and it is sourced here if present.

# The shared helpers, read from beside this file — the checkout when it is
# sourced from there, HARNESS_DIR once install.sh has shipped lib/ into it.
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside repos.conf.sh — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH

# Load user pins, if any. repos.local.sh lives alongside this file (i.e. inside
# HARNESS_DIR once installed) and defines repo_config_local().
_conf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$HARNESS_DIR")"
# shellcheck source=/dev/null
[ -f "$_conf_dir/repos.local.sh" ] && . "$_conf_dir/repos.local.sh"
unset _conf_dir

repo_config() {
  local repo="$1"
  local name; name=$(basename "$repo")
  BASE_BRANCH=""; INSTALL_CMD=""; GATE_CMD=""; VISUAL_GATE_CMD=""; MCP_CONFIG=""
  ENV_SUBDIRS=""; DEV_CMD=""; PREFLIGHT_CMD=""; DEMO_DEV_CMD=""; DEMO_PORT=""; PREPROD=""

  # User pins first (if repos.local.sh defined the hook); auto-detection then
  # fills only the fields the hook left blank, so a pin can set just one value.
  if command -v repo_config_local >/dev/null 2>&1; then
    repo_config_local "$repo" "$name"
  fi

  _detect_config "$repo"
  [ -n "$BASE_BRANCH" ] || _detect_base "$repo"
  # Only pass an MCP config that actually exists.
  [ -n "$MCP_CONFIG" ] && [ ! -f "$MCP_CONFIG" ] && MCP_CONFIG=""
  return 0
}

_detect_base() {
  local repo="$1"
  if git -C "$repo" show-ref --verify --quiet refs/remotes/origin/staging; then BASE_BRANCH=staging
  elif git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main; then BASE_BRANCH=main
  else BASE_BRANCH=master
  fi
}

# Fill INSTALL_CMD / GATE_CMD from the repo's lockfiles, but never overwrite a
# value a repos.local.sh pin already set.
_detect_config() {
  local repo="$1"
  if [ -f "$repo/yarn.lock" ]; then
    [ -n "$INSTALL_CMD" ] || INSTALL_CMD="yarn install"
    [ -n "$GATE_CMD" ] || GATE_CMD="yarn test"
  elif [ -f "$repo/package-lock.json" ] || [ -f "$repo/package.json" ]; then
    [ -n "$INSTALL_CMD" ] || INSTALL_CMD="npm ci"
    [ -n "$GATE_CMD" ] || GATE_CMD="npm test"
  elif [ -f "$repo/uv.lock" ] || [ -f "$repo/pyproject.toml" ]; then
    [ -n "$INSTALL_CMD" ] || INSTALL_CMD="uv sync"
    [ -n "$GATE_CMD" ] || GATE_CMD="uv run pytest"
  fi
}
