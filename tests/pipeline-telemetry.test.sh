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
#      the old two-field shape. The copy the models read is bounded in both
#      dimensions (100 lines, 2000 characters per line), says which round it is
#      and what it left out, and hands over the failing step the harness already
#      knows instead of making a model re-derive it.
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
# Implementer spawns within the current dispatch, reset by dispatch() below, so
# a mode can exhaust its turns on the first spawn and finish on the resume.
SPAWNS="$ROOT/spawns"
# Every argument list either model stand-in was handed, truncated per dispatch by
# dispatch() below: the only way to assert what a prompt actually said.
PROMPTS="$ROOT/prompts.log"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES"
: > "$CLAUDE_CALLS"; : > "$CODEX_CALLS"; : > "$CURL_LOG"; : > "$PROMPTS"
echo 0 > "$SPAWNS"
printf 'commit\n' > "$CLAUDE_MODE"
printf 'notes\n' > "$CODEX_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/metrics.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# Every harness script reads lib/common.sh from beside itself, so the shared
# helpers travel with both staged copies — the layout install.sh produces.
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"

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
# floor only applies to those); `tiny` leaves a two-line one. A reviewer prompt
# (the Claude tier) deliberately does NOTHING here: this suite is about the
# Codex stage's telemetry, and an inert last tier is what lets the silent
# failure below stay silent all the way to review_failed.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
printf 'claude\n' >> "$CLAUDE_CALLS"
printf '%s\n' "\$*" >> "$PROMPTS"
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in *"reviewer stage"*) exit 0 ;; esac
n=\$(cat "$SPAWNS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$SPAWNS"
case "\$(cat "$CLAUDE_MODE")" in
  commit) seq 1 30 >> impl.txt ;;
  tiny)   printf 'one\ntwo\n' >> impl.txt ;;
  fail)   exit 1 ;;
  # Same 30-line diff, but first lands an empty commit in the harness checkout
  # the symlinked entry runs from, before metrics are collected.
  bump-harness)
    seq 1 30 >> impl.txt
    git -C "$ROOT/harness-checkout" -c user.email=t@t -c user.name=t \
      commit -q --allow-empty -m bump
    ;;
  # One turn-ceiling resume inside a single dispatch: the first spawn commits
  # nothing and dies on the ceiling, the second finishes. Both write a stream
  # event naming their segment, so the rotation can be asserted on content —
  # and each carries a top-level cost, so the sum across segments is testable.
  ceiling-once)
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"segment-%s"}]}}\n' "\$n"
    if [ "\$n" -lt 2 ]; then
      printf '{"type":"result","subtype":"error_max_turns","session_id":"fork-%s","total_cost_usd":1.25}\n' "\$n"
      exit 1
    fi
    seq 1 30 >> impl.txt
    printf '{"type":"result","subtype":"success","session_id":"fork-%s","total_cost_usd":2.50}\n' "\$n"
    ;;
  # The same two segments, each reporting the turn and token counters the CLI
  # puts on its result event — the only place the real usage is ever reported.
  usage-segments)
    if [ "\$n" -lt 2 ]; then
      printf '{"type":"result","subtype":"error_max_turns","session_id":"fork-%s","num_turns":40,"usage":{"input_tokens":1000,"cache_read_input_tokens":2000000,"cache_creation_input_tokens":30000,"output_tokens":5000,"service_tier":"standard"}}\n' "\$n"
      exit 1
    fi
    seq 1 30 >> impl.txt
    printf '{"type":"result","subtype":"success","session_id":"fork-%s","num_turns":52,"usage":{"input_tokens":500,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":10000,"output_tokens":2000,"service_tier":"standard"}}\n' "\$n"
    ;;
  # A resumed stream where only one segment reports num_turns. The assistants
  # in the other segment are that segment's fallback, not grounds to discard it.
  usage-mixed-turns)
    if [ "\$n" -lt 2 ]; then
      printf '{"type":"result","subtype":"error_max_turns","session_id":"fork-%s","num_turns":40}\n' "\$n"
      exit 1
    fi
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"one"}]}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}\n'
    seq 1 30 >> impl.txt
    printf '{"type":"result","subtype":"success","session_id":"fork-%s"}\n' "\$n"
    ;;
  # A stream cut mid-line, the shape a killed process leaves behind: one whole
  # result event, then half of the next event and no newline at all.
  usage-truncated)
    seq 1 30 >> impl.txt
    printf '{"type":"result","subtype":"success","session_id":"fork-%s","num_turns":7,"usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":0,"output_tokens":300}}\n' "\$n"
    printf '{"type":"assistant","message":{"content":[{"typ'
    ;;
  # Complete assistant events do not constitute reported usage when the CLI
  # crashes before producing even one result event.
  usage-no-result)
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"one"}]}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"two"}]}}\n'
    exit 1
    ;;
esac
# git(1) writes to stdout, and stdout is the stream-json the harness parses.
git add -A >/dev/null
git commit -q -m "feat: fixture change" >/dev/null
EOF

# Reviewer stand-in: every mode is one of the shapes the integrity check has to
# tell apart. `instant` is the confirmed failure — it returns at once having
# touched nothing at all.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""; prompt=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && wt="\$a"
  prev="\$a"; prompt="\$a"
done
printf 'codex %s\n' "\$wt" >> "$CODEX_CALLS"
printf '%s\n' "\$*" >> "$PROMPTS"
case "\$prompt" in
  *"refutation stage"*)
    cat > "\$wt/.harness/refuted.json" <<'JSON'
[{"id":"F1","refuted":false,"reason":"the fixture still needs the reported review change"}]
JSON
    exit 0
    ;;
  *"fix stage"*)
    case "\$(cat "$CODEX_MODE")" in
      commits) ( cd "\$wt" && printf 'reviewer touched this\n' >> impl.txt \
                 && git add -A && git commit -q -m "refactor: reviewer change [F1]" ) ;;
      marker)  ( cd "\$wt" && printf 'reviewed\n' > reviewed.txt \
                 && git add -A && git commit -q -m "refactor: reviewer change [F1]" ) ;;
    esac
    exit 0
    ;;
  *"reviewer stage"*)
    case "\$(cat "$CODEX_MODE")" in
      commits|marker)
        printf 'review fixes must remain visible in telemetry\n' > "\$wt/.harness/expected-properties.md"
        cat > "\$wt/.harness/findings.json" <<'JSON'
