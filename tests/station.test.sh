#!/usr/bin/env bash
# Station/installer behavior with fake providers, SSH and tmux. No account
# logins, model calls, shared tmux server or writes outside this temp fixture.
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/station-test.XXXXXX")"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT
FIXTURE_HOME="$ROOT/home"
H="$FIXTURE_HOME/.claude/harness"
BIN="$ROOT/bin"; CAPTURE="$ROOT/capture"
mkdir -p "$FIXTURE_HOME" "$BIN" "$CAPTURE"
pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }
has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3"; fi; }
absent() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2"; fi; }
omits() { if grep -qF -- "$2" "$1"; then bad "$3"; else ok "$3"; fi; }
# Clear ambient overrides so this suite cannot inherit a real station identity.
fixture() {
  env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u GH_CONFIG_DIR -u HARNESS_OWNER \
    -u DISPATCH_STATION_DIR -u DISPATCH_PLANNER -u DISPATCH_MODEL -u QM_ACCOUNTS_DIR \
    -u CLAUDE_SKILLS_DIR -u CODEX_SKILLS_DIR -u CLAUDE_SETTINGS_FILE \
    HOME="$FIXTURE_HOME" HARNESS_DIR="$H" PATH="$BIN:$PATH" CAPTURE="$CAPTURE" \
    CODEX_BIN=codex CLAUDE_BIN=claude "$@"
}
station() { fixture bash "$H/station.sh" "$@"; }
install() { fixture bash "$SRC/install.sh" --no-statusline "$@" > "$ROOT/install.out"; }
cat > "$BIN/codex" <<'CLI'
#!/usr/bin/env bash
set -eu
case "$*" in
  'login status')
    [ "${FAKE_AUTH_FAIL:-}" != codex ] || exit 1
    [ "${FAKE_SETUP:-0}" != 1 ] || [ -f "$CAPTURE/setup-codex" ]; exit ;;
  '--version') echo 'codex-cli 0.153.4'; exit ;;
esac
if [ "$1" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != codex ] || exit 1
  [ "${FAKE_SETUP:-0}" != 1 ] || touch "$CAPTURE/setup-codex"
  printf 'codex\n' >> "$CAPTURE/login-calls"
fi
printf '%s\n' "$@" > "$CAPTURE/codex.args"
printf '%s\n' "${CODEX_HOME:-native}" "${CLAUDE_CONFIG_DIR:-native}" "${GH_CONFIG_DIR:-native}" "${HARNESS_OWNER:-}" > "$CAPTURE/identity"
printf '%s\n' "${GH_TOKEN:-clear}" "${OPENAI_API_KEY:-clear}" "${ANTHROPIC_API_KEY:-clear}" > "$CAPTURE/tokens"
CLI
cat > "$BIN/claude" <<'CLI'
#!/usr/bin/env bash
set -eu
if [ "$*" = 'auth status --json' ]; then
  if [ "${FAKE_AUTH_FAIL:-}" = claude ]; then echo '{"loggedIn":false}'; exit 1; fi
  if [ "${FAKE_SETUP:-0}" = 1 ] && [ ! -f "$CAPTURE/setup-claude" ]; then echo '{"loggedIn":false}'; exit 1; fi
  echo '{"loggedIn":true}'; exit
fi
if [ "${2:-}" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != claude ] || exit 1
  [ "${FAKE_SETUP:-0}" != 1 ] || touch "$CAPTURE/setup-claude"
  printf 'claude\n' >> "$CAPTURE/login-calls"
fi
printf '%s\n' "$@" > "$CAPTURE/claude.args"
printf '%s\n' "${CLAUDE_CONFIG_DIR:-native}" > "$CAPTURE/claude.home"
CLI
cat > "$BIN/gh" <<'CLI'
#!/usr/bin/env bash
set -eu
case "$*" in 'auth status --hostname github.com')
  [ "${FAKE_AUTH_FAIL:-}" != gh ] || exit 1
  [ "${FAKE_SETUP:-0}" != 1 ] || [ -f "$CAPTURE/setup-gh" ]; exit ;; esac
if [ "${2:-}" = login ]; then
  [ "${FAKE_LOGIN_FAIL:-}" != gh ] || exit 1
  [ "${FAKE_SETUP:-0}" != 1 ] || touch "$CAPTURE/setup-gh"
  printf 'gh\n' >> "$CAPTURE/login-calls"
