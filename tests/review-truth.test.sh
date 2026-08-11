#!/usr/bin/env bash
# Telling the truth about the review stage, in two parts:
#
#   1. The post-review gate earns its run. Round 2 on a tree byte-identical to
#      the one round 1 just judged is recorded as skipped instead of re-run —
#      and the verdict that stands is still round 1's, so a gate that was
#      already failing still reaches the fix round. The comparison is against
#      the tree the review STAGE was handed, so a commit from any tier (Codex,
#      its retry, or the Claude reviewer) counts the same.
#   2. The reviewer may measure instead of argue — on loopback and nothing
#      else, out of a harness-owned CODEX_HOME that inherits none of the
#      operator's rules, plugins or MCP servers. HARNESS_REVIEW_NETWORK=0
#      restores the old command line AND environment byte-for-byte, in
#      run-task.sh and its sync-pr.sh mirror.
#
# Nothing real is contacted. `claude` (implementer), `codex` (reviewer), `gh`
# (the PR) and `curl` (ntfy) are fake binaries on PATH driven by mode files, and
# every run is a real run-task.sh invocation against a fabricated repo with a
# local bare remote — the technique tests/pipeline-telemetry.test.sh uses.
#
# Usage: bash tests/review-truth.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-truth-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
# A claim this machine genuinely cannot test. Counted apart from ok/FAIL and
# printed, so a gap in the evidence reads as a gap rather than as a pass.
skipped=0
skip() { skipped=$((skipped+1)); printf '  skip %s\n' "$1"; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
CODEX_ARGV="$ROOT/codex-argv.log"
CODEX_ARGS="$ROOT/codex-args.nul"
CODEX_HOMES="$ROOT/codex-homes.log"
CODEX_MODE="$ROOT/codex-mode"
CLAUDE_MODE="$ROOT/claude-mode"
# The operator's own Codex home, exactly as a developer machine has it: an
# auth token, a rules file recording every command they ever approved (`git
# push` and `gh` among them), an MCP server and a plugin. None of it is the
# harness's to hand an unattended reviewer.
OPHOME="$FHOME/.codex"      # what CODEX_HOME defaults to
FBHOME="$ROOT/codex-fallback"
FAKE_TOKEN='fake-oauth-token-do-not-log'
OPERATOR_RULES='prefix_rule(pattern = ["git", "push"], decision = "allow")
prefix_rule(pattern = ["gh"], decision = "allow")'

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" \
  "$OPHOME/rules" "$OPHOME/plugins" "$FBHOME"
: > "$CODEX_ARGV"; : > "$CODEX_ARGS"; : > "$CODEX_HOMES"
printf 'notes\n' > "$CODEX_MODE"
printf 'notes\n' > "$CLAUDE_MODE"
printf '%s\n' "$FAKE_TOKEN" > "$OPHOME/auth.json"
printf '%s\n' "$OPERATOR_RULES" > "$OPHOME/rules/default.rules"
printf 'enabled = true\n' > "$OPHOME/plugins/some-plugin.toml"
printf '[mcp_servers.prod-db]\ncommand = "prod-db-mcp"\n' > "$OPHOME/config.toml"
printf '%s\n' "$FAKE_TOKEN-fallback" > "$FBHOME/auth.json"
printf '%s\n' "$OPERATOR_RULES" > "$FBHOME/default.rules"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
cp "$SRC/sync-pr.sh"  "$SRCDIR/sync-pr.sh"
chmod +x "$SRCDIR/run-task.sh" "$SRCDIR/sync-pr.sh"
cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"

# One knob so a dispatch can pick a green gate or a failing one.
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*)
      INSTALL_CMD=''
      GATE_CMD="${TEST_GATE_CMD:-true}"
      ;;
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
# writes a diff big enough that the review floor applies to it, and the Claude
# review tier — the last one, reached when both Codex accounts came up empty —
# either leaves notes or leaves a commit, which is exactly the distinction the
# gate-#2 skip has to make for a non-Codex reviewer.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
prompt=""; prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && prompt="\$a"; prev="\$a"; done
case "\$prompt" in
  *"reviewer stage"*)
    mkdir -p .harness
    echo "claude tier: sound" > .harness/review-notes.md
    if [ "\$(cat "$CLAUDE_MODE")" = commits ]; then
      printf 'claude reviewer touched this\n' >> impl.txt
      git add -A && git commit -q -m "refactor: claude reviewer change"
    fi
    ;;
  *)
    seq 1 30 >> impl.txt
    git add -A
    git commit -q -m "feat: fixture change"
    ;;
