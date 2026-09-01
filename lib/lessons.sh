# shellcheck shell=bash
# The feedback loop: what past runs in a repo taught, distilled into a file the
# next run's planner and implementer read before they start.
#
# The pipeline already produces the only two honest signals it will ever have
# about whether a run was any good, and until this existed it threw both away
# into a table nobody read back:
#
#   promoted.json  — the findings that SURVIVED refutation. A reviewer from a
#                    different vendor claimed a defect, a second session that
#                    had not seen the diff failed to disprove it, and the fix
#                    pass edited code for it. That is not an opinion about
#                    style; it is a defect an implementer actually wrote in
#                    this repo and the pipeline actually caught.
#   outcome.json   — what the world then did with the PR (janitor.sh): merged,
#                    reverted, how many humans had to comment, how many commits
#                    landed on those files afterwards.
#
# The split between them is the whole design: **findings supply the text,
# outcomes supply the weight.** Nothing here asks a model to summarise anything.
# Distillation by judge was the tempting version and it fails the same test
# ADR 0014 records — a daily cron that needs a vendor, a quota and a key is a
# loop that stops the first week the key expires, and a judge's paraphrase of a
# finding is one more thing that can be confidently wrong. A verbatim claim,
# counted and ranked by evidence, cannot be.
#
# Ranking is one point per run that hit the file, plus what the world charged for
# those PRs. Recurrence is the base because it is the signal a human gardener
# acts on — the third time the same file bites is when it becomes a rule — but a
# revert is worth three of it: a PR that had to be undone is the loudest thing
# this pipeline can learn about a file, and one of those outranking three quiet
# repeats is the intended order, not a rounding accident.
#
# Three evictions keep the file small enough to be worth reading, and honest:
#   - anything from a run older than LESSONS_MAX_AGE days is gone,
#   - a trap seen in exactly one run is gone after LESSONS_SOLO_MAX_AGE days —
#     one sighting is an anecdote until it repeats,
#   - a trap whose file is no longer tracked in the repo is gone, which also
#     silently drops findings that cited a path the reviewer invented (`.file`
#     is free-form model text; nothing upstream validates it).
#
# Sourced, never executed — lessons.sh is the CLI, janitor.sh the daily caller,
# run-task.sh the just-in-time one. Safe under `set -u`.
#
# HARNESS_DIR comes from common.sh, which every caller sources first.
# shellcheck disable=SC2034

LESSONS_DIR="${LESSONS_DIR:-$HARNESS_DIR/lessons}"
LESSONS_MAX_ENTRIES="${LESSONS_MAX_ENTRIES:-8}"       # traps per repo (files)
LESSONS_MAX_CLAIMS="${LESSONS_MAX_CLAIMS:-2}"         # findings quoted per trap
LESSONS_CLAIM_CHARS="${LESSONS_CLAIM_CHARS:-160}"     # per quoted finding
LESSONS_MAX_AGE="${LESSONS_MAX_AGE:-60}"              # days a run may contribute
LESSONS_SOLO_MAX_AGE="${LESSONS_SOLO_MAX_AGE:-21}"    # days a one-run trap survives
LESSONS_NOISY_COMMENTS="${LESSONS_NOISY_COMMENTS:-5}" # human review comments = "argued over"
LESSONS_STALE_HOURS="${LESSONS_STALE_HOURS:-12}"      # before a dispatch refreshes on its own

# The two separators this file passes between awk, sort and shell. Named
# because a literal tab inside a case pattern or a ${x%%...} is invisible in a
# diff, and one that gets normalised to spaces by an editor is a silent
# mis-parse rather than a syntax error.
LESSONS_TAB=$(printf '\t'); LESSONS_NL='
'

