#!/usr/bin/env bash
# The capacity preflight contract: run-task.sh must know the session window is
# empty BEFORE it pays for a worktree, a deps install and an implementer spawn,
# and defer itself to the block's reset time instead of dying on
# "You've hit your session limit" and recording implementer_failed.
#
# Nothing real is contacted. `npx` (ccusage), `claude` (the implementer) and
# `curl` (ntfy) are fake binaries on PATH answering from canned files and
# recording what they were asked to do, and schedule.sh is a stand-in beside the
# run-task.sh under test — the technique tests/quartermaster.test.sh uses — so
# the deferral is asserted argument by argument. Every run is a real
# run-task.sh invocation against a fabricated repo with a local bare remote.
#
# Usage: bash tests/capacity-preflight.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/capacity-preflight-test.XXXXXX")"
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
NPX_LOG="$ROOT/npx.log"
CURL_LOG="$ROOT/curl.log"
CCUSAGE_JSON="$ROOT/ccusage.json"
CCUSAGE_BROKEN="$ROOT/ccusage-broken"
CLAUDE_MODE="$ROOT/claude-mode"
INSTALL_MARK="$ROOT/install-ran"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude"
: > "$SCHED_CALLS"; : > "$CLAUDE_CALLS"; : > "$NPX_LOG"; : > "$CURL_LOG"
printf 'commit\n' > "$CLAUDE_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# Pin both commands so the fixture proves what it claims: INSTALL_CMD leaves a
# marker (a deferral must never reach it) and GATE_CMD fails, which parks every
# dispatching run at gate_failed instead of walking into gh and a network.
cat > "$HARNESS/repos.local.sh" <<EOF
repo_config_local() {
  case "\$2" in
    greenapp|greenapp-*)
      INSTALL_CMD='touch $INSTALL_MARK'
      GATE_CMD='exit 1'
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
# The scheduler stand-in: records its argv and the identity the snapshot would
# have carried, then leaves the real marker behind so a capacity-deferred run
# looks on disk exactly like a human-armed one.
cat > "$SRCDIR/schedule.sh" <<EOF
#!/usr/bin/env bash
{
  printf 'argv:%s\n'       "\$*"
  printf 'claude:%s\n'     "\${CLAUDE_CONFIG_DIR-<unset>}"
  printf 'harnessdir:%s\n' "\${HARNESS_DIR-<unset>}"
  printf 'owner:%s\n'      "\${HARNESS_OWNER-<unset>}"
} >> "$SCHED_CALLS"
[ -f "$ROOT/schedule-refuse" ] && { echo "[schedule] FATAL: refusing" >&2; exit 1; }
mkdir -p "$RUNS/\$1"
date +%s > "$RUNS/\$1/scheduled"
echo "[schedule] \$1 armed for \$4"
EOF

# ccusage stand-in: local files only, answers from one canned blocks file.
cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
printf '%s | CLAUDE_CONFIG_DIR=%s\n' "\$*" "\${CLAUDE_CONFIG_DIR-<unset>}" >> "$NPX_LOG"
if [ -f "$CCUSAGE_BROKEN" ]; then echo "ccusage: no usage data" >&2; exit 1; fi
cat "$CCUSAGE_JSON"
EOF

# Implementer stand-in. `commit` moves the pipeline along; the other modes are
# the failure shapes the classifier has to tell apart.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then printf '%s\n---\n' "\$a" >> "$CLAUDE_CALLS"; break; fi
  prev="\$a"
done
case "\$(cat "$CLAUDE_MODE")" in
  commit)
    date > fixture.txt
    git add fixture.txt
    git commit -q -m "feat: fixture change"
    ;;
  limit-stderr)
    echo "API Error: You've hit your session limit · resets 1:30pm" >&2
    exit 1
    ;;
  limit-result)
    printf '%s\n' '{"type":"result","subtype":"error_during_execution","result":"Claude AI usage limit reached|1754500000"}'
    exit 1
    ;;
  transcript-mention)
    # The worker merely *talking* about session limits — this feature's own
    # tests do — must never reschedule the run it is working on.
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"the harness handles: You have hit your session limit"}]}}'
    echo "boom: the implementer fell over for an ordinary reason" >&2
    exit 1
    ;;
esac
EOF

cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
EOF

chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/claude" "$FAKES/curl"

