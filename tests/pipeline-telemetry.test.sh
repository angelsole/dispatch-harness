#!/usr/bin/env bash
# The pipeline's telemetry about itself, in three parts:
#
#   1. Review-stage integrity — a review that produced no commits and no notes
#      in less time than the diff takes to read is retried once and then
#      recorded, loudly, as a review that did not happen. Evidence decides, not
#      duration: a fast review that writes its notes is a real review.
#   2. Gate-round telemetry — every gate round records how long it took and
#      which command it died on (the command that actually returned nonzero,
#      wherever in the gate's own shell it lives), without breaking readers of
#      the old two-field shape.
#   3. Attempt lifecycle — each invocation's telemetry is rotated into
#      attempts/<n>/ instead of being truncated, the resume counter is this
#      invocation's alone, and a run that already reached `done: ready` is not
#      dispatched again.
#   4. `metrics.sh --report` — the aggregate health picture, per attempt as well
#      as per run, computed from result.json files alone.
#
# Nothing real is contacted. `claude` (implementer), `codex` (reviewer), `gh`
# (the PR) and `curl` (ntfy) are fake binaries on PATH driven by mode files, and
# every run is a real run-task.sh invocation against a fabricated repo with a
# local bare remote — the technique tests/capacity-preflight.test.sh uses.
#
# Usage: bash tests/pipeline-telemetry.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-telemetry-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
CLAUDE_CALLS="$ROOT/claude-calls.log"
CODEX_CALLS="$ROOT/codex-calls.log"
CURL_LOG="$ROOT/curl.log"
CLAUDE_MODE="$ROOT/claude-mode"
CODEX_MODE="$ROOT/codex-mode"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES"
: > "$CLAUDE_CALLS"; : > "$CODEX_CALLS"; : > "$CURL_LOG"
printf 'commit\n' > "$CLAUDE_MODE"
printf 'notes\n' > "$CODEX_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/metrics.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"

# The gate command is pinned per dispatch through TEST_GATE_CMD so one fixture
# repo can play both a green gate and a two-step chain whose second step fails.
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

# --- fakes -------------------------------------------------------------------
# Implementer stand-in. `commit` leaves a diff too big to review in a blink (the
# floor only applies to those); `tiny` leaves a two-line one.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
printf 'claude\n' >> "$CLAUDE_CALLS"
case "\$(cat "$CLAUDE_MODE")" in
  commit) seq 1 30 >> impl.txt ;;
  tiny)   printf 'one\ntwo\n' >> impl.txt ;;
esac
git add -A
git commit -q -m "feat: fixture change"
EOF

# Reviewer stand-in: every mode is one of the shapes the integrity check has to
# tell apart. `instant` is the confirmed failure — it returns at once having
# touched nothing at all.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then wt="\$a"; break; fi
  prev="\$a"
done
printf 'codex %s\n' "\$wt" >> "$CODEX_CALLS"
case "\$(cat "$CODEX_MODE")" in
  instant) echo "codex: done" ;;
  notes)   printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md" ;;
  commits) ( cd "\$wt" && printf 'reviewer touched this\n' >> impl.txt \
             && git add -A && git commit -q -m "refactor: reviewer change" ) ;;
  reject)  printf '# rejected\n\nWrong approach entirely.\n' > "\$wt/.harness/REJECTED.md" ;;
esac
EOF

cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
EOF

# The PR step: no PR exists yet (view fails), and creating one prints a URL.
cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF

# A two-step gate chain: the first step passes, the second fails. Which of them
# `failed_step` names is the whole contract.
cat > "$FAKES/gate-lint" <<'EOF'
#!/usr/bin/env bash
echo "linting: clean"
EOF
cat > "$FAKES/gate-tests" <<'EOF'
#!/usr/bin/env bash
echo "tests: 1 failing"
exit 1
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh" \
  "$FAKES/gate-lint" "$FAKES/gate-tests"

# --- the harness under test ---------------------------------------------------
codex_calls() { grep -c '^codex ' "$CODEX_CALLS" 2>/dev/null | tr -d ' '; }