esac
EOF

# Reviewer stand-in. Every invocation records its whole argv, because the
# sandbox flags are as much a contract as anything the reviewer writes.
# `instant` is the confirmed failure — it returns at once having touched
# nothing at all.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then wt="\$a"; break; fi
  prev="\$a"
done
printf '%s\n' "\$*" >> "$CODEX_ARGV"
printf '%s\0' "\$@" >> "$CODEX_ARGS"
printf '%s\n' "\${CODEX_HOME-<unset>}" >> "$CODEX_HOMES"
case "\$(cat "$CODEX_MODE")" in
  instant) echo "codex: done" ;;
  credits) case "\${CODEX_HOME-}" in "$FBHOME/harness-review"/*)
             printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md"
           ;; *) printf 'stream error: Your workspace is out of\nCredits.\n' ;; esac ;;
  resolve) ( cd "\$wt" && printf 'both sides\n' > f.txt && git add -A \
             && git commit -q --no-verify -m "Merge latest main" ) ;;
  notes)   printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md" ;;
  refresh) rm -f "\$CODEX_HOME/auth.json"
           printf 'refreshed-token\n' > "\$CODEX_HOME/auth.json"
           printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md" ;;
  commits) ( cd "\$wt" && printf 'reviewer touched this\n' >> impl.txt \
             && git add -A && git commit -q -m "refactor: reviewer change" ) ;;
  fix)     ( cd "\$wt" && printf 'ok\n' > fixed.txt && git add -A \
             && git commit -q -m "fix: make the gate pass" ) ;;
esac
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

# A gate that fails until the reviewer's fix round creates fixed.txt.
cat > "$FAKES/gate-needs-fix" <<'EOF'
#!/usr/bin/env bash
[ -f fixed.txt ] || { echo "tests: 1 failing"; exit 1; }
echo "tests: green"
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh" "$FAKES/gate-needs-fix"

# --- the harness under test ---------------------------------------------------
RUN=""
TEST_GATE_CMD=true
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$CODEX_ARGV"; : > "$CODEX_ARGS"; : > "$CODEX_HOMES"
  # The fallback account is scrubbed for the same reason CODEX_HOME is: it is a
  # documented operator knob, so a machine that has one configured failed the
  # arms below that are about having nowhere else to go. The overrides can still
  # set it — env applies -u before its own assignments.
  # shellcheck disable=SC2086
  env -u CODEX_HOME -u HARNESS_CODEX_HOME_FALLBACK \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      TEST_GATE_CMD="$TEST_GATE_CMD" \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=review-truth-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  return 0
}
result()  { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
rounds()  { awk '{ print $1 $2 }' "$RUN/gate-rounds.log" | paste -sd, - | tr -d ' '; }
argv_arg() {  # $1 = one-based position in the most recent codex invocation
  local want="$1" i=0 a
  while IFS= read -r -d '' a; do
    i=$((i + 1))
    if [ "$i" -eq "$want" ]; then printf '%s' "$a"; return; fi
  done < "$CODEX_ARGS"
}
argv_count() {
  local i=0 a
  while IFS= read -r -d '' a; do i=$((i + 1)); done < "$CODEX_ARGS"
  printf '%s' "$i"
}
review_home_for() {  # $1 = account home, $2 = ticket
  printf '%s/harness-review/%s' "$1" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
}

# ---------------------------------------------------------------------------
echo "== gate #2 earns its run =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
dispatch GATE-NOCOMMITS ""
check "no commits: round 2 is recorded as skipped, not run" \
  "$(rounds)" "1pass,2skipped"
file_has "$RUN/timeline" "test gate #2 skipped — review committed nothing" \
  "no commits: the stage line says exactly why"
check "no commits: the round is in result.json like any other" \
  "$(result '.metrics.gate_rounds[1].result')" "skipped"
check "no commits: costing nothing" "$(result '.metrics.gate_rounds[1].seconds')" "0"
check "no commits: and naming no failing step" \
  "$(result '.metrics.gate_rounds[1].failed_step')" ""
check "no commits: the verdict that stands is round 1's" "$(result .gate)" "pass"
check "no commits: so the run finishes exactly as it did before" \
  "$(result .status)" "ready"
check "no commits: reviewer commits are still counted at zero" \
  "$(result .metrics.codex_commits)" "0"
if [ -e "$RUN/gate-2.log" ]; then
  bad "no commits: a skipped round runs no gate"
else
  ok "no commits: a skipped round runs no gate"
fi

printf 'commits\n' > "$CODEX_MODE"
dispatch GATE-COMMITS ""
check "commits: a reviewer that committed gets its round, exactly as today" \
  "$(rounds)" "1pass,2pass"
if [ -e "$RUN/gate-2.log" ]; then
  ok "commits: which really ran — it left its log"
else
  bad "commits: which really ran — it left its log"
fi
check "commits: and result.json carries a verdict, not a skip" \
  "$(result '.metrics.gate_rounds[1].result')" "pass"
check "commits: the run is unchanged" "$(result .status)" "ready"
check "commits: and the commit is attributed" "$(result .metrics.codex_commits)" "1"

# Skipping the round must not skip its consequence: round 1's verdict stands,
# and a failing one still buys the fix round it always did.
TEST_GATE_CMD=gate-needs-fix
printf 'fix\n' > "$CODEX_MODE"
dispatch GATE-FIXROUND ""
check "failing gate: the reviewer's own commit means round 2 runs" \
  "$(rounds)" "1fail,2pass"
check "failing gate: and the run recovers" "$(result .status)" "ready"

printf 'notes\n' > "$CODEX_MODE"
dispatch GATE-FAIL-NOCOMMITS ""
check "failing gate, no commits: round 2 is skipped but the fix round still fires" \
  "$(rounds)" "1fail,2skipped,3fail"
file_has "$RUN/timeline" "fix round 2 — Codex (ChatGPT sub)" \
  "failing gate, no commits: the fix round is reached"
check "failing gate, no commits: the run parks at gate_failed as before" \
  "$(result .status)" "gate_failed"
TEST_GATE_CMD=true

# The reviewer is not always Codex. When both Codex accounts come up empty the
# Claude tier takes the review, and its commits are commits: the comparison is
# against the tree the review STAGE was handed, so which backend moved HEAD
# never enters into it.
printf 'instant\n' > "$CODEX_MODE"   # nothing from Codex on either attempt
printf 'notes\n'   > "$CLAUDE_MODE"
dispatch GATE-CLAUDE-NOCOMMITS ""
check "claude tier: it really was the Claude reviewer that reviewed" \
  "$(result .review)" "reviewed_claude"
check "claude tier: leaving notes and no commits, round 2 is skipped" \
  "$(rounds)" "1pass,2skipped"
check "claude tier: and the run ships as it would have" "$(result .status)" "ready"

printf 'commits\n' > "$CLAUDE_MODE"
dispatch GATE-CLAUDE-COMMITS ""
check "claude tier: the same tier committing earns the round" \
  "$(rounds)" "1pass,2pass"
check "claude tier: which is attributed to the reviewer like any other" \
  "$(result .metrics.codex_commits)" "1"
printf 'notes\n' > "$CLAUDE_MODE"

# ---------------------------------------------------------------------------
echo "== the reviewer measures on loopback and reaches nothing else =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
dispatch NET-ON ""
RHOME="$(review_home_for "$OPHOME" NET-ON)"
check "network: the attempt runs in a harness-owned CODEX_HOME" \
  "$(cat "$CODEX_HOMES")" "$RHOME"
check "network: built inside the account's own tree, not somewhere else" \
  "$(dirname "$(dirname "$RHOME")")" "$OPHOME"
CFG="$RHOME/config.toml"

echo "-- the policy it is handed --"
file_has "$CFG" "features.network_proxy.enabled = true" \
  "policy: sandboxed networking is the mechanism"
file_has "$CFG" 'default_permissions = "harness-review"' \
  "policy: pointed at the harness's own profile"
file_has "$CFG" 'mode = "limited"' \
  "policy: the restricted mode is named, never left to a default"
file_has "$CFG" '"localhost" = "allow"'  "policy: localhost is reachable"
file_has "$CFG" '"127.0.0.1" = "allow"' "policy: and the v4 loopback literal"
file_has "$CFG" '"::1" = "allow"'       "policy: and the v6 one"
file_has "$CFG" "allow_local_binding = true" \
  "policy: loopback can be BOUND, which is what flutter test needs"
has_not "$(cat "$CFG")" '"*" = "allow"' \
  "policy: no wildcard allow — what is not named is denied"
has_not "$(cat "$CFG")" "danger" \
  "policy: no escape hatch anywhere in it"
# The whole point of the redesign: the blunt flag must appear nowhere at all.
has_not "$(cat "$CFG")" "network_access" \
  "policy: unrestricted sandbox networking is never asked for in the config"
has_not "$(cat "$CODEX_ARGV")" "network_access" \
  "policy: nor on the command line"
# The profile only becomes active when no legacy -s override is present. This
# is production argv behavior, not something the separate sandbox probe proves:
# codex 0.145 gives an explicit -s precedence over default_permissions.
has_not "$(cat "$CODEX_ARGV")" "-s workspace-write" \
  "policy: enabled exec does not override the named permission profile"
has_not "$(cat "$CODEX_ARGV")" "sandbox_workspace_write.writable_roots" \
  "policy: nor smuggle the legacy sandbox back through its root override"
GIT_ROOT="$(git -C "$ROOT/greenapp-net-on" rev-parse --path-format=absolute --git-common-dir)"
check "policy: the fixture really has a separate git common dir" \
  "$(printf '%s' "$GIT_ROOT" | grep -c '\.git$' | tr -d ' ')" "1"
file_has "$CFG" "\"$GIT_ROOT\" = \"write\"" \
  "policy: the active profile keeps the git common dir writable"

echo "-- what it does NOT inherit --"
# The operator's own home is full of things an unattended reviewer must not
# get: a rules file that allows `git push` and `gh`, an MCP server, a plugin.
if [ -e "$RHOME/rules" ] || [ -e "$RHOME/plugins" ]; then
  bad "isolation: the operator's rules and plugins are not on the review path"
else
  ok "isolation: the operator's rules and plugins are not on the review path"
fi
# Signatures of the operator's own config, not the words for them — the review
# config talks *about* rules and plugins in its header comment.
INHERITED="$(grep -rlF -e 'prefix_rule' -e 'mcp_servers' -e 'prod-db-mcp' \
  "$RHOME" 2>/dev/null | paste -sd, -)"
check "isolation: no inherited rule, plugin or MCP server is on that path" \
  "$INHERITED" ""
check "isolation: the operator's own home is untouched — still theirs" \
  "$(cat "$OPHOME/rules/default.rules")" "$OPERATOR_RULES"

echo "-- auth: inherited, never copied, never logged --"
if [ -L "$RHOME/auth.json" ]; then
  ok "auth: reached through a link, not a copy"
else
  bad "auth: reached through a link, not a copy"
fi
check "auth: the link stays inside the account's own tree" \
  "$(readlink "$RHOME/auth.json")" "../../auth.json"
check "auth: the account's own auth.json is where it always was" \
  "$(cat "$OPHOME/auth.json")" "$FAKE_TOKEN"
LEAK="$(grep -rlF "$FAKE_TOKEN" "$RUNS" 2>/dev/null | paste -sd, -)"
check "auth: no token anywhere in any run dir" "$LEAK" ""

echo "-- a token the attempt refreshed goes back to the account --"
# codex may replace auth.json rather than write through the link. Reconciliation
# after that same attempt must put it back. The fake performs
# the replacement while it is running, exactly where the real CLI would.
printf 'refresh\n' > "$CODEX_MODE"
dispatch NET-REFRESH ""
REFRESH_HOME="$(review_home_for "$OPHOME" NET-REFRESH)"
check "auth: the refreshed token landed back in the account's own file" \
  "$(cat "$OPHOME/auth.json")" "refreshed-token"
if [ -L "$REFRESH_HOME/auth.json" ]; then
  ok "auth: and the link was restored over it"
else
  bad "auth: and the link was restored over it"
fi
check "isolation: different runs have different config homes" \
  "$REFRESH_HOME" "$OPHOME/harness-review/net-refresh"
file_has "$RHOME/config.toml" "$GIT_ROOT" \
  "isolation: a later run leaves the first run's root policy intact"
printf 'notes\n' > "$CODEX_MODE"
printf '%s\n' "$FAKE_TOKEN" > "$OPHOME/auth.json"

echo "-- the knob puts everything back --"
OFF_HOME="$(review_home_for "$OPHOME" NET-OFF)"
command rm -rf "$OFF_HOME"
dispatch NET-OFF "HARNESS_REVIEW_NETWORK=0"
check "off: no CODEX_HOME is imposed on the primary account, as before" \
  "$(cat "$CODEX_HOMES")" "<unset>"
if [ -e "$OFF_HOME" ]; then
  bad "off: and no review home is built at all"
else
  ok "off: and no review home is built at all"
fi
# Pin the complete pre-feature argv prefix by element, including its count.
# The final element is the unchanged review prompt; everything before it is the
# old invocation contract and no new option may leak into this arm.
check "off: the legacy invocation still has exactly twelve arguments" \
  "$(argv_count)" "12"
check "off: argv 1 is exec" "$(argv_arg 1)" "exec"
check "off: argv 2 selects the worktree" "$(argv_arg 2)" "-C"
check "off: argv 3 is the worktree" "$(argv_arg 3)" "$ROOT/greenapp-net-off"
check "off: argv 4 selects the legacy sandbox" "$(argv_arg 4)" "-s"
check "off: argv 5 is workspace-write" "$(argv_arg 5)" "workspace-write"
check "off: argv 6 introduces the root override" "$(argv_arg 6)" "-c"
has "$(argv_arg 7)" "sandbox_workspace_write.writable_roots=[\"" \
  "off: argv 7 is the legacy writable-roots override"
check "off: argv 8 introduces the model" "$(argv_arg 8)" "-c"
check "off: argv 9 keeps the pinned model" "$(argv_arg 9)" 'model="gpt-5.6-sol"'
check "off: argv 10 introduces effort" "$(argv_arg 10)" "-c"
check "off: argv 11 keeps the pinned effort" \
  "$(argv_arg 11)" 'model_reasoning_effort="high"'
has "$(argv_arg 12)" "You are the reviewer stage" \
  "off: argv 12 remains the review prompt"

echo "-- it composes with the fallback account --"
printf 'credits\n' > "$CODEX_MODE"
dispatch NET-FALLBACK "HARNESS_CODEX_HOME_FALLBACK=$FBHOME"
check "fallback: each account's attempt runs in that account's own review home" \
  "$(cat "$CODEX_HOMES")" "$OPHOME/harness-review/net-fallback
$FBHOME/harness-review/net-fallback"
file_has "$FBHOME/harness-review/net-fallback/config.toml" '"localhost" = "allow"' \
  "fallback: with the same policy"
check "fallback: and the fallback account's own auth, not the primary's" \
  "$(readlink "$FBHOME/harness-review/net-fallback/auth.json")" "../../auth.json"
printf 'notes\n' > "$CODEX_MODE"

echo "-- isolation setup failure never falls back to the operator config --"
BROKEN_HOME="$ROOT/codex-home-is-a-file"
printf 'not a directory\n' > "$BROKEN_HOME"
dispatch NET-SETUP-FAIL \
  "CODEX_HOME=$BROKEN_HOME HARNESS_CODEX_HOME_FALLBACK=$FBHOME"
check "fail closed: the primary Codex process is never started on ambient config" \
  "$(cat "$CODEX_HOMES")" "$FBHOME/harness-review/net-setup-fail"
file_has "$RUN/codex-1.log" \
  "reviewer isolation setup failed — codex attempt not started" \
  "fail closed: the skipped primary attempt records why it did not start"
check "fail closed: the isolated fallback still completes the review" \
  "$(result .review)" "reviewed"
check "fail closed: result.json attributes that review to the fallback" \
  "$(result .review_account)" "fallback"
dispatch NET-SETUP-CLAUDE "CODEX_HOME=$BROKEN_HOME"
check "fail closed: without another account, no Codex process starts" \
  "$(cat "$CODEX_HOMES")" ""
check "fail closed: the existing Claude tier takes the review instead" \
  "$(result .review)" "reviewed_claude"

# ---------------------------------------------------------------------------
echo "== does the policy actually hold? (real codex sandbox, when available) =="
# ---------------------------------------------------------------------------
# The assertions above pin the policy the harness HANDS to codex. Whether codex
# enforces it is codex's contract, and proving that needs the real CLI — which
# the gate cannot assume, so this probe reports honestly instead of pretending.
#
# Ordered so it can only ever produce evidence, never a green by accident:
#
#   - the loopback bind under our profile has to succeed first, which is what
#     proves the wrapper ran at all. Only then is a failure to reach a public
#     host read as a refusal rather than as a broken invocation;
#   - and a CONTROL runs the same bind under a bare CODEX_HOME. If loopback
#     already worked there, the profile is not what changed anything and the
#     probe says so instead of taking credit.
with_timeout() {  # $1 = seconds, rest = command
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}
BIND_PROBE='import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
socket.create_connection(("127.0.0.1", s.getsockname()[1]), 2)
print("LOOPBACK-OK")'
PROBE_ARGV=""   # the codex sandbox invocation that this build accepted
sandbox_probe() {  # $1 = CODEX_HOME, $2 = shell command -> output, or 1 if unrunnable
  local plat out rc a
  case "$(uname -s)" in Darwin) plat=macos ;; Linux) plat=linux ;; *) return 1 ;; esac
  for a in "${PROBE_ARGV:-sandbox $plat}" "sandbox"; do
    # shellcheck disable=SC2086
    out=$(CODEX_HOME="$1" with_timeout 60 codex $a -- /bin/sh -c "$2" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q 'LOOPBACK-OK'; then
      PROBE_ARGV="$a"; printf '%s' "$out"; return 0
    fi
  done
  return 1
}
bare_home="$ROOT/codex-bare"; mkdir -p "$bare_home"

dispatch NET-PROBE ""   # rebuild the review home the probe runs under
RHOME="$(review_home_for "$OPHOME" NET-PROBE)"
if ! command -v codex >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  skip "probe: no real codex/python3 here — policy enforcement unverified on this machine"
elif ! OURS=$(sandbox_probe "$RHOME" "python3 -c '$BIND_PROBE'") \
     || ! printf '%s' "$OURS" | grep -q 'LOOPBACK-OK'; then
  skip "probe: this codex build would not run a sandbox probe — enforcement unverified here"
else
  ok "probe: a loopback socket binds and connects inside the sandbox (codex $PROBE_ARGV)"
  if sandbox_probe "$RHOME" 'curl -sS -m 5 -o /dev/null https://example.com' >/dev/null 2>&1; then
    bad "probe: a public host was reachable — the domain map is not holding"
  else
    ok "probe: and a public host is refused"
  fi
  # The control. Without it, a build that allowed loopback all along would read
  # as this feature working.
  if CTRL=$(sandbox_probe "$bare_home" "python3 -c '$BIND_PROBE'") \
     && printf '%s' "$CTRL" | grep -q 'LOOPBACK-OK'; then
    skip "probe: this build binds loopback without the profile too — the bind above proves nothing about it"
  else
    ok "probe: and the same bind is refused without the profile — the profile is what allows it"
  fi
fi

# ---------------------------------------------------------------------------
echo "== sync-pr.sh's resolver is the same invocation, deliberately =="
# ---------------------------------------------------------------------------
# The two codex command lines are mirrors. A network posture that lands on one
# and not the other means a conflict resolver that cannot run the tests it is
# told to re-run — and one that still inherits the operator's `git push` rule.
# A sync consumes its own conflict, so each case gets a branch of its own.
mk_sync_case() {  # $1 = ticket -> a pushed branch that conflicts with main
  local t="$1" lc
  lc=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  git -C "$REPO" checkout -q -b "fix/$t" main
  printf 'branch side %s\n' "$t" > "$REPO/f.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: branch side"
  git -C "$REPO" push -q -u origin "fix/$t"
  git -C "$REPO" checkout -q main
  printf 'base side %s\n' "$t" > "$REPO/f.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: base side"
  git -C "$REPO" push -q origin main
  git -C "$REPO" branch -q -D "fix/$t"
  mkdir -p "$RUNS/$t"
  printf '# fixture task\n' > "$RUNS/$t/brief.md"
  jq -n --arg wt "$ROOT/greenapp-$lc" --arg b "fix/$t" --arg t "$t" \
    '{ticket:$t,status:"ready",worktree:$wt,branch:$b,base:"main"}' > "$RUNS/$t/result.json"
}
sync_pr() {  # $1 = ticket, $2 = space-separated VAR=VAL overrides (may be empty)
  : > "$CODEX_ARGV"; : > "$CODEX_ARGS"; : > "$CODEX_HOMES"
  # shellcheck disable=SC2086
  env -u CODEX_HOME HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CODEX_BIN="$FAKES/codex" HARNESS_NOTIFY=0 $2 \
      bash "$SRCDIR/sync-pr.sh" "$1" > "$ROOT/sync-$1.log" 2>&1
}
printf 'resolve\n' > "$CODEX_MODE"
mk_sync_case SYNC-ON
RHOME="$(review_home_for "$OPHOME" SYNC-ON)"
command rm -rf "$RHOME"
sync_pr SYNC-ON ""
check "sync-pr: its resolver runs in the same harness-owned home" \
  "$(cat "$CODEX_HOMES")" "$RHOME"
file_has "$RHOME/config.toml" "features.network_proxy.enabled = true" \
  "sync-pr: with sandboxed networking, not the blunt flag"
file_has "$RHOME/config.toml" '"127.0.0.1" = "allow"' \
  "sync-pr: and the same loopback-only domain map"
has_not "$(cat "$RHOME/config.toml")" "network_access" \
  "sync-pr: unrestricted networking is never asked for here either"
SYNC_ON_ARGV="$(cat "$CODEX_ARGV")"
check "sync-pr: the resolver really ran" \
  "$(printf '%s' "$SYNC_ON_ARGV" | grep -c 'exec -C' | tr -d ' ')" "1"
has_not "$SYNC_ON_ARGV" "-s workspace-write" \
  "sync-pr: enabled exec leaves its permission profile authoritative"

mk_sync_case SYNC-SETUP-FAIL
sync_pr SYNC-SETUP-FAIL \
  "CODEX_HOME=$BROKEN_HOME HARNESS_CODEX_HOME_FALLBACK=$FBHOME"
check "sync-pr: a broken primary home starts only the isolated fallback" \
  "$(cat "$CODEX_HOMES")" "$FBHOME/harness-review/sync-setup-fail"
file_has "$RUNS/SYNC-SETUP-FAIL/codex-post-sync.log" \
  "resolver isolation setup failed — codex attempt not started" \
  "sync-pr: the primary resolver records the fail-closed decision"

mk_sync_case SYNC-OFF
OFF_HOME="$(review_home_for "$OPHOME" SYNC-OFF)"
command rm -rf "$OFF_HOME"
sync_pr SYNC-OFF "HARNESS_REVIEW_NETWORK=0"
check "sync-pr: the knob puts its environment back too" \
  "$(cat "$CODEX_HOMES")" "<unset>"
if [ -e "$OFF_HOME" ]; then
  bad "sync-pr: and builds no review home"
else
  ok "sync-pr: and builds no review home"
fi
check "sync-pr: its legacy invocation still has exactly ten arguments" \
  "$(argv_count)" "10"
check "sync-pr: off argv 1 is exec" "$(argv_arg 1)" "exec"
check "sync-pr: off argv 2 selects the worktree" "$(argv_arg 2)" "-C"
check "sync-pr: off argv 3 is the worktree" \
  "$(argv_arg 3)" "$ROOT/greenapp-sync-off"
check "sync-pr: off argv 4 selects the legacy sandbox" "$(argv_arg 4)" "-s"
check "sync-pr: off argv 5 is workspace-write" "$(argv_arg 5)" "workspace-write"
check "sync-pr: off argv 6 introduces the root override" "$(argv_arg 6)" "-c"
has "$(argv_arg 7)" "sandbox_workspace_write.writable_roots=[\"" \
  "sync-pr: off argv 7 is the legacy writable-roots override"
check "sync-pr: off argv 8 introduces effort" "$(argv_arg 8)" "-c"
check "sync-pr: off argv 9 keeps the pinned effort" \
  "$(argv_arg 9)" 'model_reasoning_effort="high"'
has "$(argv_arg 10)" "A merge of origin/main" \
  "sync-pr: off argv 10 remains the conflict-resolution prompt"

echo
printf 'review truth: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
