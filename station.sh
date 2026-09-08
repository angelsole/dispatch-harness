#!/usr/bin/env bash
# The dispatch station: a persistent Astra (Codex) or Claude planner.
#
# Usage:
#   station.sh setup [--owner NAME]  guide missing logins, then open the planner
#   station.sh [start] [--planner codex|claude] [--model ID] [--dir PATH]
#   station.sh doctor [--repo PATH] [--planner codex|claude]
#   station.sh login codex|claude|gh [--browser]
#   Add --host SSH_ALIAS to any command to run it on the Mini.
#   Add --owner NAME to select ~/accounts/NAME/{claude,codex,gh}.
#   --accounts-dir PATH overrides ~/accounts (on the target machine).
#   --remote-harness PATH selects a non-default install on the SSH host.
#   --hands-off bypasses planner permission checks (Codex also disables its sandbox).
#   Available for start/setup; it opens a separate session from the default mode.
#
# Codex defaults to gpt-6-astra; Claude defaults to fable.
# Each owner/planner/model gets a separate tmux session. Re-running reattaches;
# The default detach binding is Ctrl-b d. macOS caffeinate keeps it awake.
# Login defaults to Codex device authentication; --browser uses its callback
# flow instead (forward localhost:1455 yourself when using SSH).
# Doctor prints no credentials. --repo also checks origin access and runs that
# repo's configured PREFLIGHT_CMD, capped at 30 seconds; it runs no test gate.
#
# Env: DISPATCH_STATION_DIR (default: $HOME), DISPATCH_PLANNER (codex),
# DISPATCH_MODEL (provider default), QM_ACCOUNTS_DIR ($HOME/accounts),
# HARNESS_OWNER (current account when unset), HARNESS_DIR (~/.claude/harness),
# CODEX_BIN / CLAUDE_BIN (from PATH). Remote defaults resolve on the remote host.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

usage_error() { echo "station: $*" >&2; exit 2; }
die() { echo "station: $*" >&2; exit 1; }
# SSH and tmux both pass a command through a shell. Quote every argument with
# POSIX single quotes; never interpolate a directory, owner or model as code.
shell_args() {
  local arg quote="'" escaped="'\\''"
  for arg in "$@"; do printf "'%s' " "${arg//$quote/$escaped}"; done
}

ACTION=start; LOGIN_PROVIDER=""; HOST=""; REMOTE_HARNESS=""; BROWSER=0
HANDS_OFF=0
PLANNER="${DISPATCH_PLANNER:-codex}"; MODEL="${DISPATCH_MODEL:-}"
OWNER="${HARNESS_OWNER:-}"; OWNER_EXPLICIT=0; ACCOUNTS_DIR="${QM_ACCOUNTS_DIR:-$HOME/accounts}"
STATION_DIR="${DISPATCH_STATION_DIR:-$HOME}"; REPO=""
REMOTE_ARGS=()
case "${1:-}" in
  start|doctor|setup) ACTION="$1"; REMOTE_ARGS+=("$1"); shift ;;
  login) ACTION=login; shift
         [ $# -gt 0 ] || usage_error "login needs codex, claude or gh"
         LOGIN_PROVIDER="$1"; REMOTE_ARGS+=(login "$1"); shift ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --host|--remote-harness|--planner|--model|--dir|--owner|--accounts-dir|--repo)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
      case "$1" in
        --host) HOST="$2" ;;
        --remote-harness) REMOTE_HARNESS="$2" ;;
        *) REMOTE_ARGS+=("$1" "$2") ;;
      esac
      case "$1" in
        --planner) PLANNER="$2" ;; --model) MODEL="$2" ;;
        --dir) STATION_DIR="$2" ;; --owner) OWNER="$2"; OWNER_EXPLICIT=1 ;;
        --accounts-dir) ACCOUNTS_DIR="$2" ;; --repo) REPO="$2" ;;
      esac
      shift ;;
    --browser) BROWSER=1; REMOTE_ARGS+=("$1") ;;
    --hands-off) HANDS_OFF=1; REMOTE_ARGS+=("$1") ;;
    -h|--help) harness_usage "$0"; exit 0 ;;
    *) usage_error "unknown option: $1 (see --help)" ;;
  esac
  shift
