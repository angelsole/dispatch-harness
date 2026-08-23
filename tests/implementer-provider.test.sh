#!/usr/bin/env bash
# The implementer-provider contract: which vendor the implementer bills to is a
# knob pinned per run, its environment reaches the implementer and nothing else,
# the credential never lands anywhere a reader could find it, the Claude-window
# preflight steps aside for a provider it cannot account for, and z.ai's own
# failure vocabulary is classified — deferring a spent balance, failing fast on
# the configuration error that wears the same error code.
#
# Nothing real is contacted. `claude` (every model stage) and `npx` (ccusage)
# are fake binaries on PATH that record what they were asked to do — including
# the environment they were handed — and schedule.sh is a stand-in beside the
# run-task.sh under test, the technique tests/capacity-preflight.test.sh uses.
# Every run is a real run-task.sh invocation against a fabricated repo with a
# local bare remote.
#
# Usage: bash tests/implementer-provider.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/implementer-provider-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
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
ENVLOG="$ROOT/claude-env.log"
NPX_CALLS="$ROOT/npx-calls.log"
CCUSAGE_JSON="$ROOT/ccusage.json"
CLAUDE_MODE="$ROOT/claude-mode"
ATTEMPTS="$ROOT/attempts"

# The credential under test. A marker no other fixture uses, so a single grep
# over the run dir is a complete answer to "did it leak".
ZAI_KEY='zai-not-a-real-key-0123456789'
ZAI_URL='https://api.z.ai/api/anthropic'

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude" "$HARNESS/lib"
: > "$SCHED_CALLS"; : > "$CLAUDE_CALLS"; : > "$ENVLOG"; : > "$NPX_CALLS"
printf 'commit\n' > "$CLAUDE_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp -R "$SRC/lib" "$SRCDIR/lib"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp "$SRC/lib/common.sh" "$HARNESS/lib/common.sh"
( umask 077; printf '%s\n' "$ZAI_KEY" > "$HARNESS/zai-api-key" )

# A failing gate parks every dispatching run at gate_failed, which keeps the
# suite short of gh and a network while still exercising every model stage.
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

# ccusage stand-in, with a call log: the preflight skip is only proved by the
# accountant never being asked.
cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$NPX_CALLS"
cat "$CCUSAGE_JSON"
EOF

# Every model stage runs through this one binary, so it starts by working out
# which stage it is from the prompt it was handed, and records the environment
# that stage was spawned with. The env record lives OUTSIDE the run dir on
# purpose: it is where the token is allowed to be seen, and it is what makes
# "the run dir holds no copy of it" a meaningful assertion.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then prompt="\$a"; break; fi
  prev="\$a"
done
role=implementer
case "\$prompt" in
  *"You are the reviewer stage"*)                      role=reviewer ;;
  *"The test gate is still failing after your review"*) role=fix ;;
esac
model=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "--model" ]; then model="\$a"; break; fi
  prev="\$a"
done
printf 'role=%s model=[%s] base=[%s] token=[%s] timeout=[%s] haiku=[%s] subagent=[%s] compact=[%s] apikey=[%s]\n' \\
  "\$role" "\$model" "\${ANTHROPIC_BASE_URL:-}" "\${ANTHROPIC_AUTH_TOKEN:-}" \\
  "\${API_TIMEOUT_MS:-}" "\${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" \\
  "\${CLAUDE_CODE_SUBAGENT_MODEL:-}" "\${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" \\
  "\${ANTHROPIC_API_KEY:-}" >> "$ENVLOG"

# sync-pr's conflict resolver: conclude the merge the harness stopped.
case "\$prompt" in
  *"stopped on conflicts"*)
    git add -A >/dev/null 2>&1
    git commit -q --no-edit >/dev/null 2>&1
    echo "conflicts resolved"
    exit 0 ;;
esac

if [ "\$role" != implementer ]; then
  # The Claude review tier and the fix round that follows it. Leaving notes is
  # what buys the fix round, so one fake covers both invocations.
  mkdir -p .harness
  printf 'reviewed\n' > .harness/review-notes.md
  echo "review done"
  exit 0
