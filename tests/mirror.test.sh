#!/usr/bin/env bash
# The HARNESS_MIRROR contract: with it set, a run continuously mirrors its run
# dir to the target for the lifetime of the invocation, and stops dead when the
# invocation does; with it unset, nothing changes at all.
#
# None of that can be asserted by reading run-task.sh — a background loop, an
# EXIT trap and an exit code are behaviour — so every case here is a real
# run-task.sh invocation against a fabricated repo with a local bare remote and
# the fake `claude` / `codex` binaries the pattern in tests/preprod.test.sh
# established. The local (no-colon) target form is what makes that hermetic:
# the "other machine" is a directory under the temp root, and the one remote
# case deliberately names a host that cannot resolve. Nothing here reaches a
# network, and every write lands in the sandbox.
#
# Usage: bash tests/mirror.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mirror-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent() { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
file_has()     { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
file_has_not() { if grep -qF -- "$2" "$1" 2>/dev/null; then bad "$3 (found [$2] in $1)"; else ok "$3"; fi; }

# shellcheck source=../mirror.sh
. "$SRC/mirror.sh"

# Mirroring is guarded on rsync at its only call site and degrades to nothing
# without it. The integration cases need the real binary, but a machine without
# it must still prove that the documented no-op path is silent and successful.
if ! command -v rsync >/dev/null 2>&1; then
  echo "== rsync absent: mirroring degrades safely =="
  NO_RSYNC_RUN="$ROOT/no-rsync-run"
  mkdir -p "$NO_RSYNC_RUN"
  HARNESS_MIRROR="$ROOT/no-rsync-wall"
  mirror_sync "$NO_RSYNC_RUN" no-rsync
  check "missing rsync: mirror_sync still succeeds" "$?" "0"
  exists "missing rsync: the diagnostic stays in the run dir" "$NO_RSYNC_RUN/mirror.log"
  absent "missing rsync: no destination is created" "$HARNESS_MIRROR/no-rsync"
  echo
  printf 'mirror: %d passed, %d failed (rsync integration unavailable)\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

# Poll rather than sleep: the assertions are about how quickly the mirror
# follows the run dir, so they measure it. Tenths of a second, since a pass is
# two seconds.
wait_for()  { local i=0; while [ ! -e "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i+1)); done; echo "$i"; }
wait_gone() { local i=0; while [   -e "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.1; i=$((i+1)); done; echo "$i"; }
within() {  # $1 = deciseconds waited, $2 = limit, $3 = label
  if [ "$1" -lt "$2" ]; then ok "$3 (${1}00ms)"; else bad "$3 (gave up after ${1}00ms)"; fi
}
listing() {  # $1 = dir, $2 = one name to leave out
  local f
  for f in "$1"/*; do
    f=$(basename "$f")
    [ "$f" = "$2" ] || printf '%s\n' "$f"
  done
}

# --- fixture: a repo with a real (local) origin ------------------------------
BARE="$ROOT/origin.git"
REPO="$ROOT/mirrorapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# A repo with no origin at all: run-task.sh's first fetch fails, which is the
# fail() exit path — the earliest terminal state the wall can be shown.
NOREMOTE="$ROOT/noremote"
git init -q "$NOREMOTE"
git -C "$NOREMOTE" config user.email t@t
git -C "$NOREMOTE" config user.name  t
git -C "$NOREMOTE" commit -q --allow-empty -m init

# --- fake workers ------------------------------------------------------------
FAKES="$ROOT/bin"; mkdir -p "$FAKES"
cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
# Implementer stand-in. Emits real stream-json events so the run writes a
# feed.log, optionally holds the run open while the test pokes the live run
# dir, and either asks a question (needs_input) or commits.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"fixture.txt"}}]}}\n'
if [ -n "${HOLD_UNTIL:-}" ]; then
  i=0
  while [ ! -f "$HOLD_UNTIL" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done
fi
if [ "${FIXTURE_QUESTIONS:-0}" = 1 ]; then
  printf '# blocked\nWhich way?\n' > .harness/QUESTIONS.md
else
  date > fixture.txt
  git add fixture.txt
  git commit -q -m "feat: fixture change"
fi
printf '{"type":"result","subtype":"success","session_id":"11111111-2222-3333-4444-555555555555"}\n'
SH
cat > "$FAKES/codex" <<'SH'
#!/usr/bin/env bash
# Reviewer stand-in: rejecting ends the run before the push/PR stage.
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "-C" ] && wt="$a"
  prev="$a"
done
printf 'fixture stop\n' > "$wt/.harness/REJECTED.md"
SH
chmod +x "$FAKES/claude" "$FAKES/codex"

# A harness dir laid out the way install.sh installs one.
mkharness() {  # $1 = ticket
  local h="$ROOT/harness-$1"
  mkdir -p "$h/runs/$1"
  cp "$SRC/repos.conf.sh" "$SRC/mirror.sh" "$SRC/worker-settings.json" "$h/"
  printf '# fixture task\n' > "$h/runs/$1/brief.md"
  printf '%s' "$h"
}

dispatch() {  # $1 = ticket, $2 = repo — HARNESS_MIRROR & co. come from the caller
  HARNESS_DIR="$ROOT/harness-$1" CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
  HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC="" \
    bash "$SRC/run-task.sh" "$1" "$2" "fix/$1" > "$ROOT/run-$1.log" 2>&1
}

MIRROR="$ROOT/wall-runs"   # the "other machine" — deliberately not pre-created

# ---------------------------------------------------------------------------
# A live run: the mirror follows the run dir while the run is still going
# ---------------------------------------------------------------------------
echo "== live run: the wall follows a run on another machine =="
T=mirror-live
H=$(mkharness "$T"); RUN="$H/runs/$T"
export HARNESS_MIRROR="$MIRROR" HOLD_UNTIL="$ROOT/go"
dispatch "$T" "$REPO" &
DISPATCH_PID=$!

within "$(wait_for "$MIRROR/$T/status" 150)" 100 "live: the run appears on the mirror while it runs"
exists "live: the target directory was created for us" "$MIRROR/$T"

# A run that stopped to ask something raises the loudest alarm on the wall, and
# --delete is what takes it down again once the orchestrator has answered.
printf '# blocked\nWhich way?\n' > "$RUN/QUESTIONS.md"
within "$(wait_for "$MIRROR/$T/QUESTIONS.md" 100)" 50 "live: a new file reaches the mirror within an interval"
rm -f "$RUN/QUESTIONS.md"
within "$(wait_gone "$MIRROR/$T/QUESTIONS.md" 100)" 50 "live: --delete clears an answered QUESTIONS.md from the mirror"

touch "$ROOT/go"
wait "$DISPATCH_PID"; RC_LIVE=$?
# The moment run-task.sh returns, its loop must already be reaped — measured
# here rather than after the sleep below, where the loop's own parent-follow
# would have ended it anyway. A surviving loop is a fork of run-task.sh, so it
# carries the same argv.
LEFTOVER=$(ps -Ao args= 2>/dev/null | grep -F "run-task.sh $T" | grep -vc grep)
unset HOLD_UNTIL

echo "== after the run: the terminal state is on the wall =="
check "live: a rejected run still exits 1" "$RC_LIVE" "1"
exists   "live: result.json is mirrored"           "$MIRROR/$T/result.json"
exists   "live: feed.log is mirrored"              "$MIRROR/$T/feed.log"
check    "live: the mirrored result is terminal" \
  "$(jq -r .status "$MIRROR/$T/result.json" 2>/dev/null)" "rejected"
file_has "$MIRROR/$T/status" "done: rejected"      "live: the mirrored status is the terminal stage"
check    "live: the mirrored result.json matches the run's" \
  "$(cat "$MIRROR/$T/result.json")" "$(cat "$RUN/result.json")"

echo "== after the run: no mirror process outlives the invocation =="
check "no loop: nothing of the run is left the moment it returns" "$LEFTOVER" "0"
# And behaviourally, which is what actually matters: change the run dir now and
# it must never reach the mirror again.
printf 'written after the run ended\n' > "$RUN/orphan-probe"
sleep 5   # comfortably more than two mirror passes
absent "no loop: a post-run change is never mirrored" "$MIRROR/$T/orphan-probe"

# ---------------------------------------------------------------------------
# cleanup.sh drops the mirrored copy
# ---------------------------------------------------------------------------
echo "== cleanup.sh: a promoted run leaves the wall's disk =="
mkdir -p "$MIRROR/mirror-gone" "$H/runs/mirror-gone"
printf '1 done: ready\n' > "$MIRROR/mirror-gone/status"
HARNESS_DIR="$H" bash "$SRC/cleanup.sh" mirror-gone > "$ROOT/cleanup-on.log" 2>&1
check  "cleanup: exits 0 with nothing else to clean" "$?" "0"
absent "cleanup: the mirrored copy is gone" "$MIRROR/mirror-gone"
file_has "$ROOT/cleanup-on.log" "cleared mirrored copy" "cleanup: says what it cleared"

mkdir -p "$MIRROR/mirror-kept" "$H/runs/mirror-kept"
printf '1 done: ready\n' > "$MIRROR/mirror-kept/status"
( unset HARNESS_MIRROR; HARNESS_DIR="$H" bash "$SRC/cleanup.sh" mirror-kept ) > "$ROOT/cleanup-off.log" 2>&1
exists "cleanup: leaves the mirror alone when HARNESS_MIRROR is unset" "$MIRROR/mirror-kept"
file_has_not "$ROOT/cleanup-off.log" "mirrored copy" "cleanup: says nothing about mirroring when it is off"

# ---------------------------------------------------------------------------
# Unset: the run is what it was before this feature existed
# ---------------------------------------------------------------------------
echo "== HARNESS_MIRROR unset: nothing mirrors, nothing changes =="
T=mirror-off
H_OFF=$(mkharness "$T"); RUN_OFF="$H_OFF/runs/$T"
unset HARNESS_MIRROR
OFF_START=$(date +%s)
dispatch "$T" "$REPO"; RC_OFF=$?
OFF_SECONDS=$(( $(date +%s) - OFF_START ))
check  "off: the run still ends rejected, exit 1" "$RC_OFF" "1"
check  "off: result.json says rejected" "$(jq -r .status "$RUN_OFF/result.json")" "rejected"
absent "off: nothing is written to the mirror root" "$MIRROR/$T"
absent "off: the run dir gains no mirror.log"       "$RUN_OFF/mirror.log"

# ---------------------------------------------------------------------------
# An unreachable target changes nothing about the run
# ---------------------------------------------------------------------------
echo "== unreachable ssh target: the run does not notice =="
T=mirror-remote
H_REM=$(mkharness "$T"); RUN_REM="$H_REM/runs/$T"
export HARNESS_MIRROR="nosuchhost.invalid:/tmp/harness-mirror-test"
REM_START=$(date +%s)
dispatch "$T" "$REPO"; RC_REM=$?
REM_SECONDS=$(( $(date +%s) - REM_START ))
check "unreachable: same exit code as a run with no mirror" "$RC_REM" "$RC_OFF"
check "unreachable: same status as a run with no mirror" \
  "$(jq -r .status "$RUN_REM/result.json")" "$(jq -r .status "$RUN_OFF/result.json")"
# Same artefacts, plus the one file that records the failure.
check "unreachable: the run dir is what it would be without a mirror" \
  "$(listing "$RUN_REM" mirror.log)" "$(listing "$RUN_OFF" '')"
if [ -s "$RUN_REM/mirror.log" ]; then
  ok "unreachable: the failure is recorded in mirror.log"
else
  bad "unreachable: the failure is recorded in mirror.log (log is empty)"
fi
file_has_not "$ROOT/run-$T.log" "rsync"  "unreachable: no rsync noise in the run's own output"
file_has_not "$ROOT/run-$T.log" "resolve host" "unreachable: no ssh noise in the run's own output"
if [ "$REM_SECONDS" -le $(( OFF_SECONDS + MIRROR_SYNC_TIMEOUT + 1 )) ]; then
  ok "unreachable: the run is not slowed down (${REM_SECONDS}s vs ${OFF_SECONDS}s unmirrored)"
else
  bad "unreachable: the run is not slowed down (${REM_SECONDS}s vs ${OFF_SECONDS}s unmirrored)"
fi

# ---------------------------------------------------------------------------
# The other two exit paths still reach the wall, and still exit as they did
# ---------------------------------------------------------------------------
echo "== needs_input (exit 3): the question reaches the wall =="
T=mirror-asks
mkharness "$T" >/dev/null
export HARNESS_MIRROR="$MIRROR" FIXTURE_QUESTIONS=1
dispatch "$T" "$REPO"; RC_ASK=$?
unset FIXTURE_QUESTIONS
check    "asks: the exit-3 contract survives the EXIT trap" "$RC_ASK" "3"
exists   "asks: the question is on the wall" "$MIRROR/$T/QUESTIONS.md"
check    "asks: the mirrored result says needs_input" \
  "$(jq -r .status "$MIRROR/$T/result.json" 2>/dev/null)" "needs_input"
file_has "$MIRROR/$T/status" "waiting" "asks: the mirrored status is the waiting stage"

echo "== fail() (setup_failed): the terminal state still lands =="
T=mirror-setupfail
mkharness "$T" >/dev/null
dispatch "$T" "$NOREMOTE"; RC_FAIL=$?
check    "fail: still exits 1" "$RC_FAIL" "1"
check    "fail: the mirrored result says setup_failed" \
  "$(jq -r .status "$MIRROR/$T/result.json" 2>/dev/null)" "setup_failed"
file_has "$MIRROR/$T/status" "done: setup_failed" "fail: the mirrored status is the terminal stage"
unset HARNESS_MIRROR

# ---------------------------------------------------------------------------
# The library's own contract, called directly
# ---------------------------------------------------------------------------
echo "== mirror.sh: target forms and the no-op cases =="
HARNESS_MIRROR="mini:.claude/harness/runs"; mirror_is_remote
check "lib: a colon means an ssh destination" "$?" "0"
HARNESS_MIRROR="/some/dir"; mirror_is_remote
check "lib: a plain path means this machine" "$?" "1"

ODD_REMOTE="dir/odd'name"
QUOTED_REMOTE=$(mirror_shell_quote "$ODD_REMOTE")
eval "ROUND_TRIP_REMOTE=$QUOTED_REMOTE"
check "lib: remote paths are shell-quoted without changing them" "$ROUND_TRIP_REMOTE" "$ODD_REMOTE"

UNIT="$ROOT/unit"; mkdir -p "$UNIT/run"
printf 'x\n' > "$UNIT/run/status"
HARNESS_MIRROR="$UNIT/wall"
mirror_sync "$UNIT/run" unit-1
exists "lib: mirror_sync creates the target directory" "$UNIT/wall/unit-1/status"
mirror_remove unit-1
absent "lib: mirror_remove drops just that run" "$UNIT/wall/unit-1"

# A run id is untrusted input to cleanup.sh. It must never escape the configured
# target and turn cleanup into deletion of a sibling directory.
mkdir -p "$UNIT/safe-root/target" "$UNIT/safe-root/keep"
HARNESS_MIRROR="$UNIT/safe-root/target"
mirror_remove ../keep
exists "lib: mirror_remove refuses path traversal" "$UNIT/safe-root/keep"

NO_RSYNC_RUN="$UNIT/no-rsync"; mkdir -p "$NO_RSYNC_RUN"
SAVED_PATH="$PATH"
# shellcheck disable=SC2123  # Deliberately hide the optional binary for this call.
PATH="$ROOT/path-without-rsync"
HARNESS_MIRROR="$UNIT/no-rsync-wall"
mirror_sync "$NO_RSYNC_RUN" no-rsync
NO_RSYNC_RC=$?
PATH="$SAVED_PATH"
check "lib: missing rsync is successful" "$NO_RSYNC_RC" "0"
file_has "$NO_RSYNC_RUN/mirror.log" "rsync not installed" "lib: missing rsync records one diagnostic"
absent "lib: missing rsync creates no destination" "$UNIT/no-rsync-wall/no-rsync"

# A pass that never returns must be canceled at shutdown and the final attempt
# must hit the library's hard deadline. This pins both non-blocking best-effort
# behavior and the original exit code.
STALL_BIN="$ROOT/stall-bin"; STALL_RUN="$UNIT/stall-run"
mkdir -p "$STALL_BIN" "$STALL_RUN"
cat > "$STALL_BIN/rsync" <<'SH'
#!/usr/bin/env bash
trap 'exit 142' ALRM
trap 'exit 143' TERM INT
while :; do :; done
SH
chmod +x "$STALL_BIN/rsync"
STALL_START=$(date +%s)
PATH="$STALL_BIN:$PATH" HARNESS_MIRROR="$UNIT/stall-wall" \
  bash -c '. "$1"; mirror_start "$2" stalled; exit 7' _ "$SRC/mirror.sh" "$STALL_RUN"
STALL_RC=$?
STALL_SECONDS=$(( $(date +%s) - STALL_START ))
check "lib: a stalled mirror preserves the caller's exit code" "$STALL_RC" "7"
if [ "$STALL_SECONDS" -le $(( MIRROR_SYNC_TIMEOUT + 1 )) ]; then
  ok "lib: a stalled mirror cannot block shutdown (${STALL_SECONDS}s)"
else
  bad "lib: a stalled mirror cannot block shutdown (${STALL_SECONDS}s)"
fi
STALL_LEFT=$(ps -Ao args= 2>/dev/null | grep -F "$STALL_BIN/rsync" | grep -vc grep)
check "lib: the stalled rsync is reaped before shutdown returns" "$STALL_LEFT" "0"

unset HARNESS_MIRROR
mirror_sync "$UNIT/run" unit-2
check  "lib: mirror_sync is a no-op with no target" "$?" "0"
absent "lib: and writes nothing" "$UNIT/wall/unit-2"
mirror_remove unit-2
check  "lib: mirror_remove is a no-op with no target" "$?" "0"
HARNESS_MIRROR="$UNIT/wall"
mirror_remove ""
check  "lib: mirror_remove refuses an empty run id" "$?" "0"
exists "lib: and leaves the target standing" "$UNIT/wall"
unset HARNESS_MIRROR

# ---------------------------------------------------------------------------
# Documented where the rest of the environment is
# ---------------------------------------------------------------------------
echo "== HARNESS_MIRROR is documented =="
file_has "$SRC/README.md"  'HARNESS_MIRROR' "docs: README documents the env var"
file_has "$SRC/README.md"  'rsync'          "docs: README names the dependency"
file_has "$SRC/install.sh" 'mirror.sh'      "docs: install.sh installs the library"

echo
printf 'mirror: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
