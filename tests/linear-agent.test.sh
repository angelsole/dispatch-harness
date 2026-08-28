#!/usr/bin/env bash
# The harness as a Linear agent: a run is a session on its ticket, an
# attachment card summarising it, and — when neither is configured — exactly the
# three calls ticket sync has always made and not one more.
#
# What this suite is for that tests/review-fallback.test.sh cannot be: its fake
# `curl` records the FULL argv in a file of its own, plus the mode and contents
# of every `-H @<file>` and every `-d` body. review-fallback's fake records only
# the body, so a leaked `-u id:secret` or a `Bearer` on argv would pass it
# unseen. Secrets are the point here, so nothing about the invocation is thrown
# away.
#
# Nothing real is contacted. `claude`, `gh`, `npx` (ccusage), `schedule.sh` and
# `curl` are fakes answering from canned files; every run is a real run-task.sh
# invocation against a fabricated repo with a local bare remote.
#
# Usage: bash tests/linear-agent.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/linear-agent-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }
at_least() { if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1"; else bad "$1 (want >= $3 got $2)"; fi; }
at_most()  { if [ "$2" -le "$3" ] 2>/dev/null; then ok "$1"; else bad "$1 (want <= $3 got $2)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
STATION="$ROOT/station"
MODES="$ROOT/modes"
CURL_LOG="$ROOT/curl.log"        # one line per call: url, header files, body
ARGV_LOG="$ROOT/argv.log"        # the full argv of every invocation, nothing else
SCHED_CALLS="$ROOT/schedule.log"
KEYFILE="$ROOT/linear-api-key"
CREDS="$ROOT/linear-agent-credentials"
TOKEN_FILE="$HARNESS/linear-agent-token"
ISSUE_JSON="$ROOT/issue.json"
CCUSAGE_JSON="$ROOT/ccusage.json"
CLAUDE_MODE="$MODES/claude"
GATE_MODE="$MODES/gate"
LINK_BASE="http://mini:4711"
SECRET="sekr3t-CLIENT-SECRET-never-on-argv"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude" "$MODES"
: > "$CURL_LOG"; : > "$ARGV_LOG"; : > "$SCHED_CALLS"
printf 'ok\n' > "$CLAUDE_MODE"
printf 'exit 0\n' > "$GATE_MODE"
printf 'lin_api_PERSONALKEY\n' > "$KEYFILE"; chmod 600 "$KEYFILE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# Every harness script reads lib/ from beside itself, so the shared helpers
# travel with both staged copies — the layout install.sh produces.
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"
cat > "$HARNESS/repos.local.sh" <<EOF
repo_config_local() {
  case "\$2" in
    greenapp|greenapp-*) INSTALL_CMD='true'; GATE_CMD="\$(cat $GATE_MODE)" ;;
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

# --- canned Linear ------------------------------------------------------------
cat > "$ISSUE_JSON" <<'EOF'
{"data":{"issue":{"id":"uuid-77","identifier":"OLYX-77","team":{"states":{"nodes":[{"id":"st-todo","name":"Todo","type":"unstarted"},{"id":"st-errors","name":"errors","type":"unstarted"},{"id":"st-rev","name":"In Review","type":"started"},{"id":"st-done","name":"Done","type":"completed"}]}}}}}
EOF

# --- fakes -------------------------------------------------------------------
# The Linear stand-in. Every call becomes ONE line in CURL_LOG (newlines are
# squashed out of the body) so counting a mutation is counting lines, and the
# argv goes to a file of its own so those counts can never be doubled by it.
cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'ARGV %s\n' "\$*" >> "$ARGV_LOG"
url=""; body=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$a" in http*://*) url="\$a" ;; esac
  case "\$prev" in
    -H) case "\$a" in
          @*) f="\${a#@}"
              hdrs="\$hdrs [\$(ls -l "\$f" 2>/dev/null | cut -c1-10) \$(tr -d '\n' < "\$f" 2>/dev/null)]" ;;
        esac ;;
    -d) body="\$a" ;;
  esac
  prev="\$a"
done
printf 'CALL %s HDR%s BODY %s\n' "\$url" "\$hdrs" "\$(printf '%s' "\$body" | tr -d '\n')" >> "$CURL_LOG"

if [ -s "$MODES/curl-exit" ]; then
  rc=\$(cat "$MODES/curl-exit"); : > "$MODES/curl-exit"; exit "\$rc"
fi

case "\$url" in
  *oauth/token*)
    if [ -s "$MODES/token-fail" ]; then printf '{"error":"invalid_client"}'; exit 0; fi
    n=\$(cat "$MODES/mint-count" 2>/dev/null || echo 0)
    n=\$((n + 1)); printf '%s\n' "\$n" > "$MODES/mint-count"
    life=\$(cat "$MODES/token-life" 2>/dev/null || echo 2592000)
    printf '{"access_token":"app_tok_%s","token_type":"Bearer","expires_in":%s}' "\$n" "\$life"
    exit 0 ;;
  *api.linear.app*) ;;
  *) exit 0 ;;
esac

if [ -s "$MODES/http-401" ]; then
  : > "$MODES/http-401"
  printf '{"errors":[{"message":"Authentication required"}]}\n401'
  exit 0
fi
if [ -s "$MODES/response-http-500" ] && [[ "\$body" = *'"type":"response"'* ]]; then
  printf '{"data":{"agentActivityCreate":{"success":true}}}\n500'
  exit 0