[{"file":"impl.txt","line":1,"claim":"the fixture needs a reviewer change","scenario":"the review fix is absent from the committed tree"}]
JSON
        exit 0
        ;;
    esac
    ;;
esac
case "\$(cat "$CODEX_MODE")" in
  instant) echo "codex: done" ;;
  notes)   printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md" ;;
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

# A DIFFERENT failing step, for the round-2 prompt: it must name the round that
# just failed, not the one the review prompt was built from.
cat > "$FAKES/gate-tests-late" <<'EOF'
#!/usr/bin/env bash
echo "tests: still 1 failing"
exit 1
EOF

# The shape a jest snapshot diff, a vite build error or a minified stack frame
# has: enormous output on ONE line, where a line-count ceiling bounds nothing.
# The second line's 2000-character mark falls inside a two-byte character, which
# is what a byte-based clamp splits.
cat > "$FAKES/gate-wide" <<'EOF'
#!/usr/bin/env bash
perl -e 'print "x" x 10000, "\n"'
perl -e 'print "\xc3\xa9" x 3000, "\n"'
printf 'ordinary [clipped: this line is 123 characters long]\n'
perl -e 'print "A", "\x80" x 10000, "\n"'
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh" \
  "$FAKES/gate-lint" "$FAKES/gate-tests" "$FAKES/gate-tests-late" \
  "$FAKES/gate-wide"

# --- the harness under test ---------------------------------------------------
codex_calls() { grep -c '^codex ' "$CODEX_CALLS" 2>/dev/null | tr -d ' '; }

RC=0; OUT=""; RUN=""
TEST_GATE_CMD=true    # repos.local.sh reads this; a gate command has spaces in
                      # it, so it travels as its own variable, not an override
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty),
              # $3 = run-task.sh entry to invoke (default: the staged copy)
  local ticket="$1" overrides="$2" entry="${3:-$SRCDIR/run-task.sh}"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  # BRIEF_TEXT, when set, replaces the one-line default for this dispatch.
  [ -n "${BRIEF_TEXT:-}" ] && printf '%s' "$BRIEF_TEXT" > "$RUN/brief.md"
  : > "$PROMPTS"; echo 0 > "$SPAWNS"
  # shellcheck disable=SC2086
  env -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      IMPLEMENTER_PROVIDER=claude \
      TEST_GATE_CMD="$TEST_GATE_CMD" \
      HARNESS_REVIEW_NETWORK=0 \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=telemetry-test \
      $overrides \
      bash "$entry" "$ticket" "$REPO" "fix/$ticket" \
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
check "silent: and leaves the pinned experimental arm alone" "$(result .arm)" "full"
file_has "$RUN/timeline" "review failed silently — diff is unreviewed" \
  "silent: the status line says so in the words the wall and statusline read"
file_has "$CURL_LOG" "review failed silently — diff is unreviewed" \
  "silent: and it goes out over the existing ntfy mechanics"
has "$OUT" "this diff is UNREVIEWED" "silent: the console is blunt about it"
check "silent: a diff nothing reviewed does not ship — review_failed, no PR" \
  "$(result .status)" "review_failed"
check "silent: so there is no pr_url to mistake for a reviewed one" \
  "$(result .pr_url)" ""
check "silent: and the exit code says not-ready" "$RC" "1"
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
check "commits: find, refute and fix run without a review retry" \
  "$(codex_calls)" "$((BEFORE + 3))"
absent "commits: no review retry log" "$RUN/codex-1-retry.log"
check "commits: the reviewer's commit is attributed to the reviewer" \
  "$(result .metrics.codex_commits)" "1"

printf 'reject\n' > "$CODEX_MODE"
dispatch REV-REJECT ""
check "reject: a rejection is the most engaged review there is" \
  "$(result .review)" "reviewed"
check "reject: and the run is rejected as before" "$(result .status)" "rejected"

# The floor is what buys the CODEX retry; without it, a no-evidence review is
# never paid for twice on an account that already came up empty. It is not,
# however, a reason to ship: a stopwatch is not evidence, so the last tier gets
# the diff — and this suite's Claude tier is inert, so the run holds.
printf 'instant\n' > "$CODEX_MODE"
BEFORE=$(codex_calls)
dispatch REV-NOFLOOR "HARNESS_REVIEW_MIN_SECONDS=0"
check "floor: a review above the floor is not retried on Codex" \
  "$(codex_calls)" "$((BEFORE + 1))"
file_has "$RUN/timeline" "review — Codex unavailable (no evidence from the Codex review after" \
  "floor: it hands the diff to the Claude tier instead of recording a shippable no_evidence"
check "floor: which produced nothing here, so nothing reviewed the diff" \
  "$(result .review)" "failed_silent"
check "floor: and the failed attempt leaves its pinned arm alone" "$(result .arm)" "full"
check "floor: a diff no tier read does not ship" "$(result .status)" "review_failed"

# A two-line diff genuinely can be reviewed in seconds: crying wolf over it
# would teach everyone to ignore the alarm. "Trivial" excuses a fast review,
# never an absent one — the Claude tier gets it like any other empty stage.
printf 'tiny\n' > "$CLAUDE_MODE"
BEFORE=$(codex_calls)
dispatch REV-TRIVIAL ""
printf 'commit\n' > "$CLAUDE_MODE"
check "trivial: a trivial diff never triggers the Codex retry" "$(codex_calls)" "$((BEFORE + 1))"
check "trivial: but it is still handed on rather than shipped" \
  "$(result .review)" "failed_silent"
check "trivial: so it holds too" "$(result .status)" "review_failed"

# ---------------------------------------------------------------------------
echo "== the one arm that still has no review says so =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
dispatch REV-SKIPARM "HARNESS_SKIP_REVIEW=1"
check "skip arm: review is recorded as skipped" "$(result .review)" "skipped"
check "skip arm: with the no_review arm" "$(result .arm)" "no_review"
file_has "$RUN/timeline" "review skipped — HARNESS_SKIP_REVIEW=1 (no_review arm)" \
  "skip arm: and a stage line naming the knob that asked for it"

