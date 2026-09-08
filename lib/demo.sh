# shellcheck shell=bash
# Optional frontend capture: advisory, saved locally before any upload.
DEMO_ACTIVE=0

demo_capture() {
  if ! grep -qiE '^## Demo storyboard[[:space:]]*$' "$BRIEF" \
     && [ ! -f "$WORKTREE/.harness/demo.json" ] && [ ! -f "$WORKTREE/.harness/demo.yml" ]; then
    return 0
  fi
  DEMO_ACTIVE=1
  stage "demo — recording (script, no model)"
  local auth="${DEMO_AUTH_FILE:-$HARNESS_DIR/auth/$(basename "$REPO").json}"
  env SHOT_BIN="${SHOT_BIN:-$HOME/.local/bin/shot-scraper}" DEMO_PORT="${DEMO_PORT:-}" \
    python3 "$SELF_DIR/lib/demo.py" capture --run "$RUN_DIR" --worktree "$WORKTREE" \
      --attempt "$ATTEMPT" --auth "$auth" >> "$RUN_DIR/demo-driver.log" 2>&1 || {
        jq -n --arg head "$(git -C "$WORKTREE" rev-parse HEAD)" --argjson attempt "$ATTEMPT" \
          '{version:1,head:$head,attempt:$attempt,status:"failed",artifacts:[],reason:"Capture driver failed; see demo-driver.log"}' \
          > "$RUN_DIR/evidence.json"
      }
  stage "demo — $(jq -r '.status' "$RUN_DIR/evidence.json")"
}

demo_pr_section() {
  [ "$DEMO_ACTIVE" = 1 ] || return 0
  python3 "$SELF_DIR/lib/demo.py" section --run "$RUN_DIR" --worktree "$WORKTREE"
}

demo_publish() {
  [ "$DEMO_ACTIVE" = 1 ] || return 0
  # Existing storage settings remain an optional fallback for older gh builds.
  if [ -f "$HARNESS_DIR/demo.conf.sh" ]; then
    # shellcheck disable=SC1091
    . "$HARNESS_DIR/demo.conf.sh"
  fi
  if jq -e '.directory' "$RUN_DIR/evidence.json" >/dev/null; then
    env R2_REMOTE="${R2_REMOTE:-}" R2_PUBLIC="${R2_PUBLIC:-}" \
      python3 "$SELF_DIR/lib/demo.py" publish --run "$RUN_DIR" --worktree "$WORKTREE" \
        --pr "$PR_URL" >> "$RUN_DIR/demo-driver.log" 2>&1 || true
  fi
  # Read by run-task.sh's result and wall consumers.
  # shellcheck disable=SC2034
  DEMO_URL=$(jq -r '[.artifacts[]? | select(.kind == "video") | .url // empty][0] // ""' "$RUN_DIR/evidence.json")
  stage "demo — $(jq -r '.status' "$RUN_DIR/evidence.json")"
}

demo_result_extra() {
  [ "$DEMO_ACTIVE" = 1 ] || return 0
  jq '{evidence:.}' "$RUN_DIR/evidence.json"
}
