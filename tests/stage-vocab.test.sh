#!/usr/bin/env bash
# The stage-text wire format, as a test.
#
# run-task.sh's stage() writes prose into a run dir's `status`; three surfaces
# parse it back into "who is working" — wall/server.js, statusline.sh, and
# status.sh --watch through statusline.sh. That was three independent copies of
# a format nothing checked, and it is the most fragile coupling in the harness:
# renaming a literal in run-task.sh degrades every one of them silently.
#
# wall/stage-vocab.json is now the single table, and this suite is the thing
# that makes it one:
#   1. the table is well formed, and DISJOINT — exactly one row wins any stage
#   2. every stage string run-task.sh (and sync-pr.sh) emits is covered by it,
#      and every row of it is reached by something they emit or is flagged inert
#   3. wall/server.js resolves each row to the actor, key and state it declares
#   4. statusline.sh's hardcoded case arms answer the same, colour included
#
# Read-only: run-task.sh and sync-pr.sh are grepped, never run. Nothing outside
# a temp scratch file is written.
#
# Usage: bash tests/stage-vocab.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
VOCAB="$SRC/wall/stage-vocab.json"
SERVER="$SRC/wall/server.js"
SL="$SRC/statusline.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stage-vocab-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
unset NO_COLOR   # the colour column is part of the contract, so keep the SGRs

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
list_ok() {  # $1 = accumulated offenders, $2 = ok label, $3 = fail label
  if [ -z "$1" ]; then ok "$2"; else bad "$3:$1"; fi
}

for bin in node jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "  FAIL stage vocab: $bin is required to run this suite"
    echo; printf 'stage vocab: 0 passed, 1 failed\n'; exit 1
  fi
done

# --- the stage strings the pipeline can write ---------------------------------
# Extracted from source, exactly as tests/statusline.test.sh does it: a shell
# expansion becomes the placeholder X, because what the table has to recognise
# is the literal frame around it.
echo "== the stage strings run-task.sh emits =="
STAGES="$ROOT/stages.txt"
grep -hoE 'stage "[^"]+"' "$SRC/run-task.sh" "$SRC/sync-pr.sh" \
  | sed -e 's/^stage "//' -e 's/"$//' \
        -e 's/\$[A-Za-z_][A-Za-z0-9_]*/X/g' -e 's/\$[0-9]/X/g' \
  | sort -u > "$STAGES"
n=$(grep -c '' < "$STAGES" | tr -d ' ')
if [ "$n" -ge 20 ]; then ok "emissions: found $n stage literals"
else bad "emissions: only $n stage literals found — extraction broken?"; fi

# `stage "done: $STATUS"` and fail()'s `stage "done: $1"` both flatten to
# "done: X" above, which hides the only part of a terminal stage that carries
# meaning. Expand them over the statuses run-task.sh can actually write, so the
# table is judged on the real words and not on the placeholder.
STATUSES="$ROOT/statuses.txt"
grep -ohE '(^|[^_A-Za-z])STATUS="[a-z_]+"' "$SRC/run-task.sh" \
  | tr -d ' \t' | sed -e 's/^STATUS="//' -e 's/"$//' | sort -u > "$STATUSES"
n=$(grep -c '' < "$STATUSES" | tr -d ' ')
if [ "$n" -ge 8 ]; then ok "emissions: found $n terminal statuses"
else bad "emissions: only $n terminal statuses found — extraction broken?"; fi
while IFS= read -r s; do
  [ -n "$s" ] && printf 'done: %s\n' "$s" >> "$STAGES"
done < "$STATUSES"