# A machine without the codex CLI is NOT that arm: it reviews on the Claude
# tier. tests/review-fallback.test.sh owns the working version; here the tier is
# inert, which is what proves the arm holds rather than shipping.
BEFORE=$(codex_calls)
dispatch REV-NOCODEX "CODEX_BIN=$ROOT/no-such-codex"
check "no codex: nothing on the Codex side is ever asked" "$(codex_calls)" "$BEFORE"
check "no codex: the pinned arm names the machine, not an ablation" \
  "$(cat "$RUN/arm")" "claude_only"
file_has "$RUN/timeline" "review — Codex unavailable (no codex CLI on this machine (Claude-only mode)) → Claude reviewer (Claude sub)" \
  "no codex: the Claude tier takes the review instead of the stage being skipped"
check "no codex: and a dead Claude tier holds the run like any other dead review" \
  "$(result .status)" "review_failed"

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
# Entering the Claude tier sets review_account even when that attempt produces
# nothing. A gate failure wins the terminal status, but its push must not turn
# that dead attempt into the success claim used by reviewed_claude runs.
has_not "$(grep -A1 -F 'Title: dispatch GATE-FAIL' "$CURL_LOG")" \
  "review ran on the Claude tier" \
  "fail: a dead Claude attempt is not described as a completed review"
# The run dir's log is the raw, complete record: the tracer must be invisible in
# it, and nothing else may be added to it either.
check "fail: the gate log is exactly the gate's own output" \
  "$(cat "$RUN/gate-1.log")" "linting: clean
tests: 1 failing"
# The models' copy is deliberately NOT that file. On a log this small nothing is
# cut, so every line of the gate's output is still there verbatim — behind a
# header that says which round, what its verdict was, which step it died on, and
# that this is the whole thing. Pinned in full: the header IS the contract.
check "fail: the copy handed to the reviewer states what it is, then the output" \
  "$(cat "$ROOT/greenapp-gate-fail/.harness/gate-latest.log")" "=== gate round 1 ===
result: fail
failed step: gate-tests
shown: all 2 lines
=== gate output follows ===
linting: clean
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

# A reviewer that commits is what makes this a full three-round loop: round 2 is
# only run at all when the tree it would verify is not the one round 1 already
# judged (tests/review-truth.test.sh owns the skip).
printf 'commits\n' > "$CODEX_MODE"
TEST_GATE_CMD='gate-lint && gate-tests'
dispatch GATE-ROUNDS ""
check "rounds: a full review loop records all three rounds" \
  "$(result '.metrics.gate_rounds | length')" "3"
check "rounds: every one of them names the failing step" \
  "$(result '[.metrics.gate_rounds[].failed_step] | unique | join(",")')" "gate-tests"
TEST_GATE_CMD=true

# ---------------------------------------------------------------------------
echo "== the gate output the models read is bounded and self-describing =="
# ---------------------------------------------------------------------------
# Counts characters, not bytes: a clamp that landed at 2000 BYTES on the
# two-byte line below would look compliant to a byte ruler and be broken.
widest() {  # $1 = file; prints the longest line's length in characters
  perl -MEncode -ne 'chomp; my $n = length(Encode::decode("UTF-8", $_, Encode::FB_DEFAULT));
    $m = $n if $n > $m; END { print $m + 0, "\n" }' "$1"
}

# A log that is deep AND wide, failing on a named step: all three ceilings and
# all three header facts in one round.
printf 'notes\n' > "$CODEX_MODE"
TEST_GATE_CMD='seq 1 4312 && gate-wide && gate-tests'
dispatch GATE-CONTEXT "CODEX_BIN=$ROOT/no-such-codex"
LATEST="$ROOT/greenapp-gate-context/.harness/gate-latest.log"
TOTAL=$(awk 'END { print NR + 0 }' "$RUN/gate-1.log")

check "extract: the fixture log really is deeper than the tail depth" \
  "$(( TOTAL > 100 ))" "1"
check "extract: the first line names the round it came from" \
  "$(sed -n 1p "$LATEST")" "=== gate round 1 ==="
file_has "$LATEST" "result: fail" "extract: the header states the round's verdict"
file_has "$LATEST" "failed step: gate-tests" \
  "extract: and the failing step the trap machinery already isolated"
# Counted against the real log, not a constant: the header's claim about how much
# it left out has to be true of the file it was cut from.
file_has "$LATEST" "shown: the last 100 of $TOTAL lines" \
  "extract: and how much of the log this is, shown against the real total"
check "extract: the tail depth is unchanged — 100 lines below the header" \
  "$(LC_ALL=C awk 'f { n++ } /^=== gate output follows ===$/ { f = 1 } END { print n + 0 }' "$LATEST")" \
  "100"
check "extract: and it is the END of the log, as it always was" \
  "$(tail -1 "$LATEST")" "tests: 1 failing"
# The run dir is outside the worktree and outside both sandboxes. A header that
# named it would send the model after a file it cannot open.
has_not "$(cat "$LATEST")" "$RUN" \
  "extract: the header points the model at no path outside its reach"

check "clamp: no line reaches the reviewer wider than the 2000-character ceiling" \
  "$(widest "$LATEST")" "2000"
file_has "$LATEST" "[clipped: this line is 10000 characters long]" \
  "clamp: and a cut line says it was cut, and how much line there was"
file_has "$LATEST" "clipped: 3 line(s) over 2000 characters, each marked inline" \
  "clamp: the header counts the cuts too"
file_has "$LATEST" "ordinary [clipped: this line is 123 characters long]" \
  "clamp: a genuine marker-like log line is preserved"
has_not "$(cat "$LATEST")" "clipped: 4 line(s)" \
  "clamp: a genuine marker-like log line is not counted as a cut"
# The 2000-character mark falls mid-character on this line. Strip the marker and
# what remains must be whole two-byte characters — `cut -c` would leave a stray
# lead byte here.
check "clamp: a multi-byte line is cut between characters, never inside one" \
  "$(perl -ne 'next unless /^\xc3\xa9/; chomp;
     s/ \[clipped: this line is [0-9]+ characters long\]\z//;
     print /\A(?:\xc3\xa9)+\z/ ? "whole" : "split"; exit' "$LATEST")" \
  "whole"
