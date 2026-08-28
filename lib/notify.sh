# shellcheck shell=bash
# Owner routing for the phone push in run-task.sh's stage(): which ntfy topics
# a handoff must reach. The push itself stays in stage(); this is only the
# routing, so quartermaster.sh's own nightly push keeps its separate curl.
#
# Sourced, never executed — like lib/common.sh, read from beside the caller,
# from the checkout and from the install. Safe under `set -u`: nothing here
# reads a variable it has not defaulted first. Bash 3.2-compatible: no
# associative arrays, indirect expansion only.
#
# Both functions print their answer and nothing else. A topic value is a
# secret (notify.conf.example says so) — neither function may end up in a
# log, and stage() sends its curl output to /dev/null.

# The env-var suffix for an owner's private topic: the owner uppercased with
# every character outside [A-Z0-9] replaced by `_` (angel -> ANGEL,
# angel.sole -> ANGEL_SOLE). Replaced, never stripped: two owners whose
# logins differ only in punctuation must not collide on one phone.
ntfy_owner_key() {  # $1 = owner login; empty (unowned) prints nothing, rc 0
  [ -n "${1:-}" ] || return 0
  local key
  # LC_ALL=C makes tr byte-wise: every byte the owner's login has that is not
  # ASCII [A-Z0-9] becomes exactly one `_`, whatever the machine's locale.
  key=$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9' '_')
  printf '%s\n' "$key"
}

# The topics a stage push must reach, one per line, owner first: the owner's
# own HARNESS_NTFY_TOPIC_<KEY> when set, then the global HARNESS_NTFY_TOPIC
# (the room feed every run shares). A topic equal to one already printed is
# printed once — the owner who is also the room gets one push, not two.
# Unowned, or an owner with no private topic configured, means global only;
# nothing configured prints nothing, which is how the push disables itself.
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
