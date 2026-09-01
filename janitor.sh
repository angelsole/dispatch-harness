#!/usr/bin/env bash
# The Janitor — the pass that closes the loop cleanup.sh only closes when
# somebody is watching.
#
# cleanup.sh runs when the orchestrator promotes a PR in-session. Every other
# road to a merged PR leaves the run's worktree on disk forever, because nothing
# in the harness ever looks back: a PR merged from the web UI, merged by a
# teammate, promoted in a session that died, or a `push_failed` run whose branch
# shipped anyway. Twenty-two of those worktrees, thirteen gigabytes, was the
# state of the machine this was written for. `flutter test` compounds it — it
# leaves detached `flutter_tester` processes behind, and removing a worktree does
# not kill them. And a run whose process dies without ever writing a terminal
# `done:` status reads as in progress forever, because every surface keys
# liveness on that prefix — a fifty-day ghost was the state of the machine this
# was written for.
#
# >>> --help >>>
# Usage:
#   janitor.sh [--report]        what --clean would do; sweeps and reaps nothing
#   janitor.sh --clean           sweep those worktrees, reap zombies and processes,
#                                evict deps-cache entries unused for 14 days
#   janitor.sh --install [MODE]  daily LaunchAgent (MODE: --report|--clean)
#   janitor.sh --uninstall       remove that agent
#
# <<< --help <<<
# A run is swept only when every one of these holds: its result.json carries a
# pr_url, `gh pr view` says that PR is MERGED, the worktree is still there, and
# `git status --porcelain` in it is empty. Everything else is listed and left —
# an OPEN PR above all, whose worktree is where post-PR review fixes land. A PR
# whose state cannot be read is `unknown`, never "probably merged": a state that
# could not be read is not evidence of anything.
#
# The same poll also writes outcome.json into each run dir with a PR: the state,
# when it merged, how long that took, how many review comments humans left,
# whether base-branch commits later touched the PR's files, and whether anything
# reverted it. That is the only ground-truth label the pipeline ever gets about
# whether a run's PR was good, and it costs the gh call the sweep already makes
# plus at most one more. Refreshing stops once the PR is terminal and the
# outcome is JANITOR_OUTCOME_MAX_AGE days old.
#
# Sweeping is delegated to cleanup.sh, which already knows how to remove a
# worktree, delete the local branch only when it is on origin, and drop a
# mirrored copy. Run logs under runs/<RUN-ID>/ are never deleted: this script
# removes worktrees and processes, and flips stale statuses to terminal —
# nothing else.
#
# A run is a zombie when its status exists and never reached `done:`, no live
# `run-task.sh <id>` / `sync-pr.sh <id>` process serves it, and that status is
# older than JANITOR_ZOMBIE_HOURS (12h). Reaping writes a terminal status only
# — `done: reaped (stale — no live process, was: <the stage it died on>)`, or
# `done: ready (reaped — PR merged)` when the poll above already recorded the
# run's PR as merged — with the same line appended to stages.log and timeline so
# the history stays honest. Worktrees stay the sweep's business: the two passes
# never decide for each other. Without pgrep the absence of a live process
# cannot be proven, and an unprovable absence reaps nothing.
#
# What leaves this machine: one read-only `gh pr view` per run that has a PR,
# plus — while that run's outcome is still being refreshed — one read-only
# `gh api` call for its review comments.
set -u

_COMMON_LIB_PATH="$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[ -r "$_COMMON_LIB_PATH" ] \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
# shellcheck source=lib/common.sh
. "$_COMMON_LIB_PATH"
# shellcheck source=lib/deps-cache.sh
. "$(dirname "$_COMMON_LIB_PATH")/deps-cache.sh"
# shellcheck source=lib/lessons.sh
. "$(dirname "$_COMMON_LIB_PATH")/lessons.sh"
unset _COMMON_LIB_PATH

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS="$HARNESS_DIR/runs"
JAN_DIR="$RUNS/janitor"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LABEL_ID="com.olyx.janitor"
WRAPPER="$JAN_DIR/janitor-agent.sh"
PLIST="$AGENTS_DIR/$LABEL_ID.plist"
AGENT_LOG="$JAN_DIR/janitor.log"
CLEANUP="$SELF_DIR/cleanup.sh"

# Every knob env-tunable, the way the sibling scripts do it.
AT="${JANITOR_AT:-09:00}"                       # when the installed agent fires
PROC_AGE="${JANITOR_PROC_AGE:-7200}"            # seconds one may live (2h)
GH_TIMEOUT="${JANITOR_GH_TIMEOUT:-20}"          # seconds allowed per gh call
OUTCOME_MAX_AGE="${JANITOR_OUTCOME_MAX_AGE:-14}"  # days a terminal outcome stays refreshed
ZOMBIE_HOURS="${JANITOR_ZOMBIE_HOURS:-12}"       # hours a non-terminal status may age unattended
# When driver.pid + heartbeat PROVE the driver is dead (run_alive = 1), waiting
# 12 hours is pointless — the long window only exists because pgrep alone cannot
# distinguish "no process" from "not started yet". Proof of death is proof of
# death: minutes, not hours.
DEAD_ZOMBIE_MINS="${JANITOR_DEAD_ZOMBIE_MINS:-10}"
DEPS_CACHE_DAYS="${JANITOR_DEPS_CACHE_DAYS:-14}"  # days an unused deps-cache entry may stay
# The one knob that does NOT swallow an empty value into its default: an
# accidentally-empty `JANITOR_PROC_MATCH=$SOMETHING` has to be refused out loud
# rather than quietly reaping the default's processes instead.
PROC_MATCH="${JANITOR_PROC_MATCH-flutter_tester}"   # process name to reap

usage() { harness_usage "$0" >&2; exit 2; }
fail()  { echo "FATAL: $*" >&2; exit 1; }
say()   { echo "[janitor] $*"; }

# Reuse the harness's macOS-safe process cap rather than carrying another copy.
# shellcheck source=capacity.sh
# shellcheck disable=SC1091  # SELF_DIR is resolved at runtime.
. "$SELF_DIR/capacity.sh" || fail "cannot read $SELF_DIR/capacity.sh — re-run install.sh"
capped() { capacity_capped "$@"; }

