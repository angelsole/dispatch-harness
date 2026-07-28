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

WORKTREE="$(dirname "$REPO")/$(basename "$REPO")-$TICKET_LC"
BASE_REF="origin/$BASE_BRANCH"
mkdir -p "$RUN_DIR"

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

# Gather per-run quantitative metrics from the artefacts on disk. Every field is
# best-effort: called on EVERY exit path (including early failures), it emits
# whatever is available and nulls/empties the rest — partial metrics are fine.
collect_metrics() {
  local now started wall stage_durations gate_rounds opus_c codex_c
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

  # Gate history for this invocation: "<round> <pass|fail>" per line.
  gate_rounds='[]'
  if [ -f "$RUN_DIR/gate-rounds.log" ]; then
    gate_rounds=$(jq -Rn '[inputs | capture("^(?<round>[^ ]+) (?<result>[^ ]+)$")?]' \
      "$RUN_DIR/gate-rounds.log" 2>/dev/null || echo '[]')
    [ -n "$gate_rounds" ] || gate_rounds='[]'
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
    --argjson opus_commits "$opus_c" \
    --argjson codex_commits "$codex_c" \
    --argjson files "${files:-null}" --argjson ins "${ins:-null}" --argjson del "${del:-null}" \
    --argjson impl "$impl" \
    '{
      wall_seconds: $wall,
      stage_durations: $stage_durations,
      gate_rounds: $gate_rounds,
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
    --arg arm "$ARM" --arg model "$IMPLEMENTER_MODEL" --arg ieffort "$IMPLEMENTER_EFFORT" \
    --arg rmodel "$REVIEWER_MODEL" --arg reffort "$REVIEWER_EFFORT" \
    --arg worktree "$WORKTREE" --arg branch "$BRANCH" --arg base "$BASE_BRANCH" \
    --arg pr "${2:-}" --arg run_dir "$RUN_DIR" --arg opus_head "$OPUS_HEAD" --arg session "$OPUS_SESSION" --arg demo "$DEMO_URL" \
    --argjson metrics "$metrics" \
    '{ticket:$ticket,status:$status,arm:$arm,implementer_model:$model,implementer_effort:$ieffort,reviewer_model:$rmodel,reviewer_effort:$reffort,gate:$gate,worktree:$worktree,branch:$branch,base:$base,pr_url:$pr,opus_head:$opus_head,opus_session:$session,demo_url:$demo,metrics:$metrics,logs:$run_dir}' \
    > "$RUN_DIR/result.json"
}

