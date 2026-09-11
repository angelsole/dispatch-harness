#!/usr/bin/env bash
# The dispatch station: a persistent Astra (Codex) or Claude planner.
#
# Usage:
#   station.sh [start] [--planner codex|claude] [--model ID] [--dir PATH]
#   station.sh setup         onboard this OS user: logins, skills, profile
#   station.sh doctor [--repo PATH] [--planner codex|claude]
#   station.sh login codex|claude|gh [--browser]
#   Add --host SSH_ALIAS to run a command on the Mini; the SSH user is the
#   identity there (for somebody else's station: --host NAME@mini).
#   --remote-harness PATH selects a non-default install on the SSH host.
#   --hands-off bypasses planner permission checks (Codex also disables its sandbox).
#   Available for start; it opens a separate session from the default mode.
#
# The station acts for the OS user running it. Credentials live in that user's
# own home (~/.claude, ~/.codex, ~/.config/gh); no config directory is
# re-exported and there is no --owner: another person's station is reached by
# SSHing in as that user.
#
# Codex defaults to gpt-6-astra; Claude defaults to fable. Each user/planner/
# model gets a separate tmux session. Re-running reattaches; the default detach
# binding is Ctrl-b d. macOS caffeinate keeps it awake.
# Logins prefer flows that work over SSH: codex and gh print a device code;
# claude stores a `claude setup-token` in ~/.claude/oauth-token (mode 600) —
# `login claude` explains that path first and offers the browser flow second.
# Doctor prints no credentials. --repo also checks origin access and runs that
# repo's configured PREFLIGHT_CMD, capped at 30 seconds; it runs no test gate.
#
# Env: DISPATCH_STATION_DIR (default: $HOME), DISPATCH_PLANNER (codex),
# DISPATCH_MODEL (provider default), HARNESS_DIR (the directory containing this script),
# CODEX_BIN / CLAUDE_BIN (from PATH). Remote defaults resolve on the remote host.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SELF_DIR/$(basename "$0")"
# A seat's first setup starts the service-owned shared script before its profile
# has HARNESS_DIR. The script location is therefore the installed runtime.
HARNESS_DIR="${HARNESS_DIR:-$SELF_DIR}"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

usage_error() { echo "station: $*" >&2; exit 2; }
die() { echo "station: $*" >&2; exit 1; }
# SSH and tmux both pass a command through a shell. Quote every argument with
# POSIX single quotes; never interpolate a directory, user or model as code.
shell_args() {
  local arg quote="'" escaped="'\\''"
  for arg in "$@"; do printf "'%s' " "${arg//$quote/$escaped}"; done
}

ACTION=start; LOGIN_PROVIDER=""; HOST=""; REMOTE_HARNESS=""; BROWSER=0
HANDS_OFF=0; BAD_OWNER=""
PLANNER="${DISPATCH_PLANNER:-codex}"; MODEL="${DISPATCH_MODEL:-}"
OWNER="$(id -un)"
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
    --host|--remote-harness|--planner|--model|--dir|--repo)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
      case "$1" in
        --host) HOST="$2" ;;
        --remote-harness) REMOTE_HARNESS="$2" ;;
        *) REMOTE_ARGS+=("$1" "$2") ;;
      esac
      case "$1" in
        --planner) PLANNER="$2" ;; --model) MODEL="$2" ;;
        --dir) STATION_DIR="$2" ;; --repo) REPO="$2" ;;
      esac
      shift ;;
    --owner)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "--owner needs a value"
      BAD_OWNER="$2"; shift ;;
    --browser) BROWSER=1; REMOTE_ARGS+=("$1") ;;
    --hands-off) HANDS_OFF=1; REMOTE_ARGS+=("$1") ;;
    -h|--help) harness_usage "$0"; exit 0 ;;
    *) usage_error "unknown option: $1 (see --help)" ;;
  esac
  shift
