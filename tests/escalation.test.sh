#!/usr/bin/env bash
# The escalation contract: a run implements on the cheap vendor first, and when
# that work fails the test gate the harness buys ONE pass on the Claude
# subscription instead of ending on gate_failed.
#
# What this suite pins down:
#   1. a zai run whose gate fails escalates exactly once — fresh session, fresh
#      provider pin, the failure evidence in the prompt, the record in result.json
#   2. a second failure ends the run on gate_failed with the escalation recorded
#   3. the guards: never twice, never on a gate-integrity-flagged attempt, never
#      on an attempt that left no patch, and only on the step classes the knob names
#   4. escalation off — and a run that has nowhere to escalate to — behaves
#      exactly as this pipeline did before any of this existed
#   5. an empty Claude window at the handover defers the ESCALATION, keeping the
#      evidence that earned it, and the deferred re-dispatch still escalates
#
# Nothing real is contacted. `claude` (every model stage), `gh`, `npx` (ccusage)
# and the gate command itself are fake binaries on PATH that record what they
# were asked to do, and schedule.sh is a stand-in beside the run-task.sh under
# test — the technique tests/implementer-provider.test.sh uses. Every run is a
# real run-task.sh invocation against a fabricated repo with a local bare remote.
#
# Usage: bash tests/escalation.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/escalation-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 (no $2)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 (found $2)"; else ok "$1"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
STATION="$ROOT/station"
SCHED_CALLS="$ROOT/schedule-calls.log"
CLAUDE_CALLS="$ROOT/claude-calls.log"
ENVLOG="$ROOT/claude-env.log"
GH_CALLS="$ROOT/gh-calls.log"
CCUSAGE_JSON="$ROOT/ccusage.json"
IMPL_MODE="$ROOT/impl-mode"
GATE_MODE="$ROOT/gate-mode"
GATE_ROUNDS="$ROOT/gate-rounds"
ATTEMPTS="$ROOT/attempts"

ZAI_KEY='zai-not-a-real-key-0123456789'
ZAI_URL='https://api.z.ai/api/anthropic'

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude" "$HARNESS/lib"
: > "$SCHED_CALLS"; : > "$CLAUDE_CALLS"; : > "$ENVLOG"; : > "$GH_CALLS"
printf 'commit\n' > "$IMPL_MODE"; printf 'fail\n' > "$GATE_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp -R "$SRC/lib" "$SRCDIR/lib"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp "$SRC/lib/common.sh" "$SRC/lib/gate-integrity.sh" "$HARNESS/lib/"
( umask 077; printf '%s\n' "$ZAI_KEY" > "$HARNESS/zai-api-key" )

# `run-tests` is the default gate command because the step it records is what
# the escalation trigger classifies: a fake named for what it is makes the
# `test` class real rather than asserted.
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*)
      INSTALL_CMD='true'; GATE_CMD="${TEST_GATE_CMD:-run-tests}" ;;
  esac
}
EOF

BARE="$ROOT/origin.git"
REPO="$ROOT/greenapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
mkdir -p "$REPO/src" "$REPO/tests"
printf 'hello\n' > "$REPO/src/app.js"
printf 'grep -q hello src/app.js\n' > "$REPO/tests/keep.test.js"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init
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

cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
cat "$CCUSAGE_JSON"
EOF

cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$GH_CALLS"
case "\$1 \$2" in
  "pr view")   exit 1 ;;
  "pr create") echo "https://github.com/fixture/greenapp/pull/1" ;;
  *)           exit 0 ;;
esac
EOF

# The gate, counting its own rounds so a scenario can say "fails for the first
# implementer, passes for the escalated one" without the fake knowing anything
# about the pipeline.
cat > "$FAKES/run-tests" <<EOF
#!/usr/bin/env bash
n=\$(cat "$GATE_ROUNDS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$GATE_ROUNDS"
echo "run-tests round \$n"
case "\$(cat "$GATE_MODE")" in
  pass)      exit 0 ;;
  fail-once) [ "\$n" -ge 2 ] && exit 0 || exit 1 ;;
  *)         exit 1 ;;
