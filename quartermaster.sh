#!/usr/bin/env bash
# The Quartermaster — the 19:00 brain between capacity that expires and work
# that is waiting.
#
# Subscription capacity left unused at the end of the day is worth nothing
# tomorrow, while dispatchable work sits in Linear. The crew convention (the
# label `overnight` plus an assignee = consent plus identity) and the machinery
# (schedule.sh, briefs at runs/<TICKET>/brief.md, per-station env) already
# exist. This connects them: estimate what each crew member has left, decide
# how many runs fit, arm them, and tell the crew's phones.
#
# Usage:
#   quartermaster.sh [--report]         compute and report; arms NOTHING
#   quartermaster.sh --arm              compute, arm via schedule.sh, report
#   quartermaster.sh --install [MODE]   daily LaunchAgent (MODE: --report|--arm)
#   quartermaster.sh --uninstall        remove that agent
#
# The report is written to runs/quartermaster/<YYYY-MM-DD>.md and pushed as one
# compact summary when notify.conf sets HARNESS_NTFY_TOPIC.
#
# Only two things ever leave this machine: the Linear API (read, plus one
# comment per ticket actually armed) and the ntfy push. Capacity accounting is
# local-file only — ccusage parses the station's own Claude logs, and no model
# provider is contacted from anywhere in here.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
RUNS="$HARNESS_DIR/runs"
QM_DIR="$RUNS/quartermaster"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_ID="com.olyx.quartermaster"
WRAPPER="$QM_DIR/quartermaster-agent.sh"
PLIST="$AGENTS_DIR/$LABEL_ID.plist"
AGENT_LOG="$QM_DIR/quartermaster.log"
TAB=$(printf '\t')

# Every knob the evening turns on, all env-tunable: a crew tightens the dial
# without editing the script.
ACCOUNTS_DIR="${QM_ACCOUNTS_DIR:-$HOME/accounts}"  # one directory per crew station
LINEAR_URL="https://api.linear.app/graphql"
LINEAR_KEY_FILE="${LINEAR_API_KEY_FILE:-$HARNESS_DIR/linear-api-key}"
TAG="${QM_LABEL:-overnight}"                       # the consent label
SAFETY="${QM_SAFETY:-0.5}"                         # fraction of the estimate we dare spend
MAX_PER_CREW="${QM_MAX_PER_CREW:-3}"               # hard ceiling per crew member
FALLBACK_N="${QM_FALLBACK_N:-1}"                   # when capacity is unknowable
TIMES="${QM_TIMES:-23:30 02:00 04:30}"             # fire times, handed out in queue order
HISTORY="${QM_HISTORY:-20}"                        # runs sampled for the median cost
DEFAULT_COST="${QM_DEFAULT_COST:-40000}"           # median cost when history is thin
AT="${QM_AT:-19:00}"                               # when the installed agent fires
# The two knobs capacity.sh reads, under this script's documented names.
CAPACITY_TOKEN_LIMIT="${QM_TOKEN_LIMIT:-}"         # pin the block ceiling yourself
CAPACITY_TIMEOUT="${QM_CCUSAGE_TIMEOUT:-120}"
LINEAR_TIMEOUT="${QM_LINEAR_TIMEOUT:-20}"
NTFY_TIMEOUT="${QM_NTFY_TIMEOUT:-10}"
EFFORT="${QM_EFFORT:-high}"                        # IMPLEMENTER_EFFORT for armed runs

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
fail()  { echo "FATAL: $*" >&2; exit 1; }

# The capacity accountant, shared with run-task.sh's dispatch preflight so the
# local-file-only rule is stated and enforced in exactly one place.
# shellcheck source=capacity.sh
. "$SELF_DIR/capacity.sh" || fail "cannot read $SELF_DIR/capacity.sh — re-run install.sh"

# ntfy topic and server, read exactly the way run-task.sh reads them.
# shellcheck source=/dev/null
. "$HARNESS_DIR/notify.conf" 2>/dev/null || true

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

human_time() {  # $1 = epoch
  perl -e 'use POSIX qw(strftime); print strftime("%a %d %b %H:%M", localtime($ARGV[0]))' -- "$1"
}

# Keep the quartermaster's existing generic name while sharing the identical
# macOS-safe process cap supplied by capacity.sh.
capped() { capacity_capped "$@"; }

