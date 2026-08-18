#!/usr/bin/env bash
# The verifier stage, in two halves:
#
#   1. The stage inside run-task.sh — guarded by HARNESS_VERIFY, an interpreter,
#      a key file and the adapter's presence; capped by with_timeout; and unable
#      to change anything the run does. A verifier that is off, absent, broken,
#      hung or writing garbage must leave the same status, the same PR and the
#      same PR body as a run with no verifier at all.
#   2. verify.py itself — the trajectory it builds out of a run dir (the
#      implementer's stream across attempts, the gate rounds, the reviewer's
#      evidence, the final diff and the standing gate verdict), the criteria it
#      parses out of the brief, its clipping and elision, and the call it makes
#      to the library. --dry-run needs neither the library nor a key, which is
#      what lets CI run it; the scoring half runs against a stand-in
#      `llm_verifier` module on PYTHONPATH, the same technique the fake
#      `claude`/`codex` binaries below use for the models.
#
# Nothing real is contacted: `claude`, `codex`, `gh` and `curl` are fakes on
# PATH, the interpreter is a fake, and the library is a stub.
#
# Usage: bash tests/verify.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0; skipped=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip()  { skipped=$((skipped+1)); printf '  skip %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists(){ if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# ---------------------------------------------------------------------------
# Fixture: a harness dir, a repo with a bare remote, and fakes for every binary
# ---------------------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
VERIFY_MODE="$ROOT/verify-mode"
VERIFY_ARGS="$ROOT/verify-args.log"
KEY_FILE="$ROOT/verifier-api-key"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES"
printf 'score\n' > "$VERIFY_MODE"
: > "$VERIFY_ARGS"
printf 'sk-not-a-real-key-0123456789\n' > "$KEY_FILE"
chmod 600 "$KEY_FILE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp "$SRC/verify.py" "$SRCDIR/verify.py"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/metrics.sh" "$SRC/status.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"

cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*)
      INSTALL_CMD=''
      GATE_CMD="${TEST_GATE_CMD:-true}"
      ;;
  esac
}
EOF

BARE="$ROOT/origin.git"
REPO="$ROOT/greenapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# Implementer stand-in: commits a diff and writes its notes, so every dispatch
# below reaches the review stage with something to look at.
cat > "$FAKES/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
case "$prompt" in *"reviewer stage"*) exit 0 ;; esac
seq 1 30 >> impl.txt
printf '# notes\n\nAdded impl.txt.\n' > .harness/implementer-notes.md
git add -A
git commit -q -m "feat: fixture change"
EOF

# Reviewer stand-in: leaves notes, which is evidence enough for `reviewed`.
cat > "$FAKES/codex" <<'EOF'
#!/usr/bin/env bash
wt=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-C" ]; then wt="$a"; break; fi
  prev="$a"
done
printf '# review\n\nEverything is sound.\n' > "$wt/.harness/review-notes.md"
EOF

cat > "$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF

# The interpreter stand-in. run-task.sh invokes it as
#   <python> <adapter> <run-dir> <worktree> <base-ref>
# so $2 is the run dir every mode writes into. One fake, one mode file, every
# shape the stage has to survive.
cat > "$FAKES/fakepy" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$VERIFY_ARGS"
run="\$2"
case "\$(cat "$VERIFY_MODE")" in
  score)
    cat > "\$run/verify.json" <<'JSON'
{
  "score": 0.83,
  "at_implementer": 0.71,
  "criteria": [{"name": "The endpoint exists | safely", "score": 0.9}],
  "model": "deepseek-v4-flash",
  "provider": "deepseek",
  "evaluations": 3,
  "steps": 42,
  "elided_steps": 0,
  "usage": {"calls": 4, "input_tokens": 1000, "output_tokens": 40},
  "seconds": 12.5
}
JSON
    echo "verify: score 0.83"
    ;;
  garbage)  printf 'not json {{{\n' > "\$run/verify.json" ;;
  boom)     echo "boom" >&2; exit 7 ;;
  score_boom)
    printf '{"score":0.99}\n' > "\$run/verify.json"
    echo "failed after publishing a score" >&2
    exit 7
    ;;
  hang)     sleep 6 ;;
  score_hang)
    printf '{"score":0.99}\n' > "\$run/verify.json"
    sleep 6
    ;;
  quiet)    echo "no trajectory: no implementer stream" >&2; exit 3 ;;
esac
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh" "$FAKES/fakepy"

