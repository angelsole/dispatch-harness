#!/usr/bin/env bash
# The review-fallback contract: cross-vendor review is the preference, A REVIEW
# is the requirement. When codex dies mid-run (the production shape: a ChatGPT
# workspace out of credits) the same prompt re-runs in a fresh Claude session
# and the switch is recorded loudly; when BOTH backends fail the run ends
# review_failed and pushes nothing — an unreviewed diff must never ship looking
# reviewed. And when a run does reach ready, the ticket-sync step puts the PR
# link on the Linear ticket and moves it to In Review without an orchestrator
# watching.
#
# Nothing real is contacted. `codex`, `claude`, `gh`, `npx` (ccusage) and
# `curl` (ntfy + Linear) are fake binaries answering from canned files and
# recording what they were asked — the technique tests/capacity-preflight.test.sh
# uses. Every run is a real run-task.sh invocation against a fabricated repo
# with a local bare remote.
#
# Usage: bash tests/review-fallback.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-fallback-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
STATION="$ROOT/station"
CODEX_CALLS="$ROOT/codex-calls.log"
CLAUDE_CALLS="$ROOT/claude-calls.log"
GH_CALLS="$ROOT/gh-calls.log"
LINEAR_LOG="$ROOT/linear.log"
NTFY_LOG="$ROOT/ntfy.log"
CODEX_MODE="$ROOT/codex-mode"
REVIEWER_MODE="$ROOT/reviewer-mode"
CCUSAGE_JSON="$ROOT/ccusage.json"
KEYFILE="$ROOT/linear-api-key"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude"
: > "$CODEX_CALLS"; : > "$CLAUDE_CALLS"; : > "$GH_CALLS"; : > "$LINEAR_LOG"; : > "$NTFY_LOG"
printf 'ok\n' > "$CODEX_MODE"; printf 'ok\n' > "$REVIEWER_MODE"
printf 'lin_api_TESTKEY\n' > "$KEYFILE"; chmod 600 "$KEYFILE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# Every harness script reads lib/common.sh from beside itself, so the shared
# helpers travel with both staged copies — the layout install.sh produces.
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"
cat > "$HARNESS/repos.local.sh" <<EOF
repo_config_local() {
  case "\$2" in
    greenapp|greenapp-*) INSTALL_CMD='true'; GATE_CMD='exit 0' ;;
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
# The reviewer stand-in. `ok` reviews (writes review-notes.md in the worktree
# it was pointed at); `credits` is the production failure verbatim; `boom` is
# any other death; `silent` is the shape that used to ship — it exits clean
# having touched nothing at all.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
printf 'codex %s\n---\n' "\$*" >> "$CODEX_CALLS"
wt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-C" ] && wt="\$a"; prev="\$a"; done
case "\$(cat "$CODEX_MODE")" in
  ok)      mkdir -p "\$wt/.harness"; echo "codex: sound" > "\$wt/.harness/review-notes.md" ;;
  silent)  echo "codex: done" ;;
  credits) echo "ERROR: Your workspace is out of credits."; exit 1 ;;
  boom)    echo "stream disconnected before completion"; exit 1 ;;
esac
EOF

# One fake claude, two jobs, told apart by the prompt: the implementer commits;
# the fallback reviewer (prompt says "reviewer stage") reviews or dies per
# REVIEWER_MODE. Both run with cwd = the worktree.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in
  *"reviewer stage"*|*"test gate is still failing"*)
    printf 'reviewer anthropic:%s\n---\n' "\${ANTHROPIC_API_KEY-<unset>}" >> "$CLAUDE_CALLS"
    case "\$(cat "$REVIEWER_MODE")" in
      ok)   mkdir -p .harness; echo "claude: sound" > .harness/review-notes.md ;;
      dead) echo "claude reviewer also failed" >&2; exit 1 ;;
    esac
    ;;
  *)
    printf 'implementer\n---\n' >> "$CLAUDE_CALLS"
    date > fixture.txt
    git add fixture.txt
    git commit -q -m "feat: fixture change"
    ;;
esac
EOF

# gh: pr view finds nothing, pr create hands back a fixed URL.
cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$GH_CALLS"
case "\$*" in
  *"pr create"*) echo "https://github.com/olyx/greenapp/pull/9" ;;
  *"pr view"*)   exit 1 ;;