# --- canned capacity ----------------------------------------------------------
stamp() { perl -e 'use POSIX qw(strftime); print strftime($ARGV[1], localtime($ARGV[0]))' -- "$1" "$2"; }
iso_utc() { perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime($ARGV[0]))' -- "$1"; }

NOW=$(date +%s)
RESET_EPOCH=$((NOW + 900))                 # the active block rolls over in 15m
RESET_ISO=$(iso_utc "$RESET_EPOCH")
FIRE_EPOCH=$((RESET_EPOCH + 300))          # + the default HARNESS_DEFER_BUFFER_SECS
FIRE_WHEN=$(stamp "$FIRE_EPOCH" '%Y-%m-%d %H:%M')
FIRE_HHMM=$(stamp "$FIRE_EPOCH" '%H:%M')

# One completed block at 400k output tokens is the ceiling; how much of it the
# active block has already spent is the whole question.
blocks() {  # $1 = output tokens spent in the active block
  cat > "$CCUSAGE_JSON" <<EOF
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":false,"isGap":true,"tokenCounts":{"outputTokens":9999999}},
  {"id":"b3","isActive":true,"isGap":false,"endTime":"$RESET_ISO",
   "tokenCounts":{"outputTokens":$1}}
]}
EOF
}
healthy()   { blocks 10000; }     # 390k left — plenty
exhausted() { blocks 400000; }    # nothing left at all

# --- the harness under test ---------------------------------------------------
arm_calls() { grep -c '^argv:' "$SCHED_CALLS" 2>/dev/null | tr -d ' '; }
impl_calls() { grep -c '^---$' "$CLAUDE_CALLS" 2>/dev/null | tr -d ' '; }
npx_calls() { grep -c '' < "$NPX_LOG" | tr -d ' '; }

RC=0; OUT=""; RUN=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  rm -f "$INSTALL_MARK"
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=cap-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
stage_now() { cut -d' ' -f2- < "$RUN/status" 2>/dev/null; }
result_status() { jq -r '.status // ""' "$RUN/result.json" 2>/dev/null; }
worktree_of() { printf '%s/greenapp-%s' "$ROOT" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; }

# ---------------------------------------------------------------------------
echo "== an exhausted window defers itself instead of burning the launch =="
# ---------------------------------------------------------------------------
exhausted
dispatch CAP-DEFER ""
check "defer: the run exits 0 — a deferral is not a failure" "$RC" "0"
check "defer: exactly one schedule armed" "$(arm_calls)" "1"
file_has "$SCHED_CALLS" "argv:CAP-DEFER $REPO fix/CAP-DEFER $FIRE_WHEN" \
  "defer: ticket, repo, branch and the reset time + buffer reach schedule.sh"
file_has "$SCHED_CALLS" "claude:$STATION/claude" \
  "defer: the launching identity's config dir is in the env schedule.sh snapshots"
file_has "$SCHED_CALLS" "harnessdir:$HARNESS" "defer: the harness dir travels with it"
check "defer: the status line says so" "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"
check "defer: result.json records the outcome" "$(result_status)" "deferred_capacity"
check "defer: the deferral is counted" "$(cat "$RUN/deferrals")" "1"
exists "defer: the schedule marker makes it look exactly like a human-armed run" \
  "$RUN/scheduled"
check "defer: no implementer was spawned" "$(impl_calls)" "0"
absent "defer: no worktree was created" "$(worktree_of CAP-DEFER)"
absent "defer: no deps install was wasted" "$INSTALL_MARK"
absent "defer: no install log, because the step never ran" "$RUN/install.log"
file_has "$RUN/capacity.log" "preflight: only 0 of 400000 output tokens left" \
  "defer: the preflight leaves its own reasoning on disk"
file_has "$CURL_LOG" "deferred: capacity, armed for $FIRE_HHMM" \
  "defer: the deferral goes out over the existing ntfy mechanics"
has "$OUT" "session capacity is spent — armed for $FIRE_WHEN" "defer: and says so on the console"

# ---------------------------------------------------------------------------
echo "== a healthy window dispatches exactly as it always did =="
# ---------------------------------------------------------------------------
healthy
BEFORE_ARMS=$(arm_calls)
dispatch CAP-HEALTHY ""
HEALTHY_RC=$RC
check "healthy: the implementer ran" "$(impl_calls)" "1"
file_has "$CLAUDE_CALLS" "You are the implementer stage of an automated pipeline." \
  "healthy: with the unchanged implementer prompt"