# Malformed input must not let a long line escape the ceiling either. The old
# grouping of a lead byte plus every following continuation byte treated this
# entire line as one unit; the replacement-aware ruler above counts each stray
# byte as one display character.
check "clamp: malformed bytes cannot reopen the width hole" \
  "$(LC_ALL=C grep -cF '[clipped: this line is 10001 characters long]' "$LATEST")" "1"
# The raw log keeps its promise while the extract keeps the ceiling.
check "clamp: the run dir's own log still holds the line at full width" \
  "$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$RUN/gate-1.log")" \
  "10001"

# The whole point of isolating the failing step: hand it over.
file_has "$PROMPTS" "current status: fail — the failing step was: gate-tests)" \
  "prompt: the reviewer is told the failing step alongside the gate status"
file_has "$PROMPTS" "gate-latest.log is a clipped extract, not the whole gate log" \
  "prompt: and told that what it is reading is an extract"
file_has "$PROMPTS" "':(exclude)package-lock.json'" \
  "prompt: lockfiles are excluded from the diff the reviewer reads"
file_has "$PROMPTS" "checklist item 1 below keeps its full force over every file in the diff" \
  "prompt: without letting that exemption reach anything else"

# The header is a line in the file too, and the failing step it quotes is a whole
# element of the operator's own gate command — nothing bounds its length. The
# ceiling has to cover the header, or a long gate command reopens the hole.
TEST_GATE_CMD="gate-tests --pad=$(perl -e 'print "x" x 3000')"
dispatch GATE-CTX-WIDESTEP "CODEX_BIN=$ROOT/no-such-codex"
WIDESTEP="$ROOT/greenapp-gate-ctx-widestep/.harness/gate-latest.log"
check "wide step: no line escapes the ceiling, the header included" \
  "$(widest "$WIDESTEP")" "2000"
has "$(sed -n 3p "$WIDESTEP")" "failed step: gate-tests --pad=xxx" \
  "wide step: the header still names the step, just bounded"
has "$(sed -n 3p "$WIDESTEP")" "characters long]" \
  "wide step: and says where it cut it"
# The prompt quotes the same operator-controlled command. Bounding only the file
# would leave the same context hole open immediately beside it.
file_has "$PROMPTS" "current status: fail — the failing step was: gate-tests --pad=xxx" \
  "wide step: the reviewer prompt still identifies the long failing step"
file_has "$PROMPTS" "characters long])" \
  "wide step: and bounds that copy with the same disclosed marker"
# Bounding the models' copy must not bound the record readers parse.
check "wide step: gate-rounds.log still carries the step at full length" \
  "$(result '.metrics.gate_rounds[0].failed_step' | wc -c | tr -d ' ')" "3018"

# A passing round has no failing step to name, and must not borrow one.
TEST_GATE_CMD='seq 1 3 && gate-lint'
dispatch GATE-CTX-PASS "CODEX_BIN=$ROOT/no-such-codex"
PASSED="$ROOT/greenapp-gate-ctx-pass/.harness/gate-latest.log"
check "pass: the header states the pass" "$(sed -n 2p "$PASSED")" "result: pass"
has_not "$(cat "$PASSED")" "failed step:" \
  "pass: and invents no failing step for a round that had none"
file_has "$PASSED" "shown: all 4 lines" \
  "pass: a log inside the tail depth says so rather than claiming a cut"
file_has "$PROMPTS" "current status: pass)" \
  "pass: and the reviewer prompt claims no failing step either"

# Round 2's failure is a DIFFERENT step from round 1's, so the fix-round prompt
# cannot pass by quoting the step the review prompt was built from.
printf 'marker\n' > "$CODEX_MODE"
TEST_GATE_CMD='if [ -f reviewed.txt ]; then gate-tests-late; else gate-tests; fi'
dispatch GATE-CTX-FIX ""
check "fix: round 1 died on the first step" \
  "$(result '.metrics.gate_rounds[0].failed_step')" "gate-tests"
check "fix: round 2 died on a different one" \
  "$(result '.metrics.gate_rounds[1].failed_step')" "gate-tests-late"
file_has "$PROMPTS" \
  "The test gate is still failing after your review — the failing step was: gate-tests-late." \
  "fix: the fix round is told the step of the round that just failed"
has_not "$(cat "$PROMPTS")" \
  "The test gate is still failing after your review — the failing step was: gate-tests." \
  "fix: not the one the review prompt was built from"
file_has "$PROMPTS" "current status: fail — the failing step was: gate-tests)" \
  "fix: while the review prompt still carries round 1's, which is when it was written"
check "fix: and the standing extract names the last round that actually ran" \
  "$(sed -n 1p "$ROOT/greenapp-gate-ctx-fix/.harness/gate-latest.log")" \
  "=== gate round 3 ==="
printf 'notes\n' > "$CODEX_MODE"
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

# An attempt is one invocation, and a turn-ceiling resume is a segment INSIDE
# one — the implementer's stream is appended to within a dispatch and rotated
# whole between dispatches. Both halves are asserted here, because rotating half
# an attempt's stream would lose exactly what the append was added to keep.
printf 'ceiling-once\n' > "$CLAUDE_MODE"
dispatch CEILING-ROTATE ""
check "multi-segment: one dispatch, two segments in the live stream" \
  "$(jq -s -r '[.[] | select(.type == "assistant") | .message.content[]?.text] | join(",")' \
     "$RUN/opus-stream.jsonl")" "segment-1,segment-2"
check "multi-segment: recorded as two" "$(result .metrics.implementer_segments)" "2"
check "multi-segment: on one resume of the turn ceiling" \
  "$(result .metrics.turn_resumes)" "1"
SEG_BEFORE=$(cat "$RUN/opus-stream.jsonl")
dispatch CEILING-ROTATE ""
printf 'commit\n' > "$CLAUDE_MODE"
check "multi-segment: the re-dispatch rotates the WHOLE attempt aside" \
  "$(cat "$RUN/attempts/1/opus-stream.jsonl")" "$SEG_BEFORE"
check "multi-segment: and the live stream is the new attempt's alone" \
  "$(jq -s -r '[.[] | select(.type == "assistant") | .message.content[]?.text] | join(",")' \
     "$RUN/opus-stream.jsonl")" "segment-1,segment-2"