# Live stage tracking: status (current), timeline (history), macOS notification
# on every model handoff, plus ntfy.sh push to the phone when notify.conf sets
# a topic. Disable local notifications with HARNESS_NOTIFY=0.
. "$HARNESS_DIR/notify.conf" 2>/dev/null || true
stage() {
  echo "$(date +%s) $1" > "$RUN_DIR/status"
  printf '%s %s\n' "$(date +%s)" "$1" >> "$RUN_DIR/stages.log"   # epoch history for metrics
  echo "$(date '+%H:%M:%S') $1" >> "$RUN_DIR/timeline"
  echo "$1" > "$RUN_DIR/activity"
  echo "[harness] $1"
  if [ "${HARNESS_NOTIFY:-1}" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"dispatch $TICKET\"" 2>/dev/null || true
  fi
  if [ -n "${HARNESS_NTFY_TOPIC:-}" ]; then
    curl -s -m 5 -H "Title: dispatch $TICKET" -d "$1" \
      "${HARNESS_NTFY_SERVER:-https://ntfy.sh}/$HARNESS_NTFY_TOPIC" >/dev/null 2>&1 || true
  fi
}

date +%s > "$RUN_DIR/started"
# Metrics bookkeeping: a per-invocation marker segments stages.log so resume
# pauses aren't charged to a stage; gate-rounds.log is fresh each invocation
# (a resumed run re-runs its gates, so stale rounds would double-count).
printf '%s __invocation__\n' "$(date +%s)" >> "$RUN_DIR/stages.log"
: > "$RUN_DIR/gate-rounds.log"
echo "$WORKTREE" > "$RUN_DIR/worktree"
echo "$BASE_REF" > "$RUN_DIR/base"
echo "[harness] $TICKET -> $REPO ($BRANCH from $BASE_REF)"
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
mkdir -p "$WORKTREE/.harness"
cp "$BRIEF" "$WORKTREE/.harness/brief.md"
rm -f "$WORKTREE/.harness/QUESTIONS.md"   # stale questions would re-trigger needs_input
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

# --- 4. Opus implements (Claude subscription: ANTHROPIC_API_KEY unset) -------
IMPLEMENTER_PROMPT="You are the implementer stage of an automated pipeline.
Read .harness/brief.md first — it is your task contract — then follow this repo's CLAUDE.md conventions.
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
- When finished, write .harness/implementer-notes.md: what you changed, key decisions, deviations from the brief, and what the reviewer should scrutinize. Keep it tight — substance only, no filler; it becomes the PR body."

# Worker sessions are resumable: we pin the session id so the user can step in
# interactively at any time (attach.sh), and so a re-dispatch after needs_input
# continues with the worker's context intact. After each run the id is refreshed
# from the stream's result event, since --resume forks to a new session id.
OPUS_SESSION_FILE="$RUN_DIR/opus-session"
CLAUDE_ARGS=(--model "$IMPLEMENTER_MODEL" --effort "$IMPLEMENTER_EFFORT" --settings "$HARNESS_DIR/worker-settings.json" --permission-mode acceptEdits --max-turns 120)
[ -n "$MCP_CONFIG" ] && CLAUDE_ARGS=("${CLAUDE_ARGS[@]}" --mcp-config "$MCP_CONFIG")
if [ -f "$OPUS_SESSION_FILE" ]; then
  OPUS_SESSION=$(cat "$OPUS_SESSION_FILE")
  OPUS_PROMPT="The orchestrator updated .harness/brief.md — it now contains answers to your questions and/or revision notes. Re-read it and continue the task under the same rules as before."
  CLAUDE_ARGS=("${CLAUDE_ARGS[@]}" --resume "$OPUS_SESSION")
  stage "resuming — Opus (Claude sub)"
else
  OPUS_SESSION=$(uuidgen | tr '[:upper:]' '[:lower:]')
  echo "$OPUS_SESSION" > "$OPUS_SESSION_FILE"
  OPUS_PROMPT="$IMPLEMENTER_PROMPT"
  CLAUDE_ARGS=("${CLAUDE_ARGS[@]}" --session-id "$OPUS_SESSION")
  stage "implementing — Opus (Claude sub)"
fi
# Stream events so the statusline and feed.log can show live what the worker
# is doing (tool by tool); raw stream kept for debugging.
(cd "$WORKTREE" && env -u ANTHROPIC_API_KEY CLAUDE_CODE_SUBAGENT_MODEL=sonnet \
    "$CLAUDE_BIN" -p "$OPUS_PROMPT" "${CLAUDE_ARGS[@]}" \
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
NEW_SESSION=$(jq -r 'select(.type == "result") | .session_id // empty' "$RUN_DIR/opus-stream.jsonl" 2>/dev/null | tail -1)
[ -n "$NEW_SESSION" ] && echo "$NEW_SESSION" > "$OPUS_SESSION_FILE"
if [ -f "$WORKTREE/.harness/QUESTIONS.md" ]; then
  cp "$WORKTREE/.harness/QUESTIONS.md" "$RUN_DIR/QUESTIONS.md"
  STATUS="needs_input"; write_result "$STATUS" ""
  stage "waiting — implementer needs your input (QUESTIONS.md)"
  exit 3
fi
if [ $OPUS_EXIT -ne 0 ] || [ -z "$(git -C "$WORKTREE" log "$BASE_REF"..HEAD --oneline 2>/dev/null)" ]; then
  STATUS="implementer_failed"; write_result "$STATUS" ""
  stage "done: implementer_failed"
  echo "[harness] implementer failed (exit $OPUS_EXIT, see opus-stderr.log / feed.log in $RUN_DIR)"; exit 1
fi
# Everything up to this commit is Opus's work; later commits are Codex's.
OPUS_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
echo "$OPUS_HEAD" > "$RUN_DIR/opus-head"

# --- 5. Gate + Codex review/fix loop ------------------------------------------
run_gate() {
  stage "test gate #$1 (deterministic — no model)"
  (cd "$WORKTREE" && bash -c "$GATE_CMD") > "$RUN_DIR/gate-$1.log" 2>&1
  local rc=$?
  tail -100 "$RUN_DIR/gate-$1.log" > "$WORKTREE/.harness/gate-latest.log"
  if [ $rc -eq 0 ]; then GATE_STATUS="pass"; else GATE_STATUS="fail"; fi
  printf '%s %s\n' "$1" "$GATE_STATUS" >> "$RUN_DIR/gate-rounds.log"
  return $rc
}

GIT_COMMON=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)
# codex exec must never inherit our stdin: in a background run it is a pipe
# that never closes, and codex blocks forever on "Reading additional input
# from stdin..." (bit us in production). </dev/null fixes the cause;
# with_timeout is the backstop cap (timeout(1), or a perl-alarm fallback).
CODEX_TIMEOUT="${CODEX_TIMEOUT:-3600}"
run_codex() {  # $1 = round label, $2 = prompt
  with_timeout "$CODEX_TIMEOUT" \
    "$CODEX_BIN" exec -C "$WORKTREE" -s workspace-write \
    -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON\"]" \
    -c "model=\"$CODEX_MODEL\"" \
    -c "model_reasoning_effort=\"$CODEX_EFFORT\"" \
    "$2" </dev/null 2>&1 \
    | tee "$RUN_DIR/codex-$1.log" \
    | while IFS= read -r l; do
        [ -n "$l" ] && printf '%.100s\n' "$l" > "$RUN_DIR/activity"
      done
  return "${PIPESTATUS[0]}"
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
        [ -n "$l" ] && printf '%.100s\n' "$l" > "$RUN_DIR/activity"
      done
  return "${PIPESTATUS[0]}"
}

# Merge-conflict resolution is PR mechanics, not quality review, so it runs in
# BOTH arms — on codex when it is installed (unchanged), on Claude otherwise.
resolve_conflicts() {  # $1 = round label, $2 = prompt
  if [ "$CODEX_AVAILABLE" = 1 ]; then run_codex "$1" "$2"; else run_claude_worker "$1" "$2"; fi
}

run_gate 1 || true

# --- Codex review + fix rounds ----------------------------------------------
# Skipped when the codex CLI is absent (Claude-only mode — the review is skipped
# honestly, never reassigned to a second Claude worker: no model grades its own
# homework) and in the no_review ablation arm (HARNESS_SKIP_REVIEW=1). Either way
# the deterministic gate above still ran, so a failing gate still yields
# gate_failed downstream, and the base-sync step below still runs in both arms.
if [ "$CODEX_AVAILABLE" = 0 ]; then
  stage "review skipped — no codex CLI found (Claude-only mode)"
elif [ "$ARM" = "full" ]; then
REVIEW_PROMPT="You are the reviewer stage of an automated pipeline; another agent just implemented a task.
Context (all inside .harness/): brief.md (the task contract), implementer-notes.md, gate-latest.log (test gate output — current status: $GATE_STATUS).
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
- If everything is genuinely sound, say so in review-notes.md and change nothing."

stage "review — Codex (ChatGPT sub)"
run_codex 1 "$REVIEW_PROMPT" || true

if [ ! -f "$WORKTREE/.harness/REJECTED.md" ]; then
  if ! run_gate 2; then
    stage "fix round 2 — Codex (ChatGPT sub)"
    run_codex 2 "The test gate is still failing after your review. Output is in .harness/gate-latest.log. Fix the failures and commit (no AI attribution; never commit anything under .harness/). If it cannot be fixed without violating .harness/brief.md, write .harness/REJECTED.md instead." || true
    run_gate 3 || true
  fi
fi
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
stage "done: $STATUS"
echo "[harness] DONE status=$STATUS gate=$GATE_STATUS pr=${PR_URL:-none}"
echo "[harness] worktree=$WORKTREE logs=$RUN_DIR"
[ "$STATUS" = "ready" ]
}

main "$@"
