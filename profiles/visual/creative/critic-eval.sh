#!/usr/bin/env bash
# The critic's eval set: does the judge actually discriminate?
#
# The gate acts on one number — `pairwise` — and until this script existed the
# only evidence that the number meant anything was that it had once agreed with
# a human. It had also, measurably, done all of this:
#
#   * called the same challenger `worse` in both presentation orders, including
#     the order in which "worse" was the reigning champion (status-quo bias);
#   * answered `worse`/`fail` and then `better`/`pass` on identical inputs.
#
# So: a small set of pairs a human has already ranked, run through the real
# critic, scored on three things that matter more than any single verdict —
#
#   ACCURACY          the final verdict against the human's ranking;
#   ORDER-CONCORDANCE how often the two blind presentations agree, which is what
#                     makes a `better`/`worse` trustworthy at all;
#   REPEAT-AGREEMENT  how often the same pair, run again, answers the same way.
#
# Run it after any model change, any prompt change, and before trusting a new
# repo's rubric. It is LIVE ONLY — there is nothing to learn from a fake critic
# here — and it costs roughly $0.5–1.5 and 3–6 minutes per pair-repeat.
#
# Usage:
#   VISUAL_LIVE=1 critic-eval.sh [--repeats N] [--jobs J]
#                                [--pairs FILE] [--out DIR] [--refs DIR]
#
# --refs DIR hands the critic a reference board, exactly as the gate does with
# VISUAL_REFS; the pair set may name one too ("refs", relative to the pairs
# file). Measure WITH the board the gate will use — the same judge answers
# differently with and without one, and it is the with-board answer the gate
# acts on.
# Env:
#   VISUAL_LIVE=1          required; without it this refuses to spend money
#   CRITIC_MODEL           passed through to critic.sh
#   CRITIC_ORDERS          passed through (2 = the calibrated protocol)
#   CRITIC_TIEBREAK_MARGIN passed through
#
# Exit 0 when every human-judged pair (one whose `expect` is `better` or
# `worse`) came out right, 1 when one did not, 2 when the set could not be run.
# A `tie` pair is measured and reported but never fails the run: "these two are
# about equal" is a weaker claim than "this one is worse", and only the strong
# claims are worth a red build.
set -u -o pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "$SELF_DIR/../../../lib/common.sh"
REPEATS=1
JOBS=2
PAIRS="$SELF_DIR/eval/pairs.json"
OUT=".harness/critic-eval"
REFS=""
MAX_JOBS=3   # the CLI is on a subscription; three concurrent critics is polite

usage() { harness_usage "$0"; exit "${1:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repeats) REPEATS="${2:-}"; shift 2 ;;
    --jobs)    JOBS="${2:-}";    shift 2 ;;
    --pairs)   PAIRS="${2:-}";   shift 2 ;;
    --out)     OUT="${2:-}";     shift 2 ;;
    --refs)    REFS="${2:-}";    shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "critic-eval.sh: unknown option $1" >&2; usage ;;
  esac
done

die() { echo "critic-eval.sh: $1" >&2; exit "${2:-2}"; }

case "$REPEATS" in ''|*[!0-9]*|0) die "--repeats must be a positive integer" ;; esac
case "$JOBS"    in ''|*[!0-9]*|0) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -le "$MAX_JOBS" ] || die "--jobs $JOBS is more than $MAX_JOBS — the critic runs on a subscription CLI, not a rate-limited API key"
[ -f "$PAIRS" ] || die "no pair set at $PAIRS"
jq -e . "$PAIRS" >/dev/null 2>&1 || die "$PAIRS is not valid JSON"
command -v jq >/dev/null 2>&1 || die "jq is required"

# Live only, and loudly so. Every other tier in this harness can be exercised
# for free; this one cannot, and a fake critic scoring 100 % on the eval set is
# the single most misleading artefact this repo could produce.
[ "${VISUAL_LIVE:-0}" = 1 ] || die "this spends real money on the real critic — re-run with VISUAL_LIVE=1"