fi
printf '%s\n' "$@" > "$CAPTURE/gh.args"
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
  attach-session) touch "$CAPTURE/attached"; exit ;;
  new-session)
    printf '%s' "$4" > "$CAPTURE/session"
    printf '%s' "$6" > "$CAPTURE/dir"
    printf '%s' "${13}" > "$CAPTURE/context"
    # Simulate a tmux server that retained another user's ambient API keys.
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
install --symlink
if [ -L "$FIXTURE_HOME/.agents/skills/dispatch/SKILL.md" ]; then ok 'install: copy can return to symlink'; else bad 'install: copy can return to symlink'; fi
if [ -f "$H/planner-skills/dispatch/SKILL.md" ]; then ok 'install: shared protocol is in runtime'; else bad 'install: shared protocol is in runtime'; fi
for skill_root in "$FIXTURE_HOME/.agents/skills" "$FIXTURE_HOME/.claude/skills"; do
  if cmp -s "$SRC/skills/dispatch/references/pipeline.md" "$skill_root/dispatch/references/pipeline.md"; then
    ok 'install: linked detailed dispatch protocol is available to the planner'
  else bad 'install: detailed dispatch protocol is missing'; fi
done

station doctor > "$ROOT/doctor.out"
has "$ROOT/doctor.out" '0 failed check(s)' 'doctor: healthy fixture succeeds'
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
if FAKE_AUTH_FAIL=codex station doctor --owner alice > "$ROOT/doctor-bad.out"; then bad 'doctor: missing auth fails'; else ok 'doctor: missing auth fails'; fi
has "$ROOT/doctor-bad.out" "'login' 'codex' '--owner' 'alice'" 'doctor: repair selects affected owner'
absent "$FIXTURE_HOME/accounts/alice" 'doctor: missing account is not created'
station login codex --owner alice > "$ROOT/login.out"
has "$CAPTURE/codex.args" '--device-auth' 'login: Codex device flow is default'
check 'login: owner home selected' "$(head -1 "$CAPTURE/identity")" "$FIXTURE_HOME/accounts/alice/codex"
station login codex --owner alice --browser >/dev/null
check 'login: browser fallback omits device flag' "$(cat "$CAPTURE/codex.args")" login
station login claude --owner alice >/dev/null
has "$CAPTURE/claude.args" '--claudeai' 'login: Claude uses subscription'
station login gh --owner alice >/dev/null
check 'login: GitHub owner home selected' "$(cat "$CAPTURE/gh.home")" "$FIXTURE_HOME/accounts/alice/gh"

# Literal shell syntax and a quote in the path must survive tmux's shell hop.
WEIRD_DIR="$ROOT/space ' \$(touch INJECTED) \`touch INJECTED2\`"
mkdir -p "$WEIRD_DIR"
station --owner alice --dir "$WEIRD_DIR" > "$ROOT/start.out"
check 'start: Astra session' "$(cat "$CAPTURE/session")" dispatch-alice-codex-gpt-6-astra
has "$CAPTURE/codex.args" 'gpt-6-astra' 'start: Astra model is explicit'
omits "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'start: ordinary Codex does not request bypass'
has "$CAPTURE/codex.args" "$H/runs" 'start: run directory is writable for Codex'
check 'start: tmux receives literal directory' "$(cat "$CAPTURE/dir")" "$WEIRD_DIR"
check 'start: tmux inherited tokens cleared' "$(sort -u "$CAPTURE/tokens")" clear
absent "$WEIRD_DIR/INJECTED" 'start: dollar substitution never executes'
absent "$WEIRD_DIR/INJECTED2" 'start: backticks never execute'
FAKE_EXISTING=1 station --owner alice --dir "$WEIRD_DIR" >/dev/null
if [ -f "$CAPTURE/attached" ]; then ok 'start: reconnect attaches'; else bad 'start: reconnect attaches'; fi
if FAKE_EXISTING=1 station --owner alice --dir "$FIXTURE_HOME" > "$ROOT/reconnect.out" 2>&1; then bad 'start: different cwd refused'; else ok 'start: different cwd refused'; fi
mkdir -p "$ROOT/other-accounts/alice"
if FAKE_EXISTING=1 station --owner alice --dir "$WEIRD_DIR" --accounts-dir "$ROOT/other-accounts" > "$ROOT/reconnect.out" 2>&1; then bad 'start: different account root refused'; else ok 'start: different account root refused'; fi
station --owner alice --planner claude >/dev/null
check 'start: Claude has distinct session' "$(cat "$CAPTURE/session")" dispatch-alice-claude-default
check 'start: Claude account selected' "$(cat "$CAPTURE/claude.home")" "$FIXTURE_HOME/accounts/alice/claude"
omits "$CAPTURE/claude.args" '--dangerously-skip-permissions' 'start: ordinary Claude does not request bypass'
if [ -f "$FIXTURE_HOME/accounts/alice/claude/skills/dispatch/SKILL.md" ]; then ok 'start: Claude owner discovers shared skills'; else bad 'start: Claude owner discovers shared skills'; fi
if [ -f "$FIXTURE_HOME/accounts/alice/claude/skills/dispatch-pixel/SKILL.md" ]; then ok 'start: Claude owner discovers enabled visual skill'; else bad 'start: Claude owner discovers enabled visual skill'; fi
station --owner alice --model gpt-5.6-sol >/dev/null
has "$CAPTURE/codex.args" 'gpt-5.6-sol' 'start: explicit model honored'
if FAKE_AUTH_FAIL=codex station --owner alice > "$ROOT/start-bad.out" 2>&1; then bad 'start: missing login refused'; else ok 'start: missing login refused'; fi