RC=0; OUT=""; RUN=""
TEST_GATE_CMD=true
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  cp "$ROOT/brief.md" "$RUN/brief.md"
  # shellcheck disable=SC2086
  env -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      -u HARNESS_VERIFY -u HARNESS_VERIFY_TIMEOUT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      TEST_GATE_CMD="$TEST_GATE_CMD" \
      HARNESS_REVIEW_NETWORK=0 HARNESS_NOTIFY=0 \
      HARNESS_VERIFY_PYTHON="$FAKES/fakepy" \
      VERIFIER_API_KEY_FILE="$KEY_FILE" \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
result() { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }

# The brief every dispatch is handed: a title, a Problem section and three
# acceptance criteria, one of which wraps onto a second line.
cat > "$ROOT/brief.md" <<'EOF'
# Add the export endpoint

- **Ticket**: FIX-1

## Problem

The dashboard has no way to export anything, so people screenshot the table.

## Acceptance criteria
- [ ] The endpoint exists
- [ ] It returns CSV
  and XLSX
- [x] Tests cover both formats

## Out of scope
- The import side
EOF

STAGE_LINE='verify — trajectory score (verifier · third vendor)'

# ---------------------------------------------------------------------------
echo "== the stage is off, and the run is exactly what it always was =="
# ---------------------------------------------------------------------------
dispatch V-OFF "HARNESS_VERIFY=0"
check "off: the run ships" "$(result .status)" "ready"
check "off: and the dispatch exits 0" "$RC" "0"
check "off: no score reaches result.json" "$(result .metrics.verifier)" ""
has_not "$(cat "$RUN/timeline")" "$STAGE_LINE" "off: and no stage line is written"
file_has "$RUN/verify.log" "skipped: HARNESS_VERIFY=0" "off: verify.log says which knob turned it off"
file_has_not "$RUN/pr-body.md" "## Verifier" "off: the PR body carries no verifier section"
cp "$RUN/pr-body.md" "$ROOT/body-without-verifier.md"
BASELINE_STATUS="$(result .status)"
BASELINE_PR="$(result .pr_url)"

# ---------------------------------------------------------------------------
echo "== every guard is one line in verify.log and nothing else =="
# ---------------------------------------------------------------------------
dispatch V-NOKEY "VERIFIER_API_KEY_FILE=$ROOT/no-such-key"
check "no key: the run still ships" "$(result .status)" "$BASELINE_STATUS"
check "no key: with the same PR" "$(result .pr_url)" "$BASELINE_PR"
check "no key: and no score" "$(result .metrics.verifier)" ""
file_has "$RUN/verify.log" "skipped: no verifier key file at $ROOT/no-such-key" \
  "no key: the reason names the file it looked for"
check "no key: the PR body is byte-identical to a run with no verifier at all" \
  "$(sed 1d "$RUN/pr-body.md")" "$(sed 1d "$ROOT/body-without-verifier.md")"

dispatch V-NOPY "HARNESS_VERIFY_PYTHON=$ROOT/no-such-python"
check "no interpreter: the run still ships" "$(result .status)" "$BASELINE_STATUS"
file_has "$RUN/verify.log" "skipped: no verifier interpreter at $ROOT/no-such-python" \
  "no interpreter: the reason names the interpreter and how to get one"
file_has "$RUN/verify.log" "install.sh --verifier" "no interpreter: including the flag that builds it"

# The adapter has to be beside run-task.sh; an install that predates it simply
# does not verify.
mv "$SRCDIR/verify.py" "$ROOT/verify.py.away"
dispatch V-NOADAPTER ""
mv "$ROOT/verify.py.away" "$SRCDIR/verify.py"
check "no adapter: the run still ships" "$(result .status)" "$BASELINE_STATUS"
file_has "$RUN/verify.log" "skipped: no verify.py beside run-task.sh" \
  "no adapter: and says so"

# ---------------------------------------------------------------------------
echo "== a score reaches result.json, the plate data and the PR body =="
# ---------------------------------------------------------------------------
printf 'score\n' > "$VERIFY_MODE"
dispatch V-SCORE ""
check "scored: the run ships as before" "$(result .status)" "ready"
check "scored: the score is in result.json" "$(result .metrics.verifier.score)" "0.83"
check "scored: with the implementer-end checkpoint beside it" \
  "$(result .metrics.verifier.at_implementer)" "0.71"
check "scored: and the per-criterion detail" \
  "$(result '.metrics.verifier.criteria | length')" "1"
file_has "$RUN/timeline" "$STAGE_LINE" "scored: the stage announced itself"
file_has "$RUN/verify.log" "verifier: 0.83" "scored: verify.log records the score it got"
file_has "$RUN/pr-body.md" "## Verifier" "scored: the PR body gains the section"
file_has "$RUN/pr-body.md" "Trajectory score **0.83** (implementer 0.71 → final 0.83) · deepseek-v4-flash · 3 evaluations" \
  "scored: whose headline reads as one sentence"
