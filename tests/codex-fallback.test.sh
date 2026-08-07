#!/usr/bin/env bash
# The fallback Codex account: when the primary ChatGPT workspace is out of
# credits, the review retry runs on a second CODEX_HOME instead of on the same
# dry account — and says so where the operator will see it.
#
# What is pinned here:
#   1. Credits-certain (tier 1) — the attempt's log carries the workspace-credits
#      error, so the retry switches account immediately, even above the review
#      floor that would otherwise buy no retry at all.
#   2. Silent no-op (tier 2) — the single retry the harness already buys runs on
#      the fallback when one is configured.
#   3. A fallback that also comes up empty downgrades exactly as today.
#   4. Knob unset — every attempt runs on the primary CODEX_HOME, one retry, the
#      same words, no fallback anywhere in the run's artefacts.
#   5. One attempt, one account, and the label is all that is ever recorded.
#   6. sync-pr.sh's conflict resolver follows the same rule.
#
# Nothing real is contacted. `claude` (implementer), `codex` (reviewer), `gh`
# (the PR) and `curl` (ntfy) are fake binaries on PATH driven by mode files, and
# every run is a real run-task.sh / sync-pr.sh invocation against a fabricated
# repo with a local bare remote — the technique tests/pipeline-telemetry.test.sh
# uses.
#
# Usage: bash tests/codex-fallback.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-fallback-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
CODEX_CALLS="$ROOT/codex-calls.log"
CURL_LOG="$ROOT/curl.log"
CODEX_MODE="$ROOT/codex-mode"
PRIMARY_HOME="$ROOT/codex-primary"     # the station's own account
FALLBACK_HOME="$ROOT/codex-fallback"   # the second subscription

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$PRIMARY_HOME" "$FALLBACK_HOME"
: > "$CODEX_CALLS"; : > "$CURL_LOG"
printf 'credits\n' > "$CODEX_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp "$SRC/sync-pr.sh"  "$SRCDIR/sync-pr.sh"
chmod +x "$SRCDIR/run-task.sh" "$SRCDIR/sync-pr.sh"
cp "$SRC/metrics.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"

cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='true' ;;
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
# One claude stand-in, two jobs, told apart by the prompt: the implementer
# writes a diff big enough that the review floor applies to it; the Claude
# review tier (prompt says "reviewer stage") leaves notes — the evidence the
# classifier reads.
cat > "$FAKES/claude" <<'EOF'
#!/usr/bin/env bash
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
case "$prompt" in
  *"reviewer stage"*)
    mkdir -p .harness
    echo "claude tier: sound" > .harness/review-notes.md
    ;;
  *)
    seq 1 30 >> impl.txt
    git add -A
    git commit -q -m "feat: fixture change"
    ;;
esac
EOF

# Reviewer stand-in. Which account it is on comes from CODEX_HOME and nothing
# else — that is the whole plumbing under test — and every call records the
# label it derived plus the raw directory it was handed.
#
# The credits error is deliberately awkward: wrapped mid-phrase across two lines
# and capitalised differently from the code's pattern, so the match has to be
# the resilient one it claims to be.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then wt="\$a"; break; fi
  prev="\$a"
done
acct=primary
[ "\${CODEX_HOME-}" = "$FALLBACK_HOME" ] && acct=fallback
printf 'codex %s %s\n' "\$acct" "\${CODEX_HOME-<unset>}" >> "$CODEX_CALLS"
notes() { printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md"; }
dry()   { printf 'stream error: Your workspace is out of\nCredits. Top up and retry.\n'; }
case "\$(cat "$CODEX_MODE")" in
  credits)      if [ "\$acct" = fallback ]; then notes; else dry; fi ;;
  credits-both) dry ;;
  silent)       if [ "\$acct" = fallback ]; then notes; else echo "codex: done"; fi ;;
  notes)        notes ;;
  resolve)      if [ "\$acct" = fallback ]; then
                  ( cd "\$wt" && printf 'both sides\n' > f.txt && git add -A \
                    && git -c user.email=t@t -c user.name=t commit -q --no-verify -m "Merge latest main" )
                else dry; fi ;;
