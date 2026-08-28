# shellcheck shell=bash
# Everything the harness says to Linear, in one place: the end-of-run comment
# and state move that ticket sync has always done, the agent session a run posts
# its timeline to, and the attachment card that summarises the run on the issue.
#
# Sourced, never executed — read from beside the sourcing script, like
# lib/common.sh, so it travels with the checkout and with the install.
#
# Three layers, each with its own switch:
#   linear-api-key             the end-of-run comment and the state move
#   + HARNESS_RUN_LINK_BASE    the attachment card, keyed by the run's link
#   linear-agent-credentials   the agent session and its activities
# HARNESS_TICKET_SYNC=0 turns off all three. Every layer is best-effort in the
# strongest sense: no failure here ever changes a run's status or exit code, and
# every entry point returns 0.
#
# Secrets travel in mode-600 header files and never on argv — `ps` must never
# show them, and neither must ticket-sync.log.
#
# The run globals read below (RUN_DIR, TICKET, BRANCH, IMPLEMENTER_PROVIDER,
# IMPLEMENTER_MODEL, HARNESS_OWNER) belong to the sourcing script.
# shellcheck disable=SC2154

LINEAR_URL="https://api.linear.app/graphql"
LINEAR_TOKEN_URL="https://api.linear.app/oauth/token"
LINEAR_KEY_FILE="${LINEAR_API_KEY_FILE:-$HARNESS_DIR/linear-api-key}"
LINEAR_AGENT_CREDS_FILE="${LINEAR_AGENT_CREDENTIALS_FILE:-$HARNESS_DIR/linear-agent-credentials}"
LINEAR_AGENT_TOKEN_FILE="$HARNESS_DIR/linear-agent-token"
# An app token lives 30 days. Re-mint with less than a day left rather than
# discover the expiry mid-run.
LINEAR_TOKEN_MIN_LIFE=86400
LINEAR_TOKEN_DEFAULT_LIFE=2592000
# What a body carrying a whole file is cut to before it becomes an activity.
LINEAR_BODY_MAX=10000
# Set by linear_post from curl's -w; empty when the responder ignored it.
LINEAR_STATUS=""
# Set alongside LINEAR_STATUS so callers do not need a command substitution,
# which would discard both assignments in a subshell.
LINEAR_RESPONSE=""
# Set by linear_auth_hdr: agent or personal. Only an app token can be re-minted.
LINEAR_IDENTITY=""

# The TEAM-123 identifier a run id has to start with for any of this to happen.
# An adhoc-* run prints nothing and returns 1, and every caller stops there.
linear_ident() {  # $1 = run id
  printf '%s' "$1" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+'
}

linear_agent_on() { [ -r "$LINEAR_AGENT_CREDS_FILE" ]; }

linear_host() { hostname -s 2>/dev/null || printf 'unknown'; }

# The run's deep link on the team's wall, and the attachment card's idempotency
# key. Returns 1 when no wall is configured.
linear_run_link() {
  [ -n "${HARNESS_RUN_LINK_BASE:-}" ] || return 1
  printf '%s/console#%s' "${HARNESS_RUN_LINK_BASE%/}" "$TICKET"
}

# A mode-600 file holding one Authorization header; prints its path.
linear_hdr_file() {  # $1 = dest path, $2 = header value
  ( umask 077; printf 'Authorization: %s\n' "$2" > "$1" ) || return 1
  printf '%s' "$1"
}

# curl prints the body and then, from -w, the HTTP status on a line of its own.
# A response whose last line is not a bare status code came from something that
# ignored -w, so all of it is the body and the status stays unknown.
#
# The body goes on argv after -d, exactly as it always has: it carries no
# secret, and the suites that read Linear traffic read it there.
linear_post() {  # $1 = header file, $2 = JSON body
  local out last
  LINEAR_STATUS=""
  LINEAR_RESPONSE=""
  out=$(curl -s -m 10 -H @"$1" -H 'Content-Type: application/json' \
        -w '\n%{http_code}' -d "$2" "$LINEAR_URL") || return $?
  last=${out##*$'\n'}
  case "$last" in
    [0-9][0-9][0-9]) LINEAR_STATUS="$last"; out=${out%$'\n'*} ;;
  esac
  LINEAR_RESPONSE="$out"
  printf '%s' "$out"
}

# --- The app actor token ------------------------------------------------------
# client_credentials, so there is no browser, no refresh token and no inbound
# URL anywhere in this: the harness only ever pushes.