RC=0; OUT=""; RUN=""
TEST_GATE_CMD=true    # repos.local.sh reads this; a gate command has spaces in
                      # it, so it travels as its own variable, not an override
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      TEST_GATE_CMD="$TEST_GATE_CMD" \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=telemetry-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
result()    { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
stage_now() { cut -d' ' -f2- < "$RUN/status" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== a review that never happened: retried once, then recorded honestly =="
# ---------------------------------------------------------------------------
printf 'instant\n' > "$CODEX_MODE"
dispatch REV-SILENT ""
check "silent: the review ran twice — one retry, no more" "$(codex_calls)" "2"
exists "silent: the retry has its own log" "$RUN/codex-1-retry.log"
check "silent: result.json says the review failed silently" "$(result .review)" "failed_silent"
check "silent: and records the honest arm" "$(result .arm)" "no_review"
file_has "$RUN/timeline" "review failed silently — diff is unreviewed" \
  "silent: the status line says so in the words the wall and statusline read"
file_has "$CURL_LOG" "review failed silently — diff is unreviewed" \
  "silent: and it goes out over the existing ntfy mechanics"
has "$OUT" "this diff is UNREVIEWED" "silent: the console is blunt about it"
check "silent: the run still finishes — the gate passed, the PR is real" \
  "$(result .status)" "ready"
check "silent: and exits 0, because nothing about the run failed" "$RC" "0"
check "silent: the pinned arm is untouched, so a re-dispatch still tries to review" \
  "$(cat "$RUN/arm")" "full"

# ---------------------------------------------------------------------------
echo "== evidence, not duration, decides =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
BEFORE=$(codex_calls)
dispatch REV-NOTES ""
check "notes: an instant review that writes notes is not retried" \
  "$(codex_calls)" "$((BEFORE + 1))"
absent "notes: no retry log" "$RUN/codex-1-retry.log"
check "notes: it is recorded as a real review" "$(result .review)" "reviewed"
check "notes: the arm stays full" "$(result .arm)" "full"
has_not "$OUT" "review failed silently" "notes: nothing loud is said"
exists "notes: and the notes are harvested into the run dir" "$RUN/review-notes.md"

printf 'commits\n' > "$CODEX_MODE"
BEFORE=$(codex_calls)
dispatch REV-COMMITS ""
check "commits: a review that commits but writes no notes is accepted" \
  "$(result .review)" "reviewed"
check "commits: and is not retried" "$(codex_calls)" "$((BEFORE + 1))"
check "commits: the reviewer's commit is attributed to the reviewer" \
  "$(result .metrics.codex_commits)" "1"

printf 'reject\n' > "$CODEX_MODE"
dispatch REV-REJECT ""
check "reject: a rejection is the most engaged review there is" \
  "$(result .review)" "reviewed"
check "reject: and the run is rejected as before" "$(result .status)" "rejected"

# The floor is what buys the retry; without it, a no-evidence review is recorded
# but never paid for twice.
printf 'instant\n' > "$CODEX_MODE"
BEFORE=$(codex_calls)
dispatch REV-NOFLOOR "HARNESS_REVIEW_MIN_SECONDS=0"
check "floor: a review above the floor is not retried" "$(codex_calls)" "$((BEFORE + 1))"
check "floor: it is recorded as no_evidence, not as a failure" \
  "$(result .review)" "no_evidence"
check "floor: so the arm is left alone" "$(result .arm)" "full"

# A two-line diff genuinely can be reviewed in seconds: crying wolf over it
# would teach everyone to ignore the alarm.
printf 'tiny\n' > "$CLAUDE_MODE"
BEFORE=$(codex_calls)
dispatch REV-TRIVIAL ""
printf 'commit\n' > "$CLAUDE_MODE"
check "trivial: a trivial diff never triggers the retry" "$(codex_calls)" "$((BEFORE + 1))"
check "trivial: and is recorded as no_evidence" "$(result .review)" "no_evidence"

# ---------------------------------------------------------------------------
echo "== the arms that have no review say so =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
dispatch REV-SKIPARM "HARNESS_SKIP_REVIEW=1"
check "skip arm: review is recorded as skipped" "$(result .review)" "skipped"
check "skip arm: with the no_review arm" "$(result .arm)" "no_review"

BEFORE=$(codex_calls)
dispatch REV-NOCODEX "CODEX_BIN=$ROOT/no-such-codex"
check "no codex: review is recorded as skipped" "$(result .review)" "skipped"
check "no codex: and nothing was asked to review" "$(codex_calls)" "$BEFORE"

# ---------------------------------------------------------------------------
echo "== gate rounds record what failed and what it cost =="
# ---------------------------------------------------------------------------
dispatch GATE-PASS "CODEX_BIN=$ROOT/no-such-codex"
check "pass: one round" "$(result '.metrics.gate_rounds | length')" "1"
check "pass: it passed" "$(result '.metrics.gate_rounds[0].result')" "pass"
check "pass: seconds are recorded as a number" \
  "$(result '.metrics.gate_rounds[0].seconds | type')" "number"
check "pass: a passing round names no failing step" \
  "$(result '.metrics.gate_rounds[0].failed_step')" ""

TEST_GATE_CMD='gate-lint && gate-tests'
dispatch GATE-FAIL "CODEX_BIN=$ROOT/no-such-codex"
check "fail: the round failed" "$(result '.metrics.gate_rounds[0].result')" "fail"
check "fail: and names the SECOND step of the chain, not the first or the whole line" \
  "$(result '.metrics.gate_rounds[0].failed_step')" "gate-tests"
check "fail: seconds are recorded" \
  "$(result '.metrics.gate_rounds[0].seconds | type')" "number"
check "fail: the run parks at gate_failed as before" "$(result .status)" "gate_failed"
# The gate log is what the reviewer reads: the tracer must be invisible in it.
check "fail: the gate log is exactly the gate's own output" \
  "$(cat "$RUN/gate-1.log")" "linting: clean
tests: 1 failing"
check "fail: and so is the copy handed to the reviewer" \
  "$(cat "$ROOT/greenapp-gate-fail/.harness/gate-latest.log")" "linting: clean
tests: 1 failing"

# Old readers parse the first two whitespace-separated fields (wall/server.js) or
# jq's `.result` (metrics.sh's table). Both must be unaffected.
check "compat: the log's first two fields are unchanged" \
  "$(awk '{ print $1, $2 }' "$RUN/gate-rounds.log")" "1 fail"
check "compat: metrics.sh's gate column still renders" \
  "$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh" \
      | awk '$1 == "GATE-FAIL" { print $8 }')" "fail"

# The failing command inside a subshell in the MIDDLE of a chain: ERR is
# suppressed there by bash, so inherited DEBUG tracking must keep the round from
# blaming the preceding command — the OLYX-1601 misattribution.
TEST_GATE_CMD='gate-lint && ( cd . && gate-tests ) && gate-lint'
dispatch GATE-SUBSHELL "CODEX_BIN=$ROOT/no-such-codex"
check "subshell: the step that returned nonzero is the one recorded" \
  "$(result '.metrics.gate_rounds[0].failed_step')" "gate-tests"

# Same for a shell function in the middle of the chain.
TEST_GATE_CMD='f() { cd . && gate-tests; }; gate-lint && f && gate-lint'
dispatch GATE-FUNC "CODEX_BIN=$ROOT/no-such-codex"
check "function: a failure inside a function names the command, not the function" \
  "$(result '.metrics.gate_rounds[0].failed_step')" "gate-tests"

# Inherited DEBUG also sees a command substitution while expanding the real
# step; the ERR trap must restore the full outer command after it fails.
TEST_GATE_CMD='gate-lint && gate-tests --rev=$(gate-lint)'
dispatch GATE-SUBST "CODEX_BIN=$ROOT/no-such-codex"
check "expansion: an expansion helper is never recorded as the failing step" \
  "$(result '.metrics.gate_rounds[0].failed_step')" 'gate-tests --rev=$(gate-lint)'

printf 'notes\n' > "$CODEX_MODE"
TEST_GATE_CMD='gate-lint && gate-tests'
dispatch GATE-ROUNDS ""
check "rounds: a full review loop records all three rounds" \
  "$(result '.metrics.gate_rounds | length')" "3"
check "rounds: every one of them names the failing step" \
  "$(result '[.metrics.gate_rounds[].failed_step] | unique | join(",")')" "gate-tests"
TEST_GATE_CMD=true

# ---------------------------------------------------------------------------
echo "== resumes are counted, not inferred =="
# ---------------------------------------------------------------------------
# A failing gate: re-dispatching a run that did NOT reach ready is the normal
# path, and the one a resume counter is about.
TEST_GATE_CMD='exit 1'
dispatch RESUME-1 ""
check "resume: a first dispatch has no resumes" "$(result .metrics.turn_resumes)" "0"
dispatch RESUME-1 ""
check "resume: the second dispatch resumed the worker once" \
  "$(result .metrics.turn_resumes)" "1"
file_has "$RUN/stages.log" "resuming — Opus (Claude sub)" "resume: from the stage it counts"
# stages.log is append-only across every invocation. The count is this
# invocation's, not the run's lifetime total.
dispatch RESUME-1 ""
check "resume: a third dispatch still reports one — its own, not the history's" \
  "$(result .metrics.turn_resumes)" "1"
check "resume: while the log has kept every invocation's" \
  "$(grep -c 'resuming — Opus' "$RUN/stages.log" | tr -d ' ')" "2"

# ---------------------------------------------------------------------------
echo "== every attempt keeps its own telemetry =="
# ---------------------------------------------------------------------------
check "attempts: the third dispatch is attempt 3" "$(result .attempt)" "3"
check "attempts: and the run knows how many there have been" \
  "$(result .attempts_total)" "3"
exists "attempts: the first attempt's stream survived two re-dispatches" \
  "$RUN/attempts/1/opus-stream.jsonl"
exists "attempts: with its gate rounds" "$RUN/attempts/1/gate-rounds.log"
exists "attempts: and the worker's final message" "$RUN/attempts/1/opus.log"
exists "attempts: the second attempt has its own directory" \
  "$RUN/attempts/2/gate-rounds.log"
absent "attempts: the live attempt is not rotated while it runs" "$RUN/attempts/3"
exists "attempts: the live filenames are exactly where they always were" \
  "$RUN/gate-rounds.log"
check "attempts: and the live gate log is this attempt's alone" \
  "$(grep -c '' "$RUN/gate-rounds.log" | tr -d ' ')" \
  "$(grep -c '' "$RUN/attempts/1/gate-rounds.log" | tr -d ' ')"
check "attempts: the ledger has a row per attempt" \
  "$(result '.metrics.attempts | length')" "3"
check "attempts: each with the status it ended on" \
  "$(result '[.metrics.attempts[].status] | join(",")')" \
  "gate_failed,gate_failed,gate_failed"
check "attempts: and its own clock" \
  "$(result '[.metrics.attempts[] | select(.started > 0 and .ended >= .started)] | length')" "3"
check "attempts: the pinned turn ceiling is recorded beside the CLI's count" \
  "$(result .metrics.implementer_max_turns)" "200"

# Preservation is the contract, so a filesystem collision must stop before the
# next worker truncates the live files. Silently continuing here would destroy
# exactly the telemetry this feature exists to retain.
dispatch ROTATE-FAIL ""
ROTATE_RESULT=$(cat "$RUN/result.json")
ROTATE_STREAM=$(cat "$RUN/opus-stream.jsonl")
ROTATE_MARKERS=$(grep -c '__invocation__' "$RUN/stages.log" | tr -d ' ')
mkdir -p "$RUN/attempts/1"
printf 'collision\n' > "$RUN/attempts/1/opus-stream.jsonl"
BEFORE=$(grep -c '' "$CLAUDE_CALLS" | tr -d ' ')
dispatch ROTATE-FAIL ""
check "attempts: a rotation collision fails the dispatch" \
  "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "attempts: no worker can truncate the unpreserved stream" \
  "$(grep -c '' "$CLAUDE_CALLS" | tr -d ' ')" "$BEFORE"
check "attempts: the previous result is left intact" \
  "$(cat "$RUN/result.json")" "$ROTATE_RESULT"
check "attempts: the live stream is left intact" \
  "$(cat "$RUN/opus-stream.jsonl")" "$ROTATE_STREAM"
check "attempts: a failed rotation does not count as a new invocation" \
  "$(grep -c '__invocation__' "$RUN/stages.log" | tr -d ' ')" "$ROTATE_MARKERS"
has "$OUT" "refusing to overwrite preserved attempt telemetry" \
  "attempts: the collision is explained"
TEST_GATE_CMD=true

# ---------------------------------------------------------------------------
echo "== a run that already shipped is not dispatched again =="
# ---------------------------------------------------------------------------
dispatch READY-GUARD ""
check "guard: the first dispatch ships" "$(result .status)" "ready"
READY_BEFORE=$(cat "$RUN/result.json")
BEFORE=$(grep -c '' "$CLAUDE_CALLS" | tr -d ' ')
dispatch READY-GUARD ""
check "guard: a re-dispatch of a ready run exits 0 — nothing failed" "$RC" "0"
check "guard: no implementer was spawned" "$(grep -c '' "$CLAUDE_CALLS" | tr -d ' ')" "$BEFORE"
check "guard: result.json is left exactly as the shipped run wrote it" \
  "$(cat "$RUN/result.json")" "$READY_BEFORE"
check "guard: and so is the attempt count" "$(result .attempt)" "1"
has "$OUT" "already finished as 'done: ready'" "guard: it says why it refused"
has "$OUT" "https://example.invalid/pr/1" "guard: and points at the PR that already exists"
has "$OUT" "HARNESS_REDISPATCH=1" "guard: with the override spelled out"

dispatch READY-GUARD "HARNESS_REDISPATCH=1"
check "override: HARNESS_REDISPATCH=1 dispatches anyway" \
  "$(grep -c '' "$CLAUDE_CALLS" | tr -d ' ')" "$((BEFORE + 1))"
check "override: and the run is on its second attempt" "$(result .attempt)" "2"

# ---------------------------------------------------------------------------
echo "== metrics.sh --report: the aggregate picture =="
# ---------------------------------------------------------------------------
# Hand-written result.json files: the report reads nothing else, so this is the
# whole input, and the expected medians are computable by hand.
REPORTH="$ROOT/report-harness"; RRUNS="$REPORTH/runs"
mkdir -p "$RRUNS"
mkrun() {  # $1 = run id, $2 = the whole result.json
  mkdir -p "$RRUNS/$1"
  printf '%s\n' "$2" > "$RRUNS/$1/result.json"
}
mkrun A-1 '{"ticket":"A-1","status":"ready","arm":"full","review":"reviewed",
  "worktree":"/w/myapp-a-1",
  "metrics":{"wall_seconds":600,"implementer_num_turns":10,"turn_resumes":0,
    "implementer_max_turns":200,
    "implementer_usage":{"output_tokens":1000},
    "gate_rounds":[{"round":"1","result":"fail","seconds":30,"failed_step":"npm run lint"},
                   {"round":"2","result":"pass","seconds":40,"failed_step":null}]}}'