fi
case "\$body" in
  *agentSessionCreateOnIssue*)
    [ ! -s "$MODES/session-delay" ] || sleep 1
    printf '{"data":{"agentSessionCreateOnIssue":{"success":true,"agentSession":{"id":"sess-1","externalLinks":[{"label":"Dispatch run","url":"$LINK_BASE/console#OLYX-77"}]}}}}\n200' ;;
  *agentActivityCreate*)
    if [ -s "$MODES/activity-errors" ]; then
      printf '{"errors":[{"message":"Variable input got invalid value"}]}\n200'
    elif [ -s "$MODES/activity-unsuccessful" ]; then
      printf '{"data":{"agentActivityCreate":{"success":false}}}\n200'
    else
      printf '{"data":{"agentActivityCreate":{"success":true}}}\n200'
    fi ;;
  *agentSessionUpdate*) printf '{"data":{"agentSessionUpdate":{"success":true}}}\n200' ;;
  *attachmentCreate*)   printf '{"data":{"attachmentCreate":{"success":true}}}\n200' ;;
  *commentCreate*)      printf '{"data":{"commentCreate":{"success":true}}}\n200' ;;
  *issueUpdate*)        printf '{"data":{"issueUpdate":{"success":true}}}\n200' ;;
  *)                    printf '%s\n200' "\$(tr -d '\n' < "$ISSUE_JSON")" ;;
esac
EOF

# One fake claude, two jobs, told apart by the prompt. The implementer's mode
# file picks which shape of run this is: a commit, a blocking question, or a
# reviewer that rejects the diff.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
mode=\$(cat "$CLAUDE_MODE")
case "\$prompt" in
  *"reviewer stage"*|*"test gate is still failing"*)
    mkdir -p .harness
    if [ "\$mode" = reject ]; then
      printf 'the diff undoes the feature it was asked for\n' > .harness/REJECTED.md
    else
      echo "claude: sound" > .harness/review-notes.md
    fi
    ;;
  *)
    case "\$mode" in
      questions)
        mkdir -p .harness
        printf 'Should the card carry the branch or the worktree path?\n' > .harness/QUESTIONS.md
        ;;
      longquestions)
        mkdir -p .harness
        head -c 10000 /dev/zero | tr '\0' q > .harness/QUESTIONS.md
        ;;
      slow)
        date > fixture.txt; git add fixture.txt; git commit -q -m "feat: fixture change"
        sleep 4
        ;;
      *)
        date > fixture.txt; git add fixture.txt; git commit -q -m "feat: fixture change"
        ;;
    esac
    ;;
esac
EOF

cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr create"*) echo "https://github.com/olyx/greenapp/pull/9" ;;
  *"pr view"*)   exit 1 ;;
esac
EOF

cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
cat "$CCUSAGE_JSON"
EOF
healthy_capacity() {
  cat > "$CCUSAGE_JSON" <<'EOF'
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"tokenCounts":{"outputTokens":10000}}
]}
EOF
}
healthy_capacity

# The scheduler stand-in, beside run-task.sh where the driver looks for it.
cat > "$SRCDIR/schedule.sh" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$SCHED_CALLS"
mkdir -p "$RUNS/\$1"
date +%s > "$RUNS/\$1/scheduled"
echo "[schedule] \$1 armed for \$4"
EOF

chmod +x "$FAKES/curl" "$FAKES/claude" "$FAKES/gh" "$FAKES/npx" "$SRCDIR/schedule.sh"

# --- the harness under test ---------------------------------------------------
RC=0; RUN=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  # Per-dispatch traffic, so "one call" means one and never a suite-wide tally.
  : > "$CURL_LOG"; : > "$ARGV_LOG"
  # shellcheck disable=SC2086
  env -u HARNESS_CODEX_HOME_FALLBACK -u HARNESS_OWNER \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      -u HARNESS_ESCALATION -u HARNESS_SKIP_REVIEW -u HARNESS_RUN_LINK_BASE \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" \
      LINEAR_API_KEY_FILE="$KEYFILE" \
      LINEAR_AGENT_CREDENTIALS_FILE="$CREDS" \
      HARNESS_REVIEW_NETWORK=0 HARNESS_NOTIFY=0 \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  return 0
}
result_field() { jq -r ".$2 // \"\"" "$RUNS/$1/result.json" 2>/dev/null; }
# One call per line in CURL_LOG, and every mutation name appears once in its own
# body — so counting a mutation is counting the lines that mention it.
calls()      { grep -c -- "$1" "$CURL_LOG" 2>/dev/null | tr -d ' '; }
mint_count() { cat "$MODES/mint-count" 2>/dev/null || echo 0; }
agent_on()   { printf 'client_id=lin_app_ID\nclient_secret=%s\n' "$SECRET" > "$CREDS"; chmod 600 "$CREDS"; }
agent_off()  { rm -f "$CREDS" "$TOKEN_FILE"; }
reset_modes() {
  : > "$MODES/curl-exit"; : > "$MODES/http-401"
  : > "$MODES/activity-errors"; : > "$MODES/activity-unsuccessful"
  : > "$MODES/response-http-500"; : > "$MODES/session-delay"
  : > "$MODES/token-fail"
  rm -f "$MODES/mint-count" "$MODES/token-life"
  printf 'ok\n' > "$CLAUDE_MODE"; printf 'exit 0\n' > "$GATE_MODE"
}
# stages.log is append-only across invocations, segmented by an `__invocation__`
# marker — so both counters below reset at the last one and describe the
# dispatch that just ran, never the run's whole history.
all_stages() {  # $1 = run id — every stage of the last dispatch, terminal included
  awk '$2 == "__invocation__" { c = 0; next } { c++ } END { print c+0 }' "$RUNS/$1/stages.log"
}
# Every stage that is not terminal, not the pause and not a deferral owes the
# session exactly one `action` activity.
action_stages() {  # $1 = run id
  awk '$2 == "__invocation__" { c = 0; next }
       { $1=""; sub(/^ /,"") }
       /^done:/ || /^waiting —/ || /^deferred:/ { next }
       { c++ } END { print c+0 }' "$RUNS/$1/stages.log"
}