# One spelling per repo. Everything here keys on the path as a STRING — the file
# name, and the comparison that decides which runs belong to a repo — so two
# spellings of one checkout are two repos. On macOS that is not hypothetical:
# $TMPDIR hands out /var/folders/… while `pwd -P` and git both answer
# /private/var/folders/…, and a planner asking for one would have read an empty
# file while the traps sat under the other. Canonicalised at every entry point
# instead of trusting callers to agree. A path that no longer exists is returned
# as it came: a checkout that is gone cannot be resolved, and refusing to name
# it would lose its history rather than preserve it.
lessons_canon() {  # $1 = a repo path
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

# The file's name. basename alone would silently merge two checkouts that share
# one (a worktree of the same project, ~/work/api and ~/oss/api), so the path's
# checksum decides identity and the basename is there to keep the directory
# readable. cksum rather than shasum: it is POSIX, always present, and the value
# is an identity, not a security claim.
lessons_slug() {  # $1 = repo path
  local repo
  repo=$(lessons_canon "$1")
  printf '%s-%s\n' "$(basename "$repo")" "$(printf '%s' "$repo" | cksum | awk '{print $1}')"
}

lessons_file() {  # $1 = repo path
  printf '%s/%s.md\n' "$LESSONS_DIR" "$(lessons_slug "$1")"
}

# Which repo a run belongs to. The `repo` file is written by run-task.sh at
# setup and by the janitor's outcome pass, so the answer survives the sweep that
# removes the worktree; the worktree is the fallback for runs that predate both.
# Prints nothing when neither answers — a run that cannot be attributed teaches
# nobody anything, and guessing which repo it belongs to would be worse.
lessons_run_repo() {  # $1 = run dir
  local repo wt gitdir
  if [ -s "$1/repo" ]; then
    repo=$(cat "$1/repo" 2>/dev/null) || repo=""
    [ -n "$repo" ] && { lessons_canon "$repo"; return 0; }
  fi
  wt=$(harness_worktree "$1") || wt=""
  { [ -n "$wt" ] && [ -d "$wt" ]; } || return 0
  gitdir=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  lessons_canon "$(dirname "$gitdir")"
}

# What the world charged for this run's PR, as a weight and a word. A merged PR
# nobody had to touch adds nothing on top of the finding itself; the three
# things that cost somebody time add to it and say so in the rendered file, so a
# reader can see WHY a trap is ranked where it is.
#
# Absent, unreadable or still-open outcomes weigh zero. An outcome the janitor
# has not written yet is not evidence of a clean merge.
lessons_outcome() {  # $1 = run dir; prints "<weight>\t<note>"
  local w=0 note='' o="$1/outcome.json" reverted follow comments
  if [ -s "$o" ]; then
    reverted=$(jq -r '.reverted // false' "$o" 2>/dev/null) || reverted=false
    follow=$(jq -r '.follow_up_commits // 0' "$o" 2>/dev/null) || follow=0
    comments=$(jq -r '.review_comment_count // 0' "$o" 2>/dev/null) || comments=0
    case "$follow" in ''|*[!0-9]*) follow=0 ;; esac
    case "$comments" in ''|*[!0-9]*) comments=0 ;; esac
    if [ "$reverted" = true ]; then w=$((w + 3)); note="reverted"; fi
    if [ "$comments" -ge "$LESSONS_NOISY_COMMENTS" ]; then
      w=$((w + 1)); note="${note:+$note,}argued over"
    fi
    if [ "$follow" -ge 1 ]; then w=$((w + 1)); note="${note:+$note,}patched after merge"; fi
  fi
  printf '%s\t%s\n' "$w" "$note"
}

