#!/usr/bin/env bash
# The visual critic: fresh, blind, shell-less `claude -p` calls that grade a
# contact sheet — and, the part that actually matters, say whether the
# challenger is better or worse than the reigning champion.
#
# Six properties, each of them load-bearing:
#
#   * FRESH CONTEXT. No --resume, no session id. A model may not grade its own
#     work, and a model that watched the work being done is grading its own.
#   * NO SHELL. --settings creative/critic-settings.json allows Read and Glob
#     and nothing else. The rubric is text from the target repo and the frames
#     were made by the worker being graded; neither may reach a command line.
#   * STRICT OUTPUT. --json-schema, not "please answer in JSON": the CLI
#     validates and returns a parsed object in .structured_output, so a chatty
#     answer is the CLI's problem rather than this script's regex.
#   * PAIRWISE. Absolute VLM scores are noisy and calibrated by nothing. "Is B
#     better than A" is the signal the gate is allowed to trust, and a
#     challenger judged `worse` fails no matter how high its axes are.
#   * BLIND. The critic is handed two images called A and B and is told nothing
#     else about either: not which one reigns, not which one is new. The old
#     prompt named the champion as "the reigning champion, the best render of
#     this project so far", and the measured result was status-quo bias — the
#     same two sheets, swapped, were judged `worse` both times. Even the file
#     names are laundered (image-a.png / image-b.png in a scratch dir) because
#     `champion-sheet.png` in a path is the same tell in smaller type.
#   * BOTH ORDERS. One blind answer is still one sample of a noisy judge, and
#     the same pair run twice came back `worse` once and `better` once. So the
#     question is asked twice, with the images swapped, and only an answer that
#     survives the swap is allowed to be `better` or `worse`. When the two
#     orders disagree the axes decide — as a MARGIN (the challenger's mean
#     minus the champion's, over both runs), never as a threshold — and inside
#     that margin the answer is `tie`, which is the honest word for a verdict
#     the critic will not repeat.
#
# Usage:
#   critic.sh --challenger SHEET.png [--champion SHEET.png] [--refs DIR]
#             [--rubric FILE] --out VERDICT.json
# Env:
#   CLAUDE_BIN             the CLI (default: claude on PATH)
#   CRITIC_MODEL           default claude-opus-5 (the harness's reviewer tier)
#   CRITIC_TIMEOUT         seconds per call, default 600
#   CRITIC_MAX_TURNS       default 20
#   CRITIC_ORDERS          presentation orders to ask in: 2 (default) or 1.
#                          1 is the old single-order behaviour — half the money,
#                          none of the concordance guarantee. Off by default
#                          because an uncalibrated pairwise verdict is what this
#                          protocol exists to stop trusting.
#   CRITIC_TIEBREAK_MARGIN axes-mean margin that breaks a disagreement,
#                          default 0.5 (the DOM wall scored 3.2 against the
#                          rejected render's 1.8 in the same position, so half a
#                          point is well inside the gap a human calls obvious)
#
# Exit 0 when a verdict was produced (pass OR fail — read the JSON), 1 when the
# critic could not produce one after a retry. A critic that cannot answer is
# never a pass: silence is the failure mode this whole stage exists to close,
# and a second call that dies is a failed critic rather than a quiet fallback to
# the one order we already know is biased.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../lib/common.sh
. "$SELF_DIR/../../../lib/common.sh"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
CRITIC_MODEL="${CRITIC_MODEL:-claude-opus-5}"
CRITIC_TIMEOUT="${CRITIC_TIMEOUT:-600}"
# One turn per image the critic opens, plus its own answer. A twelve-tile
# reference board, a champion sheet and a challenger sheet is fourteen turns
# before it has said anything — and a critic that runs out of them returns an
# envelope with is_error and no structured output, which reads exactly like a
# critic that refused. Six (the research's figure, for one bare sheet) failed
# every pairwise call this gate makes. Per call: the swap does not raise it.
CRITIC_MAX_TURNS="${CRITIC_MAX_TURNS:-20}"
CRITIC_SETTINGS="${CRITIC_SETTINGS:-$SELF_DIR/critic-settings.json}"
CRITIC_ORDERS="${CRITIC_ORDERS:-2}"
CRITIC_TIEBREAK_MARGIN="${CRITIC_TIEBREAK_MARGIN:-0.5}"
RUBRIC_MAX_LINES=200   # the rubric is repo input; bound what reaches the model