done
case "$PLANNER" in codex|claude) ;; *) usage_error "planner must be codex or claude" ;; esac
case "$OWNER" in *[!a-zA-Z0-9_-]*|-*) usage_error "owner must contain letters, digits, underscores or dashes and cannot start with a dash" ;; esac
case "$MODEL" in *[!a-zA-Z0-9._-]*|-*) usage_error "invalid model ID" ;; esac
if [ "$ACTION" = login ]; then
  case "$LOGIN_PROVIDER" in codex|claude|gh) ;; *) usage_error "login needs codex, claude or gh" ;; esac
fi
[ "$BROWSER" = 0 ] || { [ "$ACTION" = login ] && [ "$LOGIN_PROVIDER" = codex ]; } \
  || usage_error "--browser is only for login codex"
[ -z "$REPO" ] || [ "$ACTION" = doctor ] || usage_error "--repo is only for doctor"
[ "$HANDS_OFF" = 0 ] || { [ "$ACTION" = start ] || [ "$ACTION" = setup ]; } \
  || usage_error "--hands-off is only for start or setup"

if [ -n "$HOST" ]; then
  case "$HOST" in -*|*[!a-zA-Z0-9_.@:-]*) usage_error "invalid SSH host" ;; esac
  if [ -n "$REMOTE_HARNESS" ]; then
    case "$REMOTE_HARNESS" in /*) ;; *) usage_error "--remote-harness must be an absolute remote path" ;; esac
    remote_script="$(shell_args "$REMOTE_HARNESS/station.sh")"
  else
    remote_script='"$HOME/.claude/harness/station.sh"'
  fi
  # No login shell: startup files may start a program or change identities.
  # station.sh supplies the usual macOS binary directories itself.
  remote_cmd="exec bash $remote_script $(shell_args ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"})"
  ssh_args=(-o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  if [ "$ACTION" = doctor ]; then ssh_args+=(-o BatchMode=yes); else ssh_args+=(-t); fi
  exec ssh "${ssh_args[@]}" "$HOST" "$remote_cmd"
fi
[ -z "$REMOTE_HARNESS" ] || usage_error "--remote-harness needs --host"

# Ask on the target machine, after SSH has allocated its terminal. Never save
# a default owner in the shared macOS account: it would affect the next person.
if [ "$ACTION" = setup ] && [ "$OWNER_EXPLICIT" = 0 ]; then
  [ -t 0 ] || usage_error "setup needs --owner NAME when stdin is not a terminal"
  echo "Existing stations (choose yours, or enter a new name):"
  for account in "$ACCOUNTS_DIR"/*; do
    [ ! -d "$account" ] || printf '  %s\n' "${account##*/}"
  done
  printf 'Your station name: '
  IFS= read -r OWNER || die "setup cancelled"
  case "$OWNER" in ''|*[!a-zA-Z0-9_-]*|-*) usage_error "enter a station name using letters, digits, underscores or dashes" ;; esac
fi

