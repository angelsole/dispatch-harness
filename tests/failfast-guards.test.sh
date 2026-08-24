#!/usr/bin/env bash
# The two fail-fast guards, as a test.
#
#   1. require_clean_worktree — the one predicate behind the implementer→gate
#      boundary and the read-only review passes. A dirty tree at the boundary
#      ends the run dirty_worktree_failed before the gate or any review tier
#      runs, and a re-dispatch hands the resumed session the paths to commit or
#      discard.
#   2. preflight_remote_auth — write auth exercised at setup, before an
#      implementer pass is spent. Fails only on a credential signature;
#      HARNESS_SKIP_PUSH_PREFLIGHT=1 bypasses it.
#
# Nothing real is contacted: the units run against local git fixtures, the auth
# branch against a loopback server that answers 401, and the end-to-end runs are
# real run-task.sh invocations against a fabricated repo with a local bare
# remote — the technique tests/turn-ceiling.test.sh uses. The 401 server needs
# python3; without it those checks say `skip` and the rest still runs.
#
# Usage: bash tests/failfast-guards.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/failfast-guards-test.XXXXXX")"
trap ' [ -n "${AUTH_SRV_PID:-}" ] && { kill "$AUTH_SRV_PID" 2>/dev/null; wait "$AUTH_SRV_PID" 2>/dev/null; }; rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()  { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()  { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has(){ if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
skip()    { pass=$((pass+1)); printf '  skip %s\n' "$1"; }

for bin in jq node; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "  FAIL failfast guards: $bin is required to run this suite"
    echo; printf 'failfast guards: 0 passed, 1 failed\n'; exit 1
  fi
done

# The three functions are the contract: sourceable from lib/common.sh, arg-only.
# shellcheck source=../lib/common.sh
. "$SRC/lib/common.sh"

# ---------------------------------------------------------------------------
echo "== _is_auth_error: credential signatures, and only those =="
# ---------------------------------------------------------------------------
auth_is() {  # $1 = label, $2 = sample, $3 = want: auth|other
  if _is_auth_error "$2"; then got=auth; else got=other; fi
  check "auth: $1" "$got" "$3"
}
auth_is "could not read Password (the observed push failure)" \
  "fatal: could not read Password for 'https://angelsole@github.com': terminal prompts disabled" auth
auth_is "could not read Username" \
  "fatal: could not read Username for 'http://127.0.0.1:1/': terminal prompts disabled" auth
auth_is "Authentication failed" \
  "error: Authentication failed for https://example.com/repo.git/" auth
auth_is "Invalid credentials" "remote: Invalid credentials" auth
auth_is "Bad credentials" "remote: Bad credentials" auth
auth_is "a bare 403" "remote: HTTP 403: Forbidden" auth
auth_is "a non-fast-forward is NOT this guard's concern" \
  "To github.com:x/y.git
 ! [rejected]        fix/thing -> fix/thing (non-fast-forward)" other
auth_is "a dead network is NOT this guard's concern" \
  "fatal: unable to access 'https://example.com/y/': Could not resolve host: example.com" other
auth_is "a missing remote is NOT this guard's concern" \
  "fatal: '/nowhere.git' does not appear to be a git repository" other
auth_is "an up-to-date push is not a failure at all" "Everything up-to-date" other

# ---------------------------------------------------------------------------
echo "== require_clean_worktree: the one dirty predicate =="
# ---------------------------------------------------------------------------
UNIT="$ROOT/unit"
git init -q "$UNIT"
git -C "$UNIT" config user.email t@t
git -C "$UNIT" config user.name  t
printf 'a\n' > "$UNIT/file.txt"
git -C "$UNIT" add file.txt
git -C "$UNIT" commit -q -m init
# Harness metadata is excluded in every real worktree's info/exclude, and the
# predicate must not count it: .harness/ is where the run's own artifacts live.
mkdir -p "$UNIT/.harness"
printf '# brief\n' > "$UNIT/.harness/brief.md"
EXCL="$(git -C "$UNIT" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$EXCL")"; echo '.harness/' >> "$EXCL"

