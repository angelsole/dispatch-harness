#!/usr/bin/env bash
# The turn-ceiling contract: `--max-turns` is a knob pinned per run, running out
# of turns resumes the pinned session instead of failing the run, a session
# limit still outranks it, and no commit reaches a PR wearing AI attribution.
#
# Nothing real is contacted. `claude` (the implementer) and `npx` (ccusage) are
# fake binaries on PATH that record what they were asked to do and answer from
# canned files, and schedule.sh is a stand-in beside the run-task.sh under test —
# the technique tests/capacity-preflight.test.sh uses. Every run is a real
# run-task.sh invocation against a fabricated repo with a local bare remote.
#
# Usage: bash tests/turn-ceiling.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/turn-ceiling-test.XXXXXX")"
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
STATION="$ROOT/station"
SCHED_CALLS="$ROOT/schedule-calls.log"
CLAUDE_CALLS="$ROOT/claude-calls.log"
CCUSAGE_JSON="$ROOT/ccusage.json"
CLAUDE_MODE="$ROOT/claude-mode"
ATTEMPTS="$ROOT/attempts"
# What the implementer's own commits looked like before the hygiene backstop ran.
PRE_DIFF="$ROOT/pre-diff"; PRE_TREE="$ROOT/pre-tree"; PRE_COUNT="$ROOT/pre-count"
PRE_FIRST="$ROOT/pre-first"; PRE_IDENT="$ROOT/pre-ident"; PRE_CLEAN="$ROOT/pre-clean"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude"
: > "$SCHED_CALLS"; : > "$CLAUDE_CALLS"
printf 'commit\n' > "$CLAUDE_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# A failing gate parks every dispatching run at gate_failed, which keeps the
# whole suite short of gh and a network while still exercising everything the
# implementer stage hands downstream.
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='exit 1' ;;
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
cat > "$SRCDIR/schedule.sh" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$SCHED_CALLS"
mkdir -p "$RUNS/\$1"
date +%s > "$RUNS/\$1/scheduled"
echo "[schedule] \$1 armed for \$4"
EOF

# ccusage stand-in: one canned blocks file, always with headroom. The mid-run
# classifier needs a reset time from it, not a verdict on the window.
cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
cat "$CCUSAGE_JSON"
EOF

# Implementer stand-in. Records the flags and the prompt of every spawn — on
# separate records, because the prompt is many lines and the flags must stay one
# greppable line — and counts attempts within a dispatch, so one fake can exhaust
# its turns once and then succeed on the resume.
#
# These dispatches run without a codex CLI, which is now the Claude review tier's
# arm rather than a skipped stage: the same binary is asked to review. That call
# is not an implementer spawn and must not be counted as one (nor may it replay
# whichever commit scenario is loaded), so it returns before anything is
# recorded. What the tier does with an empty review is tests/review-fallback's.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *"You are the reviewer stage"*) exit 0 ;; esac; done
flags=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  if [ "\$a" = "-p" ]; then skip=1; continue; fi
  flags="\$flags \$a"
done
printf 'argv:%s\n' "\$flags" >> "$CLAUDE_CALLS"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then printf 'prompt:%s\n---\n' "\$a" >> "$CLAUDE_CALLS"; break; fi
  prev="\$a"
done
n=\$(cat "$ATTEMPTS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$ATTEMPTS"
# Every spawn narrates which segment it is before its result event, so a stream
# that was appended to can be told apart from one that was overwritten. The
# result events carry a distinct num_turns and usage each, so the telemetry has
# something to sum that only adds up if it read every segment.
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"segment-%s"}]}}\n' "\$n"
usage() { printf '"num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":%s,"service_tier":"tier-%s"}' \\
  "\$((n * 10))" "\$((n * 100))" "\$((n * 1000))" "\$n"; }