# Prints the token. `force` re-mints even a cache that still has life in it —
# what a 401 asks for. Returns 1 when the agent layer is off or a mint failed.
linear_agent_token() {  # $1 = "force" to bypass the cache
  linear_agent_on || return 1
  local now tok exp id secret hdr resp life
  now=$(date +%s)
  if [ "${1:-}" != force ] && [ -s "$LINEAR_AGENT_TOKEN_FILE" ]; then
    tok=$(jq -r '.access_token // empty' "$LINEAR_AGENT_TOKEN_FILE" 2>/dev/null) || tok=""
    exp=$(jq -r '.expires_at // 0' "$LINEAR_AGENT_TOKEN_FILE" 2>/dev/null) || exp=0
    case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
    if [ -n "$tok" ] && [ "$((exp - now))" -gt "$LINEAR_TOKEN_MIN_LIFE" ]; then
      printf '%s' "$tok"; return 0
    fi
  fi
  id=$(grep '^client_id=' "$LINEAR_AGENT_CREDS_FILE" | head -1 | cut -d= -f2-)
  secret=$(grep '^client_secret=' "$LINEAR_AGENT_CREDS_FILE" | head -1 | cut -d= -f2-)
  [ -n "$id" ] && [ -n "$secret" ] || return 1
  hdr="$RUN_DIR/.linear-oauth-hdr"
  linear_hdr_file "$hdr" \
    "Basic $(printf '%s:%s' "$id" "$secret" | base64 | tr -d '\n')" >/dev/null || return 1
  resp=$(curl -s -m 10 -H @"$hdr" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d 'grant_type=client_credentials&scope=read,write,app:assignable,app:mentionable' \
      "$LINEAR_TOKEN_URL") || resp=""
  rm -f "$hdr"
  tok=$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null) || tok=""
  if [ -z "$tok" ]; then
    # A malformed response can still contain a credential that jq could not
    # extract, so OAuth response bodies never belong in the log.
    printf 'LINEAR ERROR oauth/token: invalid response\n' >> "$RUN_DIR/ticket-sync.log"
    return 1
  fi
  life=$(printf '%s' "$resp" | jq -r '.expires_in // empty' 2>/dev/null) || life=""
  case "$life" in ''|*[!0-9]*) life="$LINEAR_TOKEN_DEFAULT_LIFE" ;; esac
  ( umask 077; jq -n --arg t "$tok" --argjson e "$((now + life))" \
      '{access_token:$t,expires_at:$e}' > "$LINEAR_AGENT_TOKEN_FILE" ) || return 1
  printf 'oauth/token: minted, %s seconds\n' "$life" >> "$RUN_DIR/ticket-sync.log"
  printf '%s' "$tok"
}

# The identity every call travels under: the app token when the agent layer is
# configured — one actor for the whole run — and the operator's personal key
# otherwise. LINEAR_IDENTITY says which, because only the app token can be
# re-minted on a 401.
linear_auth_hdr() {  # $1 = dest path
  local tok
  LINEAR_IDENTITY=""
  if tok=$(linear_agent_token); then
    LINEAR_IDENTITY=agent
    linear_hdr_file "$1" "Bearer $tok"
    return $?
  fi
  [ -r "$LINEAR_KEY_FILE" ] || return 1
  LINEAR_IDENTITY=personal
  linear_hdr_file "$1" "$(cat "$LINEAR_KEY_FILE")"
}

# Every request and its raw response land in ticket-sync.log and nowhere else.
# A curl failure or a GraphQL `errors` array adds the one line an operator
# greps for — the live test for a mutation Linear rejects is
# `grep 'LINEAR ERROR' ticket-sync.log`, because no suite can make that call.
linear_record() {  # $1 = label, $2 = raw response, $3 = curl exit
  { printf '%s: %s\n' "$1" "$2"
    if [ "$3" -ne 0 ]; then
      printf 'LINEAR ERROR %s: curl exit %s\n' "$1" "$3"
    elif printf '%s' "$2" | grep -q '"errors"'; then
      printf 'LINEAR ERROR %s: %s\n' "$1" "$2"
    fi
  } >> "$RUN_DIR/ticket-sync.log"
  printf '%s' "$2"
  [ "$3" -eq 0 ] || return 1
  if printf '%s' "$2" | grep -q '"errors"'; then return 1; fi
  return 0
}

