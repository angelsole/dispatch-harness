#!/usr/bin/env bash
# Live dispatch-harness feedback for the Claude Code statusline: one line per
# active run — run id, which model is working, what it is doing right now,
# ±lines so far, and elapsed minutes.
#
# Claude Code pipes the session JSON on stdin and renders every stdout line as
# one statusline row. Wire it via ~/.claude/settings.json (install.sh offers to
# do it for you):
#   "statusLine": {"type": "command", "command": "~/.claude/harness/statusline.sh"}
#
# Usage:
#   statusline.sh              cwd · branch · model, then one line per active run
#   statusline.sh --runs-only  only the run lines — for appending to a statusline
#                              you already have. Reads no stdin, so it never
#                              competes with your script for the session JSON.
#
# Env:
#   HARNESS_DIR  where runs live (default: ~/.claude/harness)
#   NO_COLOR     set to any value to drop the ANSI colors
#
# Finished runs (stage `done:*`) and runs whose status has not moved in 6h are
# hidden: the statusline shows what is live, nothing else.
set -u

_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
unset _COMMON_LIB_PATH
HARNESS_STALE_SECS="${HARNESS_STALE_SECS:-21600}"   # 6h — older status = dead run
HARNESS_GIT_TIMEOUT_SECS=2                            # statusline git calls stay prompt-safe

if [ -n "${NO_COLOR:-}" ]; then
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''
  C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
fi

usage() { harness_usage "$0"; }

# --- stage text -> actor -------------------------------------------------------
# CONTRACT: this maps the stage strings written by run-task.sh's stage() (and
# sync-pr.sh's) onto the model/agent doing that work. It is a prefix match on
# the stage TEXT — renaming a stage literal silently degrades every statusline
# on the machine, so the mirrored comment at run-task.sh's stage() points back
# here, and tests/statusline.test.sh asserts every literal in both scripts maps
# to a known actor (never the "?" fallback). Add the mapping in the same commit
# as any new stage string.
#
# The vocabulary itself now lives in wall/stage-vocab.json, which wall/server.js
# reads and docs/wall-contract.md describes. These arms stay hardcoded on
# purpose: a statusline re-renders on every prompt and must not pay for a jq
# read of a table to do it. tests/stage-vocab.test.sh drives harness_actor with
# every row in that file and fails the moment the two disagree — including the
# colour — so the copy is checked rather than trusted.
harness_actor() {  # $1 = stage text -> sets HARNESS_ACTOR + HARNESS_ACTOR_COLOR
  case "$1" in
    waiting*)                  HARNESS_ACTOR='needs input'; HARNESS_ACTOR_COLOR="$C_RED" ;;
    implementing*|resuming*)   HARNESS_ACTOR='Opus';        HARNESS_ACTOR_COLOR="$C_BLUE" ;;
    'review skipped'*)         HARNESS_ACTOR='skipped';     HARNESS_ACTOR_COLOR="$C_DIM" ;;
    # The creative harness's rounds, carried here ahead of re-unifying the two
    # walls: nothing in this repo emits them yet, and a shared vocabulary is
    # only shared if both copies already know the whole of it. Above the review
    # arms because the table hands every `visual *` stage to these rows, and the
    # Claude one leads for the same reason its code path does — a visual fix
    # that fell through to the Claude tier is not Codex's work.
    'visual fix'*Claude*)      HARNESS_ACTOR='Claude';      HARNESS_ACTOR_COLOR="$C_BLUE" ;;
    'visual fix'*Codex*)       HARNESS_ACTOR='Codex';       HARNESS_ACTOR_COLOR="$C_GREEN" ;;
    'visual gate'*)            HARNESS_ACTOR='visual';      HARNESS_ACTOR_COLOR="$C_YELLOW" ;;
    'review — Codex unavailable'*|*'— Claude reviewer'*) \
                               HARNESS_ACTOR='Claude';      HARNESS_ACTOR_COLOR="$C_BLUE" ;;
    # Written after the LAST tier gave up, so it is nobody's work in progress —
    # and it sits above the greedy arm below, which used to catch it and put
    # Codex's name on a failure Codex may never have been part of.
    'review failed silently'*) HARNESS_ACTOR='unreviewed';  HARNESS_ACTOR_COLOR="$C_RED" ;;
    review*|fix*)              HARNESS_ACTOR='Codex';       HARNESS_ACTOR_COLOR="$C_GREEN" ;;
    # The third-vendor trajectory score. It is not one of the pipeline's models
    # and it decides nothing, so it gets a name and no neon of its own.
    verify*)                   HARNESS_ACTOR='verifier';    HARNESS_ACTOR_COLOR="$C_DIM" ;;
    'test gate'*' skipped'*)   HARNESS_ACTOR='skipped';     HARNESS_ACTOR_COLOR="$C_DIM" ;;
    'test gate'*)              HARNESS_ACTOR='gate';        HARNESS_ACTOR_COLOR="$C_YELLOW" ;;
    'ticket sync'*)            HARNESS_ACTOR='ticket';      HARNESS_ACTOR_COLOR="$C_MAGENTA" ;;
    push*)                     HARNESS_ACTOR='PR';          HARNESS_ACTOR_COLOR="$C_MAGENTA" ;;
    demo*)                     HARNESS_ACTOR='demo';        HARNESS_ACTOR_COLOR="$C_MAGENTA" ;;
    setup*|installing*)        HARNESS_ACTOR='setup';       HARNESS_ACTOR_COLOR="$C_CYAN" ;;
    deferred:*)                HARNESS_ACTOR='deferred';    HARNESS_ACTOR_COLOR="$C_YELLOW" ;;
    'base sync'*|'already up'*) HARNESS_ACTOR='sync';       HARNESS_ACTOR_COLOR="$C_CYAN" ;;
    'sync failed'*)            HARNESS_ACTOR='failed';      HARNESS_ACTOR_COLOR="$C_RED" ;;
    done:*)                    HARNESS_ACTOR='done';        HARNESS_ACTOR_COLOR="$C_DIM" ;;
    *)                         HARNESS_ACTOR='?';           HARNESS_ACTOR_COLOR="$C_DIM" ;;
  esac
}