file_has "$RUN/pr-body.md" "| Criterion | Score |" "scored: with the per-criterion table"
file_has "$RUN/pr-body.md" '| The endpoint exists \| safely | 0.9 |' \
  "scored: and a pipe in a criterion cannot break the table"
file_has "$RUN/pr-body.md" "Advisory only" "scored: and the sentence saying it gates nothing"
has "$(cat "$VERIFY_ARGS")" "$RUNS/V-SCORE" "scored: the adapter was handed the run dir"
has "$(cat "$VERIFY_ARGS")" "origin/main" "scored: and the base ref to diff against"
file_has_not "$RUN/verify.log" "sk-not-a-real-key" "scored: the key is not in verify.log"
file_has_not "$RUN/result.json" "sk-not-a-real-key" "scored: nor in result.json"
if grep -qF 'sk-not-a-real-key' "$VERIFY_ARGS"; then
  bad "scored: the key never travels in argv"
else
  ok "scored: the key never travels in argv"
fi

# The two read-only surfaces render it.
STATUS_OUT="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/status.sh" V-SCORE)"
has "$STATUS_OUT" "verifier: 0.83 (implementer 0.71) · 1 criteria · deepseek-v4-flash" \
  "surfaces: status.sh <RUN-ID> prints an explicit verifier line"
TABLE_OUT="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/status.sh")"
has "$TABLE_OUT" "SCORE" "surfaces: the one-shot table has a SCORE column"
check "surfaces: with this run's score in it" \
  "$(printf '%s\n' "$TABLE_OUT" | awk '$1 == "V-SCORE" { print $NF }')" "0.83"
METRICS_OUT="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh")"
has "$METRICS_OUT" "SCORE" "surfaces: metrics.sh has a score column"
check "surfaces: carrying the same number" \
  "$(printf '%s\n' "$METRICS_OUT" | awk '$1 == "V-SCORE" { print $NF }')" "0.83"
CSV_OUT="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh" --csv)"
has "$CSV_OUT" "wall_minutes,score" "surfaces: and so does the CSV header"
check "surfaces: a run with no score renders blank rather than zero" \
  "$(printf '%s\n' "$METRICS_OUT" | awk '$1 == "V-OFF" { print $NF }')" "-"

# ---------------------------------------------------------------------------
echo "== a broken verifier cannot touch the run =="
# ---------------------------------------------------------------------------
printf 'boom\n' > "$VERIFY_MODE"
dispatch V-BOOM ""
check "crash: the run still ships" "$(result .status)" "$BASELINE_STATUS"
check "crash: and the dispatch still exits 0" "$RC" "0"
has "$OUT" "DONE status=ready" "crash: the console reports the run it always would have"
file_has "$RUN/verify.log" "boom" "crash: while the verifier's own output lands in its own log"
check "crash: with the same PR" "$(result .pr_url)" "$BASELINE_PR"
check "crash: and no score" "$(result .metrics.verifier)" ""
check "crash: exactly one failure line" \
  "$(grep -c '^verifier: failed' "$RUN/verify.log" | tr -d ' ')" "1"
file_has "$RUN/verify.log" "verifier: failed (exit 7)" "crash: naming the exit code"
check "crash: the PR body is byte-identical to a run with no verifier at all" \
  "$(sed 1d "$RUN/pr-body.md")" "$(sed 1d "$ROOT/body-without-verifier.md")"

# A process can publish its atomic file and still fail afterwards. Exit status
# owns the attempt: downstream readers must not mistake that abandoned artifact
# for a successful score.
printf 'score_boom\n' > "$VERIFY_MODE"
dispatch V-SCORE-BOOM ""
check "late crash: a score written before failure is discarded" \
  "$(result .metrics.verifier)" ""
check "late crash: no verifier section reaches the PR body" \
  "$(sed 1d "$RUN/pr-body.md")" "$(sed 1d "$ROOT/body-without-verifier.md")"
if [ ! -e "$RUN/verify.json" ]; then
  ok "late crash: the failed attempt leaves no live score artifact"
else
  bad "late crash: the failed attempt leaves no live score artifact"
fi

printf 'garbage\n' > "$VERIFY_MODE"
dispatch V-GARBAGE ""
check "garbage: the run still ships" "$(result .status)" "$BASELINE_STATUS"
check "garbage: an unparseable verify.json is no score at all" "$(result .metrics.verifier)" ""
file_has "$RUN/verify.log" "verifier: failed (no score in verify.json)" \
  "garbage: recorded as the failure it is, not as an exit-0 success"