# One GraphQL call: authenticate, post, log, and re-mint once on a 401 before
# retrying. Prints the response; returns 1 on a curl failure or a GraphQL error.
linear_call() {  # $1 = label, $2 = JSON body
  local hdr="$RUN_DIR/.linear-hdr" resp rc=0
  linear_auth_hdr "$hdr" >/dev/null || return 1
  linear_post "$hdr" "$2" >/dev/null || rc=$?
  resp=$LINEAR_RESPONSE
  if [ "$rc" -eq 0 ] && [ "$LINEAR_STATUS" = 401 ] && [ "$LINEAR_IDENTITY" = agent ]; then
    if linear_agent_token force >/dev/null && linear_auth_hdr "$hdr" >/dev/null; then
      linear_post "$hdr" "$2" >/dev/null || rc=$?
      resp=$LINEAR_RESPONSE
    fi
  fi
  rm -f "$hdr"
  linear_record "$1" "$resp" "$rc"
}

# A call that only the app may make: Linear binds session writes to the OAuth
# app that owns the session, so the personal key must never be tried for one.
linear_agent_call() {  # $1 = label, $2 = JSON body
  linear_agent_token >/dev/null || return 1
  linear_call "$1" "$2"
}

# --- The issue -----------------------------------------------------------------

# The identifier -> UUID + team states lookup, made once per run and cached.
# Every mutation passes the UUID: Linear promises identifier acceptance only for
# agentSessionCreateOnIssue, and an id it rejects fails silently by design.
linear_issue_json() {
  local cache="$RUN_DIR/linear-issue.json" ident gql resp
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  ident=$(linear_ident "$TICKET") || return 1
  gql=$(jq -cn --arg id "$ident" '{query:"query($id: String!){ issue(id: $id){ id identifier team { states(first: 50){ nodes { id name type } } } } }",variables:{id:$id}}')
  resp=$(linear_call "issue lookup" "$gql") || return 1
  # Linear's answer is cached even when it is "no such issue" — a run whose
  # ticket does not exist must not re-ask on every stage. A call that never
  # reached Linear is not an answer and is not cached.
  printf '%s' "$resp" | jq -e 'has("data")' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" > "$cache"
  printf '%s' "$resp"
}

linear_issue_uuid() {
  local j id
  j=$(linear_issue_json) || return 1
  id=$(printf '%s' "$j" | jq -r '.data.issue.id // empty')
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# --- The agent session ---------------------------------------------------------

# The run's session on its issue, created once and reused: a re-dispatch
# continues the same timeline rather than opening a second one.
linear_session() {
  local f="$RUN_DIR/linear-session" iid link gql resp sid
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  linear_agent_on || return 1
  iid=$(linear_issue_uuid) || return 1
  link=$(linear_run_link) || link=""
  gql=$(jq -cn --arg id "$iid" --arg link "$link" \
    '{query:"mutation($input: AgentSessionCreateOnIssueInput!){ agentSessionCreateOnIssue(input: $input){ success agentSession { id externalLinks { label url } } } }",
      variables:{input: ({issueId:$id}
        + (if $link == "" then {} else {externalUrls:[{label:"Dispatch run",url:$link}]} end))}}')
  resp=$(linear_agent_call agentSessionCreateOnIssue "$gql") || return 1
  sid=$(printf '%s' "$resp" | jq -r '.data.agentSessionCreateOnIssue.agentSession.id // empty')
  [ -n "$sid" ] || return 1
  printf '%s\n' "$sid" > "$f"
  printf '%s' "$sid"
}

linear_content() {  # $1 = thought|elicitation|response|error, $2 = body
  local body="${2-}"
  jq -cn --arg t "$1" --arg b "${body:0:$LINEAR_BODY_MAX}" '{type:$t,body:$b}'
}

linear_content_action() {  # $1 = action, $2 = parameter
  jq -cn --arg a "$1" --arg p "$2" '{type:"action",action:$a,parameter:$p}'
}

# The content object travels as a typed variable rather than inline: a GraphQL
# variable takes an enum as a plain JSON string, so `type` needs no guess about
# quoting.
linear_activity() {  # $1 = session id, $2 = content JSON, $3 = "ephemeral"
  local gql eph=false
  [ "${3:-}" != ephemeral ] || eph=true
  gql=$(jq -cn --arg sid "$1" --argjson content "$2" --argjson eph "$eph" \
    '{query:"mutation($input: AgentActivityCreateInput!){ agentActivityCreate(input: $input){ success } }",
      variables:{input: ({agentSessionId:$sid,content:$content}
        + (if $eph then {ephemeral:true} else {} end))}}')
  linear_agent_call agentActivityCreate "$gql" >/dev/null
}

# --- The attachment card -------------------------------------------------------

# The always-visible summary: one attachment whose subtitle tracks the stage.
# Linear upserts by (issue, url), so the run's own link is all the bookkeeping
# there is — no id to store, no card to clean up.
linear_card() {  # $1 = stage text
  local link iid gql
  link=$(linear_run_link) || return 0
  iid=$(linear_issue_uuid) || return 0
  gql=$(jq -cn --arg id "$iid" --arg url "$link" \
      --arg title "Dispatch run $TICKET" --arg sub "$1" \
      --arg provider "${IMPLEMENTER_PROVIDER:-}/${IMPLEMENTER_MODEL:-}" \
      --arg owner "${HARNESS_OWNER:-}" --arg branch "${BRANCH:-}" \
      --arg host "$(linear_host)" \
    '{query:"mutation($input: AttachmentCreateInput!){ attachmentCreate(input: $input){ success } }",
      variables:{input:{issueId:$id,url:$url,title:$title,subtitle:$sub,
        metadata:{attributes:[{name:"Provider",value:$provider},
                              {name:"Owner",value:(if $owner == "" then "unowned" else $owner end)},
                              {name:"Branch",value:$branch},
                              {name:"Host",value:$host}]}}}}')
  linear_call attachmentCreate "$gql" >/dev/null
  return 0
}

# --- What a stage says on the ticket -------------------------------------------

linear_file_body() {  # $1 = path, $2 = fallback text
  local body=""
  [ ! -r "$1" ] || body=$(cat "$1")
  [ -n "$body" ] || body="$2"
  printf '%s' "$body"
}

# The session half of a stage report: one activity, chosen by the stage TEXT the
# pipeline emits. `done: ready` posts nothing — ticket_sync already sent the
# response that carries the PR link, and it runs first.
linear_session_stage() {  # $1 = stage text
  local sid body
  sid=$(linear_session) || return 0
  case "$1" in
    "done: ready") return 0 ;;
    "waiting —"*|"done: needs_input")
      body=$(linear_file_body "$RUN_DIR/QUESTIONS.md" "$1")
      linear_activity "$sid" "$(linear_content elicitation "$body