reset_modes
agent_off

# ---------------------------------------------------------------------------
echo "== inert by default: exactly today's three calls, and only at ready =="
# ---------------------------------------------------------------------------
dispatch OLYX-101 ""
check "inert: the run ships" "$(result_field OLYX-101 status)" "ready"
check "inert: one issue lookup" "$(calls 'states(first: 50)')" "1"
check "inert: one comment" "$(calls commentCreate)" "1"
check "inert: one state move" "$(calls issueUpdate)" "1"
check "inert: three Linear calls in the whole run" "$(calls 'CALL http')" "3"
check "inert: no attachment card without a wall to link to" "$(calls attachmentCreate)" "0"
check "inert: no session without credentials" "$(calls agentSession)" "0"
check "inert: no activities either" "$(calls agentActivityCreate)" "0"
file_has "$CURL_LOG" 'Draft PR ready for review: https://github.com/olyx/greenapp/pull/9 (`fix/OLYX-101`)' \
  "inert: the comment body is the one main has always sent"
file_has "$CURL_LOG" "st-rev" "inert: and the ticket still moves to In Review"
file_has "$RUNS/OLYX-101/ticket-sync.log" '"name":"errors"' \
  "inert: a workflow state named errors is retained as valid data"
file_has_not "$RUNS/OLYX-101/ticket-sync.log" "LINEAR ERROR issue lookup:" \
  "inert: nested data named errors is not a GraphQL failure"
file_has_not "$RUNS/OLYX-101/ticket-sync.log" "LINEAR ERROR" "inert: nothing failed"
absent "inert: no session file" "$RUNS/OLYX-101/linear-session"

dispatch adhoc-linear-thing ""
check "adhoc: a run with no ticket-shaped id ships" "$(result_field adhoc-linear-thing status)" "ready"
check "adhoc: and says nothing to Linear" "$(calls 'CALL http')" "0"

# The same run id with EVERY layer configured still says nothing: the ident rule
# gates all three, not just the comment.
agent_on
dispatch adhoc-linear-armed "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "adhoc, armed: still ships" "$(result_field adhoc-linear-armed status)" "ready"
check "adhoc, armed: and still makes zero Linear calls" "$(calls 'CALL http')" "0"
check "adhoc, armed: not even a token is minted" "$(mint_count)" "0"
agent_off

dispatch OLYX-102 "HARNESS_TICKET_SYNC=0 HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "knob: HARNESS_TICKET_SYNC=0 ships" "$(result_field OLYX-102 status)" "ready"
check "knob: and turns off all three layers at once" "$(calls 'CALL http')" "0"

# ---------------------------------------------------------------------------
echo "== the app token: minted once, cached, re-minted when it runs short =="
# ---------------------------------------------------------------------------
reset_modes; agent_on
dispatch OLYX-110 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "token: the run still ships" "$(result_field OLYX-110 status)" "ready"
check "token: one mint for the whole run" "$(mint_count)" "1"
file_has "$ARGV_LOG" "oauth/token" "token: the mint went to the token endpoint"
file_has "$CURL_LOG" "Authorization: Basic " "token: authenticated with a Basic header"
if grep -F 'oauth/token' "$CURL_LOG" | grep -qE 'HDR \[-rw-------'; then
  ok "token: the Basic header travelled in a mode-600 file"
else
  bad "token: the mint's Authorization header was not a 600 file"
fi
file_has_not "$ARGV_LOG" "$SECRET" "token: the client secret is never on argv"
file_has_not "$ARGV_LOG" "Basic " "token: and neither is the Basic credential"
file_has_not "$ARGV_LOG" "app_tok" "token: nor is the token itself"
exists "token: the cache is written" "$TOKEN_FILE"
check "token: mode 600" "$(ls -l "$TOKEN_FILE" | cut -c1-10)" "-rw-------"
if jq -e '.access_token and .expires_at' "$TOKEN_FILE" >/dev/null 2>&1; then
  ok "token: the cache carries the token and its expiry"
else
  bad "token: the cache is missing access_token/expires_at"
fi

# A cache with a month left is simply used.
dispatch OLYX-111 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "token: a live cache is reused — no second mint" "$(mint_count)" "1"
file_has "$CURL_LOG" "Authorization: Bearer app_tok_1" "token: the cached token is what travels"

# A cache with hours left is not worth carrying into a run that may outlive it.
jq -n --argjson e "$(( $(date +%s) + 3600 ))" \
  '{access_token:"app_tok_stale",expires_at:$e}' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
dispatch OLYX-112 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "token: under a day left is re-minted" "$(mint_count)" "2"
file_has_not "$CURL_LOG" "app_tok_stale" "token: and the short-lived one is not used"

# A 401 is the documented signal that the app token died early.
printf '1\n' > "$MODES/http-401"
rm -f "$TOKEN_FILE"
dispatch OLYX-113 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "401: one mint for the run plus exactly one re-mint" "$(mint_count)" "4"
check "401: the rejected call is retried once" "$(calls 'states(first: 50)')" "2"
check "401: and the run is untouched by it" "$(result_field OLYX-113 status)" "ready"
check "401: both issue lookup requests are recorded" \
  "$(grep -c '^issue lookup request:' "$RUNS/OLYX-113/ticket-sync.log" | tr -d ' ')" "2"
check "401: both issue lookup responses are recorded" \
  "$(grep -c '^issue lookup response:' "$RUNS/OLYX-113/ticket-sync.log" | tr -d ' ')" "2"