station --owner alice --hands-off > "$ROOT/hands-off.out"
check 'hands-off: separate Codex session' "$(cat "$CAPTURE/session")" dispatch-alice-codex-gpt-6-astra-hands-off
has "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'hands-off: Codex bypass is explicit'
omits "$CAPTURE/codex.args" '--dangerously-skip-permissions' 'hands-off: Codex does not receive Claude flag'
has "$CAPTURE/context" "'hands-off'" 'hands-off: context records permissions'
rm -f "$CAPTURE/attached"
FAKE_EXISTING=1 station --owner alice --hands-off >/dev/null
if [ -f "$CAPTURE/attached" ]; then ok 'hands-off: same context reconnects'; else bad 'hands-off: same context reconnects'; fi
if FAKE_EXISTING=1 station --owner alice > "$ROOT/reconnect-mode.out" 2>&1; then bad 'hands-off: ordinary request rejects bypass context'; else ok 'hands-off: ordinary request rejects bypass context'; fi
station --owner alice --planner claude --model fable --hands-off >/dev/null
check 'hands-off: separate Claude session' "$(cat "$CAPTURE/session")" dispatch-alice-claude-fable-hands-off
has "$CAPTURE/claude.args" '--dangerously-skip-permissions' 'hands-off: Claude bypass is explicit'
omits "$CAPTURE/claude.args" '--dangerously-bypass-approvals-and-sandbox' 'hands-off: Claude does not receive Codex flag'
if FAKE_AUTH_FAIL=claude station --owner alice --planner claude --hands-off > "$ROOT/start-bad.out" 2>&1; then bad 'hands-off: login still required'; else ok 'hands-off: login still required'; fi

station doctor --host mini --owner alice > /dev/null
has "$CAPTURE/ssh.args" 'BatchMode=yes' 'remote: doctor never waits for SSH login'
station --host mini --owner alice --dir "$WEIRD_DIR" >/dev/null
has "$CAPTURE/ssh.args" '-t' 'remote: planner requests a terminal'
REMOTE_HOME="$ROOT/remote home"
mkdir -p "$REMOTE_HOME/.claude"
ln -s "$H" "$REMOTE_HOME/.claude/harness"
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station login codex --host mini --owner bob >/dev/null
check 'remote: account paths resolve on the Mini' "$(head -1 "$CAPTURE/identity")" "$REMOTE_HOME/accounts/bob/codex"
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station --host mini --owner bob --dir "$WEIRD_DIR" >/dev/null
check 'remote: quote survives SSH and tmux' "$(cat "$CAPTURE/dir")" "$WEIRD_DIR"
absent "$WEIRD_DIR/INJECTED" 'remote: shell syntax never executes'
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station --host mini --owner bob --dir "$WEIRD_DIR" --hands-off >/dev/null
has "$CAPTURE/codex.args" '--dangerously-bypass-approvals-and-sandbox' 'remote: hands-off survives SSH and tmux'
check 'remote: hands-off has separate session' "$(cat "$CAPTURE/session")" dispatch-bob-codex-gpt-6-astra-hands-off