# Two attempts: the first stopped for input, the second shipped. The gap between
# them is the idle time a human took to answer.
mkrun A-2 '{"ticket":"A-2","status":"ready","arm":"full","review":"reviewed",
  "attempt":2,"attempts_total":2,
  "worktree":"/w/myapp-a-2",
  "metrics":{"wall_seconds":1200,"implementer_num_turns":20,"turn_resumes":1,
    "implementer_usage":{"output_tokens":3000},
    "attempts":[{"n":1,"status":"needs_input","started":100,"ended":700},
                {"n":2,"status":"ready","started":1000,"ended":2200}],
    "gate_rounds":[{"round":"1","result":"fail","seconds":10,"failed_step":"npm run lint"},
                   {"round":"2","result":"pass","seconds":10,"failed_step":null}]}}'
# Three attempts, one of them a session limit the run recovered from by itself.
mkrun A-3 '{"ticket":"A-3","status":"gate_failed","arm":"full","review":"failed_silent",
  "attempt":3,"attempts_total":3,
  "worktree":"/w/myapp-a-3",
  "metrics":{"wall_seconds":1800,"implementer_num_turns":30,"turn_resumes":2,
    "implementer_max_turns":20,"self_resumes":1,
    "implementer_usage":{"output_tokens":5000},
    "attempts":[{"n":1,"status":"implementer_failed","started":1000,"ended":1600},
                {"n":2,"status":"deferred_capacity","started":1700,"ended":1760},
                {"n":3,"status":"gate_failed","started":5360,"ended":7160}],
    "gate_rounds":[{"round":"1","result":"fail","seconds":20,"failed_step":"npm test"},
                   {"round":"2","result":"fail","seconds":20,"failed_step":"npm test"},
                   {"round":"3","result":"fail","seconds":20,"failed_step":"npm test"}]}}'
