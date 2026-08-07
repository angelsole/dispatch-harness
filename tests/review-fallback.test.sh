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
# any other death.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
printf 'codex %s\n---\n' "\$*" >> "$CODEX_CALLS"
wt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-C" ] && wt="\$a"; prev="\$a"; done
case "\$(cat "$CODEX_MODE")" in
  ok)      mkdir -p "\$wt/.harness"; echo "codex: sound" > "\$wt/.harness/review-notes.md" ;;
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
reviewer_calls() { grep -c '^reviewer' "$CLAUDE_CALLS" 2>/dev/null | tr -d ' '; }
codex_calls()    { grep -c '^codex'    "$CODEX_CALLS" 2>/dev/null | tr -d ' '; }

RC=0; RUN=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" \
      LINEAR_API_KEY_FILE="$KEYFILE" \
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
check "fallback: exactly one Codex attempt — a dry account is never retried" "$(codex_calls)" "2"
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
check "dead: and the arm is honest" "$(result_field OLYX-79 arm)" "no_review"
check "dead: no PR was created" "$(grep -c 'pr create' "$GH_CALLS" | tr -d ' ')" "$GH_BEFORE"
check "dead: result.json carries no pr_url" "$(result_field OLYX-79 pr_url)" ""
file_has_not "$LINEAR_LOG" "OLYX-79" "dead: the ticket is not touched"
file_has "$NTFY_LOG" "done: review_failed" "dead: the phone hears about it"
if grep -F "done: review_failed" "$NTFY_LOG" | grep -qF "Priority: high"; then
  ok "dead: at high priority — only a human can top up credits"
else
  bad "dead: the review_failed push is not escalated"
fi
printf 'ok\n' > "$CODEX_MODE"; printf 'ok\n' > "$REVIEWER_MODE"

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

echo
printf 'review-fallback: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
