# shellcheck shell=bash
# ntfy routing for run-task.sh's stage(): which topics a stage handoff reaches.
#
# Sourced, never executed, like lib/common.sh. Bash 3.2 and `set -u` safe: no
# associative arrays, indirect expansion only, every read defaulted. A topic
# value is a secret (notify.conf.example) — these functions print one, so no
# caller may route their output anywhere but the curl it builds.

# The env-var suffix for an owner's private topic: the owner uppercased with
# every character outside [A-Z0-9] replaced by `_` (angel.sole -> ANGEL_SOLE).
# Replaced, never stripped — two logins that differ only in punctuation must
# not collide on one phone.
ntfy_owner_key() {  # $1 = owner login; empty (unowned) prints nothing, rc 0
  [ -n "${1:-}" ] || return 0
  local key
  # LC_ALL=C keeps tr byte-wise: the fold is the same under every locale.
  key=$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9' '_')
  printf '%s\n' "$key"
}

# The topics a stage push must reach, one per line, owner first: the owner's
# own HARNESS_NTFY_TOPIC_<KEY>, then the global HARNESS_NTFY_TOPIC (the room
# feed). Set-but-empty counts as unset, matching how the global disables the
# push. Duplicates collapse, so an owner whose topic is the room feed is
# pushed to once. Nothing configured prints nothing.
ntfy_targets() {  # $1 = the run's pinned owner; always returns 0
  local key var topic owner_topic=""
  if [ -n "${1:-}" ]; then
    key=$(ntfy_owner_key "$1")
    var="HARNESS_NTFY_TOPIC_$key"
    owner_topic="${!var:-}"
    [ -n "$owner_topic" ] && printf '%s\n' "$owner_topic"
  fi
  topic="${HARNESS_NTFY_TOPIC:-}"
  if [ -n "$topic" ] && [ "$topic" != "$owner_topic" ]; then
    printf '%s\n' "$topic"
  fi
  return 0
}