case "$PROC_AGE" in ''|*[!0-9]*) fail "JANITOR_PROC_AGE must be whole seconds — got [$PROC_AGE]" ;; esac
case "$GH_TIMEOUT" in ''|*[!0-9]*) fail "JANITOR_GH_TIMEOUT must be whole seconds — got [$GH_TIMEOUT]" ;; esac
case "$OUTCOME_MAX_AGE" in ''|*[!0-9]*) fail "JANITOR_OUTCOME_MAX_AGE must be whole days — got [$OUTCOME_MAX_AGE]" ;; esac
case "$ZOMBIE_HOURS" in ''|*[!0-9]*) fail "JANITOR_ZOMBIE_HOURS must be whole hours — got [$ZOMBIE_HOURS]" ;; esac
case "$DEAD_ZOMBIE_MINS" in ''|*[!0-9]*) fail "JANITOR_DEAD_ZOMBIE_MINS must be whole minutes — got [$DEAD_ZOMBIE_MINS]" ;; esac
case "$DEPS_CACHE_DAYS" in ''|*[!0-9]*) fail "JANITOR_DEPS_CACHE_DAYS must be whole days — got [$DEPS_CACHE_DAYS]" ;; esac
# An empty process name is never a valid reaping policy.
[ -n "$PROC_MATCH" ] || fail "JANITOR_PROC_MATCH must not be empty"

WORK=""
cleanup_work() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup_work EXIT

SWEEP_FAILED=0   # cleanup.sh calls that did not succeed, in --clean

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------
human_secs() {  # $1 = seconds
  if   [ "$1" -ge 3600 ]; then printf '%dh%02dm' "$(($1 / 3600))" "$((($1 % 3600) / 60))"
  elif [ "$1" -ge 60 ];   then printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"
  else                         printf '%ds' "$1"
  fi
}

human_kb() {  # $1 = kilobytes, as du -sk reports them
  if   [ "$1" -ge 1048576 ]; then printf '%d.%dG' "$(($1 / 1048576))" "$((($1 % 1048576) * 10 / 1048576))"
  elif [ "$1" -ge 1024 ];    then printf '%dM' "$(($1 / 1024))"
  else                            printf '%dK' "$1"
  fi
}

# One line per worktree the harness still holds, and what may be done about it.
# The full path is printed rather than a basename: it is what an operator checks
# before trusting --clean.
line() {  # $1 = verb, $2 = run id, $3 = why, $4 = worktree
  printf '[janitor]   %-7s %-24s %-44s %s\n' "$1" "$2" "$3" "$4"
}

# ps prints elapsed time as [[DD-]HH:]MM:SS. Leading zeros make $(( )) read a
# field as octal, so every validated field goes through base 10 explicitly.
dec() { printf '%d' "$((10#$1))"; }

etime_secs() {  # $1 = a ps etime field; prints seconds, fails when it is not one
  local e="${1:-}" days=0 h=0 m=0 s=0 has_days=0
  case "$e" in ''|*[!0-9:-]*) return 1 ;; esac
  case "$e" in
    *-*) days="${e%%-*}"; e="${e#*-}"; has_days=1 ;;
  esac
  case "$e" in
    *:*:*:*) return 1 ;;
    *:*:*) h="${e%%:*}"; e="${e#*:}"; m="${e%%:*}"; s="${e##*:}" ;;
    *:*)   [ "$has_days" -eq 0 ] || return 1
            m="${e%%:*}"; s="${e##*:}" ;;
    *)     [ "$has_days" -eq 0 ] || return 1
            s="$e" ;;
  esac
  case "$days:$h:$m:$s" in *[!0-9:]*) return 1 ;; esac
  [ -n "$days" ] && [ -n "$h" ] && [ -n "$m" ] && [ -n "$s" ] || return 1
  days=$(dec "$days"); h=$(dec "$h"); m=$(dec "$m"); s=$(dec "$s")
  [ "$h" -le 23 ] && [ "$m" -le 59 ] && [ "$s" -le 59 ] || return 1
  printf '%d' "$((days * 86400 + h * 3600 + m * 60 + s))"
}

# ---------------------------------------------------------------------------
# The PR state — the one thing this asks the network
# ---------------------------------------------------------------------------
GH_OK=1
GH_NOTE=''

gh_probe() {
  if ! command -v gh >/dev/null 2>&1; then
    GH_OK=0
    GH_NOTE='gh is not installed — no PR state can be read, so nothing is sweepable'
    return 0
  fi
  if ! capped "$GH_TIMEOUT" gh auth status >/dev/null 2>&1; then
    GH_OK=0
    GH_NOTE='gh is not authenticated (gh auth login) — no PR state can be read, so nothing is sweepable'
  fi
  return 0
}

# The fields one poll carries: the state the sweep decides on, plus the dates
# and the squash commit the outcome is built from.
PR_VIEW_FIELDS='state,mergedAt,createdAt,mergeCommit,files'