# ---------------------------------------------------------------------------
# Linear — the only remote API this touches: read, plus one comment per arm
# ---------------------------------------------------------------------------
LINEAR_HDR=""    # header file, mode 600 — keeps the key out of every argv
LINEAR_NOTE=""   # what the report says when the queue could not be read
LINEAR_PARTIAL_NOTE=""  # what the report says when later pages could not be read
LINEAR_PAGE="${QM_PAGE:-100}"  # page size; Relay cursors fetch the complete queue
case "$LINEAR_PAGE" in ''|*[!0-9]*|0) LINEAR_PAGE=100 ;; esac

# Deliberately plain. Every extra argument is one more chance for a schema
# mismatch to turn the whole evening into "Linear unreachable", so the queue is
# ordered here instead of server-side: priority ascending with 0 ("no
# priority") last, oldest first within a priority.
LINEAR_QUERY='query Overnight($label: String!, $page: Int!, $after: String) {
  issues(first: $page, after: $after, filter: {
    labels: { name: { eq: $label } },
    state: { type: { in: ["backlog", "unstarted"] } },
    assignee: { null: false }
  }) {
    nodes {
      id identifier title priority createdAt
      assignee { email }
      state { type }
    }
    pageInfo { hasNextPage endCursor }
  }
}'

LINEAR_COMMENT_MUTATION='mutation Armed($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) { success }
}'

load_linear_key() {  # sets LINEAR_HDR, or explains itself in LINEAR_NOTE
  local key
  if [ ! -r "$LINEAR_KEY_FILE" ]; then
    LINEAR_NOTE="no readable Linear API key at $LINEAR_KEY_FILE"
    return 1
  fi
  key=$(tr -d '\r\n' < "$LINEAR_KEY_FILE" 2>/dev/null) || key=""
  if [ -z "$key" ]; then
    LINEAR_NOTE="the Linear API key file $LINEAR_KEY_FILE is empty"
    return 1
  fi
  LINEAR_HDR="$WORK/linear-headers"
  : > "$LINEAR_HDR" || return 1
  chmod 600 "$LINEAR_HDR" || return 1
  printf 'Authorization: %s\nContent-Type: application/json\n' "$key" >> "$LINEAR_HDR"
  return 0
}

linear_post() {  # $1 = request body; prints the response body
  [ -n "$LINEAR_HDR" ] || return 1
  printf '%s' "$1" | capped "$LINEAR_TIMEOUT" \
    curl -sS -X POST -H "@$LINEAR_HDR" --data-binary @- "$LINEAR_URL" 2>/dev/null
}

# GraphQL answers 200 with an errors array, so a failure has to be read out of
# the body. The message travels; the key never does.
linear_errors() {  # $1 = response body
  local msg
  msg=$(printf '%s' "$1" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null) || msg=""
  [ -n "$msg" ] && printf ' (%s)' "$msg"
  return 0
}

