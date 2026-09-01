#!/usr/bin/env bash
# The feedback loop's front door: what past runs in a repo taught, distilled
# from the pipeline's own evidence and read back by the next run.
#
# The pipeline records two ground truths and, until this existed, read neither
# back: the review findings that SURVIVED refutation (a defect an implementer
# wrote and a second vendor confirmed) and, from janitor.sh, what the world then
# did with the PR — merged, reverted, argued over, patched afterwards. Findings
# supply the text; outcomes supply the weight. No model reads or writes any of
# it: the entries are the reviewer's own words, counted and ranked by evidence.
#
# The planner reads `--show` before writing a brief; every dispatch mounts the
# same file at .harness/lessons.md for the implementer. Both are advisory — a
# trap is a place to be careful, never a task. The brief is still the task.
#
# >>> --help >>>
# Usage:
#   lessons.sh                     what each repo's file holds (same as --list)
#   lessons.sh --list              one line per repo: traps, age, path
#   lessons.sh --show <repo>       print that repo's traps (nothing when it has none)
#   lessons.sh --refresh [<repo>]  regenerate one repo's file, or every repo's
#   lessons.sh --path <repo>       where that repo's file lives
#
# Knobs (env): LESSONS_DIR  LESSONS_MAX_ENTRIES  LESSONS_MAX_CLAIMS
#   LESSONS_CLAIM_CHARS  LESSONS_MAX_AGE  LESSONS_SOLO_MAX_AGE
#   LESSONS_NOISY_COMMENTS  LESSONS_STALE_HOURS
# <<< --help <<<
set -u
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
# shellcheck source=lib/lessons.sh
. "$(dirname "$_COMMON_LIB_PATH")/lessons.sh"
unset _COMMON_LIB_PATH

usage() { harness_usage "$0" >&2; exit 2; }

# A repo argument in the spelling the run history stores: absolute, symlinks
# resolved. `lessons.sh --show .` from inside a repo has to find the same file
# the dispatch of that repo wrote, and `cd` + `pwd -P` is what run-task.sh's own
# path handling reduces to.
resolve_repo() {  # $1 = a path; prints an absolute repo path or exits
  local p="$1" top
  [ -n "$p" ] || { echo "lessons: --show/--refresh/--path needs a repo path" >&2; exit 2; }
  [ -d "$p" ] || { echo "lessons: not a directory: $p" >&2; exit 1; }
  p=$(cd "$p" 2>/dev/null && pwd -P) || { echo "lessons: cannot read $1" >&2; exit 1; }
  # A path inside a repo resolves to its root, so `--show .` works from a
  # subdirectory. A path that is not in a repo at all is taken at its word:
  # the run history may still have runs filed under it.
  top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) && p="$top"
  printf '%s\n' "$p"
}

list_repos() {
  local repo file n age d
  local found=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    found=1
    file=$(lessons_file "$repo")
    if [ -s "$file" ]; then
      n=$(grep -c '^- `' "$file" 2>/dev/null | tr -d ' ') || n=0
      d=$(harness_mtime "$file") || d=""
      case "$d" in ''|*[!0-9]*) d="" ;; esac
      if [ -n "$d" ]; then age="$(lessons_day "$d")"; else age="unknown"; fi
      printf '%-4s traps  refreshed %s  %s\n' "$n" "$age" "$repo"
      printf '            %s\n' "$file"
    else
      printf '%-4s traps  %s\n' "0" "$repo"
    fi
  done <<EOF
$(lessons_repos)
EOF
  [ "$found" = 1 ] || echo "no runs the history can attribute to a repo yet — nothing to distil"
}

case "${1:---list}" in
  -h|--help) harness_usage "$0"; exit 0 ;;
  --list)
    [ $# -le 1 ] || usage
    list_repos ;;
  --show)
    REPO=$(resolve_repo "${2:-}")
    FILE=$(lessons_file "$REPO")
    [ -s "$FILE" ] && cat "$FILE"
    exit 0 ;;
  --path)
    REPO=$(resolve_repo "${2:-}")
    lessons_file "$REPO" ;;
  --refresh)
    if [ -n "${2:-}" ]; then
      REPO=$(resolve_repo "$2")
      N=$(lessons_render "$REPO")
      echo "[lessons] $REPO: $N trap(s) — $(lessons_file "$REPO")"
    else
      read -r REPOS TRAPS <<EOF
$(lessons_refresh_all)
EOF
      echo "[lessons] $REPOS repo(s), $TRAPS trap(s) — $LESSONS_DIR"
    fi ;;
  *) usage ;;
esac