check "garbage: and no verifier section in the PR body" \
  "$(sed 1d "$RUN/pr-body.md")" "$(sed 1d "$ROOT/body-without-verifier.md")"

printf 'quiet\n' > "$VERIFY_MODE"
dispatch V-SKIP ""
check "adapter skip: the run still ships" "$(result .status)" "$BASELINE_STATUS"
file_has "$RUN/verify.log" "verifier: skipped (no trajectory: no implementer stream)" \
  "adapter skip: exit 3 is recorded as a skip with the adapter's own reason"

printf 'hang\n' > "$VERIFY_MODE"
dispatch V-HANG "HARNESS_VERIFY_TIMEOUT=1"
check "timeout: the run still ships" "$(result .status)" "$BASELINE_STATUS"
check "timeout: with the same PR" "$(result .pr_url)" "$BASELINE_PR"
file_has "$RUN/verify.log" "verifier: failed (timed out after 1s)" \
  "timeout: and the cap is recorded as what it is"

printf 'score_hang\n' > "$VERIFY_MODE"
dispatch V-SCORE-HANG "HARNESS_VERIFY_TIMEOUT=1"
printf 'score\n' > "$VERIFY_MODE"
check "late timeout: a score written before the cap is discarded" \
  "$(result .metrics.verifier)" ""
check "late timeout: no verifier section reaches the PR body" \
  "$(sed 1d "$RUN/pr-body.md")" "$(sed 1d "$ROOT/body-without-verifier.md")"
if [ ! -e "$RUN/verify.json" ]; then
  ok "late timeout: the killed attempt leaves no live score artifact"
else
  bad "late timeout: the killed attempt leaves no live score artifact"
fi

# ---------------------------------------------------------------------------
echo "== the stage runs on every arm that reaches the review =="
# ---------------------------------------------------------------------------
dispatch V-NOREVIEW "HARNESS_SKIP_REVIEW=1"
check "no_review: the ablation arm is scored too" "$(result .metrics.verifier.score)" "0.83"
check "no_review: and is still the arm it asked for" "$(result .arm)" "no_review"

TEST_GATE_CMD='exit 1'
dispatch V-ROTATE ""
check "gate_failed: a run that will not ship is scored anyway" \
  "$(result .metrics.verifier.score)" "0.83"
check "gate_failed: which is the status it ends on" "$(result .status)" "gate_failed"
dispatch V-ROTATE ""
TEST_GATE_CMD=true
exists "rotation: the first attempt's score is preserved" "$RUN/attempts/1/verify.json"
exists "rotation: with its log" "$RUN/attempts/1/verify.log"
exists "rotation: and the live attempt writes its own" "$RUN/verify.json"
check "rotation: the live score is this attempt's" "$(result .attempt)" "2"

# ---------------------------------------------------------------------------
echo "== metrics.sh --report drops unscored runs instead of counting them zero =="
# ---------------------------------------------------------------------------
REPORTH="$ROOT/report-harness"; RRUNS="$REPORTH/runs"
mkdir -p "$RRUNS"
mkrun() { mkdir -p "$RRUNS/$1"; printf '%s\n' "$2" > "$RRUNS/$1/result.json"; }
mkrun S-1 '{"ticket":"S-1","status":"ready","arm":"full","review":"reviewed",
  "worktree":"/w/myapp-s-1",
  "metrics":{"wall_seconds":600,"verifier":{"score":0.4,"at_implementer":0.2}}}'
mkrun S-2 '{"ticket":"S-2","status":"ready","arm":"full","review":"reviewed",
  "worktree":"/w/myapp-s-2",
  "metrics":{"wall_seconds":600,"verifier":{"score":0.8,"at_implementer":0.5}}}'
mkrun S-3 '{"ticket":"S-3","status":"ready","arm":"full","review":"reviewed",
  "worktree":"/w/myapp-s-3",
  "metrics":{"wall_seconds":600,"verifier":{"score":0.9,"at_implementer":0.9}}}'
# A run from before the verifier existed: no field at all, and no zero either.
mkrun S-LEGACY '{"ticket":"S-LEGACY","status":"ready","arm":"full",
  "worktree":"/w/myapp-s-legacy","metrics":{"wall_seconds":600}}'
REPORT="$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
has "$REPORT" "verify score 0.80 0.90 3" \
  "report: median/P90 over the three runs that were scored, at two decimals"
