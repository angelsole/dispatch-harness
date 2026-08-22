#!/usr/bin/env bash
# Tabulate per-run metrics from every result.json under the runs directory.
#
# Usage: metrics.sh           aligned table, one row per run (default)
#        metrics.sh --csv     the same data as CSV for spreadsheets / stats tools
#        metrics.sh --report  aggregate health picture across all runs
#
# Columns: run, arm, implementer model/effort, reviewer model/effort, status,
#          gate rounds (e.g. fail,pass), implementer/reviewer commit counts,
#          +/- lines vs base, wall minutes, verifier score.
#
# Runs predating a field — the metrics instrumentation (result.json without a
# `metrics` object) or the model/effort knobs — render with blanks, never
# errors: every field falls back with jq's //.
set -u
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" \
  || { echo "FATAL: cannot read lib/common.sh beside $0 — re-run install.sh" >&2; exit 1; }
RUNS="$HARNESS_DIR/runs"

usage() { echo "usage: metrics.sh [--csv|--report]" >&2; }

CSV=0; REPORT=0
case "${1:-}" in
  --csv)      CSV=1 ;;
  --report)   REPORT=1 ;;
  -h|--help)  usage; exit 0 ;;
  "")         ;;
  *)          echo "unknown option: $1" >&2; usage; exit 2 ;;
esac

[ -d "$RUNS" ] || { echo "no runs yet" >&2; exit 0; }

