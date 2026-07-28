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
run_codex() {  # $1 = label, $2 = prompt
  with_timeout "$CODEX_TIMEOUT" \
    "$CODEX_BIN" exec -C "$WORKTREE" -s workspace-write \
    -c "sandbox_workspace_write.writable_roots=[\"$GIT_COMMON\"]" \
    -c 'model_reasoning_effort="high"' \
    "$2" </dev/null 2>&1 \
    | tee "$RUN_DIR/codex-$1.log" \
    | while IFS= read -r l; do
        [ -n "$l" ] && printf '%.100s\n' "$l" > "$RUN_DIR/activity"
      done
  return "${PIPESTATUS[0]}"
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
  if [ "$CODEX_AVAILABLE" = 1 ]; then run_codex "$1" "$2"; else run_claude_worker "$1" "$2"; fi
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