has "$REPORT" "pipeline vitals · 4 runs" "report: while every run is still counted as a run"
LEGACY_TABLE="$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh")"
has "$LEGACY_TABLE" "S-LEGACY" "report: and a legacy result.json renders in the table without erroring"

# ---------------------------------------------------------------------------
echo "== verify.py: the trajectory it builds =="
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "adapter: python3 is not on this machine — verify.py is untested here"
else

ADAPTER="$SRC/verify.py"
AROOT="$ROOT/adapter"
ARUN="$AROOT/run"; AWT="$AROOT/wt"
mkdir -p "$ARUN/attempts/1" "$AWT"

# An earlier attempt that ran out of turns, rotated where run-task.sh puts it.
cat > "$ARUN/attempts/1/opus-stream.jsonl" <<'EOF'
{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the router before I touch it"}]}}
{"type":"result","subtype":"error_max_turns","result":"ran out of turns"}
EOF
# The live attempt: narration, an action with its observed output, a closing
# message — and a thinking block, which is not a step.
cat > "$ARUN/opus-stream.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"Adding the export endpoint now"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"src/export.ts"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"the file was written"}]}}
{"type":"result","subtype":"success","result":"endpoint added, notes written"}
EOF
printf '1 fail 30\tnpm test\n2 pass 40\t\n' > "$ARUN/gate-rounds.log"
cp "$ROOT/brief.md" "$ARUN/brief.md"
mkdir -p "$AWT/.harness"
printf '# review\n\nEverything is sound.\n' > "$AWT/.harness/review-notes.md"
printf '=== gate round 2 ===\nresult: pass\nshown: all 3 lines\n=== gate output follows ===\nall green\n' \
  > "$AWT/.harness/gate-latest.log"

git init -q "$AWT"
git -C "$AWT" config user.email t@t
git -C "$AWT" config user.name t
printf 'a\n' > "$AWT/f.txt"
git -C "$AWT" add f.txt
git -C "$AWT" commit -q -m "feat: implementer commit"
git -C "$AWT" update-ref refs/remotes/origin/main "$(git -C "$AWT" rev-parse HEAD)"
git -C "$AWT" rev-parse HEAD > "$ARUN/opus-head"
printf 'b\n' >> "$AWT/f.txt"
git -C "$AWT" add f.txt
git -C "$AWT" commit -q -m "refactor: reviewer commit"
# The base the diff is taken against is the tree BEFORE the implementer, so both
# commits are in it.
git -C "$AWT" update-ref refs/remotes/origin/base "$(git -C "$AWT" rev-parse HEAD~1)"

# A poisoned module that explodes on import, plus a key file with a secret in
# it: --dry-run must touch neither.
mkdir -p "$AROOT/poison"
printf 'raise RuntimeError("the dry run imported the library")\n' > "$AROOT/poison/llm_verifier.py"

# Extra knobs travel as env(1) assignments inside this call, never as a shell
# prefix on the function: bash leaves an assignment that prefixes a FUNCTION
# call in the environment afterwards, which would silently re-knob every check
# below it.
adapter() {  # rest = further VAR=VAL assignments, then the command
  env PYTHONPATH="$AROOT/poison" \
      HARNESS_VERIFY_KEY_FILE="$KEY_FILE" \
      "$@"
}
DRY="$(adapter python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run 2>"$ROOT/dry.err")"
DRY_RC=$?
check "dry run: exits 0 with neither the library nor a key" "$DRY_RC" "0"
check "dry run: and says nothing on stderr" "$(cat "$ROOT/dry.err")" ""
check "dry run: emits valid JSON" "$(printf '%s' "$DRY" | jq -r 'type')" "object"
check "dry run: the whole trajectory, in pipeline order" \
  "$(printf '%s' "$DRY" | jq -r '.labels | join(",")')" \
  "impl:narration,impl:result,impl:narration,impl:action,impl:result,gate:round,gate:round,review:notes,review:commits,final:diff,final:gate"
check "dry run: the step count agrees with the list" \
  "$(printf '%s' "$DRY" | jq -r '.steps')" "11"
check "dry run: the first step is the oldest attempt's first words" \
  "$(printf '%s' "$DRY" | jq -r '.first')" \
  "The agent says:
Reading the router before I touch it"
has "$(printf '%s' "$DRY" | jq -r '.last')" "FINAL STATE — the last test gate verdict" \
  "dry run: and the last is the standing gate verdict"
has_not "$(printf '%s' "$DRY" | jq -r '.last')" "all green" \
  "dry run: whose header is taken without the gate output behind it"
has_not "$DRY" "private reasoning" "dry run: a thinking block is not a step"
has_not "$DRY" "sk-not-a-real-key" "dry run: and no key is read"
check "dry run: the checkpoints are the implementer's last step and the last step" \
  "$(printf '%s' "$DRY" | jq -r '.checkpoints | join(",")')" "5,11"

# The action step is the shape the verifier's prompt is written for: what was
# done, and what came back.
FULL="$(adapter python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run)"
STEPS_JSON="$ROOT/steps.json"; printf '%s' "$FULL" > "$STEPS_JSON"
DIFF_SEEN="$(adapter python3 "$ADAPTER" "$ARUN" "$AWT" origin/base --dry-run \
  | jq -r '.labels | join(",")')"
has "$DIFF_SEEN" "final:diff" "dry run: a branch with a diff against its base carries it as the final state"

check "criteria: one per checkbox under the acceptance heading" \
  "$(printf '%s' "$DRY" | jq -r '.criteria | length')" "3"
check "criteria: a wrapped bullet is one criterion, rejoined" \
  "$(printf '%s' "$DRY" | jq -r '.criteria[1]')" "It returns CSV and XLSX"
check "criteria: a ticked box is a criterion like any other" \
  "$(printf '%s' "$DRY" | jq -r '.criteria[2]')" "Tests cover both formats"
check "criteria: and nothing from the section after it" \
  "$(printf '%s' "$DRY" | jq -r '[.criteria[] | select(test("import"))] | length')" "0"
check "criteria: HARNESS_VERIFY_MAX_CRITERIA caps them" \
  "$(adapter HARNESS_VERIFY_MAX_CRITERIA=2 python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run \
     | jq -r '.criteria | length')" "2"
check "criteria: and 0 asks for the overall score alone" \
  "$(adapter HARNESS_VERIFY_MAX_CRITERIA=0 python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run \
     | jq -r '.criteria | length')" "0"

printf '# No rubric here\n\n## Problem\n\nNothing to check.\n' > "$AROOT/no-criteria.md"
cp "$ARUN/brief.md" "$AROOT/brief.keep"
cp "$AROOT/no-criteria.md" "$ARUN/brief.md"
check "criteria: a brief with no acceptance section scores overall only" \
  "$(adapter python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run | jq -r '.criteria | length')" "0"
cp "$AROOT/brief.keep" "$ARUN/brief.md"

# Clipping and elision, both disclosed.
CLIPPED="$(adapter HARNESS_VERIFY_STEP_CHARS=60 python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run)"
check "clip: no step is wider than HARNESS_VERIFY_STEP_CHARS" \
  "$(printf '%s' "$CLIPPED" | jq -r '[.first, .last] | map(length) | max <= 60')" "true"
has "$(printf '%s' "$CLIPPED" | jq -r '.last')" "clipped: this step was" \
  "clip: and a clipped step says how much there was"
ELIDED="$(adapter HARNESS_VERIFY_MAX_CHARS=400 python3 "$ADAPTER" "$ARUN" "$AWT" origin/main --dry-run)"
check "elide: the middle of an over-budget trajectory is dropped" \
  "$(printf '%s' "$ELIDED" | jq -r '.elided_steps > 0')" "true"
has "$(printf '%s' "$ELIDED" | jq -r '.labels | join(",")')" "elided" \
  "elide: leaving one marker step in its place"
check "elide: which accounts for exactly what it dropped" \
  "$(printf '%s' "$ELIDED" | jq -r '.steps + .elided_steps - 1')" \
  "$(printf '%s' "$DRY" | jq -r '.steps')"
check "elide: and the whole trajectory is inside the budget" \
  "$(printf '%s' "$ELIDED" | jq -r '.chars <= 400')" "true"

# A run whose implementer left nothing behind has no trajectory, and a skip is
# the honest answer — never a fabricated step and never a score.
EMPTY="$AROOT/empty-run"
mkdir -p "$EMPTY"
cp "$ARUN/brief.md" "$EMPTY/brief.md"
adapter python3 "$ADAPTER" "$EMPTY" "$AWT" origin/main --dry-run > /dev/null 2>"$ROOT/empty.err"
check "no trajectory: exit 3, the skip code" "$?" "3"
has "$(cat "$ROOT/empty.err")" "no trajectory" "no trajectory: with one line saying why"
adapter python3 "$ADAPTER" "$ARUN" --dry-run >/dev/null 2>&1
check "usage: too few arguments exits 2" "$?" "2"

# ---------------------------------------------------------------------------
echo "== verify.py: the call it makes, and the file it writes =="
# ---------------------------------------------------------------------------
# A stand-in for the library — the same technique as the fake CLIs above. It
# records every track() call and refuses to build a client without the key, so a
# green run here proves the key was read in-process and handed to the backend.
STUB="$AROOT/stub"
mkdir -p "$STUB"
cat > "$STUB/llm_verifier.py" <<'EOF'
"""Stand-in for llm-as-a-verifier: records the calls, invents the scores."""
import json
import os

DEFAULT_MODEL = "stub-default-model"
CALLS = os.environ["VERIFY_STUB_CALLS"]


class _Progress:
    def __init__(self, scores):
        self.scores = scores
        self.final = scores[-1]


class _Client(dict):
    pass


def create_client():
    # The real package loads .env with setdefault() immediately before choosing
    # a provider. This catches an adapter that removes unused selector vars and
    # thereby lets a local .env silently restore a higher-priority backend.
    if os.path.exists(".env"):
        with open(".env", encoding="utf-8") as fh:
            for line in fh:
                if line.strip() and not line.lstrip().startswith("#") and "=" in line:
                    name, value = line.strip().split("=", 1)
                    os.environ.setdefault(name, value)
    backend = None
    for name in ("OPENAI_BASE_URL", "DEEPSEEK_API_KEY", "VERTEX_API_KEY"):
        if os.environ.get(name):
            backend = name
            break
    if backend is None:
        raise RuntimeError("no backend env var was set")
    client = _Client(backend=backend, key=os.environ.get(backend))
    if backend == "DEEPSEEK_API_KEY":
        client._llm_verifier_model = "deepseek-v4-flash"
    return client


def track(problem, steps, checkpoint_steps=None, n_evaluations=1, model=None, client=None):
    with open(CALLS, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "problem": problem,
            "steps": len(steps),
            "checkpoint_steps": checkpoint_steps,
            "n_evaluations": n_evaluations,
            "model": model,
            "backend": (client or {}).get("backend"),
            "key_seen": (client or {}).get("key"),
        }) + "\n")
    return _Progress([0.5, 0.75][: len(checkpoint_steps or [1])])


