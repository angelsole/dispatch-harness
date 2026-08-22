# shellcheck shell=bash
# The plumbing every harness script needs, in one place.
#
# Sourced, never executed — like mirror.sh and capacity.sh, and by the same
# rule: each script reads it from beside itself, so it works from the checkout
# and from the install (install.sh ships lib/ into HARNESS_DIR). Safe under
# `set -u`: nothing here reads a variable it has not defaulted first.
#
# What lives here is what was provably copied: the same line in sixteen files,
# the same function body in three, a --help that every script re-implemented
# with a different hardcoded line range. What did NOT come here is fail(): its
# five callers mean five different things by it (a run that must write a
# result, a sync that must move a stage, a plain exit), and one shared fail()
# would have to lie to at least four of them.
#
# HARNESS_DIR and the knob defaults below are outputs read by the sourcing
# script, which shellcheck cannot see from here.
# shellcheck disable=SC2034

# Where runs, config and the installed scripts live. Sixteen scripts declared
# this same line; they now all get it from here.
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"

# The implementer knobs' defaults. Two scripts have to agree on them —
# run-task.sh pins them into the run dir at first dispatch, sync-pr.sh falls
# back to them when it re-runs the implementer on a PR whose run dir predates
# the pin — so they are defined once. Explicit model IDs, never aliases: "opus"
# silently changed meaning the day Opus 5 shipped, which is exactly the
# condition drift the pinning exists to stop.
#
# Deliberately not HARNESS_*: in this repo that prefix means "an environment
# knob a user may set", and these two are constants the environment cannot
# reach. IMPLEMENTER_MODEL / IMPLEMENTER_EFFORT are the knobs; these are only
# what they fall back to.
DEFAULT_IMPLEMENTER_MODEL="claude-opus-5"
DEFAULT_IMPLEMENTER_EFFORT="high"

# Cap a long-running child. macOS ships no timeout(1), so fall back to a
# perl alarm wrapper (SIGALRM survives exec and kills the child after N secs).
with_timeout() {  # $1 = seconds, rest = command + args
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# A script's header comment IS its --help, read back at runtime so the two can
# never drift. Every caller used to carry its own `sed -n 'A,Bp' "$0"`, and a
# line added to or removed from a header silently truncated — or over-ran —
# that script's help without anything failing.
#
# By default the whole header is the help: everything from the line after the
# shebang up to the first line that is not a comment. A script whose help is
# only part of its header fences that part off, and the fence lines themselves
# are never printed:
#
#   # >>> --help >>>
#   #   thing.sh --flag   what it does
#   # <<< --help <<<
#
# Printed to stdout; the redirection and the exit status stay with the caller,
# because they differ (install.sh's --help succeeds, schedule.sh's usage is an
# error message on stderr that exits 2).
harness_usage() {  # $1 = the script, usually "$0"; prints its header comment
  awk '
    NR == 1 { next }                              # the shebang is not documentation
    $0 == "# >>> --help >>>" { n = 0; next }      # anything before this was preamble
    $0 == "# <<< --help <<<" { exit }
    !/^#/ { exit }                                # the header ends at the first code line
    { line = $0; sub(/^#/, "", line); sub(/^ /, "", line); buf[++n] = line }
    END { for (i = 1; i <= n; i++) print buf[i] }
  ' "$1"
}

# Where a run built its work. run-task.sh writes the path into the run dir as
# soon as the worktree exists; result.json is the fallback for runs that
# predate that file. Prints nothing when neither answers — the callers disagree
# about what that means (preview.sh and cleanup.sh treat it as "already cleaned
# up", the janitor counts it), so the decision stays with them.
harness_worktree() {  # $1 = run dir; prints the worktree path, or nothing
  cat "$1/worktree" 2>/dev/null || jq -r '.worktree // empty' "$1/result.json" 2>/dev/null
}

# Read a knob pinned in a run dir, falling back to a default. An empty pin file
# reads as empty, not as the default: a blank reviewer-model is a deliberate
# pin (run-task.sh writes one for a Claude-only first dispatch), not a missing one.
harness_knob() {  # $1 = run dir, $2 = file basename, $3 = default
  cat "$1/$2" 2>/dev/null || printf '%s' "$3"
}

# Is the Codex CLI here? The Codex CLI is optional: a Claude subscription alone
# runs the same pipeline with a fresh Claude review tier and Claude handling
# base-sync conflicts. Resolved once per invocation so no stage ever shells out
# to a missing binary and logs a 127.
#
# Sets CODEX_BIN and CODEX_AVAILABLE, plus the labels for the
# conflict-resolution stage line and the escalation text: they name whichever
# CLI actually does the work.
harness_codex_preamble() {  # sets CODEX_BIN CODEX_AVAILABLE CONFLICT_AGENT CONFLICT_MODEL
  CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || echo codex)}"
  if command -v "$CODEX_BIN" >/dev/null 2>&1; then CODEX_AVAILABLE=1; else CODEX_AVAILABLE=0; fi
  CONFLICT_AGENT="Codex, ChatGPT sub"; CONFLICT_MODEL="Codex"
  [ "$CODEX_AVAILABLE" = 1 ] || { CONFLICT_AGENT="Claude sub"; CONFLICT_MODEL="Claude"; }
}