fi

flags=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  if [ "\$a" = "-p" ]; then skip=1; continue; fi
  flags="\$flags \$a"
done
printf 'argv:%s\n' "\$flags" >> "$CLAUDE_CALLS"
printf 'prompt:%s\n---\n' "\$prompt" >> "$CLAUDE_CALLS"
n=\$(cat "$ATTEMPTS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$ATTEMPTS"

streamed() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"segment-%s"}]}}\n' "\$n"; }
finished() { printf '{"type":"result","subtype":"success","result":"segment %s finished","session_id":"fork-%s","num_turns":1}\n' "\$n" "\$n"; }
exhausted(){ printf '{"type":"result","subtype":"error_max_turns","result":"segment %s ran out","session_id":"fork-%s","num_turns":1}\n' "\$n" "\$n"; }
died()     { printf '{"type":"result","subtype":"error_during_execution","result":"%s","session_id":"fork-%s"}\n' "\$1" "\$n"; }
commit_it(){ date >> fixture.txt; git add fixture.txt >/dev/null; git commit -q -m "feat: fixture change" >/dev/null; }
# The stream stays valid stream-json whatever the endpoint said, so the harness
# reads this failure the way it reads a real one: the raw error on stderr, the
# CLI's own summary of it in the result event.
BALANCE_ERR='API Error 400: {"error":{"code":1113,"message":"Insufficient Balance"}}'
BALANCE_MSG='API Error 400 (code 1113): Insufficient Balance'
QUOTA_ERR='API Error 429: quota exhausted for this window, retry after it resets'

case "\$(cat "$CLAUDE_MODE")" in
  commit)
    streamed; commit_it; finished
    ;;
  turns-once)
    if [ "\$n" -ge 2 ]; then streamed; commit_it; finished
    else streamed; exhausted; exit 1; fi
    ;;
  balance-first)
    # Rejected before a single token came back: the shape a wrong base path (or
    # a plan that was never funded) produces on every request.
    echo "\$BALANCE_ERR" >&2
    died "\$BALANCE_MSG"
    exit 1
    ;;
  balance-midrun)
    streamed
    echo "\$BALANCE_ERR" >&2
    died "\$BALANCE_MSG"
    exit 1
    ;;
  quota-midrun)
    streamed
    echo "\$QUOTA_ERR" >&2
    died "\$QUOTA_ERR"
    exit 1
    ;;
esac
EOF

chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/claude"