# --- --report: the aggregate picture ------------------------------------------
# Everything below reads result.json files and nothing else — no logs, no run
# dirs, no network — so the report works on a mirrored runs directory and on runs
# whose worktrees are long cleaned up. Numbers a run never recorded are dropped
# from their statistic (and the N column says how many runs backed it) rather
# than counted as zero, which is how a partial history stays honest.
#
# One field per line again, tab-joined by jq's @tsv: awk does the statistics
# because medians need sorting and jq cannot align a column.
REPORT_FILTER='
  [ (.status // "-"),
    (.arm // "-"),
    (.review // ""),
    ((.metrics.turn_resumes
      // ((.metrics.stage_durations // {}) | [keys[] | select(startswith("resuming"))] | length)
      | tostring)),
    ((.metrics.wall_seconds // "") | tostring),
    ((.metrics.implementer_num_turns // "") | tostring),
    ((.metrics.implementer_usage.output_tokens // "") | tostring),
    (((.metrics.gate_rounds // [])
      | map(select((.round // "") | tostring | test("^[0-9]+$"))) | length) | tostring),
    (((.metrics.gate_rounds // []) | map(.seconds // 0) | add // 0) | tostring),
    (((.worktree // "") | split("/") | last // "") as $leaf
      | ((.ticket // "") | ascii_downcase) as $t
      | if ($t | length) > 0 and ($leaf | endswith("-" + $t))
        then $leaf[0:(($leaf | length) - ($t | length) - 1)] else $leaf end),
    (.review_account // ""),
    # Per-round verdicts, so the report can say which round FAILED rather than
    # how many rounds ran — a run needing round 2 is the design, not a retry.
    (((.metrics.gate_rounds // [])
      | map(select((.round // "") | tostring | test("^[0-9]+$")))
      | map(((.round // "") | tostring) + ":" + (.result // "")) | join(","))),
    # Attempts: the ledger when the run recorded one, the count when it only
    # recorded that, and 1 for everything older — every run is at least one.
    (((.attempts_total // 0) as $t
      | if $t > 0 then $t
        else (((.metrics.attempts // []) | length) as $l | if $l > 0 then $l else 1 end)
        end) | tostring),
    ((.metrics.self_resumes // 0) | tostring),
    ((.metrics.implementer_max_turns // "") | tostring),
    # The advisory trajectory score from the verifier stage. Empty on every run
    # it did not score, which keeps those runs out of the statistic rather than
    # sinking it with zeros they never earned.
    ((.metrics.verifier.score // "") | tostring)
  ] | @tsv'

# One line per attempt of every run: the status it died on, and the idle gap
# between the attempt before it ending and this one starting. A run with no
# ledger (everything before this telemetry) still counts as the one attempt its
# result.json describes, so the corpus stays whole.
ATTEMPTS_FILTER='(.metrics.attempts // []) as $a
  | (if ($a | length) == 0 then [[(.status // "-"), ""]]
     else [range(0; $a | length) as $i
       | [($a[$i].status // "-"),
          (if $i == 0 then ""
           else (($a[$i].started // 0) - ($a[$i - 1].ended // 0)) end)]]
     end)
  | .[] | @tsv'

# The failing step of every failed gate round, most frequent first: the whole
# point of the telemetry is to say what to fix first.
FAILED_STEP_FILTER='(.metrics.gate_rounds // [])[]
  | select(.result == "fail") | (.failed_step // "") | select(. != "")'

report() {
  local files=() f rows steps attempts
  for f in "$RUNS"/*/result.json; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || { echo "(no result.json files under $RUNS)" >&2; return 0; }

  rows=$(jq -r "$REPORT_FILTER" "${files[@]}" 2>/dev/null)
  steps=$(jq -r "$FAILED_STEP_FILTER" "${files[@]}" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10)
  attempts=$(jq -r "$ATTEMPTS_FILTER" "${files[@]}" 2>/dev/null)

  # ENVIRON, not -v: awk expands escape sequences in a -v value, and a gate
  # command is free to contain a backslash.
  STEPS="$steps" ATTEMPTS="$attempts" \
  awk -F'\t' -v runs="$RUNS" -v stamp="$(date '+%Y-%m-%d %H:%M')" '
    function isort(a, n,   i, j, v) {
      for (i = 2; i <= n; i++) {
        v = a[i]; j = i - 1
        while (j >= 1 && a[j] > v) { a[j + 1] = a[j]; j-- }
        a[j + 1] = v
      }
    }
    # Nearest-rank percentile on the sorted values — no interpolation, so every
    # number printed is a number some run actually recorded.
    function pctl(a, n, p,   idx) {
      if (n == 0) return 0
      isort(a, n)
      idx = int(p * (n - 1) / 100 + 0.5) + 1
      if (idx < 1) idx = 1
      if (idx > n) idx = n
      return a[idx]
    }
    # `dec` is how many decimals the value deserves: 0 for counts, 1 for
    # minutes, 2 for a score that lives entirely between 0 and 1 and would lose
    # most of what it says at one.
    function statline(label, a, n, dec) {
      if (n == 0) { printf "%-16s %10s %9s %6d\n", label, "-", "-", 0; return }
      if (dec) printf "%-16s %10.*f %9.*f %6d\n", label, dec, pctl(a, n, 50), dec, pctl(a, n, 90), n
      else     printf "%-16s %10d %9d %6d\n", label, pctl(a, n, 50), pctl(a, n, 90), n
    }
    # Keys of an associative array, by descending count then name.
    function bycount(a, keys,   n, k, i, j, t) {
      n = 0
      for (k in a) keys[++n] = k
      for (i = 2; i <= n; i++) {
        t = keys[i]; j = i - 1
        while (j >= 1 && (a[keys[j]] < a[t] || (a[keys[j]] == a[t] && keys[j] > t))) {
          keys[j + 1] = keys[j]; j--
        }
        keys[j + 1] = t
      }
      return n
    }
    function share(label, count, total) { printf "%-22s %6d %6.1f\n", label, count, 100 * count / total }
    {
      total++
      status[$1]++
      arm[$2]++
      # A run whose result.json predates the review telemetry never recorded the
      # field at all. That is not "the stage was not reached" — 28 of them were
      # perfectly good reviews — so it is labelled for what it is.
      review[$3 == "" ? "pre-telemetry" : $3]++
      if ($4 + 0 > 0) { resumed++; resumes += $4 }
      if ($5 != "") wall[++nwall] = $5 / 60
      if ($6 != "") turns[++nturns] = $6 + 0
      if ($7 != "") tok[++ntok] = $7 + 0
      if ($8 + 0 > 0) nrounds++
      if ($9 + 0 > 0) gsec[++ngsec] = $9 + 0
      if ($10 != "") {
        repo[$10]++
        if ($5 != "") rwall[$10, ++rwn[$10]] = $5 / 60
        if ($6 != "") rturns[$10, ++rtn[$10]] = $6 + 0
        if ($1 == "ready") rready[$10]++
      }
      if ($11 == "fallback") fallback_reviews++
      # The classification, not the account label: review_account is set the
      # moment the Claude tier is ENTERED, so keying off it counted an attempt
      # that produced nothing (review_failed) as a claude-tier review. Only
      # `reviewed_claude` means a Claude session actually reviewed the diff.
      if ($3 == "reviewed_claude") claude_reviews++
      if ($1 == "review_failed")   held_unreviewed++
      # Which rounds ran, and which of them failed.
      if ($12 != "") {
        nv = split($12, vs, ",")
        for (v = 1; v <= nv; v++) {
          split(vs[v], rv, ":")
          r = rv[1] + 0
          # A skipped row records an honest pipeline decision, not a gate
          # execution. Keep it in result.json/the per-run table, but leave it
          # out of this report denominator, which is explicitly the runs
          # that actually ran round N.
          if (r <= 0 || rv[2] == "skipped") continue
          ran[r]++
          if (rv[2] == "fail") gfail[r]++
          if (r > maxround) maxround = r
        }
      }
      if ($13 + 0 > 0) atts[++natts] = $13 + 0
      selfres += $14 + 0
      # The CLI reports num_turns for the whole conversation; --max-turns bounds
      # the worker turns of one invocation. They are different counts, and runs
      # above their own ceiling are how you see that rather than guess at it.
      if ($15 != "" && $6 != "") {
        nceil++
        if ($6 + 0 > $15 + 0) overceil++
      }
      if ($16 != "") vscore[++nvs] = $16 + 0
    }
    END {
      printf "pipeline vitals · %d runs · %s\n%s\n", total, stamp, runs

      printf "\n%-22s %6s %6s\n", "STATUS", "RUNS", "%"
      n = bycount(status, k)
      for (i = 1; i <= n; i++) share(k[i], status[k[i]], total)
      delete k
      # result.json only ever describes the attempt that wrote it, so this is a
      # last-attempt number and says so. The attempt-level rate — the one that
      # counts what the machine actually spent — is in the ATTEMPTS block below.
      printf "%-38s %6d %6.1f\n", "runs reaching ready (last attempt)", \
        status["ready"] + 0, 100 * (status["ready"] + 0) / total

      printf "\n%-22s %6s %6s\n", "ARM", "RUNS", "%"
      n = bycount(arm, k)
      for (i = 1; i <= n; i++) share(k[i], arm[k[i]], total)
      delete k

      printf "\n%-22s %6s %6s\n", "REVIEW", "RUNS", "%"
      n = bycount(review, k)
      for (i = 1; i <= n; i++) share(k[i], review[k[i]], total)
      delete k
      printf "%-22s %6d%s\n", "silent review failures", review["failed_silent"] + 0, \
        (review["failed_silent"] + 0 > 0 ? "   <- these diffs are UNREVIEWED" : "")
      # Reviews the primary Codex account could not take. Zero is the normal
      # number, so any other one is the line that says "top the account up".
      printf "%-22s %6d%s\n", "fallback-account reviews", fallback_reviews + 0, \
        (fallback_reviews + 0 > 0 ? "   <- the primary Codex account needs topping up" : "")
      # The tier past the Codex side: still a review, but same-vendor as the
      # implementer — any number here says the Codex side needs attention (or
      # that these runs were dispatched from a machine without the codex CLI).
      printf "%-22s %6d%s\n", "claude-tier reviews", claude_reviews + 0, \
        (claude_reviews + 0 > 0 ? "   <- the review was not cross-vendor" : "")
      # And the runs where no tier produced anything: held before the PR, which
      # is the whole point — but held work is work nobody is looking at.
      printf "%-22s %6d%s\n", "held: review_failed", held_unreviewed + 0, \
        (held_unreviewed + 0 > 0 ? "   <- no PR opened; re-dispatch once a reviewer works" : "")

      # --- Attempts: what the machine actually spent ------------------------
      # A run is a ticket; an attempt is one dispatch of it. Run-level success
      # counts only the last attempt, which is why 95.5% of runs could read
      # ready while barely half the attempts ever did.
      na = split(ENVIRON["ATTEMPTS"], al, "\n")
      nattempts = 0; aready = 0; ngap = 0
      for (i = 1; i <= na; i++) {
        if (al[i] !~ /[^ \t]/) continue
        split(al[i], af, "\t")
        nattempts++
        if (af[1] == "ready") aready++
        else deaths[af[1]]++
        if (af[2] != "") gaps[++ngap] = af[2] / 60
      }
      printf "\n%-22s %6s %6s\n", "ATTEMPTS", "COUNT", "%"
      printf "%-22s %6d\n", "attempts total", nattempts
      if (nattempts > 0)
        printf "%-22s %6d %6.1f\n", "reaching ready", aready, 100 * aready / nattempts
      printf "%-22s %6d%s\n", "capacity self-resumes", selfres + 0, \
        (selfres + 0 > 0 ? "   <- deaths the run recovered from on its own" : "")

      printf "\n%-22s %6s %6s\n", "ATTEMPT DEATHS", "COUNT", "%"
      n = bycount(deaths, k)
      if (n == 0) print "(none — every attempt reached ready)"
      for (i = 1; i <= n; i++) share(k[i], deaths[k[i]], nattempts)
      delete k

      printf "\n%-16s %10s %9s %6s\n", "PER RUN", "MEDIAN", "P90", "N"
      statline("attempts", atts, natts, 1)
      statline("idle gap mins", gaps, ngap, 1)
      statline("turns", turns, nturns, 0)
      statline("wall minutes", wall, nwall, 1)
      statline("output tokens", tok, ntok, 0)
      statline("gate seconds", gsec, ngsec, 0)
      # How well the runs satisfied their briefs, as a third vendor read them.
      # N is how many runs the verifier scored at all — the rest are absent from
      # this line rather than counted as zero.
      statline("verify score", vscore, nvs, 2)
      # The CLI and the ceiling do not count the same thing, and pretending they
      # do turned two honest runs into a phantom "206 turns against a 200 cap".
      if (nceil + 0 > 0)
        printf "%-16s %d of %d runs report more CLI turns than their pinned ceiling\n", \
          "turns vs cap", overceil + 0, nceil

      # Numbered rounds only — base-sync re-gates are recorded in result.json but
      # are not part of the review loop. A second round is the design (review,
      # then re-gate), so counting rounds made the norm look like a 88.6% retry
      # rate. What a reader can act on is which round FAILED, over the runs that
      # got as far as running it.
      printf "\n%-22s %6s %6s\n", "GATE FAILURES", "FAILED", "%"
      if (nrounds == 0) {
        print "(none recorded yet)"
      } else {
        for (r = 1; r <= maxround; r++) {
          if (!ran[r]) continue
          printf "%-22s %6d %6.1f\n", "round " r, gfail[r] + 0, \
            100 * (gfail[r] + 0) / ran[r]
        }
      }

      printf "\n%-30s %6s\n", "FAILED GATE STEP", "ROUNDS"
      ns = split(ENVIRON["STEPS"], sl, "\n")
      shown = 0
      for (i = 1; i <= ns; i++) {
        if (sl[i] !~ /[^ \t]/) continue
        c = sl[i]; sub(/^[ \t]*/, "", c); sub(/[ \t].*$/, "", c)      # the count
        s = sl[i]; sub(/^[ \t]*[0-9]+[ \t]/, "", s)                   # the command
        printf "%-30.30s %6d\n", s, c
        shown++
      }
      if (shown == 0) print "(none recorded yet — pre-telemetry runs record no failed_step)"

      printf "\n%-22s %d of %d runs resumed (%.1f%%) · %d resumes total\n", "RESUMES", \
        resumed + 0, total, 100 * (resumed + 0) / total, resumes + 0

      printf "\n%-22s %6s %8s %10s %7s\n", "REPO", "RUNS", "MED_MIN", "MED_TURNS", "READY%"
      n = bycount(repo, k)
      for (i = 1; i <= n; i++) {
        r = k[i]
        delete tw; delete tt
        for (j = 1; j <= rwn[r] + 0; j++) tw[j] = rwall[r, j]
        for (j = 1; j <= rtn[r] + 0; j++) tt[j] = rturns[r, j]
        printf "%-22s %6d %8.1f %10d %7.1f\n", r, repo[r], \
          pctl(tw, rwn[r] + 0, 50), pctl(tt, rtn[r] + 0, 50), 100 * (rready[r] + 0) / repo[r]
      }
    }
  ' <<EOF
$rows
EOF
}

if [ "$REPORT" = 1 ]; then
  report
  exit 0
fi

# Emit the thirteen data fields one per line (blank when absent). Splitting on
# newlines keeps empty fields intact and needs no delimiter char; every element
# is coerced to a string so `-r` prints it raw. Missing `metrics` (old runs)
# falls through jq's // to empty, so those rows render blank instead of erroring.
ROW_FILTER='
  (.arm // ""),
  (.implementer_model // ""),
  (.implementer_effort // ""),
  (.reviewer_model // ""),
  (.reviewer_effort // ""),
  (.status // ""),
  ((.metrics.gate_rounds // []) | map(.result) | join(",")),
  (.metrics.opus_commits // "" | tostring),
  (.metrics.codex_commits // "" | tostring),
  (.metrics.diff.insertions // "" | tostring),
  (.metrics.diff.deletions // "" | tostring),
  (.metrics.wall_seconds // "" | tostring),
  (.metrics.verifier.score // "" | tostring)'

# Model/effort columns are sized for the explicit model IDs an ablation
# actually sweeps (claude-sonnet-5 = 15, gpt-5.6-sol = 11) and the longest
# effort value (medium = 6). Longer values just push the row right, as before.
TABLE_FMT='%-26s %-9s %-15s %-6s %-11s %-6s %-13s %-11s %5s %5s %6s %6s %8s %5s\n'

if [ "$CSV" = 1 ]; then
  echo "run,arm,model,implementer_effort,reviewer_model,reviewer_effort,status,gate_rounds,opus_commits,codex_commits,insertions,deletions,wall_minutes,score"
else
  # shellcheck disable=SC2059
  printf "$TABLE_FMT" RUN ARM MODEL EFFORT R-MODEL R-EFF STATUS GATE OPUS CODEX +LN -LN WALL_MIN SCORE
fi

found=0
for f in "$RUNS"/*/result.json; do
  [ -f "$f" ] || continue
  found=1
  run=$(basename "$(dirname "$f")")
  rowdata=$(jq -r "$ROW_FILTER" "$f" 2>/dev/null) || rowdata=""
  { read -r arm; read -r model; read -r ieff; read -r rmodel; read -r reff
    read -r status; read -r gates
    read -r oc; read -r cc; read -r ins; read -r del; read -r wall; read -r score
  } <<EOF
$rowdata
EOF
  wall_min=$(awk -v s="$wall" 'BEGIN{ if (s == "") print ""; else printf "%.1f", s/60 }')
  if [ "$CSV" = 1 ]; then
    # gate_rounds is the only field that can contain a comma — quote it.
    printf '%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s\n' \
      "$run" "$arm" "$model" "$ieff" "$rmodel" "$reff" "$status" \
      "$gates" "$oc" "$cc" "$ins" "$del" "$wall_min" "$score"
  else
    # shellcheck disable=SC2059
    printf "$TABLE_FMT" "$run" "${arm:--}" "${model:--}" "${ieff:--}" \
      "${rmodel:--}" "${reff:--}" "${status:--}" \
      "${gates:--}" "${oc:--}" "${cc:--}" "${ins:--}" "${del:--}" "${wall_min:--}" \
      "${score:--}"
  fi
done

[ "$found" = 1 ] || echo "(no result.json files under $RUNS)" >&2