Answer in the run's brief and re-dispatch, or \`attach.sh $TICKET\`.")"
      ;;
    deferred:*)
      linear_activity "$sid" "$(linear_content thought "$1")"
      ;;
    "done: rejected")
      body=$(linear_file_body "$RUN_DIR/REJECTED.md" "$1")
      linear_activity "$sid" "$(linear_content error "$body")"
      ;;
    done:*)
      linear_activity "$sid" \
        "$(linear_content error "${1#done: } — $(linear_run_link || printf '%s' "$TICKET")")"
      ;;
    *)
      linear_activity "$sid" "$(linear_content_action "$1" \
        "$TICKET · ${IMPLEMENTER_PROVIDER:-}/${IMPLEMENTER_MODEL:-} · $(linear_host)")"
      ;;
  esac
  return 0
}

# The one line stage() appends. Nothing below it may fail a run.
linear_stage_report() {  # $1 = stage text
  [ "${HARNESS_TICKET_SYNC:-1}" = 1 ] || return 0
  linear_ident "$TICKET" >/dev/null 2>&1 || return 0
  local card=0
  if [ -n "${HARNESS_RUN_LINK_BASE:-}" ] && [ -r "$LINEAR_KEY_FILE" ]; then card=1; fi
  if [ "$card" = 0 ] && ! linear_agent_on; then return 0; fi
  [ "$card" = 0 ] || linear_card "$1"
  linear_agent_on || return 0
  linear_session_stage "$1"
  return 0
}

# The driver's heartbeat ticker calls this: an ephemeral thought carrying what
# the run is doing right now, so a long implementer stage never reaches the 30
# minutes after which Linear calls a session stale. It never creates a session —
# stage() owns that — and never posts more than one per interval.
linear_heartbeat() {
  [ "${HARNESS_TICKET_SYNC:-1}" = 1 ] || return 0
  local f="$RUN_DIR/linear-session" mark now last body
  [ -s "$f" ] || return 0
  linear_agent_on || return 0
  mark="$RUN_DIR/linear-heartbeat"
  now=$(date +%s)
  last=$(cat "$mark" 2>/dev/null) || last=0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$((now - last))" -ge "${HARNESS_LINEAR_HEARTBEAT_SECS:-300}" ] || return 0
  body=$(cat "$RUN_DIR/activity" 2>/dev/null) || body=""
  [ -n "$body" ] || return 0
  printf '%s\n' "$now" > "$mark"
  linear_activity "$(cat "$f")" "$(linear_content thought "$body")" ephemeral
  return 0
}