OUT_CW=$(require_clean_worktree "$UNIT" 2>&1); RC_CW=$?
check "clean: a clean tree passes" "$RC_CW" "0"
check "clean: and says nothing" "$OUT_CW" ""

printf 'b\n' >> "$UNIT/file.txt"
OUT_CW=$(require_clean_worktree "$UNIT" 2>&1); RC_CW=$?
check "dirty: a modified file fails" "$RC_CW" "1"
has "$OUT_CW" "file.txt" "dirty: naming the offending path"
has "$OUT_CW" "not gating a partial diff" "dirty: saying why"

printf 'scratch\n' > "$UNIT/leftover.txt"
OUT_CW=$(require_clean_worktree "$UNIT" 2>&1)
has "$OUT_CW" "leftover.txt" "dirty: untracked files count too"
git -C "$UNIT" checkout -q -- file.txt
rm "$UNIT/leftover.txt"
require_clean_worktree "$UNIT" 2>/dev/null \
  && ok "clean: an excluded .harness/ never counts as dirty" \
  || bad "clean: an excluded .harness/ never counts as dirty"

# ---------------------------------------------------------------------------
echo "== preflight_remote_auth: write auth, and only write auth =="
# ---------------------------------------------------------------------------
BARE_UNIT="$ROOT/unit-origin.git"
git init -q --bare "$BARE_UNIT"
git -C "$UNIT" remote add origin "$BARE_UNIT"
git -C "$UNIT" push -q origin main 2>/dev/null

PO=$(preflight_remote_auth "$UNIT" main "$BARE_UNIT" 2>&1); PRC=$?
check "writable: a local bare remote passes" "$PRC" "0"
check "writable: quietly" "$PO" ""
PO=$(preflight_remote_auth "$UNIT" side-branch 2>&1); PRC=$?
check "writable: a branch the remote does not have yet passes too" "$PRC" "0"

PO=$(preflight_remote_auth "$UNIT" main "$ROOT/no-such-remote.git" 2>&1); PRC=$?
check "non-auth: a nonexistent remote does NOT block setup" "$PRC" "0"
PO=$(preflight_remote_auth "$UNIT" main "https://host-nobody-resolves.invalid/x.git" 2>&1); PRC=$?
check "non-auth: a DNS-dead remote does NOT block setup" "$PRC" "0"
# The no-prompt guard is part of the contract: without it a dispatch from a
# terminal hangs on /dev/tty instead of failing in seconds.
file_has "$SRC/lib/common.sh" "GIT_TERMINAL_PROMPT=0 git" \
  "non-auth: the push runs with terminal prompts disabled"

# A loopback server answering 401 to everything: the credential branch without
# a network. git gets the challenge, finds no helper, and — with prompts
# disabled — fails with the exact signature the run observed.
AUTH_PORT_FILE="$ROOT/auth-port"
if command -v python3 >/dev/null 2>&1; then
  cat > "$ROOT/auth401.py" <<'PYEOF'
import http.server, socketserver, sys

class Deny(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="git"')
        self.send_header("Content-Length", "0")
        self.end_headers()
    do_GET = deny
    do_POST = deny

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

srv = Srv(("127.0.0.1", 0), Deny)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
  python3 "$ROOT/auth401.py" "$AUTH_PORT_FILE" &
  AUTH_SRV_PID=$!
  i=0; until [ -s "$AUTH_PORT_FILE" ] || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i+1)); done
  AUTH_PORT=$(cat "$AUTH_PORT_FILE" 2>/dev/null || echo "")
else
  AUTH_PORT=""
fi

