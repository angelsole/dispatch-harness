#!/usr/bin/env bash
# The seat layer of lib/common.sh: a seat is an OS user, seat_exec is the one
# door across accounts, and ~/.claude/oauth-token is the one credential the
# harness itself exports. Everything runs against the real lib/common.sh with
# fakes on PATH: `id` answers for the fixture's seats, `uname` picks the Darwin
# or Linux home lookup (dscl / getent), and `sudo` dumps its argv one line per
# argument — which pins the exact crossing sudo is asked to build, including
# that no token ever appears on it: argv is ps(1)-visible. When the current
# user already is the seat, seat_exec execs directly, so the suite fakes
# `id -un` to sit inside the seat and checks the same explicit environment
# arrives without sudo.
#
# No real sudo, no real accounts, no writes outside this temp fixture.
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/lib/common.sh"
PROBE="$SRC/seat-probe.sh"
SUDOERS="$SRC/examples/sudoers-dispatch-crew.example"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/seat-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1"; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }
line_is()  { if grep -qx -- "$2" "$1"; then ok "$3"; else bad "$3 (no exact line [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FIXTURE_HOME="$ROOT/home"; HARNESS="$ROOT/harness"
BIN="$ROOT/bin"
SEATS="$ROOT/seats"; HOMES="$ROOT/homes"
CURRENT="$ROOT/current-user"; UNAME_STATE="$ROOT/uname-state"
SUDO_LOG="$ROOT/sudo.log"; SUDO_RC="$ROOT/sudo-rc"
ERRLOG="$ROOT/stderr.log"
SEAT_HOMES="$ROOT/seat-homes"
mkdir -p "$FIXTURE_HOME/.claude" "$HARNESS" "$BIN" \
  "$SEAT_HOMES/angel" "$SEAT_HOMES/bea home" "$SEAT_HOMES/seat-3"
printf 'angel\nbea\nseat-3\n' > "$SEATS"
printf 'angel:%s\nbea:%s\nseat-3:%s\n' \
  "$SEAT_HOMES/angel" "$SEAT_HOMES/bea home" "$SEAT_HOMES/seat-3" > "$HOMES"
: > "$CURRENT"
printf 'Darwin\n' > "$UNAME_STATE"
: > "$SUDO_LOG"; printf '0' > "$SUDO_RC"
FIXPATH="$BIN:/usr/bin:/bin"

# Seat registry semantics, not a real passwd: `id -u NAME` answers only for
# the seats registered above and delegates everything else to the real binary,
# so an unknown name fails exactly the way it would on a machine with no such
# user. `id -un` answers from a state file so a test can sit inside a seat.
cat > "$BIN/id" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 2 ] && [ "\$1" = -u ] && grep -qx -- "\$2" "$SEATS"; then
  echo 2000; exit 0
fi
if [ "\$#" -eq 1 ] && [ "\$1" = -un ] && [ -s "$CURRENT" ]; then
  cat "$CURRENT"; exit 0
fi
exec /usr/bin/id "\$@"
EOF

cat > "$BIN/uname" <<EOF
#!/usr/bin/env bash
cat "$UNAME_STATE"
EOF

# dscl . -read /Users/NAME NFSHomeDirectory — the macOS home lookup, printing
# the same labelled format the real one does (bea's home has a space in it).
cat > "$BIN/dscl" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 4 ] && [ "\$2" = -read ] && [ "\$4" = NFSHomeDirectory ]; then
  home=\$(sed -n "s/^\${3#/Users/}://p" "$HOMES")
  [ -n "\$home" ] || exit 1
  printf 'NFSHomeDirectory: %s\n' "\$home"
  exit 0
fi
exit 1
EOF

# getent passwd NAME — the Linux home lookup, field 6 of the passwd line.
cat > "$BIN/getent" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 2 ] && [ "\$1" = passwd ]; then
  home=\$(sed -n "s/^\$2://p" "$HOMES")
  [ -n "\$home" ] || exit 2
  printf '%s:x:2000:2000::%s:/bin/bash\n' "\$2" "\$home"
  exit 0
fi
exit 2
EOF

# The crossing under test: one line per argv element, then a configurable exit
# status so pass-through can be asserted. It never runs the command — the argv
# IS the contract here (sudo's env_reset, and the child environment it hands
# over, are exercised through the exec-ing fakes in the quartermaster and
# schedule suites).
cat > "$BIN/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SUDO_LOG"
exit "\$(cat "$SUDO_RC" 2>/dev/null || echo 0)"
EOF