esac
EOF

cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
EOF

cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh"

# --- the harness under test ---------------------------------------------------
RC=0; OUT=""; RUN=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$CODEX_CALLS"; : > "$CURL_LOG"
  # -u, because the "knob unset" section means unset — a station whose shell
  # exports a real fallback account would otherwise smuggle it into the fixture
  # and the suite would assert the opposite of what it says.
  # shellcheck disable=SC2086
  env -u HARNESS_CODEX_HOME_FALLBACK \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      CODEX_HOME="$PRIMARY_HOME" \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=fallback-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
FB="HARNESS_CODEX_HOME_FALLBACK=$FALLBACK_HOME"
result()   { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
accounts() { awk '{print $2}' "$CODEX_CALLS" | paste -sd, - | tr -d ' '; }
homes()    { awk '{print $3}' "$CODEX_CALLS" | sort -u | paste -sd, - | tr -d ' '; }
first_of() { head -1 "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== tier 1: a primary that is out of credits loses the retry to the fallback =="
# ---------------------------------------------------------------------------
printf 'credits\n' > "$CODEX_MODE"
dispatch FB-CREDITS "$FB"
check "credits: two attempts — primary, then the fallback" "$(accounts)" "primary,fallback"
check "credits: and the second one really was handed the other CODEX_HOME" \
  "$(homes)" "$FALLBACK_HOME,$PRIMARY_HOME"
check "credits: the review counts as a real review" "$(result .review)" "reviewed"
check "credits: result.json names the account it ran on" "$(result .review_account)" "fallback"
check "credits: the arm stays full — nothing was left unreviewed" "$(result .arm)" "full"
check "credits: the run ships" "$(result .status)" "ready"
check "credits: and exits 0" "$RC" "0"
file_has "$CURL_LOG" "review ran on the fallback Codex account — primary is out of credits" \
  "credits: the phone push says why, in one sentence"
file_has "$RUN/timeline" "review retry — Codex (ChatGPT sub) (fallback account)" \
  "credits: the retry's stage line says which account, in a suffix the actor map tolerates"
has "$OUT" "the primary Codex account is out of credits — retrying once on the fallback Codex account" \
  "credits: the console says it before spending the retry"
exists "credits: the retry has its own log" "$RUN/codex-1-retry.log"

echo "-- one attempt, one account: the log says which, and nothing else --"
check "label: the first attempt's log opens with its account" \
  "$(first_of "$RUN/codex-1.log")" "codex account: primary"
check "label: and the retry's with the other one" \
  "$(first_of "$RUN/codex-1-retry.log")" "codex account: fallback"
LEAK=$(grep -rlF "$FALLBACK_HOME" "$RUN" 2>/dev/null | paste -sd, -)
check "label: no account directory anywhere in the run dir" "$LEAK" ""
has_not "$(cat "$CURL_LOG")" "$FALLBACK_HOME" "label: nor in anything pushed to the phone"

# ---------------------------------------------------------------------------
echo "== tier 1 outranks the review floor =="
# ---------------------------------------------------------------------------
# Above the floor a no-evidence review is recorded, never retried — because a
# second pass on the same account is expensive and unlikely. A second pass on a
# different account is neither.
dispatch FB-FLOOR "$FB HARNESS_REVIEW_MIN_SECONDS=0"
check "floor: certainty about credits buys the retry anyway" "$(accounts)" "primary,fallback"
check "floor: which produced a real review" "$(result .review)" "reviewed"
check "floor: on the fallback" "$(result .review_account)" "fallback"

dispatch FB-FLOOR-NOKNOB "HARNESS_REVIEW_MIN_SECONDS=0"
check "floor: with no fallback configured there is still only one Codex attempt" "$(accounts)" "primary"
check "floor: but certainty about credits outranks the floor here too — the Claude tier reviews" \
  "$(result .review)" "reviewed_claude"

# ---------------------------------------------------------------------------
echo "== tier 2: a silent no-op spends its one retry on the fallback =="
# ---------------------------------------------------------------------------
printf 'silent\n' > "$CODEX_MODE"
dispatch FB-SILENT "$FB"
check "silent: the retry moved account" "$(accounts)" "primary,fallback"
check "silent: and reviewed" "$(result .review)" "reviewed"
check "silent: on the fallback" "$(result .review_account)" "fallback"
has "$OUT" "review produced nothing in" "silent: the reason is still the floor's"
file_has "$CURL_LOG" "review ran on the fallback Codex account" \
  "silent: the push still says where the review happened"
has_not "$(cat "$CURL_LOG")" "primary is out of credits" \
  "silent: but never claims a credits error the log never carried"

# ---------------------------------------------------------------------------
echo "== a fallback that is also dry hands the review to the Claude tier =="
# ---------------------------------------------------------------------------
printf 'credits-both\n' > "$CODEX_MODE"
dispatch FB-BOTHDEAD "$FB"
check "both dry: two attempts, one per account — never a third Codex call" \
  "$(accounts)" "primary,fallback"
check "both dry: the Claude tier takes the review" "$(result .review)" "reviewed_claude"
check "both dry: and review_account says which backend" "$(result .review_account)" "claude"
file_has "$RUN/timeline" "review — Codex unavailable (no evidence from either Codex account) → Claude reviewer (Claude sub)" \
  "both dry: the handoff is a visible stage line"
file_has "$RUN/review-fallback" "no evidence from either Codex account" \
  "both dry: the run dir records why"
file_has "$RUN/review-notes.md" "claude tier: sound" \
  "both dry: the notes are the Claude reviewer's"
check "both dry: the run finishes on its gate" "$(result .status)" "ready"
check "both dry: the pinned arm is untouched, so a re-dispatch tries codex again" \
  "$(cat "$RUN/arm")" "full"

# ---------------------------------------------------------------------------
echo "== knob unset: a dry primary goes straight to the Claude tier =="
# ---------------------------------------------------------------------------
printf 'credits\n' > "$CODEX_MODE"
dispatch NOFB-CREDITS ""
check "unset: exactly one Codex attempt — a retry on the same dry account is certain to repeat" \
  "$(accounts)" "primary"
check "unset: no attempt is handed a different CODEX_HOME" "$(homes)" "$PRIMARY_HOME"
check "unset: the Claude tier takes the review" "$(result .review)" "reviewed_claude"
check "unset: and review_account says which backend" "$(result .review_account)" "claude"
file_has "$RUN/timeline" "review — Codex unavailable (the Codex account is out of credits) → Claude reviewer (Claude sub)" \
  "unset: the handoff names the credits cause"
# The temp fixture path has the word "fallback" in it, so these assert the
# phrases the feature introduces rather than the substring.
has_not "$OUT" "fallback Codex account"  "unset: no fallback account is ever mentioned"
has_not "$OUT" "(fallback account)"      "unset: and no stage line carries the suffix"
has_not "$(cat "$RUN/timeline")" "(fallback account)" "unset: nor does the timeline"
has_not "$(cat "$CURL_LOG")" "fallback Codex account" "unset: nor any notification"

printf 'notes\n' > "$CODEX_MODE"
dispatch NOFB-NOTES ""
check "unset: a review that works is one attempt, as before" "$(accounts)" "primary"
check "unset: reviewed" "$(result .review)" "reviewed"
check "unset: on the primary" "$(result .review_account)" "primary"

# An arm that never attempts a review carries no account field at all: an empty
# string would be indistinguishable from "primary" to every reader.
dispatch FB-SKIPARM "$FB HARNESS_SKIP_REVIEW=1"
check "skip arm: no review attempt" "$(accounts)" ""
check "skip arm: and no account field in result.json" \
  "$(jq -r 'has("review_account")' "$RUN/result.json")" "false"
check "skip arm: review recorded as skipped, as before" "$(result .review)" "skipped"

# ---------------------------------------------------------------------------
echo "== metrics.sh --report counts the reviews the primary could not take =="
# ---------------------------------------------------------------------------
REPORTH="$ROOT/report-harness"; RRUNS="$REPORTH/runs"
mkdir -p "$RRUNS"
mkrun() {  # $1 = run id, $2 = the whole result.json
  mkdir -p "$RRUNS/$1"
  printf '%s\n' "$2" > "$RRUNS/$1/result.json"
}
mkrun F-1 '{"ticket":"F-1","status":"ready","arm":"full","review":"reviewed",
  "review_account":"fallback","worktree":"/w/myapp-f-1","metrics":{"wall_seconds":600}}'
mkrun F-2 '{"ticket":"F-2","status":"ready","arm":"full","review":"reviewed",
  "review_account":"primary","worktree":"/w/myapp-f-2","metrics":{"wall_seconds":600}}'