PAIRS_DIR="$(cd "$(dirname "$PAIRS")" && pwd)"
RUBRIC=$(jq -r '.rubric // empty' "$PAIRS")
if [ -n "$RUBRIC" ]; then RUBRIC="$PAIRS_DIR/$RUBRIC"; else RUBRIC="$SELF_DIR/rubric.md"; fi
[ -f "$RUBRIC" ] || die "no rubric at $RUBRIC"
if [ -z "$REFS" ]; then
  REFS=$(jq -r '.refs // empty' "$PAIRS")
  [ -z "$REFS" ] || REFS="$PAIRS_DIR/$REFS"
fi
if [ -n "$REFS" ]; then
  [ -d "$REFS" ] || die "no reference board at $REFS"
  REFS="$(cd "$REFS" && pwd)"
fi

mkdir -p "$OUT" || die "cannot write into $OUT"
OUT="$(cd "$OUT" && pwd)"
SUMMARY="$OUT/summary.json"
rm -f "$OUT"/*.json.run "$SUMMARY"

N_PAIRS=$(jq -r '.pairs | length' "$PAIRS")
[ "$N_PAIRS" -gt 0 ] || die "$PAIRS lists no pairs"

# The work list, one line per run: id<TAB>repeat<TAB>expect<TAB>champion<TAB>challenger.
# Resolved and checked here rather than inside a lane, so a typo in the set
# fails before the first dollar is spent.
WORK="$OUT/work.tsv"
: > "$WORK"
i=0
while [ "$i" -lt "$N_PAIRS" ]; do
  ID=$(jq -r --argjson i "$i" '.pairs[$i].id' "$PAIRS")
  EXPECT=$(jq -r --argjson i "$i" '.pairs[$i].expect' "$PAIRS")
  BETTER=$(jq -r --argjson i "$i" '.pairs[$i].better' "$PAIRS")
  WORSE=$(jq -r --argjson i "$i" '.pairs[$i].worse // ""' "$PAIRS")
  SIDE=$(jq -r --argjson i "$i" '.pairs[$i].challenger // "worse"' "$PAIRS")
  case "$ID" in ''|null|*[!A-Za-z0-9._-]*) die "pair $i has an unusable id '$ID'" ;; esac
  case "$EXPECT" in better|worse|tie) ;; *) die "pair $ID expects '$EXPECT' — must be better, worse or tie" ;; esac
  [ -n "$WORSE" ] && [ "$WORSE" != null ] || WORSE="$BETTER"
  if [ "$SIDE" = better ]; then CHAMP="$PAIRS_DIR/$WORSE"; CHAL="$PAIRS_DIR/$BETTER"
  else                         CHAMP="$PAIRS_DIR/$BETTER"; CHAL="$PAIRS_DIR/$WORSE"; fi
  for f in "$CHAMP" "$CHAL"; do
    [ -f "$f" ] || die "pair $ID names a sheet that is not there: $f"
    bytes=$(wc -c < "$f" | tr -d ' ')
    [ "$bytes" -le 500000 ] || echo "critic-eval.sh: warning — $f is ${bytes}B, over the 500 KB the Read tool recompresses above; the critic will grade a JPEG of it" >&2
  done
  r=1
  while [ "$r" -le "$REPEATS" ]; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$ID" "$r" "$EXPECT" "$CHAMP" "$CHAL" >> "$WORK"
    r=$((r + 1))
  done
  i=$((i + 1))
done
N_RUNS=$(grep -c '' "$WORK" | tr -d ' ')

echo "critic eval: $N_PAIRS pair(s) x $REPEATS repeat(s) = $N_RUNS run(s), $JOBS at a time"
echo "  model:  ${CRITIC_MODEL:-claude-opus-5}   orders: ${CRITIC_ORDERS:-2}   margin: ${CRITIC_TIEBREAK_MARGIN:-0.5}"
echo "  rubric: $RUBRIC"
echo "  refs:   ${REFS:-none}"
echo "  out:    $OUT"
echo

# One lane per job slot, each running every Nth line of the work list. No
# `wait -n` (bash 3.2 on macOS has none) and no job-control bookkeeping: the
# lanes are independent, and the runs are long enough that even splitting them
# round-robin keeps every lane busy.
lane() {  # $1 = lane index (0-based)
  local lane_i="$1" n=0 id repeat expect champ chal rc verdict
  while IFS=$'\t' read -r id repeat expect champ chal; do
    if [ $((n % JOBS)) -eq "$lane_i" ]; then
      verdict="$OUT/$id-r$repeat.json"
      rc=0
      bash "$SELF_DIR/critic.sh" --challenger "$chal" --champion "$champ" \
        --rubric "$RUBRIC" ${REFS:+--refs "$REFS"} --out "$verdict" \
        > "$OUT/$id-r$repeat.log" 2>&1 || rc=$?
      # The run's own facts, beside the verdict, so the aggregation below never
      # has to guess whether a missing file was a crash or a lane that is still
      # running.
      jq -n --arg id "$id" --argjson repeat "$repeat" --arg expect "$expect" \
            --arg champ "$champ" --arg chal "$chal" --argjson rc "$rc" \
            --slurpfile v "$verdict" \
        '($v[0] // null) as $c
         | {id:$id, repeat:$repeat, expect:$expect, champion:$champ, challenger:$chal,
            rc:$rc,
            got:(if $rc == 0 then ($c.pairwise // "none") else "FAILED" end),
            verdict:($c.verdict // null),
            concordant:(if ($c.calibration.orders // 0) > 1
                        then ($c.calibration.concordant // null) else null end),
            tiebreak:($c.calibration.tiebreak.used // null),
            delta:($c.calibration.tiebreak.delta // null),
            champion_axes:($c.calibration.champion_axes // null),
            challenger_axes:($c.calibration.challenger_axes // null),
            preferred:[($c.calibration.runs // [])[] | .preferred],
            cost_usd:($c.cost_usd // 0), seconds:($c.seconds // 0),
            error:($c.error // null)}' > "$verdict.run" 2>/dev/null \
        || jq -n --arg id "$id" --argjson repeat "$repeat" --arg expect "$expect" \
             '{id:$id, repeat:$repeat, expect:$expect, rc:1, got:"FAILED",
               concordant:null, tiebreak:null, delta:null, preferred:[],
               cost_usd:0, seconds:0, error:"the critic wrote no readable verdict"}' \
             > "$verdict.run"
      printf '  %-18s r%-2s %s\n' "$id" "$repeat" \
        "$(jq -r '"\(.got)\(if .concordant == false then " (tiebreak \(.delta))" else "" end)"' "$verdict.run")"
    fi
    n=$((n + 1))
  done < "$WORK"
}

STARTED=$(date +%s)
l=0
while [ "$l" -lt "$JOBS" ]; do
  lane "$l" &
  l=$((l + 1))
done
wait
SECONDS_TAKEN=$(( $(date +%s) - STARTED ))
echo

# --- the table ----------------------------------------------------------------
printf '%-18s %-7s %-3s %-7s %-6s %-10s %-7s %-8s %s\n' \
  PAIR EXPECT REP GOT ORDERS TIEBREAK DELTA COST SECS
jq -rs 'sort_by(.id, .repeat)[]
  | [ .id, .expect, ("r" + (.repeat|tostring)), .got,
      (if .concordant == null then "-" elif .concordant then "agree" else "differ" end),
      (if .tiebreak == null then "-" elif .tiebreak then "used" else "no" end),
      (if .delta == null then "-" else (.delta|tostring) end),
      ("$" + ((.cost_usd // 0)|tostring)), ((.seconds // 0)|tostring) ]
  | @tsv' "$OUT"/*.json.run \
  | awk -F'\t' '{printf "%-18s %-7s %-3s %-7s %-6s %-10s %-7s %-8s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}'
echo

# --- the three numbers ---------------------------------------------------------
# `tie` expected accepts `tie` and nothing else — but only the human-judged
# pairs (better/worse) decide the exit code.
jq -s --argjson secs "$SECONDS_TAKEN" --argjson repeats "$REPEATS" \
      --argjson jobs "$JOBS" --arg pairs "$PAIRS" --arg rubric "$RUBRIC" \
      --arg model "${CRITIC_MODEL:-claude-opus-5}" --arg refs "$REFS" \
      --arg orders "${CRITIC_ORDERS:-2}" \
      --arg margin "${CRITIC_TIEBREAK_MARGIN:-0.5}" '
  ((try ($orders | tonumber) catch null)) as $orders
  | ((try ($margin | tonumber) catch null)) as $margin
  |
  def rate(sel): (map(select(sel)) | length) as $n
    | {correct: (map(select(sel and (.got == .expect))) | length), total: $n,
       rate: (if $n == 0 then null
              else ((map(select(sel and (.got == .expect))) | length) / $n * 1000 | round) / 1000 end)};
  def is_verdict: . == "better" or . == "worse" or . == "tie";
  sort_by(.id, .repeat) as $runs
  | ($runs | group_by(.id) | map(
      (map(.got)) as $got
      | {id: .[0].id, expect: .[0].expect, got: $got,
         complete: ($got | map(is_verdict) | all),
         agreed: (($repeats > 1) and ($got | map(is_verdict) | all)
                  and ($got | unique | length == 1))})) as $bypair
  | {pairs: $pairs, rubric: $rubric, refs: (if $refs == "" then null else $refs end),
     model: $model, orders: $orders,
     tiebreak_margin: $margin, repeats: $repeats, jobs: $jobs,
     seconds: $secs,
     cost_usd: ((($runs | map(.cost_usd // 0) | add) * 1000000 | round) / 1000000),
     accuracy: ($runs | rate(true)),
     accuracy_enforced: ($runs | rate(.expect != "tie")),
     order_concordance: (($runs | map(select(.concordant != null))) as $c
       | {agreed: ($c | map(select(.concordant)) | length), total: ($c | length),
          rate: (if ($c | length) == 0 then null
                 else (($c | map(select(.concordant)) | length) / ($c | length) * 1000 | round) / 1000 end)}),
     repeat_agreement: {pairs: ($bypair | map(select(.agreed)) | length),
                        total: (if $repeats > 1 then ($bypair | length) else 0 end),
                        rate: (if $repeats <= 1 or ($bypair | length) == 0 then null
                               else (($bypair | map(select(.agreed)) | length) / ($bypair | length) * 1000 | round) / 1000 end),
                        measured: ($repeats > 1)},
     by_pair: $bypair, runs: $runs}' "$OUT"/*.json.run > "$SUMMARY"

# A scorer that could not score is not a pass. Every verdict is still on disk,
# so this is recoverable — but it must never read as "nothing was wrong".
jq -e . "$SUMMARY" >/dev/null 2>&1 \
  || die "the runs finished but $SUMMARY could not be written — the per-run verdicts are in $OUT" 2

jq -r '
  "accuracy:          \(.accuracy.correct)/\(.accuracy.total) runs matched the human ranking",
  "  enforced:        \(.accuracy_enforced.correct)/\(.accuracy_enforced.total) on the better/worse pairs (the ones that decide this exit code)",
  "order-concordance: \(.order_concordance.agreed)/\(.order_concordance.total) runs got the same answer in both presentation orders",
  "repeat-agreement:  \(.repeat_agreement.pairs)/\(.repeat_agreement.total) pairs answered the same way every repeat" +
    (if .repeat_agreement.measured then "" else " (one repeat — nothing to disagree with; use --repeats 2)" end),
  "cost:              $\(.cost_usd) over \(.seconds)s of wall time",
  "summary:           " + input_filename' "$SUMMARY"

BAD=$(jq -r '[.runs[] | select(.expect != "tie" and .got != .expect)
              | "\(.id) r\(.repeat): expected \(.expect), got \(.got)"] | join("; ")' "$SUMMARY")
if [ -n "$BAD" ]; then
  echo
  echo "critic eval: FAILED — $BAD" >&2
  exit 1
fi
TIES=$(jq -r '[.runs[] | select(.expect == "tie" and .got != "tie")
               | "\(.id) r\(.repeat): \(.got)"] | join("; ")' "$SUMMARY")
[ -z "$TIES" ] || echo "note: a pair expected to tie came back with a verdict — $TIES (reported, not failed)"
echo "critic eval: OK"
exit 0
