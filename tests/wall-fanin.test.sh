#!/usr/bin/env bash
# The wall fan-in contract, from the harness's side: with HARNESS_WALL_URL unset
# a dispatch sends nothing and sets nothing, and with it set exactly three things
# change — every stage handoff is POSTed, the implementer and the Claude-tier
# reviewer are handed the reporting environment, and nothing else in the pipeline
# is. The gate and the codex spawn are the two that must stay clean: one runs the
# repo's own commands, the other is a second vendor.
#
# Nothing real is contacted. `claude`, `codex`, `gh`, `npx` (ccusage) and `curl`
# are fake binaries on PATH that record what they were asked and the environment
# they were handed — the technique tests/implementer-provider.test.sh uses. Every
# run is a real run-task.sh invocation against a fabricated repo with a local
# bare remote.
#
# Usage: bash tests/wall-fanin.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wall-fanin-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 exists)"; else ok "$1"; fi; }

WALL_URL="http://wall.invalid:4711"
WALL_TOKEN="fanin-shared-secret-0123456789"

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
STATION="$ROOT/station"
INGEST_LOG="$ROOT/ingest.log"        # one "<url>\t<body>" line per ingest POST
CURL_ARGV="$ROOT/curl-argv.log"      # every curl invocation, headers included
OTHER_CURL="$ROOT/other-curl.log"    # anything the harness curls that is not ingest
CURL_MODE="$ROOT/curl-mode"          # the exit status the fake curl answers with
GATE_ENV="$ROOT/gate-env.txt"
CCUSAGE_JSON="$ROOT/ccusage.json"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude"
: > "$INGEST_LOG"; : > "$CURL_ARGV"; : > "$OTHER_CURL"; printf '0\n' > "$CURL_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"

# The gate is the step that must never inherit the reporting environment: it
# runs the repo's own commands, on the repo's own machine. It records what it
# was given and passes, so every run here reaches the PR.
cat > "$HARNESS/repos.local.sh" <<EOF
repo_config_local() {
  case "\$2" in
    greenapp|greenapp-*) INSTALL_CMD='true'; GATE_CMD='env > $GATE_ENV' ;;
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
# curl: the ingest routes are told apart from everything else by URL, and the
# body is kept whole so the report's shape can be asserted key by key. The exit
# status comes from a mode file, because the reports are sent from a background
# subshell whose environment this suite cannot reach.
cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$CURL_ARGV"
url=""; body=""; prev=""
for a in "\$@"; do
  case "\$a" in http*://*) url="\$a" ;; esac
  [ "\$prev" = "-d" ] && body="\$a"
  prev="\$a"