: > "$CAPTURE/login-calls"
station setup --owner alice >/dev/null
check 'setup: healthy accounts skip every login' "$(cat "$CAPTURE/login-calls")" ''
check 'setup: opens Astra after checks' "$(cat "$CAPTURE/session")" dispatch-alice-codex-gpt-6-astra
FAKE_SETUP=1 station setup --owner new-person >/dev/null
check 'setup: guides all missing logins in order' "$(tr '\n' ' ' < "$CAPTURE/login-calls")" 'codex claude gh '
check 'setup: opens the new owner session' "$(cat "$CAPTURE/session")" dispatch-new-person-codex-gpt-6-astra
check 'setup: new owner credentials stay in own directory' "$(head -1 "$CAPTURE/identity")" "$FIXTURE_HOME/accounts/new-person/codex"
: > "$CAPTURE/login-calls"
rm "$CAPTURE/setup-claude"
FAKE_SETUP=1 station setup --owner new-person >/dev/null
check 'setup: renews only the missing provider' "$(cat "$CAPTURE/login-calls")" claude
rm "$CAPTURE/setup-claude"
printf 'not-started' > "$CAPTURE/session"
if FAKE_SETUP=1 FAKE_LOGIN_FAIL=claude station setup --owner new-person > "$ROOT/setup-fail.out" 2>&1; then bad 'setup: cancelled login fails'; else ok 'setup: cancelled login fails'; fi
check 'setup: cancelled login never launches planner' "$(cat "$CAPTURE/session")" not-started
if [ -f "$CAPTURE/setup-codex" ] && [ -f "$CAPTURE/setup-gh" ]; then ok 'setup: cancellation retains completed logins'; else bad 'setup: cancellation retains completed logins'; fi
if station setup </dev/null > "$ROOT/setup-missing-owner.out" 2>&1; then bad 'setup: requires owner without terminal'; else ok 'setup: requires owner without terminal'; fi
if fixture env HARNESS_OWNER=alice bash "$H/station.sh" setup </dev/null > "$ROOT/setup-ambient-owner.out" 2>&1; then bad 'setup: never selects an ambient shared owner'; else ok 'setup: never selects an ambient shared owner'; fi
mkdir -p "$REMOTE_HOME/.agents"
ln -s "$FIXTURE_HOME/.agents/skills" "$REMOTE_HOME/.agents/skills"
FAKE_SSH_EXEC=1 FAKE_REMOTE_HOME="$REMOTE_HOME" station setup --host mini --owner bob >/dev/null
check 'setup: works over SSH without a separate remote installer' "$(cat "$CAPTURE/session")" dispatch-bob-codex-gpt-6-astra
has "$CAPTURE/ssh.args" '-t' 'setup: remote onboarding requests a terminal'
station setup --owner alice --planner claude --hands-off >/dev/null
has "$CAPTURE/claude.args" '--dangerously-skip-permissions' 'setup: hands-off reaches selected planner after login checks'
station login claude >/dev/null
check 'native: login keeps Claude configuration unset' "$(cat "$CAPTURE/claude.home")" native
station --planner claude --hands-off >/dev/null
check 'native: tmux does not inherit an old Claude profile' "$(cat "$CAPTURE/claude.home")" native
check 'native: avoids pre-fix alternate-profile session' "$(cat "$CAPTURE/session")" dispatch-current-claude-default-native-hands-off
station >/dev/null
check 'native: tmux clears inherited account directory overrides' "$(head -3 "$CAPTURE/identity" | sort -u)" native
fixture env CLAUDE_CONFIG_DIR="$FIXTURE_HOME/.claude" bash "$H/station.sh" --planner claude >/dev/null
check 'native: explicitly selected default directory stays explicit' "$(cat "$CAPTURE/claude.home")" "$FIXTURE_HOME/.claude"
for option in '--owner ../escape' '--host -oops' '--planner other' '--browser' '--repo /tmp' 'doctor --hands-off' 'login codex --hands-off'; do
  # Only fixed test literals are split here.
  # shellcheck disable=SC2086
  if station $option > "$ROOT/invalid.out" 2>&1; then bad "usage: rejects $option"; else ok "usage: rejects $option"; fi
done

printf 'station: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
