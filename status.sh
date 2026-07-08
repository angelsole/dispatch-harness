#!/usr/bin/env bash
# Which model is handling what, right now — across all dispatch runs.
# Usage: status.sh            one-shot table
#        status.sh <TICKET>   full timeline of one run
set -u
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"
[ -d "$RUNS" ] || { echo "no runs yet"; exit 0; }

fmt() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

if [ $# -eq 1 ]; then
  dir="$RUNS/$1"
  [ -d "$dir" ] || { echo "no run named $1" >&2; exit 1; }
  echo "== $1 timeline =="
  cat "$dir/timeline" 2>/dev/null || echo "(no timeline yet)"
  [ -f "$dir/result.json" ] && { echo "== result =="; jq -r 'to_entries[] | "\(.key): \(.value)"' "$dir/result.json"; }
  exit 0
fi

now=$(date +%s)
found=0
printf '%-26s %-46s %-12s %s\n' "RUN" "STAGE" "IN STAGE" "TOTAL"
# Newest-first: run-id dir names are ticket IDs / adhoc slugs (no whitespace),
# so word-splitting ls -t output is safe here.
# shellcheck disable=SC2045
for name in $(ls -t "$RUNS" 2>/dev/null); do
  dir="$RUNS/$name"
  [ -f "$dir/status" ] || continue
  found=1
  read -r ts stagetext < "$dir/status"
  started=$(cat "$dir/started" 2>/dev/null || echo "$ts")
  case "$stagetext" in
    done:*) printf '%-26s %-46s %-12s %s\n' "$name" "$stagetext" "-" "$(fmt $((ts - started)))" ;;
    *)      printf '%-26s %-46s %-12s %s\n' "$name" "$stagetext" "$(fmt $((now - ts)))" "$(fmt $((now - started)))" ;;
  esac
done
[ $found -eq 1 ] || echo "no runs yet"