exhausted() { printf '{"type":"result","subtype":"error_max_turns","result":"segment %s ran out","session_id":"fork-%s",%s}\n' "\$n" "\$n" "\$(usage)"; }
finished()  { printf '{"type":"result","subtype":"success","result":"segment %s finished","session_id":"fork-%s",%s}\n' "\$n" "\$n" "\$(usage)"; }
# This binary's stdout IS the stream-json the harness parses, so the modes that
# are dispatched more than once against the same worktree APPEND to their fixture
# file and send git's stdout to /dev/null: an unchanged file makes git(1) print
# "nothing to commit" onto the stream, which no jq downstream can read.
case "\$(cat "$CLAUDE_MODE")" in
  commit)
    date >> fixture.txt
    git add fixture.txt >/dev/null
    git commit -q -m "feat: fixture change" >/dev/null
    finished
    ;;
  turns-once)
    if [ "\$n" -ge 2 ]; then
      date >> fixture.txt
      git add fixture.txt >/dev/null
      git commit -q -m "feat: fixture change" >/dev/null
      finished
    else
      exhausted; exit 1
    fi
    ;;
  turns-always)
    exhausted; exit 1
    ;;
  limit-and-turns)
    echo "API Error: You've hit your session limit · resets 1:30pm" >&2
    exhausted; exit 1
    ;;
  questions)
    mkdir -p .harness; printf '# a question\n' > .harness/QUESTIONS.md
    exhausted; exit 1
    ;;
  ordinary-failure)
    echo "boom: ordinary implementer failure" >&2
    printf '{"type":"result","subtype":"error_during_execution","session_id":"fork-%s"}\n' "\$n"
    exit 1
    ;;
  trailers)
    printf 'one\n' > a.txt; git add a.txt
    git commit -q -m "feat: a clean commit"
    printf 'two\n' > b.txt; git add b.txt
    printf 'feat: a signed commit\n\nBody that must survive.\n\nCo-Authored-By: Ada Lovelace <ada@example.com>\nCo-Authored-By: Claude <noreply@anthropic.com>\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
      | git commit -q -F -
    printf 'three\n' > c.txt; git add c.txt
    printf 'fix: another signed commit\n\nClaude-Session: 0c9f-dead-beef\n' | git commit -q -F -
    git diff origin/main..HEAD > "$PRE_DIFF"
    git rev-parse 'HEAD^{tree}' > "$PRE_TREE"
    git rev-list --count origin/main..HEAD > "$PRE_COUNT"
    git rev-list --reverse origin/main..HEAD | head -1 > "$PRE_FIRST"
    git log -1 --format='%an|%ae|%aI|%s' > "$PRE_IDENT"
    finished
    ;;
  clean-commits)
    printf 'one\n' > a.txt; git add a.txt
    git commit -q -m "feat: nothing to strip here"
    printf 'two\n' > b.txt; git add b.txt
    printf 'feat: a human co-author\n\nCo-Authored-By: Ada Lovelace <ada@example.com>\n' | git commit -q -F -
    git rev-parse HEAD > "$PRE_FIRST"
    finished
    ;;
  merge-trailers)
    original_branch=\$(git symbolic-ref --short HEAD)
    side_branch="fixture-side-\$(printf '%s' "\$original_branch" | tr / -)"
    git switch -q -c "\$side_branch"
    printf 'side\n' > side.txt; git add side.txt
    git commit -q -m "feat: attributed side commit" \
      -m "Co-Authored-By: Claude <noreply@anthropic.com>"
    git switch -q "\$original_branch"
    printf 'main\n' > main.txt; git add main.txt
    git commit -q -m "feat: clean mainline commit"
    git rev-parse HEAD > "$PRE_CLEAN"
    git merge -q --no-ff "\$side_branch" -m "Merge fixture side" \
      -m "Co-Authored-By: Ada Lovelace <ada@example.com>" \
      -m "Claude-Session: merge-fixture"
    git diff origin/main..HEAD > "$PRE_DIFF"
    git rev-parse 'HEAD^{tree}' > "$PRE_TREE"
    git rev-list --count origin/main..HEAD > "$PRE_COUNT"
    finished
    ;;
esac
EOF

chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/claude"

stamp() { perl -e 'use POSIX qw(strftime); print strftime($ARGV[1], localtime($ARGV[0]))' -- "$1" "$2"; }
iso_utc() { perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime($ARGV[0]))' -- "$1"; }
RESET_EPOCH=$(( $(date +%s) + 900 ))
FIRE_HHMM=$(stamp "$((RESET_EPOCH + 300))" '%H:%M')
cat > "$CCUSAGE_JSON" <<EOF
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"endTime":"$(iso_utc "$RESET_EPOCH")",
   "tokenCounts":{"outputTokens":10000}}
]}
EOF

