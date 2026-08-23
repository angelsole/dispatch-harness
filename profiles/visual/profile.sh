# shellcheck shell=bash
# The visual profile: the pipeline, for work that is judged by eye.
#
# It fills five of the six hooks in lib/profile.sh with one stage — render the
# app, measure the frames, ask a blind critic whether this beats the reigning
# champion — plus the asset factories the implementer draws with. The stage
# itself is creative/visual-gate.sh; everything here is how it reaches the run.
#
# Sourced into run-task.sh's shell by harness_load_profiles, so it reads REPO,
# WORKTREE, RUN_DIR, TICKET and MCP_CONFIG, and calls stage(), run_fix_round()
# and gate_write_latest() directly.
#
# The VISUAL_* state below is this profile's half of the run's own variables,
# and shellcheck cannot see run-task.sh reading it from here.
# shellcheck disable=SC2034

# The standing verdict, in the same shape and at the same scope as the test
# gate's, because it is the same kind of fact: not_run (the stage never
# happened, or the machine could not render) | skip (nothing in the diff can
# have changed the picture) | pass | fail. The pairwise verdict and the critic's
# worst axis travel with it — they are what a human reads first.
VISUAL_STATUS="not_run"; VISUAL_ROUNDS=0; VISUAL_PAIRWISE=""; VISUAL_WORST_AXIS=""
VISUAL_FAILED_STEP=""
# Why the verdict is not a verdict. Only ever set for skip and not_run, and the
# thing that tells "the stage never happened" from "the stage could not run".
VISUAL_REASON=""; VISUAL_REMEDY=""

# The shipped gate's exit code for an environment that cannot render, such as a
# missing browser. Distinct from a failing render, because no fix round can
# install Chromium.
VISUAL_RC_NOT_RUN=3

# A repo that carries .creative/ but pinned no command gets the gate this
# profile ships. The pin stays available for a repo that wants its own.
VISUAL_GATE_CMD="${VISUAL_GATE_CMD:-bash $PROFILE_DIR/creative/visual-gate.sh}"

# Which paths this repo's picture is made of. Activation is repo-level — a repo
# carrying .creative/ gets the profile for every run it dispatches — so without
# this a branch that touched only a shell script would still be rendered and
# graded against the reigning champion, and a critic asked to compare two
# identical pictures answers noise. Git pathspec globs, space-separated, pinned
# per repo through repo_config; the defaults cover where a picture usually
# lives and a repo whose render is elsewhere states so.
DEFAULT_VISUAL_SCOPE_GLOBS="wall/** .creative/** assets/**"
VISUAL_SCOPE_GLOBS="${VISUAL_SCOPE_GLOBS:-$DEFAULT_VISUAL_SCOPE_GLOBS}"

# Bounded exactly like the test gate's fix rounds, and an exhausted budget is a
# terminal status rather than a PR nobody looked at.
DEFAULT_VISUAL_ROUNDS=2
VISUAL_MAX_ROUNDS="${HARNESS_VISUAL_ROUNDS:-$DEFAULT_VISUAL_ROUNDS}"
positive_int "$VISUAL_MAX_ROUNDS" || VISUAL_MAX_ROUNDS=$DEFAULT_VISUAL_ROUNDS

# The asset factories' keys, and nothing else. They live in
# $HARNESS_DIR/factory.conf.sh (mode 600, never in git) and are applied INSIDE
# the implementer's subshell — so the gate, the reviewer, the PR stage and the
# feed never inherit them, and no `env` dump from any other stage can contain
# one. A missing file is a skip, not an error: most repos have no factory.
VISUAL_FACTORY_CONF="$HARNESS_DIR/factory.conf.sh"
visual_implementer_env() {
  [ -n "${MCP_CONFIG:-}" ] || return 0
  [ -f "$VISUAL_FACTORY_CONF" ] || return 0
  set -a
  # shellcheck source=/dev/null  # an operator credential file, outside this repo
  . "$VISUAL_FACTORY_CONF"
  set +a
}
if [ -n "${MCP_CONFIG:-}" ] && [ ! -f "$VISUAL_FACTORY_CONF" ]; then
  echo "[harness] factory keys SKIP — no $VISUAL_FACTORY_CONF"
fi

# Does this branch touch anything the render is made of? Asked of git with the
# globs as pathspecs, so they mean what git means by them rather than what a
# re-implementation in shell would. Every unanswerable case — no merge base, a
# pathspec git rejects, an empty glob list — renders: a round nobody needed
# costs minutes, and a picture nobody looked at is the failure this stage
# exists to prevent.
visual_diff_in_scope() {
  local base out g
  local spec=() globs=()
  [ -n "$VISUAL_SCOPE_GLOBS" ] || return 0
  base=$(git -C "$WORKTREE" merge-base "$BASE_REF" HEAD 2>/dev/null) || return 0
  [ -n "$base" ] || return 0
  # read -ra, not an unquoted expansion: these are git's globs, and the shell
  # would match them against ITS OWN working directory first — the harness
  # checkout, which has a wall/ and a docs/ of its own.
  read -ra globs <<< "$VISUAL_SCOPE_GLOBS"
  for g in "${globs[@]}"; do spec+=(":(glob)$g"); done
  out=$(git -C "$WORKTREE" diff --name-only "$base..HEAD" -- "${spec[@]}" 2>/dev/null) || return 0
  [ -n "$out" ]
}

