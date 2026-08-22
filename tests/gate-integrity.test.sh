#!/usr/bin/env bash
# The gate learns to tell a discriminating test from theater.
#
# Between the implementer's gate round and the review stage, a deterministic
# check (lib/gate-integrity.sh) replays this branch's new and changed test files
# against the UNPATCHED base tree and reads the diff for the structural
# signatures of a gate made green rather than earned. It only ever flags: the
# findings reach result.json and the reviewer's prompt, and nothing about the
# run's statuses or stage flow moves because of them.
#
# Five scenarios, each a real run-task.sh invocation against a fabricated repo
# with a local bare remote — the technique tests/review-truth.test.sh uses:
#
#   1. a new test that passes on base   -> non_discriminating, named in the prompt
#   2. a deleted test file              -> flagged
#   3. an it.only introduced            -> flagged
#   4. a replay whose runner is broken  -> not_run, and the run finishes normally
#   5. a diff that touches no test      -> "No flags", empty flags in result.json
#
# plus runner-selection, timeout, rename and assertion-count regressions.
#
# Nothing real is contacted: `claude` (implementer), `codex` (reviewer), `gh`
# (the PR), `curl` (ntfy), `npm` and `yarn` (the replayed test runners) are fake
# binaries on PATH, driven by mode files.
#
# Usage: bash tests/gate-integrity.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-integrity-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has(){ if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
IMPL_MODE="$ROOT/impl-mode"      # which diff the implementer fake produces
NPM_MODE="$ROOT/npm-mode"        # ok | broken
PROMPT="$ROOT/review-prompt.txt" # the prompt the reviewer was handed

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$HARNESS/lib"
printf 'clean\n' > "$IMPL_MODE"
printf 'ok\n'    > "$NPM_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp -R "$SRC/lib" "$SRCDIR/lib"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp "$SRC/lib/common.sh" "$HARNESS/lib/common.sh"
cp "$SRC/lib/gate-integrity.sh" "$HARNESS/lib/"

# `true`, not the empty string: an unset value means "auto-detect", and the
# fixture repo has a package.json, so a blank INSTALL_CMD would become `npm ci`.
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD='true'; GATE_CMD='true' ;;
  esac
}
EOF

# The repo under test: an npm project whose "tests" are shell scripts, so the
# fake runner can execute them for real and their verdict against the base tree
# is the thing being measured rather than something the fixture asserts.
BARE="$ROOT/origin.git"
REPO="$ROOT/greenapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
mkdir -p "$REPO/src" "$REPO/tests" "$REPO/.github/workflows"
printf '{"name":"greenapp","scripts":{"test":"fake"}}\n' > "$REPO/package.json"
: > "$REPO/package-lock.json"
printf 'hello world again\n' > "$REPO/src/app.js"
printf 'jobs:\n  test:\n    runs-on: ubuntu-latest\n' > "$REPO/.github/workflows/ci.yml"
cat > "$REPO/tests/old.test.js" <<'EOF'
assert() { grep -q "$1" src/app.js || exit 1; }
assert hello
assert world
assert again
EOF
printf 'grep -q hello src/app.js\n' > "$REPO/tests/doomed.test.js"
printf 'assert(1); assert(2); assert(3)\n' > "$REPO/tests/packed.test.js"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# --- fakes -------------------------------------------------------------------
# The implementer, one diff per scenario. Every mode leaves the tree in a state
# the gate (`true`) accepts, so what varies between runs is only what the
# integrity check has to say about it.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in
  *"reviewer stage"*)
    printf '%s' "\$prompt" > "$PROMPT"
    mkdir -p .harness
    echo "reviewed" > .harness/review-notes.md
    exit 0 ;;