done
case "\$url" in
  */api/ingest/*) printf '%s\t%s\n' "\$url" "\$body" >> "$INGEST_LOG" ;;
  *)              printf '%s\n' "\$*" >> "$OTHER_CURL" ;;
esac
exit "\$(cat "$CURL_MODE")"
EOF

# Every model stage runs through this one binary. It works out which stage it is
# from the prompt and dumps the reporting environment it was handed into a file
# named after that stage — outside the run dir, so "the run dir holds no copy of
# the token" stays a meaningful question.
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
  *"The test gate is still failing after your review"*)  role=fix ;;
esac
env | grep -E '^(OTEL_|HARNESS_|CLAUDE_CODE_ENABLE_TELEMETRY)' | sort \
  > "$ROOT/env-\$role.txt"

if [ "\$role" != implementer ]; then
  mkdir -p .harness
  printf 'reviewed\n' > .harness/review-notes.md
  echo "review done"
  exit 0
fi
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n'
date > fixture.txt
git add fixture.txt >/dev/null
git commit -q -m "feat: fixture change" >/dev/null
printf '{"type":"result","subtype":"success","result":"done","session_id":"sess-1","num_turns":1}\n'
EOF

# codex: the other vendor. Same job, same question asked of its environment.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
env | grep -E '^(OTEL_|HARNESS_|CLAUDE_CODE_ENABLE_TELEMETRY)' | sort \
  > "$ROOT/env-codex.txt"
wt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-C" ] && wt="\$a"; prev="\$a"; done
mkdir -p "\$wt/.harness"
echo "codex: sound" > "\$wt/.harness/review-notes.md"
EOF

cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr create"*) echo "https://github.example/greenapp/pull/7" ;;
  *"pr view"*)   exit 1 ;;
esac
EOF

cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
cat "$CCUSAGE_JSON"
EOF
cat > "$CCUSAGE_JSON" <<'EOF'
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"tokenCounts":{"outputTokens":10000}}
]}
EOF

chmod +x "$FAKES/curl" "$FAKES/claude" "$FAKES/codex" "$FAKES/gh" "$FAKES/npx"

# --- the harness under test ---------------------------------------------------
# $1 = run id, $2 = notify.conf body, rest = VAR=VAL overrides.
RUN=""; OUT=""
dispatch() {
  local ticket="$1" conf="$2"; shift 2
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  printf '%s\n' "$conf" > "$HARNESS/notify.conf"
  : > "$INGEST_LOG"; : > "$CURL_ARGV"; : > "$OTHER_CURL"
  rm -f "$ROOT"/env-*.txt "$GATE_ENV"
  env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      -u HARNESS_WALL_URL -u HARNESS_WALL_TOKEN -u HARNESS_RUN_ID \
      -u OTEL_EXPORTER_OTLP_ENDPOINT -u CLAUDE_CODE_ENABLE_TELEMETRY \
      -u ANTHROPIC_API_KEY -u HARNESS_MAX_TURNS -u HARNESS_REDISPATCH \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CLAUDE_CONFIG_DIR="$STATION/claude" \
      HARNESS_NOTIFY=0 HARNESS_TICKET_SYNC=0 HARNESS_OWNER=tester \
      "$@" \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  OUT=$(cat "$ROOT/run-$ticket.log")
  # The reports are sent in the background; give the last one a moment to land
  # rather than racing the assertions against it.
  local want i=0
  want=$(awk '$2 != "__invocation__"' "$RUN/stages.log" 2>/dev/null | grep -c '' | tr -d ' ')
  while [ "$i" -lt 60 ] \
        && [ "$(grep -c '' "$INGEST_LOG" | tr -d ' ')" -lt "$want" ]; do
    sleep 0.05; i=$((i + 1))
  done
}

result()      { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
stage_posts() { grep -c '/api/ingest/stage' "$INGEST_LOG" 2>/dev/null | tr -d ' '; }
stage_bodies(){ cut -f 2- "$INGEST_LOG"; }
env_of()      { cat "$ROOT/env-$1.txt" 2>/dev/null; }
# Every stage() call, minus the invocation markers stage() does not write.
stages_written() {
  awk '$2 != "__invocation__"' "$RUN/stages.log" 2>/dev/null | grep -c '' | tr -d ' '
}

CONF_OFF='HARNESS_NTFY_TOPIC=""'
CONF_ON="HARNESS_NTFY_TOPIC=\"\"
HARNESS_WALL_URL=\"$WALL_URL\"
HARNESS_WALL_TOKEN=\"$WALL_TOKEN\""

# ---------------------------------------------------------------------------
echo "== the knob is unset: nothing is sent and nothing is set =="
# ---------------------------------------------------------------------------
dispatch WALL-OFF "$CONF_OFF"
check "off: the run still ships" "$(result .status)" "ready"
check "off: no ingest POST was made" "$(stage_posts)" "0"
has_not "$(cat "$CURL_ARGV")" "/api/ingest/" "off: nor any other ingest call"
absent "off: no wall-report.log is created" "$RUN/wall-report.log"
IMPL_OFF="$(env_of implementer)"
has_not "$IMPL_OFF" "OTEL_"      "off: the implementer gets no OTel exporter"
has_not "$IMPL_OFF" "HARNESS_WALL_" "off: nor the wall's URL or token"
has_not "$IMPL_OFF" "HARNESS_RUN_ID" "off: nor a run id"
has_not "$IMPL_OFF" "CLAUDE_CODE_ENABLE_TELEMETRY" "off: and telemetry stays off"
has_not "$OUT" "HARNESS_WALL_TOKEN" "off: and the startup says nothing about a wall"

# ---------------------------------------------------------------------------
echo "== the knob is set: every stage handoff is reported =="
# ---------------------------------------------------------------------------
dispatch WALL-ON "$CONF_ON"
check "on: the run still ships" "$(result .status)" "ready"
check "on: one POST per stage() call" "$(stage_posts)" "$(stages_written)"
FIRST=$(stage_bodies | head -1)
check "report: exactly the contract's keys" \
  "$(printf '%s' "$FIRST" | jq -r 'keys_unsorted | sort | join(",")')" \
  "at,base,branch,host,model,owner,pr_url,provider,repo,run,stage,status,worktree"
check "report: run is the ticket" "$(printf '%s' "$FIRST" | jq -r .run)" "WALL-ON"
check "report: repo is the repo's own name" "$(printf '%s' "$FIRST" | jq -r .repo)" "greenapp"
check "report: owner is the dispatcher" "$(printf '%s' "$FIRST" | jq -r .owner)" "tester"
check "report: branch is the run's" "$(printf '%s' "$FIRST" | jq -r .branch)" "fix/WALL-ON"
check "report: base is the repo's" "$(printf '%s' "$FIRST" | jq -r .base)" "main"
check "report: host is named" "$(printf '%s' "$FIRST" | jq -r '.host | length > 0')" "true"
check "report: at is an epoch" \
  "$(printf '%s' "$FIRST" | jq -r '.at | (type == "number" and . > 1700000000)')" "true"
# The stage TEXT is a wire format the wall parses; a report that paraphrased it
# would put a different word on the board than on the statusline.
SENT=$(stage_bodies | jq -r .stage | sort)
WROTE=$(awk '$2 != "__invocation__" { $1 = ""; sub(/^ /, ""); print }' "$RUN/stages.log" | sort)
check "report: every stage text is sent verbatim" "$SENT" "$WROTE"
has "$(cat "$CURL_ARGV")" "Authorization: Bearer $WALL_TOKEN" \
  "report: carrying the shared token"
has "$(cat "$CURL_ARGV")" "$WALL_URL/api/ingest/stage" "report: to the stage route"
has "$(cat "$CURL_ARGV")" "-m 3" "report: with a three-second ceiling"
absent "report: a wall that answers takes no log line" "$RUN/wall-report.log"
LEAKS="$(grep -rlF "$WALL_TOKEN" "$RUN" 2>/dev/null || true)"
check "report: the token lands in no file of the run dir" "$LEAKS" ""

# ---------------------------------------------------------------------------
echo "== the worker reports for itself; nothing else does =="
# ---------------------------------------------------------------------------
IMPL="$(env_of implementer)"
has "$IMPL" "HARNESS_RUN_ID=WALL-ON"                "worker: the implementer knows its run id"
has "$IMPL" "HARNESS_WALL_URL=$WALL_URL"            "worker: and where the wall is"
has "$IMPL" "HARNESS_WALL_TOKEN=$WALL_TOKEN"        "worker: and the token to reach it with"
has "$IMPL" "HARNESS_DIR=$HARNESS"                  "worker: and where its hook wrapper lives"
has "$IMPL" "CLAUDE_CODE_ENABLE_TELEMETRY=1"        "worker: telemetry is on"
has "$IMPL" "OTEL_METRICS_EXPORTER=otlp"            "worker: metrics are exported"
has "$IMPL" "OTEL_LOGS_EXPORTER=none"               "worker: logs are not"
has "$IMPL" "OTEL_EXPORTER_OTLP_PROTOCOL=http/json" "worker: over OTLP/HTTP JSON"
has "$IMPL" "OTEL_EXPORTER_OTLP_ENDPOINT=$WALL_URL" "worker: to the same wall"
has "$IMPL" "OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer $WALL_TOKEN" \
  "worker: authenticated the one way the exporter allows"
has "$IMPL" "OTEL_METRIC_EXPORT_INTERVAL=10000"     "worker: flushing every ten seconds"
has "$IMPL" "run.id=WALL-ON"        "worker: the resource attributes name the run"
has "$IMPL" "owner=tester"          "worker: and the dispatcher"
has "$IMPL" "repo=greenapp"         "worker: and the repo"
has "$IMPL" "stage=implement"       "worker: and which worker this is"

GATE="$(grep -E '^(OTEL_|HARNESS_RUN_ID|CLAUDE_CODE_ENABLE_TELEMETRY)' "$GATE_ENV" || true)"
check "gate: the repo's own commands get none of it" "$GATE" ""
CODEX="$(env_of codex)"
has_not "$CODEX" "OTEL_"           "codex: the second vendor exports nothing"
has_not "$CODEX" "HARNESS_RUN_ID"  "codex: and is told no run id"
has_not "$CODEX" "CLAUDE_CODE_ENABLE_TELEMETRY" "codex: and no telemetry switch"

# ---------------------------------------------------------------------------
echo "== the Claude-tier reviewer reports as the reviewer =="
# ---------------------------------------------------------------------------
# No codex CLI: the review runs on a fresh Claude session, and that session is
# the only other worker the harness hands the reporting environment to.
dispatch WALL-REVIEW "$CONF_ON" CODEX_BIN="$ROOT/no-such-codex"
check "review: the run still ships" "$(result .status)" "ready"
REV="$(env_of reviewer)"
has "$REV" "HARNESS_RUN_ID=WALL-REVIEW"  "review: the reviewer knows the run id"
has "$REV" "OTEL_METRICS_EXPORTER=otlp"  "review: and exports its own metrics"
has "$REV" "stage=review"                "review: labelled as the review stage"
has_not "$REV" "stage=implement"         "review: never as the implementer"

# ---------------------------------------------------------------------------
echo "== a wall that refuses never touches the run =="
# ---------------------------------------------------------------------------
# 22 is curl's HTTP-error code under -f (the wall's own 401/404); 7 is a
# connection refused. Both are the operator's problem, not the run's.
for code in 22 7; do
  printf '%s\n' "$code" > "$CURL_MODE"
  dispatch "WALL-FAIL-$code" "$CONF_ON"
  # The log is appended by the same background subshell that sent the report,
  # so it lands a moment after the POST the assertions above already waited for.
  i=0
  while [ "$i" -lt 60 ] \
        && [ "$(grep -c '' "$RUN/wall-report.log" 2>/dev/null | tr -d ' ')" -lt "$(stage_posts)" ]; do
    sleep 0.05; i=$((i + 1))
  done
  check "fail $code: the run is unaffected" "$(result .status)" "ready"
  check "fail $code: one line per refused report" \
    "$(grep -c "stage report failed (curl $code)" "$RUN/wall-report.log" | tr -d ' ')" \
    "$(stage_posts)"
  check "fail $code: and nothing else in it" \
    "$(grep -vc "stage report failed (curl $code)" "$RUN/wall-report.log" | tr -d ' ')" "0"
  LOG="$(cat "$RUN/wall-report.log")"
  has_not "$LOG" "$WALL_TOKEN" "fail $code: the token is never written down"
  has_not "$LOG" "\"run\":"    "fail $code: nor the body that failed"
  has_not "$OUT" "stage report failed" "fail $code: and the dispatch output stays clean"
done
printf '0\n' > "$CURL_MODE"

# ---------------------------------------------------------------------------
echo "== a URL with no token is legal, and says so once =="
# ---------------------------------------------------------------------------
dispatch WALL-NOTOKEN "HARNESS_NTFY_TOPIC=\"\"
HARNESS_WALL_URL=\"$WALL_URL\"" OTEL_EXPORTER_OTLP_HEADERS='Api-Key=vendor-secret'
check "no token: the warning is printed exactly once" \
  "$(printf '%s\n' "$OUT" | grep -c 'HARNESS_WALL_URL is set without HARNESS_WALL_TOKEN' | tr -d ' ')" \
  "1"
check "no token: the run proceeds anyway" "$(result .status)" "ready"
check "no token: and still reports every stage" "$(stage_posts)" "$(stages_written)"
has_not "$(cat "$CURL_ARGV")" "Authorization:" "no token: with no credential attached"
has_not "$(env_of implementer)" "OTEL_EXPORTER_OTLP_HEADERS" \
  "no token: and the exporter is given no header either"
has "$(env_of implementer)" "OTEL_EXPORTER_OTLP_ENDPOINT=$WALL_URL" \
  "no token: but it is still pointed at the wall"

# ---------------------------------------------------------------------------
echo "== the wiring has one home =="
# ---------------------------------------------------------------------------
RT="$SRCDIR/run-task.sh"
check "wiring: apply_wall_env is defined once and registered once" \
  "$(grep -c 'hook_register implementer_env  *apply_wall_env\|^apply_wall_env()' "$RT" | tr -d ' ')" "2"
check "wiring: the reviewer's copy is applied inside its own subshell" \
  "$(grep -c 'apply_wall_env review' "$RT" | tr -d ' ')" "1"
check "wiring: and stage() reports through one function" \
  "$(grep -c '^  wall_report_stage "\$1"' "$RT" | tr -d ' ')" "1"
# A suite that inherited an operator's wall would post its fixtures to a real
# board, so the gate clears both knobs for every suite it runs.
GATE_SH="$(cat "$SRC/gate.sh")"
has "$GATE_SH" "-u HARNESS_WALL_URL -u HARNESS_WALL_TOKEN" \
  "wiring: the gate clears the wall knobs for every suite"

echo
printf 'wall fan-in: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
