#!/usr/bin/env bash
# Find, refute, fix: a review finding only earns an edit by surviving a session
# whose whole job is to disprove it.
#
# What is pinned here:
#   1. A real finding survives refutation and gets exactly one commit naming it.
#   2. A spurious finding is refuted, produces NO edit at all, and the run still
#      records what was dropped and on what evidence.
#   3. Refutation that leaves nothing behind — a crash, a timeout, the knob off —
#      degrades to today's single-pass review (every finding promoted) and says so
#      in the notes and in result.json rather than quietly looking refuted.
#   4. A reviewer that writes no findings.json is the single-pass review this
#      replaced: one backend call, no extra passes, no new fields.
#   5. The three passes are three separate sessions, and only the first one is
#      given the review checklist.
#
# Nothing real is contacted. `claude` (implementer), `codex` (reviewer), `gh`
# (the PR) and `curl` (ntfy) are fake binaries on PATH driven by mode files, and
# every run is a real run-task.sh invocation against a fabricated repo with a
# local bare remote — the technique tests/review-truth.test.sh uses.
#
# Usage: bash tests/review-refute.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-refute-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
ROLES="$ROOT/roles.log"          # one line per backend call: find | refute | fix
FIND_PROMPT="$ROOT/find-prompt.txt"
REFUTE_PROMPT_FILE="$ROOT/refute-prompt.txt"
FIX_PROMPT_FILE="$ROOT/fix-prompt.txt"
FIND_MODE="$ROOT/find-mode"
REFUTE_MODE="$ROOT/refute-mode"
BACKEND="$ROOT/backend"          # codex | claude — which tier the fake plays
TIMEOUTS="$ROOT/timeouts.log"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES"
: > "$ROLES"; : > "$TIMEOUTS"
printf 'two\n'      > "$FIND_MODE"
printf 'spurious\n' > "$REFUTE_MODE"
printf 'codex\n'    > "$BACKEND"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# Every harness script reads lib/common.sh from beside itself, so the shared
# helpers travel with both staged copies — the layout install.sh produces.
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"

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
# The reviewer's three passes, in one stand-in: which pass it is comes from the
# prompt and nothing else, which is also the assertion that the harness really
# does send three different prompts. Whatever backend runs it plays the same
# three roles, so the Claude tier is exercised by the same body.
cat > "$ROOT/review-body.sh" <<EOF
#!/usr/bin/env bash
# \$1 = the worktree, \$2 = the prompt
wt="\$1"; prompt="\$2"
case "\$prompt" in
  *"You are the reviewer stage"*)   role=find;   printf '%s' "\$prompt" > "$FIND_PROMPT" ;;
  *"You are the refutation stage"*) role=refute; printf '%s' "\$prompt" > "$REFUTE_PROMPT_FILE" ;;
  *"You are the fix stage"*)        role=fix;    printf '%s' "\$prompt" > "$FIX_PROMPT_FILE" ;;
  *) role=other ;;
esac
printf '%s\n' "\$role" >> "$ROLES"
cd "\$wt" 2>/dev/null || exit 0
mkdir -p .harness
case "\$role" in
  find)
    echo "reviewer: read the diff, changed nothing" > .harness/review-notes.md
    echo "a correct change keeps the counter one-based" > .harness/expected-properties.md
    case "\$(cat "$FIND_MODE")" in
      mutate-once)
        printf 'reviewer mutation\n' > other.txt
        git add other.txt
        git commit -q -m "bad finder edit"
        printf 'two\n' > "$FIND_MODE"
        ;;
      two) cat > .harness/findings.json <<'JSON'
[{"file": "impl.txt", "line": 1,
  "claim": "the counter starts at zero and is never advanced",
  "scenario": "a list of one element reports a count of zero"},
 {"file": "other.txt", "line": 1,
  "claim": "other.txt leaks the file handle it opens",
  "scenario": "repeated calls exhaust the descriptor table"}]