# Same shape as run_gate, deliberately: same trace prelude, same clipped
# model-facing log, same one-row-per-round ledger in the same format, so
# everything that already reads a gate round reads this one too. What differs is
# what it measures — the picture, not the code — and where the artefacts go:
# frames, a contact sheet and a score file, all inside the worktree's .harness/
# (git-excluded) and harvested into the run dir afterwards, because cleanup.sh
# deletes worktrees and a champion has to outlive the run that earned it.
run_visual_gate() {  # $1 = round
  local rc started secs step script f visual_trace_prelude reported_status
  stage "visual gate #$1 (deterministic + critic)"
  step="$RUN_DIR/visual-$1.step"
  : > "$step"
  # The visual gate writes its own human-readable failing step. The test gate's
  # inherited ERR trap would run afterwards on Bash >= 4 and replace that step
  # with the gate command, so this stage deliberately inherits DEBUG only.
  visual_trace_prelude="trap '$GATE_TRACE_WRITE' DEBUG"
  script="$visual_trace_prelude
$VISUAL_GATE_CMD"
  # Classification must use this invocation's score. A custom gate that writes
  # no score must not inherit a previous round's not_run declaration.
  rm -f "$WORKTREE/.harness/visual-score.json"
  started=$(date +%s)
  (cd "$WORKTREE" && HARNESS_GATE_STEP="$step" HARNESS_DIR="$HARNESS_DIR" \
     VISUAL_ROUND="$1" VISUAL_REPO="$(basename "$REPO")" \
     bash -c "$script") > "$RUN_DIR/visual-$1.log" 2>&1
  rc=$?
  secs=$(( $(date +%s) - started ))
  VISUAL_ROUNDS=$((VISUAL_ROUNDS + 1))
  reported_status=$(jq -r '.status // ""' \
    "$WORKTREE/.harness/visual-score.json" 2>/dev/null || echo "")
  case $rc in
    0) VISUAL_STATUS="pass" ;;
    "$VISUAL_RC_NOT_RUN")
      if [ "$reported_status" = not_run ]; then VISUAL_STATUS="not_run"
      else VISUAL_STATUS="fail"
      fi ;;
    *) VISUAL_STATUS="fail" ;;
  esac
  VISUAL_FAILED_STEP=""
  if [ "$VISUAL_STATUS" != pass ]; then
    VISUAL_FAILED_STEP=$(tr -d '\t' < "$step" 2>/dev/null | head -1)
  fi
  gate_write_latest "$1 (visual)" "$VISUAL_STATUS" "$VISUAL_FAILED_STEP" \
    "$RUN_DIR/visual-$1.log" "$WORKTREE/.harness/visual-latest.log"
  printf '%s %s %s\t%s\n' "$1" "$VISUAL_STATUS" "$secs" "$VISUAL_FAILED_STEP" \
    >> "$RUN_DIR/visual-rounds.log"
  # Replaced wholesale each round: a frame from the round before is not this
  # round's evidence.
  rm -rf "$RUN_DIR/visual"
  mkdir -p "$RUN_DIR/visual"
  [ -d "$WORKTREE/.harness/frames" ] && cp -R "$WORKTREE/.harness/frames" "$RUN_DIR/visual/frames"
  for f in contact-sheet.png visual-score.json visual-checks.json visual-critic.json; do
    [ -f "$WORKTREE/.harness/$f" ] && cp "$WORKTREE/.harness/$f" "$RUN_DIR/visual/$f"
  done
  VISUAL_PAIRWISE=$(jq -r '.pairwise // ""' "$RUN_DIR/visual/visual-score.json" 2>/dev/null || echo "")
  VISUAL_WORST_AXIS=$(jq -r '.worst_axis // ""' "$RUN_DIR/visual/visual-score.json" 2>/dev/null || echo "")
  VISUAL_REASON=""; VISUAL_REMEDY=""
  if [ "$VISUAL_STATUS" = not_run ]; then
    VISUAL_REASON=$(jq -r '.reason // ""' "$RUN_DIR/visual/visual-score.json" 2>/dev/null || echo "")
    VISUAL_REMEDY=$(jq -r '.remedy // ""' "$RUN_DIR/visual/visual-score.json" 2>/dev/null || echo "")
    # Keep a sparse custom not_run score useful without making its reason field
    # mandatory; the status field and exit code are the protocol boundary.
    [ -n "$VISUAL_REASON" ] \
      || VISUAL_REASON="${VISUAL_FAILED_STEP:-the visual gate reported it could not run on this machine (exit $rc)}"
    echo "[harness] visual gate NOT RUN — $VISUAL_REASON${VISUAL_REMEDY:+ (remedy: $VISUAL_REMEDY)}"
  fi
  return $rc
}