CHALLENGER=""; CHAMPION=""; REFS=""; RUBRIC="$SELF_DIR/rubric.md"; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --challenger) CHALLENGER="${2:-}"; shift 2 ;;
    --champion)   CHAMPION="${2:-}";   shift 2 ;;
    --refs)       REFS="${2:-}";       shift 2 ;;
    --rubric)     RUBRIC="${2:-}";     shift 2 ;;
    --out)        OUT="${2:-}";        shift 2 ;;
    *) echo "critic.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$CHALLENGER" ] && [ -n "$OUT" ] || {
  echo "usage: critic.sh --challenger SHEET.png --out VERDICT.json [--champion S] [--refs D] [--rubric F]" >&2
  exit 2
}
[ -f "$CHALLENGER" ] || { echo "critic.sh: no challenger sheet at $CHALLENGER" >&2; exit 2; }
[ -z "$CHAMPION" ] || [ -f "$CHAMPION" ] || {
  echo "critic.sh: no champion sheet at $CHAMPION" >&2
  exit 2
}
[ -f "$RUBRIC" ] || RUBRIC="$SELF_DIR/rubric.md"
case "$CRITIC_ORDERS" in
  1|2) ;;
  *) echo "critic.sh: CRITIC_ORDERS must be 1 or 2 (got '$CRITIC_ORDERS')" >&2; exit 2 ;;
esac
# Validated and normalised in one step: jq's --argjson wants JSON, and ".5" is
# a number to a human and a syntax error to it.
MARGIN=$(awk -v m="$CRITIC_TIEBREAK_MARGIN" \
  'BEGIN { if (m ~ /^[0-9]*\.?[0-9]+$/) printf "%g", m + 0 }')
[ -n "$MARGIN" ] || {
  echo "critic.sh: CRITIC_TIEBREAK_MARGIN must be a non-negative number (got '$CRITIC_TIEBREAK_MARGIN')" >&2
  exit 2
}

# The schema is stated to the CLI, which enforces it, AND summarised in the
# prompt, which is what makes the model fill it in with meaning rather than
# with something that merely validates. Composed with jq rather than written
# out twice: the one-image and two-image schemas must not drift apart, because
# the axes they share are the numbers the tiebreak subtracts.
AXIS_NAMES='["palette_discipline","grid_discipline","silhouette_readability",
             "composition","animation_continuity","style_match_to_reference"]'
AXES_SCHEMA=$(jq -nc --argjson names "$AXIS_NAMES" \
  '{type:"object",
    properties: ($names | map({(.): {type:"integer", minimum:1, maximum:5}}) | add),
    required: $names, additionalProperties: false}')
IMAGE_SCHEMA=$(jq -nc --argjson axes "$AXES_SCHEMA" \
  '{type:"object",
    properties: {axes:$axes, worst_axis:{type:"string"}, evidence:{type:"string"},
                 one_fix:{type:"string"},
                 verdict:{type:"string", enum:["pass","fail"]}},
    required: ["axes","worst_axis","evidence","one_fix","verdict"],
    additionalProperties: false}')