mkrun F-3 '{"ticket":"F-3","status":"ready","arm":"no_review","review":"skipped",
  "worktree":"/w/myapp-f-3","metrics":{"wall_seconds":600}}'
REPORT="$(env HARNESS_DIR="$REPORTH" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
has "$REPORT" "fallback-account reviews 1 <- the primary Codex account needs topping up" \
  "report: counts the fallback reviews and says what to do about it"
has "$REPORT" "reviewed 2 66.7" "report: the review classes are untouched by the new field"

REPORT="$(env HARNESS_DIR="$HARNESS" bash "$HARNESS/metrics.sh" --report | tr -s ' ')"
has "$REPORT" "fallback-account reviews" "live: the line renders over real run dirs too"

# ---------------------------------------------------------------------------
echo "== sync-pr.sh: the conflict resolver follows the same rule =="
# ---------------------------------------------------------------------------
# A published PR branch that conflicts with a moved base, resolved by codex —
# whose primary account is dry. The knob has to reach this script too, or a run
# whose review already fell back still parks on a conflict nobody can resolve.
SYNC="SYNC-1"
git -C "$REPO" checkout -q -b "fix/$SYNC" main
printf 'branch side\n' > "$REPO/f.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: branch side"
git -C "$REPO" push -q -u origin "fix/$SYNC"
git -C "$REPO" checkout -q main
printf 'base side\n' > "$REPO/f.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: base side"
git -C "$REPO" push -q origin main
git -C "$REPO" branch -q -D "fix/$SYNC"