file_has "$RUNS/OLYX-113/ticket-sync.log" \
  'issue lookup response: {"errors":[{"message":"Authentication required"}]}' \
  "401: the raw rejected response is retained"
file_has "$RUNS/OLYX-113/ticket-sync.log" "LINEAR ERROR issue lookup: HTTP 401" \
  "401: the rejected attempt remains an error even though retry succeeds"

# The driver and its heartbeat can decide to mint at the same time. Their Basic
# authorization files must not share a pathname.
reset_modes; agent_on; rm -f "$TOKEN_FILE"
OAUTH_RUN="$RUNS/OLYX-114"; mkdir -p "$OAUTH_RUN"
: > "$CURL_LOG"; : > "$ARGV_LOG"
oauth_worker() {
  ( HARNESS_DIR="$HARNESS" RUN_DIR="$OAUTH_RUN" TICKET="OLYX-114"
    LINEAR_AGENT_CREDENTIALS_FILE="$CREDS" LINEAR_API_KEY_FILE="$KEYFILE"
    export HARNESS_DIR RUN_DIR TICKET LINEAR_AGENT_CREDENTIALS_FILE
    export LINEAR_API_KEY_FILE PATH="$FAKES:$PATH"
    # shellcheck source=../lib/linear.sh
    . "$SRC/lib/linear.sh"
    linear_agent_token force >/dev/null )
}
oauth_worker & OAUTH_ONE=$!
oauth_worker & OAUTH_TWO=$!
wait "$OAUTH_ONE"; wait "$OAUTH_TWO"
OAUTH_HDRS=$(awk '/oauth\/token/ {
  for (i=1; i<=NF; i++) if ($i ~ /^@.*\.linear-oauth-hdr\./) print $i
}' "$ARGV_LOG")
check "OAuth race: both mint calls use a header file" \
  "$(printf '%s\n' "$OAUTH_HDRS" | sed '/^$/d' | wc -l | tr -d ' ')" "2"
check "OAuth race: concurrent mint calls use distinct header files" \
  "$(printf '%s\n' "$OAUTH_HDRS" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" "2"
if compgen -G "$OAUTH_RUN/.linear-oauth-hdr.*" >/dev/null; then
  bad "OAuth race: a temporary authorization header survived"
else
  ok "OAuth race: no temporary authorization header survives"
fi

# ---------------------------------------------------------------------------
echo "== the session: one per run, reused across dispatches =="
# ---------------------------------------------------------------------------
reset_modes; agent_on; rm -f "$TOKEN_FILE"
dispatch OLYX-120 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "session: created exactly once" "$(calls agentSessionCreateOnIssue)" "1"
file_has "$CURL_LOG" 'mutation($input: AgentSessionCreateOnIssue!)' \
  "session: creation uses Linear's declared input type"
file_has_not "$CURL_LOG" 'AgentSessionCreateOnIssueInput' \
  "session: creation does not use the nonexistent Input-suffixed type"
file_has "$RUNS/OLYX-120/linear-session" "sess-1" "session: its id is kept in the run dir"
file_has "$CURL_LOG" '"externalUrls":[{"label":"Dispatch run","url":"http://mini:4711/console#OLYX-120"}]' \
  "session: opened with the run's deep link on the wall"
file_has "$CURL_LOG" '"issueId":"uuid-77"' "session: created against the issue's UUID"
check "session: one action per non-terminal stage" \
  "$(calls '"type":"action"')" "$(action_stages OLYX-120)"
file_has "$CURL_LOG" '"parameter":"OLYX-120 · anthropic/' \
  "session: each action names the run and the provider that owns the stage"
check "session: exactly one issue query for the whole run" "$(calls 'states(first: 50)')" "1"
exists "session: the lookup is cached in the run dir" "$RUNS/OLYX-120/linear-issue.json"

# A re-dispatch continues the same timeline rather than opening a second one.
dispatch OLYX-120 "HARNESS_REDISPATCH=1 HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "session: a second dispatch of the same run creates none" \
  "$(calls agentSessionCreateOnIssue)" "0"
check "session: and re-uses the cached issue — no second lookup" "$(calls 'states(first: 50)')" "0"
check "session: it still reports its stages" "$(calls '"type":"action"')" "$(action_stages OLYX-120)"

# Two dispatch processes can reach the first eligible stage together. The
# session lock makes the second reuse the id created by the first.
reset_modes; agent_on
SESSION_RUN="$RUNS/OLYX-122"; mkdir -p "$SESSION_RUN"
cp "$ISSUE_JSON" "$SESSION_RUN/linear-issue.json"
jq -n --argjson e "$(( $(date +%s) + 2592000 ))" \
  '{access_token:"app_tok_concurrent",expires_at:$e}' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf '1\n' > "$MODES/session-delay"
: > "$CURL_LOG"
session_worker() {
  ( HARNESS_DIR="$HARNESS" RUN_DIR="$SESSION_RUN" TICKET="OLYX-122"
    LINEAR_AGENT_CREDENTIALS_FILE="$CREDS" LINEAR_API_KEY_FILE="$KEYFILE"
    HARNESS_RUN_LINK_BASE="$LINK_BASE"
    export HARNESS_DIR RUN_DIR TICKET LINEAR_AGENT_CREDENTIALS_FILE
    export LINEAR_API_KEY_FILE HARNESS_RUN_LINK_BASE PATH="$FAKES:$PATH"
    # shellcheck source=../lib/linear.sh
    . "$SRC/lib/linear.sh"
    linear_session >/dev/null )
}
session_worker & SESSION_ONE=$!
session_worker & SESSION_TWO=$!
wait "$SESSION_ONE"; wait "$SESSION_TWO"
check "session race: concurrent creators make one session" \
  "$(calls agentSessionCreateOnIssue)" "1"