JSON
        ;;
      clean)  printf '[]\n' > .harness/findings.json ;;
      junk)   printf 'this is not json\n' > .harness/findings.json ;;
      legacy) : ;;
    esac
    ;;
  refute)
    case "\$(cat "$REFUTE_MODE")" in
      spurious) cat > .harness/refuted.json <<'JSON'
[{"id": "F1", "refuted": false, "reason": "impl.txt:1 really does start at zero"},
 {"id": "F2", "refuted": true,  "reason": "other.txt:1 closes the handle in a finally block"}]
JSON
        ;;
      all) cat > .harness/refuted.json <<'JSON'
[{"id": "F1", "refuted": true, "reason": "impl.txt:1 is never reached"},
 {"id": "F2", "refuted": true, "reason": "other.txt:1 closes the handle in a finally block"}]
JSON
        ;;
      no-reason) cat > .harness/refuted.json <<'JSON'
[{"id": "F1", "refuted": true, "reason": "   "},
 {"id": "F2", "refuted": true, "reason": "other.txt:1 closes the handle in a finally block"}]
JSON
        ;;
      mutate) cat > .harness/refuted.json <<'JSON'
[{"id": "F1", "refuted": true, "reason": "impl.txt:1 is never reached"},
 {"id": "F2", "refuted": true, "reason": "other.txt:1 closes the handle in a finally block"}]
JSON
        printf 'refuter mutation\n' > other.txt
        git add other.txt
        git commit -q -m "bad refuter edit"
        ;;
      fail-valid) cat > .harness/refuted.json <<'JSON'
[{"id": "F1", "refuted": true, "reason": "impl.txt:1 is never reached"},
 {"id": "F2", "refuted": true, "reason": "other.txt:1 closes the handle in a finally block"}]
JSON
        exit 7
        ;;
      none) echo "refuter: died before writing anything" ;;
    esac
    ;;
  fix)
    for id in \$(jq -r '.[].id' .harness/promoted.json 2>/dev/null); do
      printf 'fixed\n' > "fix-\$id.txt"
      git add -A
      git commit -q -m "fix(impl): address the finding [\$id]"
    done
    printf 'fix pass: done\n' >> .harness/review-notes.md
    ;;
esac
EOF
chmod +x "$ROOT/review-body.sh"

# One claude stand-in, two jobs, told apart by the prompt: the implementer
# leaves a diff big enough that the review floor applies to it, and the Claude
# review tier plays the same three passes as Codex through the shared body.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in
  *"You are the reviewer stage"*|*"You are the refutation stage"*|*"You are the fix stage"*)
    "$ROOT/review-body.sh" "\$PWD" "\$prompt" ;;
  *)
    seq 1 30 > impl.txt
    printf 'untouched\n' > other.txt
    git add -A
    # A re-dispatch resumes onto a tree this already wrote: nothing to commit is
    # a resumed implementer, not a failed one.
    git commit -q -m "feat: fixture change" || true
    ;;
esac
EOF

cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""; prompt=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && wt="\$a"
  prev="\$a"; prompt="\$a"
done
"$ROOT/review-body.sh" "\$wt" "\$prompt"
EOF

cat > "$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$FAKES/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TIMEOUTS"
shift
exec "\$@"
EOF

cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh" \
  "$FAKES/timeout"

