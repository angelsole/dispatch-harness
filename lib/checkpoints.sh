# shellcheck shell=bash
# Variables restored here are consumed by run-task.sh.
# shellcheck disable=SC2034
# Checkpoints are optional for legacy callers without Python. Reuse is explicit
# (HARNESS_RESUME=1), and a failed validation always runs the normal pipeline.
checkpoint() {
  command -v python3 >/dev/null 2>&1 || return 1
  jq -n --arg gate "$GATE_CMD" --arg install "$INSTALL_CMD" \
    --arg preflight "${PREFLIGHT_CMD:-}" --arg profiles "${ACTIVE_PROFILES:-}" \
    --arg integrity "${HARNESS_GATE_INTEGRITY:-1}" --arg fallback "${HARNESS_CODEX_HOME_FALLBACK:-}" \
    --arg env_subdirs "${ENV_SUBDIRS:-}" --arg arm "$ARM" \
    --arg provider "$IMPLEMENTER_PROVIDER" --arg model "$IMPLEMENTER_MODEL" \
    --arg effort "$IMPLEMENTER_EFFORT" --arg owner "${HARNESS_OWNER:-}" \
    --arg chome "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --arg ohome "${CODEX_HOME:-$HOME/.codex}" \
    --arg review_model "$(cat "$RUN_DIR/reviewer-model" 2>/dev/null)" \
    --arg review_effort "$(cat "$RUN_DIR/reviewer-effort" 2>/dev/null)" \
    --arg gate_status "$GATE_STATUS" --arg review "$REVIEW_CLASS" \
    --arg review_account "$REVIEW_ACCOUNT" --arg actual_model "$REVIEWER_MODEL" \
    --arg actual_effort "$REVIEWER_EFFORT" --arg opus_head "$OPUS_HEAD" \
    --arg claude_reason "${CLAUDE_TIER_REASON:-}" \
    '{config:{gate:$gate,install:$install,preflight:$preflight,profiles:$profiles,
      integrity:$integrity,fallback:$fallback,env_subdirs:$env_subdirs,arm:$arm,provider:$provider,model:$model,effort:$effort,
      owner:$owner,claude_home:$chome,codex_home:$ohome,review_model:$review_model,review_effort:$review_effort},
      state:{gate:$gate_status,review:$review,review_account:$review_account,
      reviewer_model:$actual_model,reviewer_effort:$actual_effort,opus_head:$opus_head,claude_reason:$claude_reason}}' \
    | python3 "$SELF_DIR/lib/checkpoints.py" "$1" "${2:-}" "$WORKTREE" "$RUN_DIR" "$HARNESS_DIR" "$BASE_REF"
}

checkpoint_restore_review() {
  GATE_STATUS=$(jq -r '.state.gate' "$RUN_DIR/checkpoint.json")
  REVIEW_CLASS=$(jq -r '.state.review' "$RUN_DIR/checkpoint.json")
  REVIEW_ACCOUNT=$(jq -r '.state.review_account' "$RUN_DIR/checkpoint.json")
  REVIEWER_MODEL=$(jq -r '.state.reviewer_model' "$RUN_DIR/checkpoint.json")
  REVIEWER_EFFORT=$(jq -r '.state.reviewer_effort' "$RUN_DIR/checkpoint.json")
  CLAUDE_TIER_REASON=$(jq -r '.state.claude_reason // ""' "$RUN_DIR/checkpoint.json")
  REVIEW_OK=1
}
