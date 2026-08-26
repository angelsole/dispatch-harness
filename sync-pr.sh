#!/usr/bin/env bash
# Post-PR base sync: re-merge the latest base into a run's already-pushed PR
# branch when GitHub marks it CONFLICTING (base moved after the PR opened).
# Same recipe as run-task.sh section 5c: script merge -> Codex on conflict, or a
# Claude worker when the codex CLI is not installed (package-lock regeneration
# rules included) -> re-gate -> push.
#
# Usage: sync-pr.sh <RUN-ID>
# Reads ~/.claude/harness/runs/<RUN-ID>/result.json for worktree/branch/base;
# recreates the worktree from origin if it was cleaned up.
set -u -o pipefail

# The shared helpers, read from beside this script — the checkout when it runs
# from there, HARNESS_DIR once install.sh has shipped lib/ into it. Sourced out
# here rather than inside main() so it is read at parse time, like run-task.sh.
_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# Captured BEFORE common.sh defaults it, exactly as run-task.sh does: a
# caller-supplied HARNESS_DIR means a fixture. Three suites — codex-fallback,
# implementer-provider and review-truth — run this script in the FOREGROUND with
# HARNESS_DIR pointed at a temp tree and assert on its exit status and its log.
# gate.sh pins HARNESS_DETACH=0 for the suites it runs, so CI was never wrong;
# a suite run by hand had no such cover, and would have asserted against the
# instant 0 of the launcher half while the real work happened elsewhere.
_INSTALL_DIR_FROM_ENV="${HARNESS_DIR:-}"
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
# shellcheck source=lib/deps-cache.sh
. "$(dirname "$_COMMON_LIB_PATH")/deps-cache.sh"
unset _COMMON_LIB_PATH