mkrun B-1 '{"ticket":"B-1","status":"ready","arm":"no_review","review":"skipped",
  "worktree":"/w/myapi-b-1",
  "metrics":{"wall_seconds":2400,"implementer_num_turns":40,"turn_resumes":0,
    "implementer_usage":{"output_tokens":7000},
    "gate_rounds":[{"round":"1","result":"pass","seconds":50,"failed_step":null}]}}'
mkrun B-2 '{"ticket":"B-2","status":"rejected","arm":"full","review":"no_evidence",
  "worktree":"/w/myapi-b-2",
  "metrics":{"wall_seconds":3000,"implementer_num_turns":50,"turn_resumes":0,
    "implementer_usage":{"output_tokens":9000},
    "gate_rounds":[{"round":"1","result":"pass","seconds":60,"failed_step":null}]}}'
# A run from before any of this existed: no review field, no gate seconds, no
# turn_resumes, and a resume only visible as a stage_durations key.
mkrun LEGACY-1 '{"ticket":"LEGACY-1","status":"ready","arm":"full",
  "worktree":"/w/myapi-legacy-1",
  "metrics":{"wall_seconds":3600,
    "stage_durations":{"resuming — Opus (Claude sub)":42,"test gate #1 (deterministic — no model)":10},
    "gate_rounds":[{"round":"1","result":"fail"},{"round":"2","result":"pass"}]}}'