if [ -n "$AUTH_PORT" ]; then
  PO=$(preflight_remote_auth "$UNIT" main "http://127.0.0.1:$AUTH_PORT/auth.git" 2>&1 </dev/null); PRC=$?
  check "auth: a 401 push fails the preflight" "$PRC" "1"
  has "$PO" "cannot authenticate a push" "auth: saying the end-of-run push will fail"
  has "$PO" "GH_TOKEN" "auth: and naming the fix"
  has_not "$PO" "Username for" "auth: without ever asking for one"
else
  skip "auth: a 401 push fails the preflight (no python3 for the loopback server)"
  skip "auth: saying the end-of-run push will fail (no python3)"
  skip "auth: and naming the fix (no python3)"
  skip "auth: without ever asking for one (no python3)"
fi

# ---------------------------------------------------------------------------
# End to end: the real run-task.sh, a fabricated repo, a local bare remote and
# a fake implementer — the tests/turn-ceiling.test.sh fixture.
# ---------------------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
STATION="$ROOT/station"
CLAUDE_CALLS="$ROOT/claude-calls.log"
CLAUDE_MODE="$ROOT/claude-mode"
ATTEMPTS="$ROOT/attempts"
CCUSAGE_JSON="$ROOT/ccusage.json"
SCHED_CALLS="$ROOT/schedule-calls.log"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$STATION/claude"
: > "$SCHED_CALLS"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"; chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/capacity.sh" "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
cp -R "$SRC/lib" "$SRCDIR/lib"
cp -R "$SRC/lib" "$HARNESS/lib"
# A failing gate parks every run that gets past the boundary at gate_failed —
# short of gh, a PR and any network, while proving the run crossed the guard.
cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='exit 1' ;;
    redapp|redapp-*)     INSTALL_CMD=''; GATE_CMD='exit 1' ;;
  esac
}
EOF

mkrepo() {  # $1 = dir name -> a clone of a fresh bare remote, main pushed
  local bare="$ROOT/$1-origin.git" clone="$ROOT/$1"
  git init -q --bare "$bare"
  git clone -q "$bare" "$clone" 2>/dev/null
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name  t
  git -C "$clone" commit -q --allow-empty -m init
  git -C "$clone" branch -M main
  git -C "$clone" push -q -u origin main
}
mkrepo greenapp
mkrepo redapp
REPO="$ROOT/greenapp"
REDAUTH="$ROOT/redapp"

cat > "$SRCDIR/schedule.sh" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$SCHED_CALLS"
mkdir -p "\$RUNS/\$1"
date +%s > "\$RUNS/\$1/scheduled"
EOF

cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
cat "$CCUSAGE_JSON"
EOF

# Implementer stand-in: records its flags and prompt, then answers from the
# loaded mode. Reviewer spawns return before anything is recorded, so the call
# count counts implementer segments only.
cat > "$FAKES/claude" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in *"You are the reviewer stage"*) exit 0 ;; esac; done
flags=""; skiparg=0
for a in "\$@"; do
  if [ "\$skiparg" = 1 ]; then skiparg=0; continue; fi
  if [ "\$a" = "-p" ]; then skiparg=1; continue; fi
  flags="\$flags \$a"
done
printf 'argv:%s\n' "\$flags" >> "$CLAUDE_CALLS"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-p" ]; then printf 'prompt:%s\n---\n' "\$a" >> "$CLAUDE_CALLS"; break; fi
  prev="\$a"
done
n=\$(cat "$ATTEMPTS" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$ATTEMPTS"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"segment-%s"}]}}\n' "\$n"
finished() { printf '{"type":"result","subtype":"success","result":"segment %s finished","session_id":"fork-%s","num_turns":%s,"usage":{"input_tokens":%s,"output_tokens":%s}}\n' "\$n" "\$n" "\$((n * 10))" "\$((n * 100))" "\$((n * 1000))"; }
case "\$(cat "$CLAUDE_MODE")" in
  commit)
    date >> fixture.txt
    git add fixture.txt >/dev/null
    git commit -q -m "feat: fixture change" >/dev/null
    finished
    ;;
  dirty)
    printf 'the committed half\n' > done-part.txt
    git add done-part.txt >/dev/null
    git commit -q -m "feat: the committed half" >/dev/null
    printf 'scratch\n' > leftover-scratch.txt
    printf 'an uncommitted edit\n' >> done-part.txt
    finished
    ;;
  dirty-fix)
    git add -A >/dev/null
    git commit -q -m "fix: commit the leftovers" >/dev/null
    finished
    ;;