# --- the table, and what it resolves ------------------------------------------
# One node pass answers everything the JS side owes: the table's own shape, that
# exactly one row matches each emitted stage, that no row is dead, and that
# wall/server.js — the real file, not a restatement of it — resolves every row
# to what it declares.
echo "== the vocabulary table =="
REPORT="$ROOT/report.json"
node -e '
  const fs = require("fs");
  const [vocabPath, serverPath, stagesPath] = process.argv.slice(1);
  const doc = JSON.parse(fs.readFileSync(vocabPath, "utf8"));
  const rows = doc.stages;
  const server = require(serverPath);
  const STATES = new Set(["active", "alarm", "ready", "failed"]);
  const COLORS = new Set(["red", "green", "yellow", "blue", "magenta", "cyan", "dim"]);

  const malformed = [];
  for (const row of rows) {
    const label = row.pattern || JSON.stringify(row);
    for (const field of ["pattern", "actor", "key", "state", "color", "example"]) {
      if (typeof row[field] !== "string" || row[field] === "") malformed.push(label + ": no " + field);
    }
    if (!STATES.has(row.state)) malformed.push(label + ": state [" + row.state + "] is not one the wall has");
    if (!COLORS.has(row.color)) malformed.push(label + ": colour [" + row.color + "] is not one statusline.sh has");
    if (!Object.hasOwn(server.FLOOR_OF, row.key) && row.key !== "done") {
      malformed.push(label + ": key [" + row.key + "] has no rung on the ladder");
    }
    try { new RegExp(row.pattern, "i"); } catch { malformed.push(label + ": pattern does not compile"); }
    try { if (row.unless) new RegExp(row.unless, "i"); } catch { malformed.push(label + ": unless does not compile"); }
  }

  // The table resolved the way the wall resolves it, but reporting EVERY row
  // that claims a string rather than the first — which is what makes
  // disjointness checkable instead of assumed.
  const claimants = (text) => rows.filter((row) =>
    new RegExp(row.pattern, "i").test(text) &&
    !(row.unless && new RegExp(row.unless, "i").test(text)));

  const ambiguousExample = [], selfExample = [];
  for (const row of rows) {
    const hits = claimants(row.example);
    if (hits.length !== 1) ambiguousExample.push(row.pattern + ": " + hits.length + " rows claim its example");
    else if (hits[0] !== row) selfExample.push(row.pattern + ": its example is won by [" + hits[0].pattern + "]");
  }

  const stages = fs.readFileSync(stagesPath, "utf8").split("\n").filter((s) => s.trim() !== "");
  const uncovered = [], ambiguous = [];
  const reached = new Set();
  for (const text of stages) {
    const hits = claimants(text);
    if (hits.length === 0) uncovered.push(text);
    else if (hits.length > 1) ambiguous.push(text + " -> " + hits.map((h) => h.pattern).join(" & "));
    if (hits.length) reached.add(rows.indexOf(hits[0]));
  }
  const dead = rows.filter((row, i) => !row.inert && !reached.has(i)).map((row) => row.pattern);
  const notInert = rows.filter((row, i) => row.inert && reached.has(i)).map((row) => row.pattern);

  // And the consumer this file exists for, asked through its own front door.
  const drift = [];
  for (const row of rows) {
    const { actor, actorKey } = server.actorOf(row.example);
    const state = server.stateOf(row.example);
    if (actor !== row.actor) drift.push(row.pattern + ": actor [" + actor + "] != [" + row.actor + "]");
    if (actorKey !== row.key) drift.push(row.pattern + ": key [" + actorKey + "] != [" + row.key + "]");
    if (state !== row.state) drift.push(row.pattern + ": state [" + state + "] != [" + row.state + "]");
  }
  const unknown = server.actorOf("something nobody has a row for");

  process.stdout.write(JSON.stringify({
    rows: rows.length,
    inert: rows.filter((row) => row.inert).length,
    malformed, ambiguousExample, selfExample, uncovered, ambiguous, dead, notInert, drift,
    fallbackActor: unknown.actor + "/" + unknown.actorKey,
    fallbackState: server.stateOf("something nobody has a row for"),
    visualFailedState: server.stateOf("done: visual_failed"),
    visualFailedFloor: server.floorOf("done: visual_failed", "done"),
    visualGateFloor: server.floorOf("visual gate — rendering the shots (script, no model)", "gate"),
  }));
' "$VOCAB" "$SERVER" "$STAGES" > "$REPORT" 2>"$ROOT/node.err"
if [ ! -s "$REPORT" ]; then
  bad "vocab: the table and wall/server.js load ($(tr '\n' ' ' < "$ROOT/node.err"))"
  echo; printf 'stage vocab: %d passed, %d failed\n' "$pass" "$((fail))"; exit 1
fi
r() { jq -r "$1" < "$REPORT"; }
rlist() { jq -r "$1 | if length == 0 then \"\" else \" \" + join(\" | \") end" < "$REPORT"; }

n=$(r '.rows')
if [ "$n" -ge 20 ]; then ok "vocab: the table carries $n rows ($(r '.inert') of them inert)"
else bad "vocab: only $n rows — is wall/stage-vocab.json still the whole vocabulary?"; fi
list_ok "$(rlist '.malformed')" "vocab: every row declares a pattern, actor, key, state, colour and example" \
                                "vocab: malformed rows"