esac
EOF

# ccusage: always healthy — capacity is tests/capacity-preflight.test.sh's job.
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

# curl: ntfy pushes and the Linear GraphQL conversation, told apart by URL and
# body, exactly like tests/quartermaster.test.sh's fake.
cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*://*) url="\$a" ;; esac; done
case "\$url" in
  *api.linear.app*)
    body=""
    prev=""
    for a in "\$@"; do [ "\$prev" = "-d" ] && body="\$a"; prev="\$a"; done
    printf 'linear %s\n' "\$body" >> "$LINEAR_LOG"
    case "\$body" in
      *commentCreate*) printf '{"data":{"commentCreate":{"success":true}}}' ;;
      *issueUpdate*)   printf '{"data":{"issueUpdate":{"success":true}}}' ;;
      *)               printf '{"data":{"issue":{"id":"uuid-77","identifier":"OLYX-77","team":{"states":{"nodes":[{"id":"st-todo","name":"Todo","type":"unstarted"},{"id":"st-rev","name":"In Review","type":"started"},{"id":"st-done","name":"Done","type":"completed"}]}}}}}' ;;
    esac ;;
  *)
    printf 'curl %s\n' "\$*" >> "$NTFY_LOG" ;;
esac
EOF

chmod +x "$FAKES/codex" "$FAKES/claude" "$FAKES/gh" "$FAKES/npx" "$FAKES/curl"

# --- the harness under test ---------------------------------------------------
# Per-dispatch counts, not lifetime ones: the backend logs are truncated at the
# top of every dispatch below, so "one Codex attempt" means one, and inserting a
# run above cannot quietly turn an assertion into a tally of the whole suite.
reviewer_calls() { grep -c '^reviewer' "$CLAUDE_CALLS" 2>/dev/null | tr -d ' '; }
codex_calls()    { grep -c '^codex'    "$CODEX_CALLS" 2>/dev/null | tr -d ' '; }