# Non-interactive SSH often has only /usr/bin:/bin:/usr/sbin:/sbin. Preserve
# explicit PATH choices and append the common user/Homebrew install locations.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
CODEX_BIN="${CODEX_BIN:-codex}"; CLAUDE_BIN="${CLAUDE_BIN:-claude}"
case "$ACCOUNTS_DIR" in /*) ;; *) ACCOUNTS_DIR="$PWD/$ACCOUNTS_DIR" ;; esac
case "$HARNESS_DIR" in /*) ;; *) HARNESS_DIR="$PWD/$HARNESS_DIR" ;; esac
if [ -n "$OWNER" ]; then
  ACCOUNT_DIR="$ACCOUNTS_DIR/$OWNER"
  export CLAUDE_CONFIG_DIR="$ACCOUNT_DIR/claude"
  export CODEX_HOME="$ACCOUNT_DIR/codex"
  export GH_CONFIG_DIR="$ACCOUNT_DIR/gh"
fi
# Keep native CLI configuration selection. In particular, exporting the
# default Claude directory changes its global config file and MCP servers.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
GH_DIR="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
ACCOUNT_ENV=()
[ -z "${CLAUDE_CONFIG_DIR:-}" ] || ACCOUNT_ENV+=("CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR")
[ -z "${CODEX_HOME:-}" ] || ACCOUNT_ENV+=("CODEX_HOME=$CODEX_HOME")
[ -z "${GH_CONFIG_DIR:-}" ] || ACCOUNT_ENV+=("GH_CONFIG_DIR=$GH_CONFIG_DIR")
export HARNESS_DIR HARNESS_OWNER="$OWNER"
# Station workers use the selected subscription/account, including when an
# existing tmux server remembers tokens from somebody else's old shell.
CLEAR_AUTH=(-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL
  -u CLAUDE_CODE_OAUTH_TOKEN -u OPENAI_API_KEY -u OPENAI_BASE_URL
  -u CODEX_ACCESS_TOKEN -u GH_TOKEN -u GITHUB_TOKEN
  -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u HARNESS_CODEX_HOME_FALLBACK)
account_exec() { env "${CLEAR_AUTH[@]}" "$@"; }
repair_command() {
  local args=("$SELF" login "$1")
  [ -z "$OWNER" ] || args+=(--owner "$OWNER")
  shell_args "${args[@]}" --accounts-dir "$ACCOUNTS_DIR"
}
# Timeout wraps the actual subprocess, not a shell function.
check_auth() {
  case "$1" in
    codex) with_timeout 20 env "${CLEAR_AUTH[@]}" "$CODEX_BIN" login status >/dev/null 2>&1 ;;
    claude) with_timeout 20 env "${CLEAR_AUTH[@]}" "$CLAUDE_BIN" auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1 ;;
    gh) with_timeout 20 env "${CLEAR_AUTH[@]}" gh auth status --hostname github.com >/dev/null 2>&1 ;;
  esac
}

login_provider() {  # $1 = provider, $2 = use browser callback (Codex only)
  local provider="$1" browser="${2:-0}"
  if [ -n "$OWNER" ]; then
    (umask 077; mkdir -p "$CLAUDE_DIR" "$CODEX_DIR" "$GH_DIR") || return 1
  fi
  echo "station: login $provider for ${OWNER:-current account}"
  case "$provider" in
    codex)
      command -v "$CODEX_BIN" >/dev/null || die "codex is not installed"
      if [ "$browser" = 1 ]; then
        account_exec "$CODEX_BIN" login || return 1
      else
        echo "Open the printed link on your own device and enter its code."
        echo "If device login is disabled, enable it in ChatGPT settings or use --browser."
        account_exec "$CODEX_BIN" login --device-auth || return 1
      fi ;;
    claude) account_exec "$CLAUDE_BIN" auth login --claudeai || return 1 ;;
    gh) account_exec gh auth login --hostname github.com --git-protocol https --web || return 1 ;;
  esac
  check_auth "$provider" || { echo "station: login did not establish $provider authentication" >&2; return 1; }
  echo "station: $provider authentication configured for ${OWNER:-current account}"
}

if [ "$ACTION" = login ]; then
  login_provider "$LOGIN_PROVIDER" "$BROWSER"
  exit 0
fi

if [ "$ACTION" = setup ]; then
  # Check the shared installation before asking anyone to sign in. This flow
  # is personal onboarding; installing/updating binaries stays with the host.
  for bin in git bash jq gh "$CLAUDE_BIN" "$CODEX_BIN" tmux; do
    command -v "$bin" >/dev/null 2>&1 || die "missing $bin; ask the station operator to install it on this machine"
  done
  [ -x "$HARNESS_DIR/run-task.sh" ] || die "shared harness is missing; ask the station operator to run install.sh on this machine"
  [ -d "$STATION_DIR" ] || die "working directory missing: $STATION_DIR"
  for skill in dispatch briefed-dispatch; do
    [ -f "$HOME/.agents/skills/$skill/SKILL.md" ] \
      || die "shared Codex skill $skill is missing; ask the station operator to re-run install.sh"
  done
  (umask 077; mkdir -p "$CLAUDE_DIR" "$CODEX_DIR" "$GH_DIR")
  echo "station: setting up $OWNER on this machine"
  for provider in codex claude gh; do
    if check_auth "$provider"; then
      echo "[ok] $provider is already signed in"
    else
      echo "[setup] $provider needs your sign-in; use your own account in the browser."
      login_provider "$provider" || die "$provider setup stopped; re-run setup to continue (completed logins are kept)"
    fi
  done
  echo "station: accounts ready; opening your $PLANNER planner. Re-run this command to reconnect or repair a login."
  ACTION=start
fi

if [ "$ACTION" = doctor ]; then
  failures=0
  good() { printf '[ok] %s\n' "$*"; }
  bad() { printf '[fail] %s\n' "$*"; failures=$((failures+1)); }
  echo "station: ${OWNER:-current account} | planner $PLANNER | $STATION_DIR"
  for bin in git bash jq gh "$CLAUDE_BIN" "$CODEX_BIN" tmux; do
    if command -v "$bin" >/dev/null 2>&1; then good "tool $bin"; else bad "missing tool $bin"; fi
  done
  [ -d "$STATION_DIR" ] && good "working directory" || bad "working directory missing: $STATION_DIR"
  [ -x "$HARNESS_DIR/run-task.sh" ] && good "harness installed" || bad "harness missing: run install.sh on this machine"
  for provider in codex claude gh; do
    if check_auth "$provider"; then good "$provider authentication configured"
    else bad "$provider authentication unavailable; repair: $(repair_command "$provider")"; fi
  done
  # login status is a local credential check, not proof of model entitlement.
  if command -v "$CODEX_BIN" >/dev/null 2>&1; then
    account_exec "$CODEX_BIN" --version
    echo "[info] Model access is checked when the planner starts."
  fi
  for skill in dispatch briefed-dispatch; do
    if [ -f "$HOME/.agents/skills/$skill/SKILL.md" ]; then good "Codex skill $skill"
    else bad "Codex skill $skill missing; re-run install.sh on this machine"; fi
  done
  if [ -n "$REPO" ]; then
    if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
      if with_timeout 20 env "${CLEAR_AUTH[@]}" GIT_TERMINAL_PROMPT=0 git -C "$REPO" ls-remote origin HEAD >/dev/null 2>&1; then
        good "repository origin reachable"
      else bad "repository origin unavailable (SSH or GitHub credentials/network)"; fi
      # Pins are trusted local shell configuration, as in run-task.sh.
      # shellcheck source=repos.conf.sh
      . "$SELF_DIR/repos.conf.sh"
      repo_config "$REPO"
      if [ -n "${PREFLIGHT_CMD:-}" ]; then
        if (cd "$REPO" && with_timeout 30 env "${CLEAR_AUTH[@]}" bash -c "$PREFLIGHT_CMD") >/dev/null 2>&1; then
          good "repository service preflight"
        else bad "repository service preflight failed or timed out; inspect PREFLIGHT_CMD in repos.local.sh"; fi
      else echo "[info] No repository service preflight configured."; fi
    else bad "not a git repository: $REPO"; fi
  fi
  echo "station: $failures failed check(s)"
  [ "$failures" -eq 0 ]; exit
fi

[ -d "$STATION_DIR" ] || die "working directory missing: $STATION_DIR"
STATION_DIR="$(cd "$STATION_DIR" && pwd -P)"
[ -z "$OWNER" ] || [ -d "$ACCOUNTS_DIR/$OWNER" ] \
  || die "unknown owner $OWNER; set up authentication: $(repair_command codex)"
command -v tmux >/dev/null || die "tmux is not installed"
MODEL="${MODEL:-$(python3 "$SELF_DIR/lib/planner.py" model "$PLANNER")}"
if [ "$PLANNER" = codex ]; then
  planner_cmd=("$CODEX_BIN" -m "$MODEL" -C "$STATION_DIR" --add-dir "$HARNESS_DIR/runs")
  [ "$HANDS_OFF" = 0 ] || planner_cmd+=(--dangerously-bypass-approvals-and-sandbox)
else
  planner_cmd=("$CLAUDE_BIN")
  [ -z "$MODEL" ] || planner_cmd+=(--model "$MODEL")
  [ "$HANDS_OFF" = 0 ] || planner_cmd+=(--dangerously-skip-permissions)
fi
SESSION="dispatch-${OWNER:-current}-$PLANNER-${MODEL:-default}"
# A native session must not reattach to a pre-fix session that exported the
# default CLAUDE_CONFIG_DIR and therefore opened a different Claude profile.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || SESSION="$SESSION-native"
[ "$HANDS_OFF" = 0 ] || SESSION="$SESSION-hands-off"
SESSION="${SESSION//./_}"
context=$(shell_args "$STATION_DIR" "$HARNESS_DIR" "$CLAUDE_DIR" "$CODEX_DIR" "$GH_DIR" "$MODEL")
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || context="$context $(shell_args native-claude-config)"
# Preserve the context format of existing ordinary sessions. Hands-off has its
# own name and records the permission choice as an additional context field.
[ "$HANDS_OFF" = 0 ] || context="$context $(shell_args hands-off)"
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  # A changed accounts root must never reattach to the other account's session.
  existing_context=$(tmux show-options -qv -t "$SESSION" @dispatch-context)
  [ "$existing_context" = "$context" ] || die "session $SESSION uses a different working directory or account configuration; reconnect with its original --dir and --accounts-dir"
  exec tmux attach-session -t "=$SESSION"
fi
command -v "${planner_cmd[0]}" >/dev/null || die "$PLANNER is not installed"
check_auth "$PLANNER" || die "$PLANNER authentication unavailable; repair: $(repair_command "$PLANNER")"
mkdir -p "$HARNESS_DIR/runs"
prompt_args=(prompt "$HARNESS_DIR")
[ "$HANDS_OFF" = 0 ] || prompt_args+=(--hands-off)
planner_cmd+=("$(python3 "$SELF_DIR/lib/planner.py" "${prompt_args[@]}")")
# Claude's skills follow CLAUDE_CONFIG_DIR. Account-specific installs need the
# same shared protocol. Existing personal skills are never overwritten here.
if [ "$PLANNER" = claude ]; then
  owner_skills=(dispatch briefed-dispatch)
  if [ -f "$HOME/.agents/skills/dispatch-pixel/SKILL.md" ] \
      || [ -f "$HOME/.claude/skills/dispatch-pixel/SKILL.md" ]; then
    owner_skills+=(dispatch-pixel)
  fi
  for skill in "${owner_skills[@]}"; do
    if [ ! -e "$CLAUDE_DIR/skills/$skill" ]; then
      mkdir -p "$CLAUDE_DIR/skills"
      ln -s "$HARNESS_DIR/planner-skills/$skill" "$CLAUDE_DIR/skills/$skill"
    fi
  done
fi
keep_awake=()
command -v caffeinate >/dev/null 2>&1 && keep_awake=(caffeinate -i)
command_line=$(shell_args env "${CLEAR_AUTH[@]}" -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GH_CONFIG_DIR \
  "PATH=$PATH" "HARNESS_DIR=$HARNESS_DIR" "HARNESS_DETACH=1" \
  "HARNESS_OWNER=$OWNER" ${ACCOUNT_ENV[@]+"${ACCOUNT_ENV[@]}"} \
  ${keep_awake[@]+"${keep_awake[@]}"} "${planner_cmd[@]}")
echo "station: $SESSION | $STATION_DIR (detach with your tmux prefix, then d; default Ctrl-b)"
# Chain the option write before attaching, so another reconnect can verify cwd.
exec tmux new-session -d -s "$SESSION" -c "$STATION_DIR" "$command_line" \; \
  set-option -t "$SESSION" @dispatch-context "$context" \; attach-session -t "=$SESSION"