iso_utc() { perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime($ARGV[0]))' -- "$1"; }
RESET_EPOCH=$(( $(date +%s) + 900 ))
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
  : > "$CLAUDE_CALLS"; : > "$ENVLOG"; : > "$NPX_CALLS"; echo 0 > "$ATTEMPTS"
  # Globbing off: a model id like glm-5.3[1m] is a bracket expression to the
  # word splitting below, and must reach the harness the way an operator typed it.
  set -f
  # shellcheck disable=SC2086
  env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" HARNESS_NOTIFY=0 \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  set +f
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
stage_now()     { cut -d' ' -f2- < "$RUN/status" 2>/dev/null; }
result()        { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
pin()           { cat "$RUN/$1" 2>/dev/null; }
env_of()        { grep "^role=$1" "$ENVLOG" | sed -n "${2:-1}p"; }
spawns_of()     { grep -c "^role=$1" "$ENVLOG" 2>/dev/null | tr -d ' '; }
npx_calls()     { grep -c '^argv:' "$NPX_CALLS" 2>/dev/null | tr -d ' '; }
arm_calls()     { grep -c '^argv:' "$SCHED_CALLS" 2>/dev/null | tr -d ' '; }

# ---------------------------------------------------------------------------
echo "== the provider is a knob, pinned per run =="
# ---------------------------------------------------------------------------
dispatch PROV-DEFAULT commit ""
check "knob: the default provider is anthropic" "$(pin implementer-provider)" "anthropic"
check "knob: and it reaches result.json" "$(result .implementer_provider)" "anthropic"
check "knob: the default model is unchanged by the new knob" \
  "$(pin implementer-model)" "claude-opus-5"

dispatch PROV-ZAI commit "IMPLEMENTER_PROVIDER=zai"
check "knob: an explicit provider is pinned into the run dir" "$(pin implementer-provider)" "zai"
check "knob: and recorded in result.json" "$(result .implementer_provider)" "zai"
check "knob: with no model pinned, zai brings its own default" \
  "$(pin implementer-model)" "glm-5.3"
has "$(env_of implementer)" "model=[glm-5.3]" "knob: which is what the CLI is spawned with"

dispatch PROV-ZAI commit "IMPLEMENTER_PROVIDER=anthropic"
check "knob: a re-dispatch reuses the pinned provider" "$(pin implementer-provider)" "zai"
check "knob: and the model that came with it" "$(pin implementer-model)" "glm-5.3"
has "$(env_of implementer)" "base=[$ZAI_URL]" \
  "knob: the resuming shell's provider is ignored, env and all"

dispatch PROV-MODEL commit "IMPLEMENTER_PROVIDER=zai IMPLEMENTER_MODEL=glm-5.3[1m]"
check "knob: an explicit model outranks the provider's default" \
  "$(pin implementer-model)" "glm-5.3[1m]"
has "$(env_of implementer)" "compact=[1000000]" \
  "knob: and the 1M variant is given a compaction window that matches it"
dispatch PROV-ZAI commit ""
has "$(env_of implementer)" "compact=[]" \
  "knob: an ordinary glm-5.3 gets no compaction override"

dispatch PROV-BOGUS commit "IMPLEMENTER_PROVIDER=openai"
check "knob: an unknown provider falls back to the default" \
  "$(pin implementer-provider)" "anthropic"
check "knob: the fallback says so exactly once" \
  "$(printf '%s\n' "$OUT" | grep -c "is not a known provider" | tr -d ' ')" "1"
has "$(env_of implementer)" "base=[]" "knob: and injects nothing"
dispatch PROV-BOGUS commit "IMPLEMENTER_PROVIDER=openai"
check "knob: the re-pinned value stops the warning repeating" \
  "$(printf '%s\n' "$OUT" | grep -c "is not a known provider" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== the provider env reaches the implementer and nothing else =="
# ---------------------------------------------------------------------------
dispatch PROV-ENV commit "IMPLEMENTER_PROVIDER=zai"
IMPL="$(env_of implementer)"
has "$IMPL" "base=[$ZAI_URL]"      "env: the implementer is pointed at the z.ai endpoint"
has "$IMPL" "token=[$ZAI_KEY]"     "env: with the credential from the key file"
has "$IMPL" "timeout=[3000000]"    "env: and the long request timeout the plan needs"
has "$IMPL" "haiku=[glm-4.7]"      "env: the CLI's own small model moves with the provider"
has "$IMPL" "subagent=[glm-4.7]"   "env: and so do the worker's subagents"
has "$IMPL" "apikey=[]"            "env: ANTHROPIC_API_KEY is still unset, as on every arm"

check "env: the review tier ran" "$(spawns_of reviewer)" "1"
check "env: and so did a fix round" "$(spawns_of fix)" "1"
for role in reviewer fix; do
  E="$(env_of "$role")"
  has "$E" "base=[]"          "env: the $role stage is not pointed at z.ai"
  has "$E" "token=[]"         "env: the $role stage never sees the credential"
  has "$E" "timeout=[]"       "env: the $role stage keeps the CLI's own timeout"
  has "$E" "haiku=[]"         "env: the $role stage keeps the CLI's own small model"
  has "$E" "subagent=[sonnet]" "env: the $role stage keeps its Anthropic subagents"
  has "$E" "model=[claude-opus-5]" \
    "env: the $role stage runs on a Claude model, not the implementer's GLM one"
done
check "env: and result.json names the model that actually reviewed" \
  "$(result .reviewer_model)" "claude-opus-5"

# ---------------------------------------------------------------------------
echo "== the credential never leaves the key file =="
# ---------------------------------------------------------------------------
LEAKS="$(grep -rlF "$ZAI_KEY" "$RUN" 2>/dev/null || true)"
check "leak: no file in the run dir holds the key" "$LEAKS" ""
WT_LEAKS="$(grep -rlF "$ZAI_KEY" "$WT" 2>/dev/null || true)"
check "leak: nor does anything in the worktree" "$WT_LEAKS" ""
has_not "$(cat "$CLAUDE_CALLS")" "$ZAI_KEY" "leak: the key never travels in argv"
file_has "$HARNESS/zai-api-key" "$ZAI_KEY" "leak: it is still only in the key file"
check "leak: which is mode 600" \
  "$(perl -e 'printf "%04o", (stat($ARGV[0]))[2] & 07777' "$HARNESS/zai-api-key")" "0600"

dispatch PROV-NOKEY commit "IMPLEMENTER_PROVIDER=zai ZAI_API_KEY_FILE=$ROOT/no-such-key"
check "key: a missing key file fails the run before it spawns anything" \
  "$(result .status)" "setup_failed"
check "key: nothing was spawned" "$(spawns_of implementer)" "0"
has "$OUT" "$ROOT/no-such-key" "key: and the message names the file it looked for"

# ---------------------------------------------------------------------------
echo "== the Claude-window preflight steps aside for a provider it cannot see =="
# ---------------------------------------------------------------------------
dispatch PROV-CAP commit "IMPLEMENTER_PROVIDER=zai"
file_has "$RUN/capacity.log" "preflight: skipped" "capacity: the skip is written down"
file_has "$RUN/capacity.log" "not the Claude subscription this measures" \
  "capacity: with the reason, not just the fact"
check "capacity: and the accountant was never asked" "$(npx_calls)" "0"

dispatch PROV-CAP-DEFAULT commit ""
check "capacity: the default provider still measures the window" \
  "$([ "$(npx_calls)" -ge 1 ] && echo yes || echo no)" "yes"
file_has "$RUN/capacity.log" "preflight: ok" "capacity: and records its verdict as before"

# ---------------------------------------------------------------------------
echo "== z.ai's own failure vocabulary =="
# ---------------------------------------------------------------------------
# Error 1113 covers two very different things. A run that never got a token out
# cannot tell a spent balance from a base URL typo, and waiting cures only one
# of them — so it fails fast instead of re-arming itself in a circle.
BEFORE_ARMS=$(arm_calls)
dispatch PROV-1113-FIRST balance-first "IMPLEMENTER_PROVIDER=zai"
check "1113: a rejection before any output is a setup failure" \
  "$(result .status)" "setup_failed"
check "1113: the run says so" "$(stage_now)" "done: setup_failed"
check "1113: and arms nothing" "$(arm_calls)" "$BEFORE_ARMS"
has "$OUT" "before it streamed anything" "1113: the message says what happened"
has "$OUT" "$HARNESS/zai-api-key" "1113: and names the credential to check"
has "$OUT" "$ZAI_URL" "1113: and the endpoint it should be pointed at"

# The same code once the endpoint has answered is the balance running out
# mid-run, which is a window to wait for — the deferral every session limit gets.
BEFORE_ARMS=$(arm_calls)
dispatch PROV-1113-MID balance-midrun "IMPLEMENTER_PROVIDER=zai"
check "1113: a rejection after real output defers instead" \
  "$(result .status)" "deferred_capacity"
check "1113: exiting 0 — deferred, not failed" "$RC" "0"
check "1113: having armed exactly one schedule" "$(arm_calls)" "$((BEFORE_ARMS + 1))"
check "1113: counted as a self-resume" "$(result .metrics.self_resumes)" "1"
file_has "$RUN/capacity.log" "ccusage accounts for the Claude window and is not asked" \
  "1113: and the Claude accountant is not consulted about a z.ai window"

# The stream is rotated between invocations, but it is still part of this run's
# history. A first-request 1113 after earlier output is a balance event, not a
# fresh setup failure.
BEFORE_ARMS=$(arm_calls)
dispatch PROV-1113-MID balance-first ""
check "1113: a resumed first-request rejection still defers after earlier output" \
  "$(result .status)" "deferred_capacity"
check "1113: the resumed rejection exits 0" "$RC" "0"
check "1113: the resumed rejection arms one more schedule" \
  "$(arm_calls)" "$((BEFORE_ARMS + 1))"

BEFORE_ARMS=$(arm_calls)
dispatch PROV-QUOTA quota-midrun "IMPLEMENTER_PROVIDER=zai"
check "quota: an exhausted quota defers too" "$(result .status)" "deferred_capacity"
check "quota: one schedule armed" "$(arm_calls)" "$((BEFORE_ARMS + 1))"

# The vocabulary belongs to the provider. On the default one the very same
# output is an ordinary implementer failure, exactly as it was before this knob.
BEFORE_ARMS=$(arm_calls)
dispatch PROV-1113-ANTHROPIC balance-midrun ""
check "gating: a 1113 on an anthropic run is a plain failure" \
  "$(result .status)" "implementer_failed"
check "gating: and nothing is armed for it" "$(arm_calls)" "$BEFORE_ARMS"

# ---------------------------------------------------------------------------
echo "== every resumed segment is billed to the same provider =="
# ---------------------------------------------------------------------------
dispatch PROV-RESUME turns-once "IMPLEMENTER_PROVIDER=zai"
check "resume: the implementer was spawned twice" "$(spawns_of implementer)" "2"
has "$(env_of implementer 2)" "base=[$ZAI_URL]" \
  "resume: the turn-ceiling resume goes to the same endpoint"
has "$(env_of implementer 2)" "token=[$ZAI_KEY]" "resume: with the same credential"
has "$(env_of implementer 2)" "subagent=[glm-4.7]" "resume: and the same subagent model"

# The deferred run above is resumed by a shell that knows nothing about z.ai:
# the pin on disk is what carries the provider across an invocation boundary.
dispatch PROV-1113-MID commit ""
check "resume: the deferred run is picked up on its pinned provider" \
  "$(pin implementer-provider)" "zai"
has "$(env_of implementer)" "base=[$ZAI_URL]" \
  "resume: and re-injected without the environment naming it"
has "$(env_of implementer)" "token=[$ZAI_KEY]" "resume: credential included"

# ---------------------------------------------------------------------------
echo "== the default provider behaves exactly as it did before =="
# ---------------------------------------------------------------------------
dispatch PROV-BASELINE commit ""
BASE_IMPL="$(env_of implementer)"
has "$BASE_IMPL" "base=[]"     "default: no base URL is injected"
has "$BASE_IMPL" "token=[]"    "default: no auth token is injected"
has "$BASE_IMPL" "timeout=[]"  "default: no request timeout is injected"
has "$BASE_IMPL" "haiku=[]"    "default: no small-model override is injected"
has "$BASE_IMPL" "compact=[]"  "default: no compaction override is injected"
has "$BASE_IMPL" "subagent=[sonnet]" "default: subagents stay on sonnet"
has "$BASE_IMPL" "model=[claude-opus-5]" "default: and the implementer on Opus"
has "$(env_of reviewer)" "model=[claude-opus-5]" \
  "default: the Claude review tier still mirrors the implementer's model"

# ---------------------------------------------------------------------------
echo "== attaching never opens a z.ai session against Anthropic =="
# ---------------------------------------------------------------------------
BEFORE_SPAWNS=$(grep -c '^role=implementer' "$ENVLOG" 2>/dev/null | tr -d ' ')
ATTACH_OUT=$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
  HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" bash "$SRC/attach.sh" PROV-ENV 2>&1)
ATTACH_RC=$?
check "attach: missing provider env stops before resume" "$ATTACH_RC" "2"
check "attach: no session was spawned against the wrong endpoint" \
  "$(grep -c '^role=implementer' "$ENVLOG" 2>/dev/null | tr -d ' ')" "$BEFORE_SPAWNS"
has "$ATTACH_OUT" 'ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic' \
  "attach: the hint includes the endpoint"
has "$ATTACH_OUT" 'ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7' \
  "attach: the hint includes the CLI small model"
has "$ATTACH_OUT" 'CLAUDE_CODE_SUBAGENT_MODEL=glm-4.7' \
  "attach: the hint includes the subagent model"
has "$ATTACH_OUT" "$HARNESS/zai-api-key" "attach: the hint names the key file"
has_not "$ATTACH_OUT" "$ZAI_KEY" "attach: the hint never prints the credential"
ATTACH_1M_OUT=$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
  HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" bash "$SRC/attach.sh" PROV-MODEL 2>&1)
has "$ATTACH_1M_OUT" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000' \
  "attach: the 1M model hint includes its compaction window"

printf 'commit\n' > "$CLAUDE_MODE"
env HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
  ANTHROPIC_BASE_URL="$ZAI_URL" ANTHROPIC_AUTH_TOKEN="$ZAI_KEY" \
  API_TIMEOUT_MS=3000000 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 \
  CLAUDE_CODE_SUBAGENT_MODEL=glm-4.7 \
  bash "$SRC/attach.sh" PROV-ENV >/dev/null 2>&1
check "attach: a correctly configured shell resumes the session" \
  "$(grep -c '^role=implementer' "$ENVLOG" 2>/dev/null | tr -d ' ')" "$((BEFORE_SPAWNS + 1))"

env HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
  ANTHROPIC_BASE_URL="$ZAI_URL" ANTHROPIC_AUTH_TOKEN="$ZAI_KEY" \
  API_TIMEOUT_MS=3000000 ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7 \
  CLAUDE_CODE_SUBAGENT_MODEL=glm-4.7 CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 \
  bash "$SRC/attach.sh" PROV-BASELINE >/dev/null 2>&1
ANTHROPIC_ATTACH="$(env_of implementer 3)"
has "$ANTHROPIC_ATTACH" "base=[]" \
  "attach: an anthropic pin removes an ambient zai endpoint"
has "$ANTHROPIC_ATTACH" "token=[]" \
  "attach: an anthropic pin removes the ambient zai credential"
has "$ANTHROPIC_ATTACH" "timeout=[]" \
  "attach: an anthropic pin removes the ambient zai timeout"
has "$ANTHROPIC_ATTACH" "haiku=[]" \
  "attach: an anthropic pin removes the ambient zai small model"
has "$ANTHROPIC_ATTACH" "subagent=[]" \
  "attach: an anthropic pin removes the ambient zai subagent model"
has "$ANTHROPIC_ATTACH" "compact=[]" \
  "attach: an anthropic pin removes the ambient zai compaction window"

# ---------------------------------------------------------------------------
echo "== the repo decides its implementer provider, not the machine =="
# ---------------------------------------------------------------------------
# A station may carry an ambient provider default (an exported IMPLEMENTER_
# PROVIDER in the login shell). The repo's repos.local.sh arm outranks it, so a
# repo whose code is not approved for third-party providers pins anthropic and
# no exported machine default can route its dispatches elsewhere.
repo_pin() {  # $1 = provider to pin for greenapp, "" for none
  cat > "$HARNESS/repos.local.sh" <<EOF
repo_config_local() {
  case "\$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='exit 1'${1:+ IMPLEMENTER_PROVIDER='$1'} ;;
  esac
}
EOF
}

repo_pin anthropic
dispatch PROV-REPO-ANTHROPIC commit "IMPLEMENTER_PROVIDER=zai IMPLEMENTER_MODEL=glm-5.3"
check "repo pin: anthropic outranks the ambient zai" "$(pin implementer-provider)" "anthropic"
check "repo pin: result.json records it" "$(result .implementer_provider)" "anthropic"
check "repo pin: the model keeps its own repo-ambient-default precedence" \
  "$(pin implementer-model)" "glm-5.3"
IMPL="$(env_of implementer)"
has "$IMPL" "base=[]"              "repo pin: no zai endpoint reaches the implementer"
has "$IMPL" "token=[]"             "repo pin: nor the credential"
has "$IMPL" "subagent=[sonnet]"    "repo pin: subagents stay on the provider's own"
has "$IMPL" "model=[glm-5.3]" "repo pin: the ambient model reaches the implementer"
check "repo pin: nothing to escalate to, so escalation is off" "$(pin escalation)" "off"
check "repo pin: the Claude window is measured again" \
  "$([ "$(npx_calls)" -ge 1 ] && echo yes || echo no)" "yes"

dispatch PROV-REPO-ANTHROPIC commit "IMPLEMENTER_PROVIDER=zai"
check "repo pin: a resume keeps the run-dir pin whatever the ambient says" \
  "$(pin implementer-provider)" "anthropic"

repo_pin zai
dispatch PROV-REPO-ZAI commit ""
check "repo pin: zai with no ambient default" "$(pin implementer-provider)" "zai"
check "repo pin: the provider's own model default applies" "$(pin implementer-model)" "glm-5.3"
has "$(env_of implementer)" "base=[$ZAI_URL]" "repo pin: the endpoint comes from the pin alone"
has "$(env_of implementer)" "token=[$ZAI_KEY]" "repo pin: with the key file's credential"

dispatch PROV-REPO-ZAI commit "ZAI_API_KEY_FILE=$ROOT/no-such-key"
check "repo pin: the key-file requirement is intact" "$(result .status)" "setup_failed"
check "repo pin: nothing was spawned" "$(spawns_of implementer)" "0"

dispatch PROV-REPO-ZAI2 commit "IMPLEMENTER_PROVIDER=anthropic IMPLEMENTER_MODEL=glm-5.3[1m]"
check "repo pin: a zai pin outranks an ambient anthropic" \
  "$(pin implementer-provider)" "zai"
check "repo pin: changing only the provider retains the ambient model" \
  "$(pin implementer-model)" "glm-5.3[1m]"
has "$(env_of implementer)" "compact=[1000000]" \
  "repo pin: the retained ambient 1M model keeps its compaction window"

repo_pin ""

# ---------------------------------------------------------------------------
echo "== a synced run keeps the provider its dispatch pinned =="
# ---------------------------------------------------------------------------
# sync-pr re-runs the Claude tier of an existing run, so the run-dir pin is the
# authority there — including for a run whose repo was pinned anthropic only
# after it shipped on zai: the sync neither re-decides the provider nor lets
# the zai model id reach its Anthropic-billed fallback.
SYNC="PROV-SYNC"
git -C "$REPO" checkout -q -b "fix/$SYNC" main
printf 'branch side\n' > "$REPO/f.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "feat: branch side"
git -C "$REPO" push -q -u origin "fix/$SYNC"
git -C "$REPO" checkout -q main
printf 'base side\n' > "$REPO/f.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "feat: base side"
git -C "$REPO" push -q origin main
git -C "$REPO" branch -q -D "fix/$SYNC"

RUN="$RUNS/$SYNC"; WT="$ROOT/greenapp-prov-sync"
mkdir -p "$RUN"
printf '# fixture task\n' > "$RUN/brief.md"
printf 'zai\n' > "$RUN/implementer-provider"
printf 'glm-5.3\n' > "$RUN/implementer-model"
jq -n --arg wt "$WT" --arg b "fix/$SYNC" \
  '{ticket:"PROV-SYNC",status:"ready",worktree:$wt,branch:$b,base:"main"}' > "$RUN/result.json"
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='true' IMPLEMENTER_PROVIDER='anthropic' ;;
  esac
}
EOF
: > "$ENVLOG"
env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
    HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
    CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" HARNESS_NOTIFY=0 \
    bash "$SRC/sync-pr.sh" "$SYNC" > "$ROOT/sync.log" 2>&1