esac
EOF
cp "$FAKES/run-tests" "$FAKES/run-lint"
cat > "$FAKES/npm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cp "$FAKES/npm" "$FAKES/cargo"

# Every model stage runs through this one binary: it works out which stage it is
# from the prompt, records the environment it was spawned with, and — for the
# implementer — keeps each segment's prompt so the handover can be read back.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then prompt="\$a"; break; fi
  prev="\$a"
done
role=implementer
case "\$prompt" in
  *"You are the reviewer stage"*)                       role=reviewer ;;
  *"The test gate is still failing after your review"*) role=fix ;;
  *"You are the refutation stage"*)                     role=refute ;;
esac
model=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--model" ]; then model="\$a"; break; fi
  prev="\$a"
done
printf 'role=%s model=[%s] base=[%s] token=[%s] subagent=[%s]\n' \\
  "\$role" "\$model" "\${ANTHROPIC_BASE_URL:-}" "\${ANTHROPIC_AUTH_TOKEN:-}" \\
  "\${CLAUDE_CODE_SUBAGENT_MODEL:-}" >> "$ENVLOG"

if [ "\$role" != implementer ]; then
  mkdir -p .harness
  printf 'reviewed\n' > .harness/review-notes.md
  printf '[]\n' > .harness/findings.json
  echo "review done"
  exit 0
fi

flags=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  if [ "\$a" = "-p" ]; then skip=1; continue; fi
  flags="\$flags \$a"
done
n=\$(cat "$ATTEMPTS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$ATTEMPTS"
printf 'argv:%s\n' "\$flags" >> "$CLAUDE_CALLS"
printf '%s' "\$prompt" > "$ROOT/impl-prompt-\$n.txt"

if [ "\$n" = 2 ] && [ "\$(cat "$IMPL_MODE")" = escalation-start-fails ]; then
  echo "session failed before establishment" >&2
  exit 1
fi

printf '{"type":"assistant","message":{"content":[{"type":"text","text":"segment-%s"}]}}\n' "\$n"
if [ "\$n" = 1 ]; then
  case "\$(cat "$IMPL_MODE")" in
    delete-test)
      git rm -q tests/keep.test.js
      git commit -q -m "feat: fixture change" ;;
    empty-commit)
      git commit -q --allow-empty -m "chore: fixture commits nothing" ;;
    *)
      date >> src/app.js; git add src/app.js
      git commit -q -m "feat: fixture change" ;;
  esac
else
  date >> src/app.js; git add src/app.js
  git commit -q -m "fix: escalated fixture change"
fi
printf '{"type":"result","subtype":"success","result":"segment %s finished","session_id":"fork-%s","num_turns":1}\n' "\$n" "\$n"
EOF

chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/gh" "$FAKES/claude" \
         "$FAKES/run-tests" "$FAKES/run-lint" "$FAKES/npm" "$FAKES/cargo"

iso_utc() { perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime($ARGV[0]))' -- "$1"; }
RESET_EPOCH=$(( $(date +%s) + 900 ))
window() {  # $1 = output tokens already spent in the live block
  cat > "$CCUSAGE_JSON" <<EOF
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"endTime":"$(iso_utc "$RESET_EPOCH")",
   "tokenCounts":{"outputTokens":$1}}
]}
EOF
}
window 10000

