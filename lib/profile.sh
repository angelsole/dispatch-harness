# shellcheck shell=bash
# The pipeline's named extension points, and the loader that fills them.
#
# A hook is a name; an implementation is a shell function registered against it.
# run-task.sh registers the core ones; a profile under profiles/<name>/ registers
# its own by defining <name>_<hook>. The six hooks are:
#
#   implementer_env      exports applied INSIDE the implementer's subshell only
#   post_gate            a stage between test gate #1 and the review
#   review_prompt_extra  text appended to the reviewer's prompt
#   pr_body_sections     sections appended to the PR body
#   result_json_extra    objects merged into result.json
#   outcome_status       a run status the §6 ladder may end on
#
# Implementations run in registration order and must not depend on each other.
# A hook nothing registers produces nothing at all — no key, no line, no stage —
# which is what keeps a run without profiles byte-identical to one from before
# any of this existed.
#
# HARNESS_HOOKS and HARNESS_ACTIVE_PROFILES are outputs read by the sourcing
# script, which shellcheck cannot see from here.
# shellcheck disable=SC2034

HARNESS_HOOKS="implementer_env post_gate review_prompt_extra pr_body_sections result_json_extra outcome_status"

# Which profiles this run loaded, space-separated. Empty on every ordinary run.
HARNESS_ACTIVE_PROFILES=""

# bash 3.2 is the only bash on stock macOS and has no associative arrays, so the
# registry is one dynamically-named variable per hook.
hook_register() {  # $1 = hook name, $2 = function name
  eval "_HARNESS_HOOK_$1=\"\${_HARNESS_HOOK_$1:-} \$2\""
}

# Registered names that are actually defined functions right now. Core hooks are
# registered before their definitions are reached, and a profile is free to
# implement only the hooks it cares about, so the filter is the contract.
hook_impls() {  # $1 = hook name
  local list fn
  eval "list=\"\${_HARNESS_HOOK_$1:-}\""
  # shellcheck disable=SC2086  # the registry is a space-separated list of names
  for fn in $list; do
    declare -F "$fn" >/dev/null || continue
    printf '%s\n' "$fn"
  done
}

# Every implementation, in the caller's own shell — so a hook can set variables,
# move the stage and write files. Stops at the first one that fails and returns
# its status, which is what lets implementer_env abort a spawn the way a missing
# credential always has.
hook_run() {  # $1 = hook name, rest = arguments
  local hook="$1" fn rc=0
  shift
  for fn in $(hook_impls "$hook"); do
    "$fn" "$@" || { rc=$?; break; }
  done
  return "$rc"
}

# The first implementation to return 0 claims the decision; 1 when none does.
hook_claim() {  # $1 = hook name, rest = arguments
  local hook="$1" fn
  shift
  for fn in $(hook_impls "$hook"); do
    "$fn" "$@" && return 0
  done
  return 1
}

# Every implementation's JSON object, merged left to right. Prints nothing when
# no implementation produced anything, so the caller can tell "no profile had
# anything to add" from "a profile added an empty object".
hook_json() {  # $1 = hook name
  local hook="$1" fn out merged=""
  for fn in $(hook_impls "$hook"); do
    out=$("$fn") || continue
    [ -n "$out" ] || continue
    if [ -z "$merged" ]; then
      merged="$out"
    else
      merged=$(printf '%s\n%s\n' "$merged" "$out" | jq -c -s 'reduce .[] as $o ({}; . + $o)') \
        || return 0
    fi
  done
  printf '%s' "$merged"
}

# Load the profiles that apply to this run's target repo. A profile is a
# directory holding activate.sh (a predicate: exit 0 to apply) and profile.sh
# (the implementations). The predicate is sourced in a subshell, because
# deciding whether a profile applies must not be able to change the run it is
# deciding about; profile.sh is sourced into the caller's shell, because its
# hooks are.
harness_load_profiles() {  # $1 = target repo path, $2 = the directory profiles live in
  local repo="$1" root="$2" dir name hook
  HARNESS_ACTIVE_PROFILES=""
  [ "${HARNESS_PROFILES:-1}" != 0 ] || return 0
  [ -d "$root" ] || return 0
  for dir in "$root"/*/; do
    [ -r "$dir/activate.sh" ] && [ -r "$dir/profile.sh" ] || continue
    name=$(basename "$dir")
    # shellcheck source=/dev/null
    ( HARNESS_PROFILE_DIR="${dir%/}"; . "$dir/activate.sh" "$repo" ) || continue
    HARNESS_PROFILE_DIR="${dir%/}"
    # shellcheck source=/dev/null
    . "$dir/profile.sh"
    for hook in $HARNESS_HOOKS; do
      hook_register "$hook" "${name}_${hook}"
    done
    HARNESS_ACTIVE_PROFILES="$HARNESS_ACTIVE_PROFILES $name"
    echo "[harness] profile: $name (from $HARNESS_PROFILE_DIR)"
  done
}