esac
EOF
chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/claude"

RESET_EPOCH=$(( $(date +%s) + 900 ))
iso_utc() { perl -e 'use POSIX qw(strftime); print strftime("%Y-%m-%dT%H:%M:%S.000Z", gmtime($ARGV[0]))' "$1"; }
cat > "$CCUSAGE_JSON" <<EOF
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"endTime":"$(iso_utc "$RESET_EPOCH")",
   "tokenCounts":{"outputTokens":10000}}
]}
EOF

RC=0; OUT=""; RUN=""; WT=""
dispatch() {  # $1 = run id, $2 = repo dir, $3 = mode, $4 = space-separated VAR=VAL overrides
  local ticket="$1" repo="$2" mode="$3" overrides="${4:-}"
  RUN="$RUNS/$ticket"
  WT="$ROOT/$(basename "$repo")-$(printf '%s' "$ticket" | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  printf '%s\n' "$mode" > "$CLAUDE_MODE"
  : > "$CLAUDE_CALLS"; echo 0 > "$ATTEMPTS"
  # shellcheck disable=SC2086
  env -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES -u HARNESS_REDISPATCH \
      -u HARNESS_RESUME_MODE -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL \
      -u IMPLEMENTER_EFFORT -u HARNESS_SKIP_PUSH_PREFLIGHT \
      -u GIT_TERMINAL_PROMPT -u GH_TOKEN \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$ROOT/no-such-codex" \
      CLAUDE_CONFIG_DIR="$STATION/claude" HARNESS_NOTIFY=0 \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$repo" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1 </dev/null
  RC=$?
  OUT=$(cat "$ROOT/run-$ticket.log")
  return 0
}
stage_now()     { cut -d' ' -f2- < "$RUN/status" 2>/dev/null; }
result_status() { jq -r '.status // ""' "$RUN/result.json" 2>/dev/null; }
stages()        { cat "$RUN/stages.log" 2>/dev/null; }
spawns()        { grep -c '^prompt:' "$CLAUDE_CALLS" 2>/dev/null | tr -d ' '; }
prompts()       { cat "$CLAUDE_CALLS" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== the boundary guard, end to end =="
# ---------------------------------------------------------------------------
dispatch GUARD-DIRTY "$REPO" dirty
check "dirty: the run fails" "$RC" "1"
check "dirty: and its terminal stage is done: dirty_worktree_failed" \
  "$(stage_now)" "done: dirty_worktree_failed"
check "dirty: result.json agrees" "$(result_status)" "dirty_worktree_failed"
has "$OUT" "leftover-scratch.txt" "dirty: the refusal names the uncommitted path"
has "$OUT" "done-part.txt" "dirty: and the modified one"
has "$OUT" "not gating a partial diff" "dirty: saying why it refused"
absent "dirty: the gate never ran" "$RUN/gate-1.log"
has_not "$(stages)" "test gate" "dirty: no gate stage was recorded"
has_not "$(stages)" "review" "dirty: no review tier ever saw the diff"
check "dirty: exactly one implementer segment was spent" "$(spawns)" "1"
has "$(prompts)" "Commit ALL your work before finishing" \
  "contract: the implementer was told the tree must be clean"
has "$(prompts)" "rejects a dirty worktree" \
  "contract: in the words the guard enforces"

# ---------------------------------------------------------------------------
echo "== the dirty resume, end to end =="
# ---------------------------------------------------------------------------
dispatch GUARD-DIRTY "$REPO" dirty-fix
RESUME_PROMPT=$(prompts)
has "$RESUME_PROMPT" "leftover-scratch.txt" \
  "resume: the prompt names the path to commit or discard"
has "$RESUME_PROMPT" "uncommitted changes" \
  "resume: and says why the run stopped"
has "$RESUME_PROMPT" "Commit ALL your work before finishing" \
  "resume: the restated rules carry the clean-tree rule too"
check "resume: the run crosses the boundary and parks at the gate" \
  "$(stage_now)" "done: gate_failed"
exists "resume: the gate ran this time" "$RUN/gate-1.log"
require_clean_worktree "$WT" 2>/dev/null \
  && ok "resume: the worktree is clean again" \
  || bad "resume: the worktree is clean again"

# ---------------------------------------------------------------------------
echo "== the push-auth preflight, end to end =="
# ---------------------------------------------------------------------------
# redapp's pushes are rewritten to the 401 server while its fetches (anonymous
# reads against the local bare remote) keep succeeding — the exact shape of the
# observed failure, minus the network.
if [ -n "$AUTH_PORT" ]; then
  git -C "$REDAUTH" config "url.http://127.0.0.1:$AUTH_PORT/auth.git.pushInsteadOf" \
      "$ROOT/redapp-origin.git"
  dispatch GUARD-AUTH "$REDAUTH" commit
  check "auth: the dispatch stops at setup" "$(stage_now)" "done: setup_failed"
  check "auth: result.json agrees" "$(result_status)" "setup_failed"
  check "auth: the implementer never ran" "$(spawns)" "0"
  has "$OUT" "cannot authenticate a push" "auth: the failure is named at setup"
  has "$OUT" "GH_TOKEN" "auth: with the fix in the message"

  dispatch GUARD-SKIP "$REDAUTH" commit "HARNESS_SKIP_PUSH_PREFLIGHT=1"
  check "skip: the knob bypasses the preflight" "$(stage_now)" "done: gate_failed"
  check "skip: the implementer ran this time" "$( [ "$(spawns)" -ge 1 ] && echo yes )" "yes"
else
  skip "auth: the dispatch stops at setup (no python3 for the loopback server)"
  skip "auth: result.json agrees (no python3)"
  skip "auth: the implementer never ran (no python3)"
  skip "auth: the failure is named at setup (no python3)"
  skip "auth: with the fix in the message (no python3)"
  skip "skip: the knob bypasses the preflight (no python3)"
  skip "skip: the implementer ran this time (no python3)"
fi

# ---------------------------------------------------------------------------
echo "== the wall draws the burnout where it happened =="
# ---------------------------------------------------------------------------
WALLREPORT="$ROOT/wall.json"
node -e '
  const server = require(process.argv[1]);
  const floor = server.floorOf("done: dirty_worktree_failed", "done");
  process.stdout.write(JSON.stringify({
    state: server.stateOf("done: dirty_worktree_failed"),
    floor,
    floorName: server.FLOORS[floor],
    roof: server.FLOORS[server.FLOORS.length - 1],
  }));
' "$SRC/wall/server.js" > "$WALLREPORT" 2>"$ROOT/wall.err"
if [ -s "$WALLREPORT" ]; then
  check "wall: dirty_worktree_failed is a failed run" "$(jq -r .state "$WALLREPORT")" "failed"
  check "wall: it parks on the IMPLEMENT floor, not the roof" "$(jq -r .floor "$WALLREPORT")" "1"
  check "wall: that rung is named IMPLEMENT" "$(jq -r .floorName "$WALLREPORT")" "IMPLEMENT"
  check "wall: and the roof is still PUSH" "$(jq -r .roof "$WALLREPORT")" "PUSH"
else
  bad "wall: server.js loads and answers ($(tr "\n" " " < "$ROOT/wall.err"))"
fi

echo
printf 'failfast guards: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
