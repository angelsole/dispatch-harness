#!/usr/bin/env bash
# Install the dispatch harness.
#
# Symlinks (default) or copies the runtime scripts into ~/.claude/harness and
# the planner skill into ~/.claude/skills/dispatch/SKILL.md. Idempotent: safe to
# re-run. Your local config (notify.conf, repos.local.sh, demo.conf.sh) is
# seeded from the matching *.example ONLY when absent — an existing file is
# never overwritten.
#
# It then offers to wire statusline.sh into ~/.claude/settings.json — only with
# your explicit consent, and only when you have no statusLine yet. An existing
# statusLine is never rewritten: you get the one-liner to compose it yourself.
#
# Usage:
#   ./install.sh                  symlink scripts back to this checkout (git pull to update)
#   ./install.sh --copy           install detached copies instead
#   ./install.sh --statusline     wire without prompting when run in a terminal
#   ./install.sh --no-statusline  never touch settings.json, just print how
#
# Env overrides:
#   HARNESS_DIR           install target         (default: ~/.claude/harness)
#   CLAUDE_SKILLS_DIR     skills directory       (default: ~/.claude/skills)
#   CLAUDE_SETTINGS_FILE  settings.json to wire  (default: ~/.claude/settings.json)
set -eu

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=symlink
STATUSLINE=ask
for arg in "$@"; do
  case "$arg" in
    --copy)          MODE=copy ;;
    --symlink)       MODE=symlink ;;
    --statusline)    STATUSLINE=yes ;;
    --no-statusline) STATUSLINE=no ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "unknown option: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
  esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
SKILL_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/dispatch"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
STATUSLINE_CMD="$HARNESS_DIR/statusline.sh"

# Runtime files installed into HARNESS_DIR. `wall` is a directory: the wall's
# page and server travel with wall.sh.
FILES=(
  mirror.sh capacity.sh run-task.sh schedule.sh quartermaster.sh sync-pr.sh status.sh statusline.sh
  metrics.sh attach.sh cleanup.sh preview.sh station.sh wall.sh wall demo-auth.sh
  auth-capture.py repos.conf.sh setup-repo.sh worker-settings.json setup-ai-settings.json
  brief-template.md
)

link_or_copy() {  # $1 = source path, $2 = dest path
  # A directory entry is replaced wholesale: ln would otherwise drop the link
  # *inside* an existing real directory, and cp -R would merge into it.
  if [ -d "$1" ]; then rm -rf "$2"; fi
  if [ "$MODE" = symlink ]; then
    ln -sfn "$1" "$2"
  elif [ -d "$1" ]; then
    cp -R "$1" "$2"
  else
    cp -f "$1" "$2"
  fi
}

# Everything we print when we are NOT editing settings.json — the manual path is
# always shown, so declining still leaves you with working instructions.
statusline_manual() {  # $1 = why we are not writing
  echo
  echo "statusline: $1"
  echo "  To show live runs in every Claude session, add to $SETTINGS:"
  echo "    \"statusLine\": {\"type\": \"command\", \"command\": \"$STATUSLINE_CMD\"}"
  echo "  Already have a statusline command? Append the harness run lines to it:"
  echo "    <your command>; $STATUSLINE_CMD --runs-only"
  echo "  (--runs-only reads no stdin — the session JSON can only be consumed"
  echo "   once, so your own script keeps it.)"
  echo "  Prefer no wiring at all? $HARNESS_DIR/status.sh --watch is the"
  echo "  zero-config live dashboard."
}

wire_statusline() {
  local reply='' backup tmp
  if [ "$STATUSLINE" = no ]; then
    statusline_manual "not wired (--no-statusline)."
    return 0
  fi
  if [ -f "$SETTINGS" ]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
      statusline_manual "left $SETTINGS alone — it is not valid JSON."
      return 0
    fi
    if jq -e 'has("statusLine")' "$SETTINGS" >/dev/null 2>&1; then
      statusline_manual "$SETTINGS already defines a statusLine — untouched."
      return 0
    fi
  fi
  # Even an affirmative flag must not let automation rewrite a user's Claude
  # settings. The flag is explicit consent only when the installer itself is
  # attached to a terminal; otherwise the manual path is the safe contract.
  if [ ! -t 0 ]; then
    statusline_manual "stdin is not a terminal — settings.json untouched."
    return 0
  fi
  if [ "$STATUSLINE" = ask ]; then
    printf 'Wire the harness statusline into %s? [y/N] ' "$SETTINGS"
    read -r reply || reply=''
    case "$reply" in
      y|Y|yes|Yes|YES) ;;
      *) statusline_manual "declined — settings.json untouched."; return 0 ;;
    esac
  fi
  mkdir -p "$(dirname "$SETTINGS")"
  if [ -f "$SETTINGS" ]; then
    backup="$SETTINGS.bak-$(date '+%Y%m%d-%H%M%S')"
    cp "$SETTINGS" "$backup"
  else
    backup="none — file did not exist"
    echo '{}' > "$SETTINGS"
  fi
  tmp="$SETTINGS.tmp.$$"
  jq --arg cmd "$STATUSLINE_CMD" \
    '.statusLine = {type: "command", command: $cmd, padding: 0}' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo
  echo "wire  $SETTINGS statusLine -> $STATUSLINE_CMD"
  echo "      backup: $backup"
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

wire_statusline

echo
echo "Installed into $HARNESS_DIR (mode: $MODE)."
echo "Next: pin your repos in $HARNESS_DIR/repos.local.sh — see README.md."
