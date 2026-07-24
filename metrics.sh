#!/usr/bin/env bash
# Tabulate per-run metrics from every result.json under the runs directory.
#
# Usage: metrics.sh          aligned table (default)
#        metrics.sh --csv    CSV for spreadsheets / stats tools
#
# Columns: run, arm, implementer model/effort, reviewer model/effort, status,
#          gate rounds (e.g. fail,pass), implementer/reviewer commit counts,
#          +/- lines vs base, wall minutes.
#
# Runs predating a field — the metrics instrumentation (result.json without a
# `metrics` object) or the model/effort knobs — render with blanks, never
# errors: every field falls back with jq's //.
set -u
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"

usage() { echo "usage: metrics.sh [--csv]" >&2; }

CSV=0
case "${1:-}" in
  --csv)      CSV=1 ;;
  -h|--help)  usage; exit 0 ;;
  "")         ;;
  *)          echo "unknown option: $1" >&2; usage; exit 2 ;;
esac

[ -d "$RUNS" ] || { echo "no runs yet" >&2; exit 0; }

# Emit the twelve data fields one per line (blank when absent). Splitting on
# newlines keeps empty fields intact and needs no delimiter char; every element
# is coerced to a string so `-r` prints it raw. Missing `metrics` (old runs)
# falls through jq's // to empty, so those rows render blank instead of erroring.
ROW_FILTER='
  (.arm // ""),
  (.implementer_model // ""),
  (.implementer_effort // ""),
  (.reviewer_model // ""),
  (.reviewer_effort // ""),
  (.status // ""),
  ((.metrics.gate_rounds // []) | map(.result) | join(",")),
  (.metrics.opus_commits // "" | tostring),
  (.metrics.codex_commits // "" | tostring),
  (.metrics.diff.insertions // "" | tostring),
  (.metrics.diff.deletions // "" | tostring),
  (.metrics.wall_seconds // "" | tostring)'

# Model/effort columns are sized for the explicit model IDs an ablation
# actually sweeps (claude-sonnet-5 = 15, gpt-5.6-sol = 11) and the longest
# effort value (medium = 6). Longer values just push the row right, as before.
TABLE_FMT='%-26s %-9s %-15s %-6s %-11s %-6s %-13s %-11s %5s %5s %6s %6s %8s\n'

if [ "$CSV" = 1 ]; then
  echo "run,arm,model,implementer_effort,reviewer_model,reviewer_effort,status,gate_rounds,opus_commits,codex_commits,insertions,deletions,wall_minutes"
else
  # shellcheck disable=SC2059
  printf "$TABLE_FMT" RUN ARM MODEL EFFORT R-MODEL R-EFF STATUS GATE OPUS CODEX +LN -LN WALL_MIN
fi

found=0
for f in "$RUNS"/*/result.json; do
  [ -f "$f" ] || continue
  found=1
  run=$(basename "$(dirname "$f")")
  rowdata=$(jq -r "$ROW_FILTER" "$f" 2>/dev/null) || rowdata=""
  { read -r arm; read -r model; read -r ieff; read -r rmodel; read -r reff
    read -r status; read -r gates
    read -r oc; read -r cc; read -r ins; read -r del; read -r wall
  } <<EOF
$rowdata
EOF
  wall_min=$(awk -v s="$wall" 'BEGIN{ if (s == "") print ""; else printf "%.1f", s/60 }')
  if [ "$CSV" = 1 ]; then
    # gate_rounds is the only field that can contain a comma — quote it.
    printf '%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s\n' \
      "$run" "$arm" "$model" "$ieff" "$rmodel" "$reff" "$status" \
      "$gates" "$oc" "$cc" "$ins" "$del" "$wall_min"
  else
    # shellcheck disable=SC2059
    printf "$TABLE_FMT" "$run" "${arm:--}" "${model:--}" "${ieff:--}" \
      "${rmodel:--}" "${reff:--}" "${status:--}" \
      "${gates:--}" "${oc:--}" "${cc:--}" "${ins:--}" "${del:--}" "${wall_min:--}"
  fi
done

[ "$found" = 1 ] || echo "(no result.json files under $RUNS)" >&2