# --- the harness under test ---------------------------------------------------
RC=0; OUT=""; RUN=""; WT=""
dispatch() {  # $1 = run id, $2 = mode, $3 = space-separated VAR=VAL overrides
  local ticket="$1" mode="$2" overrides="${3:-}"
  RUN="$RUNS/$ticket"
  WT="$ROOT/greenapp-$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  printf '%s\n' "$mode" > "$CLAUDE_MODE"
  : > "$CLAUDE_CALLS"; echo 0 > "$ATTEMPTS"
  # shellcheck disable=SC2086
  env -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" HARNESS_NOTIFY=0 \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
stage_now()     { cut -d' ' -f2- < "$RUN/status" 2>/dev/null; }
result_status() { jq -r '.status // ""' "$RUN/result.json" 2>/dev/null; }
metric()        { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
# What the raw stream kept, in the order it kept it.
stream_texts()  { jq -s -r '[.[] | select(.type == "assistant")
                             | .message.content[]? | select(.type == "text")
                             | .text] | join(",")' "$RUN/opus-stream.jsonl" 2>/dev/null; }
stream_results(){ jq -s -r '[.[] | select(.type == "result") | .subtype] | join(",")' \
                    "$RUN/opus-stream.jsonl" 2>/dev/null; }
spawns()        { grep -c '^---$' "$CLAUDE_CALLS" 2>/dev/null | tr -d ' '; }
argv_of()       { grep '^argv:' "$CLAUDE_CALLS" | sed -n "$1p"; }
arm_calls()     { grep -c '^argv:' "$SCHED_CALLS" 2>/dev/null | tr -d ' '; }
git_wt()        { git -C "$WT" "$@"; }

# ---------------------------------------------------------------------------
echo "== the ceiling is a knob, pinned per run =="
# ---------------------------------------------------------------------------
dispatch TURN-DEFAULT commit ""
check "knob: the default ceiling is 200" "$(cat "$RUN/max-turns")" "200"
has "$(argv_of 1)" "--max-turns 200" "knob: and it is what the implementer is spawned with"
has_not "$(argv_of 1)" "--max-turns 120" "knob: the old hardcoded 120 is gone"

dispatch TURN-PINNED commit "HARNESS_MAX_TURNS=350"
check "knob: an explicit ceiling is pinned into the run dir" "$(cat "$RUN/max-turns")" "350"
has "$(argv_of 1)" "--max-turns 350" "knob: and reaches the CLI"

dispatch TURN-PINNED commit "HARNESS_MAX_TURNS=999"
check "knob: a re-dispatch reuses the pinned ceiling" "$(cat "$RUN/max-turns")" "350"
has "$(argv_of 1)" "--max-turns 350" "knob: the resuming shell's value is ignored"

dispatch TURN-BADKNOB commit "HARNESS_MAX_TURNS=abc"
check "knob: a garbled ceiling falls back to the default" "$(cat "$RUN/max-turns")" "200"
has "$(argv_of 1)" "--max-turns 200" "knob: and the fallback is what the CLI gets"
check "knob: the fallback says so exactly once" \
  "$(printf '%s\n' "$OUT" | grep -c "is not a positive integer" | tr -d ' ')" "1"
dispatch TURN-BADKNOB commit "HARNESS_MAX_TURNS=abc"
check "knob: the re-pinned value stops the warning repeating" \
  "$(printf '%s\n' "$OUT" | grep -c "is not a positive integer" | tr -d ' ')" "0"

dispatch TURN-ZERO commit "HARNESS_MAX_TURNS=0"
check "knob: zero is not a ceiling either" "$(cat "$RUN/max-turns")" "200"

# ---------------------------------------------------------------------------
echo "== running out of turns resumes the session instead of failing the run =="
# ---------------------------------------------------------------------------
dispatch TURN-RESUME turns-once ""
check "resume: the implementer was spawned twice" "$(spawns)" "2"
check "resume: the run reaches its normal terminal status" "$(stage_now)" "done: gate_failed"
check "resume: result.json is not implementer_failed" "$(result_status)" "gate_failed"
check "resume: the counter is on disk" "$(cat "$RUN/turn-resumes")" "1"
file_has "$RUN/timeline" "resuming: turn ceiling (1/2)" \
  "resume: the wall and the statusline get a stage line of their own"
has "$(argv_of 2)" "--resume fork-1" \
  "resume: it continues the pinned session, forked id and all — what a human re-dispatch does"
has "$(argv_of 2)" "--max-turns 200" "resume: with the run's pinned ceiling, not a fresh default"
has_not "$(argv_of 2)" "--session-id" "resume: never a second fresh session"
has "$(cat "$CLAUDE_CALLS")" "You stopped because you ran out of turns" \
  "resume: the continuation says why it was resumed"
has "$(cat "$CLAUDE_CALLS")" "Never mention AI, Claude, or agents in commits" \
  "resume: and restates the binding commit rules"
has "$(cat "$CLAUDE_CALLS")" "Never git add or commit anything under .harness/" \
  "resume: including the .harness/ rule"

# ---------------------------------------------------------------------------
echo "== a resume appends to the stream instead of replacing it =="
# ---------------------------------------------------------------------------
# The second spawn used to truncate opus-stream.jsonl, so every event of the
# segment that had run out of turns was destroyed — the verifier scored a
# trajectory missing most of the implementer's work, and the telemetry recorded
# the resumed run (the expensive kind) as cheaper than one that finished in a
# single go. TURN-RESUME above is exactly that shape: one exhausted segment,
# then a clean one.
check "stream: both segments survive, oldest first" "$(stream_texts)" "segment-1,segment-2"
check "stream: with one result event each, in order" \
  "$(stream_results)" "error_max_turns,success"

# The classifiers want something narrower than the file: the segment that just
# ended. They read the LAST result event, so a ceiling hit followed by a clean
# segment is not max_turns_hit — otherwise the loop above would have spawned a
# third time and the run would have died as implementer_failed.
check "stream: opus.log is the last segment's message alone" \
  "$(cat "$RUN/opus.log")" "segment 2 finished"
has_not "$(cat "$RUN/opus.log")" "segment 1 ran out" \
  "stream: not every segment's closing message concatenated"
check "stream: so the classifiers judged the segment that just ended" "$(spawns)" "2"

# Telemetry is the whole invocation's: each fake segment reports 10*n turns,
# 100*n input tokens and 1000*n output tokens, so only a reader that saw both
# result events gets 30 / 300 / 3000.
check "telemetry: num_turns is summed over the segments" \
  "$(metric .metrics.implementer_num_turns)" "30"
check "telemetry: and so is every numeric usage key" \
  "$(metric .metrics.implementer_usage.input_tokens)" "300"
check "telemetry: including the one the quartermaster sizes dispatches with" \
  "$(metric .metrics.implementer_usage.output_tokens)" "3000"
check "telemetry: a non-numeric usage key comes from the last segment" \
  "$(metric .metrics.implementer_usage.service_tier)" "tier-2"
check "telemetry: and the segment count says how many there were" \
  "$(metric .metrics.implementer_segments)" "2"
check "telemetry: the pinned ceiling is still the per-segment one, not a sum" \
  "$(metric .metrics.implementer_max_turns)" "200"

# An unresumed run records exactly what it always did, with one segment.
dispatch TURN-ONESEG commit ""
check "one segment: the stream holds the single spawn" "$(stream_texts)" "segment-1"
check "one segment: and its single result" "$(stream_results)" "success"
check "one segment: num_turns is the CLI's own number, unchanged" \
  "$(metric .metrics.implementer_num_turns)" "10"
check "one segment: usage is the CLI's own object, unchanged" \
  "$(metric '.metrics.implementer_usage | [.input_tokens, .output_tokens, .service_tier] | join(",")')" \
  "100,1000,tier-1"
check "one segment: counted as one" "$(metric .metrics.implementer_segments)" "1"
check "one segment: no resume was spent" "$(metric .metrics.turn_resumes)" "0"

# A fresh invocation always starts the live stream empty: it is appended to
# within an invocation, never across two.
dispatch TURN-ONESEG commit ""
check "fresh invocation: the live stream is this attempt's alone" \
  "$(stream_texts)" "segment-1"
check "fresh invocation: which the previous attempt's stream did not join" \
  "$(metric .metrics.implementer_segments)" "1"
file_has "$RUN/attempts/1/opus-stream.jsonl" "segment-1" \
  "fresh invocation: the previous one was rotated, not appended to"

# The budget is spent, then the run fails honestly.
dispatch TURN-BUDGET turns-always ""
check "budget: one spawn plus two resumes" "$(spawns)" "3"
file_has "$RUN/timeline" "resuming: turn ceiling (1/2)" "budget: first resume announced"
file_has "$RUN/timeline" "resuming: turn ceiling (2/2)" "budget: second resume announced"
check "budget: the counter stops at the budget" "$(cat "$RUN/turn-resumes")" "2"
check "budget: only then does the run fail" "$(stage_now)" "done: implementer_failed"
check "budget: and says so in result.json" "$(result_status)" "implementer_failed"
check "budget: with a non-zero exit" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"

dispatch TURN-BUDGET1 turns-always "HARNESS_MAX_RESUMES=1"
check "budget: the budget is configurable" "$(spawns)" "2"
check "budget: and honored" "$(cat "$RUN/turn-resumes")" "1"

dispatch TURN-NORESUME turns-always "HARNESS_MAX_RESUMES=0"
check "budget: zero opts out entirely" "$(spawns)" "1"
check "budget: opted out, exhaustion is a plain failure" "$(stage_now)" "done: implementer_failed"
absent "budget: and no counter is written" "$RUN/turn-resumes"

# Only turn exhaustion earns a resume.
dispatch TURN-PLAIN ordinary-failure ""
check "plain: an ordinary failure is not resumed" "$(spawns)" "1"
check "plain: it just fails" "$(stage_now)" "done: implementer_failed"
absent "plain: no turn budget was spent" "$RUN/turn-resumes"

# A worker that stopped to ask must not be talked over.
dispatch TURN-ASKED questions ""
check "questions: a pending question outranks the turn budget" "$(spawns)" "1"
check "questions: the run waits for the orchestrator" "$(stage_now)" \
  "waiting — implementer needs your input (QUESTIONS.md)"
check "questions: and records needs_input" "$(result_status)" "needs_input"
absent "questions: no turn resume was spent" "$RUN/turn-resumes"

# ---------------------------------------------------------------------------
echo "== a session limit outranks the turn ceiling =="
# ---------------------------------------------------------------------------
# Both signals at once: the capacity classifier must win, because a resume into
# an empty window cannot spawn anything and would burn the budget for nothing.
BEFORE_ARMS=$(arm_calls)
dispatch TURN-VS-CAP limit-and-turns ""
check "ordering: the implementer was spawned exactly once" "$(spawns)" "1"
check "ordering: the run defers on capacity" "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"
check "ordering: result.json agrees" "$(result_status)" "deferred_capacity"
check "ordering: a deferral was armed" "$(arm_calls)" "$((BEFORE_ARMS + 1))"
absent "ordering: no turn-resume was spent on it" "$RUN/turn-resumes"
has_not "$(cat "$RUN/timeline")" "resuming: turn ceiling" \
  "ordering: and the wall never showed a turn resume"

# ---------------------------------------------------------------------------
echo "== AI attribution never survives the implementer stage =="
# ---------------------------------------------------------------------------
dispatch TURN-TRAILERS trailers ""
LOG_AFTER="$(git_wt log origin/main..HEAD --format='%B')"
has_not "$LOG_AFTER" "Co-Authored-By: Claude"       "hygiene: the Claude co-author trailer is gone"
has_not "$LOG_AFTER" "noreply@anthropic.com"        "hygiene: and its address with it"
has_not "$LOG_AFTER" "Claude-Session:"              "hygiene: session trailers go too"
has_not "$LOG_AFTER" "Generated with [Claude Code]" "hygiene: so does the generated-with line"
has "$LOG_AFTER" "Co-Authored-By: Ada Lovelace <ada@example.com>" \
  "hygiene: a real human co-author is left alone"
has "$LOG_AFTER" "Body that must survive." "hygiene: the rest of the message is untouched"
has "$LOG_AFTER" "feat: a signed commit"   "hygiene: subjects are untouched"
has "$OUT" "commit hygiene: stripped AI attribution from 2 commit message(s)" \
  "hygiene: one line says what it did"

check "hygiene: the diff vs. base is byte-identical" \
  "$(git_wt diff origin/main..HEAD)" "$(cat "$PRE_DIFF")"
check "hygiene: the tip tree object is the same one" \
  "$(git_wt rev-parse 'HEAD^{tree}')" "$(cat "$PRE_TREE")"
check "hygiene: no commit was added or dropped" \
  "$(git_wt rev-list --count origin/main..HEAD)" "$(cat "$PRE_COUNT")"
check "hygiene: commits before the first offender keep their sha" \
  "$(git_wt rev-list --reverse origin/main..HEAD | head -1)" "$(cat "$PRE_FIRST")"
check "hygiene: author identity and dates are preserved" \
  "$(git_wt log -1 --format='%an|%ae|%aI|%s')" "$(cat "$PRE_IDENT")"
check "hygiene: the working copy is left clean" "$(git_wt status --porcelain)" ""
check "hygiene: opus_head points at the rewritten history" \
  "$(git_wt rev-parse HEAD)" "$(cat "$RUN/opus-head")"

dispatch TURN-CLEAN clean-commits ""
check "hygiene: a clean range is not rewritten at all" \
  "$(git_wt rev-parse HEAD)" "$(cat "$PRE_FIRST")"
has_not "$OUT" "commit hygiene:" "hygiene: and nothing is logged about it"
has "$(git_wt log origin/main..HEAD --format='%B')" "Co-Authored-By: Ada Lovelace" \
  "hygiene: human co-authors survive a clean run too"

dispatch TURN-MERGE merge-trailers ""
MERGE_LOG_AFTER="$(git_wt log origin/main..HEAD --format='%B')"
has_not "$MERGE_LOG_AFTER" "Co-Authored-By: Claude" \
  "hygiene merge: attribution is stripped from a merged side commit"
has_not "$MERGE_LOG_AFTER" "Claude-Session:" \
  "hygiene merge: attribution is stripped from the merge commit"
has "$MERGE_LOG_AFTER" "Co-Authored-By: Ada Lovelace <ada@example.com>" \
  "hygiene merge: a human merge co-author survives"
check "hygiene merge: the merge topology survives" \
  "$(git_wt rev-list --count --merges origin/main..HEAD)" "1"
check "hygiene merge: the diff vs. base is byte-identical" \
  "$(git_wt diff origin/main..HEAD)" "$(cat "$PRE_DIFF")"
check "hygiene merge: the tip tree object is unchanged" \
  "$(git_wt rev-parse 'HEAD^{tree}')" "$(cat "$PRE_TREE")"
check "hygiene merge: no commit was added or dropped" \
  "$(git_wt rev-list --count origin/main..HEAD)" "$(cat "$PRE_COUNT")"
check "hygiene merge: an unaffected mainline commit keeps its sha" \
  "$(git_wt rev-parse HEAD^1)" "$(cat "$PRE_CLEAN")"

# ---------------------------------------------------------------------------
echo "== a re-dispatched session is told the commit rules again =="
# ---------------------------------------------------------------------------
# TURN-ASKED stopped on a question, so its session is pinned and the next
# dispatch takes the ordinary resume path.
dispatch TURN-ASKED commit ""
has "$(argv_of 1)" "--resume" "re-dispatch: continues the pinned session"
has "$(cat "$CLAUDE_CALLS")" "The orchestrator updated .harness/brief.md" \
  "re-dispatch: with the orchestrator's continuation message"
has "$(cat "$CLAUDE_CALLS")" "Never mention AI, Claude, or agents in commits" \
  "re-dispatch: which restates the commit rules too"

# ---------------------------------------------------------------------------
echo "== the backstop is wired for every arm =="
# ---------------------------------------------------------------------------
RT="$SRC/run-task.sh"
strip_line=$(grep -nx 'strip_ai_attribution' "$RT" | cut -d: -f1)
review_line=$(grep -n 'end: review stage' "$RT" | cut -d: -f1)
push_line=$(grep -n 'stage "push + draft PR' "$RT" | cut -d: -f1)
head_line=$(grep -n '^OPUS_HEAD=' "$RT" | cut -d: -f1)
if [ -n "$strip_line" ] && [ -n "$review_line" ] && [ -n "$push_line" ] && [ -n "$head_line" ] \
   && [ "$strip_line" -lt "$review_line" ] && [ "$strip_line" -lt "$push_line" ] \
   && [ "$strip_line" -lt "$head_line" ]; then
  ok "wiring: the strip runs after the implementer, before the review arm, the PR and opus_head"
else
  bad "wiring: strip=[$strip_line] review=[$review_line] push=[$push_line] opus_head=[$head_line]"
fi

echo
printf 'turn ceiling: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
