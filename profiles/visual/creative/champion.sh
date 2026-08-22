#!/usr/bin/env bash
# The champion: the best render of a project so far, and the thing every later
# challenger is judged against.
#
# It lives OUTSIDE the worktrees — $HARNESS_DIR/champion/<repo>/ — because
# cleanup.sh deletes worktrees, and a reference frame that dies with the run
# that produced it is not a reference. The visual gate copies it into the
# worktree's .harness/champion/ per round so the critic can Read it.
#
# PROMOTION IS MANUAL AND MILESTONE-ONLY, and this script is the only way to do
# it. Nothing in run-task.sh promotes anything: auto-promoting every green run
# ratchets the project toward whatever the critic happens to like this week, and
# six rounds of that is how a champion ends up worse than the render it
# replaced with every round green on the way down.
#
# Usage:
#   champion.sh promote <repo-name> <run-id|dir>   crown that run's frames
#   champion.sh show [repo-name]                   what reigns, and since when
#
# <run-id> is a run under $HARNESS_DIR/runs/; <dir> is any directory holding a
# frames/ subdirectory (a run dir, its visual/ subdirectory, or a worktree's
# .harness/) — which is how you crown a render you made by hand.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "$SELF_DIR/../../../lib/common.sh"
CHAMPION_ROOT="$HARNESS_DIR/champion"

usage() { harness_usage "$0"; exit "${1:-2}"; }

valid_repo() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Where the frames of a promotion source are. Accepts the three shapes a human
# will actually have in front of them, rather than making them find the fourth.
find_source() {  # $1 = run id or directory -> echoes a dir containing frames/
  local arg="$1" d
  for d in "$arg" "$arg/visual" "$HARNESS_DIR/runs/$arg/visual" \
           "$HARNESS_DIR/runs/$arg" "$arg/.harness"; do
    [ -d "$d/frames" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

promote() {
  local repo="$1" src_arg="$2" src dest staged old n=0 shot f
  [ -n "$repo" ] && [ -n "$src_arg" ] || usage
  valid_repo "$repo" || {
    echo "champion.sh: repo name must contain only letters, digits, dot, underscore or hyphen" >&2
    exit 2
  }
  src=$(find_source "$src_arg") || {
    echo "champion.sh: no frames/ under $src_arg (tried it, its visual/, and \$HARNESS_DIR/runs/$src_arg)" >&2
    exit 1
  }
  dest="$CHAMPION_ROOT/$repo"
  mkdir -p "$CHAMPION_ROOT" || exit 1
  staged=$(mktemp -d "$CHAMPION_ROOT/.${repo}.new.XXXXXX") || exit 1
  old="$CHAMPION_ROOT/.${repo}.old.$$"
  cleanup_staging() {
    [ -z "${staged:-}" ] || rm -rf "$staged"
    if [ -e "${old:-}" ] && [ ! -e "$dest" ]; then mv "$old" "$dest"; fi
  }
  trap cleanup_staging EXIT

  # Build the complete replacement before touching what currently reigns. A
  # malformed source or a full disk must leave the existing champion intact.
  for f in "$src"/frames/*-f00.png; do
    [ -e "$f" ] || continue
    shot=$(basename "$f"); shot="${shot%-f00.png}"
    cp "$f" "$staged/champion-$shot.png" || exit 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "champion.sh: $src/frames holds no <shot>-f00.png frames" >&2; exit 1; }

  # Rebuild rather than trusting an arbitrary source sheet: promotion must
  # guarantee the critic has an A image, with the same labels and byte ceiling
  # as every challenger sheet.
  bash "$SELF_DIR/contact-sheet.sh" "$staged/champion-sheet.png" "$src"/frames/*.png \
    >/dev/null || {
      echo "champion.sh: could not build a champion sheet from $src/frames" >&2
      exit 1
    }

  jq -n --arg repo "$repo" --arg src "$src" \
        --arg at "$(date '+%Y-%m-%dT%H:%M:%S%z')" --argjson shots "$(
          for f in "$staged"/champion-*.png; do
            [ -e "$f" ] || continue
            b=$(basename "$f"); b="${b#champion-}"; b="${b%.png}"
            [ "$b" = "sheet" ] || printf '%s\n' "$b"
          done | jq -R . | jq -s .)" \
    '{repo:$repo, promoted_at:$at, source:$src, shots:$shots,
      sheet:"champion-sheet.png"}' > "$staged/champion.json"

  # Replace wholesale rather than merge: retaining a shot the new render no
  # longer takes would compare later challengers with stale evidence.
  [ ! -e "$dest" ] || mv "$dest" "$old"
  mv "$staged" "$dest" || exit 1
  staged=""
  [ ! -e "$old" ] || rm -rf "$old"
  echo "champion: $repo now reigns with $n shot(s) from $src"
  sed 's/^/  /' "$dest/champion.json"
}

show() {
  local repo="${1:-}" d
  if [ -n "$repo" ]; then
    valid_repo "$repo" || {
      echo "champion.sh: repo name must contain only letters, digits, dot, underscore or hyphen" >&2
      return 2
    }
    d="$CHAMPION_ROOT/$repo"
    [ -d "$d" ] || { echo "champion: nothing reigns for $repo (promote one: champion.sh promote $repo <run-id>)"; return 0; }
    echo "champion: $repo"
    [ -f "$d/champion.json" ] && sed 's/^/  /' "$d/champion.json"
    find "$d" -maxdepth 1 -name '*.png' | sort | sed 's/^/  /'
    return 0
  fi
  [ -d "$CHAMPION_ROOT" ] || { echo "champion: none promoted yet ($CHAMPION_ROOT does not exist)"; return 0; }
  for d in "$CHAMPION_ROOT"/*; do
    [ -d "$d" ] || continue
    show "$(basename "$d")"
  done
}

case "${1:-}" in
  promote) shift; promote "${1:-}" "${2:-}" ;;
  show)    shift; show "${1:-}" ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