esac
# Every mode appends to src/app.js rather than rewriting it, so the tests the
# base commit already carries keep passing and only the scenario under test
# changes what the integrity check has to say.
case "\$(cat "$IMPL_MODE")" in
  replay)
    printf 'const PATCHED = 4242\n'       >> src/app.js
    printf 'exit 0\n'                      > tests/passes-anywhere.test.js
    printf 'grep -q PATCHED src/app.js\n'  > tests/discriminates.test.js
    ;;
  newrunner)
    printf '{"name":"greenapp","scripts":{"test":"fake"}}\n' > package.json
    printf 'exit 0\n' > tests/passes-anywhere.test.js
    ;;
  cameltest)
    printf 'more\n' >> src/app.js
    printf 'exit 0\n' > src/WidgetTest.tsx
    ;;
  deleted)
    printf 'more\n' >> src/app.js
    rm -f tests/doomed.test.js
    ;;
  renamed)
    printf 'more\n' >> src/app.js
    git mv tests/doomed.test.js src/doomed.js
    ;;
  only)
    printf 'more\n' >> src/app.js
    printf 'it.only "the case" 2>/dev/null || true\n' >> tests/old.test.js
    ;;
  gaming)
    printf 'const TOKEN = "supersecret42"\n' >> src/app.js
    printf 'schedule: nightly\n' >> .github/workflows/ci.yml
    { echo 'assert() { grep -q "\$1" src/app.js || exit 1; }'
      echo 'assert hello'
      echo 'assert "supersecret42"'
    } > tests/old.test.js
    printf 'assert(1)\n' > tests/packed.test.js
    ;;
  clean)
    printf 'more\n' >> src/app.js
    ;;
esac
git add -A
git commit -q -m "feat: fixture change"
EOF

# The reviewer. It only has to keep its prompt and leave evidence behind.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""; last=""
for a in "\$@"; do
  [ "\$prev" = "-C" ] && [ -z "\$wt" ] && wt="\$a"
  prev="\$a"; last="\$a"
done
printf '%s' "\$last" > "$PROMPT"
printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md"
EOF

# The replayed test runner. `npm test --silent -- <file>` runs that one file;
# broken mode is the runner that cannot start at all, which is the whole point
# of scenario 4.
cat > "$FAKES/npm" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = test ] || exit 0
[ "\$(cat "$NPM_MODE")" = broken ] && exit 127
[ "\$(cat "$NPM_MODE")" = notests ] && { echo 'Error: no test specified'; exit 1; }
[ "\$(cat "$NPM_MODE")" = slow ] && sleep 4
last=""
for a in "\$@"; do last="\$a"; done
[ -f "\$last" ] || exit 1
bash "\$last"
EOF

cat > "$FAKES/yarn" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = test ] || exit 0
last=""
for a in "$@"; do last="$a"; done
[ -f "$last" ] || exit 1
bash "$last"
EOF

cat > "$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr create") echo "https://example.invalid/pr/1" ;;
  *)           exit 1 ;;
esac
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/npm" "$FAKES/yarn" "$FAKES/curl" "$FAKES/gh"