REPORT="$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh" --report)"
FLAT="$(printf '%s' "$REPORT" | tr -s ' ')"

has "$FLAT" "pipeline vitals · 6 runs" "report: counts every run it read"
has "$FLAT" "$RRUNS"                   "report: names the directory it read"
has "$FLAT" "ready 4 66.7"             "report: run counts by status, with a share"
has "$FLAT" "gate_failed 1 16.7"       "report: including the failures"
has "$FLAT" "full 5 83.3"              "report: run counts by arm"
has "$FLAT" "no_review 1 16.7"         "report: both arms"
has "$FLAT" "reviewed 2 33.3"          "report: review classifications"
has "$FLAT" "failed_silent 1 16.7"     "report: silent review failures are counted"
has "$FLAT" "no_evidence 1 16.7"       "report: and so are the unproven ones"
has "$FLAT" "pre-telemetry 1 16.7" \
  "report: a run from before the review telemetry says so, instead of claiming the stage was never reached"
has_not "$FLAT" "(not reached)" \
  "report: and the label that hid 28 real reviews is gone"
has "$FLAT" "runs reaching ready (last attempt) 4 66.7" \
  "report: run-level success is labelled as the last-attempt number it is"
has "$FLAT" "silent review failures 1 <- these diffs are UNREVIEWED" \
  "report: and the silent count is called out in words"