# The one network ask per run with a PR. Prints gh's JSON object, and nothing at
# all when it could not be read — an unreadable PR is never collapsed into a
# state: that is the whole difference between a janitor and a data-loss incident.
#
# Asked from inside the run's own worktree, the way run-task.sh asks: the url
# identifies the PR by itself, and the cwd makes the repo context right anyway on
# an install where more than one host or account is configured. Once the
# worktree is gone there is nothing to cd into, and the url still identifies the
# PR, so the harness dir stands in.
pr_view() {  # $1 = PR url, $2 = the run's worktree ('' once swept)
  local out cwd="$SELF_DIR"
  [ "$GH_OK" = 1 ] || return 0
  { [ -n "$2" ] && [ -d "$2" ]; } && cwd="$2"
  out=$( (cd "$cwd" 2>/dev/null && capped "$GH_TIMEOUT" gh pr view "$1" --json "$PR_VIEW_FIELDS") 2>/dev/null ) \
    || return 0
  [ -n "$out" ] || return 0
  printf '%s' "$out" | jq -e 'type == "object" and (.state | type == "string")' >/dev/null 2>&1 \
    || return 0
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The outcome — the ground truth a finished run leaves behind
# ---------------------------------------------------------------------------
# result.json says what the pipeline did; outcome.json says what the world then
# did with it. Refreshed from the poll the sweep already made plus at most one
# `gh api` call, never allowed to fail a sweep: anything that cannot be read
# leaves its field at the last value it had (null if there was none).

# Where the run's repo lives, so the git-derived outcome fields survive the
# sweep that removes the worktree. Resolved once from the worktree and kept in
# the run dir, exactly like the worktree path itself.
outcome_repo() {  # $1 = run dir, $2 = the run's worktree (''); prints a repo path or nothing
  local d="$1" repo gitdir
  if [ -s "$d/repo" ]; then
    repo=$(cat "$d/repo" 2>/dev/null)
    [ -n "$repo" ] && [ -d "$repo" ] && { printf '%s\n' "$repo"; return 0; }
  fi
  { [ -n "$2" ] && [ -d "$2" ]; } || return 0
  gitdir=$(git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  repo=$(dirname "$gitdir")
  printf '%s\n' "$repo" > "$d/repo" 2>/dev/null
  printf '%s\n' "$repo"
}

# Refresh one origin/base pair at most once per pass, even when many outcomes
# belong to the same repository. A failed fetch is cached as failed too: using
# the old remote-tracking ref would turn unavailable ground truth into a stale
# but authoritative-looking label.
refreshed_base_ref() {  # $1 = repo, $2 = base branch; prints the refreshed ref or nothing
  local repo="$1" base="$2" cache="$WORK/base-fetches" row status ref
  row=$(awk -F '\t' -v r="$repo" -v b="$base" \
    '$1 == r && $2 == b { print $3 "\t" $4; exit }' "$cache" 2>/dev/null)
  if [ -z "$row" ]; then
    status=failed
    ref=''
    if capped "$GH_TIMEOUT" git -C "$repo" fetch --quiet origin \
         "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null; then
      ref=$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$base" 2>/dev/null)
      [ -z "$ref" ] || status=ok
    fi
    printf '%s\t%s\t%s\t%s\n' "$repo" "$base" "$status" "$ref" >> "$cache"
  else
    status=${row%%$'\t'*}
    ref=${row#*$'\t'}
  fi
  [ "$status" = ok ] && [ -n "$ref" ] && printf '%s\n' "$ref"
  return 0
}

# The politeness knob, asked before the poll: a terminal outcome older than
# JANITOR_OUTCOME_MAX_AGE days costs nothing further, not even the gh call.
outcome_settled() {  # $1 = run dir, $2 = current PR url; succeeds when refresh may stop
  local out="$1/outcome.json" url="$2" cutoff
  [ -s "$out" ] || return 1
  cutoff=$(( $(date +%s) - OUTCOME_MAX_AGE * 86400 ))
  jq -e --arg url "$url" --argjson cutoff "$cutoff" '
    .pr_url == $url
    and (.pr_state == "MERGED" or .pr_state == "CLOSED")
    and (((.checked_at // "") | if test("^[0-9]{4}-") then fromdateiso8601 else 0 end) < $cutoff)
  ' "$out" >/dev/null 2>&1
}

# Prints written | unreadable.
capture_outcome() {  # $1 = run dir, $2 = PR url, $3 = the poll's JSON ('' = unreadable), $4 = worktree
  local d="$1" url="$2" view="$3" wt="${4:-}"
  local out="$d/outcome.json" tmp
  local state merged_at merge_oid files_tsv ttm ids rcc=''
  local repo base base_ref tip_ct merged_ct follow='' reverted=''
  local candidates candidate
  local rest owner api fpaths=()

  [ -n "$view" ] || { printf 'unreadable'; return 0; }

  state=$(printf '%s' "$view"  | jq -r '.state // ""' 2>/dev/null)
  merged_at=$(printf '%s' "$view" | jq -r '.mergedAt // ""' 2>/dev/null)
  merge_oid=$(printf '%s' "$view" | jq -r '.mergeCommit.oid // ""' 2>/dev/null)
  files_tsv=$(printf '%s' "$view" | jq -r '[.files[]?.path] | @tsv' 2>/dev/null)
  ttm=$(printf '%s' "$view" | jq -r '
    ((.mergedAt | fromdateiso8601?) // null) as $m
    | ((.createdAt | fromdateiso8601?) // null) as $c
    | if ($m != null and $c != null) then ($m - $c | tostring) else "" end' 2>/dev/null)

  # The one extra call: the inline review comments, which `gh pr view` does not
  # carry. Bots are counted out; a line per comment, paginated, so a heavily
  # reviewed PR is counted rather than capped at the first page.
  case "$url" in
    https://github.com/*/*/pull/[0-9]*)
      rest="${url#https://github.com/}"; owner="${rest%%/*}"; rest="${rest#*/}"
      api="repos/$owner/${rest%%/*}/pulls/${rest##*/}/comments"
      if ids=$( (cd "$SELF_DIR" 2>/dev/null \
                 && capped "$GH_TIMEOUT" gh api --paginate "$api" \
                      --jq '.[] | select(.user.type != "Bot") | .id') 2>/dev/null ); then
        # printf '%s', not '%s\n': an empty answer is zero comments, not a
        # blank line somebody counted.
        rcc=$(printf '%s' "$ids" | grep -c '' | tr -d ' ')
      fi
      ;;
  esac

  # The git-derived fields: only a merged PR has them, and only while the local
  # base branch has seen the merge. A base tip that predates the merge would
  # answer "none" to a question it has no data for, so it answers null instead.
  if [ "$state" = MERGED ] && [ -n "$merged_at" ] && [ -n "$merge_oid" ]; then
    repo=$(outcome_repo "$d" "$wt")
    base=$(jq -r '.base // empty' "$d/result.json" 2>/dev/null)
    if [ -n "$repo" ] && [ -n "$base" ] \
       && base_ref=$(refreshed_base_ref "$repo" "$base") && [ -n "$base_ref" ]; then
      tip_ct=$(git -C "$repo" log -1 --format=%ct "$base_ref" 2>/dev/null)
      # -R: the timestamp arrives as raw text, and without it jq tries to read
      # it as a JSON number and dies at parse level, where no ? can catch it.
      merged_ct=$(printf '%s' "$merged_at" | jq -Rr 'try fromdateiso8601 catch 0' 2>/dev/null)
      if [ -n "$tip_ct" ] && [ "$tip_ct" -ge "$merged_ct" ] 2>/dev/null; then
        if [ -n "$files_tsv" ]; then
          IFS=$'\t' read -r -a fpaths <<< "$files_tsv"
          # Exact when the squash commit is in the local history (and on the
          # base branch); by date when only the merge time is.
          if git -C "$repo" merge-base --is-ancestor "$merge_oid" "$base_ref" 2>/dev/null; then
            follow=$(git -C "$repo" rev-list --count "$merge_oid..$base_ref" \
                       -- ${fpaths[@]+"${fpaths[@]}"} 2>/dev/null || echo '')
          else
            follow=$(git -C "$repo" rev-list --count "$base_ref" --since="$merged_at" \
                       -- ${fpaths[@]+"${fpaths[@]}"} 2>/dev/null || echo '')
          fi
        fi
        # `git revert` records an exact trailer. A prose mention of the squash
        # SHA (for example in release notes) is not evidence that it was undone.
        reverted=false
        candidates=$(git -C "$repo" log -F --grep="$merge_oid" --format=%H \
                       "$base_ref" 2>/dev/null)
        for candidate in $candidates; do
          if git -C "$repo" show -s --format=%B "$candidate" 2>/dev/null \
               | grep -Fxq "This reverts commit $merge_oid."; then
            reverted=true
            break
          fi
        done
      fi
    fi
  fi

  local prev='{}'
  [ -s "$out" ] && prev=$(jq -c . "$out" 2>/dev/null)
  [ -n "$prev" ] || prev='{}'
  tmp=$(mktemp "$out.tmp.XXXXXX" 2>/dev/null) \
    || { printf 'unreadable'; return 0; }
  if jq -n --arg url "$url" --arg state "$state" --arg merged_at "$merged_at" --arg ttm "$ttm" \
        --arg rcc "$rcc" --arg follow "$follow" --arg reverted "$reverted" \
        --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson prev "$prev" '
      {pr_url: $url,
       pr_state: $state,
       merged_at: (if $merged_at == "" then null else $merged_at end),
       time_to_merge_s: (if $ttm == "" then ($prev.time_to_merge_s // null) else ($ttm | tonumber) end),
       review_comment_count: (if $rcc == "" then ($prev.review_comment_count // null) else ($rcc | tonumber) end),
       follow_up_commits: (if $follow == "" then ($prev.follow_up_commits // null) else ($follow | tonumber) end),
       reverted: (if $reverted == "" then ($prev.reverted // null) else ($reverted == "true") end),
       checked_at: $checked}
    ' > "$tmp" 2>/dev/null && mv "$tmp" "$out"; then
    printf 'written'
  else
    rm -f "$tmp"
    printf 'unreadable'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The feedback loop
# ---------------------------------------------------------------------------
# The outcome pass above records what the world did with each PR; this one
# reads that back. Per repo, the review findings that survived refutation are
# ranked by recurrence and by what their PR then cost, and the top few are
# written to a lessons file the next dispatch mounts for its implementer and
# the planner reads before writing a brief (lib/lessons.sh, lessons.sh).
#
# It runs in both modes and destroys nothing: the files are derived, rewritten
# whole from run history every pass, and a repo with no confirmed traps has its
# file removed rather than left stale. Never fails the sweep — a distillation
# that cannot be produced costs the next run one missing paragraph of advice.
distil_lessons() {
  local repos traps
  read -r repos traps <<EOF
$(lessons_refresh_all 2>/dev/null)
EOF
  case "${repos:-}" in ''|*[!0-9]*) say "lessons: could not distil this pass"; return 0 ;; esac
  say "lessons: $traps trap(s) across $repos repo(s) — $LESSONS_DIR"
}

# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------
sweep_runs() {  # $1 = report | clean
  local mode="$1"
  local d id wt pr view state porcelain gitdir kb rc stage_text dirty
  local n_runs=0 n_sweep=0 n_open=0 n_closed=0 n_dirty=0 n_unknown=0
  local n_nopr=0 n_unfinished=0 n_gone=0 reclaim=0 kept=0
  local n_oc_written=0 n_oc_settled=0 n_oc_unreadable=0

  if [ ! -d "$RUNS" ]; then
    say "no runs directory at $RUNS — nothing to sweep"
    return 0
  fi
  [ -n "$GH_NOTE" ] && say "$GH_NOTE"

  for d in "$RUNS"/*; do
    [ -d "$d" ] || continue
    # A run dir is one the pipeline wrote a status or a result into. The
    # quartermaster's and this script's own directories live under runs/ too and
    # are not runs.
    [ -f "$d/status" ] || [ -f "$d/result.json" ] || continue
    id="${d##*/}"
    n_runs=$((n_runs + 1))

    # The worktree, read exactly the way cleanup.sh reads it — the same helper.
    wt=$(harness_worktree "$d")

    # The poll and the outcome come before anything else, because a run whose
    # worktree is already gone still has a PR whose fate is worth recording —
    # and a settled one is not polled at all.
    pr=$(jq -r '.pr_url // empty' "$d/result.json" 2>/dev/null)
    view=''
    state=''
    if [ -n "$pr" ]; then
      if outcome_settled "$d" "$pr"; then
        n_oc_settled=$((n_oc_settled + 1))
        # Settling suppresses network refreshes, not the cleanup decision. The
        # terminal state already persisted in outcome.json is still ground
        # truth for a worktree that survived until a later pass.
        if [ "$GH_OK" = 1 ]; then
          state=$(jq -r '.pr_state // ""' "$d/outcome.json" 2>/dev/null)
        fi
      else
        view=$(pr_view "$pr" "$wt")
        state=$(printf '%s' "$view" | jq -r '.state // ""' 2>/dev/null)
        case "$(capture_outcome "$d" "$pr" "$view" "$wt")" in
          written)  n_oc_written=$((n_oc_written + 1)) ;;
          *)        n_oc_unreadable=$((n_oc_unreadable + 1)) ;;
        esac
      fi
    fi

    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
      n_gone=$((n_gone + 1))
      continue
    fi

    # A run that has not reached a done: stage may still be building in that
    # worktree, or waiting in it for an answer. Never touched, whatever its PR
    # says — and a run with no stage line at all is one whose state cannot be
    # read, which is the same answer.
    stage_text=$(sed -n '1s/^[0-9]* //p' "$d/status" 2>/dev/null)
    case "$stage_text" in
      done:*) ;;
      '') line keep "$id" "no status line — cannot tell if it is done" "$wt"
          n_unfinished=$((n_unfinished + 1)); continue ;;
      *)  line keep "$id" "still running — $stage_text" "$wt"
          n_unfinished=$((n_unfinished + 1)); continue ;;
    esac

    if [ -z "$pr" ]; then
      line keep "$id" "no pr_url — the work exists only here" "$wt"
      n_nopr=$((n_nopr + 1)); continue
    fi

    # MERGED, OPEN or CLOSED out of the poll above; anything else — including a
    # DRAFT — is a state this sweep cannot act on, which is the `unknown` below.
    case "$state" in
      MERGED) ;;
      OPEN)   line keep "$id" "PR is OPEN — review fixes land here" "$wt"
              n_open=$((n_open + 1)); continue ;;
      CLOSED) line keep "$id" "PR is CLOSED, not merged" "$wt"
              n_closed=$((n_closed + 1)); continue ;;
      *)      line keep "$id" "PR state unreadable — left alone" "$wt"
              n_unknown=$((n_unknown + 1)); continue ;;
    esac

    if ! porcelain=$(git --no-optional-locks -C "$wt" status --porcelain 2>/dev/null); then
      line keep "$id" "not a readable git worktree" "$wt"
      n_unknown=$((n_unknown + 1)); continue
    fi
    if [ -n "$porcelain" ]; then
      dirty=$(printf '%s\n' "$porcelain" | grep -c '' | tr -d ' ')
      line keep "$id" "merged, but dirty ($dirty uncommitted)" "$wt"
      n_dirty=$((n_dirty + 1)); continue
    fi

    kb=$(du -sk "$wt" 2>/dev/null | awk 'NR==1 {print $1}')
    case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
    n_sweep=$((n_sweep + 1))

    # The repo can only be resolved through the worktree, so it is resolved
    # before cleanup.sh removes it.
    if gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
      dirname "$gitdir" >> "$WORK/repos"
    fi

    if [ "$mode" != clean ]; then
      line sweep "$id" "merged and clean — $(human_kb "$kb") to reclaim" "$wt"
      reclaim=$((reclaim + kb))
      continue
    fi

    line sweep "$id" "merged and clean — reclaiming $(human_kb "$kb")" "$wt"
    rc=0
    HARNESS_DIR="$HARNESS_DIR" bash "$CLEANUP" "$id" > "$WORK/cleanup.out" 2>&1 || rc=$?
    sed 's/^/[janitor]           /' "$WORK/cleanup.out"
    if [ "$rc" -ne 0 ] || [ -d "$wt" ]; then
      say "  cleanup.sh left $wt standing (exit $rc) — kept for the next pass"
      SWEEP_FAILED=$((SWEEP_FAILED + 1))
      n_sweep=$((n_sweep - 1))
    else
      reclaim=$((reclaim + kb))
    fi
  done

  kept=$((n_open + n_closed + n_dirty + n_unknown + n_nopr + n_unfinished))
  echo
  if [ "$mode" = clean ]; then
    say "$n_sweep worktree(s) swept, $(human_kb "$reclaim") reclaimed · $kept kept · $n_gone of $n_runs runs had no worktree left"
  else
    say "$n_sweep worktree(s) sweepable, $(human_kb "$reclaim") to reclaim · $kept kept · $n_gone of $n_runs runs had no worktree left"
  fi
  say "  kept: $n_open open · $n_closed closed · $n_dirty dirty · $n_unknown unknown · $n_nopr no-pr · $n_unfinished unfinished"
  if [ $((n_oc_written + n_oc_settled + n_oc_unreadable)) -gt 0 ]; then
    say "  outcomes: $n_oc_written written · $n_oc_settled settled (terminal, over $OUTCOME_MAX_AGE days old) · $n_oc_unreadable not readable"
  fi
  return 0
}

# cleanup.sh prunes the repo it just removed a worktree from. This prunes them
# again, once each, after the whole sweep: a stale administrative entry left by
# something else is the same disk lie, and it costs nothing to catch it here.
prune_repos() {
  local repo
  [ -s "$WORK/repos" ] || return 0
  sort -u "$WORK/repos" > "$WORK/repos.uniq"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if git -C "$repo" worktree prune 2>/dev/null; then
      say "  pruned worktree metadata in $repo"
    else
      say "  could not prune $repo — left as it is"
    fi
  done < "$WORK/repos.uniq"
  return 0
}

# ---------------------------------------------------------------------------
# The zombie reap — statuses a dead process left non-terminal
# ---------------------------------------------------------------------------
# The stage text of a status line: everything after the leading epoch, the way
# the sweep and the wall read it. A line with no epoch hands back the raw line;
# one that is only an epoch hands back nothing.
status_text() {  # $1 = the status file's first line
  local ts="${1%% *}" rest
  case "$ts" in *[!0-9]*|'') printf '%s' "$1"; return 0 ;; esac
  rest="${1#"$ts"}"
  printf '%s' "${rest# }"
}

# Seconds since a status was written: the line's own epoch when it has one,
# else the file's mtime — a line nobody can parse still happened at some
# point. Prints nothing when neither answers: a run that cannot be dated is
# never a zombie.
status_age() {  # $1 = status file, $2 = its first line
  local ts="${2%% *}" m
  case "$ts" in *[!0-9]*) ts='' ;; esac
  if [ -n "$ts" ] && [ "${#ts}" -le 10 ]; then
    printf '%s\n' "$(( $(date +%s) - $(dec "$ts") ))"
    return 0
  fi
  if m=$(stat -f %m "$1" 2>/dev/null); then
    :
  elif m=$(stat -c %Y "$1" 2>/dev/null); then
    :
  else
    return 0
  fi
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$(( $(date +%s) - m ))"
}

# The merged special case's one fact, out of the sweep's own product: a PR this
# pass already polled is in outcome.json, so the answer costs no network call.
# The recorded url must be this run's — a file naming another PR is not
# evidence about this one.
pr_merged() {  # $1 = run dir, $2 = pr url ('' = none); succeeds when it is recorded MERGED
  [ -n "$2" ] || return 1
  [ "$(jq -r --arg url "$2" 'select(.pr_url == $url) | .pr_state // ""' \
     "$1/outcome.json" 2>/dev/null)" = MERGED ]
}

reap_history_snapshot() {  # $1 = run dir; saves both histories before append
  REAP_STAGES_EXISTED=0
  REAP_TIMELINE_EXISTED=0
  if [ -e "$1/stages.log" ]; then
    cp "$1/stages.log" "$WORK/reap-stages.before" 2>/dev/null || return 1
    REAP_STAGES_EXISTED=1
  fi
  if [ -e "$1/timeline" ]; then
    cp "$1/timeline" "$WORK/reap-timeline.before" 2>/dev/null || return 1
    REAP_TIMELINE_EXISTED=1
  fi
  return 0
}

reap_history_restore() {  # $1 = run dir
  local rc=0
  if [ "$REAP_STAGES_EXISTED" -eq 1 ]; then
    cp "$WORK/reap-stages.before" "$1/stages.log" 2>/dev/null || rc=1
  else
    rm -f "$1/stages.log" 2>/dev/null || rc=1
  fi
  if [ "$REAP_TIMELINE_EXISTED" -eq 1 ]; then
    cp "$WORK/reap-timeline.before" "$1/timeline" 2>/dev/null || rc=1
  else
    rm -f "$1/timeline" 2>/dev/null || rc=1
  fi
  return "$rc"
}

reap_zombies() {  # $1 = report | clean
  local mode="$1"
  local d id id_pattern first current text age new pr pgrep_rc _ra _rs
  local n_reap=0 n_live=0 n_fresh=0 n_left=0

  # The guard cannot run without pgrep, and a reap that cannot prove the
  # absence of a live process does not happen at all.
  command -v pgrep >/dev/null 2>&1 \
    || { say "zombies: pgrep is unavailable — a stale status is never reaped without it"; return 0; }

  say "zombies: statuses older than ${ZOMBIE_HOURS}h that never reached done: and have no live process"
  [ -d "$RUNS" ] || return 0

  for d in "$RUNS"/*; do
    [ -d "$d" ] || continue
    [ -f "$d/status" ] || continue
    id="${d##*/}"

    # Terminal runs are not zombies, whatever their age — and idempotence
    # lives here too: a reaped run is a done: run on the next pass.
    first=''
    if ! IFS= read -r first < "$d/status" 2>/dev/null; then
      n_left=$((n_left + 1))
      continue
    fi
    text=$(status_text "$first")
    case "$text" in done:*) continue ;; esac

    age=$(status_age "$d/status" "$first")
    [ -n "$age" ] || { n_left=$((n_left + 1)); continue; }
    # Two thresholds: proof of death (driver.pid + heartbeat, run_alive = 1)
    # earns the minutes-scale reap; everything else keeps the conservative
    # hours-scale window, because pgrep alone cannot distinguish "no process"
    # from "not started yet".
    run_alive "$d"; _ra=$?
    if [ "$_ra" -eq 1 ]; then
      [ "$age" -gt $((DEAD_ZOMBIE_MINS * 60)) ] || { n_fresh=$((n_fresh + 1)); continue; }
    else
      [ "$age" -gt $((ZOMBIE_HOURS * 3600)) ] || { n_fresh=$((n_fresh + 1)); continue; }
    fi

    # Match the scheduler's ticket alphabet. The dot is escaped in the process
    # pattern below so it remains a literal ticket character.
    case "$id" in *[!A-Za-z0-9._-]*|.*) n_left=$((n_left + 1)); continue ;; esac

    # A live run-task.sh or sync-pr.sh for this id is proof the run is not
    # dead, whatever its status says. Only pgrep's no-match result proves
    # absence; an enumeration error leaves the run unjudged.
    id_pattern=${id//./\\.}
    pgrep -f "run-task\.sh $id_pattern( |$)|sync-pr\.sh $id_pattern( |$)" >/dev/null 2>&1
    pgrep_rc=$?
    case "$pgrep_rc" in
      0) n_live=$((n_live + 1))
         line live "$id" "stale $(human_secs "$age") but a process is serving it" "$d"
         continue ;;
      1) ;;
      *) n_left=$((n_left + 1))
         line keep "$id" "process state could not be read — left as it was" "$d"
         continue ;;
    esac

    current=''
    if ! IFS= read -r current < "$d/status" 2>/dev/null || [ "$current" != "$first" ]; then
      n_left=$((n_left + 1))
      line keep "$id" "status changed while checking liveness — left as it was" "$d"
      continue
    fi

    pr=$(jq -r '.pr_url // empty' "$d/result.json" 2>/dev/null)
    if pr_merged "$d" "$pr"; then
      new="done: ready (reaped — PR merged)"
    else
      new="done: reaped (stale — no live process, was: ${text:-no stage text})"
    fi
    n_reap=$((n_reap + 1))

    if [ "$mode" != clean ]; then
      line reap "$id" "stale $(human_secs "$age") — would write: $new" "$d"
      continue
    fi

    if [ ! -w "$d/status" ]; then
      n_reap=$((n_reap - 1))
      line keep "$id" "status could not be rewritten — left as it was" "$d"
      continue
    fi
    if ! reap_history_snapshot "$d"; then
      n_reap=$((n_reap - 1))
      line keep "$id" "history could not be read — left as it was" "$d"
      continue
    fi
    if ! printf '%s %s\n' "$(date +%s)" "$new" >> "$d/stages.log" 2>/dev/null \
       || ! printf '%s %s\n' "$(date '+%H:%M:%S')" "$new" >> "$d/timeline" 2>/dev/null; then
      reap_history_restore "$d" || :
      n_reap=$((n_reap - 1))
      line keep "$id" "history could not be appended — left as it was" "$d"
      continue
    fi
    if printf '%s %s\n' "$(date +%s)" "$new" > "$d/status" 2>/dev/null; then
      line reaped "$id" "stale $(human_secs "$age") — $new" "$d"
      # A reaped run also gets a verdict file, so metrics.sh and the wall see a
      # terminated attempt instead of a run that never ended. Only when none
      # exists — a real verdict (ready, gate_failed, …) is never rewritten by
      # the janitor. The status mirrors the reaped stage text: a merged PR is
      # ready, everything else died driving.
      if [ ! -f "$d/result.json" ]; then
        case "$new" in "done: ready"*) _rs="ready" ;; *) _rs="driver_failed" ;; esac
        jq -n --arg t "$id" --arg s "$_rs" --arg pr "$pr" --arg dir "$d" \
          '{ticket:$t,status:$s,pr_url:$pr,logs:$dir,reaped:true}' \
          > "$d/result.json" 2>/dev/null || true
      fi
    else
      reap_history_restore "$d" || :
      n_reap=$((n_reap - 1))
      line keep "$id" "status could not be rewritten — left as it was" "$d"
    fi
  done

  if [ "$mode" = clean ]; then
    say "  $n_reap reaped, $n_live guarded by a live process, $n_fresh under ${ZOMBIE_HOURS}h, $n_left could not be judged"
  else
    say "  $n_reap to reap, $n_live guarded by a live process, $n_fresh under ${ZOMBIE_HOURS}h, $n_left could not be judged"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The process reap