# One image, no comparison to make: the shape this script has always returned.
SCHEMA_SINGLE=$(jq -nc --argjson img "$IMAGE_SCHEMA" \
  '$img | .properties.pairwise = {type:"string", enum:["better","worse","tie","none"]}
        | .required += ["pairwise"]')
# Two images, no labels but A and B: both graded, one preferred.
SCHEMA_BLIND=$(jq -nc --argjson img "$IMAGE_SCHEMA" \
  '{type:"object",
    properties: {images: {type:"object", properties:{A:$img, B:$img},
                          required:["A","B"], additionalProperties:false},
                 preferred: {type:"string", enum:["A","B","tie"]}},
    required: ["images","preferred"], additionalProperties: false}')

# Reference board first: it is the stable half of the prompt, so putting it
# ahead of the volatile frames lets the prefix cache carry it between rounds —
# and between the two orders, which are otherwise the same tokens twice.
REF_LINE=""
if [ -n "$REFS" ] && [ -d "$REFS" ]; then
  REF_FILES=$(find "$REFS" -maxdepth 1 -type f \( -name '*.png' -o -name '*.jpg' \) | sort | head -12)
  if [ -n "$REF_FILES" ]; then
    REF_LINE="1. The reference board — the target look, frozen by a human. Read every one of these first:
$(printf '%s\n' "$REF_FILES" | sed 's/^/   - /')
"
  fi
fi

POSTURE="You are the visual critic of an automated pipeline. Another agent rendered the images below; you had no hand in them and you are grading someone else's work. The person who asked for this grade wants the truth, not encouragement — do not soften, do not congratulate, and do not assume the work is good because it is finished."
SHEET_NOTE="Each sheet is a contact sheet: consecutive frames of the same shot(s), one per tile, with the frame name printed under each tile. Refer to tiles by that name."
RUBRIC_TEXT=$(sed -n "1,${RUBRIC_MAX_LINES}p" "$RUBRIC")
AXES_NOTE="  - axes — each of the six, 1 (broken) to 5 (excellent). Score what you can see, not what you assume was intended.
  - worst_axis — the axis you scored lowest.
  - evidence — what IN THE IMAGE justifies that lowest score. Name the tile and the element. \"It feels unpolished\" is not evidence.
  - one_fix — the single most impactful change, one sentence, specific enough to implement. Camera, light and composition before more objects.
  - verdict — pass only if you would put this image on a screen in front of the person who commissioned it. Otherwise fail."

# The blind prompt. Every word that could identify which image is the incumbent
# has been taken out of it, and nothing replaces them: no "current", no "new",
# no "reigning". The model gets two contact sheets and the rubric.
blind_prompt() {  # $1 = the file shown as A, $2 = the file shown as B
  printf '%s\n' "$POSTURE

You are given two images, labelled A and B. You are told nothing else about either one — not where it came from, not which was made first, not which anyone prefers — and nothing but the pixels distinguishes them. Grade both with the same severity, and do not try to work out which answer is expected of you: there is none.

Read the images with the Read tool, in this order:
${REF_LINE}2. Image A: $1
3. Image B: $2

$SHEET_NOTE

The rubric you score against:

$RUBRIC_TEXT

Fill in the structured output:
- images.A and images.B — grade each image on its own, against the rubric, filling in the same five fields for each:
$AXES_NOTE
- preferred — which of the two is the better picture as a whole, judged against the reference board: \"A\", \"B\" or \"tie\". This is the answer that decides the run, so weigh it: an image that is merely different from the other is a tie, and an image that lost something the other one has is the weaker of the two."
}

# No champion to compare against: one image, one call, pairwise none.
single_prompt() {
  printf '%s\n' "$POSTURE

Read the images with the Read tool, in this order:
${REF_LINE}2. The image you are grading: $CHALLENGER

$SHEET_NOTE

The rubric you score against:

$RUBRIC_TEXT

Fill in the structured output:
$AXES_NOTE
- pairwise — answer \"none\". There is no second image in this call, so there is nothing to compare against."
}

run_once() {  # $1 = envelope path, $2 = prompt, $3 = schema, $4 = extra readable dir
  local args
  args=("$CLAUDE_BIN" -p "$2"
        --model "$CRITIC_MODEL"
        --settings "$CRITIC_SETTINGS"
        --permission-mode acceptEdits
        --max-turns "$CRITIC_MAX_TURNS"
        --json-schema "$3"
        --output-format json)
  # The blinded copies live in a scratch dir outside the worktree, so the
  # session has to be told it may read there. Nothing else is added to it.
  [ -z "$4" ] || args+=(--add-dir "$4")
  # env(1) sits INSIDE the timeout, never outside it: with_timeout is a shell
  # function and env cannot exec one — it fails instantly, which reads exactly
  # like a critic that returned nothing.
  ( with_timeout "$CRITIC_TIMEOUT" env -u ANTHROPIC_API_KEY "${args[@]}" </dev/null ) \
    > "$1" 2>"$1.err"
}

STARTED=$(date +%s)
TMP="${TMPDIR:-/tmp}/critic-$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

COST_TOTAL=0; COST_SEEN=0; TURNS_TOTAL=0; TURNS_SEEN=0; ATTEMPTS_TOTAL=0
CALL_OUT=""; CALL_SESSION=""; CALL_ATTEMPTS=0; CALL_ERROR=""
CALL_COST=0; CALL_TURNS=0; CALL_SECONDS=0

# What a call cost is owed to the caller whether or not it answered: a retry
# that produced prose still spent money and turns.
account_for() {  # $1 = envelope
  local c t
  c=$(jq -r '.total_cost_usd // empty' "$1" 2>/dev/null | head -1)
  if [ -n "$c" ]; then
    # %.10g, not %f: jq 1.7 prints a number back exactly as it was written, so
    # a padded "0.020000" would travel all the way into result.json.
    COST_TOTAL=$(awk -v a="$COST_TOTAL" -v b="$c" 'BEGIN{printf "%.10g", a + b}')
    CALL_COST=$(awk -v a="$CALL_COST" -v b="$c" 'BEGIN{printf "%.10g", a + b}')
    COST_SEEN=1
  fi
  t=$(jq -r '.num_turns // empty' "$1" 2>/dev/null | head -1)
  case "$t" in
    ''|*[!0-9]*) ;;
    *) TURNS_TOTAL=$((TURNS_TOTAL + t)); CALL_TURNS=$((CALL_TURNS + t)); TURNS_SEEN=1 ;;
  esac
}