# A cited path in the one spelling the rest of the harness accepts, or nothing.
# Same policy as the review stage's evidence check (review_evidence_reject):
# a path that is absolute, escapes the tree, or points at orchestration
# metadata is not a fact about this repo's code.
lessons_rel_path() {  # $1 = the reviewer's path; prints a repo-relative path or nothing
  local rel="$1"
  while [ "${rel#./}" != "$rel" ]; do rel=${rel#./}; done
  case "$rel" in
    ''|/*|..|../*|*/..|*/../*|.harness/*) return 0 ;;
  esac
  printf '%s\n' "$rel"
}

# Every confirmed finding this repo's runs produced, one TSV row each:
#   file \t weight \t epoch \t ticket \t note \t claim
#
# Only runs with a non-trivial promoted.json pay for jq at all: an empty array
# is three bytes, and the overwhelming majority of run dirs are either that or
# nothing. `doubted` findings are excluded on purpose — the refuter found those
# plausible and could NOT confirm them, so they are exactly the class this file
# must not turn into a rule.
lessons_rows() {  # $1 = absolute repo path
  local repo="$1" d ts ticket size ow weight note cutoff
  cutoff=$(( $(date +%s) - LESSONS_MAX_AGE * 86400 ))
  for d in "$HARNESS_DIR/runs"/*; do
    [ -d "$d" ] || continue
    [ -f "$d/promoted.json" ] || continue
    size=$(wc -c < "$d/promoted.json" 2>/dev/null | tr -d ' ') || continue
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ "$size" -gt 4 ] || continue                # "[]\n" is three bytes: no findings
    ts=$(harness_mtime "$d/result.json") || ts=""
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    [ "$ts" -ge "$cutoff" ] || continue
    [ "$(lessons_run_repo "$d")" = "$repo" ] || continue
    ticket="${d##*/}"
    weight=0; note=''
    IFS="$LESSONS_TAB" read -r weight note <<EOF || true
$(lessons_outcome "$d")
EOF
    case "$weight" in ''|*[!0-9]*) weight=0 ;; esac
    jq -r --arg ts "$ts" --arg t "$ticket" --arg w "$weight" --arg note "$note" \
          --argjson chars "$LESSONS_CLAIM_CHARS" '
      .[]?
      | select(type == "object")
      | select(.doubted != true)
      | select(((.file // "") | tostring) != "")
      | [ (.file | tostring),
          $w, $ts, $t, $note,
          ((.claim // "") | tostring | gsub("\\s+"; " ")
            | if (. | length) > $chars then ((.[0:$chars] | sub(" +$"; "")) + "…") else . end) ]
      | @tsv' "$d/promoted.json" 2>/dev/null
  done
}

# Rows whose file is still tracked in the repo, in the spelling git knows. This
# is the eviction that keeps the file trustworthy: a trap in a file that was
# deleted or renamed is advice about code nobody can open, and a finding that
# cited a path the reviewer imagined never becomes a rule at all.
lessons_keep_tracked() {  # $1 = repo path; TSV on stdin, filtered TSV on stdout
  local repo="$1" line file rel rest known="$LESSONS_NL"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    file="${line%%"$LESSONS_TAB"*}"; rest="${line#*"$LESSONS_TAB"}"
    rel=$(lessons_rel_path "$file")
    [ -n "$rel" ] || continue
    # Each distinct path is asked about once, however many findings cite it:
    # the answer is memoised in `known` as "\n<verdict>\t<path>\n". No
    # associative array — macOS ships bash 3.2, which has none.
    case "$known" in
      *"${LESSONS_NL}yes${LESSONS_TAB}${rel}${LESSONS_NL}"*) ;;
      *"${LESSONS_NL}no${LESSONS_TAB}${rel}${LESSONS_NL}"*)  continue ;;
      *)
        if git -C "$repo" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
          known="${known}yes${LESSONS_TAB}${rel}${LESSONS_NL}"
        else
          known="${known}no${LESSONS_TAB}${rel}${LESSONS_NL}"
          continue
        fi ;;
    esac
    printf '%s\t%s\n' "$rel" "$rest"
  done
}

# The ranked traps, one TSV row per file:
#   score \t runs \t last-epoch \t notes \t file \t claim [\t claim ...]
#
# Rows arrive newest-first (sorted by the caller) so "the most recent claims"
# is the first LESSONS_MAX_CLAIMS awk sees for a file — awk has no sort worth
# writing here. A run contributes its weight once per file however many findings
# it filed there: one chatty review of one file must not outrank three separate
# runs tripping over it, because recurrence ACROSS runs is the whole signal.
lessons_group() {  # TSV on stdin, ranked TSV on stdout
  awk -F '\t' -v maxc="$LESSONS_MAX_CLAIMS" '
    {
      file = $1; w = $2 + 0; ts = $3 + 0; ticket = $4; note = $5; claim = $6
      seen = file SUBSEP ticket
      if (!(seen in runseen)) {
        runseen[seen] = 1
        score[file] += 1 + w
        runs[file]  += 1
      }
      if (ts > last[file]) last[file] = ts
      if (note != "" && index(SUBSEP notes[file] SUBSEP, SUBSEP note SUBSEP) == 0)
        notes[file] = (notes[file] == "" ? note : notes[file] "," note)
      if (nclaims[file] < maxc && claim != "") {
        claims[file] = claims[file] "\t" claim " (" ticket ")"
        nclaims[file] += 1
      }
      order[file] = 1
    }
    END {
      # "-" rather than "": tab is IFS whitespace, so bash `read` collapses a
      # run of tabs and an empty column would shift every field after it one
      # place left. The renderer reads "-" back as "no note".
      for (f in order)
        printf "%d\t%d\t%d\t%s\t%s%s\n",
          score[f], runs[f], last[f], (notes[f] == "" ? "-" : notes[f]), f, claims[f]
    }'
}

# Rank, evict the anecdotes, cap. Sorting here rather than in awk because the
# ordering is the product: score first, then recency, and a stable tie-break on
# the path so a regeneration that changed nothing produces a byte-identical file.
lessons_rank() {  # ranked TSV on stdin, capped TSV on stdout
  local solo_cutoff
  solo_cutoff=$(( $(date +%s) - LESSONS_SOLO_MAX_AGE * 86400 ))
  awk -F '\t' -v cutoff="$solo_cutoff" '$2 > 1 || $3 >= cutoff' \
    | sort -t "$LESSONS_TAB" -k1,1nr -k3,3nr -k5,5 \
    | head -n "$LESSONS_MAX_ENTRIES"
}