RC=0; RUN=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$CODEX_CALLS"; : > "$CLAUDE_CALLS"
  # The fallback account is a documented operator knob, so it is scrubbed here:
  # a machine that has one configured failed the arms below that are about
  # having nowhere else to go. The overrides can still set it — env applies -u
  # before its own assignments.
  # shellcheck disable=SC2086
  env -u HARNESS_CODEX_HOME_FALLBACK \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" \
      LINEAR_API_KEY_FILE="$KEYFILE" \
      HARNESS_REVIEW_NETWORK=0 \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=rf-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  return 0
}
result_field() { jq -r ".$2 // \"\"" "$RUNS/$1/result.json" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== codex healthy: no fallback, and the ticket syncs itself =="
# ---------------------------------------------------------------------------
dispatch OLYX-77 ""
check "healthy: run exits 0" "$RC" "0"
check "healthy: status is ready" "$(result_field OLYX-77 status)" "ready"
check "healthy: classified from the evidence" "$(result_field OLYX-77 review)" "reviewed"
check "healthy: codex reviewed" "$(codex_calls)" "1"
check "healthy: the Claude reviewer never ran" "$(reviewer_calls)" "0"
absent "healthy: no fallback marker" "$RUNS/OLYX-77/review-fallback"
check "healthy: the PR url reaches result.json" "$(result_field OLYX-77 pr_url)" "https://github.com/olyx/greenapp/pull/9"
file_has "$LINEAR_LOG" "commentCreate" "sync: the PR link is commented on the ticket"
file_has "$LINEAR_LOG" "https://github.com/olyx/greenapp/pull/9" "sync: with the actual PR url"
file_has "$LINEAR_LOG" "st-rev" "sync: the ticket moves to the team's In Review state"
file_has "$RUNS/OLYX-77/stages.log" "ticket sync — PR link + In Review" \
  "sync: the step is a visible stage, not a side effect"
file_has "$RUNS/OLYX-77/ticket-sync.log" "issueUpdate" "sync: the log records the state move"

# ---------------------------------------------------------------------------
echo "== out of credits: a fresh Claude session reviews, loudly =="
# ---------------------------------------------------------------------------
printf 'credits\n' > "$CODEX_MODE"
dispatch OLYX-78 ""
check "fallback: run exits 0" "$RC" "0"
check "fallback: status is ready — a review happened" "$(result_field OLYX-78 status)" "ready"
check "fallback: classified as the Claude tier's review" "$(result_field OLYX-78 review)" "reviewed_claude"
check "fallback: review_account names the backend" "$(result_field OLYX-78 review_account)" "claude"
check "fallback: exactly one Codex attempt — a dry account is never retried" "$(codex_calls)" "1"
check "fallback: the Claude reviewer ran once" "$(reviewer_calls)" "1"
file_has "$RUNS/OLYX-78/stages.log" "review — Codex unavailable (the Codex account is out of credits) → Claude reviewer (Claude sub)" \
  "fallback: the switch is a visible stage line"
file_has "$RUNS/OLYX-78/review-fallback" "out of credits" \
  "fallback: the run dir records why"
check "fallback: result.json names the model that actually reviewed" \
  "$(result_field OLYX-78 reviewer_model)" "$(result_field OLYX-78 implementer_model)"
file_has "$CLAUDE_CALLS" "reviewer anthropic:<unset>" \
  "fallback: the Claude reviewer cannot bill to a stray API key"
exists "fallback: the review notes came from the fallback" "$RUNS/OLYX-78/review-notes.md"
file_has "$RUNS/OLYX-78/review-notes.md" "claude: sound" \
  "fallback: and they are the Claude reviewer's notes"
file_has "$LINEAR_LOG" "OLYX-78" "fallback: the ticket still syncs" || true

# ---------------------------------------------------------------------------
echo "== both reviewers dead: review_failed, and nothing ships =="
# ---------------------------------------------------------------------------
printf 'credits\n' > "$CODEX_MODE"; printf 'dead\n' > "$REVIEWER_MODE"
GH_BEFORE=$(grep -c 'pr create' "$GH_CALLS" 2>/dev/null | tr -d ' ')
dispatch OLYX-79 ""
check "dead: status is review_failed" "$(result_field OLYX-79 status)" "review_failed"
check "dead: the class says nothing reviewed it" "$(result_field OLYX-79 review)" "failed_silent"
check "dead: the failed attempt does not rewrite its pinned arm" \
  "$(result_field OLYX-79 arm)" "full"
check "dead: no PR was created" "$(grep -c 'pr create' "$GH_CALLS" | tr -d ' ')" "$GH_BEFORE"
check "dead: result.json carries no pr_url" "$(result_field OLYX-79 pr_url)" ""
file_has_not "$LINEAR_LOG" "OLYX-79" "dead: the ticket is not touched"
file_has "$NTFY_LOG" "done: review_failed" "dead: the phone hears about it"
if grep -F "done: review_failed" "$NTFY_LOG" | grep -qF "Priority: high"; then
  ok "dead: at high priority — only a human can top up credits"
else
  bad "dead: the review_failed push is not escalated"
fi
# The body's extra line is its own physical line in the fake's log (the push
# body is "<stage>\n<note>"), so the reason is what follows the stage line.
if grep -A1 -F "done: review_failed" "$NTFY_LOG" \
   | grep -qF "last tier to fail: the Claude reviewer — the Codex account is out of credits"; then
  ok "dead: and the highest-priority push the pipeline sends finally says why"
else
  bad "dead: the review_failed push carries no reason"
fi
printf 'ok\n' > "$CODEX_MODE"; printf 'ok\n' > "$REVIEWER_MODE"

# ---------------------------------------------------------------------------
echo "== a Codex review that left nothing behind does not ship on its stopwatch =="
# ---------------------------------------------------------------------------
# The confirmed hole: the reviewer spent longer than the floor (or the diff was
# small enough to skip it), left no notes, no commits and no rejection — and the
# run recorded `no_evidence` and opened a PR anyway. Duration is not evidence,
# by this pipeline's own doctrine. HARNESS_REVIEW_MIN_SECONDS=0 puts every empty
# review on that branch, which is what makes both shapes below deterministic.
printf 'silent\n' > "$CODEX_MODE"
dispatch OLYX-81 "HARNESS_REVIEW_MIN_SECONDS=0"
check "no evidence: still exactly one Codex attempt — the second pass stays unbought" \
  "$(codex_calls)" "1"
check "no evidence: but the diff reaches the Claude tier" "$(reviewer_calls)" "1"
check "no evidence: which reviewed it" "$(result_field OLYX-81 review)" "reviewed_claude"
check "no evidence: so the run ships a reviewed diff" "$(result_field OLYX-81 status)" "ready"
file_has "$RUNS/OLYX-81/review-fallback" "no evidence from the Codex review after" \
  "no evidence: the run dir records what sent it to the last tier"
if grep -A1 -F "done: ready" "$NTFY_LOG" \
   | grep -qF "review ran on the Claude tier — no evidence from the Codex review after"; then
  ok "no evidence: and the ready push says the review was not cross-vendor"
else
  bad "no evidence: a ready run reviewed by the Claude tier says nothing about it"
fi

printf 'dead\n' > "$REVIEWER_MODE"
GH_BEFORE=$(grep -c 'pr create' "$GH_CALLS" 2>/dev/null | tr -d ' ')
dispatch OLYX-82 "HARNESS_REVIEW_MIN_SECONDS=0"
check "no evidence, dead tier: nothing reviewed the diff" \
  "$(result_field OLYX-82 review)" "failed_silent"
check "no evidence, dead tier: so the run holds" "$(result_field OLYX-82 status)" "review_failed"
check "no evidence, dead tier: no PR was created" \
  "$(grep -c 'pr create' "$GH_CALLS" | tr -d ' ')" "$GH_BEFORE"
check "no evidence, dead tier: and no pr_url to mistake for a reviewed one" \
  "$(result_field OLYX-82 pr_url)" ""
if grep -A1 -F "done: review_failed" "$NTFY_LOG" \
   | grep -qF "last tier to fail: the Claude reviewer — no evidence from the Codex review after"; then
  ok "no evidence, dead tier: the escalated push names the tier and what sent it there"
else
  bad "no evidence, dead tier: the review_failed push carries no reason"
fi

# ---------------------------------------------------------------------------
echo "== no codex CLI at all: the Claude tier reviews, and a dead one holds =="
# ---------------------------------------------------------------------------
# This arm used to skip the stage outright and ship every PR unreviewed by
# design — with run_claude_worker, exactly the fresh-cold-read machinery it
# needed, sitting unwired in the same file.
NOCODEX="$ROOT/no-such-codex"
printf 'ok\n' > "$REVIEWER_MODE"
dispatch OLYX-83 "CODEX_BIN=$NOCODEX"
check "claude-only: nothing on the Codex side is asked" "$(codex_calls)" "0"
check "claude-only: the Claude tier reviews instead" "$(reviewer_calls)" "1"
check "claude-only: recorded as the review it is" "$(result_field OLYX-83 review)" "reviewed_claude"
check "claude-only: the pinned arm names the machine, not an ablation" \
  "$(cat "$RUNS/OLYX-83/arm")" "claude_only"
check "claude-only: and result.json carries the same arm" "$(result_field OLYX-83 arm)" "claude_only"
check "claude-only: the run ships" "$(result_field OLYX-83 status)" "ready"
check "claude-only: reviewer_model names the model that actually reviewed" \
  "$(result_field OLYX-83 reviewer_model)" "$(result_field OLYX-83 implementer_model)"
file_has "$RUNS/OLYX-83/review-notes.md" "claude: sound" \
  "claude-only: and the notes are the reviewer's own"

printf 'dead\n' > "$REVIEWER_MODE"
GH_BEFORE=$(grep -c 'pr create' "$GH_CALLS" 2>/dev/null | tr -d ' ')
dispatch OLYX-84 "CODEX_BIN=$NOCODEX"
check "claude-only, dead: nothing reviewed the diff" \
  "$(result_field OLYX-84 review)" "failed_silent"
check "claude-only, dead: the run holds here too" "$(result_field OLYX-84 status)" "review_failed"
check "claude-only, dead: and opens no PR" \
  "$(grep -c 'pr create' "$GH_CALLS" | tr -d ' ')" "$GH_BEFORE"
check "claude-only, dead: the result keeps the condition it was dispatched under" \
  "$(result_field OLYX-84 arm)" "claude_only"
check "claude-only, dead: matching the pin, so a re-dispatch tries the same arm" \
  "$(cat "$RUNS/OLYX-84/arm")" "claude_only"
printf 'ok\n' > "$CODEX_MODE"; printf 'ok\n' > "$REVIEWER_MODE"

# The arm is an experimental condition, pinned at first dispatch: codex being
# installed between attempts must not quietly move a run to a different one.
mkdir -p "$RUNS/OLYX-85"
printf 'claude_only\n' > "$RUNS/OLYX-85/arm"
dispatch OLYX-85 ""
check "pinned: codex is on this machine and still never asked" "$(codex_calls)" "0"
check "pinned: the pinned arm's own tier takes the review" "$(reviewer_calls)" "1"
check "pinned: and it is recorded as one" "$(result_field OLYX-85 review)" "reviewed_claude"
file_has "$RUNS/OLYX-85/review-fallback" "this run is pinned to the Claude-only arm" \
  "pinned: the run dir records that the pin, not the machine, sent it there"

# ---------------------------------------------------------------------------
echo "== the sync knows when to stay home =="
# ---------------------------------------------------------------------------
LINEAR_BEFORE=$(grep -c '' < "$LINEAR_LOG" | tr -d ' ')
dispatch OLYX-80 "HARNESS_TICKET_SYNC=0"
check "knob: HARNESS_TICKET_SYNC=0 dispatches fine" "$(result_field OLYX-80 status)" "ready"
check "knob: and never talks to Linear" "$(grep -c '' < "$LINEAR_LOG" | tr -d ' ')" "$LINEAR_BEFORE"

LINEAR_BEFORE=$(grep -c '' < "$LINEAR_LOG" | tr -d ' ')
dispatch adhoc-fixture-thing ""
check "adhoc: a run with no ticket-shaped id is ready" "$(result_field adhoc-fixture-thing status)" "ready"
check "adhoc: and skips the ticket sync" "$(grep -c '' < "$LINEAR_LOG" | tr -d ' ')" "$LINEAR_BEFORE"

# ---------------------------------------------------------------------------
echo "== an unreadable diff is not a small diff =="
# ---------------------------------------------------------------------------
# review_diff_is_trivial() decides whether the review floor applies at all, and
# it used to answer "trivial" whenever it could not measure — so a diff nothing
# could size talked its way out of the retry. Lifted out of run-task.sh by
# source extraction (the script runs its whole pipeline on source, so it cannot
# be sourced), the way tests/context-mount.test.sh reads mount_specs().
# Exported rather than plain assignments: the extracted body is their only
# reader, and no linter can see inside an eval to know that.
TRIVIAL_FN="$(awk '/^review_diff_is_trivial\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SRC/run-task.sh")"
has "$TRIVIAL_FN" 'REVIEW_TRIVIAL_LINES' "extract: review_diff_is_trivial() lifted from run-task.sh"
eval "$TRIVIAL_FN"
trivial() { if review_diff_is_trivial; then printf 'trivial'; else printf 'not-trivial'; fi; }