# One model call, one retry. Why it produced nothing is the whole diagnosis, and
# the envelope says: a turn-exhausted run is is_error with a stop_reason of
# tool_use, a refusal is a plain result, and a CLI that never started leaves an
# empty file.
critic_call() {  # $1 = call index, $2 = prompt, $3 = schema, $4 = jq check, $5 = add-dir, $6 = what a wrong answer failed
  local idx="$1" prompt="$2" schema="$3" check="$4" adddir="$5" requirement="$6"
  local attempt envelope out why started
  CALL_OUT=""; CALL_SESSION=""; CALL_ATTEMPTS=0; CALL_ERROR=""
  CALL_COST=0; CALL_TURNS=0; CALL_SECONDS=0
  started=$(date +%s)
  for attempt in 1 2; do
    CALL_ATTEMPTS=$attempt
    ATTEMPTS_TOTAL=$((ATTEMPTS_TOTAL + 1))
    envelope="$TMP/call-$idx-attempt-$attempt.json"
    run_once "$envelope" "$prompt" "$schema" "$adddir" || true
    account_for "$envelope"
    # The envelope carries the verdict AND what it cost; both are wanted, and a
    # CLI that died leaves neither, which is itself the answer.
    out=$(jq -c 'select(.structured_output != null) | .structured_output' \
      "$envelope" 2>/dev/null | head -1)
    if [ -n "$out" ] && printf '%s' "$out" | jq -e "$check" >/dev/null 2>&1; then
      CALL_OUT="$out"
      CALL_SESSION=$(jq -r '.session_id // ""' "$envelope" 2>/dev/null) || CALL_SESSION=""
      CALL_SECONDS=$(( $(date +%s) - started ))
      return 0
    fi
    if [ -n "$out" ]; then
      why="$requirement"
    else
      why=$(jq -r 'if .is_error and ((.result // "") | length) > 0
                   then "the CLI reported an error: \(.result)"
                   elif .is_error
                   then "the CLI reported an error (stop_reason \(.stop_reason // "?"), \(.num_turns // "?") turns — raise CRITIC_MAX_TURNS if it ran out)"
                   else "no structured_output in the envelope" end' \
        "$envelope" 2>/dev/null) || why=""
      [ -n "$why" ] && [ "$why" != null ] || why="the CLI wrote nothing"
    fi
    CALL_ERROR="the critic returned no valid structured output: $why"
    echo "critic.sh: call $idx attempt $attempt returned no usable verdict — $why$([ "$attempt" = 1 ] && echo ' — retrying once')" >&2
    # Both streams, clipped: a CLI that refused says so on stderr, a model that
    # ignored the schema says so on stdout, and the two failures need opposite
    # fixes. The full pair is kept beside the verdict — the scratch dir goes at
    # exit, and "the critic returned nothing" is not a bug report anyone can act
    # on without the nothing itself.
    head -c 300 "$envelope.err" 2>/dev/null >&2 || true
    head -c 300 "$envelope" 2>/dev/null >&2 || true
    echo >&2
    cp "$envelope" "$OUT.call-$idx-attempt-$attempt.log" 2>/dev/null || true
    cp "$envelope.err" "$OUT.call-$idx-attempt-$attempt.err" 2>/dev/null || true
  done
  CALL_SECONDS=$(( $(date +%s) - started ))
  return 1
}

# Every exit that is not a verdict writes the same shape the gate reads, so the
# fix round is handed a sentence rather than a silence — with whatever the dead
# run already cost, because that money was spent either way.
fail_out() {  # $1 = the one-line reason
  local secs cost turns cal
  secs=$(( $(date +%s) - STARTED ))
  cost=null; [ "$COST_SEEN" = 1 ] && cost="$COST_TOTAL"
  turns=null; [ "$TURNS_SEEN" = 1 ] && turns="$TURNS_TOTAL"
  cal=null
  [ "$(printf '%s' "$RUNS_JSON" | jq -r 'length')" = 0 ] || \
    cal=$(jq -nc --argjson runs "$RUNS_JSON" --argjson orders "$CRITIC_ORDERS" \
      '{orders:$orders, runs:$runs, concordant:false, rule:"none — the critic failed",
        tiebreak:{used:false, margin:null, delta:null},
        champion_axes:null, challenger_axes:null}')
  jq -n --arg model "$CRITIC_MODEL" --arg err "$1" \
        --argjson attempts "$ATTEMPTS_TOTAL" --argjson secs "$secs" \
        --argjson cost "$cost" --argjson turns "$turns" --argjson cal "$cal" \
    '{ran:true,model:$model,verdict:"fail",pairwise:"none",worst_axis:"",
      evidence:"",one_fix:"",axes:null,cost_usd:$cost,num_turns:$turns,
      session_id:null,attempts:$attempts,seconds:$secs,error:$err,
      calibration:$cal}' > "$OUT"
  echo "critic: FAILED — $1" >&2
  exit 1
}