check "multi-segment: which the rotated one did not leak into" \
  "$(result .metrics.implementer_segments)" "2"

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
echo "== cost, configuration and brief shape ride along in metrics =="
# ---------------------------------------------------------------------------
# The CLI reports cost as a top-level key on each result event, never under
# .usage; a resumed attempt's cost is the sum over both segments, not the last
# segment's number — the same rule the usage counters already follow.
printf 'ceiling-once\n' > "$CLAUDE_MODE"
dispatch COST-SEGMENTS ""
printf 'commit\n' > "$CLAUDE_MODE"
check "cost: both segments of the resumed attempt are summed" \
  "$(result .metrics.total_cost_usd)" "3.75"
check "cost: and the segments they came from are counted" \
  "$(result .metrics.implementer_segments)" "2"

# Two dispatches of the same pinned condition must hash identically; one pin
# moved must move the hash. The staged run-task.sh is not a checkout, so the
# harness HEAD component is empty here and cannot mask a pin difference.
dispatch CFG-SAME-A ""
dispatch CFG-SAME-B ""
CFG_A=$(jq -r '.metrics.config_hash' "$RUNS/CFG-SAME-A/result.json")
check "config: two dispatches with the same pins hash identically" \
  "$(result .metrics.config_hash)" "$CFG_A"
if [ "${#CFG_A}" -eq 12 ] && ! printf '%s' "$CFG_A" | grep -q '[^0-9a-f]'; then
  ok "config: the hash is 12 hex characters"
else
  bad "config: the hash is not 12 hex characters ($CFG_A)"
fi
dispatch CFG-OTHER-CEILING "HARNESS_MAX_TURNS=111"
if [ "$(result .metrics.config_hash)" = "$CFG_A" ]; then
  bad "config: one pin different and the hash did not move"
else
  ok "config: one pin different and the hash moves"
fi
# Claude-only runs pin blank Codex reviewer knobs. Reaching the Claude review
# tier fills the runtime reviewer labels, but must not relabel the run's pinned
# condition compared with an otherwise identical early implementer failure.
printf 'fail\n' > "$CLAUDE_MODE"
dispatch CFG-CLAUDE-EARLY "CODEX_BIN=$ROOT/no-such-codex"
CFG_CLAUDE=$(result .metrics.config_hash)
check "config: the Claude-only reviewer model is pinned blank" \
  "$(cat "$RUN/reviewer-model")" ""
printf 'commit\n' > "$CLAUDE_MODE"
dispatch CFG-CLAUDE-REVIEW "CODEX_BIN=$ROOT/no-such-codex"
check "config: runtime fallback labels do not change identical pinned hashes" \
  "$(result .metrics.config_hash)" "$CFG_CLAUDE"
# A run with no cost events and the one-line fixture brief: nulls and false
# detectors, never zeros that pretend something was measured.
check "cost: no result event carrying it records null" \
  "$(result .metrics.total_cost_usd)" ""
check "brief: a brief with none of the sections reads false" \
  "$(jq -r '.metrics.brief.has_reproduction' "$RUNS/CFG-SAME-A/result.json")" "false"
check "brief: and counts no acceptance items" \
  "$(jq -r '.metrics.brief.acceptance_count' "$RUNS/CFG-SAME-A/result.json")" "0"
check "brief: the one fixture line is one line" \
  "$(jq -r '.metrics.brief.lines' "$RUNS/CFG-SAME-A/result.json")" "1"

# The sections a good brief carries, detected by header stem — the acceptance
# count comes from the checkboxes under the acceptance heading, and a checked
# box counts the same as an open one.
BRIEF_TEXT='# Task
## Problem
The widget breaks.

## Reproduction
Run the fixture.

## Interface
None.

## Edit locations
src/impl.txt

## Decision points
Whether to fix it here.

## Acceptance criteria
- [ ] it works
- [x] it is tested
'
dispatch BRIEF-SHAPE ""
BRIEF_TEXT=""
check "brief: the line count is recorded"        "$(result .metrics.brief.lines)" "19"
check "brief: both acceptance checkboxes count"  "$(result .metrics.brief.acceptance_count)" "2"
check "brief: reproduction section detected"     "$(result .metrics.brief.has_reproduction)" "true"
check "brief: interface section detected"        "$(result .metrics.brief.has_interface)" "true"
check "brief: edit locations detected"           "$(result .metrics.brief.has_edit_locations)" "true"
check "brief: decision points detected"          "$(result .metrics.brief.has_decision_points)" "true"

# ---------------------------------------------------------------------------
echo "== what the run actually spent: window tokens and z.ai credits =="
# ---------------------------------------------------------------------------
# Per-`assistant`-event usage is zeros on zai and unreliable everywhere, so the
# result event is the only source — and an attempt that resumed off the turn
# ceiling has one per segment, whose SUM is what the attempt cost.
has_key() {  # $1 = jq path to an object, $2 = key
  jq -r "$1 | has(\"$2\")" "$RUN/result.json" 2>/dev/null
}

printf 'usage-segments\n' > "$CLAUDE_MODE"
dispatch USAGE-SUM ""
check "usage: two result events, and both are counted" \
  "$(result .metrics.implementer_segments)" "2"
check "usage: input tokens are summed across the segments" \
  "$(result .metrics.usage.input_tokens)" "1500"
check "usage: and so is the cache-read volume that dominates the bill" \
  "$(result .metrics.usage.cache_read_input_tokens)" "3000000"
check "usage: cache creation too" \
  "$(result .metrics.usage.cache_creation_input_tokens)" "40000"
check "usage: and output" "$(result .metrics.usage.output_tokens)" "7000"
check "usage: turns are the CLI's own count, summed the same way" \
  "$(result .metrics.usage.turns)" "92"
check "usage: an anthropic run is billed flat, so it carries no credit estimate" \
  "$(has_key .metrics.usage zai_credits_est)" "false"

# The same stream on the other vendor: identical counters, plus the credit
# estimate the Coding-Plan formula makes of them.
#   (1500*6.9 + 3000000*1.7 + 7000*24) / 10000 = 527.835
( umask 077; printf 'zai-not-a-real-key-0123456789\n' > "$HARNESS/zai-api-key" )
dispatch USAGE-ZAI "IMPLEMENTER_PROVIDER=zai"
printf 'commit\n' > "$CLAUDE_MODE"
check "credits: the run really did bill the other vendor" \
  "$(result .implementer_provider)" "zai"