SRUN="$RUNS/$SYNC"; mkdir -p "$SRUN"
printf '# fixture task\n' > "$SRUN/brief.md"
jq -n --arg wt "$ROOT/greenapp-sync-1" --arg b "fix/$SYNC" \
  '{ticket:"SYNC-1",status:"ready",worktree:$wt,branch:$b,base:"main"}' > "$SRUN/result.json"

printf 'resolve\n' > "$CODEX_MODE"
: > "$CODEX_CALLS"
env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
    CODEX_BIN="$FAKES/codex" CODEX_HOME="$PRIMARY_HOME" \
    HARNESS_NOTIFY=0 HARNESS_CODEX_HOME_FALLBACK="$FALLBACK_HOME" \
    bash "$SRCDIR/sync-pr.sh" "$SYNC" > "$ROOT/sync.log" 2>&1
SRC_RC=$?
SOUT=$(cat "$ROOT/sync.log")
check "sync-pr: the dry primary attempt is followed by one on the fallback" \
  "$(accounts)" "primary,fallback"
check "sync-pr: which resolved the merge, so the sync succeeds" "$SRC_RC" "0"
has "$SOUT" "the fallback account takes the next attempt" "sync-pr: and says so"
file_has "$SRUN/timeline" "conflict resolution (Codex, ChatGPT sub, fallback account)" \
  "sync-pr: the stage line names the account without leaving the sync prefix"
check "sync-pr: each attempt's log records its own account" \
  "$(first_of "$SRUN/codex-post-sync.log"),$(first_of "$SRUN/codex-post-sync-fallback.log")" \
  "codex account: primary,codex account: fallback"

echo
printf 'codex fallback: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