RUNS_JSON='[]'
CALL1_OUT=""
CALL1_SESSION=""

if [ -z "$CHAMPION" ]; then
  # ---- one image, nothing to compare it against ------------------------------
  critic_call 1 "$(single_prompt)" "$SCHEMA_SINGLE" \
    '.verdict and .axes and (.pairwise == "none")' "" \
    "pairwise must be none when no champion was supplied" \
    || fail_out "$CALL_ERROR"
  CALL1_OUT="$CALL_OUT"
  CALL1_SESSION="$CALL_SESSION"
  PAIRWISE=none
  CALIBRATION=null
  printf 'critic: one image, no champion (%ss, $%s, %s turn(s))\n' \
    "$CALL_SECONDS" "$CALL_COST" "$CALL_TURNS"
else
  # ---- the same pair, both ways round ---------------------------------------
  BLIND_CHECK='.images.A.axes and .images.B.axes and .images.A.verdict and .images.B.verdict
               and ((.preferred == "A") or (.preferred == "B") or (.preferred == "tie"))'
  BLIND_WHY='the two-image answer must score images.A and images.B and prefer "A", "B" or "tie"'
  ORDERS_LIST=1
  [ "$CRITIC_ORDERS" = 2 ] && ORDERS_LIST="1 2"
  for order in $ORDERS_LIST; do
    if [ "$order" = 1 ]; then A_SHEET="$CHAMPION"; B_SHEET="$CHALLENGER"
    else                      A_SHEET="$CHALLENGER"; B_SHEET="$CHAMPION"; fi
    # Blind means blind down to the file name: a path with "champion" in it
    # answers the question the prompt refuses to.
    BLIND_DIR="$TMP/call-$order"
    mkdir -p "$BLIND_DIR"
    if ! cp "$A_SHEET" "$BLIND_DIR/image-a.png" \
       || ! cp "$B_SHEET" "$BLIND_DIR/image-b.png"; then
      fail_out "could not stage blinded copies of the two sheets in $BLIND_DIR"
    fi
    critic_call "$order" "$(blind_prompt "$BLIND_DIR/image-a.png" "$BLIND_DIR/image-b.png")" \
      "$SCHEMA_BLIND" "$BLIND_CHECK" "$BLIND_DIR" "$BLIND_WHY" \
      || fail_out "presentation order $order of $CRITIC_ORDERS produced no verdict — $CALL_ERROR"

    PREFERRED=$(printf '%s' "$CALL_OUT" | jq -r '.preferred')
    # Un-map: what the answer says about the CHALLENGER, whichever label it wore.
    if [ "$PREFERRED" = tie ]; then RUN_PAIRWISE=tie
    elif [ "$order" = 1 ]; then
      if [ "$PREFERRED" = B ]; then RUN_PAIRWISE=better; else RUN_PAIRWISE=worse; fi
    else
      if [ "$PREFERRED" = A ]; then RUN_PAIRWISE=better; else RUN_PAIRWISE=worse; fi
    fi
    if [ "$order" = 1 ]; then CALL1_OUT="$CALL_OUT"; CALL1_SESSION="$CALL_SESSION"; fi

    RUNS_JSON=$(jq -c --argjson v "$CALL_OUT" --argjson order "$order" \
      --arg a "$A_SHEET" --arg b "$B_SHEET" --arg pw "$RUN_PAIRWISE" \
      --arg session "$CALL_SESSION" --argjson cost "$CALL_COST" \
      --argjson turns "$CALL_TURNS" --argjson attempts "$CALL_ATTEMPTS" \
      --argjson secs "$CALL_SECONDS" \
      '. + [{order:$order, a:$a, b:$b, preferred:$v.preferred, pairwise:$pw,
             axes_a:$v.images.A.axes, axes_b:$v.images.B.axes,
             verdict_a:$v.images.A.verdict, verdict_b:$v.images.B.verdict,
             cost_usd:$cost, num_turns:$turns, attempts:$attempts, seconds:$secs,
             session_id:(if $session == "" then null else $session end)}]' \
      <<<"$RUNS_JSON")
    printf 'critic: order %s (A=%s, B=%s) preferred=%s — challenger %s (%ss, $%s, %s turn(s))\n' \
      "$order" "$(basename "$A_SHEET")" "$(basename "$B_SHEET")" "$PREFERRED" \
      "$RUN_PAIRWISE" "$CALL_SECONDS" "$CALL_COST" "$CALL_TURNS"
  done

  # Concordance first, the axes only when the orders disagree. The margin is a
  # margin and not a threshold on purpose: absolute VLM scores are calibrated by
  # nothing, but the DIFFERENCE between two sheets graded in the same call, in
  # both positions, is the one absolute number this protocol has earned.
  CALIBRATION=$(jq -nc --argjson runs "$RUNS_JSON" --argjson orders "$CRITIC_ORDERS" \
    --argjson margin "$MARGIN" '
      def mean(o): ([o[]] | add) / ([o[]] | length);
      def r4: (. * 10000 | round) / 10000;
      ($runs | map(if .order == 1 then mean(.axes_b) else mean(.axes_a) end)
             | add / length) as $chal
      | ($runs | map(if .order == 1 then mean(.axes_a) else mean(.axes_b) end)
               | add / length) as $champ
      | (($chal - $champ) | r4) as $delta
      | (($runs | map(.pairwise) | unique | length) == 1) as $same_answer
      | (($orders > 1) and $same_answer) as $concordant
      | {orders: $orders, runs: $runs, concordant: $concordant,
         rule: (if $orders == 1 then "single order — CRITIC_ORDERS=1, no concordance check"
                elif $concordant then "concordance — both presentation orders agreed"
                else "axes margin — the presentation orders disagreed" end),
         tiebreak: {used: (($concordant | not) and ($orders > 1)),
                    margin: $margin, delta: $delta},
         champion_axes: ($champ | r4), challenger_axes: ($chal | r4)}')
  PAIRWISE=$(jq -r --argjson m "$MARGIN" '
    if .orders == 1 or .concordant then .runs[0].pairwise
    elif .tiebreak.delta > 0 and .tiebreak.delta >= $m then "better"
    elif .tiebreak.delta < 0 and .tiebreak.delta <= (0 - $m) then "worse"
    else "tie" end' <<<"$CALIBRATION")
fi

SECONDS_TAKEN=$(( $(date +%s) - STARTED ))
COST_JSON=null; [ "$COST_SEEN" = 1 ] && COST_JSON="$COST_TOTAL"
TURNS_JSON=null; [ "$TURNS_SEEN" = 1 ] && TURNS_JSON="$TURNS_TOTAL"

# The top-level fields are the contract the gate, the fix round and result.json
# have always read, and they describe the CHALLENGER. Its absolute grade comes
# from the first call — the order that presents it as B, which is exactly the
# presentation the single-order protocol used — so `evidence` and `one_fix`
# belong to one reading of one image rather than being spliced from two. Both
# calls, in full, are in `calibration.runs`; a disagreement about the absolute
# verdict is visible there.
#
# `cost_usd` and `num_turns` are summed over every call AND every retry inside
# them — a retry that answered with prose still spent the money — and `attempts`
# is the number of CLI invocations that took, so a clean two-order round reads
# 2 and a round that had to retry reads more. `session_id` is the first call's;
# each run carries its own.
CHALLENGER_BLOCK=$(printf '%s' "$CALL1_OUT" | jq -c 'if .images then .images.B else . end')

jq -n --argjson v "$CHALLENGER_BLOCK" --arg model "$CRITIC_MODEL" \
      --arg pairwise "$PAIRWISE" --argjson cal "$CALIBRATION" \
      --argjson cost "$COST_JSON" --argjson turns "$TURNS_JSON" \
      --arg session "$CALL1_SESSION" --argjson attempts "$ATTEMPTS_TOTAL" \
      --argjson secs "$SECONDS_TAKEN" \
  '{ran:true, model:$model, verdict:$v.verdict, pairwise:$pairwise,
    worst_axis:$v.worst_axis, evidence:$v.evidence, one_fix:$v.one_fix,
    axes:$v.axes, cost_usd:$cost, num_turns:$turns,
    session_id:(if $session == "" then null else $session end),
    attempts:$attempts, seconds:$secs, error:null, calibration:$cal}' > "$OUT"

printf 'critic: verdict=%s pairwise=%s worst=%s (%s) (%ss, $%s, %s turn(s))\n' \
  "$(jq -r .verdict "$OUT")" "$(jq -r .pairwise "$OUT")" \
  "$(jq -r .worst_axis "$OUT")" \
  "$(jq -r '.calibration.rule // "no champion — absolute grade only"' "$OUT")" \
  "$SECONDS_TAKEN" "$(jq -r '.cost_usd // "?"' "$OUT")" \
  "$(jq -r '.num_turns // "?"' "$OUT")"
exit 0