check "credits: a zai run prices its own tokens in Coding-Plan credits" \
  "$(result .metrics.usage.zai_credits_est)" "527.835"
check "credits: over the same summed counters" \
  "$(result .metrics.usage.cache_read_input_tokens)" "3000000"

# A stream cut mid-line by a killed process. Slurping the file failed on the
# whole thing; every complete event before the cut still has to count.
printf 'usage-truncated\n' > "$CLAUDE_MODE"
dispatch USAGE-TRUNC ""
printf 'commit\n' > "$CLAUDE_MODE"
check "truncated: the stream really does end mid-line" \
  "$(tail -c 1 "$RUN/opus-stream.jsonl")" 'p'
check "truncated: the complete result event before the cut still counts" \
  "$(result .metrics.usage.output_tokens)" "300"
check "truncated: turns included" "$(result .metrics.usage.turns)" "7"
check "truncated: and the run still reaches ready" "$(result .status)" "ready"

# No result event at all — an implementer that died before reporting anything.
# Zeros, never nulls, and metrics still get written.
printf 'usage-no-result\n' > "$CLAUDE_MODE"
dispatch USAGE-NONE ""
check "empty: every counter reads zero rather than null" \
  "$(result '[.metrics.usage.input_tokens, .metrics.usage.cache_read_input_tokens,
              .metrics.usage.cache_creation_input_tokens, .metrics.usage.output_tokens,
              .metrics.usage.turns] | join(",")')" "0,0,0,0,0"
exists "empty: and the run still writes its result" "$RUN/result.json"
check "empty: complete assistant events do not become turns without a result" \
  "$(jq -s 'map(select(.type == "assistant")) | length' "$RUN/opus-stream.jsonl")" "2"

# Result events that report no num_turns at all: the turn count falls back to
# the assistant events the stream does carry, rather than reporting nothing.
printf 'ceiling-once\n' > "$CLAUDE_MODE"
dispatch USAGE-NOTURNS ""
printf 'commit\n' > "$CLAUDE_MODE"
check "fallback: the CLI's own turn count is genuinely absent here" \
  "$(result .metrics.implementer_num_turns)" ""
check "fallback: so turns are counted from the assistant events instead" \
  "$(result .metrics.usage.turns)" "2"

# Fallback is per segment: a numeric count in one segment must not suppress the
# assistant-event count for a different result event that omitted num_turns.
printf 'usage-mixed-turns\n' > "$CLAUDE_MODE"
dispatch USAGE-MIXED-TURNS ""
printf 'commit\n' > "$CLAUDE_MODE"
check "mixed fallback: the reported segment keeps its CLI turn count" \
  "$(result .metrics.implementer_num_turns)" "40"
check "mixed fallback: the unreported segment adds its assistant turns" \
  "$(result .metrics.usage.turns)" "42"

# ---------------------------------------------------------------------------
echo "== the config hash resolves the harness checkout from the installed entry =="
# ---------------------------------------------------------------------------
# The installed layout: a station dir whose run-task.sh is a symlink into a
# harness checkout. The staged copies above are not a git repo, so every hash
# in this file so far has an empty HEAD component — the checkout's HEAD is the
# first input that can tell symlinks and HEAD-less copies apart.
CHECKOUT="$ROOT/harness-checkout"; STATION="$ROOT/station"
mkdir -p "$CHECKOUT" "$STATION"
cp "$SRC/run-task.sh" "$CHECKOUT/run-task.sh"
cp -R "$SRC/lib" "$CHECKOUT/lib"
git -C "$CHECKOUT" init -q
git -C "$CHECKOUT" add -A
git -C "$CHECKOUT" -c user.email=t@t -c user.name=t commit -q -m "harness a"
ln -s "$CHECKOUT/run-task.sh" "$STATION/run-task.sh"
# The lib is read from beside the entry as invoked — the station, not the
# checkout — which is exactly the layout install.sh leaves behind.
cp -R "$SRC/lib" "$STATION/lib"

dispatch LINK-PLAIN "" "$STATION/run-task.sh"
LINK_A=$(jq -r '.metrics.config_hash // ""' "$RUNS/LINK-PLAIN/result.json")
if [ -n "$LINK_A" ] && [ "$LINK_A" != "$CFG_A" ]; then
  ok "link: the symlinked entry hashes the checkout HEAD it resolves to"
else
  bad "link: the symlinked entry hashed like the HEAD-less staged copy ($LINK_A)"
fi

printf 'bump-harness\n' > "$CLAUDE_MODE"
dispatch LINK-BUMPED "" "$STATION/run-task.sh"
printf 'commit\n' > "$CLAUDE_MODE"
LINK_B=$(jq -r '.metrics.config_hash // ""' "$RUNS/LINK-BUMPED/result.json")
if [ -n "$LINK_B" ] && [ "$LINK_B" != "$LINK_A" ]; then
  ok "link: metrics collection sees the checkout's current HEAD"
else
  bad "link: a checkout change was absent from the collected hash ($LINK_B)"
fi

dispatch LINK-AFTER "" "$STATION/run-task.sh"
check "link: a later run at the same checkout HEAD hashes identically" \
  "$(jq -r '.metrics.config_hash // ""' "$RUNS/LINK-AFTER/result.json")" "$LINK_B"

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
mkoutcome() {  # $1 = run id, $2 = the whole outcome.json
  mkdir -p "$RRUNS/$1"
  printf '%s\n' "$2" > "$RRUNS/$1/outcome.json"
}
mkrun A-1 '{"ticket":"A-1","status":"ready","arm":"full","review":"reviewed",
  "worktree":"/w/myapp-a-1",
  "metrics":{"wall_seconds":600,"implementer_num_turns":10,"turn_resumes":0,
    "implementer_max_turns":200,"total_cost_usd":1.5,
    "implementer_usage":{"output_tokens":1000},
    "gate_rounds":[{"round":"1","result":"fail","seconds":30,"failed_step":"npm run lint"},
                   {"round":"2","result":"pass","seconds":40,"failed_step":null}]}}'