check "healthy: nothing was armed" "$(arm_calls)" "$BEFORE_ARMS"
exists "healthy: deps were installed" "$INSTALL_MARK"
check "healthy: the run reaches its normal terminal status" "$(stage_now)" "done: gate_failed"
absent "healthy: no deferral counter appears" "$RUN/deferrals"
has_not "$OUT" "[harness] preflight:" "healthy: the console says nothing about the preflight"
file_has "$RUN/capacity.log" "preflight: ok — 390000 of 400000 output tokens left" \
  "healthy: the verdict is still recorded off to the side"

BEFORE_NPX=$(npx_calls)
dispatch CAP-OFF "HARNESS_PREFLIGHT=off"
check "off: HARNESS_PREFLIGHT=off consults ccusage not at all" "$(npx_calls)" "$BEFORE_NPX"
absent "off: and writes no capacity log" "$RUN/capacity.log"
check "off: the run behaves the same" "$RC" "$HEALTHY_RC"

# Byte-identical, modulo the run id: the preflight is invisible on the console
# of a run that had capacity all along.
norm() { sed -e "s/$1/TICKET/g" -e "s/$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')/ticket/g" "$2"; }
if [ "$(norm CAP-HEALTHY "$ROOT/run-CAP-HEALTHY.log")" = "$(norm CAP-OFF "$ROOT/run-CAP-OFF.log")" ]; then
  ok "healthy: the console output is identical to a run with the preflight off"
else
  bad "healthy: console drift vs. HARNESS_PREFLIGHT=off
$(diff <(norm CAP-HEALTHY "$ROOT/run-CAP-HEALTHY.log") <(norm CAP-OFF "$ROOT/run-CAP-OFF.log"))"
fi

# ---------------------------------------------------------------------------
echo "== ccusage unavailable: fail open, one line, dispatch anyway =="
# ---------------------------------------------------------------------------
: > "$CCUSAGE_BROKEN"
BEFORE_ARMS=$(arm_calls); BEFORE_IMPL=$(impl_calls)
dispatch CAP-BLIND ""
rm -f "$CCUSAGE_BROKEN"
check "blind: the implementer still ran" "$(impl_calls)" "$((BEFORE_IMPL + 1))"
check "blind: nothing was armed" "$(arm_calls)" "$BEFORE_ARMS"
check "blind: the run reaches its normal terminal status" "$(stage_now)" "done: gate_failed"
check "blind: exactly one preflight line on the console" \
  "$(printf '%s\n' "$OUT" | grep -c '\[harness\] preflight:' | tr -d ' ')" "1"
has "$OUT" "capacity unknown (ccusage unavailable" "blind: and it says what it could not read"

# ---------------------------------------------------------------------------
echo "== at most two auto-deferrals, then an honest failure =="
# ---------------------------------------------------------------------------
exhausted
dispatch CAP-CAP ""
check "cap: the first dispatch defers" "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"
check "cap: counter at 1" "$(cat "$RUN/deferrals")" "1"
dispatch CAP-CAP ""
check "cap: the second dispatch defers too" "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"
check "cap: counter at 2" "$(cat "$RUN/deferrals")" "2"

BEFORE_ARMS=$(arm_calls)
dispatch CAP-CAP ""
check "cap: the third dispatch fails instead of rescheduling" "$(stage_now)" "done: capacity_failed"
check "cap: with a status of its own, not implementer_failed" "$(result_status)" "capacity_failed"
check "cap: and a non-zero exit" "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "cap: nothing further was armed" "$(arm_calls)" "$BEFORE_ARMS"
check "cap: the counter did not move" "$(cat "$RUN/deferrals")" "2"
has "$OUT" "already been deferred 2 time(s)" "cap: the console explains why it stopped"
has "$OUT" "not rescheduling again" "cap: and that it will not try again"

# A refused arm must not swallow the dispatch: the preflight is advisory.
: > "$ROOT/schedule-refuse"
exhausted
dispatch CAP-REFUSED ""
rm -f "$ROOT/schedule-refuse"
check "refused: the run dispatches anyway" "$(stage_now)" "done: gate_failed"
absent "refused: no deferral was counted" "$RUN/deferrals"
has "$OUT" "could not arm a deferral" "refused: and says why"