has "$FLAT" "turns 30 50 5"            "report: median/p90 turns over the runs that recorded them"
has "$FLAT" "wall minutes 40.0 60.0 6" "report: median/p90 wall minutes"
has "$FLAT" "output tokens 5000 9000 5" "report: median/p90 output tokens"
has "$FLAT" "gate seconds 60 70 5"     "report: median/p90 seconds spent in the gate"
has "$FLAT" "turns vs cap 1 of 2 runs report more CLI turns than their pinned ceiling" \
  "report: the CLI's turn count and the pinned ceiling are reconciled, not conflated"

# Attempt-level truth: the run-level 66.7% above counts last attempts only.
has "$FLAT" "attempts total 9"         "report: every attempt of every run is counted"
has "$FLAT" "reaching ready 4 44.4"    "report: with the attempt-level success rate"
has "$FLAT" "capacity self-resumes 1 <- deaths the run recovered from on its own" \
  "report: and the deaths the runs recovered from without a human"
has "$FLAT" "ATTEMPT DEATHS COUNT %"   "report: deaths are broken down by terminal status"
has "$FLAT" "implementer_failed 1 11.1" "report: the #1 sink is visible as an attempt, not a run"
has "$FLAT" "needs_input 1 11.1"       "report: including the attempts that stopped to ask"
has "$FLAT" "attempts 1.0 3.0 6"       "report: median/p90 attempts per run"
has "$FLAT" "idle gap mins 5.0 60.0 3" \
  "report: and the idle time between one attempt ending and the next starting"