SYNC_RC=$?
check "sync: the conflicted sync completes" "$SYNC_RC" "0"
check "sync: the run-dir provider pin is untouched" "$(pin implementer-provider)" "zai"
check "sync: and so is the model pin" "$(pin implementer-model)" "glm-5.3"
SYNC_IMPL="$(env_of implementer)"
has "$SYNC_IMPL" "model=[claude-opus-5]" \
  "sync: the Anthropic-billed resolver runs the Anthropic model"
has_not "$SYNC_IMPL" "glm-5.3" "sync: the zai model id never reaches it"
has_not "$SYNC_IMPL" "base=[$ZAI_URL]" "sync: nor the zai endpoint"

# Runs from before knob files were introduced fall back through the same
# repo/ambient/default layers. In particular, repo_config clearing its output
# fields must not erase the shell values sync-pr inherited.
SYNC="PROV-SYNC-LEGACY"
git -C "$REPO" checkout -q -b "fix/$SYNC" main
printf 'legacy branch side\n' > "$REPO/legacy.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "feat: legacy branch side"
git -C "$REPO" push -q -u origin "fix/$SYNC"
git -C "$REPO" checkout -q main
printf 'legacy base side\n' > "$REPO/legacy.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "feat: legacy base side"
git -C "$REPO" push -q origin main
git -C "$REPO" branch -q -D "fix/$SYNC"