# ---------------------------------------------------------------------------
echo "== a window that empties mid-run is capacity, not a failed implementer =="
# ---------------------------------------------------------------------------
healthy
printf 'limit-stderr\n' > "$CLAUDE_MODE"
BEFORE_ARMS=$(arm_calls)
dispatch CAP-MIDRUN ""
check "mid-run: the run exits 0 — it is deferred, not failed" "$RC" "0"
check "mid-run: armed one schedule" "$(arm_calls)" "$((BEFORE_ARMS + 1))"
file_has "$SCHED_CALLS" "argv:CAP-MIDRUN $REPO fix/CAP-MIDRUN $FIRE_WHEN" \
  "mid-run: the reset time comes from ccusage, not from the message"
check "mid-run: the status says capacity, not implementer_failed" \
  "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"
check "mid-run: result.json agrees" "$(result_status)" "deferred_capacity"
file_has "$RUN/capacity.log" "mid-run: the implementer stopped on a session limit" \
  "mid-run: the classification is recorded"

printf 'limit-result\n' > "$CLAUDE_MODE"
dispatch CAP-MIDRUN2 ""
check "mid-run: the CLI's own result message triggers it too" \
  "$(stage_now)" "deferred: capacity, armed for $FIRE_HHMM"

# The other half of the contract: an ordinary failure stays an ordinary failure,
# and the worker's transcript is not evidence.
printf 'transcript-mention\n' > "$CLAUDE_MODE"
BEFORE_ARMS=$(arm_calls)
dispatch CAP-PLAINFAIL ""
check "plain: an unrelated implementer failure is still implementer_failed" \
  "$(stage_now)" "done: implementer_failed"
check "plain: nothing was armed for it" "$(arm_calls)" "$BEFORE_ARMS"
file_has "$RUN/feed.log" "hit your session limit" \
  "plain: the phrase really was in the worker's transcript"
absent "plain: and it did not reschedule the run" "$RUN/deferrals"

printf 'limit-stderr\n' > "$CLAUDE_MODE"
dispatch CAP-MIDRUN-OFF "HARNESS_PREFLIGHT=off"
check "off: the classifier is off with the rest of the feature" \
  "$(stage_now)" "done: implementer_failed"
printf 'commit\n' > "$CLAUDE_MODE"

# ---------------------------------------------------------------------------
echo "== the hard rule: local file accounting, no model provider =="
# ---------------------------------------------------------------------------
has_not "$(cat "$CURL_LOG")" "anthropic" "hard rule: no Anthropic endpoint was contacted"
has_not "$(cat "$CURL_LOG")" "openai"    "hard rule: no OpenAI endpoint was contacted"
if grep -v 'ntfy' "$CURL_LOG" | grep -q 'http'; then
  bad "hard rule: curl reached a host other than ntfy"
else
  ok "hard rule: curl only ever reached ntfy"
fi
file_has "$NPX_LOG" "ccusage@latest blocks --json --offline" \
  "hard rule: ccusage is asked for local blocks, offline"
if grep -v -- '--offline' "$NPX_LOG" | grep -q '[^[:space:]]'; then
  bad "hard rule: a ccusage read dropped offline mode"
else
  ok "hard rule: every ccusage invocation stays offline"
fi
if grep -v 'ccusage' "$NPX_LOG" | grep -q '[^[:space:]]'; then
  bad "hard rule: npx was used for something other than ccusage"
else
  ok "hard rule: npx is only ever used for ccusage"
fi
if grep -v "CLAUDE_CONFIG_DIR=$STATION/claude" "$NPX_LOG" | grep -q '[^[:space:]]'; then
  bad "hard rule: capacity was read for a config dir other than the launching identity's"
else
  ok "hard rule: capacity is only ever read for the launching identity"
fi

# ---------------------------------------------------------------------------
echo "== the preflight is wired before the expensive steps =="
# ---------------------------------------------------------------------------
RT="$SRC/run-task.sh"
pre_line=$(grep -nx 'capacity_preflight' "$RT" | cut -d: -f1)
wt_line=$(grep -n 'stage "setup: worktree"' "$RT" | cut -d: -f1)
inst_line=$(grep -n 'stage "setup: installing deps"' "$RT" | cut -d: -f1)
if [ -n "$pre_line" ] && [ -n "$wt_line" ] && [ -n "$inst_line" ] \
   && [ "$pre_line" -lt "$wt_line" ] && [ "$pre_line" -lt "$inst_line" ]; then
  ok "wiring: capacity_preflight runs before the worktree and the deps install"
else
  bad "wiring: capacity_preflight must precede worktree/install (pre=[$pre_line] wt=[$wt_line] install=[$inst_line])"
fi

echo
printf 'capacity preflight: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
