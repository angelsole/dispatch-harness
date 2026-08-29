#!/usr/bin/env bash
# Joining a laptop to the team's wall without typing a secret:
#   wall.sh --init-token   writes <HARNESS_DIR>/wall-ingest-token (600) and
#                          wall-url on the wall's machine, and the wall reads
#                          the token file itself when WALL_INGEST_TOKEN is unset;
#   install.sh --team H    reads both over ssh and writes the two knobs into
#                          notify.conf, replacing rather than stacking them.
# Everything external is a fake on PATH: node records the env wall.sh hands it,
# tailscale answers a fixed address, ssh serves the two files from a local dir.
#
# Usage: bash tests/team-join.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/team-join-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check()        { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
file_has()     { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }
mode_of()      { ls -l "$1" | cut -c1-10; }

FAKES="$ROOT/fakes"; mkdir -p "$FAKES"
export NODE_ENV_LOG="$ROOT/node-env.log"
cat > "$FAKES/node" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${WALL_INGEST_TOKEN-<unset>}" > "$NODE_ENV_LOG"
exit 0
FAKE
cat > "$FAKES/tailscale" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = ip ] && { echo 100.64.0.9; exit 0; }
exit 1
FAKE
chmod +x "$FAKES/node" "$FAKES/tailscale"
export PATH="$FAKES:$PATH"

echo "== wall.sh --init-token =="
H1="$ROOT/h1"; mkdir -p "$H1"
HARNESS_DIR="$H1" bash "$SRC/wall.sh" --init-token --port 4711 > "$ROOT/init1.out" 2>&1
check "init: exits 0" "$?" "0"
TOKEN="$(head -n 1 "$H1/wall-ingest-token" 2>/dev/null)"
check "init: the token is 48 hex chars" "$(printf '%s' "$TOKEN" | grep -cE '^[0-9a-f]{48}$')" "1"
check "init: the token file is mode 600" "$(mode_of "$H1/wall-ingest-token")" "-rw-------"
check "init: wall-url is the Tailscale address and the port" "$(cat "$H1/wall-url")" "http://100.64.0.9:4711"
file_has "$ROOT/init1.out" "install.sh --team" "init: tells the laptops how to join"
file_has_not "$ROOT/init1.out" "$TOKEN" "init: never prints the token"

HARNESS_DIR="$H1" bash "$SRC/wall.sh" --init-token --port 4711 --url http://wall.example:9 > "$ROOT/init2.out" 2>&1
check "init again: keeps the token the laptops already carry" "$(head -n 1 "$H1/wall-ingest-token")" "$TOKEN"
check "init again: --url replaces the detected address" "$(cat "$H1/wall-url")" "http://wall.example:9"
file_has "$ROOT/init2.out" "keep " "init again: says it kept the token"

echo "== the wall reads the token file =="
mkdir -p "$ROOT/runs"
HARNESS_DIR="$H1" bash "$SRC/wall.sh" --runs "$ROOT/runs" --host 127.0.0.1 --port 1 > /dev/null 2>&1
check "serve: the token file reaches the server's environment" "$(cat "$NODE_ENV_LOG")" "$TOKEN"
WALL_INGEST_TOKEN=env-wins HARNESS_DIR="$H1" bash "$SRC/wall.sh" --runs "$ROOT/runs" --host 127.0.0.1 --port 1 > /dev/null 2>&1
check "serve: an explicit WALL_INGEST_TOKEN wins over the file" "$(cat "$NODE_ENV_LOG")" "env-wins"
H0="$ROOT/h0"; mkdir -p "$H0"
HARNESS_DIR="$H0" bash "$SRC/wall.sh" --runs "$ROOT/runs" --host 127.0.0.1 --port 1 > /dev/null 2>&1
check "serve: no file, no env — the wall stays closed (empty token)" "$(cat "$NODE_ENV_LOG")" ""