# Two attempts: the first stopped for input, the second shipped. The gap between
# them is the idle time a human took to answer.
mkrun A-2 '{"ticket":"A-2","status":"ready","arm":"full","review":"reviewed",
  "attempt":2,"attempts_total":2,
  "worktree":"/w/myapp-a-2",
  "metrics":{"wall_seconds":1200,"implementer_num_turns":20,"turn_resumes":1,
    "total_cost_usd":2.5,
    "implementer_usage":{"output_tokens":3000},
    "attempts":[{"n":1,"status":"needs_input","started":100,"ended":700},
                {"n":2,"status":"ready","started":1000,"ended":2200}],
    "gate_rounds":[{"round":"1","result":"fail","seconds":10,"failed_step":"npm run lint"},
                   {"round":"2","result":"skipped","seconds":0,"failed_step":null}]}}'
# Three attempts, one of them a session limit the run recovered from by itself.
mkrun A-3 '{"ticket":"A-3","status":"gate_failed","arm":"full","review":"failed_silent",
  "attempt":3,"attempts_total":3,
  "worktree":"/w/myapp-a-3",
  "metrics":{"wall_seconds":1800,"implementer_num_turns":30,"turn_resumes":2,
    "implementer_max_turns":20,"self_resumes":1,"total_cost_usd":4.0,
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
    "total_cost_usd":8.0,
    "implementer_usage":{"output_tokens":9000},
    "gate_rounds":[{"round":"1","result":"pass","seconds":60,"failed_step":null}]}}'
# A run from before any of this existed: no review field, no gate seconds, no
# turn_resumes, and a resume only visible as a stage_durations key.
mkrun LEGACY-1 '{"ticket":"LEGACY-1","status":"ready","arm":"full",
  "worktree":"/w/myapi-legacy-1",
  "metrics":{"wall_seconds":3600,
    "stage_durations":{"resuming — Opus (Claude sub)":42,"test gate #1 (deterministic — no model)":10},
    "gate_rounds":[{"round":"1","result":"fail"},{"round":"2","result":"pass"}]}}'
# What the janitor later wrote beside four of them: two merges (one reverted,
# one hour and two hours to merge), one PR still open, one closed unmerged.
# LEGACY-1 and B-2 have none — an old corpus renders exactly as before.
mkoutcome A-1 '{"pr_state":"MERGED","merged_at":"2026-08-20T10:00:00Z",
  "time_to_merge_s":3600,"review_comment_count":1,"follow_up_commits":0,
  "reverted":false,"checked_at":"2026-08-21T00:00:00Z"}'
mkoutcome A-2 '{"pr_state":"MERGED","merged_at":"2026-08-21T10:00:00Z",
  "time_to_merge_s":7200,"review_comment_count":3,"follow_up_commits":2,
  "reverted":true,"checked_at":"2026-08-21T00:00:00Z"}'
mkoutcome A-3 '{"pr_state":"CLOSED","merged_at":null,"time_to_merge_s":null,
  "review_comment_count":0,"follow_up_commits":null,"reverted":null,
  "checked_at":"2026-08-21T00:00:00Z"}'
mkoutcome B-1 '{"pr_state":"OPEN","merged_at":null,"time_to_merge_s":null,
  "review_comment_count":0,"follow_up_commits":null,"reverted":null,
  "checked_at":"2026-08-21T00:00:00Z"}'

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
has "$FLAT" "round 2 1 33.3"           "report: skipped rounds stay out of the execution denominator"
has "$FLAT" "round 3 1 100.0"          "report: and the tail"
has_not "$FLAT" "2 rounds 3 50.0" \
  "report: the by-design second pass is no longer presented as a retry rate"
has "$FLAT" "npm test 3"               "report: the top failing gate step, most frequent first"
has "$FLAT" "npm run lint 2"           "report: and the runner-up"
has "$FLAT" "RESUMES 3 of 6 runs resumed (50.0%) · 4 resumes total" \
  "report: resume rate, counting a legacy run's resuming stage key"
has "$FLAT" "myapp 3 20.0 20 66.7"     "report: per-repo runs, median minutes/turns and ready share"
has "$FLAT" "myapi 3 50.0 50 66.7"     "report: for every repo, derived from the worktree path"

# Cost and outcomes: only four runs recorded a cost, only four have an
# outcome.json — the other two must not drag either block's numbers down.
has "$FLAT" "cost usd 3.25 8.00 4"     "report: median/p90 cost over the runs that recorded one"
has "$FLAT" "cost total \$16.00 across 4 runs" \
  "report: and their sum, with the runs without a cost left out"
has "$FLAT" "OUTCOMES RUNS %"          "report: the outcomes the janitor captured, as a block"
has "$FLAT" "merged 2 50.0"            "report: merge rate over the runs with an outcome"
has "$FLAT" "open 1 25.0"              "report: PRs still open when last checked"
has "$FLAT" "closed 1 25.0"            "report: closed unmerged"
has "$FLAT" "reverted 1 25.0"          "report: reverts, out of all captured outcomes"
has "$FLAT" "mins to merge 90.0 120.0 2" \
  "report: median/p90 minutes from PR to merge, merged runs only"

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

# --- the two review counters, on a corpus built to tell them apart -----------
# `review_account` is set the moment the Claude tier is ENTERED, so counting it
# credited a tier that produced nothing with a review. Only the classification
# says a Claude session actually read the diff. Its own runs dir, so the shares
# above stay the hand-computable ones.
TIERH="$ROOT/tier-harness"; TRUNS="$TIERH/runs"
mkdir -p "$TRUNS"
tierrun() { mkdir -p "$TRUNS/$1"; printf '%s\n' "$2" > "$TRUNS/$1/result.json"; }
tierrun T-CLAUDE '{"ticket":"T-CLAUDE","status":"ready","arm":"full","review":"reviewed_claude",
  "review_account":"claude","worktree":"/w/myapp-t-claude","metrics":{"wall_seconds":600}}'
tierrun T-ONLY '{"ticket":"T-ONLY","status":"ready","arm":"claude_only","review":"reviewed_claude",
  "review_account":"claude","worktree":"/w/myapp-t-only","metrics":{"wall_seconds":600}}'