file_has "$SESSION_RUN/linear-session" "sess-1" \
  "session race: both processes converge on the persisted id"
absent "session race: the owned lock is released" \
  "$SESSION_RUN/.linear-session.lock"

# A process that dies inside the API call cannot run its cleanup. Its recorded
# PID lets the next dispatch distinguish that orphan from a live creator.
reset_modes; agent_on
STALE_SESSION_RUN="$RUNS/OLYX-124"; mkdir -p "$STALE_SESSION_RUN/.linear-session.lock"
cp "$ISSUE_JSON" "$STALE_SESSION_RUN/linear-issue.json"
printf '99999999\n' > "$STALE_SESSION_RUN/.linear-session.lock/owner"
: > "$CURL_LOG"
( HARNESS_DIR="$HARNESS" RUN_DIR="$STALE_SESSION_RUN" TICKET="OLYX-124"
  LINEAR_AGENT_CREDENTIALS_FILE="$CREDS" LINEAR_API_KEY_FILE="$KEYFILE"
  HARNESS_RUN_LINK_BASE="$LINK_BASE"
  export HARNESS_DIR RUN_DIR TICKET LINEAR_AGENT_CREDENTIALS_FILE
  export LINEAR_API_KEY_FILE HARNESS_RUN_LINK_BASE PATH="$FAKES:$PATH"
  # shellcheck source=../lib/linear.sh
  . "$SRC/lib/linear.sh"
  linear_session >/dev/null )
check "stale session lock: the next caller creates the session" \
  "$(calls agentSessionCreateOnIssue)" "1"
file_has "$STALE_SESSION_RUN/linear-session" "sess-1" \
  "stale session lock: the recovered session id is persisted"
absent "stale session lock: the orphaned lock is removed" \
  "$STALE_SESSION_RUN/.linear-session.lock"

# A killed writer can leave an old-style partial cache behind. It is ignored
# and atomically replaced with the next complete lookup response.
reset_modes; agent_on
mkdir -p "$RUNS/OLYX-123"
printf '{"data":' > "$RUNS/OLYX-123/linear-issue.json"
dispatch OLYX-123 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "issue cache: a truncated cache triggers a new lookup" \
  "$(calls 'states(first: 50)')" "1"
if jq -e 'has("data")' "$RUNS/OLYX-123/linear-issue.json" >/dev/null 2>&1; then
  ok "issue cache: the corrupt cache is replaced with a complete response"
else
  bad "issue cache: the replacement cache is still invalid"
fi
if compgen -G "$RUNS/OLYX-123/.linear-issue.*" >/dev/null; then
  bad "issue cache: a temporary cache file survived"
else
  ok "issue cache: no temporary cache file survives"
fi

# Without a wall the session is still opened — it just has nothing to link to.
reset_modes; agent_on
dispatch OLYX-121 ""
check "session: no wall, still one session" "$(calls agentSessionCreateOnIssue)" "1"
file_has_not "$CURL_LOG" "externalUrls" "session: and no external URL invented for it"
check "session: and no card, whose key is that link" "$(calls attachmentCreate)" "0"

# ---------------------------------------------------------------------------
echo "== the heartbeat: a live run keeps its session out of stale =="
# ---------------------------------------------------------------------------
# The interval logic on its own, where nothing races: lib/linear.sh is sourced,
# which is how run-task.sh reads it.
HB_RUN="$RUNS/OLYX-130"; mkdir -p "$HB_RUN"
reset_modes; agent_on; rm -f "$TOKEN_FILE"
: > "$CURL_LOG"
# The assignments below are lib/linear.sh's inputs, which shellcheck reads as
# unused because their only reader is the sourced file.
# shellcheck disable=SC2034
( set -u
  HARNESS_DIR="$HARNESS"; RUN_DIR="$HB_RUN"; TICKET="OLYX-130"
  LINEAR_AGENT_CREDENTIALS_FILE="$CREDS"; LINEAR_API_KEY_FILE="$KEYFILE"
  export PATH="$FAKES:$PATH"
  # shellcheck source=../lib/linear.sh
  . "$SRC/lib/linear.sh"
  printf 'implementing — Opus (Claude sub)\n' > "$RUN_DIR/activity"
  HARNESS_LINEAR_HEARTBEAT_SECS=300
  linear_heartbeat                       # no session yet: must say nothing
  printf 'sess-1\n' > "$RUN_DIR/linear-session"
  linear_heartbeat                       # the first tick starts the interval
  linear_heartbeat                       # ...and the next one is inside the interval
  HARNESS_LINEAR_HEARTBEAT_SECS=1
  sleep 2
  linear_heartbeat )
check "heartbeat: three ticks, one due beat — the interval is honoured" \
  "$(calls '"type":"thought"')" "1"
check "heartbeat: and it is ephemeral" "$(calls '"ephemeral":true')" "1"
file_has "$CURL_LOG" '"body":"implementing — Opus (Claude sub)"' \
  "heartbeat: carrying the run's current activity line"
exists "heartbeat: the last beat's epoch is on disk" "$HB_RUN/linear-heartbeat"
check "heartbeat: no session, no beat — it never opens one" \
  "$(calls agentSessionCreateOnIssue)" "0"

HB_RETRY_RUN="$RUNS/OLYX-134"; mkdir -p "$HB_RETRY_RUN"
reset_modes; agent_on
jq -n --argjson e "$(( $(date +%s) + 2592000 ))" \
  '{access_token:"app_tok_heartbeat",expires_at:$e}' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf 'sess-1\n' > "$HB_RETRY_RUN/linear-session"