def token_usage():
    return {"calls": 4, "input_tokens": 900, "cached_input_tokens": 100,
            "uncached_input_tokens": 800, "output_tokens": 40,
            "reasoning_tokens": 12, "cache_hit_rate": 0.11}
EOF

CALLS="$AROOT/stub-calls.jsonl"
: > "$CALLS"
env PYTHONPATH="$STUB" VERIFY_STUB_CALLS="$CALLS" \
    HARNESS_VERIFY_KEY_FILE="$KEY_FILE" HARNESS_VERIFY_EVALS=3 \
    python3 "$ADAPTER" "$ARUN" "$AWT" origin/main > "$ROOT/score.out" 2>"$ROOT/score.err"
check "score: exits 0" "$?" "0"
check "score: and says nothing on stderr" "$(cat "$ROOT/score.err")" ""
V="$ARUN/verify.json"
exists "score: verify.json is written" "$V"
check "score: the overall score is the last checkpoint" "$(jq -r .score "$V")" "0.75"
check "score: and the first checkpoint is what the implementer alone was worth" \
  "$(jq -r .at_implementer "$V")" "0.5"
check "score: one entry per acceptance criterion" "$(jq -r '.criteria | length' "$V")" "3"
check "score: each with a name and a number" \
  "$(jq -r '[.criteria[] | select(.name != "" and (.score | type) == "number")] | length' "$V")" "3"