# --- the harness under test ---------------------------------------------------
RC=0; OUT=""; RUN=""; WT=""; TEST_GATE_CMD=""; TEST_PREFLIGHT_CMD=""
dispatch() {  # $1 = run id, $2 = implementer mode, $3 = gate mode, $4 = overrides
  local ticket="$1" imode="$2" gmode="$3" overrides="${4:-}"
  RUN="$RUNS/$ticket"
  WT="$ROOT/greenapp-$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  printf '%s\n' "$imode" > "$IMPL_MODE"
  printf '%s\n' "$gmode" > "$GATE_MODE"
  : > "$CLAUDE_CALLS"; : > "$ENVLOG"; echo 0 > "$ATTEMPTS"; echo 0 > "$GATE_ROUNDS"
  rm -f "$ROOT"/impl-prompt-*.txt
  # shellcheck disable=SC2086
  env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      -u HARNESS_ESCALATION -u HARNESS_ESCALATION_STEPS \
      -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" HARNESS_NOTIFY=0 \
      HARNESS_GATE_INTEGRITY=0 TEST_GATE_CMD="$TEST_GATE_CMD" \
      PREFLIGHT_CMD="$TEST_PREFLIGHT_CMD" \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
result()    { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
pin()       { cat "$RUN/$1" 2>/dev/null; }
env_of()    { grep "^role=$1" "$ENVLOG" | sed -n "${2:-1}p"; }
spawns_of() { grep -c "^role=$1" "$ENVLOG" 2>/dev/null | tr -d ' '; }
arm_calls() { grep -c '^argv:' "$SCHED_CALLS" 2>/dev/null | tr -d ' '; }
impl_argv() { sed -n "${1}p" "$CLAUDE_CALLS" 2>/dev/null; }
prompt_of() { cat "$ROOT/impl-prompt-$1.txt" 2>/dev/null; }
commits()   { git -C "$WT" rev-list --count "$1..$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== the knob, and what it defaults to =="
# ---------------------------------------------------------------------------
dispatch ESC-KNOB-DEFAULT commit fail ""
check "knob: a run on the escalation target itself pins escalation off" \
  "$(pin escalation)" "off"
check "knob: and the step classes are pinned whatever the arm" \
  "$(pin escalation-steps)" "test,lint,type-check"

dispatch ESC-KNOB-ZAI commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION=off"
check "knob: an explicit off is pinned" "$(pin escalation)" "off"
dispatch ESC-KNOB-ZAI commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION=on"
check "knob: and a re-dispatch reuses the pin rather than the environment" \
  "$(pin escalation)" "off"

dispatch ESC-KNOB-BOGUS commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION=maybe"
check "knob: an unknown value falls back to the provider's default" \
  "$(pin escalation)" "on"
check "knob: and says so exactly once" \
  "$(printf '%s\n' "$OUT" | grep -c 'is not on or off' | tr -d ' ')" "1"
dispatch ESC-STEPS-BOGUS commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION_STEPS=test,fortran"
check "knob: an unknown step class falls back too" \
  "$(pin escalation-steps)" "test,lint,type-check"
has "$OUT" "names no such step class 'fortran'" "knob: naming the class it could not use"

# ---------------------------------------------------------------------------
echo "== a failing gate on the cheap tier buys one pass on the Claude sub =="
# ---------------------------------------------------------------------------
dispatch ESC-ONE commit fail \
  "IMPLEMENTER_PROVIDER=zai ANTHROPIC_BASE_URL=$ZAI_URL ANTHROPIC_AUTH_TOKEN=$ZAI_KEY"
check "escalate: the implementer ran twice" "$(spawns_of implementer)" "2"
has "$(env_of implementer 1)" "model=[glm-5.3]" "escalate: the first pass was the cheap vendor's"
has "$(env_of implementer 1)" "base=[$ZAI_URL]" "escalate: pointed at its endpoint"
has "$(env_of implementer 2)" "model=[claude-opus-5]" \
  "escalate: the second pass is the Claude subscription's default model"
has "$(env_of implementer 2)" "base=[]"  "escalate: with no z.ai endpoint in sight"
has "$(env_of implementer 2)" "token=[]" "escalate: and no z.ai credential"
has "$(env_of implementer 2)" "subagent=[sonnet]" \
  "escalate: its subagents move back to Anthropic with it"

has "$(impl_argv 2)" "--session-id" "escalate: the escalated pass is a FRESH session"
has_not "$(impl_argv 2)" "--resume" "escalate: never the cheap tier's context on a dearer model"

P2="$(prompt_of 2)"
has "$P2" "left FAILING"            "prompt: the framing says the previous attempt failed"
has "$P2" "external artifact"       "prompt: and that the report is somebody else's account"
has "$P2" "You are the implementer stage" "prompt: the original brief instructions are still the contract"
has "$P2" "Why this task is being handed over" "prompt: the gate evidence is attached"
has "$P2" "Failing gate step: run-tests" "prompt: naming the step that failed"
has "$P2" "run-tests round 1"       "prompt: with the gate output the harness kept"
has "$P2" "src/app.js"              "prompt: and the diff the cheap attempt left behind"

check "escalate: the run is re-pinned to the escalation target" \
  "$(pin implementer-provider)" "anthropic"
check "escalate: on that vendor's own default model" "$(pin implementer-model)" "claude-opus-5"
check "escalate: which is what result.json now reports" \
  "$(result .implementer_provider)" "anthropic"

# ---------------------------------------------------------------------------
echo "== the record: what escalated, from where, and on what evidence =="
# ---------------------------------------------------------------------------
check "record: result.json says the run escalated" "$(result .escalation.triggered)" "true"
check "record: naming the vendor it came from"     "$(result .escalation.from_provider)" "zai"
check "record: and the model"                      "$(result .escalation.from_model)" "glm-5.3"
check "record: the attempt it was triggered at"    "$(result .escalation.at_attempt)" "1"
check "record: and the gate step that triggered it" "$(result .escalation.failed_step)" "run-tests"
GLM_HEAD="$(result .escalation.glm_head)"
OPUS_HEAD="$(result .opus_head)"
check "record: glm_head is the cheap attempt's last commit" \
  "$(commits origin/main "$GLM_HEAD")" "1"
check "record: and glm_head..opus_head is the escalated session's" \
  "$(commits "$GLM_HEAD" "$OPUS_HEAD")" "1"

check "record: the escalated attempt is the run's second" "$(result .attempt)" "2"
check "record: and the first is in the ledger on the verdict that escalated it" \
  "$(jq -r '.metrics.attempts[0].status' "$RUN/result.json")" "gate_failed"
exists "record: the cheap attempt's stream is preserved" "$RUN/attempts/1/opus-stream.jsonl"
exists "record: with its gate rounds"                    "$RUN/attempts/1/gate-rounds.log"
exists "record: and the handover report is kept"         "$RUN/escalation-report.md"
absent "record: no independent pending marker is written" \
  "$RUN/escalation-pending"
check "record: the atomic handoff record is no longer pending" \
  "$(jq -r '.pending' "$RUN/escalation.json")" "false"

# ---------------------------------------------------------------------------
echo "== a second failure ends the run, it does not escalate again =="
# ---------------------------------------------------------------------------
check "twice: the run ends on the gate's verdict" "$(result .status)" "gate_failed"
check "twice: exiting non-zero"                   "$RC" "1"
has "$OUT" "already escalated once" "twice: saying why it did not escalate again"
check "twice: with the escalation still on the record" "$(result .escalation.triggered)" "true"
check "twice: and the review still happened on the escalated diff" \
  "$(spawns_of reviewer)" "1"

# ---------------------------------------------------------------------------
echo "== an escalated attempt that passes the gate ships like any other =="
# ---------------------------------------------------------------------------
dispatch ESC-RECOVER commit fail-once "IMPLEMENTER_PROVIDER=zai"
check "recover: the escalated pass turned the gate green" "$(result .gate)" "pass"
check "recover: and the run reached ready"                "$(result .status)" "ready"
check "recover: on a diff a reviewer read"                "$(result .review)" "reviewed_claude"
check "recover: with the escalation on the record"        "$(result .escalation.triggered)" "true"

# ---------------------------------------------------------------------------
echo "== the guards =="
# ---------------------------------------------------------------------------
# A gate the integrity check does not believe must not buy a second, more
# expensive pass — whichever way that round went.
dispatch ESC-FLAGGED-RED delete-test fail \
  "IMPLEMENTER_PROVIDER=zai HARNESS_GATE_INTEGRITY=1"
check "guard: a flagged attempt does not escalate" "$(spawns_of implementer)" "1"
absent "guard: and nothing is recorded as escalated" "$RUN/escalation.json"
has "$OUT" "gate integrity check flagged this attempt" "guard: the log says why"
check "guard: the run ends on the gate's verdict" "$(result .status)" "gate_failed"

TEST_GATE_CMD=true
dispatch ESC-FLAGGED-GREEN delete-test pass \
  "IMPLEMENTER_PROVIDER=zai HARNESS_GATE_INTEGRITY=1"
TEST_GATE_CMD=""
check "guard: a flagged GREEN never escalates either" "$(spawns_of implementer)" "1"
absent "guard: nothing escalated on a passing gate" "$RUN/escalation.json"
if [ "$(jq -r '.gate_integrity.flag_count' "$RUN/result.json" 2>/dev/null)" -ge 1 ]; then
  ok "guard: and the flags that would have vetoed it are real"
else
  bad "guard: the flagged fixture produced no integrity flags"
fi

# Escalation corrects a patch the gate rejected. There is nothing to correct
# when the attempt produced no patch, and measured recovery there is zero.
dispatch ESC-NO-PATCH empty-commit fail "IMPLEMENTER_PROVIDER=zai"
check "guard: an attempt with no diff does not escalate" "$(spawns_of implementer)" "1"
has "$OUT" "there is no patch to correct" "guard: saying so"
check "guard: and the run ends on the gate's verdict" "$(result .status)" "gate_failed"

# A rejection from an earlier dispatch judged an earlier brief and tree. An
# escalation-enabled cheap run archives it during setup, before it can veto a
# newly-earned escalation.
STALE_TICKET=ESC-STALE-REJECTION
STALE_WT="$ROOT/greenapp-$(printf '%s' "$STALE_TICKET" | tr '[:upper:]' '[:lower:]')"
git -C "$REPO" worktree add -q -b "fix/$STALE_TICKET" "$STALE_WT" origin/main
mkdir -p "$STALE_WT/.harness"
printf '# obsolete rejection\n' > "$STALE_WT/.harness/REJECTED.md"
dispatch "$STALE_TICKET" commit fail "IMPLEMENTER_PROVIDER=zai"
check "guard: a stale rejection does not suppress escalation" \
  "$(spawns_of implementer)" "2"
exists "guard: the stale rejection is archived" "$RUN/REJECTED.prev.md"
absent "guard: the stale rejection is gone before the new attempt" \
  "$WT/.harness/REJECTED.md"

# Outside that path, stale rejections retain their historical meaning. In
# particular, a no-review redispatch must still end rejected even when its new
# gate passes, whether escalation is explicitly off or has nowhere to go.
for stale_case in \
  'ESC-STALE-OFF|IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION=off HARNESS_SKIP_REVIEW=1' \
  'ESC-STALE-ANTHROPIC|HARNESS_SKIP_REVIEW=1'; do
  STALE_TICKET=${stale_case%%|*}
  STALE_OVERRIDES=${stale_case#*|}
  STALE_WT="$ROOT/greenapp-$(printf '%s' "$STALE_TICKET" | tr '[:upper:]' '[:lower:]')"
  git -C "$REPO" worktree add -q -b "fix/$STALE_TICKET" "$STALE_WT" origin/main
  mkdir -p "$STALE_WT/.harness"
  printf '# prior dispatch rejection\n' > "$STALE_WT/.harness/REJECTED.md"
  dispatch "$STALE_TICKET" commit pass "$STALE_OVERRIDES"
  check "guard: $STALE_TICKET keeps the old rejected outcome" \
    "$(result .status)" "rejected"
  exists "guard: $STALE_TICKET leaves the rejection in the worktree" \
    "$WT/.harness/REJECTED.md"
  absent "guard: $STALE_TICKET does not archive the rejection" \
    "$RUN/REJECTED.prev.md"
done

# But an arm that REVIEWS has always cleared it, escalation or no escalation:
# section 6 keys the outcome off this file, so a re-review that approves would
# still read as rejected. That is the pipeline's own behaviour and escalation
# must not have narrowed it.
STALE_TICKET=ESC-STALE-REVIEWED
STALE_WT="$ROOT/greenapp-$(printf '%s' "$STALE_TICKET" | tr '[:upper:]' '[:lower:]')"
git -C "$REPO" worktree add -q -b "fix/$STALE_TICKET" "$STALE_WT" origin/main
mkdir -p "$STALE_WT/.harness"
printf '# prior dispatch rejection\n' > "$STALE_WT/.harness/REJECTED.md"
TEST_PREFLIGHT_CMD='test -f .harness/REJECTED.md'
dispatch "$STALE_TICKET" commit pass ""
TEST_PREFLIGHT_CMD=""
exists "guard: a reviewing arm archives the stale rejection" "$RUN/REJECTED.prev.md"
absent "guard: and does not carry it into this dispatch" "$WT/.harness/REJECTED.md"
check "guard: so a re-review that approves is not read as rejected" \
  "$(result .status)" "ready"

# The other half of the same condition: the escalation path clears it even in
# the arm that never reviews, or a stale verdict would veto the handover.
STALE_TICKET=ESC-STALE-NOREVIEW-ESC
STALE_WT="$ROOT/greenapp-$(printf '%s' "$STALE_TICKET" | tr '[:upper:]' '[:lower:]')"
git -C "$REPO" worktree add -q -b "fix/$STALE_TICKET" "$STALE_WT" origin/main
mkdir -p "$STALE_WT/.harness"
printf '# prior dispatch rejection\n' > "$STALE_WT/.harness/REJECTED.md"
dispatch "$STALE_TICKET" commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_SKIP_REVIEW=1"
exists "guard: the no_review arm archives it when it can still escalate" \
  "$RUN/REJECTED.prev.md"
check "guard: and the handover happens" "$(spawns_of implementer)" "2"
check "guard: with the review still skipped" "$(result .review)" "skipped"

# The step classes: escalation-steps decides, and it is overridable.
TEST_GATE_CMD='exit 7'
dispatch ESC-STEP-UNKNOWN commit fail "IMPLEMENTER_PROVIDER=zai"
check "steps: a step no class recognises does not escalate by default" \
  "$(spawns_of implementer)" "1"
has "$OUT" "died on a 'unknown' step" "steps: naming the class it decided on"

dispatch ESC-STEP-OVERRIDE commit fail \
  "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION_STEPS=unknown"
check "steps: and escalates on it when the knob says so" "$(spawns_of implementer)" "2"
TEST_GATE_CMD=""

TEST_GATE_CMD=run-lint
dispatch ESC-STEP-LINT commit fail "IMPLEMENTER_PROVIDER=zai"
check "steps: a lint step is in the default set" "$(spawns_of implementer)" "2"
check "steps: and the class it escalated on is recorded by its step" \
  "$(result .escalation.failed_step)" "run-lint"
TEST_GATE_CMD=""

for type_gate in 'npm run check:types' 'cargo check'; do
  TEST_GATE_CMD="$type_gate"
  dispatch "ESC-STEP-$(printf '%s' "$type_gate" | tr ' :' '--' | tr '[:lower:]' '[:upper:]')" \
    commit fail "IMPLEMENTER_PROVIDER=zai"
  check "steps: '$type_gate' is a type-check step in the default set" \
    "$(spawns_of implementer)" "2"
  check "steps: '$type_gate' is recorded as the failing step" \
    "$(result .escalation.failed_step)" "$type_gate"
done
TEST_GATE_CMD=""

# ---------------------------------------------------------------------------
echo "== off, and on a run with nowhere to escalate to, nothing changes =="
# ---------------------------------------------------------------------------
dispatch ESC-OFF commit fail "IMPLEMENTER_PROVIDER=zai HARNESS_ESCALATION=off"
check "off: the implementer ran exactly once" "$(spawns_of implementer)" "1"
check "off: on the vendor the run was dispatched with" "$(pin implementer-provider)" "zai"
check "off: ending on the gate's verdict"  "$(result .status)" "gate_failed"
absent "off: nothing was recorded"         "$RUN/escalation.json"
absent "off: nothing was handed over"      "$RUN/escalation-report.md"
check "off: result.json carries no escalation field at all" \
  "$(jq -r 'has("escalation")' "$RUN/result.json")" "false"
check "off: and the pipeline never mentions escalation" \
  "$(printf '%s\n' "$OUT" | grep -c 'harness. escalation' | tr -d ' ')" "0"

dispatch ESC-ANTHROPIC commit fail ""
check "default: an anthropic run runs its implementer once" "$(spawns_of implementer)" "1"
absent "default: and escalates nowhere" "$RUN/escalation.json"
check "default: saying nothing about it" \
  "$(printf '%s\n' "$OUT" | grep -c 'harness. escalation' | tr -d ' ')" "0"
check "default: ending exactly where it did before" "$(result .status)" "gate_failed"

# ---------------------------------------------------------------------------
echo "== an empty Claude window defers the escalation, not the evidence =="
# ---------------------------------------------------------------------------
# The escalated segment spends the Claude subscription, so it pays the same
# preflight every anthropic run pays — and a deferral there must leave the
# handover armed rather than throwing away the failure that earned it.
window 1000000
BEFORE_ARMS=$(arm_calls)
dispatch ESC-DEFER commit fail-once "IMPLEMENTER_PROVIDER=zai"
check "defer: the run deferred instead of spawning Opus" \
  "$(result .status)" "deferred_capacity"
check "defer: exiting 0 — deferred, not failed" "$RC" "0"
check "defer: having armed exactly one schedule" "$(arm_calls)" "$((BEFORE_ARMS + 1))"
check "defer: the cheap implementer ran, the escalated one did not" \
  "$(spawns_of implementer)" "1"
check "defer: the atomic handoff record still says it is owed" \
  "$(jq -r '.pending' "$RUN/escalation.json")" "true"
absent "defer: no independent pending marker can get out of sync" \
  "$RUN/escalation-pending"
exists "defer: with its report still on disk"    "$RUN/escalation-report.md"
check "defer: and the escalation still on the record" \
  "$(result .escalation.triggered)" "true"
exists "defer: the cheap attempt's evidence survived" "$RUN/attempts/1/opus-stream.jsonl"

window 10000
dispatch ESC-DEFER commit fail-once ""
check "defer: the re-dispatch runs the escalated session it owed" \
  "$(spawns_of implementer)" "1"
has "$(env_of implementer 1)" "model=[claude-opus-5]" "defer: on the escalation target"
has "$(prompt_of 1)" "left FAILING" "defer: with the handover it kept"
check "defer: and the atomic record is cleared once it is spent" \
  "$(jq -r '.pending' "$RUN/escalation.json")" "false"

# A handoff is not spent merely because its session id was allocated. Without a
# result event proving the CLI established that session, a later dispatch must
# still see the obligation and start fresh.
dispatch ESC-START-FAIL escalation-start-fails fail-once "IMPLEMENTER_PROVIDER=zai"
check "handoff: a session that never establishes fails the escalated attempt" \
  "$(result .status)" "implementer_failed"
exists "handoff: the transaction record survives until a session is established" \
  "$RUN/escalation.json"
check "handoff: its atomic record still says the handoff is owed" \
  "$(jq -r '.pending' "$RUN/escalation.json")" "true"

# The transaction record, not separately-written pins, drives recovery. Simulate
# an interruption that left old pin contents behind and prove the owed handoff
# still launches on the complete target recorded atomically.
printf 'zai\n' > "$RUN/implementer-provider"
printf 'glm-5.3\n' > "$RUN/implementer-model"
dispatch ESC-START-FAIL commit fail-once ""
has "$(env_of implementer 1)" "model=[claude-opus-5]" \
  "handoff: recovery takes its model from the atomic record"
has "$(env_of implementer 1)" "base=[]" \
  "handoff: recovery takes its provider from the atomic record"
has "$(prompt_of 1)" "left FAILING" \
  "handoff: recovery still receives the escalation handoff"
check "handoff: the recovered session completes the pending transition" \
  "$(jq -r '.pending' "$RUN/escalation.json")" "false"

echo
printf 'escalation: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
