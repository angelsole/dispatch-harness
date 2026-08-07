#!/usr/bin/env bash
# Multi-model dispatch pipeline.
#   Opus (Claude sub) implements in a git worktree
#   -> deterministic test gate
#   -> Codex (ChatGPT sub) reviews & fixes (max 2 rounds; optional — skipped
#      when the codex CLI is not installed)
#   -> draft PR.
#
# Usage: run-task.sh <TICKET> <repo-path> <branch-name>
# Expects the orchestrator to have written the brief at:
#   ~/.claude/harness/runs/<TICKET>/brief.md
set -u -o pipefail

# Whole script runs inside main() so bash parses it fully before executing —
# editing this file while a run is live can no longer corrupt that run.
main() {

HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"   # where schedule.sh lives, for deferrals
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || echo codex)}"
# The Codex reviewer is optional: a Claude subscription alone runs the same
# pipeline with the review stage skipped and base-sync conflicts resolved by a
# Claude worker. Resolved once per invocation so no stage ever shells out to a
# missing binary and logs a 127.
if command -v "$CODEX_BIN" >/dev/null 2>&1; then CODEX_AVAILABLE=1; else CODEX_AVAILABLE=0; fi
# Labels for the conflict-resolution stage line and the escalation text: they
# name whichever CLI actually does the work.
CONFLICT_AGENT="Codex, ChatGPT sub"; CONFLICT_MODEL="Codex"
[ "$CODEX_AVAILABLE" = 1 ] || { CONFLICT_AGENT="Claude sub"; CONFLICT_MODEL="Claude"; }

# Cap a long-running child. macOS ships no timeout(1), so fall back to a
# perl alarm wrapper (SIGALRM survives exec and kills the child after N secs).
with_timeout() {  # $1 = seconds, rest = command + args
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

usage() { echo "usage: run-task.sh <TICKET> <repo-path> <branch-name>" >&2; exit 2; }
[ $# -eq 3 ] || usage

TICKET="$1"; REPO="$2"; BRANCH="$3"
TICKET_LC=$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')
RUN_DIR="$HARNESS_DIR/runs/$TICKET"
BRIEF="$RUN_DIR/brief.md"

fail() { echo "FATAL: $*" >&2; write_result "$1" ""; stage "done: $1"; exit 1; }

[ -f "$BRIEF" ] || { echo "FATAL: no brief at $BRIEF" >&2; exit 1; }
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { echo "FATAL: $REPO is not a git repo" >&2; exit 1; }

# shellcheck source=repos.conf.sh
. "$HARNESS_DIR/repos.conf.sh"
repo_config "$REPO"   # sets BASE_BRANCH INSTALL_CMD GATE_CMD MCP_CONFIG ENV_SUBDIRS PREFLIGHT_CMD
# Keep the unset path independent of the optional library, including on an old
# install that predates mirror.sh.
if [ -n "${HARNESS_MIRROR:-}" ] && [ -r "$HARNESS_DIR/mirror.sh" ]; then
  # shellcheck source=mirror.sh
  . "$HARNESS_DIR/mirror.sh"   # HARNESS_MIRROR: mirror_start / mirror_stop
fi
# The capacity accountant behind the dispatch preflight below, shared with
# quartermaster.sh. Optional in exactly the way the preflight is: an install
# that predates it simply dispatches, like the harness always did.
if [ "${HARNESS_PREFLIGHT:-on}" != off ] && [ -r "$HARNESS_DIR/capacity.sh" ]; then
  # shellcheck source=capacity.sh
  . "$HARNESS_DIR/capacity.sh"   # capacity_for -> CAP_REMAINING / CAP_RESET
fi

WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$TICKET_LC"
BASE_REF="origin/$BASE_BRANCH"
mkdir -p "$RUN_DIR"
# From here the run dir exists, so another machine's wall can follow this run
# (HARNESS_MIRROR). Best-effort throughout, and stopped — after one last pass —
# on every exit path by the EXIT trap mirror_start installs.
if [ -n "${HARNESS_MIRROR:-}" ] && declare -F mirror_start >/dev/null; then
  mirror_start "$RUN_DIR" "$TICKET"
fi

# --- Ablation knobs, pinned at first dispatch --------------------------------
# The arm (full pipeline vs. review-skipped) and the implementer model are
# written into the run dir on the first invocation and reused verbatim on
# resume, so a re-dispatch whose environment differs can never silently switch
# a run to a different experimental condition.
ARM_FILE="$RUN_DIR/arm"
if [ -f "$ARM_FILE" ]; then
  ARM=$(cat "$ARM_FILE")
else
  # No codex CLI on this machine means no review stage — pin the same arm the
  # ablation knob does, so status, metrics and result.json all agree.
  if [ "${HARNESS_SKIP_REVIEW:-0}" = "1" ] || [ "$CODEX_AVAILABLE" = 0 ]; then ARM="no_review"; else ARM="full"; fi
  echo "$ARM" > "$ARM_FILE"
fi
# Model/effort knobs follow the same pin-at-first-dispatch rule. Defaults are
# explicit model IDs, never aliases: "opus" silently changed meaning the day
# Opus 5 shipped, which is exactly the condition drift this file exists to stop.
pin_knob() {  # $1 = file basename, $2 = var name, $3 = default
  local f="$RUN_DIR/$1" v
  if [ -f "$f" ]; then
    v=$(cat "$f")
  else
    eval "v=\"\${$2:-$3}\""
    echo "$v" > "$f"
  fi
  eval "$2=\"\$v\""
}
positive_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ] 2>/dev/null
}
pin_knob implementer-model  IMPLEMENTER_MODEL  claude-opus-5
pin_knob implementer-effort IMPLEMENTER_EFFORT xhigh
# A first dispatch without codex pins blank reviewer knobs. If codex is
# installed before a later resume, the run remains honestly review-less instead
# of silently acquiring reviewer metadata for a stage its pinned arm skips.
if [ "$CODEX_AVAILABLE" = 0 ]; then
  [ -f "$RUN_DIR/reviewer-model" ] || : > "$RUN_DIR/reviewer-model"
  [ -f "$RUN_DIR/reviewer-effort" ] || : > "$RUN_DIR/reviewer-effort"
fi
pin_knob reviewer-model REVIEWER_MODEL gpt-5.6-sol
pin_knob reviewer-effort REVIEWER_EFFORT high
# Who dispatched this run. Not an ablation knob — provenance, so the wall can
# group runs by the crew member who owns them — but the same pin-at-first-
# dispatch rule applies: resuming from someone else's station must not
# re-attribute a run. Station sessions export HARNESS_OWNER; an unset one pins
# empty and the run is simply unowned.
pin_knob owner HARNESS_OWNER ""

# The implementer's turn ceiling. `--max-turns` is a runaway-worker guard rail,
# not a verdict on the task: pinned at 120 it killed eight runs, nearly always at
# the finish line (writing the notes, `git add`), each recovered by a human
# re-dispatch that finished in minutes. Pinned like the model knobs, so every
# resume — including the automatic one below — spends the ceiling the run was
# dispatched with rather than whatever the resuming shell happens to export.
DEFAULT_MAX_TURNS=200
DEFAULT_MAX_RESUMES=2
pin_knob max-turns HARNESS_MAX_TURNS "$DEFAULT_MAX_TURNS"
MAX_TURNS="$HARNESS_MAX_TURNS"
# A garbled ceiling must neither reach the CLI (`--max-turns abc` is a usage
# error that kills the dispatch on the spot) nor become the run's pinned budget:
# say so once, fall back, and re-pin what the run actually used.
if ! positive_int "$MAX_TURNS"; then
  echo "[harness] HARNESS_MAX_TURNS='$MAX_TURNS' is not a positive integer — using $DEFAULT_MAX_TURNS"
  MAX_TURNS=$DEFAULT_MAX_TURNS
  echo "$MAX_TURNS" > "$RUN_DIR/max-turns"
fi
# How often turn exhaustion may resume itself before the run fails. Not pinned:
# like the deferral cap, it bounds this invocation's automation rather than the
# experimental condition, and 0 switches the self-resume off.
MAX_RESUMES="${HARNESS_MAX_RESUMES:-$DEFAULT_MAX_RESUMES}"
case "$MAX_RESUMES" in ''|*[!0-9]*) MAX_RESUMES=$DEFAULT_MAX_RESUMES ;; esac

# A Claude-only run resumed after codex is installed may still need Codex for
# base-sync conflicts. Use the normal defaults for that mechanical step while
# keeping the run's reviewer fields blank.
CODEX_MODEL="${REVIEWER_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${REVIEWER_EFFORT:-high}"
if [ "$CODEX_AVAILABLE" = 0 ]; then
  REVIEWER_MODEL=""
  REVIEWER_EFFORT=""
fi

STATUS="setup_failed"; GATE_STATUS="not_run"; PR_URL=""; OPUS_HEAD=""; OPUS_SESSION=""; DEMO_URL=""
# How the review stage actually went, decided from evidence after it runs (see
# section 5b): "" until the stage is reached, then skipped | reviewed |
# no_evidence | failed_silent. Recorded in result.json so nobody has to read
# logs to find out whether a diff was reviewed.
REVIEW_CLASS=""
# Which Codex subscription the review attempt ran on: primary | fallback, empty
# when no review attempt was made (the skipped arms). A label, never a path.
REVIEW_ACCOUNT=""