list_ok "$(rlist '.ambiguousExample')" "vocab: each row's example is claimed by exactly one row" \
                                       "vocab: examples more than one row claims"
list_ok "$(rlist '.selfExample')" "vocab: and that row is the one it belongs to" \
                                  "vocab: examples won by the wrong row"

echo "== run-task.sh emissions vs. the table =="
list_ok "$(rlist '.uncovered')" "coverage: every stage string the pipeline writes has a row" \
                                "coverage: stage strings no row claims"
list_ok "$(rlist '.ambiguous')" "coverage: and exactly one row claims it — the table is disjoint" \
                                "coverage: stage strings two rows claim"
list_ok "$(rlist '.dead')" "coverage: every row is reached by something the pipeline emits" \
                           "coverage: rows nothing can ever reach"
list_ok "$(rlist '.notInert')" "coverage: the rows flagged inert really are inert in this repo" \
                               "coverage: rows flagged inert that this repo does emit"

echo "== wall/server.js reads the table =="
list_ok "$(rlist '.drift')" "server: resolves every row to the actor, key and state it declares" \
                            "server: wall/server.js disagrees with the table"
check "server: an unrecognised stage is an honest '?', not a guess" \
  "$(r '.fallbackActor')" "?/unknown"
check "server: and stays a live panel rather than claiming an outcome" \
  "$(r '.fallbackState')" "active"

# The creative harness's rows, live here ahead of re-unification. A visual gate
# that gave up is a failure, and it burns out on the rung its live stage stands
# on rather than on a roof the run never reached.
echo "== the creative harness's visual rows =="
for p in '^visual fix.*Claude' '^visual fix.*Codex' '^visual gate'; do
  if jq -e --arg p "$p" '[.stages[] | select(.pattern == $p)] | length == 1' "$VOCAB" >/dev/null; then
    ok "visual: the table carries $p"
  else
    bad "visual: the table carries $p"
  fi
done
check "visual: done: visual_failed is a failure, not a ship" "$(r '.visualFailedState')" "failed"
check "visual: and it parks on the rung the visual gate stands on" \
  "$(r '.visualFailedFloor')" "$(r '.visualGateFloor')"

# --- statusline.sh -------------------------------------------------------------
# The bash copy is deliberately hardcoded — a statusline re-renders on every
# prompt and must not pay for a jq read to name an actor — so the whole point of
# this block is that the copy is checked rather than trusted. harness_actor is
# called directly (status.sh --watch sources it the same way) because the
# rendered line hides every `done:` run, and those rows are contract too.
echo "== statusline.sh agrees with the table =="
# shellcheck source=../statusline.sh
. "$SL"
color_of() {  # $1 = the table's colour name -> the SGR statusline.sh uses
  case "$1" in
    red) printf '%s' "$C_RED" ;;      green)   printf '%s' "$C_GREEN" ;;
    yellow) printf '%s' "$C_YELLOW" ;; blue)   printf '%s' "$C_BLUE" ;;
    magenta) printf '%s' "$C_MAGENTA" ;; cyan) printf '%s' "$C_CYAN" ;;
    dim) printf '%s' "$C_DIM" ;;
    *) printf 'no-such-colour' ;;
  esac
}
actors=''; colors=''
while IFS=$'\t' read -r pattern actor color example; do
  [ -n "$pattern" ] || continue
  harness_actor "$example"
  [ "$HARNESS_ACTOR" = "$actor" ] || \
    actors="$actors $pattern: statusline says [$HARNESS_ACTOR], the table says [$actor]"
  [ "$HARNESS_ACTOR_COLOR" = "$(color_of "$color")" ] || \
    colors="$colors $pattern: colour is not $color"
done < <(jq -r '.stages[] | [.pattern, .actor, .color, .example] | @tsv' "$VOCAB")
list_ok "$actors" "statusline: every row resolves to the actor the table names" \
                  "statusline: actors that have drifted from the table"
list_ok "$colors" "statusline: and to the colour the table names" \
                  "statusline: colours that have drifted from the table"
harness_actor "something nobody has a row for"
check "statusline: an unrecognised stage is the same honest '?'" "$HARNESS_ACTOR" "?"

echo
printf 'stage vocab: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