printf 'implementing — retry heartbeat\n' > "$HB_RETRY_RUN/activity"
printf '1\n' > "$HB_RETRY_RUN/linear-heartbeat"
printf '7\n' > "$MODES/curl-exit"
: > "$CURL_LOG"
( set -u
  HARNESS_DIR="$HARNESS" RUN_DIR="$HB_RETRY_RUN" TICKET="OLYX-134"
  LINEAR_AGENT_CREDENTIALS_FILE="$CREDS" LINEAR_API_KEY_FILE="$KEYFILE"
  export HARNESS_DIR RUN_DIR TICKET LINEAR_AGENT_CREDENTIALS_FILE
  export LINEAR_API_KEY_FILE PATH="$FAKES:$PATH"
  # shellcheck source=../lib/linear.sh
  . "$SRC/lib/linear.sh"
  HARNESS_LINEAR_HEARTBEAT_SECS=300
  export HARNESS_LINEAR_HEARTBEAT_SECS
  linear_heartbeat
  [ "$(cat "$RUN_DIR/linear-heartbeat")" = 1 ] \
    || : > "$RUN_DIR/failed-beat-advanced-mark"
  linear_heartbeat )
absent "heartbeat retry: a failed send does not advance the marker" \
  "$HB_RETRY_RUN/failed-beat-advanced-mark"
check "heartbeat retry: the next tick retries immediately" \
  "$(calls '"type":"thought"')" "2"
exists "heartbeat retry: the successful retry records its epoch" \
  "$HB_RETRY_RUN/linear-heartbeat"

# And the same thing wired into the driver's ticker, on a run slow enough to tick.
reset_modes; agent_on; rm -f "$TOKEN_FILE"
printf 'slow\n' > "$CLAUDE_MODE"
dispatch OLYX-131 "HARNESS_RUN_LINK_BASE=$LINK_BASE HARNESS_HEARTBEAT_SECS=1 HARNESS_LINEAR_HEARTBEAT_SECS=1"
at_least "heartbeat: the ticker beats on a live run" "$(calls '"ephemeral":true')" 1
exists "heartbeat: and records when it last did" "$RUNS/OLYX-131/linear-heartbeat"

reset_modes; agent_on; rm -f "$TOKEN_FILE"
printf 'slow\n' > "$CLAUDE_MODE"
dispatch OLYX-132 "HARNESS_RUN_LINK_BASE=$LINK_BASE HARNESS_HEARTBEAT_SECS=1"
check "heartbeat: at the default interval a short run does not beat" \
  "$(calls '"ephemeral":true')" 0

reset_modes; agent_off
printf 'slow\n' > "$CLAUDE_MODE"
dispatch OLYX-133 "HARNESS_RUN_LINK_BASE=$LINK_BASE HARNESS_HEARTBEAT_SECS=1 HARNESS_LINEAR_HEARTBEAT_SECS=1"
check "heartbeat: no agent layer, no beat" "$(calls agentActivityCreate)" "0"
reset_modes

# ---------------------------------------------------------------------------
echo "== the terminal stages, driven by the texts the pipeline really emits =="
# ---------------------------------------------------------------------------
agent_on; rm -f "$TOKEN_FILE"
printf 'questions\n' > "$CLAUDE_MODE"
dispatch OLYX-140 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "waiting: the run pauses for a human" "$RC" "3"
check "waiting: with the status that says so" "$(result_field OLYX-140 status)" "needs_input"
check "waiting: one elicitation" "$(calls '"type":"elicitation"')" "1"
file_has "$CURL_LOG" "Should the card carry the branch or the worktree path?" \
  "waiting: carrying the questions themselves"
file_has "$CURL_LOG" 'attach.sh OLYX-140' "waiting: and how to answer them"
check "waiting: nothing was mistaken for an error" "$(calls '"type":"error"')" "0"

reset_modes; agent_on
printf 'longquestions\n' > "$CLAUDE_MODE"
dispatch OLYX-144 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "long waiting: one elicitation" "$(calls '"type":"elicitation"')" "1"
file_has "$CURL_LOG" 'attach.sh OLYX-144' \
  "long waiting: the answer instructions survive truncation"

reset_modes; agent_on
printf 'reject\n' > "$CLAUDE_MODE"
dispatch OLYX-141 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "rejected: the run ends rejected" "$(result_field OLYX-141 status)" "rejected"
check "rejected: one error activity" "$(calls '"type":"error"')" "1"
file_has "$CURL_LOG" "the diff undoes the feature it was asked for" \
  "rejected: carrying the rejection itself"

reset_modes; agent_on
printf 'exit 1\n' > "$GATE_MODE"
dispatch OLYX-142 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "gate: the run ends gate_failed" "$(result_field OLYX-142 status)" "gate_failed"
check "gate: one error activity" "$(calls '"type":"error"')" "1"
file_has "$CURL_LOG" '"body":"gate_failed — http://mini:4711/console#OLYX-142"' \
  "gate: naming the status and where to look"
check "gate: no PR, so no response" "$(calls '"type":"response"')" "0"

reset_modes; agent_on
RESET_ISO=$(perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime(time + 900))')
cat > "$CCUSAGE_JSON" <<EOF
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"endTime":"$RESET_ISO","tokenCounts":{"outputTokens":400000}}
]}
EOF
# The gate pins HARNESS_PREFLIGHT=off for every suite it runs, and a run that
# never asks about capacity never defers. This is the one case here that needs
# the preflight, so it asks for it — the way tests/escalation.test.sh and
# tests/turn-ceiling.test.sh do.
dispatch OLYX-143 "HARNESS_RUN_LINK_BASE=$LINK_BASE HARNESS_PREFLIGHT=on"
check "deferred: the run defers itself" "$(result_field OLYX-143 status)" "deferred_capacity"
check "deferred: one thought — the run is coming back" "$(calls '"type":"thought"')" "1"
file_has "$CURL_LOG" 'deferred: capacity, armed for' "deferred: saying what it is waiting for"
check "deferred: and no error, because nothing failed" "$(calls '"type":"error"')" "0"
healthy_capacity