RUN="$RUNS/$SYNC"; WT="$ROOT/greenapp-prov-sync-legacy"
mkdir -p "$RUN"
printf '# fixture task\n' > "$RUN/brief.md"
jq -n --arg wt "$WT" --arg b "fix/$SYNC" \
  '{ticket:"PROV-SYNC-LEGACY",status:"ready",worktree:$wt,branch:$b,base:"main"}' > "$RUN/result.json"
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='true' ;;
  esac
}
EOF
: > "$ENVLOG"
env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
    IMPLEMENTER_PROVIDER=anthropic IMPLEMENTER_MODEL=claude-sonnet-4-5 \
    HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
    CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" HARNESS_NOTIFY=0 \
    bash "$SRC/sync-pr.sh" "$SYNC" > "$ROOT/sync-legacy.log" 2>&1
SYNC_RC=$?
check "sync legacy: the conflicted sync completes" "$SYNC_RC" "0"
has "$(env_of implementer)" "model=[claude-sonnet-4-5]" \
  "sync legacy: an ambient model survives repo_config"

# ---------------------------------------------------------------------------
echo "== the injection has exactly one home =="
# ---------------------------------------------------------------------------
# Every segment of every attempt goes through opus_attempt, so the provider env
# is applied there and only there. A second call site is how a resume path
# quietly reverts to the wrong vendor.
#
# apply_provider_env reaches that subshell through the implementer_env hook now,
# which puts the invariant in two halves: the function is defined once and
# registered once (never called by hand from a second place), and the hook that
# fires it is fired exactly once, inside opus_attempt's subshell. A profile that
# registers itself on the same hook adds an export to that one spawn; it cannot
# add a second place where the provider is chosen.
RT="$SRC/run-task.sh"
check "wiring: apply_provider_env is defined once and registered once" \
  "$(grep -c 'apply_provider_env' "$RT" | tr -d ' ')" "2"
check "wiring: and reaches the implementer through the hook, not a hand-written call" \
  "$(grep -c 'hook_register implementer_env  *apply_provider_env' "$RT" | tr -d ' ')" "1"
check "wiring: the implementer_env hook is fired exactly once" \
  "$(grep -c 'hook_run implementer_env' "$RT" | tr -d ' ')" "1"
call_line=$(grep -n 'hook_run implementer_env' "$RT" | cut -d: -f1)
open_line=$(grep -n '^opus_attempt() {' "$RT" | cut -d: -f1)
exit_line=$(grep -n '^  OPUS_EXIT=' "$RT" | cut -d: -f1)
if [ -n "$call_line" ] && [ -n "$open_line" ] && [ -n "$exit_line" ] \
   && [ "$call_line" -gt "$open_line" ] && [ "$call_line" -lt "$exit_line" ]; then
  ok "wiring: and that firing sits inside opus_attempt's subshell"
else
  bad "wiring: call=[$call_line] opus_attempt=[$open_line] exit=[$exit_line]"
fi

echo
printf 'implementer provider: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