check "score: the model is the client-resolved DeepSeek default, not Gemini's global default" \
  "$(jq -r .model "$V")" "deepseek-v4-flash"
check "score: the provider is recorded" "$(jq -r .provider "$V")" "deepseek"
check "score: so is K" "$(jq -r .evaluations "$V")" "3"
check "score: and the size of the trajectory it read" "$(jq -r .steps "$V")" "11"
check "score: with nothing elided at the default budget" "$(jq -r .elided_steps "$V")" "0"
check "score: token usage is carried over" "$(jq -r .usage.input_tokens "$V")" "900"
check "score: including the cache columns" "$(jq -r .usage.cached_input_tokens "$V")" "100"
check "score: and how long it took" "$(jq -r '.seconds | type' "$V")" "number"
file_has_not "$V" "sk-not-a-real-key" "score: the key is in no field of verify.json"

check "call: one overall pass plus one per criterion" "$(grep -c '' < "$CALLS" | tr -d ' ')" "4"
check "call: the overall pass checkpoints at the implementer end and at the end" \
  "$(jq -r 'select(.checkpoint_steps | length == 2) | .checkpoint_steps | join(",")' "$CALLS")" "5,11"
check "call: every pass runs K evaluations" \
  "$(jq -s '[.[] | .n_evaluations] | unique | join(",")' "$CALLS")" '"3"'