# ---------------------------------------------------------------------------
echo "== ready: the PR link is the session's response, not a second comment =="
# ---------------------------------------------------------------------------
reset_modes; agent_on; rm -f "$TOKEN_FILE"
dispatch OLYX-150 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "ready: the run ships" "$(result_field OLYX-150 status)" "ready"
check "ready: one response" "$(calls '"type":"response"')" "1"
file_has "$CURL_LOG" 'Draft PR ready for review: https://github.com/olyx/greenapp/pull/9 (`fix/OLYX-150`)' \
  "ready: the response carries the PR and the branch"
file_has "$CURL_LOG" 'Review: reviewed_claude' "ready: and names the arm that reviewed it"
check "ready: the PR is hung off the session" "$(calls agentSessionUpdate)" "1"
file_has "$CURL_LOG" '"addedExternalUrls":[{"label":"Pull Request","url":"https://github.com/olyx/greenapp/pull/9"}]' \
  "ready: with the label Linear recommends"
check "ready: and no duplicate comment — Linear mirrors the response" \
  "$(calls commentCreate)" "0"
check "ready: the ticket still moves to In Review" "$(calls issueUpdate)" "1"
if grep -F 'attachmentCreate' "$CURL_LOG" | grep -qF 'Authorization: lin_api_PERSONALKEY'; then
  ok "ready: the attachment card uses the personal key"
else
  bad "ready: the attachment card did not use the personal key"
fi
if grep -F 'issueUpdate' "$CURL_LOG" | grep -qF 'Bearer app_tok'; then
  ok "ready: the state move goes out as the app, one identity for the run"
else
  bad "ready: the state move did not use the app token"
fi
check "ready: done: ready posts nothing more — the response already went out" \
  "$(calls '"action":"done: ready"')" "0"

# A response Linear will not take must never cost the ticket its PR link.
reset_modes; agent_on
printf '1\n' > "$MODES/activity-errors"
dispatch OLYX-151 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "fallback: the run still ends ready" "$(result_field OLYX-151 status)" "ready"
check "fallback: the run's exit code is untouched" "$RC" "0"
check "fallback: today's comment goes out instead" "$(calls commentCreate)" "1"
file_has "$CURL_LOG" 'Draft PR ready for review: https://github.com/olyx/greenapp/pull/9 (`fix/OLYX-151`)' \
  "fallback: with the PR link on it"
if grep -F 'commentCreate' "$CURL_LOG" | grep -qF 'Authorization: lin_api_PERSONALKEY'; then
  ok "fallback: the comment retries through the personal key"
else
  bad "fallback: the comment did not use the personal key"
fi
check "fallback: and the ticket still moves" "$(calls issueUpdate)" "1"
file_has "$RUNS/OLYX-151/ticket-sync.log" "LINEAR ERROR agentActivityCreate:" \
  "fallback: every rejected activity is on the record"

# A mutation-level rejection has the same fallback semantics even when Linear
# returns no top-level GraphQL errors.
reset_modes; agent_on
printf '1\n' > "$MODES/activity-unsuccessful"
dispatch OLYX-152 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "unsuccessful: today's comment goes out instead" "$(calls commentCreate)" "1"
file_has "$RUNS/OLYX-152/ticket-sync.log" "LINEAR ERROR agentActivityCreate:" \
  "unsuccessful: the rejected mutation is on the record"

reset_modes; agent_on
printf '1\n' > "$MODES/response-http-500"
dispatch OLYX-153 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "HTTP failure: today's comment goes out instead" "$(calls commentCreate)" "1"
file_has "$RUNS/OLYX-153/ticket-sync.log" "LINEAR ERROR agentActivityCreate: HTTP 500" \
  "HTTP failure: the failed mutation is on the record"

# Agent-only installations still have a write-capable identity. A rejected
# response must fall back through it when there is no operator key.
reset_modes; agent_on
rm -f "$KEYFILE"
printf '1\n' > "$MODES/activity-errors"
dispatch OLYX-154 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "agent-only fallback: the run still ends ready" \
  "$(result_field OLYX-154 status)" "ready"
check "agent-only fallback: the comment carries the PR link" \
  "$(calls commentCreate)" "1"
file_has "$CURL_LOG" \
  'Draft PR ready for review: https://github.com/olyx/greenapp/pull/9 (`fix/OLYX-154`)' \
  "agent-only fallback: the fallback body names the PR"
if grep -F 'commentCreate' "$CURL_LOG" | grep -qF 'Authorization: Bearer app_tok'; then
  ok "agent-only fallback: the app token sends the comment"
else
  bad "agent-only fallback: the comment had no app authorization"
fi
printf 'lin_api_PERSONALKEY\n' > "$KEYFILE"; chmod 600 "$KEYFILE"

# ---------------------------------------------------------------------------
echo "== failures are logged and nothing else =="
# ---------------------------------------------------------------------------
reset_modes; agent_off
printf '7\n' > "$MODES/curl-exit"
dispatch OLYX-160 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "curl death: the run's status is untouched" "$(result_field OLYX-160 status)" "ready"
check "curl death: and so is its exit code" "$RC" "0"
check "curl death: exactly one error line" \
  "$(grep -c 'LINEAR ERROR' "$RUNS/OLYX-160/ticket-sync.log" | tr -d ' ')" "1"