# What the fix round is told: the checks that failed and the critic's own words,
# in one place, plus the paths of the artefacts it can open. Never the raw score
# JSON — a model handed a blob re-derives the summary the harness already has.
visual_fix_prompt() {
  local score="$WORKTREE/.harness/visual-score.json" reasons pairwise one_fix worst
  reasons=$(jq -r '.failures[]? | "- " + .' "$score" 2>/dev/null | head -20)
  [ -n "$reasons" ] || reasons="- see .harness/visual-latest.log — the gate failed before it could name a reason"
  pairwise=$(jq -r '.pairwise // "none"' "$score" 2>/dev/null || echo none)
  worst=$(jq -r '.worst_axis // ""' "$score" 2>/dev/null || echo "")
  one_fix=$(jq -r '.one_fix // ""' "$score" 2>/dev/null || echo "")
  printf '%s\n' "The visual gate is failing on this branch. It renders fixed shots of the running app, measures them, and asks a fresh critic to grade them against the reigning champion; it is the check this work is actually judged by, and it does not care that the test gate is green.

What failed:
$reasons

Critic: worst axis ${worst:-none named}; pairwise against the champion: $pairwise.${one_fix:+
The one fix it named: $one_fix}

LOOK at the evidence before you change anything:
- .harness/contact-sheet.png — every rendered frame on one sheet (Read it)
- .harness/frames/ — the frames themselves
- .harness/champion/ — the reigning champion's frames, when there is one
- .harness/visual-latest.log — this round's gate output
- .harness/visual-score.json — every measured number
The pipeline will re-render after your commit. If your sandbox permits a browser, you may also use shot-scraper while you work.

Fix the RENDER. Camera, light, contrast, composition and motion timing before adding more objects — density is what a flat scene already has too much of. Do NOT touch .creative/visual.conf.sh thresholds, the rubric, or the reference board to make the gate pass: moving the bar is the visual form of deleting a test, and the reviewer is told to look for exactly that. Commit your changes (no AI attribution; never commit anything under .harness/). If the gate cannot be satisfied without breaking .harness/brief.md, write .harness/REJECTED.md instead."
}

# --- the hooks ----------------------------------------------------------------

# Between the test gate and the review, because it answers a question neither of
# them asks: does the thing LOOK right?
visual_post_gate() {
  local n=1
  if ! visual_diff_in_scope; then
    VISUAL_STATUS="skip"
    VISUAL_REASON="no file this branch changes is in the visual scope ($VISUAL_SCOPE_GLOBS)"
    stage "visual gate skipped — nothing in this diff can change the picture"
    echo "[harness] visual gate SKIP — $VISUAL_REASON"
    return 0
  fi
  until run_visual_gate "$n"; do
    # The machine could not render. Nothing was judged, so there is nothing to
    # fix and nothing to re-check: the run carries on and says why.
    [ "$VISUAL_STATUS" = fail ] || return 0
    [ "$n" -lt "$VISUAL_MAX_ROUNDS" ] || break
    if [ "$REVIEW_AGENT" = codex ]; then
      stage "visual fix round $n — Codex (ChatGPT sub)"
    else
      stage "visual fix round $n — Claude worker (Claude sub)"
    fi
    run_fix_round "visual-$n" "$(visual_fix_prompt)" || true
    n=$((n + 1))
  done
  return 0
}

# What the reviewer is told about the render, and only when there is one. The
# reviewer CANNOT take its own screenshot — Chromium dies in the Codex sandbox
# on a Mach-port denial that no setting reaches — so it is handed the PNGs the
# gate already made and told plainly that this is the only way it will see them.
visual_review_prompt_extra() {
  # Only a round that rendered has anything to hand over. A skip or a not_run
  # would otherwise point the reviewer at PNGs that do not exist.
  case "$VISUAL_STATUS" in pass|fail) ;; *) return 0 ;; esac
  printf '%s\n' "The visual gate also ran on this branch (status: $VISUAL_STATUS, pairwise against the reigning champion: ${VISUAL_PAIRWISE:-none}). Its evidence is inside .harness/ too: contact-sheet.png (every rendered frame on one sheet), frames/, champion/ when a champion exists, visual-score.json (the measured checks and the critic's verdict) and visual-latest.log. Read the sheet — you cannot render this yourself, so those PNGs are the only look at it you get. Judge them as part of the diff: a change that made the picture worse is a defect however green the tests are, and a diff that moved a threshold in .creative/visual.conf.sh, the rubric or the reference board to make the gate pass is gate-gaming under checklist item 1."
}