TW="$ROOT/trivial-wt"
git init -q "$TW"
git -C "$TW" config user.email t@t
git -C "$TW" config user.name  t
printf 'base\n' > "$TW/f.txt"
git -C "$TW" add -A && git -C "$TW" commit -q -m init
git -C "$TW" update-ref refs/remotes/origin/main HEAD
export REVIEW_TRIVIAL_LINES=20 WORKTREE="$TW" BASE_REF=origin/main

printf 'one\n' >> "$TW/f.txt"
git -C "$TW" add -A && git -C "$TW" commit -q -m "a one-line change"
check "trivial: a one-line diff genuinely is trivial" "$(trivial)" "trivial"

# Git successfully reads binary numstat entries as `- - path`, but the line
# count is unknowable. Coercing those dashes to zero would call a binary-only
# change trivial even though there is no measured size.
printf '\0\1\2' > "$TW/binary.dat"
git -C "$TW" add -A && git -C "$TW" commit -q -m "a binary change"
check "unreadable: a binary numstat is unknown, not zero lines" \
  "$(trivial)" "not-trivial"

seq 1 40 >> "$TW/f.txt"
git -C "$TW" add -A && git -C "$TW" commit -q -m "forty more"
check "trivial: forty lines are not" "$(trivial)" "not-trivial"

export BASE_REF=origin/no-such-base
check "unreadable: a base ref git cannot resolve is unknown, not small" \
  "$(trivial)" "not-trivial"
export BASE_REF=origin/main WORKTREE="$ROOT/not-a-worktree-at-all"
check "unreadable: and neither is a worktree that is not there" "$(trivial)" "not-trivial"

echo
printf 'review-fallback: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