echo "== install.sh --team =="
# ssh serves the wall's two files, whatever host and command it is asked for.
cat > "$FAKES/ssh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ROOT/ssh-calls.log"
[ -f "$ROOT/ssh-mode" ] && case "\$(cat "$ROOT/ssh-mode")" in
  down) exit 255 ;;
  half) cat "$H1/wall-url"; exit 0 ;;
esac
cat "$H1/wall-url" && cat "$H1/wall-ingest-token"
FAKE
chmod +x "$FAKES/ssh"
H2="$ROOT/h2"; mkdir -p "$H2" "$ROOT/skills"
run_install() {  # rest = extra flags; stdout+stderr to $ROOT/install.out
  HARNESS_DIR="$H2" CLAUDE_SKILLS_DIR="$ROOT/skills" HOME="$ROOT/home" \
    bash "$SRC/install.sh" --no-statusline --no-pixel "$@" > "$ROOT/install.out" 2>&1
}
mkdir -p "$ROOT/home"
run_install --team wallhost
check "team: install exits 0" "$?" "0"
CONF="$H2/notify.conf"
check "team: exactly one HARNESS_WALL_URL line" "$(grep -c '^HARNESS_WALL_URL=' "$CONF")" "1"
check "team: exactly one HARNESS_WALL_TOKEN line" "$(grep -c '^HARNESS_WALL_TOKEN=' "$CONF")" "1"
check "team: the url is the wall's" "$(sed -n 's/^HARNESS_WALL_URL="\(.*\)"$/\1/p' "$CONF")" "http://wall.example:9"
check "team: the token is the wall's" "$(sed -n 's/^HARNESS_WALL_TOKEN="\(.*\)"$/\1/p' "$CONF")" "$TOKEN"
check "team: the commented example lines are gone" "$(grep -c 'HARNESS_WALL_' "$CONF")" "2"
check "team: notify.conf is mode 600" "$(mode_of "$CONF")" "-rw-------"
file_has_not "$ROOT/install.out" "$TOKEN" "team: the token is never printed"
file_has "$ROOT/install.out" "http://wall.example:9" "team: says where the runs will report"
file_has "$ROOT/ssh-calls.log" "wallhost" "team: asked the named host"
file_has "$CONF" "HARNESS_NTFY_TOPIC" "team: the rest of notify.conf survives"

run_install --team=wallhost
check "team again: still one HARNESS_WALL_URL line" "$(grep -c '^HARNESS_WALL_URL=' "$CONF")" "1"
check "team again: still one HARNESS_WALL_TOKEN line" "$(grep -c '^HARNESS_WALL_TOKEN=' "$CONF")" "1"

# The knobs are read by run-task.sh the way notify.conf is sourced: plain
# assignments, so a sourced copy must yield exactly these two values.
check "team: notify.conf sources to the url" "$(bash -c ". '$CONF'; printf '%s' \"\$HARNESS_WALL_URL\"")" "http://wall.example:9"
check "team: notify.conf sources to the token" "$(bash -c ". '$CONF'; printf '%s' \"\$HARNESS_WALL_TOKEN\"")" "$TOKEN"

echo "== install.sh --team, when the wall is not ready =="
echo down > "$ROOT/ssh-mode"
run_install --team wallhost
check "down: install exits non-zero" "$([ "$?" -ne 0 ] && echo yes)" "yes"
file_has "$ROOT/install.out" "wall.sh --init-token" "down: says what to run on the wall's machine"
check "down: notify.conf keeps the previous join" "$(grep -c '^HARNESS_WALL_TOKEN=' "$CONF")" "1"
echo half > "$ROOT/ssh-mode"
run_install --team wallhost
check "half: a host with a url but no token is refused" "$([ "$?" -ne 0 ] && echo yes)" "yes"
rm -f "$ROOT/ssh-mode"
HARNESS_DIR="$H2" CLAUDE_SKILLS_DIR="$ROOT/skills" HOME="$ROOT/home" bash "$SRC/install.sh" --no-statusline --no-pixel --team > "$ROOT/install.out" 2>&1
check "flag: --team without a host is a usage error" "$?" "2"

echo
echo "team-join: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