done
case "$PLANNER" in codex|claude) ;; *) usage_error "planner must be codex or claude" ;; esac
case "$MODEL" in *[!a-zA-Z0-9._-]*|-*) usage_error "invalid model ID" ;; esac
if [ "$ACTION" = login ]; then
  case "$LOGIN_PROVIDER" in codex|claude|gh) ;; *) usage_error "login needs codex, claude or gh" ;; esac
fi
[ "$BROWSER" = 0 ] || [ "$ACTION" = login ] || usage_error "--browser is only for login"
[ -z "$REPO" ] || [ "$ACTION" = doctor ] || usage_error "--repo is only for doctor"
[ "$HANDS_OFF" = 0 ] || [ "$ACTION" = start ] \
  || usage_error "--hands-off is only for start"

# A seat is an OS user; a station belongs to whoever is logged in. The old
# --owner selected a credentials directory under a shared account — that model
# is gone, so point the operator at SSH instead of accepting the flag.
[ -z "$BAD_OWNER" ] \
  || usage_error "--owner is gone: a station belongs to the OS user that runs it. SSH in as that user instead: ssh $BAD_OWNER@${HOST:-$(hostname -s)}"

if [ -n "$HOST" ]; then
  case "$HOST" in -*|*[!a-zA-Z0-9_.@:-]*) usage_error "invalid SSH host" ;; esac
  if [ -n "$REMOTE_HARNESS" ]; then
    case "$REMOTE_HARNESS" in /*) ;; *) usage_error "--remote-harness must be an absolute remote path" ;; esac
    remote_script="$(shell_args "$REMOTE_HARNESS/station.sh")"
    remote_cmd="exec bash $remote_script $(shell_args ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"})"
  else
    remote_cmd='IFS= read -r HARNESS_DIR < "$HOME/.claude/harness-dir" || { echo "station: shared harness is not configured; run its station.sh setup by absolute path or pass --remote-harness" >&2; exit 1; }; case "$HARNESS_DIR" in /*) ;; *) echo "station: invalid shared harness path" >&2; exit 1;; esac; export HARNESS_DIR; exec bash "$HARNESS_DIR/station.sh" '
    remote_cmd+="$(shell_args ${REMOTE_ARGS[@]+"${REMOTE_ARGS[@]}"})"
  fi
  # No login shell: startup files may start a program or change identities.
  # station.sh supplies the usual macOS binary directories itself.
  ssh_args=(-o ConnectTimeout=8 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  if [ "$ACTION" = doctor ]; then ssh_args+=(-o BatchMode=yes); else ssh_args+=(-t); fi
  exec ssh "${ssh_args[@]}" "$HOST" "$remote_cmd"
fi
[ -z "$REMOTE_HARNESS" ] || usage_error "--remote-harness needs --host"

# Non-interactive SSH often has only /usr/bin:/bin:/usr/sbin:/sbin. Preserve
# explicit PATH choices and append the common user/Homebrew install locations.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
CODEX_BIN="${CODEX_BIN:-codex}"; CLAUDE_BIN="${CLAUDE_BIN:-claude}"
case "$HARNESS_DIR" in /*) ;; *) HARNESS_DIR="$PWD/$HARNESS_DIR" ;; esac
CLAUDE_DIR="$HOME/.claude"
export HARNESS_DIR HARNESS_OWNER="$OWNER"
# The runtime is shared with the crew through a Unix group.
umask 002

# Run a command with ambient auth cleared down to this user's own credentials:
# the same environment the planner itself runs under — inherited API keys and
# config-dir overrides from an old shared-account shell are dropped, then the
# user's own token file (if any) is applied.
as_own_auth() (
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
    CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY OPENAI_BASE_URL CODEX_ACCESS_TOKEN \
    GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
    HARNESS_CODEX_HOME_FALLBACK CLAUDE_CONFIG_DIR CODEX_HOME GH_CONFIG_DIR
  harness_oauth_token
  "$@"
)
repair_command() { shell_args "$SELF" login "$1"; }
# Timeout wraps the actual subprocess, not a shell function.
check_auth() {
  case "$1" in
    codex) as_own_auth with_timeout 20 "$CODEX_BIN" login status >/dev/null 2>&1 ;;
    claude) as_own_auth with_timeout 20 "$CLAUDE_BIN" auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1 ;;
    gh) as_own_auth with_timeout 20 gh auth status --hostname github.com >/dev/null 2>&1 ;;
  esac
}

# The headless-friendly Claude login: a long-lived token minted by
# `claude setup-token` on a machine with a browser, stored mode 600. The paste
# is never echoed and the token never appears in an argument or a log line.
claude_token_login() {
  echo "station: Claude login for an SSH-only seat is a token file:"
  echo "  1. on a machine with a browser, run:  claude setup-token"
  echo "  2. its output goes into ~/.claude/oauth-token (mode 600);"
  echo "     the station and seat_exec export it as CLAUDE_CODE_OAUTH_TOKEN"
  printf '%s' "station: paste the token now (it is not echoed; leave blank to skip): "
  IFS= read -rs token || token=""
  echo
  [ -n "$token" ] || { echo "station: no token entered — for the browser flow instead, run: station.sh login claude --browser"; return 1; }
  (umask 077; mkdir -p "$CLAUDE_DIR"; printf '%s\n' "$token" > "$CLAUDE_DIR/oauth-token") || return 1
  chmod 600 "$CLAUDE_DIR/oauth-token" || return 1
  echo "station: token stored in $CLAUDE_DIR/oauth-token (mode 600)"
}

login_provider() {  # $1 = provider, $2 = use the browser flow
  local provider="$1" browser="${2:-0}"
  echo "station: login $provider for $OWNER"
  case "$provider" in
    codex)
      command -v "$CODEX_BIN" >/dev/null || die "codex is not installed"
      if [ "$browser" = 1 ]; then
        as_own_auth "$CODEX_BIN" login || return 1
      else
        echo "Open the printed link on your own device and enter its code."
        echo "If device login is disabled, enable it in ChatGPT settings or use --browser."
        as_own_auth "$CODEX_BIN" login --device-auth || return 1
      fi ;;
    claude)
      if [ "$browser" = 1 ]; then
        as_own_auth "$CLAUDE_BIN" auth login --claudeai || return 1
      else
        claude_token_login || return 1
      fi ;;
    gh)
      if [ "$browser" = 1 ]; then
        as_own_auth gh auth login --hostname github.com --git-protocol https --web || return 1
      else
        as_own_auth gh auth login --hostname github.com --git-protocol https || return 1
      fi ;;
  esac
  check_auth "$provider" || { echo "station: login did not establish $provider authentication" >&2; return 1; }
  echo "station: $provider authentication configured for $OWNER"
}

if [ "$ACTION" = login ]; then
  login_provider "$LOGIN_PROVIDER" "$BROWSER"
  exit 0
fi

# One line, in the first shell profile that exists, and only ever one line:
# repeated setup runs replace it rather than stacking.
write_profile_line() {
  local profile="" tmp candidate pointer="$CLAUDE_DIR/harness-dir"
  for candidate in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$candidate" ] && { profile="$candidate"; break; }
  done
  [ -n "$profile" ] || profile="$HOME/.zprofile"
  tmp="$profile.dispatch-tmp"
  grep -v '^export HARNESS_DIR=' "$profile" > "$tmp" 2>/dev/null || true
  printf 'export HARNESS_DIR=%q\n' "$HARNESS_DIR" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$profile"
  tmp="$pointer.dispatch-tmp"
  (umask 077; printf '%s\n' "$HARNESS_DIR" > "$tmp")
  mv "$tmp" "$pointer"
  echo "[ok] step 5/5: HARNESS_DIR set in $(basename "$profile")"
}

if [ "$ACTION" = setup ]; then
  # Check the shared installation before asking anyone to sign in. This flow
  # is personal onboarding; installing/updating binaries stays with the host.
  for bin in git bash jq gh "$CLAUDE_BIN" "$CODEX_BIN" tmux; do
    command -v "$bin" >/dev/null 2>&1 || die "missing $bin; ask the station operator to install it on this machine"
  done
  [ -x "$HARNESS_DIR/run-task.sh" ] || die "shared harness is missing; ask the station operator to run install.sh on this machine"
  [ -d "$STATION_DIR" ] || die "working directory missing: $STATION_DIR"
  echo "station: setting up $OWNER on this machine"
  if [ -f "$CLAUDE_DIR/oauth-token" ]; then
    if [ "$(harness_file_mode "$CLAUDE_DIR/oauth-token" 2>/dev/null)" = 600 ]; then
      echo "[ok] step 1/5: claude token file present ($CLAUDE_DIR/oauth-token)"
    else
      echo "[setup] step 1/5: $CLAUDE_DIR/oauth-token must be mode 600 — fix it (chmod 600) or remove it"
    fi
  elif check_auth claude; then
    echo "[ok] step 1/5: claude is already signed in"
  else
    echo "[setup] step 1/5: claude needs a login token"
    claude_token_login || echo "[setup] claude token skipped — re-run setup to add it later"
  fi
  step=2
  for provider in gh codex; do
    if check_auth "$provider"; then
      echo "[ok] step $step/5: $provider is already signed in"
    else
      echo "[setup] step $step/5: $provider needs your sign-in; use your own account in the device flow."
      login_provider "$provider" || die "$provider setup stopped; re-run setup to continue (completed logins are kept)"
    fi
    step=$((step+1))
  done
  owner_skills=(dispatch briefed-dispatch)
  [ ! -f "$HARNESS_DIR/planner-skills/dispatch-pixel/SKILL.md" ] || owner_skills+=(dispatch-pixel)
  for skill in "${owner_skills[@]}"; do
    [ -f "$HARNESS_DIR/planner-skills/$skill/SKILL.md" ] \
      || die "shared planner skill $skill is missing; ask the station operator to re-run install.sh"
  done
  mkdir -p "$CLAUDE_DIR/skills"
  for skill in "${owner_skills[@]}"; do
    [ -e "$CLAUDE_DIR/skills/$skill" ] || ln -s "$HARNESS_DIR/planner-skills/$skill" "$CLAUDE_DIR/skills/$skill"
  done
  echo "[ok] step 4/5: planner skills linked into $CLAUDE_DIR/skills"
  write_profile_line
  echo "station: setup complete for $OWNER; running doctor"
  ACTION=doctor
fi

if [ "$ACTION" = doctor ]; then
  failures=0
  good() { printf '[ok] %s\n' "$*"; }
  bad() { printf '[fail] %s\n' "$*"; failures=$((failures+1)); }
  echo "station: $OWNER | planner $PLANNER | $STATION_DIR"
  for bin in git bash jq gh "$CLAUDE_BIN" "$CODEX_BIN" tmux; do
    if command -v "$bin" >/dev/null 2>&1; then good "tool $bin"; else bad "missing tool $bin"; fi
  done
  [ -d "$STATION_DIR" ] && good "working directory" || bad "working directory missing"
  [ -x "$HARNESS_DIR/run-task.sh" ] && good "harness installed" || bad "harness missing: run install.sh on this machine"
  for provider in codex claude gh; do
    if check_auth "$provider"; then good "$provider authentication configured"
    else bad "$provider authentication unavailable; repair: $(repair_command "$provider")"; fi
  done
  # login status is a local credential check, not proof of model entitlement.
  if command -v "$CODEX_BIN" >/dev/null 2>&1; then
    as_own_auth "$CODEX_BIN" --version
    echo "[info] Model access is checked when the planner starts."
  fi
  for skill in dispatch briefed-dispatch; do
    if [ -f "$CLAUDE_DIR/skills/$skill/SKILL.md" ] || [ -f "$HOME/.agents/skills/$skill/SKILL.md" ]; then
      good "planner skill $skill"
    else
      bad "planner skill $skill missing; re-run station.sh setup on this machine"
    fi
  done
  if [ -n "$REPO" ]; then
    if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
      if as_own_auth with_timeout 20 env GIT_TERMINAL_PROMPT=0 git -C "$REPO" ls-remote origin HEAD >/dev/null 2>&1; then
        good "repository origin reachable"
      else bad "repository origin unavailable (SSH or GitHub credentials/network)"; fi
      # Pins are trusted local shell configuration, as in run-task.sh.
      # shellcheck source=repos.conf.sh
      . "$SELF_DIR/repos.conf.sh"
      repo_config "$REPO"
      if [ -n "${PREFLIGHT_CMD:-}" ]; then
        if (cd "$REPO" && as_own_auth with_timeout 30 bash -c "$PREFLIGHT_CMD") >/dev/null 2>&1; then
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
SESSION="dispatch-$OWNER-$PLANNER-${MODEL:-default}"
[ "$HANDS_OFF" = 0 ] || SESSION="$SESSION-hands-off"
SESSION="${SESSION//./_}"
context=$(shell_args "$STATION_DIR" "$PLANNER")
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  existing_context=$(tmux show-options -qv -t "$SESSION" @dispatch-context)
  [ "$existing_context" = "$context" ] \
    || die "session $SESSION was started with a different working directory (or an older station.sh); reattach manually or tmux kill-session -t $SESSION"
  exec tmux attach-session -t "=$SESSION"
fi
command -v "${planner_cmd[0]}" >/dev/null || die "$PLANNER is not installed"
check_auth "$PLANNER" || die "$PLANNER authentication unavailable; repair: $(repair_command "$PLANNER")"
mkdir -p "$HARNESS_DIR/runs"
prompt_args=(prompt "$HARNESS_DIR")
[ "$HANDS_OFF" = 0 ] || prompt_args+=(--hands-off)
planner_cmd+=("$(python3 "$SELF_DIR/lib/planner.py" "${prompt_args[@]}")")
# Claude's skills follow its config dir, which is this user's own ~/.claude.
# Existing personal skills are never overwritten here.
if [ "$PLANNER" = claude ]; then
  owner_skills=(dispatch briefed-dispatch)
  if [ -f "$HOME/.agents/skills/dispatch-pixel/SKILL.md" ] \
      || [ -f "$CLAUDE_DIR/skills/dispatch-pixel/SKILL.md" ] \
      || [ -f "$HARNESS_DIR/planner-skills/dispatch-pixel/SKILL.md" ]; then
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
# tmux runs this string through a shell. The prelude drops every ambient auth
# variable an old shared-account shell may have left in the server, then
# sources the shared library so the user's own token file (mode 600) is
# exported, then sets the run environment and replaces the shell with the
# planner. Unset first, source second: the token export must survive.
command_line="unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY OPENAI_BASE_URL CODEX_ACCESS_TOKEN \
GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
HARNESS_CODEX_HOME_FALLBACK CLAUDE_CONFIG_DIR CODEX_HOME GH_CONFIG_DIR; \
. $(shell_args "$SELF_DIR/lib/common.sh"); umask 002; \
export PATH=$(shell_args "$PATH") HARNESS_DIR=$(shell_args "$HARNESS_DIR") \
HARNESS_DETACH=1 HARNESS_OWNER=$(shell_args "$OWNER"); \
exec $(shell_args ${keep_awake[@]+"${keep_awake[@]}"} "${planner_cmd[@]}")"
echo "station: $SESSION | $STATION_DIR (detach with your tmux prefix, then d; default Ctrl-b)"
# Chain the option write before attaching, so another reconnect can verify cwd.
exec tmux new-session -d -s "$SESSION" -c "$STATION_DIR" "$command_line" \; \
  set-option -t "$SESSION" @dispatch-context "$context" \; attach-session -t "=$SESSION"