# --- the harness under test ---------------------------------------------------
RUN=""; WT=""
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2" lc
  lc=$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')
  RUN="$RUNS/$ticket"; WT="$ROOT/greenapp-$lc"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$ROLES"; : > "$TIMEOUTS"
  # The fallback account is a documented operator knob: a station that has one
  # configured would spend a second Codex attempt inside runs this suite counts
  # backend calls in.
  # shellcheck disable=SC2086
  env -u CODEX_HOME -u HARNESS_CODEX_HOME_FALLBACK \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      IMPLEMENTER_PROVIDER=claude \
      HARNESS_REVIEW_NETWORK=0 \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=review-refute-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  return 0
}
result() { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
roles()  { paste -sd, - < "$ROLES" | tr -d ' '; }
rounds() { awk '{ print $1 $2 }' "$RUN/gate-rounds.log" | paste -sd, - | tr -d ' '; }
subjects() { git -C "$WT" log --format='%s' "$(cat "$RUN/opus-head")..HEAD" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== a real finding survives, a spurious one is disproved =="
# ---------------------------------------------------------------------------
dispatch RR-SPLIT ""
check "split: three passes ran, in order, each in its own session" \
  "$(roles)" "find,refute,fix"
check "split: the run ships" "$(result .status)" "ready"
check "split: recorded as a real review" "$(result .review)" "reviewed"

echo "-- the counts --"
check "split: two findings"        "$(result .review_findings.found)"    "2"
check "split: one of them refuted" "$(result .review_findings.refuted)"  "1"
check "split: one promoted"        "$(result .review_findings.promoted)" "1"
check "split: and one fixed"       "$(result .review_findings.fixed)"    "1"
check "split: the refutation pass itself is recorded as having worked" \
  "$(result .review_findings.refute)" "ok"

echo "-- one commit per promoted finding, and none for the refuted one --"
check "split: the reviewer side committed exactly once" \
  "$(result .metrics.codex_commits)" "1"
has "$(subjects)" "[F1]" "split: the commit names the finding it fixes"
has_not "$(subjects)" "[F2]" "split: and no commit claims the refuted one"
exists "split: the promoted finding was acted on" "$WT/fix-F1.txt"
absent "split: the refuted finding produced no edit at all" "$WT/fix-F2.txt"
check "split: the file the spurious finding pointed at is untouched" \
  "$(cat "$WT/other.txt")" "untouched"

echo "-- the evidence each pass left --"
check "split: findings.json is the normalised list, ids and all" \
  "$(jq -r '[.[].id] | join(",")' "$RUN/findings.json")" "F1,F2"
check "split: with the file and line the reviewer named" \
  "$(jq -r '.[0].file + ":" + (.[0].line|tostring)' "$RUN/findings.json")" "impl.txt:1"
check "split: refuted.json holds the dropped finding" \
  "$(jq -r '[.[].id] | join(",")' "$RUN/refuted.json")" "F2"
check "split: promoted.json holds the survivor" \
  "$(jq -r '[.[].id] | join(",")' "$RUN/promoted.json")" "F1"
file_has "$RUN/refuted.json" "closes the handle in a finally block" \
  "split: and carries the refuter's own reason, not a shrug"
exists "split: the refutation pass has its own log" "$RUN/codex-1-refute.log"
exists "split: and so does the fix pass" "$RUN/codex-1-fix.log"
file_has "$RUN/expected-properties.md" "keeps the counter one-based" \
  "split: the spec the reviewer wrote before the diff is kept beside the findings"

echo "-- review-notes.md carries the split, for the planner's verdict --"
NOTES="$RUN/review-notes.md"
file_has "$NOTES" "found 2 · refuted 1 · promoted 1 · fixed 1" \
  "notes: the counts are in the heading"
file_has "$NOTES" "### Promoted" "notes: the promoted section is there"
file_has "$NOTES" "### Refuted"  "notes: and the refuted one"
file_has "$NOTES" "**F2**"       "notes: naming the finding that was dropped"
file_has "$NOTES" "refuted: other.txt:1 closes the handle in a finally block" \
  "notes: with the evidence it was dropped on"
file_has "$NOTES" "reviewer: read the diff" \
  "notes: the reviewer's own notes are still there under the ledger"

echo "-- the passes are given three different jobs --"
has "$(cat "$FIND_PROMPT")" "You FIND; you do not fix" \
  "prompt: the find pass is told to change nothing"
has "$(cat "$FIND_PROMPT")" ".harness/expected-properties.md" \
  "prompt: and to write the expected properties before it opens the diff"
has "$(cat "$FIND_PROMPT")" "Gate-gaming" \
  "prompt: gate-gaming is still checklist item 1"
has "$(cat "$FIND_PROMPT")" "time-of-check-to-time-of-use" \
  "prompt: the blind-spot checklist names TOCTOU"
has "$(cat "$FIND_PROMPT")" "concurrency and races" \
  "prompt: and races"
has "$(cat "$FIND_PROMPT")" "compositional authorization" \
  "prompt: and compositional authorization"
has "$(cat "$FIND_PROMPT")" "gate integrity flags above" \
  "prompt: the find pass starts from the deterministic flags"
has "$(cat "$REFUTE_PROMPT_FILE")" "your job is to DISPROVE them" \
  "prompt: the refutation pass is asked to disprove, not to review"
has_not "$(cat "$REFUTE_PROMPT_FILE")" "Gate-gaming" \
  "prompt: it is not handed the review checklist as well"
has "$(cat "$REFUTE_PROMPT_FILE")" "Change NOTHING" \
  "prompt: and it edits nothing"
has "$(cat "$FIX_PROMPT_FILE")" "ONE COMMIT PER FINDING" \
  "prompt: the fix pass commits one per finding"
has "$(cat "$FIX_PROMPT_FILE")" ".harness/promoted.json" \
  "prompt: over the promoted list and nothing else"

# ---------------------------------------------------------------------------
echo "== every finding refuted: nothing is edited at all =="
# ---------------------------------------------------------------------------
printf 'all\n' > "$REFUTE_MODE"
dispatch RR-ALLREFUTED ""
check "all refuted: no fix pass is spawned" "$(roles)" "find,refute"
check "all refuted: two found, two dropped" \
  "$(result .review_findings.found),$(result .review_findings.refuted)" "2,2"
check "all refuted: nothing promoted" "$(result .review_findings.promoted)" "0"
check "all refuted: and nothing fixed" "$(result .review_findings.fixed)" "0"
check "all refuted: the reviewer side committed nothing" \
  "$(result .metrics.codex_commits)" "0"
check "all refuted: so the post-review gate is skipped, as it is for any no-op review" \
  "$(rounds)" "1pass,2skipped"
check "all refuted: the run still ships a reviewed diff" "$(result .status)" "ready"
file_has "$RUN/review-notes.md" "None." "all refuted: the promoted section says so"
printf 'spurious\n' > "$REFUTE_MODE"

# ---------------------------------------------------------------------------
echo "== a refutation pass that leaves nothing behind is single-pass behaviour =="
# ---------------------------------------------------------------------------
# The degradation that matters: never silently drop a finding because the
# refuter died. Everything is promoted — which is exactly what the single-pass
# review this replaces would have done — and the run says so.
printf 'none\n' > "$REFUTE_MODE"
dispatch RR-REFUTE-DEAD ""
check "refute dead: the fix pass still runs" "$(roles)" "find,refute,fix"
check "refute dead: nothing is recorded as refuted" \
  "$(result .review_findings.refuted)" "0"
check "refute dead: every finding is promoted" \
  "$(result .review_findings.promoted)" "2"
check "refute dead: and every one of them fixed" \
  "$(result .review_findings.fixed)" "2"
check "refute dead: each fix has its own commit" \
  "$(result .metrics.codex_commits)" "2"
check "refute dead: the state is recorded honestly, not as a clean pass" \
  "$(result .review_findings.refute)" "failed"
exists "refute dead: the first finding was acted on"  "$WT/fix-F1.txt"
exists "refute dead: and so was the second"           "$WT/fix-F2.txt"
file_has "$RUN/review-notes.md" "fell back to single-pass behaviour" \
  "refute dead: the notes say the promoted list is unchecked"
has "$(cat "$ROOT/run-RR-REFUTE-DEAD.log")" "the refutation pass left no usable verdicts" \
  "refute dead: and the console says it before spending the fix pass"
check "refute dead: the run still ships" "$(result .status)" "ready"
printf 'spurious\n' > "$REFUTE_MODE"

echo "-- a failed process cannot launder verdicts it wrote before dying --"
printf 'fail-valid\n' > "$REFUTE_MODE"
dispatch RR-REFUTE-FAIL-VALID ""
check "refute failed with json: the process failure is recorded" \
  "$(result .review_findings.refute)" "failed"
check "refute failed with json: no finding is dropped" \
  "$(result .review_findings.refuted)" "0"
check "refute failed with json: every finding is promoted" \
  "$(result .review_findings.promoted)" "2"
printf 'spurious\n' > "$REFUTE_MODE"

echo "-- a zero timeout cannot disable the refute time-box --"
dispatch RR-REFUTE-TIMEOUT-ZERO "HARNESS_REFUTE_TIMEOUT=0"
check "zero timeout: the normal three passes still run" \
  "$(roles)" "find,refute,fix"
check "zero timeout: refute uses the positive default" \
  "$(grep -c '^900$' "$TIMEOUTS" | tr -d ' ')" "1"

echo "-- a refutation needs evidence before it can drop a finding --"
printf 'no-reason\n' > "$REFUTE_MODE"
dispatch RR-REFUTE-NO-REASON ""
check "no reason: the unsupported verdict is promoted" \
  "$(jq -r '[.[].id] | join(",")' "$RUN/promoted.json")" "F1"
check "no reason: the evidenced verdict is still refuted" \
  "$(jq -r '[.[].id] | join(",")' "$RUN/refuted.json")" "F2"
printf 'spurious\n' > "$REFUTE_MODE"

echo "-- the refuter cannot mutate the reviewed worktree --"
printf 'mutate\n' > "$REFUTE_MODE"
dispatch RR-REFUTE-MUTATES ""
check "refute mutation: its source edit was discarded" \
  "$(cat "$WT/other.txt")" "untouched"
has_not "$(subjects)" "bad refuter edit" \
  "refute mutation: its commit did not land on the reviewed branch"
check "refute mutation: its verdicts are discarded with its failed pass" \
  "$(result .review_findings.refute),$(result .review_findings.refuted)" "failed,0"
printf 'spurious\n' > "$REFUTE_MODE"

echo "-- the find pass cannot mutate the reviewed worktree either --"
printf 'mutate-once\n' > "$FIND_MODE"
dispatch RR-FIND-MUTATES ""
check "find mutation: the clean retry completed the three stages" \
  "$(roles)" "find,find,refute,fix"
check "find mutation: its source edit was discarded before the retry" \
  "$(cat "$WT/other.txt")" "untouched"
has_not "$(subjects)" "bad finder edit" \
  "find mutation: its commit did not land on the reviewed branch"
check "find mutation: only the promoted fix commit remains" \
  "$(result .metrics.codex_commits)" "1"
printf 'two\n' > "$FIND_MODE"

echo "-- and the knob does the same thing, on purpose --"
dispatch RR-REFUTE-OFF "HARNESS_REVIEW_REFUTE=0"
check "knob off: no refutation pass is spawned" "$(roles)" "find,fix"
check "knob off: everything is promoted" "$(result .review_findings.promoted)" "2"
check "knob off: recorded as off rather than as a pass that ran" \
  "$(result .review_findings.refute)" "off"
file_has "$RUN/review-notes.md" "HARNESS_REVIEW_REFUTE=0" \
  "knob off: the notes name the knob that skipped it"

# ---------------------------------------------------------------------------
echo "== a reviewer that writes no findings is the review this replaced =="
# ---------------------------------------------------------------------------
printf 'legacy\n' > "$FIND_MODE"
dispatch RR-LEGACY ""
check "legacy: exactly one backend call — no extra passes are paid for" \
  "$(roles)" "find"
check "legacy: recorded as a real review on its notes, as before" \
  "$(result .review)" "reviewed"
check "legacy: and result.json carries no findings field to misread" \
  "$(jq -r 'has("review_findings")' "$RUN/result.json")" "false"
check "legacy: the run ships" "$(result .status)" "ready"
file_has_not "$RUN/review-notes.md" "### Promoted" \
  "legacy: nothing is appended to notes that never had findings"

echo "-- an unparseable findings file is treated the same way --"
printf 'junk\n' > "$FIND_MODE"
dispatch RR-JUNK ""
check "junk: no pass is spawned on a file nothing can read" "$(roles)" "find"
check "junk: and no counts are invented for it" \
  "$(jq -r 'has("review_findings")' "$RUN/result.json")" "false"
check "junk: the run still ships on the review that happened" \
  "$(result .status)" "ready"

echo "-- an explicit empty array is an answer, and is recorded as one --"
printf 'clean\n' > "$FIND_MODE"
dispatch RR-CLEAN ""
check "clean: nothing to refute, so nothing is spawned" "$(roles)" "find"
check "clean: zero findings, recorded" "$(result .review_findings.found)" "0"
check "clean: nothing promoted" "$(result .review_findings.promoted)" "0"
check "clean: the run ships" "$(result .status)" "ready"
printf 'two\n' > "$FIND_MODE"

# ---------------------------------------------------------------------------
echo "== the Claude tier runs the same three passes =="
# ---------------------------------------------------------------------------
# Role separation, not cross-vendor separation, is what the split buys: on a
# machine with no codex CLI the fresh Claude session that reviews also gets a
# fresh one to refute it.
NOCODEX="$ROOT/no-such-codex"
dispatch RR-CLAUDE "CODEX_BIN=$NOCODEX"
check "claude tier: all three passes ran there too" "$(roles)" "find,refute,fix"
check "claude tier: recorded as the Claude tier's review" \
  "$(result .review)" "reviewed_claude"
check "claude tier: with the same split" \
  "$(result .review_findings.refuted),$(result .review_findings.promoted)" "1,1"
exists "claude tier: the refutation pass has its own log" "$RUN/claude-1-refute.log"
exists "claude tier: and so does the fix pass" "$RUN/claude-1-fix.log"
file_has "$RUN/timeline" "review refute — Claude reviewer (Claude sub)" \
  "claude tier: the refutation is a visible stage line"
file_has "$RUN/timeline" "review fix — Claude reviewer (Claude sub)" \
  "claude tier: and so is the fix"

# ---------------------------------------------------------------------------
echo "== last dispatch's findings never judge this one =="
# ---------------------------------------------------------------------------
# findings.json is read as review evidence, so one left in the worktree by an
# earlier attempt would be read as proof that THIS review happened — and its
# stale claims would be sent to a refutation pass that never saw them raised.
printf 'legacy\n' > "$FIND_MODE"
dispatch RR-STALE ""
check "stale: the first dispatch shipped" "$(result .status)" "ready"
printf '[{"file":"gone.txt","claim":"a claim from an earlier revision"}]\n' \
  > "$WT/.harness/findings.json"
printf 'properties from an earlier revision\n' \
  > "$WT/.harness/expected-properties.md"
dispatch RR-STALE "HARNESS_REDISPATCH=1"
exists "stale: the previous attempt's findings are harvested, not deleted" \
  "$RUN/findings.prev.json"
file_has "$RUN/findings.prev.json" "an earlier revision" \
  "stale: with what they actually said"
check "stale: and no pass is run against them" "$(roles)" "find"
check "stale: nor are they counted as this attempt's" \
  "$(jq -r 'has("review_findings")' "$RUN/result.json")" "false"
file_has "$RUN/expected-properties.prev.md" "properties from an earlier revision" \
  "stale: previous expected properties are preserved separately"
file_has "$RUN/expected-properties.md" "keeps the counter one-based" \
  "stale: current expected properties describe the current review"
printf 'two\n' > "$FIND_MODE"

echo
printf 'review refute: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