file_has "$RUNS/OLYX-160/ticket-sync.log" "LINEAR ERROR issue lookup: curl exit 7" \
  "curl death: naming the call that died and how"
check "curl death: the next stage picks the card back up" \
  "$(calls attachmentCreate)" "$(( $(all_stages OLYX-160) - 1 ))"

reset_modes; agent_on
printf '1\n' > "$MODES/token-fail"
dispatch OLYX-161 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
check "no token: the run ships anyway" "$(result_field OLYX-161 status)" "ready"
check "no token: no session was invented" "$(calls agentSessionCreateOnIssue)" "0"
check "no token: the personal key still carries the card" "$(calls attachmentCreate)" "$(all_stages OLYX-161)"
check "no token: and today's comment" "$(calls commentCreate)" "1"
file_has "$RUNS/OLYX-161/ticket-sync.log" "LINEAR ERROR oauth/token:" \
  "no token: the mint failure is on the record"
file_has_not "$RUNS/OLYX-161/ticket-sync.log" "$SECRET" \
  "no token: and the failure did not print the credential"

# ---------------------------------------------------------------------------
echo "== the card: one attachment, upserted by the run's own link =="
# ---------------------------------------------------------------------------
reset_modes; agent_off
dispatch OLYX-170 "HARNESS_RUN_LINK_BASE=$LINK_BASE/"
check "card: one per stage, terminal included" \
  "$(calls attachmentCreate)" "$(all_stages OLYX-170)"
check "card: every one of them at the same URL — Linear upserts on it" \
  "$(calls '"url":"http://mini:4711/console#OLYX-170"')" "$(calls attachmentCreate)"
file_has "$CURL_LOG" '"title":"Dispatch run OLYX-170"' "card: titled by the run"
file_has "$CURL_LOG" '"subtitle":"setup: worktree"' "card: the subtitle tracks the stage"
file_has "$CURL_LOG" '"subtitle":"done: ready"' "card: right through the last one"
file_has "$CURL_LOG" '{"name":"Provider","value":"anthropic/' "card: attribute — provider"
file_has "$CURL_LOG" '{"name":"Owner","value":"unowned"}' "card: attribute — owner"
file_has "$CURL_LOG" '{"name":"Branch","value":"fix/OLYX-170"}' "card: attribute — branch"
file_has "$CURL_LOG" '{"name":"Host","value":"' "card: attribute — host"
file_has "$CURL_LOG" '"issueId":"uuid-77"' "card: against the UUID, never the identifier"
check "card: still exactly one issue lookup for the whole run" "$(calls 'states(first: 50)')" "1"
file_has "$RUNS/OLYX-170/ticket-sync.log" 'attachmentCreate request:' \
  "card: the request is recorded for audit"
file_has "$RUNS/OLYX-170/ticket-sync.log" '"url":"http://mini:4711/console#OLYX-170"' \
  "card: the recorded request carries its identifying fields"

# ---------------------------------------------------------------------------
echo "== secrets: not on argv, not left behind, not in the log =="
# ---------------------------------------------------------------------------
reset_modes; agent_on; rm -f "$TOKEN_FILE"
dispatch OLYX-180 "HARNESS_RUN_LINK_BASE=$LINK_BASE"
file_has_not "$ARGV_LOG" "$SECRET" "secrets: the client secret never reaches argv"
file_has_not "$ARGV_LOG" "app_tok" "secrets: nor does the app token"
file_has_not "$ARGV_LOG" "lin_api_PERSONALKEY" "secrets: nor the personal key"
file_has_not "$ARGV_LOG" " -u " "secrets: and nothing was passed with curl -u"
if grep -q 'HDR \[' "$CURL_LOG" && ! grep 'HDR \[' "$CURL_LOG" | grep -qv 'HDR \[-rw-------'; then
  ok "secrets: every header file was created mode 600"
else
  bad "secrets: a header file was readable by someone else"
fi
absent "secrets: no GraphQL header file survives the run" "$RUNS/OLYX-180/.linear-hdr"
if compgen -G "$RUNS/OLYX-180/.linear-hdr.*" >/dev/null; then
  bad "secrets: a unique GraphQL header file survived the run"
else
  ok "secrets: no unique GraphQL header file survives the run"
fi
GRAPHQL_HDRS=$(awk '/api.linear.app\/graphql/ { for (i=1; i<=NF; i++) if ($i ~ /^@.*\.linear-hdr\./) print $i }' "$ARGV_LOG")
if [ -n "$GRAPHQL_HDRS" ] && [ "$(printf '%s\n' "$GRAPHQL_HDRS" | sort -u | wc -l | tr -d ' ')" = "$(printf '%s\n' "$GRAPHQL_HDRS" | wc -l | tr -d ' ')" ]; then
  ok "secrets: concurrent calls receive distinct header files"
else
  bad "secrets: a GraphQL header file was reused"
fi
if compgen -G "$RUNS/OLYX-180/.linear-oauth-hdr.*" >/dev/null; then
  bad "secrets: a unique OAuth header file survived the run"
else
  ok "secrets: no unique OAuth header file survives the run"
fi
file_has_not "$RUNS/OLYX-180/ticket-sync.log" "$SECRET" "secrets: the log holds no client secret"
file_has_not "$RUNS/OLYX-180/ticket-sync.log" "app_tok" "secrets: and no token"
file_has_not "$RUNS/OLYX-180/ticket-sync.log" "lin_api_PERSONALKEY" "secrets: and no personal key"
file_has_not "$RUNS/OLYX-180/feed.log" "app_tok" "secrets: nothing leaked into the run's feed"
file_has_not "$ROOT/run-OLYX-180.log" "app_tok" "secrets: or onto the console"

echo
printf 'linear-agent: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
