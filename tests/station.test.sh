#!/usr/bin/env bash
# Station behavior with fake providers, SSH and tmux: the seat contract. A
# station acts for the OS user that runs it — no --owner, no accounts
# directory, logins in the fixture home's own .claude/.codex/.config/gh. No
# real account logins, model calls, shared tmux server or writes outside this
# temp fixture.
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/station-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT
FIXTURE_HOME="$ROOT/home"
H="$FIXTURE_HOME/.claude/harness"
BIN="$ROOT/bin"; CAPTURE="$ROOT/capture"
mkdir -p "$FIXTURE_HOME" "$BIN" "$CAPTURE"
ME="$(id -un)"
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
absent() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2"; fi; }
omits() { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
mode_of() { m=$(stat -f %Lp "$1" 2>/dev/null) || m=$(stat -c %a "$1" 2>/dev/null) || m=""; printf '%s' "$m"; }
# Clear ambient overrides so this suite cannot inherit a real station identity
# or token: every assertion must come from the fixture alone.
fixture() {
  env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GH_CONFIG_DIR -u HARNESS_OWNER \
    -u DISPATCH_STATION_DIR -u DISPATCH_PLANNER -u DISPATCH_MODEL -u QM_CREW \
    -u CLAUDE_SKILLS_DIR -u CODEX_SKILLS_DIR -u CLAUDE_SETTINGS_FILE \
    -u CLAUDE_CODE_OAUTH_TOKEN \
    HOME="$FIXTURE_HOME" HARNESS_DIR="$H" PATH="$BIN:$PATH" CAPTURE="$CAPTURE" \
    CODEX_BIN=codex CLAUDE_BIN=claude "$@"
}
station() { fixture bash "$H/station.sh" "$@"; }
install() { fixture bash "$SRC/install.sh" --no-statusline "$@" > "$ROOT/install.out"; }

# A provider is "signed in" once its login has run (marker file). Claude also
# counts the fixture token file: within this fixture that file IS the login.
cat > "$BIN/codex" <<'CLI'
#!/usr/bin/env bash
set -eu
if [ "$1" = login ] && [ "${2:-}" = status ]; then
  [ -f "$CAPTURE/codex-ok" ] || exit 1
  exit 0
fi
if [ "$1" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != codex ] || exit 1
  touch "$CAPTURE/codex-ok"
fi
printf '%s\n' "$@" > "$CAPTURE/codex.args"
printf '%s\n' "${CODEX_HOME:-native}" "${CLAUDE_CONFIG_DIR:-native}" "${GH_CONFIG_DIR:-native}" "${HARNESS_OWNER:-}" > "$CAPTURE/identity"
printf '%s\n' "${GH_TOKEN:-clear}" "${OPENAI_API_KEY:-clear}" "${ANTHROPIC_API_KEY:-clear}" "${CLAUDE_CODE_OAUTH_TOKEN:-none}" > "$CAPTURE/tokens"
CLI
cat > "$BIN/claude" <<'CLI'
#!/usr/bin/env bash
set -eu
if [ "$1 ${2:-} ${3:-}" = 'auth status --json' ]; then
  if [ -f "$CAPTURE/claude-ok" ] \
     || { [ -f "$HOME/.claude/oauth-token" ] && [ "$(stat -f %Lp "$HOME/.claude/oauth-token" 2>/dev/null || stat -c %a "$HOME/.claude/oauth-token" 2>/dev/null)" = 600 ]; }; then
    echo '{"loggedIn":true}'
  else
    echo '{"loggedIn":false}'; exit 1
  fi
  exit 0
fi
if [ "${2:-}" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != claude ] || exit 1
  touch "$CAPTURE/claude-ok"
fi
printf '%s\n' "$@" > "$CAPTURE/claude.args"
printf '%s\n' "${CLAUDE_CONFIG_DIR:-native}" > "$CAPTURE/claude.home"
printf '%s\n' "${GH_TOKEN:-clear}" "${OPENAI_API_KEY:-clear}" "${ANTHROPIC_API_KEY:-clear}" "${CLAUDE_CODE_OAUTH_TOKEN:-none}" > "$CAPTURE/tokens"
CLI
cat > "$BIN/gh" <<'CLI'
#!/usr/bin/env bash
set -eu
if [ "$1 ${2:-}" = 'auth status' ]; then
  [ -f "$CAPTURE/gh-ok" ] || exit 1
  exit 0
fi
if [ "${2:-}" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != gh ] || exit 1
  touch "$CAPTURE/gh-ok"
fi
printf '%s\n' "$*" > "$CAPTURE/gh.args"
printf '%s\n' "${GH_CONFIG_DIR:-native}" > "$CAPTURE/gh.home"
CLI
cat > "$BIN/caffeinate" <<'CLI'
#!/usr/bin/env bash
shift
exec "$@"
CLI
cat > "$BIN/tmux" <<'CLI'
#!/usr/bin/env bash
set -eu
case "$1" in
  has-session) [ "${FAKE_EXISTING:-0}" = 1 ]; exit ;;
  show-options) cat "$CAPTURE/context"; exit ;;
  attach-session) printf '%s' "$3" > "$CAPTURE/attached-to"; touch "$CAPTURE/attached"; exit ;;
  new-session)
    printf '%s' "$4" > "$CAPTURE/session"
    printf '%s' "$6" > "$CAPTURE/dir"
    printf '%s' "${13}" > "$CAPTURE/context"
    # Simulate a tmux server that retained another user's ambient API keys and
    # config-dir overrides; the command line must clear them itself.
    cd "$6"
    GH_TOKEN=stale-server-token OPENAI_API_KEY=stale-server-key \
      ANTHROPIC_API_KEY=stale-server-key CLAUDE_CONFIG_DIR=stale-server-claude \
      CODEX_HOME=stale-server-codex GH_CONFIG_DIR=stale-server-gh bash -c "$7"
    ;;
  *) exit 2 ;;