tierrun T-DEAD '{"ticket":"T-DEAD","status":"review_failed","arm":"full","review":"failed_silent",
  "review_account":"claude","worktree":"/w/myapp-t-dead","metrics":{"wall_seconds":600}}'
TIER="$(env HARNESS_DIR="$TIERH" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
has "$TIER" "claude-tier reviews 2 <- the review was not cross-vendor" \
  "counters: only the runs a Claude session actually reviewed count as claude-tier reviews"
has "$TIER" "held: review_failed 1 <- no PR opened" \
  "counters: and the attempt that produced nothing is counted as the hold it is"
has "$TIER" "silent review failures 1" "counters: beside the class it was recorded under"
has "$TIER" "claude_only 1" "counters: the Claude-only machine's arm is reported under its own name"
has "$TIER" "(none captured yet" \
  "counters: a corpus with no outcome.json says so instead of dividing by zero"

# --- the token block, on a corpus that separates the two vendors -------------
# The point of the block: GLM's turn and cache-read distribution beside Opus's,
# so a spiral is visible rather than inferred. Its own runs dir again, so every
# median is hand-computable.
has_not "$FLAT" "MED_CACHE_RD" \
  "tokens: a corpus that never recorded usage prints no token block at all"

TOKH="$ROOT/token-harness"; TKRUNS="$TOKH/runs"
mkdir -p "$TKRUNS"
tokrun() { mkdir -p "$TKRUNS/$1"; printf '%s\n' "$2" > "$TKRUNS/$1/result.json"; }
tokrun Z-1 '{"ticket":"Z-1","status":"ready","arm":"full","review":"reviewed",
  "implementer_provider":"zai","worktree":"/w/myapp-z-1",
  "metrics":{"wall_seconds":600,
    "usage":{"input_tokens":1000,"cache_read_input_tokens":4000000,
             "cache_creation_input_tokens":0,"output_tokens":10000,
             "turns":90,"zai_credits_est":920.69}}}'
tokrun Z-2 '{"ticket":"Z-2","status":"ready","arm":"full","review":"reviewed",
  "implementer_provider":"zai","worktree":"/w/myapp-z-2",
  "metrics":{"wall_seconds":600,
    "usage":{"input_tokens":500,"cache_read_input_tokens":1000000,
             "cache_creation_input_tokens":0,"output_tokens":5000,
             "turns":30,"zai_credits_est":182.69}}}'
tokrun O-1 '{"ticket":"O-1","status":"ready","arm":"full","review":"reviewed",
  "implementer_provider":"anthropic","worktree":"/w/myapp-o-1",
  "metrics":{"wall_seconds":600,
    "usage":{"input_tokens":800,"cache_read_input_tokens":2000000,
             "cache_creation_input_tokens":0,"output_tokens":4000,
             "turns":20}}}'
# A run from before any of this: no usage object, so no row and no zeros.
tokrun OLD-1 '{"ticket":"OLD-1","status":"ready","arm":"full","review":"reviewed",
  "implementer_provider":"anthropic","worktree":"/w/myapp-old-1",
  "metrics":{"wall_seconds":600}}'
TOK="$(env HARNESS_DIR="$TOKH" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"

has "$TOK" "pipeline vitals · 4 runs" "tokens: the corpus is four runs"
has "$TOK" "TOKENS RUNS MED_TRN P90_TRN MED_CACHE_RD SUM_CACHE_RD SUM_OUTPUT CREDITS" \
  "tokens: turns and cache-read are reported side by side, per run and summed"
has "$TOK" "zai 2 60 90 2500000 5000000 15000 1103.38" \
  "tokens: the GLM runs' turns, cache-read and summed credit estimate"
has "$TOK" "anthropic 1 20 20 2000000 2000000 4000 -" \
  "tokens: the flat-billed vendor reports the same counters and no credit figure"
has "$TOK" "all 3 30 90 2000000 7000000 19000 1103.38" \
  "tokens: with the whole corpus underneath, the pre-usage run left out of it"
has "$TOK" "credits: z.ai Coding-Plan estimate, (input*6.9 + cache_read*1.7 + output*24)/10000 — off-peak discount not modelled" \
  "tokens: and the estimate says what it is and what it does not model"

# End to end: the report over the runs this suite actually dispatched must equal
# the source result.json corpus exactly. Deriving the expected totals keeps this
# assertion reorder-safe without weakening it to "at least one".
LIVE="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
LIVE_SILENT=$(printf '%s\n' "$LIVE" | awk '/^silent review failures / { print $4 }')
LIVE_HELD=$(printf '%s\n' "$LIVE" | awk '/^held: review_failed / { print $3 }')
EXPECTED_LIVE_SILENT=$(jq -s 'map(select(.review == "failed_silent")) | length' \
  "$RUNS"/*/result.json)
EXPECTED_LIVE_HELD=$(jq -s 'map(select(.status == "review_failed")) | length' \
  "$RUNS"/*/result.json)
check "live: the report counts every silent review in real run dirs" \
  "${LIVE_SILENT:-0}" "$EXPECTED_LIVE_SILENT"
check "live: and exactly the runs they held before the PR" \
  "${LIVE_HELD:-0}" "$EXPECTED_LIVE_HELD"
LIVE_RUNS=$(printf '%s\n' "$LIVE" | awk '/^pipeline vitals/ { print $4 }')
LIVE_ATTEMPTS=$(printf '%s\n' "$LIVE" | awk '/^attempts total/ { print $3 }')
# End to end for the token telemetry too: the one zai run this suite dispatched
# reaches the report as its own vendor row, counters and credit estimate intact.
has "$LIVE" "zai 1 92 92 3000000 3000000 7000 527.84" \
  "live: the dispatched zai run reports its turns, cache-read and credits"
if [ "${LIVE_ATTEMPTS:-0}" -gt "${LIVE_RUNS:-0}" ]; then
  ok "live: the re-dispatched runs make attempts outnumber runs ($LIVE_ATTEMPTS vs $LIVE_RUNS)"
else
  bad "live: attempts ($LIVE_ATTEMPTS) should outnumber runs ($LIVE_RUNS) — the ledger is not being read"
fi

echo
printf 'pipeline telemetry: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