# The render, in the PR — because a visual change reviewed as a diff is the
# whole failure this stage exists to end, and the PR is where a human finally
# looks. The sheet rides the demo recording's own route (rclone to R2, public
# URL in the body) when demo.conf.sh configures one; with no remote there is
# nothing to embed and the paths are stated instead.
visual_pr_body_sections() {
  local score="$RUN_DIR/visual/visual-score.json" sheet="$RUN_DIR/visual/contact-sheet.png" url=""
  # A stage that could not run is worth four lines in the PR: the alternative is
  # a merged render nobody judged and no trace anywhere that nobody did.
  if [ "$VISUAL_STATUS" = not_run ] && [ -n "$VISUAL_REASON" ]; then
    echo
    echo "## Visual gate"
    echo
    printf -- '- **not run** — %s\n' "$VISUAL_REASON"
    [ -z "$VISUAL_REMEDY" ] || printf -- '- remedy: `%s`\n' "$VISUAL_REMEDY"
    return 0
  fi
  case "$VISUAL_STATUS" in pass|fail) ;; *) return 0 ;; esac
  [ -f "$score" ] || return 0
  # shellcheck source=/dev/null
  . "$HARNESS_DIR/demo.conf.sh" 2>/dev/null || true
  if [ -f "$sheet" ] && [ -n "${R2_REMOTE:-}" ] \
     && rclone listremotes 2>/dev/null | grep -q "^${R2_REMOTE%%:*}:"; then
    rclone copyto "$sheet" "$R2_REMOTE/$TICKET/contact-sheet.png" --s3-no-check-bucket \
      >> "$RUN_DIR/visual-upload.log" 2>&1 && url="${R2_PUBLIC:-}/$TICKET/contact-sheet.png"
  fi
  echo
  echo "## Visual gate"
  echo
  jq -r '"- verdict: **\(.status)** after \(.round) round(s), \(.champion_shots) champion shot(s)",
         "- pairwise vs champion: **\(.pairwise)**" + (if .worst_axis == "" then "" else "  · worst axis: \(.worst_axis)" end),
         (if (.critic.axes // null) then "- critic axes: " + ([.critic.axes | to_entries[] | "\(.key) \(.value)/5"] | join(" · ")) else empty end),
         (if (.one_fix // "") == "" then empty else "- the critic'"'"'s one fix: \(.one_fix)" end),
         (if ((.advisory // []) | length) == 0 then empty else "- advisory (decides nothing):\n" + ([.advisory[] | "  - " + .] | join("\n")) end),
         (if (.failures | length) == 0 then empty else "- failures:\n" + ([.failures[] | "  - " + .] | join("\n")) end)' \
    "$score" 2>/dev/null
  echo
  if [ -n "$url" ]; then
    printf '![Visual gate contact sheet](%s)\n' "$url"
  else
    printf 'Contact sheet, frames and score: `%s/` on the machine that ran this (no R2 remote configured, so nothing was uploaded).\n' \
      "$RUN_DIR/visual"
  fi
}

# A repo with no visual gate emits nothing here, so its result.json is
# byte-for-byte the one this pipeline has always written. A stage that never
# happened emits nothing either — only a stage that ran, or ran into something,
# has a fact to state.
visual_result_json_extra() {
  case "$VISUAL_STATUS" in
    skip)
      jq -n --arg reason "$VISUAL_REASON" '{visual: {status:"skip", reason:$reason}}' ;;
    not_run)
      [ -n "$VISUAL_REASON" ] || return 0
      jq -n --argjson rounds "$VISUAL_ROUNDS" --arg reason "$VISUAL_REASON" \
        --arg remedy "$VISUAL_REMEDY" \
        '{visual: {status:"not_run", rounds:$rounds, reason:$reason, remedy:$remedy}}' ;;
    *)
      jq -n --arg status "$VISUAL_STATUS" --argjson rounds "$VISUAL_ROUNDS" \
        --arg pairwise "$VISUAL_PAIRWISE" --arg worst "$VISUAL_WORST_AXIS" \
        --arg path "$RUN_DIR/visual/visual-score.json" \
        '{visual: {status:$status, rounds:$rounds, pairwise:$pairwise,
                   worst_axis:$worst, score_path:$path}}' ;;
  esac
}

# The tests pass and the picture does not. This is the outcome the visual gate
# exists to produce: a run that stops instead of opening a PR whose diff reads
# fine and whose render was rejected by eye the moment a human saw it.
visual_outcome_status() {
  [ "$VISUAL_STATUS" = fail ] || return 1
  STATUS="visual_failed"
}