check "call: every pass reads the whole trajectory" \
  "$(jq -s '[.[] | .steps] | unique | join(",")' "$CALLS")" '"11"'
check "call: the criterion passes score one checkpoint, the final state" \
  "$(jq -s '[.[] | select((.checkpoint_steps | length) == 1) | .checkpoint_steps[0]] | unique | join(",")' "$CALLS")" '"11"'
check "call: each criterion is framed as the graders only check" \
  "$(jq -s '[.[] | select(.problem | test("checks exactly one thing"))] | length' "$CALLS")" "3"
check "call: while the overall pass carries the whole acceptance list" \
  "$(jq -s '[.[] | select(.problem | test("checks every one of these"))] | length' "$CALLS")" "1"
check "call: the brief title reaches the problem statement" \
  "$(jq -s '[.[] | select(.problem | test("Add the export endpoint"))] | length' "$CALLS")" "4"
check "call: and so does the Problem section" \
  "$(jq -s '[.[] | select(.problem | test("people screenshot the table"))] | length' "$CALLS")" "4"
check "call: the key reached the backend the provider asked for" \
  "$(jq -s '[.[] | .backend] | unique | join(",")' "$CALLS")" '"DEEPSEEK_API_KEY"'
check "call: read from the file rather than from an argument" \
  "$(jq -s '[.[] | .key_seen] | unique | join(",")' "$CALLS")" '"sk-not-a-real-key-0123456789"'

: > "$CALLS"
DOTENV_CWD="$AROOT/dotenv-cwd"
mkdir -p "$DOTENV_CWD"
printf 'OPENAI_BASE_URL=https://wrong.invalid/v1\nDEEPSEEK_API_KEY=wrong-key\n' \
  > "$DOTENV_CWD/.env"
( cd "$DOTENV_CWD" && \
  env PYTHONPATH="$STUB" VERIFY_STUB_CALLS="$CALLS" \
      HARNESS_VERIFY_KEY_FILE="$KEY_FILE" HARNESS_VERIFY_PROVIDER=vertex \
      HARNESS_VERIFY_MODEL=gemini-2.5-flash HARNESS_VERIFY_MAX_CRITERIA=0 \
      python3 "$ADAPTER" "$ARUN" "$AWT" origin/main >/dev/null 2>&1 )
check "provider: vertex selects the Vertex backend and nothing else" \
  "$(jq -s '[.[] | .backend] | unique | join(",")' "$CALLS")" '"VERTEX_API_KEY"'
check "provider: a local .env cannot restore a higher-priority backend" \
  "$(jq -s '[.[] | .key_seen] | unique | join(",")' "$CALLS")" '"sk-not-a-real-key-0123456789"'
check "provider: a pinned model is passed through" \
  "$(jq -r '.model' "$CALLS")" "gemini-2.5-flash"
check "provider: and is what verify.json records" "$(jq -r .model "$V")" "gemini-2.5-flash"
check "provider: MAX_CRITERIA=0 makes exactly one call" "$(grep -c '' < "$CALLS" | tr -d ' ')" "1"
check "provider: overall-only still gives that one call the full acceptance list" \
  "$(jq -s '[.[] | select(.problem | test("It returns CSV"))] | length' "$CALLS")" "1"

# No key is a skip, not a failure and not a zero.
env PYTHONPATH="$STUB" VERIFY_STUB_CALLS="$CALLS" \
    HARNESS_VERIFY_KEY_FILE="$AROOT/no-key" \
    python3 "$ADAPTER" "$ARUN" "$AWT" origin/main >/dev/null 2>"$ROOT/nokey.err"
check "no key: the adapter skips with exit 3" "$?" "3"
has "$(cat "$ROOT/nokey.err")" "no key" "no key: and one line saying so"

# A machine with no library at all is the same kind of skip.
env HARNESS_VERIFY_KEY_FILE="$KEY_FILE" PYTHONPATH="$AROOT/nowhere" \
    python3 "$ADAPTER" "$ARUN" "$AWT" origin/main >/dev/null 2>"$ROOT/nolib.err"
NOLIB_RC=$?
if python3 -c 'import llm_verifier' 2>/dev/null; then
  skip "no library: llm_verifier is installed on this machine — the skip path is untestable here"
else
  check "no library: exits 3 rather than failing the stage" "$NOLIB_RC" "3"
  has "$(cat "$ROOT/nolib.err")" "library missing" "no library: with one line saying so"
fi

fi   # end: python3 is available

echo
printf 'verifier: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