# Gather per-run quantitative metrics from the artefacts on disk. Every field is
# best-effort: called on EVERY exit path (including early failures), it emits
# whatever is available and nulls/empties the rest — partial metrics are fine.
collect_metrics() {
  local now started wall stage_durations gate_rounds turn_resumes opus_c codex_c
  local numstat files ins del impl
  now=$(date +%s)
  started=$(cat "$RUN_DIR/started" 2>/dev/null || echo "")
  if [ -n "$started" ]; then wall=$((now - started)); else wall=null; fi

  # Per-stage durations, summed across invocations by label. stage() appends an
  # "<epoch> <label>" line to stages.log; each invocation prepends an
  # "<epoch> __invocation__" marker so the wait between a needs_input pause and
  # the resume is not charged to the stage that was current when we paused.
  stage_durations='{}'
  if [ -f "$RUN_DIR/stages.log" ]; then
    stage_durations=$(jq -Rn --argjson now "$now" '
      [inputs | capture("^(?<e>[0-9]+) (?<label>.*)$")? | {e:(.e|tonumber), label}]
      | . as $r | (($r|length)-1) as $last
      | reduce range(0; $r|length) as $i ({};
          if $r[$i].label == "__invocation__" then .
          else
            (if $i == $last then ($now - $r[$i].e)
             elif $r[$i+1].label == "__invocation__" then 0
             else ($r[$i+1].e - $r[$i].e) end) as $d
            | .[$r[$i].label] = ((.[$r[$i].label] // 0) + (if $d > 0 then $d else 0 end))
          end)' "$RUN_DIR/stages.log" 2>/dev/null || echo '{}')
    [ -n "$stage_durations" ] || stage_durations='{}'
  fi

  # Gate history for this invocation, one line per round:
  #   "<round> <pass|fail> <seconds>\t<failed step>"
  # Seconds and the tab-separated step are optional in the pattern so a log left
  # by a run that predates the telemetry still parses (both come out null), and
  # so does the two-field shape any external reader may still write.
  gate_rounds='[]'
  if [ -f "$RUN_DIR/gate-rounds.log" ]; then
    gate_rounds=$(jq -Rn '[inputs
      | capture("^(?<round>[^ ]+) (?<result>[^ ]+)( (?<seconds>[0-9]+))?(\t(?<failed_step>.*))?$")?
      | {round, result,
         seconds: (if .seconds then (.seconds | tonumber) else null end),
         failed_step: (if (.failed_step // "") == "" then null else .failed_step end)}]' \
      "$RUN_DIR/gate-rounds.log" 2>/dev/null || echo '[]')
    [ -n "$gate_rounds" ] || gate_rounds='[]'
  fi

  # How often the implementer was resumed instead of started fresh. Counted from
  # the log rather than from stage_durations, which sums every resume under one
  # label and so can never say "three times".
  turn_resumes=0
  if [ -f "$RUN_DIR/stages.log" ]; then
    turn_resumes=$(awk '{ sub(/^[0-9]+ /, ""); if ($0 ~ /^resuming/) n++ } END { print n + 0 }' \
      "$RUN_DIR/stages.log" 2>/dev/null || echo 0)
    case "$turn_resumes" in ''|*[!0-9]*) turn_resumes=0 ;; esac
  fi

  # Commit attribution: base..opus_head is the implementer's, opus_head..HEAD is
  # the reviewer's. Null until opus_head exists (i.e. the implementer committed).
  opus_c=null; codex_c=null
  if [ -n "$OPUS_HEAD" ]; then
    local oc cc
    oc=$(git -C "$WORKTREE" rev-list --count "$BASE_REF..$OPUS_HEAD" 2>/dev/null || echo "")
    cc=$(git -C "$WORKTREE" rev-list --count "$OPUS_HEAD..HEAD" 2>/dev/null || echo "")
    [ -n "$oc" ] && opus_c=$oc
    [ -n "$cc" ] && codex_c=$cc
  fi

  # Diff size vs. base (three-dot, matching what the reviewer sees).
  files=null; ins=null; del=null
  numstat=$(git -C "$WORKTREE" diff --numstat "$BASE_REF...HEAD" 2>/dev/null || echo "")
  if [ -n "$numstat" ]; then
    read -r files ins del <<EOF
$(printf '%s\n' "$numstat" | awk 'NF{f++; if($1!="-")i+=$1; if($2!="-")d+=$2} END{print f+0, i+0, d+0}')
EOF
  fi

  # Implementer turns + token usage from the last result event of the latest
  # implementer run (fields may be absent on older CLIs — tolerate).
  impl='{}'
  if [ -f "$RUN_DIR/opus-stream.jsonl" ]; then
    impl=$(jq -s 'map(select(.type=="result")) | last // {}' "$RUN_DIR/opus-stream.jsonl" 2>/dev/null || echo '{}')
    [ -n "$impl" ] || impl='{}'
  fi

  jq -n \
    --argjson wall "$wall" \
    --argjson stage_durations "$stage_durations" \
    --argjson gate_rounds "$gate_rounds" \
    --argjson turn_resumes "$turn_resumes" \
    --argjson opus_commits "$opus_c" \
    --argjson codex_commits "$codex_c" \
    --argjson files "${files:-null}" --argjson ins "${ins:-null}" --argjson del "${del:-null}" \
    --argjson impl "$impl" \
    '{
      wall_seconds: $wall,
      stage_durations: $stage_durations,
      gate_rounds: $gate_rounds,
      turn_resumes: $turn_resumes,
      opus_commits: $opus_commits,
      codex_commits: $codex_commits,
      implementer_num_turns: ($impl.num_turns // null),
      implementer_usage: ($impl.usage // null),
      diff: {files_changed: $files, insertions: $ins, deletions: $del}
    }'
}

write_result() {
  local metrics
  metrics=$(collect_metrics)
  jq -n \
    --arg ticket "$TICKET" --arg status "$1" --arg gate "$GATE_STATUS" \
    --arg arm "$ARM" --arg review "$REVIEW_CLASS" --arg raccount "$REVIEW_ACCOUNT" \
    --arg model "$IMPLEMENTER_MODEL" --arg ieffort "$IMPLEMENTER_EFFORT" \
    --arg rmodel "$REVIEWER_MODEL" --arg reffort "$REVIEWER_EFFORT" \
    --arg worktree "$WORKTREE" --arg branch "$BRANCH" --arg base "$BASE_BRANCH" \
    --arg owner "${HARNESS_OWNER:-}" \
    --arg pr "${2:-}" --arg run_dir "$RUN_DIR" --arg opus_head "$OPUS_HEAD" --arg session "$OPUS_SESSION" --arg demo "$DEMO_URL" \
    --argjson metrics "$metrics" \
    '{ticket:$ticket,status:$status,owner:$owner,arm:$arm,review:$review,review_account:$raccount,implementer_model:$model,implementer_effort:$ieffort,reviewer_model:$rmodel,reviewer_effort:$reffort,gate:$gate,worktree:$worktree,branch:$branch,base:$base,pr_url:$pr,opus_head:$opus_head,opus_session:$session,demo_url:$demo,metrics:$metrics,logs:$run_dir}
     # The account label belongs to a review that happened: the arms that never
     # attempt one carry no field at all rather than an empty string nobody can
     # tell apart from "primary".
     | if .review_account == "" then del(.review_account) else . end' \
    > "$RUN_DIR/result.json"
}

# Live stage tracking: status (current), timeline (history), macOS notification
# on every model handoff, plus ntfy.sh push to the phone when notify.conf sets
# a topic. Disable local notifications with HARNESS_NOTIFY=0.
#
# CONTRACT: the stage TEXT below is parsed by prefix to decide which model owns
# the stage — see the actor mapping in statusline.sh (also used by
# status.sh --watch). Renaming a literal here silently degrades every
# statusline; add or update the mapping in the same commit.
# tests/statusline.test.sh asserts every literal maps to a known actor.
. "$HARNESS_DIR/notify.conf" 2>/dev/null || true
stage() {  # $1 = stage text, $2 = optional extra line for the phone push only
  echo "$(date +%s) $1" > "$RUN_DIR/status"
  printf '%s %s\n' "$(date +%s)" "$1" >> "$RUN_DIR/stages.log"   # epoch history for metrics
  echo "$(date '+%H:%M:%S') $1" >> "$RUN_DIR/timeline"
  echo "$1" > "$RUN_DIR/activity"
  echo "[harness] $1"
  if [ "${HARNESS_NOTIFY:-1}" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"dispatch $TICKET\"" 2>/dev/null || true
  fi
  if [ -n "${HARNESS_NTFY_TOPIC:-}" ]; then
    # The extra line is the push body's alone: status, stages.log, timeline and
    # activity stay byte-identical, so every stage-text contract (statusline,
    # wall, metrics) is untouched by anything said here.
    local body="$1"
    [ -n "${2:-}" ] && body="$1
$2"
    curl -s -m 5 -H "Title: dispatch $TICKET" -d "$body" \
      "${HARNESS_NTFY_SERVER:-https://ntfy.sh}/$HARNESS_NTFY_TOPIC" >/dev/null 2>&1 || true
  fi
}

# --- Capacity preflight: defer rather than burn a launch on an empty window ---
# Two dispatches once died instantly on "You've hit your session limit · resets
# 1:30pm" after paying for a worktree, a deps install and an implementer spawn,
# and the run recorded `implementer_failed` — indistinguishable from a real
# failure, and recovered by a human re-arming both. So before the expensive
# steps, ask the station's own Claude logs (capacity.sh: ccusage, local files,
# --offline, no endpoint anywhere) whether there is anything left to spend, and
# if there is not, arm the same run for just after the block resets.
#
# Advisory, never a blocker: anything ccusage cannot answer, anything
# schedule.sh refuses, and HARNESS_PREFLIGHT=off all fall through to a normal
# dispatch. The cap is what keeps that honest in the other direction — a run
# reschedules itself at most HARNESS_MAX_DEFERRALS times and then fails saying so.
DEFAULT_MIN_SESSION_TOKENS=20000
DEFAULT_DEFER_BUFFER_SECS=300
DEFAULT_MAX_DEFERRALS=2
MIN_SESSION_TOKENS="${HARNESS_MIN_SESSION_TOKENS:-$DEFAULT_MIN_SESSION_TOKENS}"  # output tokens one run wants
DEFER_BUFFER_SECS="${HARNESS_DEFER_BUFFER_SECS:-$DEFAULT_DEFER_BUFFER_SECS}"      # clearance past the reset
MAX_DEFERRALS="${HARNESS_MAX_DEFERRALS:-$DEFAULT_MAX_DEFERRALS}"                # then fail honestly
CLAUDE_LOGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"          # whose window this is
# A typo in a knob must not take the arithmetic down mid-dispatch, and the
# advisory default is the safe one to fall back to.
case "$MIN_SESSION_TOKENS" in ''|*[!0-9]*) MIN_SESSION_TOKENS=$DEFAULT_MIN_SESSION_TOKENS ;; esac
case "$DEFER_BUFFER_SECS"   in ''|*[!0-9]*) DEFER_BUFFER_SECS=$DEFAULT_DEFER_BUFFER_SECS ;; esac
case "$MAX_DEFERRALS"       in ''|*[!0-9]*) MAX_DEFERRALS=$DEFAULT_MAX_DEFERRALS ;; esac

capacity_note() {  # the preflight's own paper trail, off the dispatch's stdout
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$RUN_DIR/capacity.log"
}

# Arm this exact dispatch for later. schedule.sh snapshots the environment of
# the shell that calls it, and that shell is this run — so the deferred run
# fires with the identity, config dirs and knobs it was launched with, and looks
# on disk exactly like a human-armed one (marker, --list, quartermaster skip).
defer_arm() {  # $1 = <when> for schedule.sh
  ( export HARNESS_DIR
    exec "$SELF_DIR/schedule.sh" "$TICKET" "$REPO" "$BRANCH" "$1" ) </dev/null 2>&1
}

# The whole decision, shared by the preflight and the mid-run classifier.
# Requires CAP_RESET from a preceding capacity_for. Exits the run when it defers
# or when the cap is spent; RETURNS when it could not defer, and the caller then
# carries on exactly as it would have without this feature.
defer_for_capacity() {  # $1 = which path we came in on
  local n now target when hhmm
  n=$(cat "$RUN_DIR/deferrals" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac

  if [ -z "${CAP_RESET:-}" ]; then
    capacity_note "$1: no reset time from ccusage — dispatching anyway"
    echo "[harness] preflight: capacity is spent but ccusage gave no reset time — dispatching anyway"
    return 0
  fi
  if [ "$n" -ge "$MAX_DEFERRALS" ]; then
    capacity_note "$1: already deferred $n time(s) — failing instead of rescheduling again"
    STATUS="capacity_failed"; write_result "$STATUS" ""
    stage "done: capacity_failed"
    echo "[harness] session capacity is spent and this run has already been deferred $n time(s)"
    echo "[harness] not rescheduling again — re-dispatch it yourself once the window is back"
    exit 1
  fi

  now=$(date +%s)
  target=$((CAP_RESET + DEFER_BUFFER_SECS))
  # A reset already behind us (or a minute away, which schedule.sh rounds into
  # the past) means the block turned over while we were looking at it.
  [ "$target" -gt "$((now + 60))" ] || target=$((now + DEFER_BUFFER_SECS))
  when=$(capacity_stamp "$target" '%Y-%m-%d %H:%M')
  hhmm=$(capacity_stamp "$target" '%H:%M')
  if ! defer_arm "$when" > "$RUN_DIR/deferral.log" 2>&1; then
    capacity_note "$1: schedule.sh refused to arm for $when — dispatching anyway"
    echo "[harness] preflight: could not arm a deferral (see $RUN_DIR/deferral.log) — dispatching anyway"
    return 0
  fi
  echo "$((n + 1))" > "$RUN_DIR/deferrals"
  capacity_note "$1: deferred to $when (deferral $((n + 1)) of $MAX_DEFERRALS)"
  STATUS="deferred_capacity"; write_result "$STATUS" ""
  stage "deferred: capacity, armed for $hhmm"
  echo "[harness] session capacity is spent — armed for $when (deferral $((n + 1)) of $MAX_DEFERRALS)"
  exit 0
}

# Runs before the worktree, so a deferral costs nothing at all. Returns to
# proceed; never returns when it defers.
capacity_preflight() {
  [ "${HARNESS_PREFLIGHT:-on}" != off ] || return 0
  declare -F capacity_for >/dev/null 2>&1 || return 0
  if ! capacity_for "$CLAUDE_LOGS"; then
    capacity_note "preflight: unknown — ccusage could not account for $CLAUDE_LOGS"
    echo "[harness] preflight: capacity unknown (ccusage unavailable for $CLAUDE_LOGS) — dispatching"
    return 0
  fi
  if [ "$CAP_REMAINING" -ge "$MIN_SESSION_TOKENS" ]; then
    capacity_note "preflight: ok — $CAP_REMAINING of $CAP_LIMIT output tokens left (floor $MIN_SESSION_TOKENS)"
    return 0
  fi
  capacity_note "preflight: only $CAP_REMAINING of $CAP_LIMIT output tokens left (floor $MIN_SESSION_TOKENS)"
  defer_for_capacity preflight
  return 0
}

# Belt to the braces for the window emptying *during* a run. The brief names the
# live feed and stderr as evidence; opus.log adds the CLI's final result message,
# which the feed deliberately reduces to a generic result marker.
session_limit_hit() {
  local pattern='(session|usage|[0-9]+-hour) limit reached|hit your (session|usage) limit'
  grep -qiE "$pattern" "$RUN_DIR/opus-stderr.log" "$RUN_DIR/opus.log" 2>/dev/null \
    && return 0
  # feed.log spans resumed invocations. Only the lines written by this
  # implementer attempt are evidence for this attempt's non-zero exit.
  tail -n "+${OPUS_FEED_START_LINE:-1}" "$RUN_DIR/feed.log" 2>/dev/null \
    | grep -qiE "$pattern"
}

# The other way an implementer stops with work still on the bench: it ran out of
# turns. Structured evidence rather than prose — the CLI's final result event
# carries subtype "error_max_turns" — with the stderr text as a fallback for a
# process that never got to write one. opus-stream.jsonl is rewritten by every
# attempt, so this only ever answers for the attempt that just ended.
max_turns_hit() {
  jq -e -s 'map(select(.type == "result")) | (last // {}) | .subtype == "error_max_turns"' \
    "$RUN_DIR/opus-stream.jsonl" >/dev/null 2>&1 && return 0
  grep -qiE 'max(imum)? (number of )?turns' "$RUN_DIR/opus-stderr.log" 2>/dev/null
}

date +%s > "$RUN_DIR/started"
# Metrics bookkeeping: a per-invocation marker segments stages.log so resume
# pauses aren't charged to a stage; gate-rounds.log is fresh each invocation
# (a resumed run re-runs its gates, so stale rounds would double-count), and so
# is the turn-resume counter — this invocation starts with a full budget.
printf '%s __invocation__\n' "$(date +%s)" >> "$RUN_DIR/stages.log"
: > "$RUN_DIR/gate-rounds.log"
rm -f "$RUN_DIR/turn-resumes"
echo "$WORKTREE" > "$RUN_DIR/worktree"
echo "$BASE_REF" > "$RUN_DIR/base"
echo "[harness] $TICKET -> $REPO ($BRANCH from $BASE_REF)"

capacity_preflight

stage "setup: worktree"

# --- 1. Worktree ------------------------------------------------------------
git -C "$REPO" fetch origin --quiet || fail setup_failed "git fetch failed"
if [ -d "$WORKTREE" ]; then
  echo "[harness] reusing existing worktree $WORKTREE"
elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" worktree add "$WORKTREE" "$BRANCH" || fail setup_failed "worktree add (existing branch) failed"
else
  git -C "$REPO" worktree add "$WORKTREE" -b "$BRANCH" "$BASE_REF" || fail setup_failed "worktree add failed"
fi

# Untracked env files don't travel with worktrees; copy them from the main checkout.
for d in "." $ENV_SUBDIRS; do
  find "$REPO/$d" -maxdepth 1 -name ".env*" -type f 2>/dev/null | while read -r f; do
    cp -n "$f" "$WORKTREE/$d/" 2>/dev/null || true
  done
done

# --- 2. Context mount: brief travels inside the worktree, git-excluded -------
# Specs are the brief's source documents: office files (docx/xlsx/pdf/…) the
# planner converted to markdown into the run dir, so the workers can read the
# spec the brief was written from. When the run dir has them, the mount is
# replaced wholesale rather than merged into — a revised spec set that dropped
# or renamed a file must not leave the stale one behind for a resumed worker to
# mine (same class of bug as a stale REJECTED.md outliving the revision it
# judged). When it has none the whole helper is a no-op, mounting nothing and
# unmounting nothing, so a run that never had specs behaves exactly as it did
# before this existed. Withdrawing specs mid-run is therefore done by emptying
# $RUN_DIR/specs, not by deleting it.
mount_specs() {  # $1 = run dir, $2 = worktree
  [ -d "$1/specs" ] || return 0
  rm -rf "${2:?}/.harness/specs" || return 1
  mkdir -p "$2/.harness/specs" && cp -R "$1/specs/." "$2/.harness/specs/"
}

mkdir -p "$WORKTREE/.harness"
cp "$BRIEF" "$WORKTREE/.harness/brief.md"
rm -f "$WORKTREE/.harness/QUESTIONS.md"   # stale questions would re-trigger needs_input
mount_specs "$RUN_DIR" "$WORKTREE" \
  || fail setup_failed "could not mount $RUN_DIR/specs at $WORKTREE/.harness/specs"
EXCLUDE_FILE="$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
grep -qx '.harness/' "$EXCLUDE_FILE" 2>/dev/null || echo '.harness/' >> "$EXCLUDE_FILE"

# --- 3. Install deps ---------------------------------------------------------
if [ -n "$INSTALL_CMD" ]; then
  stage "setup: installing deps"
  (cd "$WORKTREE" && bash -c "$INSTALL_CMD") > "$RUN_DIR/install.log" 2>&1 \
    || fail setup_failed "install failed (see $RUN_DIR/install.log)"
fi

# --- 3b. Gate preflight: repo-specific environment checks (e.g. test DB up) --
# Fails fast BEFORE burning an implementer pass on an environment the gate
# cannot pass in.
if [ -n "${PREFLIGHT_CMD:-}" ]; then
  stage "setup: gate preflight"
  (cd "$WORKTREE" && bash -c "$PREFLIGHT_CMD") > "$RUN_DIR/preflight.log" 2>&1 \
    || fail setup_failed "gate preflight failed (see $RUN_DIR/preflight.log)"
fi

# --- 3c. Pre-production posture (PREPROD=1 pinned in repos.local.sh) ---------
# A repo that has not shipped yet wants the opposite defaults from a mature one:
# delete obsolete paths rather than preserve them. Both models default to
# conservative, compatibility-preserving changes, so the posture goes to BOTH —
# a reviewer left on the default checklist would demand back-compat shims the
# implementer was told not to write. An AGENTS.md in the target repo cannot
# cover this: a greenfield first dispatch starts from a tree the implementer
# itself scaffolds, so there is nothing to read yet.
# Empty unless pinned, which leaves both prompts byte-identical to a run without
# this feature.
PREPROD_POSTURE=""; PREPROD_POSTURE_REVIEW=""
if [ "${PREPROD:-}" = "1" ]; then
  PREPROD_POSTURE="

This repo is NOT in production yet. Work under this posture:
- Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers: start from the smallest version that works end to end; never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries over reimplementing common functionality.
- Lean on the dependencies already in the project before writing your own implementation or adding packages; do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term; do not accept a stopgap that only works for now and is meant to be replaced later."
  PREPROD_POSTURE_REVIEW="$PREPROD_POSTURE
- Judge the diff under this posture: do NOT request backward-compatibility shims, fallbacks, or migration paths for pre-production code."
fi

# --- 4. Opus implements (Claude subscription: ANTHROPIC_API_KEY unset) -------
IMPLEMENTER_PROMPT="You are the implementer stage of an automated pipeline.
Read .harness/brief.md first — it is your task contract — then follow this repo's CLAUDE.md conventions.
If .harness/specs/ exists, it holds the task's source documents (office files the planner converted to markdown) — they are part of the contract too, so read them alongside the brief; the brief says what to take from each.
Rules:
- Implement the brief fully. You own the implementation design; plan as you see fit.
- Delegate to subagents (Explore — they run on a cheaper model) only for sizeable, genuinely independent exploration such as a wide multi-file investigation. Do not delegate what a few tool calls of your own would answer, and never use subagents to verify or double-check your own work.
- Leave the tree passing the verify commands from the brief.
- Never weaken, skip, or delete tests to make them pass; if a test seems wrong, say so in your notes instead.
- Make small conventional commits (type(scope): description). Never mention AI, Claude, or agents in commits.
- Never git add or commit anything under .harness/ — it is orchestration metadata, excluded from git. If git refuses a path as ignored, leave it alone; never use git add -f.
- Do NOT push, do NOT create PRs, do NOT switch branches.
- Database/MCP tools: local environment only. Never switch environments or touch staging/production.
- If you hit a decision the brief does not resolve and that materially changes the outcome, do NOT guess: write the specific question(s), each with the options you considered, to .harness/QUESTIONS.md and stop working. The orchestrator will get answers and resume you.
- If the brief contains a 'Demo storyboard' section, also write .harness/demo.yml exactly as that section specifies — a shot-scraper storyboard (server + url + scenes) demonstrating the feature you built. Never commit it.
- When finished, write .harness/implementer-notes.md: what you changed, key decisions, deviations from the brief, and what the reviewer should scrutinize. Keep it tight — substance only, no filler; it becomes the PR body.$PREPROD_POSTURE"

# Every continuation message restates the commit rules. A resumed session has
# its original instructions far behind it in a long context, and two resumes in
# one day re-added `Co-Authored-By: Claude` trailers their first pass had never
# written — one caught by hand, one by the reviewer, and a no_review arm would
# have shipped them. This is the cheap half of the fix; the deterministic strip
# after the stage is the half that does not depend on a model reading it.
RESUME_RULES="These rules from your original instructions are still binding:
- Make small conventional commits (type(scope): description).
- Never mention AI, Claude, or agents in commits — no Co-Authored-By, no Generated-with, no attribution trailer of any kind, in the subject, the body or the footer.
- Never git add or commit anything under .harness/; never use git add -f.
- Do NOT push, do NOT create PRs, do NOT switch branches."

# Worker sessions are resumable: we pin the session id so the user can step in
# interactively at any time (attach.sh), and so a re-dispatch after needs_input
# continues with the worker's context intact. After each run the id is refreshed
# from the stream's result event, since --resume forks to a new session id.
OPUS_SESSION_FILE="$RUN_DIR/opus-session"
CLAUDE_ARGS=(--model "$IMPLEMENTER_MODEL" --effort "$IMPLEMENTER_EFFORT" --settings "$HARNESS_DIR/worker-settings.json" --permission-mode acceptEdits --max-turns "$MAX_TURNS")
[ -n "$MCP_CONFIG" ] && CLAUDE_ARGS=("${CLAUDE_ARGS[@]}" --mcp-config "$MCP_CONFIG")

# One implementer attempt: leaves OPUS_EXIT, the worker's final message and the
# refreshed session id behind. Stream events go to the statusline and feed.log
# so a run shows live what the worker is doing (tool by tool); the raw stream is
# kept for debugging — and, being rewritten per attempt, is also what the
# failure classifiers read to judge the attempt that has just ended.
opus_attempt() {  # $1 = prompt, rest = session args (--session-id / --resume)
  local prompt="$1" new_session; shift
  # Remember where this attempt starts in the append-only live feed so an older
  # limit message cannot classify a later, unrelated failure as capacity.
  OPUS_FEED_START_LINE=1
  if [ -f "$RUN_DIR/feed.log" ]; then
    OPUS_FEED_START_LINE=$(( $(wc -l < "$RUN_DIR/feed.log") + 1 ))
  fi
  (cd "$WORKTREE" && env -u ANTHROPIC_API_KEY CLAUDE_CODE_SUBAGENT_MODEL=sonnet \
      "$CLAUDE_BIN" -p "$prompt" "${CLAUDE_ARGS[@]}" "$@" \
      --output-format stream-json --verbose </dev/null 2> "$RUN_DIR/opus-stderr.log") \
    | tee "$RUN_DIR/opus-stream.jsonl" \
    | jq --unbuffered -r '
        if .type == "assistant" then
          (.message.content[]? |
            if .type == "tool_use" then
              "⏺ \(.name) \((.input.file_path // .input.command // .input.pattern // "") | tostring | .[0:90])"
            elif .type == "thinking" then
              "🧠 \((.thinking // "") | gsub("\\s+"; " ") | .[0:90])"
            elif .type == "text" then
              "💬 \((.text // "") | gsub("\\s+"; " ") | .[0:90])"
            else empty end)
        elif .type == "result" then "🏁 \(.subtype // "done")"
        else empty end' \
    | while IFS= read -r line; do
        printf '%s %s\n' "$(date '+%H:%M:%S')" "$line" >> "$RUN_DIR/feed.log"
        printf '%s\n' "$line" > "$RUN_DIR/activity"
      done
  OPUS_EXIT=${PIPESTATUS[0]}
  # Extract the worker's final message and the (possibly forked) session id.
  jq -r 'select(.type == "result") | .result // empty' "$RUN_DIR/opus-stream.jsonl" > "$RUN_DIR/opus.log" 2>/dev/null || true
  new_session=$(jq -r 'select(.type == "result") | .session_id // empty' "$RUN_DIR/opus-stream.jsonl" 2>/dev/null | tail -1)
  if [ -n "$new_session" ]; then
    OPUS_SESSION="$new_session"
    echo "$OPUS_SESSION" > "$OPUS_SESSION_FILE"
  fi
}

# The implementer left nothing shippable behind. One predicate for both the
# turn-ceiling loop below and the failure branch after it, so they can never
# disagree about what "it did not finish" means.
opus_incomplete() {
  [ "$OPUS_EXIT" -ne 0 ] || [ -z "$(git -C "$WORKTREE" log "$BASE_REF"..HEAD --oneline 2>/dev/null)" ]
}

if [ -f "$OPUS_SESSION_FILE" ]; then
  OPUS_SESSION=$(cat "$OPUS_SESSION_FILE")
  OPUS_PROMPT="The orchestrator updated .harness/brief.md — it now contains answers to your questions and/or revision notes. Re-read it and, if .harness/specs/ exists, re-read those source documents too before continuing under the same rules as before.

$RESUME_RULES"
  SESSION_ARGS=(--resume "$OPUS_SESSION")
  stage "resuming — Opus (Claude sub)"
else
  OPUS_SESSION=$(uuidgen | tr '[:upper:]' '[:lower:]')
  echo "$OPUS_SESSION" > "$OPUS_SESSION_FILE"
  OPUS_PROMPT="$IMPLEMENTER_PROMPT"
  SESSION_ARGS=(--session-id "$OPUS_SESSION")
  stage "implementing — Opus (Claude sub)"
fi
opus_attempt "$OPUS_PROMPT" "${SESSION_ARGS[@]}"

# --- 4b. Turn ceiling: resume rather than die at the finish line -------------
# Turn exhaustion is a budget running out, not a task that failed, and it lands
# almost exclusively during the wrap-up — so the recovery has always been the
# same: re-dispatch, which resumes the pinned session and finishes in minutes.
# Do that here instead of making a person notice. Same session, same worktree,
# same pinned ceiling; MAX_RESUMES bounds it, and only then is the run failed.
#
# ORDERING: the capacity classifier owns any session-limit death — it is checked
# FIRST, so an empty window defers (below) instead of spending a turn-resume on
# a session that cannot spawn anyway. A pending QUESTIONS.md wins too: a worker
# that stopped to ask must not be talked over.
TURN_RESUME_PROMPT="You stopped because you ran out of turns, not because the work is done. This is the same session, resumed with a fresh turn budget. Check what is already committed (git log, git status) before redoing anything, then finish the task under the same rules as before: leave the tree passing the brief's verify commands and write .harness/implementer-notes.md.

$RESUME_RULES"

TURN_RESUMES=0
while opus_incomplete && [ "$TURN_RESUMES" -lt "$MAX_RESUMES" ] \
      && [ ! -f "$WORKTREE/.harness/QUESTIONS.md" ] \
      && ! session_limit_hit && max_turns_hit; do
  TURN_RESUMES=$((TURN_RESUMES + 1))
  echo "$TURN_RESUMES" > "$RUN_DIR/turn-resumes"
  stage "resuming: turn ceiling ($TURN_RESUMES/$MAX_RESUMES)"
  opus_attempt "$TURN_RESUME_PROMPT" --resume "$OPUS_SESSION"
done

if [ -f "$WORKTREE/.harness/QUESTIONS.md" ]; then
  cp "$WORKTREE/.harness/QUESTIONS.md" "$RUN_DIR/QUESTIONS.md"
  STATUS="needs_input"; write_result "$STATUS" ""
  stage "waiting — implementer needs your input (QUESTIONS.md)"
  exit 3
fi
if opus_incomplete; then
  # A window that emptied mid-run is a capacity event, not a failed implementer.
  # The CLI's message is only the trigger; the reset time comes from ccusage, so
  # nothing here depends on parsing prose that Anthropic is free to reword.
  if [ "$OPUS_EXIT" -ne 0 ] && [ "${HARNESS_PREFLIGHT:-on}" != off ] \
     && declare -F capacity_for >/dev/null 2>&1 && session_limit_hit; then
    capacity_note "mid-run: the implementer stopped on a session limit"
    capacity_for "$CLAUDE_LOGS" || true   # the headroom is moot; CAP_RESET is not
    defer_for_capacity mid-run            # returns only when it could not defer
  fi
  STATUS="implementer_failed"; write_result "$STATUS" ""
  stage "done: implementer_failed"
  echo "[harness] implementer failed (exit $OPUS_EXIT, see opus-stderr.log / feed.log in $RUN_DIR)"; exit 1
fi

# --- 4c. Commit hygiene backstop (script — no model) -------------------------
# The prompts have always said not to sign commits with the model's name, and
# resumed sessions have twice done it anyway: one trailer was caught by hand,
# one by the reviewer, and a no_review arm would have shipped it. So stop hoping
# and make it true — mechanically, on every arm, before the branch can become a
# PR. Only the MESSAGES of the offending commits in base..HEAD are rewritten:
# each new commit reuses the original tree object verbatim, the working copy is
# never touched, and a range with nothing to strip is left byte-identical.
#
# Two shapes, because a trailer can name the model in either half: a `Claude-*:`
# key goes whatever it carries, while a generic key (`Co-Authored-By:` and kin)
# goes only when its VALUE names the model — so a genuine human co-author, the
# one thing here that must never be touched, survives.
AI_ATTRIBUTION_RE='^[[:space:]]*claude-[a-z-]*[[:space:]]*:|^[[:space:]]*(co-authored-by|assisted-by|session-id|generated-by|generated-with)[[:space:]]*:[[:space:]]*.*(claude|anthropic)|^[[:space:]]*(🤖[[:space:]]*)?generated with .*(claude|anthropic)'

strip_ai_attribution() {
  local all_messages commits c tree parents parent mapped msg cleaned new old_head new_head
  local an ae ad cn ce ct i parent_changed n=0
  local -a old_commits=() new_commits=() pargs=()
  all_messages=$(git -C "$WORKTREE" log --format='%B' "$BASE_REF..HEAD" 2>/dev/null) \
    || return 1
  printf '%s\n' "$all_messages" | grep -qiE "$AI_ATTRIBUTION_RE" || return 0
  old_head=$(git -C "$WORKTREE" rev-parse HEAD) || return 1
  # Parents precede their children, including across merges. Keep an old -> new
  # map so each changed parent can be substituted without flattening the DAG.
  # Commits whose message and parents are unchanged are reused verbatim; among
  # other things, that preserves signatures and nonstandard headers on clean
  # commits before or beside the first offender.
  commits=$(git -C "$WORKTREE" rev-list --reverse --topo-order "$BASE_REF..HEAD" 2>/dev/null) \
    || return 1
  for c in $commits; do
    tree=$(git -C "$WORKTREE" rev-parse "$c^{tree}") || return 1
    parents=$(git -C "$WORKTREE" show -s --format=%P "$c") || return 1
    pargs=(); parent_changed=0
    for parent in $parents; do
      mapped="$parent"
      for ((i=0; i<${#old_commits[@]}; i++)); do
        if [ "${old_commits[$i]}" = "$parent" ]; then
          mapped="${new_commits[$i]}"
          break
        fi
      done
      [ "$mapped" = "$parent" ] || parent_changed=1
      pargs+=(-p "$mapped")
    done
    msg=$(git -C "$WORKTREE" log -1 --format=%B "$c") || return 1
    cleaned=$(printf '%s\n' "$msg" | grep -ivE "$AI_ATTRIBUTION_RE")
    if [ "$cleaned" != "$msg" ]; then n=$((n + 1)); else cleaned="$msg"; fi
    if [ "$cleaned" = "$msg" ] && [ "$parent_changed" = 0 ]; then
      new="$c"
      old_commits+=("$c"); new_commits+=("$new")
      continue
    fi
    IFS=$'\x1f' read -r an ae ad cn ce ct <<EOF
$(git -C "$WORKTREE" log -1 --format='%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI' "$c")
EOF
    new=$(printf '%s\n' "$cleaned" | \
      GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
      GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" GIT_COMMITTER_DATE="$ct" \
      git -C "$WORKTREE" commit-tree "$tree" "${pargs[@]}") || return 1
    old_commits+=("$c"); new_commits+=("$new")
  done
  [ "$n" -gt 0 ] || return 1
  new_head=''
  for ((i=0; i<${#old_commits[@]}; i++)); do
    if [ "${old_commits[$i]}" = "$old_head" ]; then
      new_head="${new_commits[$i]}"
      break
    fi
  done
  [ -n "$new_head" ] || return 1
  # HEAD is symbolic, so this moves the branch and nothing else: identical trees
  # mean the index and the working copy still match, dirty or not.
  git -C "$WORKTREE" update-ref -m 'harness: strip AI attribution' HEAD "$new_head" "$old_head" \
    || return 1
  all_messages=$(git -C "$WORKTREE" log --format='%B' "$BASE_REF..HEAD" 2>/dev/null) \
    || return 1
  printf '%s\n' "$all_messages" | grep -qiE "$AI_ATTRIBUTION_RE" && return 1
  echo "[harness] commit hygiene: stripped AI attribution from $n commit message(s) — trees untouched"
}
strip_ai_attribution
HYGIENE_EXIT=$?
[ "$HYGIENE_EXIT" -eq 0 ] \
  || fail implementer_failed "commit hygiene could not remove AI attribution from $BASE_REF..HEAD"

# Everything up to this commit is Opus's work; later commits are Codex's.
OPUS_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
echo "$OPUS_HEAD" > "$RUN_DIR/opus-head"

# --- 5. Gate + Codex review/fix loop ------------------------------------------
# Which step of the gate died. Three quarters of runs need a second gate round,
# and until now the only record was "fail" — never WHICH command failed, so
# nobody could say what to fix first.
#
# The gate's own shell is the exact source: a DEBUG trap records each top-level
# command right before it runs, so at exit the file holds the command the chain
# stopped on — and in an `&&` chain, that IS the first failing step. The
# alternatives are both worse. Splitting GATE_CMD on `&&` and running the
# segments ourselves changes how the gate runs (a `cd backend && npm test` chain
# would lose its directory) and cannot be done safely by text (`&&` inside a
# quoted argument). Scraping "the last command line" out of gate-N.log assumes
# the gate echoes its commands, which `npm test` and `pytest` do not. This costs
# one file write per top-level command, leaves the gate log byte-identical, and
# parses nothing.
#
# Redirected to its own file, never to the log, so the reviewer's gate-latest.log
# is exactly what it always was. `|| :` keeps a failed write from ever being
# visible to the gate.
GATE_TRACE_PRELUDE='trap '\''printf "%s\n" "$BASH_COMMAND" > "$HARNESS_GATE_STEP" 2>/dev/null || :'\'' DEBUG'

run_gate() {
  local rc started secs step script failed_step
  stage "test gate #$1 (deterministic — no model)"
  step="$RUN_DIR/gate-$1.step"
  : > "$step"
  script="$GATE_TRACE_PRELUDE
$GATE_CMD"
  started=$(date +%s)
  (cd "$WORKTREE" && HARNESS_GATE_STEP="$step" bash -c "$script") > "$RUN_DIR/gate-$1.log" 2>&1
  rc=$?
  secs=$(( $(date +%s) - started ))
  tail -100 "$RUN_DIR/gate-$1.log" > "$WORKTREE/.harness/gate-latest.log"
  if [ $rc -eq 0 ]; then GATE_STATUS="pass"; else GATE_STATUS="fail"; fi
  # Only a failing round has a failing step; a passing round's last command
  # explains nothing, and recording it would invite exactly that misreading.
  failed_step=""
  if [ "$GATE_STATUS" = fail ]; then
    failed_step=$(tr -d '\t' < "$step" 2>/dev/null | head -1)
  fi
  # Additive: the first two fields are byte-for-byte what they were, so every
  # existing reader (wall/server.js splits on whitespace and takes two) is
  # unaffected; the step is tab-separated because a command contains spaces.
  printf '%s %s %s\t%s\n' "$1" "$GATE_STATUS" "$secs" "$failed_step" \
    >> "$RUN_DIR/gate-rounds.log"
  return $rc
}

GIT_COMMON=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)
# codex exec must never inherit our stdin: in a background run it is a pipe
# that never closes, and codex blocks forever on "Reading additional input
# from stdin..." (bit us in production). </dev/null fixes the cause;
# with_timeout is the backstop cap (timeout(1), or a perl-alarm fallback).
CODEX_TIMEOUT="${CODEX_TIMEOUT:-3600}"

# --- Which Codex subscription an attempt runs on ------------------------------
# A dry primary workspace turned six hours of reviews into honestly-flagged
# no-ops. codex auth is entirely CODEX_HOME-directory-scoped, so a second
# account is one more config dir (`CODEX_HOME=<dir> codex login`) plus a rule
# about when to reach for it. Unset knob: nothing below ever fires and the run
# is byte-for-byte the run it always was.
#
# ONE ATTEMPT, ONE ACCOUNT. CODEX_HOME is chosen before an attempt starts and
# never changed while it runs. The switch is sticky and only ever moves the
# NEXT attempt, so the review retry, the fix round and base-sync conflict
# resolution all follow wherever the review ended up.
CODEX_HOME_FALLBACK="${HARNESS_CODEX_HOME_FALLBACK:-}"
CODEX_ACCOUNT="primary"   # primary | fallback — a label, never a path
CODEX_PRIMARY_DRY=0       # the primary answered "out of credits" at least once

# The workspace-credits error is certainty rather than a guess: retrying the
# same account cannot possibly work. Matched case-insensitively on
# whitespace-flattened output, so a message the CLI wrapped across lines (or
# indented inside a box) still counts.
codex_out_of_credits() {  # $1 = an attempt's log
  [ -f "$1" ] || return 1
  tr -s '[:space:]' ' ' < "$1" | grep -qiE 'out of credits'
}

# Live feed for the second half of the pipeline. The implementer's stream-json
# events are appended to feed.log below as "HH:MM:SS <emoji> …"; without this the
# feed went dark the moment the implementer stopped, even though the reviewer
# still had two rounds to run. Same timestamp prefix, a ◆ marker plus the model
# name so `tail -f feed.log` stays live across both model stages.
feed() {  # $1 = marker + model, $2 = line
  printf '%s %s %.100s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$RUN_DIR/feed.log"
}

run_codex() {  # $1 = round label, $2 = prompt
  local log="$RUN_DIR/codex-$1.log" rc
  # env(1) sits between the timeout and the CLI because with_timeout is a shell
  # function: env cannot exec one. Empty on the primary, so the command line is
  # exactly what it has always been.
  local home=()
  [ "$CODEX_ACCOUNT" = fallback ] && home=(env "CODEX_HOME=$CODEX_HOME_FALLBACK")
  # The attempt's log opens with the account LABEL — which subscription ran it,
  # and nothing else about it. tee appends from here; the truncation above keeps
  # a re-dispatch's log as fresh as it was before.
  printf 'codex account: %s\n' "$CODEX_ACCOUNT" > "$log"
  with_timeout "$CODEX_TIMEOUT" \
    ${home[@]+"${home[@]}"} \
    "$CODEX_BIN" exec -C "$WORKTREE" -s workspace-write \
    -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON\",\"/opt/homebrew/share/flutter/bin/cache\",\"$HOME/.pub-cache\",\"$HOME/.config/flutter\",\"$HOME/.dart-tool\"]" \
    -c "model=\"$CODEX_MODEL\"" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    "$2" </dev/null 2>&1 \
    | tee -a "$log" \
    | while IFS= read -r l; do
        [ -n "$l" ] || continue
        printf '%.100s\n' "$l" > "$RUN_DIR/activity"
        feed '◆ codex' "$l"
      done
  rc="${PIPESTATUS[0]}"
  if [ "$CODEX_ACCOUNT" = primary ] && codex_out_of_credits "$log"; then
    CODEX_PRIMARY_DRY=1
    if [ -n "$CODEX_HOME_FALLBACK" ]; then
      CODEX_ACCOUNT="fallback"
      echo "[harness] codex round $1 hit the workspace-credits error — the fallback account takes the next attempt"
    fi
  fi
  return "$rc"
}

# Same job on a Claude subscription, for machines without the codex CLI: fresh
# session (no --resume/--session-id), ANTHROPIC_API_KEY unset so the run bills
# to the subscription, same worker permissions and the same CODEX_TIMEOUT cap.
# Logs are named after the model that produced them, like opus.log/codex-N.log.
run_claude_worker() {  # $1 = round label, $2 = prompt
  (cd "$WORKTREE" && with_timeout "$CODEX_TIMEOUT" \
      env -u ANTHROPIC_API_KEY CLAUDE_CODE_SUBAGENT_MODEL=sonnet \
      "$CLAUDE_BIN" -p "$2" --model "$IMPLEMENTER_MODEL" --effort "$IMPLEMENTER_EFFORT" \
      --settings "$HARNESS_DIR/worker-settings.json" --permission-mode acceptEdits \
      </dev/null 2>&1) \
    | tee "$RUN_DIR/claude-$1.log" \
    | while IFS= read -r l; do
        [ -n "$l" ] || continue
        printf '%.100s\n' "$l" > "$RUN_DIR/activity"
        feed '◆ claude' "$l"
      done
  return "${PIPESTATUS[0]}"
}

# Merge-conflict resolution is PR mechanics, not quality review, so it runs in
# BOTH arms — on codex when it is installed (unchanged), on Claude otherwise.
resolve_conflicts() {  # $1 = round label, $2 = prompt
  local before
  [ "$CODEX_AVAILABLE" = 1 ] || { run_claude_worker "$1" "$2"; return; }
  before="$CODEX_ACCOUNT"
  run_codex "$1" "$2" || true
  # A primary that answered "out of credits" resolved nothing, and the merge is
  # still stopped. run_codex moves the account only on that exact evidence, so
  # this pair of conditions is the credits case and nothing else — one more
  # attempt on the fallback before the caller escalates to a human.
  if [ "$before" = primary ] && [ "$CODEX_ACCOUNT" = fallback ]; then
    stage "base sync — conflict resolution ($CONFLICT_AGENT, fallback account)"
    run_codex "$1-fallback" "$2"
  fi
}

# --- Review-stage integrity ---------------------------------------------------
# Two confirmed runs "reviewed" a large diff in 4 and 19 seconds: no reviewer
# commits, no review-notes.md — and the run still recorded arm: full, gate pass,
# ready. Nothing reviewed those diffs and nothing said so; one of them shipped a
# defect a reviewer would have caught.
#
# So the stage is classified from EVIDENCE, never from duration: a genuine
# "everything is sound" review that writes its notes is a real review, however
# fast. Duration only decides whether a second pass is worth paying for — a
# stage that produced no evidence at all in less time than a human could read
# the diff is the signature of a reviewer that never started (auth prompt, CLI
# crash, empty context), and that is worth one retry.
DEFAULT_REVIEW_MIN_SECONDS=60
DEFAULT_REVIEW_TRIVIAL_LINES=20
REVIEW_MIN_SECONDS="${HARNESS_REVIEW_MIN_SECONDS:-$DEFAULT_REVIEW_MIN_SECONDS}"
REVIEW_TRIVIAL_LINES="${HARNESS_REVIEW_TRIVIAL_LINES:-$DEFAULT_REVIEW_TRIVIAL_LINES}"
case "$REVIEW_MIN_SECONDS"   in ''|*[!0-9]*) REVIEW_MIN_SECONDS=$DEFAULT_REVIEW_MIN_SECONDS ;; esac
case "$REVIEW_TRIVIAL_LINES" in ''|*[!0-9]*) REVIEW_TRIVIAL_LINES=$DEFAULT_REVIEW_TRIVIAL_LINES ;; esac

# Proof that a review happened: fix commits, notes, or a rejection. Any one of
# them is enough — the reviewer is told to write notes even when it changes
# nothing, and a REJECTED.md is the most engaged review there is.
review_evidence() {
  [ -f "$WORKTREE/.harness/review-notes.md" ] && return 0
  [ -f "$WORKTREE/.harness/REJECTED.md" ] && return 0
  [ "$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null)" != "$OPUS_HEAD" ] && return 0
  return 1
}

# The floor only means something on a diff that takes real reading: a two-line
# change genuinely can be reviewed in seconds, and crying wolf over it would
# teach everyone to ignore the alarm. An unreadable diff counts as trivial for
# the same reason.
review_diff_is_trivial() {
  local n
  n=$(git -C "$WORKTREE" diff --numstat "$BASE_REF...HEAD" 2>/dev/null \
    | awk '{ if ($1 != "-") i += $1; if ($2 != "-") d += $2 } END { print i + d + 0 }')
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -le "$REVIEW_TRIVIAL_LINES" ]
}

run_gate 1 || true

# --- Codex review + fix rounds ----------------------------------------------
# Skipped when the codex CLI is absent (Claude-only mode — the review is skipped
# honestly, never reassigned to a second Claude worker: no model grades its own
# homework) and in the no_review ablation arm (HARNESS_SKIP_REVIEW=1). Either way
# the deterministic gate above still ran, so a failing gate still yields
# gate_failed downstream, and the base-sync step below still runs in both arms.
if [ "$CODEX_AVAILABLE" = 0 ]; then
  REVIEW_CLASS="skipped"
  stage "review skipped — no codex CLI found (Claude-only mode)"
elif [ "$ARM" = "full" ]; then
REVIEW_PROMPT="You are the reviewer stage of an automated pipeline; another agent just implemented a task.
Context (all inside .harness/): brief.md (the task contract), specs/ when present (the task's source documents converted to markdown — part of the contract, read them alongside the brief), implementer-notes.md, gate-latest.log (test gate output — current status: $GATE_STATUS).
implementer-notes.md is the implementer's own account of its work: treat it as claims to verify against the diff, not as facts.
Review ALL changes on this branch: git log $BASE_REF..HEAD and git diff $BASE_REF...HEAD.

Work through this checklist, in order:
1. Gate-gaming — weakened or deleted tests, skipped/disabled cases, loosened assertions, hardcoded expected values, modified fixtures. A green gate proves nothing if the tests were touched to make it green; restore proper tests and fix the code instead. Highest priority.
2. Business logic — does the code actually satisfy each acceptance criterion in the brief? Check edge cases, error paths, and the domain invariants documented in this repo's CLAUDE.md/AGENTS.md. Read the surrounding code the diff plugs into — verify correctness in context, not just in isolation.
3. Reuse — for every new helper/hook/component/util/query in the diff, search the codebase for an existing equivalent FIRST. If one exists, use it and delete the duplicate. If the diff duplicates logic within itself, factor it out.
4. Hardcoding — magic numbers, inline strings/URLs/IDs/colors/timeouts that belong in the constants, enums, config, or theme this repo already has. Move them to where the repo keeps such values.
5. Quality of the NEW code — naming, dead code, needless abstraction, overly clever constructs. Refactor confidently.

Boundary: refactor freely within the code this branch introduces or touches; do NOT launch repo-wide refactors of untouched code — record those as suggestions in your notes instead.
- Keep the gate green: re-run the relevant tests after your changes.
- If the gate failed, make it pass (without violating check 1).
- Commit your changes as separate conventional commits. Never mention AI or agents in commits.
- Never git add or commit anything under .harness/ (orchestration metadata — your notes files live there UNCOMMITTED). If git refuses a path as ignored, leave it alone; never use git add -f.
- Do NOT push or create PRs.
- Write .harness/review-notes.md: what you fixed or refactored and why, plus anything you flagged but deliberately left alone.
- If you find a FUNDAMENTAL flaw (wrong approach, architectural problem) that should not be papered over: do not fix it — write your findings to .harness/REJECTED.md and stop.
- If everything is genuinely sound, say so in review-notes.md and change nothing.$PREPROD_POSTURE_REVIEW"

# A rejection from a previous dispatch must not outlive the revision it judged:
# the outcome check below keys off this file's existence, so a re-review that
# approves would still be read as rejected (bit us on OLYX-1497 — approval
# round left round 1's file in place and the run skipped its PR).
if [ -f "$WORKTREE/.harness/REJECTED.md" ]; then
  mv "$WORKTREE/.harness/REJECTED.md" "$RUN_DIR/REJECTED.prev.md"
fi
# Same reasoning for the notes, and for the same reason the integrity check
# below needs: a previous dispatch's review-notes.md left in the worktree would
# be read as evidence that THIS review happened. Harvested into the run dir
# rather than deleted, which is where section 6 would have copied it anyway, so
# no round's notes are ever lost.
if [ -f "$WORKTREE/.harness/review-notes.md" ]; then
  mv "$WORKTREE/.harness/review-notes.md" "$RUN_DIR/review-notes.md"
fi

stage "review — Codex (ChatGPT sub)"
REVIEW_STARTED=$(date +%s)
# Read before the attempt, not after: run_codex may move the account for the
# NEXT attempt, and this records the one that actually ran this review.
REVIEW_ACCOUNT="$CODEX_ACCOUNT"
run_codex 1 "$REVIEW_PROMPT" || true
REVIEW_SECONDS=$(( $(date +%s) - REVIEW_STARTED ))

# --- 5b. Did the review actually happen? -------------------------------------
# Two things can buy the single retry, and the second one is why the fallback
# account exists: a credits-dead attempt is *certain* to repeat itself on the
# same account, so it never spends the retry there.
REVIEW_RETRY_REASON=""
if review_evidence; then
  REVIEW_CLASS="reviewed"
elif [ "$CODEX_PRIMARY_DRY" = 1 ] && [ -n "$CODEX_HOME_FALLBACK" ]; then
  # Tier 1 — credits-certain. Takes precedence over the floor below: the floor
  # asks "is a second pass worth paying for?", and here the second pass is on a
  # different account, so the answer is yes however long the first one took.
  REVIEW_RETRY_REASON="the primary Codex account is out of credits"
elif [ "$REVIEW_SECONDS" -ge "$REVIEW_MIN_SECONDS" ] || review_diff_is_trivial; then
  # It spent real time on the diff (or there was next to nothing to read) and
  # simply left no notes behind. Recorded honestly, not retried: a second full
  # pass is expensive and the signature here is not a stage that never ran.
  REVIEW_CLASS="no_evidence"
  echo "[harness] review left no commits and no notes after ${REVIEW_SECONDS}s — recorded as no_evidence"
else
  # Tier 2 — silent no-op, cause unknown (auth prompt, CLI crash, empty
  # context, or a credits message this build words differently). The retry is
  # bought either way; a configured fallback just means it is not spent on the
  # account that already came up empty.
  REVIEW_RETRY_REASON="review produced nothing in ${REVIEW_SECONDS}s (floor ${REVIEW_MIN_SECONDS}s)"
fi

if [ -n "$REVIEW_RETRY_REASON" ]; then
  REVIEW_RETRY_SUFFIX=""
  if [ -n "$CODEX_HOME_FALLBACK" ]; then
    CODEX_ACCOUNT="fallback"
    REVIEW_RETRY_SUFFIX=" (fallback account)"
    echo "[harness] $REVIEW_RETRY_REASON — retrying once on the fallback Codex account"
  else
    echo "[harness] $REVIEW_RETRY_REASON — retrying once"
  fi
  stage "review retry — Codex (ChatGPT sub)$REVIEW_RETRY_SUFFIX"
  REVIEW_STARTED=$(date +%s)
  REVIEW_ACCOUNT="$CODEX_ACCOUNT"
  run_codex 1-retry "$REVIEW_PROMPT" || true
  REVIEW_SECONDS=$(( $(date +%s) - REVIEW_STARTED ))
  if review_evidence; then
    REVIEW_CLASS="reviewed"
  else
    # An unreviewed diff is not a failed run: the gate's verdict stands and the
    # run carries on to whatever outcome it earned — but it carries on saying out
    # loud that nothing reviewed this diff, and the arm it records is the one the
    # verdict reader already knows to distrust. A fallback that also came up
    # empty downgrades exactly like a primary that did.
    REVIEW_CLASS="failed_silent"
    ARM="no_review"
    stage "review failed silently — diff is unreviewed"
    echo "[harness] the review stage produced no commits and no notes twice — this diff is UNREVIEWED"
  fi
fi

if [ ! -f "$WORKTREE/.harness/REJECTED.md" ]; then
  if ! run_gate 2; then
    stage "fix round 2 — Codex (ChatGPT sub)"
    run_codex 2 "The test gate is still failing after your review. Output is in .harness/gate-latest.log. Fix the failures and commit (no AI attribution; never commit anything under .harness/). If it cannot be fixed without violating .harness/brief.md, write .harness/REJECTED.md instead." || true
    run_gate 3 || true
  fi
fi
else
  REVIEW_CLASS="skipped"   # the no_review ablation arm (HARNESS_SKIP_REVIEW=1)
fi   # end: review stage

# --- 6. Outcome ---------------------------------------------------------------
[ -f "$WORKTREE/.harness/review-notes.md" ] && cp "$WORKTREE/.harness/review-notes.md" "$RUN_DIR/review-notes.md"
if [ -f "$WORKTREE/.harness/REJECTED.md" ]; then
  STATUS="rejected"
  cp "$WORKTREE/.harness/REJECTED.md" "$RUN_DIR/REJECTED.md"
elif [ "$GATE_STATUS" != "pass" ]; then
  STATUS="gate_failed"
else
  STATUS="ready"

  # --- 5c. Base freshness sync (script; a model only on conflict) ---------------
  # Parallel runs merge PRs into base while this one is in flight; pushing a stale
  # branch ships a PR GitHub immediately marks as conflicting. Merge the latest
  # base BEFORE the PR: clean merge -> re-gate (a textually clean merge can still
  # break semantically); conflict -> Codex (or a Claude worker when the codex CLI
  # is absent) resolves, then re-gate; unresolvable -> needs_input for the
  # orchestrator.
  git -C "$WORKTREE" fetch origin --quiet || true
  if ! git -C "$WORKTREE" merge-base --is-ancestor "$BASE_REF" HEAD 2>/dev/null; then
    stage "base sync — merge latest $BASE_BRANCH (script — no model)"
    if git -C "$WORKTREE" merge --no-edit "$BASE_REF" > "$RUN_DIR/base-sync.log" 2>&1; then
      run_gate base-sync || true
    else
      git -C "$WORKTREE" diff --name-only --diff-filter=U >> "$RUN_DIR/base-sync.log" 2>&1 || true
      stage "base sync — conflict resolution ($CONFLICT_AGENT)"
      resolve_conflicts base-sync "A merge of $BASE_REF into this branch is stopped on conflicts (git status shows them). Newer work already merged to $BASE_BRANCH collided with this branch's changes (this branch's contract: .harness/brief.md and .harness/implementer-notes.md). Resolve every conflict by combining BOTH sides' intent — drop neither side's changes. For modify/delete conflicts on files this branch deliberately deleted, keep them deleted. If package-lock.json conflicts, resolve package.json first, then regenerate with 'npm install --package-lock-only' FOLLOWED BY 'npm dedupe --package-lock-only' (regen alone can leave an inconsistent nested tree that breaks npm ci — bit us in production), and verify with a clean 'npm ci'. Then git add the resolved files, conclude the merge commit (git commit --no-verify, plain message like 'Merge latest $BASE_BRANCH', no AI attribution), and re-run the tests relevant to the conflicted files. If the two sides are fundamentally incompatible, run git merge --abort and write .harness/REJECTED.md explaining why." || true
      if [ -f "$WORKTREE/.harness/REJECTED.md" ]; then
        # The Claude worker permission profile may refuse merge --abort. Keep
        # rejection cleanup script-owned so the worktree never remains mid-merge.
        git -C "$WORKTREE" merge --abort > /dev/null 2>&1 || true
        STATUS="rejected"; cp "$WORKTREE/.harness/REJECTED.md" "$RUN_DIR/REJECTED.md"
      elif git -C "$WORKTREE" ls-files -u | grep -q . || [ -f "$(git -C "$WORKTREE" rev-parse --git-path MERGE_HEAD)" ]; then
        git -C "$WORKTREE" merge --abort > /dev/null 2>&1 || true
        { echo "# Base sync blocked — merge conflicts with $BASE_REF"
          echo
          echo "The branch is ready but conflicts with newer $BASE_BRANCH and $CONFLICT_MODEL could not"
          echo "complete the resolution. Merge log tail:"
          echo
          tail -20 "$RUN_DIR/base-sync.log"
          echo
          echo "Resolve manually in the worktree (merge $BASE_REF, resolve, commit, push),"
          echo "then re-dispatch to finish the PR step."
        } > "$RUN_DIR/QUESTIONS.md"
        STATUS="needs_input"
      else
        run_gate base-sync2 || true
      fi
    fi
    if [ "$STATUS" = "ready" ] && [ "$GATE_STATUS" != "pass" ]; then STATUS="gate_failed"; fi
  fi

  if [ "$STATUS" = "ready" ]; then
  stage "push + draft PR (script — no model)"
  # Safety net: agents must never ship .harness/ metadata; strip if it slipped in.
  if [ -n "$(git -C "$WORKTREE" ls-files .harness 2>/dev/null)" ]; then
    git -C "$WORKTREE" rm -r -q --cached .harness
    git -C "$WORKTREE" commit -q -m "chore: remove local tooling files"
  fi
  git -C "$WORKTREE" push -u origin "$BRANCH" > "$RUN_DIR/push.log" 2>&1 || STATUS="push_failed"
  if [ "$STATUS" = "ready" ]; then
    TITLE=$(sed -n 's/^# //p' "$BRIEF" | head -1); [ -n "$TITLE" ] || TITLE="$TICKET"
    { echo "Ref: $TICKET"; echo
      if [ -f "$WORKTREE/.harness/implementer-notes.md" ]; then cat "$WORKTREE/.harness/implementer-notes.md"; fi
      if [ -f "$WORKTREE/.harness/review-notes.md" ]; then echo; echo "## Review notes"; cat "$WORKTREE/.harness/review-notes.md"; fi
    } > "$RUN_DIR/pr-body.md"
    # On re-dispatch a PR may already exist for this branch: reuse it (and do NOT
    # overwrite its body — the orchestrator may have rewritten it) instead of failing.
    PR_URL=$( (cd "$WORKTREE" && gh pr view "$BRANCH" --json url,state -q 'select(.state == "OPEN") | .url') 2>/dev/null ) || PR_URL=""
    if [ -z "$PR_URL" ]; then
      PR_URL=$( (cd "$WORKTREE" && gh pr create --draft --base "$BASE_BRANCH" --head "$BRANCH" \
          --title "$TITLE" --body-file "$RUN_DIR/pr-body.md") 2>>"$RUN_DIR/push.log" ) || STATUS="pr_failed"
    else
      echo "[harness] reusing existing PR: $PR_URL" >> "$RUN_DIR/push.log"
    fi
  fi
  fi

  # --- 6b. Demo recording (frontend runs only; a demo failure never fails the run)
  . "$HARNESS_DIR/demo.conf.sh" 2>/dev/null || true
  SHOT_BIN="${SHOT_BIN:-$HOME/.local/bin/shot-scraper}"
  if [ "$STATUS" = "ready" ] && [ -n "$PR_URL" ] && [ -f "$WORKTREE/.harness/demo.yml" ] \
     && [ -x "$SHOT_BIN" ] && [ -n "${R2_REMOTE:-}" ] \
     && rclone listremotes 2>/dev/null | grep -q "^${R2_REMOTE%%:*}:"; then
    stage "demo — recording (script, no model)"
    # Logged-in session captured once via demo-auth.sh; storyboards assume auth.
    AUTH_FILE="$HARNESS_DIR/auth/$(basename "$REPO").json"
    AUTH_ARGS=()
    [ -f "$AUTH_FILE" ] && AUTH_ARGS=(--auth "$AUTH_FILE")
    # The storyboard's server runs --strictPort on DEMO_PORT: if a stale server
    # already squats the port, ours dies silently and whatever lives there gets
    # recorded instead (bit us in production — 30s of another worktree's error overlay).
    DEMO_RC=0
    if [ -n "${DEMO_PORT:-}" ] && lsof -nP -iTCP:"$DEMO_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      { echo "[harness] demo skipped — port $DEMO_PORT already in use by:"
        lsof -nP -iTCP:"$DEMO_PORT" -sTCP:LISTEN; } > "$RUN_DIR/demo.log" 2>&1
      stage "demo — skipped (port $DEMO_PORT busy)"
      DEMO_RC=98
    else
      (cd "$WORKTREE" && with_timeout 600 \
          "$SHOT_BIN" video .harness/demo.yml --mp4 ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} </dev/null) > "$RUN_DIR/demo.log" 2>&1 || DEMO_RC=$?
      # shot-scraper only kills the npm wrapper it spawned; the vite child
      # survives and squats the port for every later run. The port was free
      # before recording, so any listener now belongs to this storyboard — reap it.
      if [ -n "${DEMO_PORT:-}" ]; then
        DEMO_SRV_PIDS=$(lsof -ti "tcp:$DEMO_PORT" -sTCP:LISTEN 2>/dev/null || true)
        [ -n "$DEMO_SRV_PIDS" ] && kill $DEMO_SRV_PIDS 2>/dev/null
      fi
    fi
    VID=$(find "$WORKTREE/.harness" -maxdepth 1 \( -name '*.mp4' -o -name '*.webm' \) -newer "$RUN_DIR/started" 2>/dev/null | head -1)
    if [ "$DEMO_RC" -ne 0 ]; then
      # Scene failures (wait_for timeouts, dead server) exit non-zero but still
      # leave a video of the broken state — never attach that to the PR.
      if [ "$DEMO_RC" -ne 98 ]; then
        echo "[harness] demo recording failed (exit $DEMO_RC) — video not uploaded" >> "$RUN_DIR/demo.log"
        stage "demo — failed (not uploaded)"
      fi
    elif [ -n "$VID" ]; then
      ffmpeg -y -i "$VID" -c:v libx264 -pix_fmt yuv420p -vf "scale=1280:-2" "$RUN_DIR/demo.mp4" >> "$RUN_DIR/demo.log" 2>&1 \
      && ffmpeg -y -i "$RUN_DIR/demo.mp4" -vf "fps=6,scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse" -loop 0 "$RUN_DIR/demo-preview.gif" >> "$RUN_DIR/demo.log" 2>&1 \
      && rclone copyto "$RUN_DIR/demo.mp4" "$R2_REMOTE/$TICKET/demo.mp4" --s3-no-check-bucket >> "$RUN_DIR/demo.log" 2>&1 \
      && rclone copyto "$RUN_DIR/demo-preview.gif" "$R2_REMOTE/$TICKET/demo-preview.gif" --s3-no-check-bucket >> "$RUN_DIR/demo.log" 2>&1 \
      && DEMO_URL="$R2_PUBLIC/$TICKET/demo.mp4" || true
      if [ -n "$DEMO_URL" ]; then
        # Append the demo to the PR's CURRENT body (it may have been rewritten since
        # creation) via the REST API — `gh pr edit --body` breaks on repos that ever
        # used classic Projects (deprecation error), the API PATCH route does not.
        { (cd "$WORKTREE" && gh pr view "$PR_URL" --json body -q .body) > "$RUN_DIR/pr-body-live.md" \
          && printf '\n## Demo\n\n[![Demo](%s)](%s)\n\n*Click the GIF to open the full video*\n' \
            "$R2_PUBLIC/$TICKET/demo-preview.gif" "$DEMO_URL" >> "$RUN_DIR/pr-body-live.md" \
          && REPO_SLUG=$( (cd "$WORKTREE" && gh repo view --json nameWithOwner -q .nameWithOwner) ) \
          && (cd "$WORKTREE" && gh api "repos/$REPO_SLUG/pulls/${PR_URL##*/}" -X PATCH \
                -F body=@"$RUN_DIR/pr-body-live.md" >/dev/null); } >> "$RUN_DIR/demo.log" 2>&1 || true
      fi
    else
      echo "[harness] demo produced no video — see log above" >> "$RUN_DIR/demo.log"
    fi
  fi
fi

write_result "$STATUS" "$PR_URL"
# A run that fell back reviewed fine, so nothing about its outcome says the
# primary needs topping up. One sentence on the run's own push is how the
# operator learns that without reading a log — and it only ever claims the
# credits error when the log actually carried it.
DONE_NOTE=""
if [ "$REVIEW_ACCOUNT" = fallback ]; then
  if [ "$CODEX_PRIMARY_DRY" = 1 ]; then
    DONE_NOTE="review ran on the fallback Codex account — primary is out of credits"
  else
    DONE_NOTE="review ran on the fallback Codex account — the primary review produced nothing"
  fi
fi
stage "done: $STATUS" "$DONE_NOTE"
echo "[harness] DONE status=$STATUS gate=$GATE_STATUS pr=${PR_URL:-none}"
echo "[harness] worktree=$WORKTREE logs=$RUN_DIR"
[ "$STATUS" = "ready" ]
}

main "$@"