# The command seat_exec execs on the direct path: dumps the environment it can
# see, one name= value per line, then its argv. umask is normalized (leading
# zeros stripped) because bash prints it four digits wide on some platforms and
# two on others — the digits are the contract, not the width.
cat > "$BIN/seatcmd" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$@"
printf 'PAIR=%s\n' "\${PAIR-<unset>}"
printf 'QVALUE=%s\n' "\${QVALUE-<unset>}"
printf 'HARNESS_OWNER=%s\n' "\${HARNESS_OWNER-<unset>}"
printf 'HARNESS_DIR=%s\n' "\${HARNESS_DIR-<unset>}"
printf 'SPECTATOR=%s\n' "\${SPECTATOR-<unset>}"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
printf 'HOME=%s\n' "\$HOME"
printf 'PATH=%s\n' "\$PATH"
printf 'umask=%s\n' "\$(umask | sed 's/^0*//')"
EOF
chmod +x "$BIN"/*

# Ambient identity is never inherited: every assertion comes from the fixture.
# The PATH is pinned (not prefixed) so an exact argv compare can rebuild it.
fixture() {
  env -u CLAUDE_CODE_OAUTH_TOKEN -u HARNESS_OWNER -u HARNESS_GROUP -u HARNESS_SEAT \
    HOME="$FIXTURE_HOME" HARNESS_DIR="$HARNESS" PATH="$FIXPATH" "$@"
}

echo "== seat_exists =="
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
if seat_exists bea; then echo yes; else echo no; fi
if seat_exists seat-3; then echo yes; else echo no; fi
if seat_exists zz-noseat; then echo yes; else echo no; fi
SNIP
)
check 'seat_exists: registered seats exist, unknown names do not' "$out" 'yes
yes
no'

echo "== seat_home =="
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_home angel
SNIP
)
check 'seat_home: Darwin reads the dscl record' "$out" "$SEAT_HOMES/angel"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_home bea
SNIP
)
check 'seat_home: a home with a space survives whole' "$out" "$SEAT_HOMES/bea home"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_home zz-noseat >/dev/null && echo found || echo missing
SNIP
)
check 'seat_home: unknown seat is missing' "$out" missing
printf 'Linux\n' > "$UNAME_STATE"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_home seat-3
seat_home zz-noseat >/dev/null && echo found || echo missing
SNIP
)
check 'seat_home: Linux reads the getent record, unknown still missing' "$out" \
"$SEAT_HOMES/seat-3
missing"
printf 'Darwin\n' > "$UNAME_STATE"

echo "== seat_exec: the sudo crossing =="
: > "$SUDO_LOG"
fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_exec angel "PATH=$PATH" "HARNESS_DIR=$HARNESS_DIR" 'NOTE=he said "hi"' \
  -- /opt/dispatch/run-task.sh OLYX-1 '/repo with space'
SNIP
expected="$ROOT/expected-argv"
{
  printf '%s\n' -n -u angel -H
  printf 'PATH=%s\n' "$FIXPATH"
  printf 'HARNESS_DIR=%s\n' "$HARNESS"
  printf 'NOTE=%s\n' 'he said "hi"'
  printf '%s\n' /opt/dispatch/run-task.sh OLYX-1 '/repo with space'
} > "$expected"
check 'seat_exec: sudo argv is exactly -n -u SEAT -H, pairs, command' \
  "$(cat "$SUDO_LOG")" "$(cat "$expected")"
file_has_not "$SUDO_LOG" '--' 'seat_exec: the separator never reaches sudo'

: > "$SUDO_LOG"
fixture env HARNESS_WALL_TOKEN=probe-must-not-receive bash -s "$LIB" <<'SNIP'
. "$1"
seat_exec angel "PATH=$PATH" -- /opt/dispatch/seat-probe.sh
SNIP
file_has_not "$SUDO_LOG" '--preserve-env=HARNESS_WALL_TOKEN' \
  'seat_exec: unrelated seat commands do not inherit the service wall token'
file_has_not "$SUDO_LOG" 'probe-must-not-receive' \
  'seat_exec: ambient wall token is not passed without the seat_run marker'

printf '42' > "$SUDO_RC"
fixture bash -s "$LIB" >/dev/null <<'SNIP'
. "$1"
seat_exec bea "PATH=$PATH" -- /bin/true
SNIP
rc=$?
check 'seat_exec: the child exit status replaces the caller (exec)' "$rc" 42
printf '0' > "$SUDO_RC"

echo "== seat_exec: refused before any crossing =="
: > "$SUDO_LOG"
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec
SNIP
)
rc=$?
check 'seat_exec: no arguments is rc 2' "$rc" 2
has "$errout" 'needs a seat and a command' 'seat_exec: says what is missing'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec angel not-a-pair -- /bin/true
SNIP
)
rc=$?
check 'seat_exec: a non-pair argument is rc 2' "$rc" 2
has "$errout" 'is not VAR=value' 'seat_exec: names the malformed argument'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec angel A-B=value -- /bin/true
SNIP
)
rc=$?
check 'seat_exec: an invalid shell variable name is rc 2' "$rc" 2
has "$errout" 'is not VAR=value' 'seat_exec: rejects names the direct path cannot export'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec angel "PATH=$PATH"
SNIP
)
rc=$?
check 'seat_exec: a missing separator is rc 2' "$rc" 2
has "$errout" 'missing -- before the command' 'seat_exec: says where the separator goes'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec angel "PATH=$PATH" --
SNIP
)
rc=$?
check 'seat_exec: a missing command is rc 2' "$rc" 2
has "$errout" 'missing command after --' 'seat_exec: says the command is absent'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
seat_exec zz-noseat "PATH=$PATH" -- /bin/true
SNIP
)
rc=$?
check 'seat_exec: an unknown seat is rc 1' "$rc" 1
has "$errout" "no user named 'zz-noseat'" 'seat_exec: names the unknown seat'
check 'seat_exec: refusals never reached sudo' "$(cat "$SUDO_LOG")" ''

echo "== the token file =="
printf 'seat-test-token-9\n' > "$FIXTURE_HOME/.claude/oauth-token"
chmod 600 "$FIXTURE_HOME/.claude/oauth-token"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
SNIP
)
check 'token: a 0600 file is exported at source time' "$out" seat-test-token-9
chmod 644 "$FIXTURE_HOME/.claude/oauth-token"
out=$(fixture bash -s "$LIB" 2>"$ERRLOG" <<'SNIP'
. "$1"
printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
SNIP
)
rc=$?
check 'token: a wrong-mode file is refused, not fatal, at source time' "$rc" 0
check 'token: a wrong-mode file exports nothing' "$out" '<unset>'
file_has "$ERRLOG" "$FIXTURE_HOME/.claude/oauth-token" 'token: the refusal names the file'
file_has "$ERRLOG" 'mode 600' 'token: the refusal names the required mode'
file_has_not "$ERRLOG" 'seat-test-token-9' 'token: the refusal never echoes the token'
errout=$(fixture bash -s "$LIB" 2>&1 <<'SNIP'
. "$1"
harness_oauth_token strict && echo strict-ok || echo strict-refused
SNIP
)
has "$errout" 'strict-refused' 'token: strict treats the wrong mode as a failure'
chmod 600 "$FIXTURE_HOME/.claude/oauth-token"
: > "$FIXTURE_HOME/.claude/oauth-token"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
SNIP
)
check 'token: an empty file exports nothing' "$out" '<unset>'

out=$(fixture bash "$PROBE")
has "$out" 'token=ok' 'probe: token mode uses the shared file-mode helper'
if grep -q '^mode_of()' "$PROBE"; then
  bad 'probe: does not duplicate the shared file-mode helper'
else
  ok 'probe: does not duplicate the shared file-mode helper'
fi

echo "== seat_exec without sudo: the caller already is the seat =="
printf 'seat-test-token-9\n' > "$FIXTURE_HOME/.claude/oauth-token"
chmod 600 "$FIXTURE_HOME/.claude/oauth-token"
printf 'angel\n' > "$CURRENT"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
export SPECTATOR=ambient-noise HARNESS_DIR=/tmp/leftover-seat
seat_exec angel 'PAIR=two words' 'QVALUE=say "hi"' -- seatcmd one 'two three'
SNIP
)
expected="$ROOT/expected-direct"
cat > "$expected" <<EOF
argv:one
argv:two three
PAIR=two words
QVALUE=say "hi"
HARNESS_OWNER=angel
HARNESS_DIR=<unset>
SPECTATOR=<unset>
CLAUDE_CODE_OAUTH_TOKEN=seat-test-token-9
HOME=$FIXTURE_HOME
PATH=$FIXPATH
umask=2
EOF
check 'self-exec: same explicit environment, no sudo' "$out" "$(cat "$expected")"
rm -f "$FIXTURE_HOME/.claude/oauth-token"
: > "$SUDO_LOG"
out=$(fixture bash -s "$LIB" <<'SNIP'
. "$1"
seat_exec angel 'PAIR=again' -- seatcmd
SNIP
)
has "$out" 'CLAUDE_CODE_OAUTH_TOKEN=<unset>' \
  'self-exec: no token file means no token in the child'
check 'self-exec: sudo is never consulted' "$(cat "$SUDO_LOG")" ''
: > "$CURRENT"

echo "== seat_run: the service-user launcher =="
printf 'seat-test-token-9\n' > "$FIXTURE_HOME/.claude/oauth-token"
chmod 600 "$FIXTURE_HOME/.claude/oauth-token"
: > "$SUDO_LOG"
fixture bash -s "$LIB" <<'SNIP'
. "$1"
export HARNESS_KNOB=carried-along HARNESS_WALL_TOKEN=wall-secret-42 \
  IMPLEMENTER_EFFORT=high SPECTATOR=ambient-noise
seat_run bea /bin/echo hi
SNIP
line_is "$SUDO_LOG" 'bea' 'seat_run: sudo is asked for the named seat'
file_has "$SUDO_LOG" 'PATH=' 'seat_run: PATH travels as an explicit pair'
file_has "$SUDO_LOG" "HARNESS_DIR=$HARNESS" 'seat_run: HARNESS_DIR travels as an explicit pair'
file_has "$SUDO_LOG" 'HARNESS_KNOB=carried-along' 'seat_run: the HARNESS_* sweep is carried'
file_has "$SUDO_LOG" 'IMPLEMENTER_EFFORT=high' 'seat_run: implementer knobs are carried'
file_has "$SUDO_LOG" '/bin/echo' 'seat_run: the command follows the pairs'
line_is "$SUDO_LOG" 'hi' 'seat_run: arguments stay single argv elements'
file_has_not "$SUDO_LOG" 'SPECTATOR=' 'seat_run: nothing outside the sweep is carried'
file_has "$SUDO_LOG" '--preserve-env=HARNESS_WALL_TOKEN' \
  'seat_run: sudo preserves the wall token without putting its value in argv'
file_has_not "$SUDO_LOG" 'wall-secret-42' 'seat_run: the wall token value never rides the command line'
file_has_not "$SUDO_LOG" 'seat-test-token-9' 'seat_run: the token never rides the command line'
file_has_not "$SUDO_LOG" 'CLAUDE_CODE_OAUTH_TOKEN=' 'seat_run: the token is never even named on argv'
rm -f "$FIXTURE_HOME/.claude/oauth-token"

echo "== the sudoers fragment =="
[ -f "$SUDOERS" ] && ok 'sudoers: the example ships' || bad 'sudoers: the example ships'
file_has "$SUDOERS" 'NOPASSWD:SETENV' 'sudoers: unattended crossings, explicit env'
file_has "$SUDOERS" '/run-task.sh' 'sudoers: run-task.sh is allowed'
file_has "$SUDOERS" '/capacity.sh' 'sudoers: capacity.sh is allowed'
file_has "$SUDOERS" '/seat-probe.sh' 'sudoers: seat-probe.sh is allowed'
n=$(grep 'NOPASSWD:SETENV' "$SUDOERS" | grep -oE '[^ ,]+\.sh' | grep -c '')
check 'sudoers: exactly three commands, no fourth' "$n" 3
file_has_not "$SUDOERS" '/Users/' 'sudoers: no machine-specific home path'
# The rendered docs fragment is the copy people paste from; it must stay
# placeholder-clean too.
fragment=$(awk '/^```sudoers$/{f=1;next} /^```/{f=0} f' "$SRC/docs/reference.md")
has "$fragment" 'NOPASSWD:SETENV' 'sudoers: docs fragment keeps the tag'
has "$fragment" 'seat-probe.sh' 'sudoers: docs fragment lists the probe'
has_not "$fragment" '/Users/' 'sudoers: docs fragment has no /Users/ path'
if command -v visudo >/dev/null 2>&1; then
  if errout=$(visudo -c -f "$SUDOERS" 2>&1); then
    ok 'sudoers: the example passes visudo -c'
  else
    bad "sudoers: visudo rejects the example: $errout"
  fi
else
  printf '  skip sudoers: visudo is not installed on this machine\n'
fi

printf 'seat: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