# --- the harness under test ---------------------------------------------------
RUN=""
BRIEF_EXTRA=""   # what this dispatch's brief asks for beyond the default
dispatch() {  # $1 = run id, $2 = implementer mode, $3 = VAR=VAL overrides (may be empty)
  local ticket="$1"
  RUN="$RUNS/$ticket"
  printf '%s\n' "$2" > "$IMPL_MODE"
  mkdir -p "$RUN"
  printf '# fixture task\n\nChange src/app.js.\n%s\n' "$BRIEF_EXTRA" > "$RUN/brief.md"
  : > "$PROMPT"
  # shellcheck disable=SC2086
  env -u CODEX_HOME -u HARNESS_CODEX_HOME_FALLBACK \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      HARNESS_NOTIFY=0 HARNESS_VERIFY=0 \
      $3 \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  return 0
}
result()   { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
integrity(){ jq -r "$1 // \"\"" "$RUN/gate-integrity.json" 2>/dev/null; }
kinds()    { jq -r '[.flags[].kind] | sort | join(",")' "$RUN/gate-integrity.json" 2>/dev/null; }
flagged()  { # $1 = kind -> the files flagged with it, comma-separated
  jq -r --arg k "$1" '[.flags[] | select(.kind == $k) | .file] | sort | join(",")' \
    "$RUN/gate-integrity.json" 2>/dev/null
}
rounds()   { awk '{ print $1 $2 }' "$RUN/gate-rounds.log" | paste -sd, - | tr -d ' '; }
prompt()   { cat "$PROMPT" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== a test that passes on unpatched code is theater, and says so =="
# ---------------------------------------------------------------------------
dispatch GI-REPLAY replay ""
check "replay: the runner that ran it is named" "$(integrity .replay.runner)" "npm"
check "replay: the replay reports itself as having run" \
  "$(integrity .replay.status)" "ok"
check "replay: the test that only passes on the patched tree discriminates" \
  "$(integrity '.replay.files.discriminating | join(",")')" "tests/discriminates.test.js"
check "replay: the test that passes anywhere does not" \
  "$(integrity '.replay.files.non_discriminating | join(",")')" "tests/passes-anywhere.test.js"
check "replay: and the counts say the same thing" \
  "$(integrity '"\(.replay.discriminating)/\(.replay.non_discriminating)/\(.replay.not_run)"')" \
  "1/1/0"
check "replay: the non-discriminating test is a flag of its own kind" \
  "$(flagged non_discriminating_test)" "tests/passes-anywhere.test.js"
has "$(prompt)" "## Gate integrity flags" \
  "replay: the reviewer is handed the section"
has "$(prompt)" "tests/passes-anywhere.test.js" \
  "replay: naming the test that proves nothing"
has "$(prompt)" "passes there unchanged" \
  "replay: and what the replay measured"
has "$(prompt)" "1. Gate-gaming" \
  "replay: the anti-gaming checklist is still there, now with evidence in front of it"
check "replay: result.json carries the counts" \
  "$(result '.gate_integrity.replay.non_discriminating')" "1"
check "replay: and the file lists" \
  "$(result '.gate_integrity.replay.files.non_discriminating | join(",")')" \
  "tests/passes-anywhere.test.js"
check "replay: the run itself is untouched — it ships" "$(result .status)" "ready"
check "replay: on the gate rounds it always had" "$(rounds)" "1pass,2skipped"
if [ -s "$RUN/gate-integrity-replay.log" ]; then
  ok "replay: the runner transcript is kept for a human"
else
  bad "replay: the runner transcript is kept for a human"
fi
# The same block, where the reviewer's file view is: beside gate-latest.log.
WT="$ROOT/greenapp-gi-replay"
file_has "$WT/.harness/gate-integrity.log" "## Gate integrity flags" \
  "replay: the flags also sit beside gate-latest.log in the worktree"
file_has "$WT/.harness/gate-integrity.log" "tests/passes-anywhere.test.js" \
  "replay: naming the same test there"
check "replay: and that artifact is orchestration metadata git never sees" \
  "$(git -C "$WT" status --porcelain | grep -c harness | tr -d ' ')" "0"
# The scratch worktree is the one piece of state this stage creates outside the
# run dir. A run that leaves it behind leaks a checkout per dispatch.
check "replay: the scratch worktree it built is gone again" \
  "$(git -C "$REPO" worktree list | grep -c '/gate-integrity\.' | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== a deleted test file =="
# ---------------------------------------------------------------------------
dispatch GI-DELETED deleted ""
check "deleted: the file that went missing is named" \
  "$(flagged deleted_test)" "tests/doomed.test.js"
has "$(prompt)" "tests/doomed.test.js" "deleted: and the reviewer is told which"
check "deleted: nothing else was invented around it" "$(kinds)" "deleted_test"
check "deleted: the run still ships" "$(result .status)" "ready"

# A rename out of the suite is deletion by another spelling: the old path no
# longer participates in discovery and must be surfaced the same way.
dispatch GI-RENAMED renamed ""
check "renamed: moving a test out of the suite is flagged as deletion" \
  "$(flagged deleted_test)" "tests/doomed.test.js"
check "renamed: the run still ships" "$(result .status)" "ready"

dispatch GI-CAMELTEST cameltest ""
check "path heuristic: a conventional CamelCase test file is replayed" \
  "$(integrity '.replay.files.non_discriminating | join(",")')" \
  "src/WidgetTest.tsx"
check "path heuristic: the run still ships" "$(result .status)" "ready"

# ---------------------------------------------------------------------------
echo "== a skip/only marker that was not there before =="
# ---------------------------------------------------------------------------
dispatch GI-ONLY only ""
check "only: the file that gained the marker is named" \
  "$(flagged skip_marker)" "tests/old.test.js"
has "$(prompt)" "it.only" "only: with the line itself, so the reviewer can find it"
check "only: the run still ships" "$(result .status)" "ready"

# ---------------------------------------------------------------------------
echo "== the rest of the structural signatures, in one diff =="
# ---------------------------------------------------------------------------
# A test that asserts less than it did, the workflow that decides what CI runs,
# and an expected value copied out of the source it is supposed to be checking.
dispatch GI-GAMING gaming ""
check "structural: all three signatures come back, and nothing else" \
  "$(kinds)" "assertions_removed,assertions_removed,ci_config_edit,literal_echoed"
check "structural: the test that lost assertions is named" \
  "$(flagged assertions_removed)" "tests/old.test.js,tests/packed.test.js"
has "$(jq -r '.flags[] | select(.kind == "assertions_removed") | .detail' \
        "$RUN/gate-integrity.json")" "2 assertion(s) removed, 1 added" \
  "structural: with the delta that makes it a finding"
has "$(jq -r '.flags[] | select(.kind == "assertions_removed" and .file == "tests/packed.test.js") | .detail' \
        "$RUN/gate-integrity.json")" "3 assertion(s) removed, 1 added" \
  "structural: assertions are counted even when several shared one line"
check "structural: the CI config edited on the side is named" \
  "$(flagged ci_config_edit)" ".github/workflows/ci.yml"
has "$(jq -r '.flags[] | select(.kind == "literal_echoed") | .detail' \
        "$RUN/gate-integrity.json")" "supersecret42" \
  "structural: and the literal the test copied out of the source"
check "structural: the run still ships" "$(result .status)" "ready"

# A brief that asked for the config change is not a finding: the check exists to
# catch the edit nobody asked for.
BRIEF_EXTRA="Also add a nightly schedule to .github/workflows/ci.yml."
dispatch GI-ASKED gaming ""
BRIEF_EXTRA=""
check "asked: the config edit the brief asked for is not flagged" \
  "$(kinds)" "assertions_removed,assertions_removed,literal_echoed"

# ---------------------------------------------------------------------------
echo "== a replay that could not run says so, and costs the run nothing =="
# ---------------------------------------------------------------------------
printf 'broken\n' > "$NPM_MODE"
dispatch GI-INFRA replay ""
printf 'ok\n' > "$NPM_MODE"
check "infra: the replay reports itself as not run" \
  "$(integrity .replay.status)" "not_run"
check "infra: with every test file in the not-run list" \
  "$(integrity '.replay.files.not_run | length')" "2"
check "infra: judging none of them either way" \
  "$(integrity '"\(.replay.discriminating)/\(.replay.non_discriminating)"')" "0/0"
has "$(integrity .replay.reason)" "could not be executed" \
  "infra: and saying why in words"
check "infra: no test is called non-discriminating on no evidence" \
  "$(flagged non_discriminating_test)" ""
has "$(prompt)" "Replay against the base tree: not run" \
  "infra: the reviewer is told the replay is missing rather than clean"
check "infra: the run finishes exactly as it would have" "$(result .status)" "ready"
check "infra: through the gate rounds it always had" "$(rounds)" "1pass,2skipped"

printf 'notests\n' > "$NPM_MODE"
dispatch GI-NO-TESTS replay ""
printf 'ok\n' > "$NPM_MODE"
check "infra verdict: a runner that executed no test is not called discriminating" \
  "$(integrity .replay.status)" "not_run"
has "$(integrity .replay.reason)" "without executing a test" \
  "infra verdict: the no-tests outcome is explained"
check "infra verdict: no false discriminating count is recorded" \
  "$(integrity .replay.discriminating)" "0"

# The whole-stage cap must shorten an otherwise longer per-file cap. Without
# that, one test can overrun the advertised budget by almost two minutes.
printf 'slow\n' > "$NPM_MODE"
dispatch GI-TIMEOUT replay \
  "HARNESS_GATE_INTEGRITY_TIMEOUT=1 HARNESS_GATE_INTEGRITY_FILE_TIMEOUT=10"
printf 'ok\n' > "$NPM_MODE"
check "timeout: an in-flight test obeys the whole replay budget" \
  "$(integrity .replay.status)" "not_run"
has "$(integrity .replay.reason)" "outlived its 1s cap" \
  "timeout: the shortened cap is explained"
check "timeout: the run still ships" "$(result .status)" "ready"

# ---------------------------------------------------------------------------
echo "== a diff that touches no test at all =="
# ---------------------------------------------------------------------------
dispatch GI-CLEAN clean ""
check "clean: no flags at all" "$(integrity .flag_count)" "0"
check "clean: an empty list, not a missing one" \
  "$(integrity '.flags | length')" "0"
check "clean: result.json carries the same empty list" \
  "$(result '.gate_integrity.flags | length')" "0"
has "$(prompt)" "No flags" "clean: and the reviewer is told so explicitly"
has "$(prompt)" "Checklist item 1 still applies in full" \
  "clean: without being told the gate is therefore honest"
check "clean: the replay had nothing to replay and says that" \
  "$(integrity .replay.reason)" "no new or changed test files on this branch"
check "clean: the run ships" "$(result .status)" "ready"

# ---------------------------------------------------------------------------
echo "== the off switch puts the prompt back =="
# ---------------------------------------------------------------------------
dispatch GI-OFF replay "HARNESS_GATE_INTEGRITY=0"
has_not "$(prompt)" "## Gate integrity flags" \
  "off: the review prompt carries no section"
if [ -e "$RUN/gate-integrity.json" ]; then
  bad "off: and no integrity file is written"
else
  ok "off: and no integrity file is written"
fi
check "off: result.json has no gate_integrity field for anyone to read" \
  "$(jq -r 'has("gate_integrity")' "$RUN/result.json" 2>/dev/null)" "false"
check "off: older consumers see the run they always saw" "$(result .status)" "ready"

# Switch the fixture's base project from npm to Yarn. Detection follows the
# base lockfile and the same per-file replay remains scoped.
git -C "$REPO" rm -q package-lock.json
: > "$REPO/yarn.lock"
git -C "$REPO" add yarn.lock
git -C "$REPO" commit -q -m "test: use yarn fixture"
git -C "$REPO" push -q origin main
dispatch GI-YARN replay ""
check "yarn: a Yarn project uses its own runner" "$(integrity .replay.runner)" "yarn"
check "yarn: the passing-on-base file is still found" \
  "$(integrity '.replay.files.non_discriminating | join(",")')" \
  "tests/passes-anywhere.test.js"
check "yarn: the run still ships" "$(result .status)" "ready"

# Runner detection belongs to the base tree. If the patch adds the test script
# itself, the replay has no evidence either way and must not label npm's
# "missing script" exit as a discriminating test failure.
printf '{"name":"greenapp"}\n' > "$REPO/package.json"
git -C "$REPO" rm -q yarn.lock
git -C "$REPO" add package.json
git -C "$REPO" commit -q -m "test: remove runner from fixture base"
git -C "$REPO" push -q origin main
dispatch GI-NEW-RUNNER newrunner ""
check "base runner: a test script added by the patch is not used on base" \
  "$(integrity .replay.status)" "not_run"
check "base runner: the file is explicitly unjudged" \
  "$(integrity '.replay.files.not_run | join(",")')" \
  "tests/passes-anywhere.test.js"
has "$(integrity .replay.reason)" "no scoped test runner" \
  "base runner: the missing base infrastructure is explained"
check "base runner: no false discriminating verdict is recorded" \
  "$(integrity .replay.discriminating)" "0"
check "base runner: the run still ships" "$(result .status)" "ready"

echo
printf 'gate integrity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