# Cap a git call: the statusline reruns constantly, and a locked or huge repo
# must never stall the prompt. It is literally the wrapper run-task.sh uses, so
# it is now that one — kept under this file's own name the way janitor.sh keeps
# capped() over capacity.sh's capacity_capped().
harness_timeout() { with_timeout "$@"; }  # $1 = seconds, rest = command + args

harness_first_line() {  # $1 = file -> its first line, empty when absent
  local v=''
  [ -f "$1" ] && { IFS= read -r v < "$1" || true; }
  printf '%s' "$v"
}

# Live diff size of a run's branch. Tolerates a worktree that was cleaned up or
# does not exist yet — an absent number is better than a stalled statusline.
harness_diffstat() {  # $1 = worktree, $2 = base ref -> "+N-M" or nothing
  local out=''
  [ -n "$1" ] && [ -n "$2" ] && [ -d "$1" ] || return 0
  out=$(harness_timeout "$HARNESS_GIT_TIMEOUT_SECS" \
    git -C "$1" --no-optional-locks diff --shortstat "$2" 2>/dev/null) || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^insertion/) ins = $(i - 1)
      if ($i ~ /^deletion/)  del = $(i - 1)
    }
  } END { printf "+%d-%d", ins + 0, del + 0 }'
}

harness_run_lines() {
  local runs="$HARNESS_DIR/runs" now name dir ts stagetext started act wt base diff line
  [ -d "$runs" ] || return 0
  now=$(date +%s)
  # Newest-first, like status.sh: run-id dir names are ticket IDs / adhoc slugs
  # (no whitespace), so word-splitting ls -t output is safe here.
  # shellcheck disable=SC2045
  for name in $(ls -t "$runs" 2>/dev/null); do
    dir="$runs/$name"
    [ -f "$dir/status" ] || continue
    ts=''; stagetext=''
    read -r ts stagetext < "$dir/status" || true
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    case "$stagetext" in done:*|'') continue ;; esac
    [ "$((now - ts))" -le "$HARNESS_STALE_SECS" ] || continue

    started=$(harness_first_line "$dir/started")
    case "$started" in ''|*[!0-9]*) started="$ts" ;; esac

    harness_actor "$stagetext"
    # Elapsed is the run's total; for a paused run the number that actually
    # matters is how long it has been blocked, so ⏸ counts from the stage.
    if [ "$HARNESS_ACTOR" = 'needs input' ]; then
      printf '%s⏸ %s needs input (%dm)%s\n' \
        "$C_RED" "$name" "$(((now - ts) / 60))" "$C_RESET"
      continue
    fi

    act=$(harness_first_line "$dir/activity")
    wt=$(harness_first_line "$dir/worktree")
    base=$(harness_first_line "$dir/base")
    diff=$(harness_diffstat "$wt" "$base")

    line="${C_BOLD}${name}${C_RESET} ${HARNESS_ACTOR_COLOR}${HARNESS_ACTOR}${C_RESET}"
    [ -n "$act" ] && line="$line ${C_DIM}${act:0:60}${C_RESET}"
    [ -n "$diff" ] && line="$line ${C_DIM}${diff}${C_RESET}"
    printf '⏵ %s %s%dm%s\n' "$line" "$C_DIM" "$(((now - started) / 60))" "$C_RESET"
  done
}

# First line of the default mode: the plain session context a statusline is
# expected to carry, so wiring this script needs no second command.
harness_header() {
  local json='' dir='' branch='' model='' line
  [ -t 0 ] || json=$(cat)
  if [ -n "$json" ]; then
    dir=$(printf '%s' "$json" | jq -r '.workspace.current_dir // empty' 2>/dev/null || true)
    model=$(printf '%s' "$json" | jq -r '.model.display_name // empty' 2>/dev/null || true)
  fi
  [ -n "$dir" ] || dir="$PWD"
  branch=$(harness_timeout "$HARNESS_GIT_TIMEOUT_SECS" \
    git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=''

  line="${C_CYAN}$(basename "$dir")${C_RESET}"
  [ -n "$branch" ] && line="$line ${C_DIM}·${C_RESET} ${C_MAGENTA}${branch}${C_RESET}"
  [ -n "$model" ] && line="$line ${C_DIM}· ${model}${C_RESET}"
  printf '%s\n' "$line"
}

harness_main() {
  local runs_only=0
  case "${1:-}" in
    --runs-only) runs_only=1 ;;
    -h|--help)   usage; exit 0 ;;
    '')          ;;
    *)           echo "unknown option: $1" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
  [ "$runs_only" = 1 ] || harness_header
  harness_run_lines
}

# status.sh --watch sources this file for harness_actor and the colors; only a
# direct invocation renders anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then harness_main "$@"; fi