# ---------------------------------------------------------------------------
# `flutter test` spawns a detached test runner and does not always take it with
# it, and removing the worktree it ran in does not kill it either. Nothing
# legitimate keeps one of these alive for hours, so age is the whole test.
kill_proc() {  # $1 = pid
  kill -TERM "$1" 2>/dev/null || return 1
  # A runner that ignores TERM still has to go.
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$1" 2>/dev/null; then kill -KILL "$1" 2>/dev/null || return 1; fi
  return 0
}

reap_procs() {  # $1 = report | clean
  local mode="$1" pid etime comm secs
  local old=0 within_limit=0 killed=0 stubborn=0

  say "processes: $PROC_MATCH older than $(human_secs "$PROC_AGE")"
  # Read from a file, not a pipe: the counters have to survive the loop.
  ps -Ao pid=,etime=,comm= > "$WORK/ps" 2>/dev/null || : > "$WORK/ps"
  while read -r pid etime comm; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$PPID" ] && continue
    # comm is a full path on macOS and a bare name on Linux; compare its basename
    # exactly so a similarly named process is never swept up accidentally.
    [ "${comm##*/}" = "$PROC_MATCH" ] || continue
    secs=$(etime_secs "$etime") || continue
    if [ "$secs" -le "$PROC_AGE" ]; then
      within_limit=$((within_limit + 1))
      continue
    fi
    old=$((old + 1))
    if [ "$mode" != clean ]; then
      line kill "$pid" "up $(human_secs "$secs")" "$comm"
      continue
    fi
    if kill_proc "$pid"; then
      killed=$((killed + 1))
      line killed "$pid" "up $(human_secs "$secs")" "$comm"
    else
      stubborn=$((stubborn + 1))
      line alive "$pid" "up $(human_secs "$secs") — would not die" "$comm"
    fi
  done < "$WORK/ps"

  if [ "$mode" = clean ]; then
    say "  $killed killed, $stubborn survived, $within_limit not older than $(human_secs "$PROC_AGE") left alone"
  else
    say "  $old to kill, $within_limit not older than $(human_secs "$PROC_AGE") left alone"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The deps-cache prune
# ---------------------------------------------------------------------------
# run-task.sh stores one node_modules per (lockfile, install command, node)
# under $HARNESS_DIR/cache/deps and touches an entry every time it restores
# from it, so an entry's mtime IS its last use. A lockfile that changed leaves
# its predecessor's entry behind forever — nothing dispatch-side ever looks
# back — which makes it this script's business, like the worktrees.
deps_line() {  # $1 = report|clean verb context, $2 = entry path, $3 = size in KB
  local verb=evict; [ "$1" = clean ] && verb=evicted
  line "$verb" "$(basename "$(dirname "$2")")" "unused > ${DEPS_CACHE_DAYS}d ($(human_kb "$3"))" "$2"
}

prune_deps_cache() {  # $1 = report | clean
  say "deps cache: entries unused for more than ${DEPS_CACHE_DAYS} days"
  DEPS_CACHE_PRUNED=0; DEPS_CACHE_KEPT=0
  deps_cache_prune "$1" "$DEPS_CACHE_DAYS" deps_line
  if [ "$1" = clean ]; then
    say "  $DEPS_CACHE_PRUNED evicted, $DEPS_CACHE_KEPT in use kept"
  else
    say "  $DEPS_CACHE_PRUNED to evict, $DEPS_CACHE_KEPT in use kept"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# One pass
# ---------------------------------------------------------------------------
pass() {  # $1 = report | clean
  local requested_mode="$1" mode="$1"
  say "$(date '+%Y-%m-%d %H:%M:%S') · $requested_mode · $RUNS"
  gh_probe
  if [ "$requested_mode" = clean ] && [ "$GH_OK" -ne 1 ]; then
    mode=report
    say "--clean degraded to report-only because PR state is unavailable; no worktrees or processes will be touched"
  fi
  if [ "$mode" = clean ]; then
    [ -r "$CLEANUP" ] || fail "cannot read $CLEANUP — re-run install.sh"
  fi
  sweep_runs "$mode"
  [ "$mode" = clean ] && prune_repos
  echo
  reap_zombies "$mode"
  echo
  reap_procs "$mode"
  echo
  prune_deps_cache "$mode"
  echo
  distil_lessons
  if [ "$mode" != clean ]; then
    echo
    say "--report swept and reaped nothing (outcome.json and the lessons files are still refreshed). janitor.sh --clean does the above."
    return 0
  fi
  # A sweep that could not finish is the one thing an operator has to notice.
  [ "$SWEEP_FAILED" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# The daily agent — quartermaster.sh's launchd conventions, one label over
# ---------------------------------------------------------------------------
shquote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

need_macos() {  # $1 = the mode that needs it
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || fail "$1 needs macOS (it manages a launchd LaunchAgent) — this is $(uname -s 2>/dev/null || echo an unknown OS).
Run janitor.sh --report from your own timer instead."
}

# launchd hands a job an almost empty environment, so the agent carries a
# snapshot of the shell that installed it. GH_CONFIG_DIR is swept in — it is
# what decides which account can read a PR's state — while GH_TOKEN is not: gh
# prefers a token over its config dir, and a credential does not belong in a
# generated file.
env_names() {
  { compgen -e 2>/dev/null | grep -E '^(HARNESS|JANITOR)_[A-Za-z0-9_]+$'
    printf '%s\n' HARNESS_DIR GH_CONFIG_DIR HOME PATH
  } | sort -u
}

env_snapshot() {
  local n set_flag val
  for n in $(env_names); do
    eval "set_flag=\${$n+x}; val=\${$n:-}"
    [ -n "$set_flag" ] || continue
    printf 'export %s=' "$n"; shquote "$val"; printf '\n'
  done
}

write_agent_wrapper() {
  : > "$WRAPPER" || return 1
  chmod 600 "$WRAPPER" || return 1
  {
    cat <<EOF
#!/usr/bin/env bash
# Daily janitor wrapper — generated by janitor.sh, do not edit.
# Mode 600: it carries the environment snapshot of the shell that installed it.
set -u

JAN=$(shquote "$SELF_DIR/janitor.sh")

$(env_snapshot)
EOF
    cat <<'EOF'

echo "[janitor] $(date '+%Y-%m-%d %H:%M:%S') waking up: $*"
exec "$JAN" "$@"
EOF
  } >> "$WRAPPER"
}

write_agent_plist() {  # $1 = mode argument, $2 = hour, $3 = minute
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml_escape "$LABEL_ID")</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml_escape "$WRAPPER")</string>
		<string>$(xml_escape "$1")</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>$2</integer>
		<key>Minute</key>
		<integer>$3</integer>
	</dict>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$AGENT_LOG")</string>
</dict>
</plist>
EOF
}

install_agent() {  # $1 = the mode the agent runs in
  local hour minute
  need_macos "--install"
  case "$AT" in
    [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9]) ;;
    *) fail "JANITOR_AT must be HH:MM — got [$AT]" ;;
  esac
  hour=$(printf '%s' "${AT%%:*}" | sed 's/^0//'); hour="${hour:-0}"
  minute=$(printf '%s' "${AT##*:}" | sed 's/^0//'); minute="${minute:-0}"
  { [ "$hour" -le 23 ] && [ "$minute" -le 59 ]; } || fail "JANITOR_AT is not a time of day: [$AT]"

  mkdir -p "$JAN_DIR" "$AGENTS_DIR" || fail "cannot create $JAN_DIR / $AGENTS_DIR"
  # Re-installing is how the trust dial is flipped, so an existing agent is
  # replaced rather than refused.
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  write_agent_wrapper || fail "cannot write $WRAPPER"
  write_agent_plist "$1" "$hour" "$minute" || { rm -f "$WRAPPER" "$PLIST"; fail "cannot write $PLIST"; }
  launchctl bootstrap "gui/$(id -u)" "$PLIST" \
    || { rm -f "$WRAPPER" "$PLIST"; fail "launchctl could not load $PLIST"; }

  echo "[janitor] installed — every day at $AT, mode $1"
  echo "[janitor]   agent   $LABEL_ID"
  echo "[janitor]   wrapper $WRAPPER (mode 600 — holds an env snapshot)"
  echo "[janitor]   plist   $PLIST"
  echo "[janitor]   log     $AGENT_LOG"
  if [ "$1" = "--report" ]; then
    echo "[janitor] It only reports. When you trust it, flip the dial:"
    echo "[janitor]   janitor.sh --install --clean"
    echo "[janitor] (or edit the third <string> in the plist and reload it)."
  fi
  echo "[janitor] Remove: janitor.sh --uninstall"
}

uninstall_agent() {
  need_macos "--uninstall"
  if [ ! -e "$PLIST" ] && [ ! -e "$WRAPPER" ]; then
    echo "[janitor] nothing installed"
    return 0
  fi
  launchctl bootout "gui/$(id -u)/$LABEL_ID" >/dev/null 2>&1 || true
  rm -f "$PLIST" "$WRAPPER"
  echo "[janitor] uninstalled — agent, plist and wrapper removed (the log in $JAN_DIR is kept)"
}

# ---------------------------------------------------------------------------
main() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/janitor.XXXXXX") || fail "cannot create a work dir"
  case "${1:-}" in
    ''|--report) [ $# -le 1 ] || usage; pass report ;;
    --clean)     [ $# -eq 1 ] || usage; pass clean ;;
    --install)
      case "${2:---report}" in
        --report|--clean) [ $# -le 2 ] || usage; install_agent "${2:---report}" ;;
        *) echo "--install takes --report or --clean: $2" >&2; echo >&2; usage ;;
      esac
      ;;
    --uninstall) [ $# -eq 1 ] || usage; uninstall_agent ;;
    -h|--help)   usage ;;
    *)           echo "unknown option: $1" >&2; echo >&2; usage ;;
  esac
}

main "$@"