# One TSV row per tagged issue: id, identifier, assignee email, title. Linear
# connections use Relay pagination; collect every page before sorting so queue
# priority is global rather than merely correct within each page.
fetch_issues() {  # prints rows; non-zero when the queue is unusable
  local after="" body response rows has_next cursor pages=0
  : > "$WORK/linear-nodes"
  : > "$WORK/linear-cursors"
  while :; do
    body=$(jq -n --arg q "$LINEAR_QUERY" --arg label "$TAG" \
      --argjson page "$LINEAR_PAGE" --arg after "$after" '
      {query: $q, variables: {
        label: $label,
        page: $page,
        after: (if $after == "" then null else $after end)
      }}') || return 1
    response=$(linear_post "$body") || {
      if [ "$pages" -eq 0 ]; then
        LINEAR_NOTE="Linear did not answer (network, timeout, or no curl)"
        return 1
      fi
      LINEAR_PARTIAL_NOTE="Linear stopped answering after $pages page(s)"
      break
    }
    if [ -z "$response" ] || ! printf '%s' "$response" | jq -e '
      ((.errors // []) | length) == 0 and (.data.issues.nodes | type == "array")
    ' >/dev/null 2>&1; then
      if [ "$pages" -eq 0 ]; then
        LINEAR_NOTE="Linear returned no usable issue list$(linear_errors "$response")"
        return 1
      fi
      LINEAR_PARTIAL_NOTE="Linear returned an unusable page after $pages page(s)$(linear_errors "$response")"
      break
    fi
    printf '%s' "$response" | jq -c '.data.issues.nodes[]' >> "$WORK/linear-nodes" \
      || return 1
    pages=$((pages + 1))
    has_next=$(printf '%s' "$response" | jq -r '.data.issues.pageInfo.hasNextPage // false') \
      || has_next=false
    [ "$has_next" = true ] || break
    cursor=$(printf '%s' "$response" | jq -r '.data.issues.pageInfo.endCursor // ""') \
      || cursor=""
    if [ -z "$cursor" ] || grep -qxF -- "$cursor" "$WORK/linear-cursors"; then
      LINEAR_PARTIAL_NOTE="Linear returned an invalid or repeated page cursor after $pages page(s)"
      break
    fi
    printf '%s\n' "$cursor" >> "$WORK/linear-cursors"
    after="$cursor"
  done

  rows=$(jq -s -r '
    map(select(.assignee != null and (.assignee.email // "") != ""))
    | map(select((.state.type // "") | . == "backlog" or . == "unstarted"))
    | sort_by([(if (.priority // 0) == 0 then 5 else .priority end), (.createdAt // "")])
    | .[]
    | [.id, .identifier, .assignee.email, (.title // "")]
    | @tsv' "$WORK/linear-nodes" 2>/dev/null) || {
    LINEAR_NOTE="Linear's answer did not have the shape of an issue list"
    return 1
  }
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows"
}

# Best-effort by contract: a failed comment must never unarm a run.
linear_comment() {  # $1 = issue id, $2 = body
  local body
  [ -n "$LINEAR_HDR" ] || return 1
  body=$(jq -n --arg q "$LINEAR_COMMENT_MUTATION" --arg id "$1" --arg text "$2" \
    '{query: $q, variables: {issueId: $id, body: $text}}') || return 1
  linear_post "$body" | jq -e '.data.commentCreate.success == true' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Capacity
# ---------------------------------------------------------------------------
# What one run costs, in the only unit measurable on both sides of this sum:
# the implementer's output tokens. Median over the most recent runs, so one
# runaway task does not move the estimate. Prints "<cost> <sample count>" —
# the sample count travels in the output rather than a global because the
# caller reads this through a command substitution.
median_cost() {
  local files vals n
  # Run-dir names are ticket IDs and adhoc slugs — no whitespace — so splitting
  # ls -t output on newlines is safe here.
  # shellcheck disable=SC2012
  files=$(ls -t "$RUNS"/*/result.json 2>/dev/null | head -n "$HISTORY") || files=""
  if [ -n "$files" ]; then
    vals=$(printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      jq -r '.metrics.implementer_usage.output_tokens // empty' "$f" 2>/dev/null
    done | grep -E '^[0-9]+$' | sort -n)
    n=$(printf '%s' "$vals" | grep -c '^[0-9]' | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      printf '%s %s\n' \
        "$(printf '%s\n' "$vals" | awk '
          { a[NR] = $1 }
          END { if (NR % 2) print a[(NR + 1) / 2]; else printf "%d\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }')" \
        "$n"
      return 0
    fi
  fi
  printf '%s 0\n' "$DEFAULT_COST"
  return 0
}

# Headroom itself comes from capacity.sh (capacity_for -> CAP_*), which
# run-task.sh's preflight reads through the same door.

# N = floor(remaining x safety / cost), never above the per-crew ceiling.
runs_that_fit() {  # $1 = remaining tokens, $2 = median cost
  local n
  n=$(awk -v r="$1" -v s="$SAFETY" -v c="$2" 'BEGIN {
    if (c + 0 <= 0) { print 0; exit }
    v = int((r + 0) * (s + 0) / (c + 0))
    print (v < 0) ? 0 : v
  }') || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -le "$MAX_PER_CREW" ] || n="$MAX_PER_CREW"
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------
# Eligibility — armable only when a human already approved a brief
# ---------------------------------------------------------------------------
SCHEDULE_LIST=""

# Prints why this ticket must be left alone, or nothing when it is free.
skip_reason() {  # $1 = ticket id
  local dir="$RUNS/$1" fire="" pr="" stagetext=""
  if [ -f "$dir/scheduled" ]; then
    read -r fire < "$dir/scheduled" 2>/dev/null || fire=""
    if [ -n "$fire" ] && [ -z "${fire//[0-9]/}" ]; then
      printf 'already armed for %s' "$(human_time "$fire")"
    else
      printf 'already armed'
    fi
    return 0
  fi
  if printf '%s\n' "$SCHEDULE_LIST" | awk '{print $1}' | grep -qxF -- "$1"; then
    printf 'already armed (schedule.sh --list)'
    return 0
  fi
  if [ -f "$dir/result.json" ]; then
    pr=$(jq -r '.pr_url // ""' "$dir/result.json" 2>/dev/null) || pr=""
    if [ -n "$pr" ]; then
      printf 'already delivered (%s)' "$pr"
      return 0
    fi
  fi
  if [ -f "$dir/status" ]; then
    read -r _ stagetext < "$dir/status" 2>/dev/null || stagetext=""
    case "${stagetext:-}" in
      done:*) ;;
      '')     printf 'already running'; return 0 ;;
      *)      printf 'already running (%s)' "$stagetext"; return 0 ;;
    esac
  fi
  return 1
}

# The brief pins where the run goes; the template fixes its header format, so
# read it rather than re-deriving a repo from a ticket ID.
brief_field() {  # $1 = brief path, $2 = field name
  sed -n "s/^- \\*\\*$2\\*\\*:[[:space:]]*//p" "$1" 2>/dev/null \
    | head -1 | sed -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//'
}

# A ticket identifier and a station name both become path components under
# runs/ and accounts/, and both are derived from what a remote API said. Same
# rule schedule.sh validates its tickets with: letters, digits, dot, dash,
# underscore, and never leading with a dot.
safe_component() {  # $1 = candidate
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# angel.sole@olyx.nl -> angel. The local part up to the first dot is the
# station name, by crew convention.
station_for() {  # $1 = email
  local local_part="${1%%@*}"
  printf '%s' "${local_part%%.*}" | tr '[:upper:]' '[:lower:]'
}

nth_time() {  # $1 = zero-based index into TIMES; prints nothing when we run out
  local i=0 t
  for t in $TIMES; do
    if [ "$i" -eq "$1" ]; then printf '%s' "$t"; return 0; fi
    i=$((i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Arming
# ---------------------------------------------------------------------------
# The station's identity is exported, not inherited: schedule.sh snapshots this
# environment into the wrapper it writes, so the run that fires at 02:00 is the
# crew member who consented to it by assigning the ticket. GH_TOKEN is actively
# unset rather than merely not set: gh prefers a token over its config dir, so
# one exported in the invoking shell would quietly make every crew member's PR
# come out of the same account.
arm_ticket() {  # $1 ticket, $2 repo, $3 branch, $4 when, $5 station, $6 station dir
  (
    unset GH_TOKEN
    export HARNESS_DIR="$HARNESS_DIR"
    export CLAUDE_CONFIG_DIR="$6/claude"
    export CODEX_HOME="$6/codex"
    export GH_CONFIG_DIR="$6/gh"
    export HARNESS_OWNER="$5"
    export IMPLEMENTER_EFFORT="$EFFORT"
    exec "$SELF_DIR/schedule.sh" "$1" "$2" "$3" "$4"
  ) </dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The evening
# ---------------------------------------------------------------------------
REPORT=""     # the file being assembled
SUMMARY=""    # the compact ntfy body
say()  { printf '%s\n' "$*" >> "$REPORT"; }
line() { SUMMARY="$SUMMARY$*
"; }
count_of() { grep -c '' < "$1" 2>/dev/null | tr -d ' '; }

# One crew member: capacity, their slice of the queue, and what happens to it.
station_pass() {  # $1 = mode, $2 = station, $3 = median cost
  local mode="$1" station="$2" cost="$3"
  local dir="$ACCOUNTS_DIR/$2" claude_dir="$ACCOUNTS_DIR/$2/claude"
  local id ident email title reason brief repo branch slot out rc
  local n armed_here fits idx used_slots armed_hdr over_hdr
  local cap_word arms nobrief_n skipped_n refused_n st

  say "## $station"
  say ""
  if capacity_for "$claude_dir"; then
    n=$(runs_that_fit "$CAP_REMAINING" "$cost")
    cap_word="~${CAP_PCT}% left"
    say "- Capacity: ~${CAP_PCT}% of the block's output budget left ($CAP_REMAINING of $CAP_LIMIT tokens; $CAP_USED spent)"
    say "- Room for: $n run(s) at $cost tokens each (safety $SAFETY, cap $MAX_PER_CREW)"
  else
    n="$FALLBACK_N"
    [ "$n" -le "$MAX_PER_CREW" ] || n="$MAX_PER_CREW"
    cap_word="capacity unknown"
    say "- Capacity: **unknown** — ccusage could not account for \`$claude_dir\`"
    say "- Room for: $n run(s) — the conservative QM_FALLBACK_N default, not an estimate"
  fi
  say ""

  # This station's slice of the queue, split into the four things a crew member
  # needs to see. Kept in files rather than arrays: bash 3.2 has no dict.
  : > "$WORK/eligible"; : > "$WORK/nobrief"; : > "$WORK/skipped"; : > "$WORK/refused"
  armed_here=0
  while IFS="$TAB" read -r id ident email title; do
    [ -n "$ident" ] || continue
    [ "$(station_for "$email")" = "$station" ] || continue
    if ! safe_component "$ident"; then
      printf '%s\t%s\t%s\n' "$ident" "$title" \
        "the identifier is not usable as a run-dir name" >> "$WORK/skipped"
      continue
    fi
    if reason=$(skip_reason "$ident"); then
      printf '%s\t%s\t%s\n' "$ident" "$title" "$reason" >> "$WORK/skipped"
      case "$reason" in "already armed"*) armed_here=$((armed_here + 1)) ;; esac
      continue
    fi
    brief="$RUNS/$ident/brief.md"
    if [ ! -f "$brief" ]; then
      printf '%s\t%s\n' "$ident" "$title" >> "$WORK/nobrief"
      continue
    fi
    repo=$(brief_field "$brief" Repo)
    branch=$(brief_field "$brief" Branch)
    if [ -z "$repo" ] || [ -z "$branch" ]; then
      printf '%s\t%s\t%s\n' "$ident" "$title" \
        "the brief has no **Repo** / **Branch** header line" >> "$WORK/skipped"
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$ident" "$title" "$repo" "$branch" >> "$WORK/eligible"
  done < "$WORK/issues"

  # Slots already spent tonight count against N, which is what makes a second
  # run at 19:05 add nothing and hand out no colliding fire times.
  fits=$((n - armed_here))
  [ "$fits" -ge 0 ] || fits=0
  idx="$armed_here"; used_slots=0; armed_hdr=0; over_hdr=0; arms=""

  while IFS="$TAB" read -r id ident title repo branch; do
    [ -n "$ident" ] || continue
    slot=$(nth_time "$idx")
    if [ "$used_slots" -ge "$fits" ] || [ -z "$slot" ]; then
      if [ "$over_hdr" = 0 ]; then
        [ "$armed_hdr" = 0 ] || say ""
        say "### Beyond tonight's capacity"; say ""; over_hdr=1
      fi
      say "- \`$ident\` $title"
      continue
    fi
    if [ "$mode" != arm ]; then
      if [ "$armed_hdr" = 0 ]; then say "### Would arm"; say ""; armed_hdr=1; fi
      say "- **$slot** \`$ident\` $title — $repo ($branch)"
      arms="${arms:+$arms, }$ident $slot"
      idx=$((idx + 1)); used_slots=$((used_slots + 1))
      continue
    fi
    out=$(arm_ticket "$ident" "$repo" "$branch" "$slot" "$station" "$dir"); rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\t%s\t%s\n' "$ident" "$title" "$(printf '%s' "$out" | tail -1)" \
        >> "$WORK/refused"
      continue
    fi
    if [ "$armed_hdr" = 0 ]; then say "### Armed"; say ""; armed_hdr=1; fi
    say "- **$slot** \`$ident\` $title — $repo ($branch)"
    if ! linear_comment "$id" \
      "Armed for $slot by the quartermaster — \`$branch\` in \`$repo\`, on $station's station."; then
      say "  - (the Linear comment failed; the run is armed regardless)"
    fi
    arms="${arms:+$arms, }$ident $slot"
    idx=$((idx + 1)); used_slots=$((used_slots + 1))
  done < "$WORK/eligible"

  refused_n=$(count_of "$WORK/refused")
  if [ "$armed_hdr" = 0 ] && [ "$over_hdr" = 0 ] && [ "${refused_n:-0}" -eq 0 ]; then
    say "### Nothing to arm"
    say ""
    say "- No briefed, un-armed ticket is waiting for $station."
  fi
  say ""

  if [ "${refused_n:-0}" -gt 0 ]; then
    say "### Failed to arm"
    say ""
    while IFS="$TAB" read -r ident title reason; do
      [ -n "$ident" ] || continue
      say "- \`$ident\` $title — **schedule.sh refused**: $reason"
    done < "$WORK/refused"
    say ""
  fi

  nobrief_n=$(count_of "$WORK/nobrief")
  if [ "${nobrief_n:-0}" -gt 0 ]; then
    say "### Needs a brief"
    say ""
    while IFS="$TAB" read -r ident title; do
      [ -n "$ident" ] || continue
      say "- \`$ident\` $title — no \`runs/$ident/brief.md\`, so it cannot be armed"
    done < "$WORK/nobrief"
    say ""
  fi

  skipped_n=$(count_of "$WORK/skipped")
  if [ "${skipped_n:-0}" -gt 0 ]; then
    say "### Skipped"
    say ""
    while IFS="$TAB" read -r ident title reason; do
      [ -n "$ident" ] || continue
      say "- \`$ident\` $title — $reason"
    done < "$WORK/skipped"
    say ""
  fi

  st="$station · $cap_word · $n fit"
  if [ -n "$arms" ]; then
    if [ "$mode" = arm ]; then st="$st · armed $arms"; else st="$st · would arm $arms"; fi
  else
    if [ "$mode" = arm ] && [ "${refused_n:-0}" -gt 0 ]; then
      st="$st · armed nothing"
    else
      st="$st · nothing to arm"
    fi
  fi
  [ "${nobrief_n:-0}" -gt 0 ] && st="$st · ${nobrief_n} need a brief"
  [ "${skipped_n:-0}" -gt 0 ] && st="$st · ${skipped_n} skipped"
  [ "${refused_n:-0}" -gt 0 ] && st="$st · ${refused_n} failed to arm"
  line "$st"
  return 0
}

evening() {  # $1 = arm|report
  local mode="$1" today stamp n_issues stations station cost samples ident email title
  local row orphan_n station_mode

  today=$(date '+%Y-%m-%d')
  stamp=$(date '+%Y-%m-%d %H:%M:%S')
  mkdir -p "$QM_DIR" 2>/dev/null || fail "cannot create $QM_DIR"
  REPORT="$WORK/report.md"
  : > "$REPORT"

  # The queue is fetched once for the whole crew: the label-plus-assignee filter
  # is global, and the station falls out of the assignee's email.
  : > "$WORK/issues"
  if load_linear_key; then
    fetch_issues > "$WORK/issues" 2>/dev/null || : > "$WORK/issues"
  fi
  n_issues=$(count_of "$WORK/issues")

  SCHEDULE_LIST=""
  if [ -x "$SELF_DIR/schedule.sh" ]; then
    SCHEDULE_LIST=$("$SELF_DIR/schedule.sh" --list </dev/null 2>/dev/null) || SCHEDULE_LIST=""
  fi

  read -r cost samples <<EOF
$(median_cost)
EOF

  say "# Quartermaster — $today"
  say ""
  station_mode="$mode"
  if [ "$mode" = arm ]; then
    if [ -n "$LINEAR_PARTIAL_NOTE" ]; then
      station_mode=report
      say "Mode: **arm requested, not run** — the Linear queue is partial, so nothing was handed to \`schedule.sh\`."
    else
      say "Mode: **arm** — everything under \`Armed\` below was handed to \`schedule.sh\`."
    fi
  else
    say "Mode: **report** — nothing was armed. \`quartermaster.sh --arm\` acts on this."
  fi
  say "Generated: $stamp"
  say "Label: \`$TAG\` · safety $SAFETY · cap $MAX_PER_CREW per crew · times: $TIMES"
  if [ -n "$LINEAR_NOTE" ]; then
    say "Queue: **unavailable** — $LINEAR_NOTE. Everything below is capacity only."
  else
    say "Queue: $n_issues tagged issue(s), assigned, in backlog or unstarted."
    if [ -n "$LINEAR_PARTIAL_NOTE" ]; then
      say "  (**partial queue** — $LINEAR_PARTIAL_NOTE.)"
      line "partial queue: $LINEAR_PARTIAL_NOTE"
    fi
  fi
  say "Run cost: median $cost implementer output tokens over $samples sampled run(s)."
  if [ "$samples" -eq 0 ]; then
    say "  (no run history carries usage yet — this is the QM_DEFAULT_COST default.)"
  fi
  say ""
  line "median $cost tok/run"
  [ -z "$LINEAR_NOTE" ] || line "queue unavailable: $LINEAR_NOTE"

  stations=""
  if [ -d "$ACCOUNTS_DIR" ]; then
    for station in "$ACCOUNTS_DIR"/*/; do
      [ -d "$station" ] || continue
      stations="$stations$(basename "$station")
"
    done
  fi
  if [ -z "$stations" ]; then
    say "## No crew"
    say ""
    say "No station directories under \`$ACCOUNTS_DIR\` — there is nobody to dispatch for."
    say ""
    line "no crew stations under $ACCOUNTS_DIR"
  fi

  # fd 3 keeps the station list out of stdin, which schedule.sh, curl and npx
  # all inherit further down.
  while IFS= read -r station <&3; do
    [ -n "$station" ] || continue
    station_pass "$station_mode" "$station" "$cost"
  done 3<<EOF
$stations
EOF

  # Tagged and assigned, but the assignee has no station on this machine. Worth
  # a line of its own: that is a crew member nobody here can dispatch for, not
  # a defect in the queue.
  : > "$WORK/orphans"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    ident=$(printf '%s' "$row" | cut -f2)
    email=$(printf '%s' "$row" | cut -f3)
    title=$(printf '%s' "$row" | cut -f4)
    station=$(station_for "$email")
    if safe_component "$station" && [ -d "$ACCOUNTS_DIR/$station" ]; then continue; fi
    printf '%s\t%s\t%s\t%s\n' "$ident" "$title" "$email" "$station" >> "$WORK/orphans"
  done < "$WORK/issues"
  orphan_n=$(count_of "$WORK/orphans")
  if [ "${orphan_n:-0}" -gt 0 ]; then
    say "## Unknown stations"
    say ""
    while IFS="$TAB" read -r ident title email station; do
      [ -n "$ident" ] || continue
      say "- \`$ident\` $title — $email maps to \`$station\`, which has no directory under \`$ACCOUNTS_DIR\`"
    done < "$WORK/orphans"
    say ""
    line "$orphan_n ticket(s) for a station this machine does not have"
  fi

  say "---"
  say ""
  say "Capacity is estimated from each station's own Claude logs (\`ccusage blocks\`);"
  say "no model provider was contacted. Linear was read, and commented on only for"
  say "the tickets this run actually armed."

  cp "$REPORT" "$QM_DIR/$today.md" || fail "cannot write $QM_DIR/$today.md"
  cat "$QM_DIR/$today.md"
  echo "[quartermaster] report: $QM_DIR/$today.md"
  push_summary "$mode" "$today"
  return 0
}

push_summary() {  # $1 = mode, $2 = date
  local body
  body="$SUMMARY"
  [ -n "$body" ] || body="nothing to report
"
  if [ -z "${HARNESS_NTFY_TOPIC:-}" ]; then
    echo "[quartermaster] no HARNESS_NTFY_TOPIC in notify.conf — report file only"
    return 0
  fi
  capped "$NTFY_TIMEOUT" curl -s -H "Title: quartermaster $2 ($1)" -d "$body" \
    "${HARNESS_NTFY_SERVER:-https://ntfy.sh}/$HARNESS_NTFY_TOPIC" >/dev/null 2>&1 \
    || echo "[quartermaster] the ntfy push failed — the report file is still on disk"
  return 0
}

# ---------------------------------------------------------------------------
# The daily agent — schedule.sh's launchd conventions, minus the one-shot
# ---------------------------------------------------------------------------
shquote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

need_macos() {  # $1 = the mode that needs it
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || fail "$1 needs macOS (it manages a launchd LaunchAgent) — this is $(uname -s 2>/dev/null || echo an unknown OS).
Run quartermaster.sh --report from your own timer instead."
}

# launchd hands a job an almost empty environment, so the agent carries a
# snapshot of the shell that installed it — the same trick, for the same
# reason, as schedule.sh's wrapper. GH_TOKEN is not swept in: the per-station
# GH_CONFIG_DIR is what decides which account opens a PR.
env_names() {
  { compgen -e 2>/dev/null | grep -E '^(HARNESS|QM)_[A-Za-z0-9_]+$'
    printf '%s\n' HARNESS_DIR LINEAR_API_KEY_FILE HOME PATH
  } | sort -u
}

env_snapshot() {
  local n set_flag val
  for n in $(env_names); do
    eval "set_flag=\${$n+x}; val=\${$n:-}"
    [ -n "$set_flag" ] || continue
    printf 'export %s=' "$n"; shquote "$val"; printf '\n'
  done
}

write_agent_wrapper() {
  : > "$WRAPPER" || return 1
  chmod 600 "$WRAPPER" || return 1
  {
    cat <<EOF
#!/usr/bin/env bash
# Daily quartermaster wrapper — generated by quartermaster.sh, do not edit.
# Mode 600: it carries the environment snapshot of the shell that installed it.
set -u

QM=$(shquote "$SELF_DIR/quartermaster.sh")

$(env_snapshot)
EOF
    cat <<'EOF'

echo "[quartermaster] $(date '+%Y-%m-%d %H:%M:%S') waking up: $*"
exec "$QM" "$@"
EOF
  } >> "$WRAPPER"
}

write_agent_plist() {  # $1 = mode argument, $2 = hour, $3 = minute
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml_escape "$LABEL_ID")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml_escape "$WRAPPER")</string>
		<string>$(xml_escape "$1")</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$2</integer>
		<key>Minute</key>
		<integer>$3</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
</dict>
</plist>
EOF
}

install_agent() {  # $1 = the mode the agent runs in
  local hour minute
  need_macos "--install"
  case "$AT" in
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
    *) fail "QM_AT must be HH:MM — got [$AT]" ;;
  esac
  hour=$(printf '%s' "${AT%%:*}" | sed 's/^0//'); hour="${hour:-0}"
  minute=$(printf '%s' "${AT##*:}" | sed 's/^0//'); minute="${minute:-0}"
  { [ "$hour" -le 23 ] && [ "$minute" -le 59 ]; } || fail "QM_AT is not a time of day: [$AT]"

  mkdir -p "$QM_DIR" "$AGENTS_DIR" || fail "cannot create $QM_DIR / $AGENTS_DIR"
  # Re-installing is how the trust dial is flipped, so an existing agent is
  # replaced rather than refused.
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  write_agent_wrapper || fail "cannot write $WRAPPER"
  write_agent_plist "$1" "$hour" "$minute" || { rm -f "$WRAPPER" "$PLIST"; fail "cannot write $PLIST"; }
  launchctl bootstrap "gui/$(id -u)" "$PLIST" \
    || { rm -f "$WRAPPER" "$PLIST"; fail "launchctl could not load $PLIST"; }

  echo "[quartermaster] installed — every day at $AT, mode $1"
  echo "[quartermaster]   agent   $LABEL_ID"
  echo "[quartermaster]   wrapper $WRAPPER (mode 600 — holds an env snapshot)"
  echo "[quartermaster]   plist   $PLIST"
  echo "[quartermaster]   log     $AGENT_LOG"
  echo "[quartermaster]   reports $QM_DIR/<date>.md"
  if [ "$1" = "--report" ]; then
    echo "[quartermaster] It only reports. When you trust it, flip the dial:"
    echo "[quartermaster]   quartermaster.sh --install --arm"
    echo "[quartermaster] (or edit the third <string> in the plist and reload it)."
  fi
  echo "[quartermaster] Remove: quartermaster.sh --uninstall"
}

uninstall_agent() {
  need_macos "--uninstall"
  if [ ! -e "$PLIST" ] && [ ! -e "$WRAPPER" ]; then
    echo "[quartermaster] nothing installed"
    return 0
  fi
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$WRAPPER"
  echo "[quartermaster] uninstalled — agent, plist and wrapper removed (the reports in $QM_DIR are kept)"
}

# ---------------------------------------------------------------------------
main() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/quartermaster.XXXXXX") || fail "cannot create a work dir"
  case "${1:-}" in
    ''|--report) [ $# -le 1 ] || usage; evening report ;;
    --arm)       [ $# -eq 1 ] || usage; evening arm ;;
    --install)
      case "${2:---report}" in
        --report|--arm) [ $# -le 2 ] || usage; install_agent "${2:---report}" ;;
        *) echo "--install takes --report or --arm: $2" >&2; echo >&2; usage ;;
      esac
      ;;
    --uninstall) [ $# -eq 1 ] || usage; uninstall_agent ;;
    -h|--help)   usage ;;
    *)           echo "unknown option: $1" >&2; echo >&2; usage ;;
  esac
}

main "$@"