has "$FLAT" "GATE FAILURES FAILED %"   "report: rounds are reported by failure, not as retries"
has "$FLAT" "round 1 4 66.7"           "report: how often the first round fails"
has "$FLAT" "round 2 1 25.0"           "report: and the second, over the runs that ran one"
has "$FLAT" "round 3 1 100.0"          "report: and the tail"
has_not "$FLAT" "2 rounds 3 50.0" \
  "report: the by-design second pass is no longer presented as a retry rate"
has "$FLAT" "npm test 3"               "report: the top failing gate step, most frequent first"
has "$FLAT" "npm run lint 2"           "report: and the runner-up"
has "$FLAT" "RESUMES 3 of 6 runs resumed (50.0%) · 4 resumes total" \
  "report: resume rate, counting a legacy run's resuming stage key"
has "$FLAT" "myapp 3 20.0 20 66.7"     "report: per-repo runs, median minutes/turns and ready share"
has "$FLAT" "myapi 3 50.0 50 66.7"     "report: for every repo, derived from the worktree path"

# The report has to survive a runs dir that has nothing to report on.
EMPTY="$ROOT/empty-harness"; mkdir -p "$EMPTY/runs"
OUT2="$(env HARNESS_DIR="$EMPTY" bash "$HARNESS/metrics.sh" --report 2>&1)"
has "$OUT2" "no result.json files" "report: an empty runs dir says so instead of erroring"
OUT2="$(env HARNESS_DIR="$ROOT/nowhere" bash "$HARNESS/metrics.sh" --report 2>&1)"
check "report: no runs dir at all is not an error" "$OUT2" "no runs yet"
if env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh" --nope >/dev/null 2>&1; then
  bad "report: an unknown option still exits non-zero"
else
  ok "report: an unknown option still exits non-zero"
fi
# The two existing modes keep working on the same data.
has "$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh")" "A-1" "report: the per-run table is untouched"
has "$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh" --csv)" "A-1,full," "report: and so is --csv"

# End to end: the report over the runs this suite actually dispatched sees the
# one silent review among them.
LIVE="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
has "$LIVE" "silent review failures 1" \
  "live: the report finds the silent review in real run dirs"
LIVE_RUNS=$(printf '%s\n' "$LIVE" | awk '/^pipeline vitals/ { print $4 }')
LIVE_ATTEMPTS=$(printf '%s\n' "$LIVE" | awk '/^attempts total/ { print $3 }')
if [ "${LIVE_ATTEMPTS:-0}" -gt "${LIVE_RUNS:-0}" ]; then
  ok "live: the re-dispatched runs make attempts outnumber runs ($LIVE_ATTEMPTS vs $LIVE_RUNS)"
else
  bad "live: attempts ($LIVE_ATTEMPTS) should outnumber runs ($LIVE_RUNS) — the ledger is not being read"
fi

echo
printf 'pipeline telemetry: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