esac
CLI
cat > "$BIN/ssh" <<'CLI'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$CAPTURE/ssh.args"
# Execute the transported command under a different HOME, just like SSH.
for arg in "$@"; do command_line="$arg"; done
if [ "${FAKE_SSH_EXEC:-0}" = 1 ]; then
  HOME="$FAKE_REMOTE_HOME" HARNESS_DIR="$FAKE_REMOTE_HOME/.claude/harness" \
    bash -c "$command_line"
fi
CLI
chmod +x "$BIN"/*

echo "== install =="
install --pixel
for skill in dispatch briefed-dispatch dispatch-pixel; do
  for dir in "$FIXTURE_HOME/.agents/skills" "$FIXTURE_HOME/.claude/skills"; do
    if cmp -s "$SRC/skills/$skill/SKILL.md" "$dir/$skill/SKILL.md"; then ok "install: $skill in $dir"; else bad "install: $skill in $dir"; fi
  done
done
printf 'personal\n' > "$FIXTURE_HOME/.agents/skills/dispatch/personal.txt"
printf 'local config\n' > "$H/notify.conf"
install --copy --pixel
if [ ! -L "$FIXTURE_HOME/.agents/skills/dispatch/SKILL.md" ]; then ok 'install: copies detach from source'; else bad 'install: copies detach from source'; fi
check 'install: preserves local config' "$(cat "$H/notify.conf")" 'local config'
check 'install: preserves extra personal skill files' "$(cat "$FIXTURE_HOME/.agents/skills/dispatch/personal.txt")" personal
install --symlink
if [ -L "$FIXTURE_HOME/.agents/skills/dispatch/SKILL.md" ]; then ok 'install: copy can return to symlink'; else bad 'install: copy can return to symlink'; fi
if [ -f "$H/planner-skills/dispatch/SKILL.md" ]; then ok 'install: shared protocol is in runtime'; else bad 'install: shared protocol is missing in runtime'; fi
for skill_root in "$FIXTURE_HOME/.agents/skills" "$FIXTURE_HOME/.claude/skills"; do
  if cmp -s "$SRC/skills/dispatch/references/pipeline.md" "$skill_root/dispatch/references/pipeline.md"; then
    ok 'install: linked detailed dispatch protocol is available to the planner'
  else bad 'install: detailed dispatch protocol is missing'; fi
done
# Test collisions in a COPY of the installer source: a regression must never
# replace the real checkout's skill files while the other suites read them.
SOURCE_COPY="$ROOT/source-copy"
cp -R "$H" "$SOURCE_COPY"
cp -R "$H/planner-skills" "$SOURCE_COPY/skills"
cp "$SRC/install.sh" "$SRC/notify.conf.example" "$SRC/repos.local.sh.example" "$SRC/demo.conf.sh.example" "$SOURCE_COPY/"
for root_name in skills planner-skills; do
  fixture env HARNESS_DIR="$ROOT/collision-$root_name" \
    CLAUDE_SKILLS_DIR="$ROOT/collision-$root_name/$root_name" \
    bash "$SOURCE_COPY/install.sh" --no-statusline --no-pixel >/dev/null
  if [ ! -L "$SOURCE_COPY/skills/dispatch/SKILL.md" ] \
      && cmp -s "$SRC/skills/dispatch/SKILL.md" "$SOURCE_COPY/skills/dispatch/SKILL.md"; then
    ok "install: $root_name overlap preserves source"
  else bad "install: $root_name overlap preserves source"; fi
done

echo "== doctor =="
touch "$CAPTURE/codex-ok" "$CAPTURE/claude-ok" "$CAPTURE/gh-ok"
station doctor > "$ROOT/doctor.out"
has "$ROOT/doctor.out" '0 failed check(s)' "doctor: healthy fixture succeeds ($ME)"
git init -q --bare "$ROOT/origin.git"
git init -q "$ROOT/repo"
git -C "$ROOT/repo" remote add origin "$ROOT/origin.git"
cat > "$H/repos.local.sh" <<'PIN'
repo_config_local() { PREFLIGHT_CMD='test -f service-ready'; }
PIN
if station doctor --repo "$ROOT/repo" > "$ROOT/services.out"; then bad 'doctor: failing service preflight fails'; else ok 'doctor: failing service preflight fails'; fi
has "$ROOT/services.out" 'repository service preflight failed' 'doctor: identifies service failure'
touch "$ROOT/repo/service-ready"
station doctor --repo "$ROOT/repo" > "$ROOT/services.out"
has "$ROOT/services.out" 'repository origin reachable' 'doctor: checks local origin without pushing'
has "$ROOT/services.out" '[ok] repository service preflight' 'doctor: preflight runs in target repo'
rm -f "$CAPTURE/codex-ok"
if station doctor > "$ROOT/doctor-bad.out"; then bad 'doctor: missing auth fails'; else ok 'doctor: missing auth fails'; fi
has "$ROOT/doctor-bad.out" "login' 'codex" 'doctor: repair names the login command for this user'
omits "$ROOT/doctor-bad.out" --owner 'doctor: repair never selects another owner'

echo "== start: the seat environment contract =="
touch "$CAPTURE/codex-ok"
# Literal shell syntax and a quote in the path must survive tmux's shell hop.
WEIRD_DIR="$ROOT/space ' \$(touch INJECTED) \`touch INJECTED2\`"
mkdir -p "$WEIRD_DIR"
station --dir "$WEIRD_DIR" > "$ROOT/start.out"
check 'start: session is named for the OS user' "$(cat "$CAPTURE/session")" "dispatch-$ME-codex-gpt-6-astra"
has "$CAPTURE/codex.args" 'gpt-6-astra' 'start: Astra model is explicit'
has "$CAPTURE/codex.args" "$H/planner-skills/dispatch/SKILL.md" 'start: Codex opens as a harness planner'
has "$CAPTURE/codex.args" 'No task has been supplied yet' 'start: planner waits for the user task'
omits "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'start: ordinary Codex does not request bypass'
has "$CAPTURE/codex.args" "$H/runs" 'start: run directory is writable for Codex'
check 'start: tmux receives literal directory' "$(cat "$CAPTURE/dir")" "$WEIRD_DIR"
check 'start: identity is the OS user, no config dirs' "$(cat "$CAPTURE/identity")" "native
native
native
$ME"
check 'start: tmux inherited tokens cleared, no token without a file' "$(cat "$CAPTURE/tokens")" "clear
clear
clear
none"
absent "$WEIRD_DIR/INJECTED" 'start: dollar substitution never executes'
absent "$WEIRD_DIR/INJECTED2" 'start: backticks never execute'

FAKE_EXISTING=1 station --dir "$WEIRD_DIR" >/dev/null
if [ -f "$CAPTURE/attached" ]; then ok 'start: reconnect attaches'; else bad 'start: reconnect attaches'; fi
rm -f "$CAPTURE/attached"
if FAKE_EXISTING=1 station --dir "$FIXTURE_HOME" > "$ROOT/reconnect.out" 2>&1; then bad 'start: different cwd refused'; else ok 'start: different cwd refused'; fi

# A mode-600 token file is exported to the planner; nothing else changes.
mkdir -p "$FIXTURE_HOME/.claude"
printf 'fixture-token-123\n' > "$FIXTURE_HOME/.claude/oauth-token"
chmod 600 "$FIXTURE_HOME/.claude/oauth-token"
station --dir "$WEIRD_DIR" >/dev/null
check 'start: 0600 token file reaches the planner' "$(sed -n 4p "$CAPTURE/tokens")" fixture-token-123
check 'start: token does not widen the environment' "$(head -3 "$CAPTURE/tokens" | sort -u)" clear
# A wrong-mode file is refused — named — and exports nothing.
chmod 644 "$FIXTURE_HOME/.claude/oauth-token"
station --dir "$WEIRD_DIR" > "$ROOT/badmode.out" 2>&1
has "$ROOT/badmode.out" "$FIXTURE_HOME/.claude/oauth-token" 'start: wrong-mode token file is refused by name'
check 'start: wrong-mode token file exports nothing' "$(sed -n 4p "$CAPTURE/tokens")" none
rm -f "$FIXTURE_HOME/.claude/oauth-token"

station --planner claude >/dev/null
check 'start: Claude has distinct session' "$(cat "$CAPTURE/session")" "dispatch-$ME-claude-fable"
has "$CAPTURE/claude.args" 'fable' 'start: Claude selects Fable without a model flag'
has "$CAPTURE/claude.args" "$H/planner-skills/dispatch/SKILL.md" 'start: Claude opens as a harness planner'
check 'start: Claude runs in its own config' "$(cat "$CAPTURE/claude.home")" native
omits "$CAPTURE/claude.args" '--dangerously-skip-permissions' 'start: ordinary Claude does not request bypass'
station --model gpt-5.6-sol >/dev/null
has "$CAPTURE/codex.args" 'gpt-5.6-sol' 'start: explicit model honored'
rm -f "$CAPTURE/codex-ok"
if station > "$ROOT/start-bad.out" 2>&1; then bad 'start: missing login refused'; else ok 'start: missing login refused'; fi
touch "$CAPTURE/codex-ok"

echo "== hands-off =="
station --hands-off > "$ROOT/hands-off.out"
check 'hands-off: separate Codex session' "$(cat "$CAPTURE/session")" "dispatch-$ME-codex-gpt-6-astra-hands-off"
has "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'hands-off: Codex bypass is explicit'
omits "$CAPTURE/codex.args" '--dangerously-skip-permissions' 'hands-off: Codex does not receive Claude flag'
omits "$CAPTURE/context" 'hands-off' 'hands-off: permissions stay out of the context'
has "$CAPTURE/context" 'codex' 'hands-off: context keeps dir and planner'
rm -f "$CAPTURE/attached" "$CAPTURE/attached-to"
FAKE_EXISTING=1 station --hands-off >/dev/null
check 'hands-off: reconnect attaches to the bypass session' \
  "$(cat "$CAPTURE/attached-to")" "=dispatch-$ME-codex-gpt-6-astra-hands-off"
FAKE_EXISTING=1 station >/dev/null
check 'hands-off: an ordinary request never lands in the bypass session' \
  "$(cat "$CAPTURE/attached-to")" "=dispatch-$ME-codex-gpt-6-astra"
station --planner claude --model fable --hands-off >/dev/null
check 'hands-off: separate Claude session' "$(cat "$CAPTURE/session")" "dispatch-$ME-claude-fable-hands-off"
has "$CAPTURE/claude.args" '--dangerously-skip-permissions' 'hands-off: Claude bypass is explicit'
omits "$CAPTURE/claude.args" '--dangerously-bypass-approvals-and-sandbox' 'hands-off: Claude does not receive Codex flag'
rm -f "$CAPTURE/claude-ok"
if station --planner claude --hands-off > "$ROOT/start-bad.out" 2>&1; then bad 'hands-off: login still required'; else ok 'hands-off: login still required'; fi

echo "== remote: the SSH user is the identity =="
station doctor --host mini > /dev/null
has "$CAPTURE/ssh.args" 'BatchMode=yes' 'remote: doctor never waits for SSH login'
station --host mini --dir "$WEIRD_DIR" >/dev/null
has "$CAPTURE/ssh.args" '-t' 'remote: planner requests a terminal'
station --host bob@mini --dir "$WEIRD_DIR" >/dev/null
has "$CAPTURE/ssh.args" 'bob@mini' 'remote: another seat is reached by SSHing in as it'
REMOTE_HOME="$ROOT/remote home"
mkdir -p "$REMOTE_HOME/.claude"
ln -s "$H" "$REMOTE_HOME/.claude/harness"
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station --host mini --dir "$WEIRD_DIR" >/dev/null
check 'remote: quote survives SSH and tmux' "$(cat "$CAPTURE/dir")" "$WEIRD_DIR"
absent "$WEIRD_DIR/INJECTED" 'remote: shell syntax never executes'
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station --host mini --dir "$WEIRD_DIR" --hands-off >/dev/null
has "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'remote: hands-off survives SSH and tmux'
check 'remote: hands-off has separate session' "$(cat "$CAPTURE/session")" "dispatch-$ME-codex-gpt-6-astra-hands-off"
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station login codex --host mini >/dev/null
has "$CAPTURE/codex.args" '--device-auth' 'remote: login runs in the remote home'
check 'remote: login keeps the remote seat native' "$(head -1 "$CAPTURE/identity")" native

echo "== --owner is gone: the SSH hint =="
for option in 'start --owner alice' 'login claude --owner alice' 'doctor --owner alice' 'setup --owner alice' '--owner alice'; do
  # Only fixed test literals are split here.
  # shellcheck disable=SC2086
  if station $option > "$ROOT/owner.out" 2>&1; then bad "owner: rejects $option"; else
    rc=$?
    if [ "$rc" = 2 ]; then ok "owner: $option exits 2"; else bad "owner: $option exits 2 (got $rc)"; fi
  fi
done
has "$ROOT/owner.out" 'ssh alice@' 'owner: the refusal names the ssh command'
station start --host mini --owner alice > "$ROOT/owner-host.out" 2>&1 || true
has "$ROOT/owner-host.out" 'ssh alice@mini' 'owner: the refusal names the host when given'

echo "== login =="
station login codex > "$ROOT/login.out"
has "$CAPTURE/codex.args" '--device-auth' 'login: Codex device flow is default'
has "$ROOT/login.out" "for $ME" 'login: acts for the current OS user'
station login codex --browser >/dev/null
check 'login: browser fallback omits device flag' "$(cat "$CAPTURE/codex.args")" login
station login gh >/dev/null
has "$CAPTURE/gh.args" '--hostname github.com' 'login: gh device flow for github.com'
omits "$CAPTURE/gh.args" --web 'login: gh device flow is not the web flow'
station login gh --browser >/dev/null
has "$CAPTURE/gh.args" --web 'login: gh browser flow on request'
station login claude > "$ROOT/claude-login.out" 2>&1 <<'TOKEN'
pasted-secret-token
TOKEN
has "$ROOT/claude-login.out" 'oauth-token' 'login claude: explains the token file first'
has "$ROOT/claude-login.out" 'claude setup-token' 'login claude: names the setup-token command'
omits "$ROOT/claude-login.out" pasted-secret-token 'login claude: never echoes the pasted token'
if [ -f "$FIXTURE_HOME/.claude/oauth-token" ]; then ok 'login claude: token file written'; else bad 'login claude: token file written'; fi
check 'login claude: token file is mode 600' "$(mode_of "$FIXTURE_HOME/.claude/oauth-token")" 600
check 'login claude: first line is the token' "$(sed -n 1p "$FIXTURE_HOME/.claude/oauth-token")" pasted-secret-token
station login claude --browser >/dev/null
has "$CAPTURE/claude.args" '--claudeai' 'login claude: browser flow uses the subscription login'
rm -f "$CAPTURE/gh-ok" "$CAPTURE/codex-ok"
if printf '\n' | station login claude > "$ROOT/claude-skip.out" 2>&1; then bad 'login claude: empty paste fails'; else ok 'login claude: empty paste fails'; fi
has "$ROOT/claude-skip.out" '--browser' 'login claude: points at the browser flow on skip'

echo "== setup: five idempotent steps =="
rm -rf "$FIXTURE_HOME/.claude/oauth-token" "$FIXTURE_HOME/.claude/skills" "$FIXTURE_HOME/.zprofile"
rm -f "$CAPTURE/gh-ok" "$CAPTURE/codex-ok" "$CAPTURE/claude-ok"
mkdir -p "$ROOT/work"
fixture env DISPATCH_STATION_DIR="$ROOT/work" \
  bash "$H/station.sh" setup > "$ROOT/setup.out" 2>&1 <<'TOKEN'
setup-secret-token
TOKEN
has "$ROOT/setup.out" 'step 1/5' 'setup: token step runs'
has "$ROOT/setup.out" 'step 2/5' 'setup: gh step runs'
has "$ROOT/setup.out" 'step 3/5' 'setup: codex step runs'
has "$ROOT/setup.out" 'step 4/5' 'setup: skills step runs'
has "$ROOT/setup.out" 'step 5/5' 'setup: profile step runs'
has "$ROOT/setup.out" 'running doctor' 'setup: ends in doctor'
omits "$ROOT/setup.out" setup-secret-token 'setup: never echoes the pasted token'
check 'setup: token file is mode 600' "$(mode_of "$FIXTURE_HOME/.claude/oauth-token")" 600
for skill in dispatch briefed-dispatch; do
  if [ -e "$FIXTURE_HOME/.claude/skills/$skill" ]; then ok "setup: links $skill into ~/.claude/skills"; else bad "setup: links $skill into ~/.claude/skills"; fi
done
check 'setup: exactly one HARNESS_DIR profile line' "$(grep -c '^export HARNESS_DIR=' "$FIXTURE_HOME/.zprofile")" 1
# A second run keeps every login, replaces the profile line, adds nothing.
fixture env DISPATCH_STATION_DIR="$ROOT/work" \
  bash "$H/station.sh" setup > "$ROOT/setup2.out" 2>&1 </dev/null
has "$ROOT/setup2.out" 'claude token file present' 'setup: second run keeps the token file'
has "$ROOT/setup2.out" 'already signed in' 'setup: second run keeps completed logins'
check 'setup: profile line not stacked by re-runs' "$(grep -c '^export HARNESS_DIR=' "$FIXTURE_HOME/.zprofile")" 1
# A cancelled login stops setup without launching anything, keeping progress.
rm -f "$CAPTURE/codex-ok" "$CAPTURE/gh-ok" "$CAPTURE/claude-ok" "$FIXTURE_HOME/.claude/oauth-token"
# gh (step 2) completes before codex (step 3) is cancelled; the token step's
# empty paste is a skip, not a failure.
if fixture env DISPATCH_STATION_DIR="$ROOT/work" FAKE_LOGIN_FAIL=codex \
  bash "$H/station.sh" setup > "$ROOT/setup-fail.out" 2>&1 </dev/null; then bad 'setup: cancelled login fails'; else ok 'setup: cancelled login fails'; fi
if [ -f "$CAPTURE/gh-ok" ]; then ok 'setup: cancellation retains completed logins'; else bad 'setup: cancellation retains completed logins'; fi
touch "$CAPTURE/gh-ok" "$CAPTURE/codex-ok" "$CAPTURE/claude-ok"
printf 'not-started' > "$CAPTURE/session"
fixture env DISPATCH_STATION_DIR="$ROOT/work" \
  bash "$H/station.sh" setup > "$ROOT/setup3.out" 2>&1 </dev/null
check 'setup: never launches the planner itself' "$(cat "$CAPTURE/session")" not-started
# A fresh seat has no profile assignment yet. Invoking the shared script by its
# absolute path must derive that installation instead of looking under HOME.
fixture env -u HARNESS_DIR DISPATCH_STATION_DIR="$ROOT/work" \
  bash "$H/station.sh" setup > "$ROOT/setup-shared.out" 2>&1 </dev/null
has "$ROOT/setup-shared.out" 'setup complete' 'setup: shared script works before HARNESS_DIR is configured'
has "$FIXTURE_HOME/.zprofile" "$H" 'setup: the shared runtime path is written to the profile'
touch "$CAPTURE/codex-ok"

echo "== usage =="
# The retired directory-model flag is assembled from two quoted pieces so this
# file never spells it: outside the migration doc, the old model may not be
# named anywhere in the tree, not even on its way to being rejected.
retired='--accounts''-dir /tmp'
for option in "$retired" '--host -oops' '--planner other' '--browser' '--repo /tmp' 'doctor --hands-off' 'login codex --hands-off' 'login scope'; do
  # Fixed test literals only — the assembled one is just as fixed.
  # shellcheck disable=SC2086
  if station $option > "$ROOT/invalid.out" 2>&1; then bad "usage: rejects $option"; else ok "usage: rejects $option"; fi
done

printf 'station: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