main() {

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
harness_codex_preamble   # CODEX_BIN CODEX_AVAILABLE CONFLICT_AGENT CONFLICT_MODEL

[ $# -eq 1 ] || { echo "usage: sync-pr.sh <RUN-ID>" >&2; exit 2; }
TICKET="$1"
RUN_DIR="$HARNESS_DIR/runs/$TICKET"
RESULT="$RUN_DIR/result.json"
[ -f "$RESULT" ] || { echo "FATAL: no result.json at $RESULT" >&2; exit 1; }

# --- Guard: a run that is already being synced --------------------------------
# Same reason as run-task.sh's: detaching makes the launcher return instantly,
# so firing the same sync twice is easy, and two syncs on one run would fight
# over the worktree, the branch and the status file.
_LIVE_PID=$(cat "$RUN_DIR/driver.pid" 2>/dev/null) || _LIVE_PID=""
case "$_LIVE_PID" in ''|*[!0-9]*) _LIVE_PID="" ;; esac
if [ -n "$_LIVE_PID" ] && [ "$_LIVE_PID" != "$$" ] && kill -0 "$_LIVE_PID" 2>/dev/null \
   && ps -o command= -p "$_LIVE_PID" 2>/dev/null \
      | grep -q "\(run-task\|sync-pr\)\.sh $TICKET\([[:space:]]\|\$\)"; then
  echo "[sync-pr] $TICKET already has a live driver (pid $_LIVE_PID) — not starting a second one"
  echo "[sync-pr]   watch it   $HARNESS_DIR/status.sh $TICKET"
  exit 0
fi
unset _LIVE_PID

# --- Detach: same contract as run-task.sh, for the same reason -----------------
# A sync launched as an orchestrator background task shares that shell's process
# group; stopping the task would kill the merge, the resolver and the gate
# mid-flight with nothing recorded. Take a session of our own first.
# HARNESS_DETACH=0 for the test suites, which assert on the foreground exit code,
# and a caller-supplied HARNESS_DIR suppresses it on its own — see above.
: "${DISPATCH_DETACHED=}"   # internal: set by the re-exec below, never by a user
if [ "${HARNESS_DETACH:-1}" = 1 ] && [ -z "$DISPATCH_DETACHED" ] \
   && [ -n "$_INSTALL_DIR_FROM_ENV" ] && [ -z "${HARNESS_DETACH:-}" ]; then
  echo "[sync-pr] HARNESS_DIR came from the environment — treating this as a fixture and NOT detaching (HARNESS_DETACH=1 forces it, =0 silences this)" >&2
fi
if [ "${HARNESS_DETACH:-1}" = 1 ] && [ -z "$DISPATCH_DETACHED" ] \
   && { [ -z "$_INSTALL_DIR_FROM_ENV" ] || [ "${HARNESS_DETACH:-}" = 1 ]; }; then
  SELF_PATH="$(cd "$(dirname "$0")" && pwd)/${0##*/}"
  echo "[sync-pr] syncing $TICKET — detached, this shell no longer owns it"
  echo "[sync-pr]   stages   $HARNESS_DIR/status.sh $TICKET"
  echo "[sync-pr]   driver   tail -f $RUN_DIR/dispatch.log"
  DISPATCH_DETACHED=1 nohup /usr/bin/perl -MPOSIX -e \
      'exit 0 if fork; POSIX::setsid(); exec @ARGV or die "exec: $!\n"' \
      "${BASH:-/bin/bash}" "$SELF_PATH" "$TICKET" \
      >> "$RUN_DIR/dispatch.log" 2>&1 &
  exit 0
fi

# Liveness, shared with run-task.sh: driver.pid + heartbeat feed run_alive
# (lib/common.sh), so status.sh can tell a slow gate from a dead sync.
DRIVER_PID_FILE="$RUN_DIR/driver.pid"
printf '%s\n' "$$" > "$DRIVER_PID_FILE"
touch "$RUN_DIR/heartbeat"
_DRIVER_PID=$$
# stdout and stderr go to /dev/null, and that is load-bearing rather than tidy:
# the ticker inherits whatever the driver was launched with, and nothing waits
# for it any more (waiting cost the exit path a whole sleep interval). In the
# foreground arm every test suite uses, the driver's stdout is a PIPE the gate
# is reading — so a ticker still holding it would keep that pipe open, and the
# gate would block on EOF for up to one interval after the run had finished.
( trap 'exit 0' TERM INT
  while kill -0 "$_DRIVER_PID" 2>/dev/null; do
    sleep "${HARNESS_HEARTBEAT_SECS:-20}"
    touch "$RUN_DIR/heartbeat" 2>/dev/null || exit 0
  done ) >/dev/null 2>&1 &
HEARTBEAT_PID=$!

WORKTREE=$(jq -r .worktree "$RESULT")
BRANCH=$(jq -r .branch "$RESULT")
TICKET_LC=$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')
REPO="${WORKTREE%-$TICKET_LC}"
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { echo "FATAL: cannot derive repo from $WORKTREE" >&2; exit 1; }

# shellcheck source=repos.conf.sh
. "$HARNESS_DIR/repos.conf.sh"
AMBIENT_IMPLEMENTER_PROVIDER="${IMPLEMENTER_PROVIDER:-}"
AMBIENT_IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-}"
repo_config "$REPO"   # sets BASE_BRANCH INSTALL_CMD GATE_CMD ENV_SUBDIRS ...
[ -n "${IMPLEMENTER_PROVIDER:-}" ] || IMPLEMENTER_PROVIDER="$AMBIENT_IMPLEMENTER_PROVIDER"
[ -n "${IMPLEMENTER_MODEL:-}" ] || IMPLEMENTER_MODEL="$AMBIENT_IMPLEMENTER_MODEL"
BASE_REF="origin/$BASE_BRANCH"

# This script writes the same status/timeline/activity files a run does, so a
# wall on another machine should follow it too (HARNESS_MIRROR). Identical
# contract to run-task.sh: best-effort, one last pass on exit, no loop left
# behind — including the fail() path below, which exits 1.
if [ -n "${HARNESS_MIRROR:-}" ] && [ -r "$HARNESS_DIR/mirror.sh" ]; then
  # shellcheck source=mirror.sh
  . "$HARNESS_DIR/mirror.sh"
  mirror_start "$RUN_DIR" "$TICKET"
fi

