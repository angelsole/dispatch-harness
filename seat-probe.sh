#!/usr/bin/env bash
# Report one seat's login state, from inside the seat.
#
# A home directory is 0700, so nobody but the seat itself can read its login
# state — the Linear bridge and `dispatch stations` run this through seat_exec,
# which is the only door the sudoers fragment opens for them. Output is one
# key=value line per credential:
#
#   claude=inside|outside|missing    ~/.claude
#   codex=inside|outside|missing     ~/.codex
#   gh=inside|outside|missing        ~/.config/gh
#   token=ok|absent|badmode          ~/.claude/oauth-token
#
# "outside" is a directory that resolves out of the seat's home — the symlink
# shape that would silently borrow another person's auth. Exit status is always
# 0: a missing login is an expected state the caller words as "needs setup",
# not a probe failure.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

# Physical resolution, both sides: a symlinked home must not make a linked
# credential directory look inside (or vice versa).
dir_state() {  # $1 = directory; prints inside|outside|missing
  local phys home
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    printf 'missing\n'
    return 0
  fi
  phys=$(cd "$1" 2>/dev/null && pwd -P) || { printf 'outside\n'; return 0; }
  home=$(cd "$HOME" 2>/dev/null && pwd -P) || { printf 'outside\n'; return 0; }
  case "$phys/" in
    "$home"/*) printf 'inside\n' ;;
    *)         printf 'outside\n' ;;
  esac
}

token_state() {  # prints ok|absent|badmode
  local file="$HOME/.claude/oauth-token" mode
  [ -f "$file" ] || { printf 'absent\n'; return 0; }
  mode=$(harness_file_mode "$file" 2>/dev/null) || mode=""
  if [ "$mode" = 600 ]; then
    printf 'ok\n'
  else
    printf 'badmode\n'
  fi
}

printf 'claude=%s\n' "$(dir_state "$HOME/.claude")"
printf 'codex=%s\n'  "$(dir_state "$HOME/.codex")"
printf 'gh=%s\n'     "$(dir_state "$HOME/.config/gh")"
printf 'token=%s\n'  "$(token_state)"
exit 0
