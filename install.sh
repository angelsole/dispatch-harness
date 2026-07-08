#!/usr/bin/env bash
# Install the dispatch harness.
#
# Symlinks (default) or copies the runtime scripts into ~/.claude/harness and
# the planner skill into ~/.claude/skills/dispatch/SKILL.md. Idempotent: safe to
# re-run. Your local config (notify.conf, repos.local.sh, demo.conf.sh) is
# seeded from the matching *.example ONLY when absent — an existing file is
# never overwritten.
#
# Usage:
#   ./install.sh           symlink scripts back to this checkout (git pull to update)
#   ./install.sh --copy    install detached copies instead
#
# Env overrides:
#   HARNESS_DIR         install target        (default: ~/.claude/harness)
#   CLAUDE_SKILLS_DIR   skills directory      (default: ~/.claude/skills)
set -eu

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=symlink
case "${1:-}" in
  --copy)         MODE=copy ;;
  --symlink|"")   MODE=symlink ;;
  -h|--help)      usage; exit 0 ;;
  *)              echo "unknown option: $1" >&2; echo; usage >&2; exit 2 ;;
esac

SRC="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
SKILL_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/dispatch"

# Runtime files installed into HARNESS_DIR.
FILES=(
  run-task.sh sync-pr.sh status.sh metrics.sh attach.sh cleanup.sh preview.sh
  station.sh demo-auth.sh auth-capture.py repos.conf.sh setup-repo.sh
  worker-settings.json setup-ai-settings.json brief-template.md
)

link_or_copy() {  # $1 = source path, $2 = dest path
  if [ "$MODE" = symlink ]; then
    ln -sfn "$1" "$2"
  else
    cp -f "$1" "$2"
  fi
}

mkdir -p "$HARNESS_DIR" "$SKILL_DIR"

for f in "${FILES[@]}"; do
  link_or_copy "$SRC/$f" "$HARNESS_DIR/$f"
  # Only the .sh entrypoints are run directly; auth-capture.py is invoked via a
  # Python interpreter, so it stays non-executable (and symlink chmod won't
  # dirty the source clone).
  case "$f" in *.sh) chmod +x "$HARNESS_DIR/$f" 2>/dev/null || true ;; esac
  echo "$MODE  $HARNESS_DIR/$f"
done

link_or_copy "$SRC/skills/dispatch/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "$MODE  $SKILL_DIR/SKILL.md"

# Seed local config from *.example, never clobbering an existing file.
seed() {  # $1 = example file, $2 = dest basename
  local dest="$HARNESS_DIR/$2"
  if [ -e "$dest" ]; then
    echo "keep  $dest (exists — not overwritten)"
  else
    cp "$SRC/$1" "$dest"
    echo "seed  $dest (from $1 — edit it)"
  fi
}
seed notify.conf.example    notify.conf
seed repos.local.sh.example repos.local.sh
seed demo.conf.sh.example   demo.conf.sh

echo
echo "Installed into $HARNESS_DIR (mode: $MODE)."
echo "Next: pin your repos in $HARNESS_DIR/repos.local.sh — see README.md."
