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

main() {

HARNESS_DIR="${HARNESS_DIR:-$HOME/.claude/harness}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || echo codex)}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
# The codex CLI is optional; without it a Claude worker resolves the conflicts.
if command -v "$CODEX_BIN" >/dev/null 2>&1; then CODEX_AVAILABLE=1; else CODEX_AVAILABLE=0; fi
CONFLICT_AGENT="Codex, ChatGPT sub"; CONFLICT_MODEL="Codex"
[ "$CODEX_AVAILABLE" = 1 ] || { CONFLICT_AGENT="Claude sub"; CONFLICT_MODEL="Claude"; }

# Cap a long-running child. macOS ships no timeout(1), so fall back to a
# perl alarm wrapper (SIGALRM survives exec and kills the child after N secs).
with_timeout() {  # $1 = seconds, rest = command + args
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

[ $# -eq 1 ] || { echo "usage: sync-pr.sh <RUN-ID>" >&2; exit 2; }
TICKET="$1"
RUN_DIR="$HARNESS_DIR/runs/$TICKET"
RESULT="$RUN_DIR/result.json"
[ -f "$RESULT" ] || { echo "FATAL: no result.json at $RESULT" >&2; exit 1; }

WORKTREE=$(jq -r .worktree "$RESULT")
BRANCH=$(jq -r .branch "$RESULT")
TICKET_LC=$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')
REPO="${WORKTREE%-$TICKET_LC}"
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || { echo "FATAL: cannot derive repo from $WORKTREE" >&2; exit 1; }

# shellcheck source=repos.conf.sh
. "$HARNESS_DIR/repos.conf.sh"
repo_config "$REPO"   # sets BASE_BRANCH INSTALL_CMD GATE_CMD ENV_SUBDIRS ...
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
fail() { stage "sync failed: $1"; exit 1; }

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
  (cd "$WORKTREE" && bash -c "$INSTALL_CMD") > "$RUN_DIR/sync-install.log" 2>&1 \
    || fail "install failed (see $RUN_DIR/sync-install.log)"
fi

GATE_STATUS="not_run"
run_gate() {
  stage "test gate ($1) — deterministic, no model"
  (cd "$WORKTREE" && bash -c "$GATE_CMD") > "$RUN_DIR/gate-$1.log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then GATE_STATUS="pass"; else GATE_STATUS="fail"; fi
  return $rc
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
  reconcile_review_auth "$base" "$home"
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
  acct_home="$CODEX_HOME_PRIMARY"
  [ "$CODEX_ACCOUNT" = fallback ] && acct_home="$CODEX_HOME_FALLBACK"
  if [ "$REVIEW_NETWORK" != 0 ] && rhome=$(review_home "$acct_home"); then
    home=(env "CODEX_HOME=$rhome")
    # An explicit -s wins over default_permissions in codex 0.145. Omit the
    # legacy sandbox only when the isolated permission profile was built.
    sandbox=()
  elif [ "$CODEX_ACCOUNT" = fallback ]; then
    home=(env "CODEX_HOME=$CODEX_HOME_FALLBACK")
  fi
  printf 'codex account: %s\n' "$CODEX_ACCOUNT" > "$log"   # the label, nothing more
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
# (subscription billing), worker permissions, same timeout cap. Model/effort come
# from the run's pinned implementer knobs, with run-task.sh's own defaults.
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-$(cat "$RUN_DIR/implementer-model" 2>/dev/null || echo claude-opus-5)}"
IMPLEMENTER_EFFORT="${IMPLEMENTER_EFFORT:-$(cat "$RUN_DIR/implementer-effort" 2>/dev/null || echo xhigh)}"
run_claude_worker() {  # $1 = label, $2 = prompt
  (cd "$WORKTREE" && with_timeout "$CODEX_TIMEOUT" \
      env -u ANTHROPIC_API_KEY CLAUDE_CODE_SUBAGENT_MODEL=sonnet \
      "$CLAUDE_BIN" -p "$2" --model "$IMPLEMENTER_MODEL" --effort "$IMPLEMENTER_EFFORT" \
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
  # run_codex moves the account only on the workspace-credits error, so this is
  # the credits case and nothing else: the merge is still stopped and the same
  # account cannot help. One more attempt on the fallback before we give up.
  if [ "$before" = primary ] && [ "$CODEX_ACCOUNT" = fallback ]; then
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
echo "[sync-pr] worktree kept at $WORKTREE — run cleanup.sh $TICKET when the PR merges"
}

main "$@"