# The file itself. Written only when there is something to say: a repo with no
# confirmed traps has its lessons file REMOVED rather than left as an empty
# heading, so every consumer's "is there anything here" test is `-s` and a fresh
# install behaves exactly as it did before this existed.
lessons_render() {  # $1 = repo path; prints the number of traps written
  local repo out tmp rows n=0
  repo=$(lessons_canon "$1")
  out=$(lessons_file "$repo")
  rows=$(lessons_rows "$repo" \
           | sort -t "$LESSONS_TAB" -k3,3nr \
           | lessons_keep_tracked "$repo" \
           | lessons_group \
           | lessons_rank)
  if [ -z "$rows" ]; then
    rm -f "$out"
    printf '0\n'; return 0
  fi
  mkdir -p "$LESSONS_DIR" || { printf '0\n'; return 1; }
  tmp=$(mktemp "$out.tmp.XXXXXX" 2>/dev/null) || { printf '0\n'; return 1; }
  {
    printf '<!-- generated by lessons.sh — regenerated from run history; edits are overwritten -->\n'
    printf '# Known traps — %s\n\n' "$(basename "$repo")"
    printf '%s\n\n' "Defects past runs of this pipeline wrote in THIS repo and its review stage caught. Every one survived a refutation pass in a session that had not seen the diff, so each is a mistake that was actually made and actually confirmed — not a reviewer's opinion and not a style rule. Ranked by how often it recurred and by what the PR cost after it merged. Read it as a list of places to be careful, never as a list of things to go and change: the brief is still the task."
    while IFS=$'\t' read -r score runs last notes file claims; do
      : "$score"
      n=$((n + 1))
      printf -- '- `%s` — %s run%s, last %s%s\n' \
        "$file" "$runs" "$([ "$runs" = 1 ] || echo s)" \
        "$(lessons_day "$last")" "$([ "$notes" = - ] || printf ', %s' "$notes")"
      printf '%s\n' "$claims" | tr '\t' '\n' | while IFS= read -r c; do
        [ -n "$c" ] && printf -- '  - %s\n' "$c"
      done
    done <<EOF
$rows
EOF
  } > "$tmp" 2>/dev/null && mv "$tmp" "$out" || { rm -f "$tmp"; printf '0\n'; return 1; }
  printf '%s\n' "$n"
}

lessons_day() {  # $1 = epoch; prints YYYY-MM-DD
  date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d 2>/dev/null || printf 'unknown'
}

# Every repo the run history can attribute a run to, one per line. Repos whose
# checkout is gone are dropped: the tracked-file eviction cannot run without
# one, and a lessons file nothing can verify is worse than none.
lessons_repos() {
  local d repo
  for d in "$HARNESS_DIR/runs"/*; do
    [ -d "$d" ] || continue
    repo=$(lessons_run_repo "$d")
    [ -n "$repo" ] && [ -e "$repo/.git" ] && printf '%s\n' "$repo"
  done | sort -u
}

# The daily pass. Never fails its caller: this is a read-only distillation of
# files that are already on disk, and nothing it can hit is worth failing a
# janitor sweep or a dispatch over.
lessons_refresh_all() {  # prints "<repos> <traps>"
  local repo n repos=0 traps=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    n=$(lessons_render "$repo" 2>/dev/null) || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    repos=$((repos + 1)); traps=$((traps + n))
  done <<EOF
$(lessons_repos)
EOF
  printf '%s %s\n' "$repos" "$traps"
}

# The just-in-time refresh a dispatch makes when nobody has installed the
# janitor: at most once every LESSONS_STALE_HOURS per repo, so the common case
# costs one stat. Returns 0 always.
lessons_refresh_if_stale() {  # $1 = absolute repo path
  local out mt age
  out=$(lessons_file "$1")
  mt=$(harness_mtime "$out") || mt=""
  case "$mt" in ''|*[!0-9]*) mt="" ;; esac   # a mtime nobody could read is not "fresh"
  if [ -n "$mt" ]; then
    age=$(( $(date +%s) - mt ))
    [ "$age" -lt $(( LESSONS_STALE_HOURS * 3600 )) ] && return 0
  fi
  lessons_render "$1" >/dev/null 2>&1 || true
  return 0
}