. "$HARNESS_DIR/notify.conf" 2>/dev/null || true
stage() {
  echo "$(date +%s) $1" > "$RUN_DIR/status"
  echo "$(date '+%H:%M:%S') $1" >> "$RUN_DIR/timeline"
  echo "$1" > "$RUN_DIR/activity"
  echo "[sync-pr] $1"
  if [ "${HARNESS_NOTIFY:-1}" = "1" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"sync-pr $TICKET\"" 2>/dev/null || true
  fi
}
fail() { stage "sync failed: $1"; TERMINAL_WRITTEN=1; exit 1; }

# --- No sync may end without a word --------------------------------------------
# Same backstop as run-task.sh's death traps: a killed sync used to leave the
# status file frozen mid-stage with no record that anything died. `sync failed:`
# is already a stage-vocab row, so no table changes anywhere.
TERMINAL_WRITTEN=0
# $2 is the exit status, passed in rather than read from $?: sync_on_exit has
# already run commands of its own by the time this is called, so `local rc=$?`
# read THEIR status and every death was recorded as "driver exited 0 mid-stage"
# — a number a human then reads off the wall, because this one goes into the
# stage text and not just a file.
sync_record_death() {  # $1 = signal name, or "" for a bare exit; $2 = rc
  local sig="${1:-}" rc="${2:-0}" why
  [ "${TERMINAL_WRITTEN:-0}" = 0 ] || return 0
  if [ -n "$sig" ]; then why="driver killed (SIG$sig)"
  else why="driver exited $rc mid-stage"; fi
  printf '%s %s %s\n' "$(date +%s)" "${sig:-EXIT}" "$why" > "$RUN_DIR/died" 2>/dev/null || true
  TERMINAL_WRITTEN=1
  stage "sync failed: $why — re-run sync-pr.sh to resume"
  return 0
}
# Same two-signal teardown as run-task.sh's, for the same two reasons: `kill`
# alone is deferred until the ticker's sleep returns (so a plain wait costs the
# exit path a whole interval, and everything below it), and no wait at all
# leaves a fork of this script alive carrying its argv.
sync_stop_heartbeat() {
  [ -n "${HEARTBEAT_PID:-}" ] || return 0
  pkill -P "$HEARTBEAT_PID" 2>/dev/null || true
  kill -9 "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}
sync_on_exit() {
  local rc=$?
  sync_record_death "" "$rc" || true
  harness_gate_lock_release "${GATE_LOCK_KEY:-}" 2>/dev/null || true
  rm -f "${DRIVER_PID_FILE:-/dev/null}" 2>/dev/null || true
  rm -f "$RUN_DIR/heartbeat" 2>/dev/null || true
  sync_stop_heartbeat
  if declare -F mirror_stop >/dev/null 2>&1; then mirror_stop >/dev/null 2>&1 || true; fi
  return "$rc"
}
trap 'sync_record_death TERM 143; exit 143' TERM
trap 'sync_record_death INT  130; exit 130' INT
trap 'sync_record_death HUP  129; exit 129' HUP
trap sync_on_exit EXIT

# --- 1. Worktree (recreate from origin if cleaned up) -------------------------
git -C "$REPO" fetch origin --quiet || fail "git fetch failed"
git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$BRANCH" \
  || fail "origin/$BRANCH not found (PR branch gone?)"
if [ -d "$WORKTREE" ]; then
  [ -z "$(git -C "$WORKTREE" status --porcelain)" ] \
    || fail "worktree $WORKTREE has uncommitted changes — resolve manually"
elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" worktree add "$WORKTREE" "$BRANCH" || fail "worktree add failed"
  git -C "$WORKTREE" reset --hard "origin/$BRANCH" --quiet
else
  git -C "$REPO" worktree add "$WORKTREE" -b "$BRANCH" "origin/$BRANCH" || fail "worktree add failed"
fi
# Branch tip must match origin — this script syncs published PRs only.
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" ] \
  || fail "local $BRANCH differs from origin/$BRANCH — push or reset first"

# Nothing to do?
if git -C "$WORKTREE" merge-base --is-ancestor "$BASE_REF" HEAD 2>/dev/null; then
  stage "already up to date with $BASE_REF — nothing to sync"
  TERMINAL_WRITTEN=1
  exit 0
fi

# Context for the conflict resolver + env files + deps (worktree may be freshly recreated).
mkdir -p "$WORKTREE/.harness"
[ -f "$RUN_DIR/brief.md" ] && cp "$RUN_DIR/brief.md" "$WORKTREE/.harness/brief.md"
[ -f "$RUN_DIR/review-notes.md" ] && cp "$RUN_DIR/review-notes.md" "$WORKTREE/.harness/review-notes.md"
EXCLUDE_FILE="$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qx '.harness/' "$EXCLUDE_FILE" 2>/dev/null || echo '.harness/' >> "$EXCLUDE_FILE"
for d in "." ${ENV_SUBDIRS:-}; do
  find "$REPO/$d" -maxdepth 1 -name ".env*" -type f 2>/dev/null | while read -r f; do
    cp -n "$f" "$WORKTREE/$d/" 2>/dev/null || true
  done
done
if [ -n "$INSTALL_CMD" ] && [ ! -d "$WORKTREE/node_modules" ]; then
  stage "installing deps"
  # Same cache as run-task.sh's install step: a recreated worktree whose
  # lockfile an earlier run already installed clones its node_modules back in
  # seconds. Restore-only here — the base merge below may change the lockfile,
  # so this tree is not worth storing; the miss path is the untouched original.
  DEPS_KEY=""
  if [ "${HARNESS_DEPS_CACHE:-1}" = "1" ] \
     && deps_cache_covered "$INSTALL_CMD" "${DEPS_CACHE_POST_CMD:-}"; then
    DEPS_KEY="$(deps_cache_key "$WORKTREE" "$INSTALL_CMD")" || DEPS_KEY=""
  fi
  if [ -n "$DEPS_KEY" ] && deps_cache_restore "$(basename "$REPO")" "$DEPS_KEY" "$WORKTREE"; then
    echo "[harness] deps: cache hit ($DEPS_KEY) — node_modules cloned, install skipped" \
      | tee "$RUN_DIR/sync-install.log"
    if [ -n "${DEPS_CACHE_POST_CMD:-}" ]; then
      (cd "$WORKTREE" && bash -c "$DEPS_CACHE_POST_CMD") >> "$RUN_DIR/sync-install.log" 2>&1 \
        || fail "DEPS_CACHE_POST_CMD failed (see $RUN_DIR/sync-install.log)"
    fi
  else
    (cd "$WORKTREE" && bash -c "$INSTALL_CMD") > "$RUN_DIR/sync-install.log" 2>&1 \
      || fail "install failed (see $RUN_DIR/sync-install.log)"
  fi
fi

GATE_STATUS="not_run"
run_gate() {
  # Same per-repo gate lock as run-task.sh, same reason: this repo's worktrees
  # share one local test database, and a sync gating beside a run's gate
  # produced deadlocks and phantom failures.
  GATE_LOCK_KEY=$(harness_gate_lock_key "$REPO")
  _GATE_LOCK_ROUND="$1"
  if ! harness_gate_lock_acquire "$GATE_LOCK_KEY" "$TICKET" sync_gate_lock_waiting; then
    [ "${HARNESS_GATE_LOCK:-1}" = 0 ] \
      || echo "[sync-pr] gate lock unavailable after ${HARNESS_GATE_LOCK_WAIT}s — gating unserialized"
    GATE_LOCK_KEY=""
  fi
  stage "test gate ($1) — deterministic, no model"
  (cd "$WORKTREE" && bash -c "$GATE_CMD") > "$RUN_DIR/gate-$1.log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then GATE_STATUS="pass"; else GATE_STATUS="fail"; fi
  harness_gate_lock_release "$GATE_LOCK_KEY"
  GATE_LOCK_KEY=""
  return $rc
}
_GATE_LOCK_ROUND=""
sync_gate_lock_waiting() {  # $1 = the holder's run id
  stage "test gate (${_GATE_LOCK_ROUND}) (waiting for gate lock — $1 is testing this repo)"
}

GIT_COMMON=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)
CODEX_TIMEOUT="${CODEX_TIMEOUT:-3600}"

CODEX_WRITABLE_ROOTS=("$GIT_COMMON")
codex_writable_roots_json() {
  local out="" r
  for r in "${CODEX_WRITABLE_ROOTS[@]}"; do out="$out,\"$r\""; done
  printf '[%s]' "${out#,}"
}

# Same network posture as run-task.sh's run_codex, and mirrored for the same
# reason: this resolver is told to re-run the tests relevant to the conflicted
# files, and the workspace-write sandbox denies loopback along with the network.
# The narrow capability, not the blunt one — features.network_proxy plus a
# permission profile that allows exactly localhost / 127.0.0.1 / ::1, inside a
# harness-owned CODEX_HOME so the resolver inherits none of the operator's
# rules, plugins or MCP servers (a developer's rules file typically allows
# `git push` and `gh`). It fails closed: nothing here sets network_access, so a
# CLI that ignores the profile leaves today's sandbox. HARNESS_REVIEW_NETWORK=0
# leaves command line and environment byte-for-byte what they were.
REVIEW_NETWORK="${HARNESS_REVIEW_NETWORK:-1}"

reconcile_review_auth() {  # $1 = account CODEX_HOME, $2 = isolated run home
  local home="$2"
  if [ -f "$home/auth.json" ] && [ ! -L "$home/auth.json" ]; then
    mv -f "$home/auth.json" "$1/auth.json" 2>/dev/null || return 1
    ln -sfn ../../auth.json "$home/auth.json" 2>/dev/null || return 1
  fi
}

review_home() {  # $1 = the account's CODEX_HOME -> echoes the isolated home
  # Runs are independent worktrees and may resolve concurrently. A per-run
  # directory prevents either resolver from replacing the other's root policy.
  local base="$1" home="$1/harness-review/$TICKET_LC" r
  [ -n "$base" ] || return 1
  mkdir -p "$home" 2>/dev/null || return 1
  reconcile_review_auth "$base" "$home" || return 1
  [ -e "$base/auth.json" ] && { ln -sfn ../../auth.json "$home/auth.json" || return 1; }
  {
    echo "# Written by dispatch-harness sync-pr.sh before every codex attempt."
    echo "# This directory is the resolver's entire CODEX_HOME: whatever is not"
    echo "# here — rules, plugins, MCP servers — is not available to it."
    echo
    echo "features.network_proxy.enabled = true"
    echo 'default_permissions = "harness-review"'
    echo
    echo '[permissions.harness-review]'
    echo 'description = "dispatch-harness review: workspace writes, loopback only"'
    echo 'extends = ":workspace"'
    echo
    echo "# The same roots as the legacy workspace-write flags used when this"
    echo "# feature is disabled. The profile is authoritative in the enabled arm"
    echo "# because an explicit -s workspace-write would override it."
    echo '[permissions.harness-review.filesystem]'
    for r in "${CODEX_WRITABLE_ROOTS[@]}"; do printf '"%s" = "write"\n' "$r"; done
    echo
    echo '[permissions.harness-review.network]'
    echo 'enabled = true'
    echo '# "limited" names the restricted mode explicitly, so no change to what'
    echo '# the CLI defaults to can quietly promote this to "full".'
    echo 'mode = "limited"'
    echo '# Required for loopback even though the three literals below are'
    echo '# allowed: allowlisting a local target is not sufficient on its own'
    echo '# (openai/codex#33227), and a test runner has to BIND a loopback'
    echo '# socket rather than merely reach one. It widens the sandbox to local'
    echo '# and private ranges and no further — the domain map below still'
    echo '# denies every public destination.'
    echo 'allow_local_binding = true'
    echo
    echo '[permissions.harness-review.network.domains]'
    echo '"localhost" = "allow"'
    echo '"127.0.0.1" = "allow"'
    echo '"::1" = "allow"'
    echo '# No "*" entry: an absent allow rule already denies, and the global'
    echo '# wildcard is rejected unless allowlist compilation is opened up.'
  } > "$home/config.toml" 2>/dev/null || return 1
  printf '%s\n' "$home"
}

# Same two-account rule as run-task.sh's run_codex, for the same reason: a
# primary workspace that is out of credits resolves nothing, and codex auth is
# CODEX_HOME-scoped, so a second account is a directory. One attempt, one
# account; the switch is sticky and only moves the NEXT attempt.
CODEX_HOME_FALLBACK="${HARNESS_CODEX_HOME_FALLBACK:-}"
CODEX_HOME_PRIMARY="${CODEX_HOME:-$HOME/.codex}"
CODEX_ACCOUNT="primary"   # primary | fallback — a label, never a path
CODEX_START_FAILED=0      # the isolated home could not be built; codex did not run
codex_out_of_credits() {  # $1 = an attempt's log
  [ -f "$1" ] || return 1
  tr -s '[:space:]' ' ' < "$1" | grep -qiE 'out of credits'
}

run_codex() {  # $1 = label, $2 = prompt
  local log="$RUN_DIR/codex-$1.log" rc
  # env(1) goes after with_timeout, which is a shell function env cannot exec.
  local home=() sandbox=(-s workspace-write \
    -c "sandbox_workspace_write.writable_roots=$(codex_writable_roots_json)")
  local acct_home rhome=""
  CODEX_START_FAILED=0
  acct_home="$CODEX_HOME_PRIMARY"
  [ "$CODEX_ACCOUNT" = fallback ] && acct_home="$CODEX_HOME_FALLBACK"
  if [ "$REVIEW_NETWORK" != 0 ]; then
    if rhome=$(review_home "$acct_home"); then
      home=(env "CODEX_HOME=$rhome")
      # An explicit -s wins over default_permissions in codex 0.145. Omit the
      # legacy sandbox only when the isolated permission profile was built.
      sandbox=()
    else
      # Network and isolation are one capability. Never recover from a failed
      # isolated-home build by starting codex on the operator's ambient config.
      CODEX_START_FAILED=1
    fi
  elif [ "$CODEX_ACCOUNT" = fallback ]; then
    home=(env "CODEX_HOME=$CODEX_HOME_FALLBACK")
  fi
  printf 'codex account: %s\n' "$CODEX_ACCOUNT" > "$log"   # the label, nothing more
  if [ "$CODEX_START_FAILED" = 1 ]; then
    echo "[sync-pr] resolver isolation setup failed — codex attempt not started" \
      | tee -a "$log"
    return 1
  fi
  with_timeout "$CODEX_TIMEOUT" \
    ${home[@]+"${home[@]}"} \
    "$CODEX_BIN" exec -C "$WORKTREE" \
    ${sandbox[@]+"${sandbox[@]}"} \
    -c 'model_reasoning_effort="high"' \
    "$2" </dev/null 2>&1 \
    | tee -a "$log" \
    | while IFS= read -r l; do
        [ -n "$l" ] && printf '%.100s\n' "$l" > "$RUN_DIR/activity"
      done
  rc="${PIPESTATUS[0]}"
  [ "$REVIEW_NETWORK" != 0 ] && [ -n "$rhome" ] \
    && reconcile_review_auth "$acct_home" "$rhome"
  if [ "$CODEX_ACCOUNT" = primary ] && [ -n "$CODEX_HOME_FALLBACK" ] \
     && codex_out_of_credits "$log"; then
    CODEX_ACCOUNT="fallback"
    echo "[sync-pr] codex hit the workspace-credits error — the fallback account takes the next attempt"
  fi
  return "$rc"
}

# Claude fallback, mirroring run-task.sh: fresh session, ANTHROPIC_API_KEY unset
# (subscription billing), worker permissions, same timeout cap. A sync is a
# resume of an existing run, so its pinned implementer knobs are authoritative:
# the first dispatch froze provider, model and effort, and neither the repo's
# pin nor this shell's environment re-decides them here. The value around each
# knob call covers a run dir that predates the pin files; the defaults are the
# same ones run-task.sh pins with — one definition, in lib/common.sh. A
# cross-vendor implementer's model never leaks into this Anthropic-billed
# fallback.
IMPLEMENTER_PROVIDER="$(harness_knob "$RUN_DIR" implementer-provider "${IMPLEMENTER_PROVIDER:-$DEFAULT_IMPLEMENTER_PROVIDER}")"
IMPLEMENTER_MODEL="$(harness_knob "$RUN_DIR" implementer-model "${IMPLEMENTER_MODEL:-$DEFAULT_IMPLEMENTER_MODEL}")"
IMPLEMENTER_EFFORT="$(harness_knob "$RUN_DIR" implementer-effort "${IMPLEMENTER_EFFORT:-$DEFAULT_IMPLEMENTER_EFFORT}")"
CLAUDE_WORKER_MODEL="$IMPLEMENTER_MODEL"
[ "$IMPLEMENTER_PROVIDER" = anthropic ] || CLAUDE_WORKER_MODEL="$DEFAULT_ANTHROPIC_MODEL"
run_claude_worker() {  # $1 = label, $2 = prompt
  (cd "$WORKTREE" && with_timeout "$CODEX_TIMEOUT" \
      env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN \
          -u API_TIMEOUT_MS -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
          -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
          CLAUDE_CODE_SUBAGENT_MODEL=sonnet \
      "$CLAUDE_BIN" -p "$2" --model "$CLAUDE_WORKER_MODEL" --effort "$IMPLEMENTER_EFFORT" \
      --settings "$HARNESS_DIR/worker-settings.json" --permission-mode acceptEdits \
      </dev/null 2>&1) \
    | tee "$RUN_DIR/claude-$1.log" \
    | while IFS= read -r l; do
        [ -n "$l" ] && printf '%.100s\n' "$l" > "$RUN_DIR/activity"
      done
  return "${PIPESTATUS[0]}"
}

resolve_conflicts() {  # $1 = label, $2 = prompt
  local before
  [ "$CODEX_AVAILABLE" = 1 ] || { run_claude_worker "$1" "$2"; return; }
  before="$CODEX_ACCOUNT"
  run_codex "$1" "$2" || true
  # A primary that answered "out of credits" or could not be started inside the
  # isolated resolver home left the merge stopped. Give the fallback one attempt
  # before we give up.
  if [ "$before" = primary ] && [ -n "$CODEX_HOME_FALLBACK" ] \
     && { [ "$CODEX_ACCOUNT" = fallback ] || [ "$CODEX_START_FAILED" = 1 ]; }; then
    CODEX_ACCOUNT="fallback"
    stage "base sync — conflict resolution ($CONFLICT_AGENT, fallback account)"
    run_codex "$1-fallback" "$2"
  fi
}

# --- 2. Merge latest base; a model only on conflict ----------------------------
rm -f "$WORKTREE/.harness/REJECTED.md"
stage "base sync — merge latest $BASE_BRANCH (script — no model)"
if git -C "$WORKTREE" merge --no-edit "$BASE_REF" > "$RUN_DIR/post-sync.log" 2>&1; then
  run_gate post-sync || true
else
  git -C "$WORKTREE" diff --name-only --diff-filter=U >> "$RUN_DIR/post-sync.log" 2>&1 || true
  stage "base sync — conflict resolution ($CONFLICT_AGENT)"
  resolve_conflicts post-sync "A merge of $BASE_REF into this branch is stopped on conflicts (git status shows them). Newer work already merged to $BASE_BRANCH collided with this branch's changes (this branch's contract: .harness/brief.md). Resolve every conflict by combining BOTH sides' intent — drop neither side's changes. For modify/delete conflicts on files this branch deliberately deleted, keep them deleted. If package-lock.json conflicts, resolve package.json first, then regenerate with 'npm install --package-lock-only' FOLLOWED BY 'npm dedupe --package-lock-only' (regen alone can leave an inconsistent nested tree that breaks npm ci — bit us in production), and verify with a clean 'npm ci'. Then git add the resolved files, conclude the merge commit (git commit --no-verify, plain message like 'Merge latest $BASE_BRANCH', no AI attribution), and re-run the tests relevant to the conflicted files. If the two sides are fundamentally incompatible, run git merge --abort and write .harness/REJECTED.md explaining why." || true
  if [ -f "$WORKTREE/.harness/REJECTED.md" ]; then
    # The Claude worker permission profile may refuse merge --abort. Keep
    # rejection cleanup script-owned so the worktree never remains mid-merge.
    git -C "$WORKTREE" merge --abort > /dev/null 2>&1 || true
    cp "$WORKTREE/.harness/REJECTED.md" "$RUN_DIR/REJECTED.md"
    fail "$CONFLICT_MODEL rejected the merge — see $RUN_DIR/REJECTED.md"
  fi
  if git -C "$WORKTREE" ls-files -u | grep -q . || [ -f "$(git -C "$WORKTREE" rev-parse --git-path MERGE_HEAD)" ]; then
    git -C "$WORKTREE" merge --abort > /dev/null 2>&1 || true
    fail "conflicts unresolved — merge aborted, resolve manually in $WORKTREE"
  fi
  run_gate post-sync || true
fi

[ "$GATE_STATUS" = "pass" ] || fail "gate failed after base sync (see $RUN_DIR/gate-post-sync.log) — NOT pushed"

# --- 3. Push -------------------------------------------------------------------
stage "push (script — no model)"
git -C "$WORKTREE" push origin "$BRANCH" > "$RUN_DIR/sync-push.log" 2>&1 || fail "push failed (see $RUN_DIR/sync-push.log)"
stage "done: PR branch synced with $BASE_BRANCH, gate green, pushed"
TERMINAL_WRITTEN=1
echo "[sync-pr] worktree kept at $WORKTREE — run cleanup.sh $TICKET when the PR merges"
}

main "$@"
