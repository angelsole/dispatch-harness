# shellcheck shell=bash
# Does this branch's green gate mean anything?
#
# Sourced by run-task.sh between the implementer's gate round and the review
# stage. Deterministic — no model, nothing sampled — and best-effort in the
# strongest sense: every failure degrades to `not_run`, no path here can change
# a status, a gate verdict or the PR decision, and every finding is a FLAG the
# reviewer is handed as a hint rather than a judgement anything acts on.
#
# Two halves, both cheap and both shallow:
#
#   A. Replay. The test files this branch adds or changes are run against the
#      UNPATCHED base tree in a scratch worktree. A test that passes there is
#      non-discriminating: whatever it asserts, it cannot have caught the change
#      it travels with. (Measured at 46% of the tests coding agents write to
#      validate their own fix.)
#   B. Structural. The diff is read for the signatures of a gate made green
#      rather than earned: deleted test files, assertions removed from tests,
#      skip/only markers introduced, CI/lint/coverage config edited without the
#      brief asking, and expected values echoed out of the source the test is
#      supposed to be checking.
#
# Both halves are heuristics with false positives and false negatives, which is
# why this iteration only flags. The reviewer's anti-gaming checklist keeps its
# full force; this gives it evidence to start from.
#
# Knobs, all optional:
#   HARNESS_GATE_INTEGRITY               0 disables the stage entirely       (1)
#   HARNESS_GATE_INTEGRITY_TIMEOUT       seconds for the whole replay half (300)
#   HARNESS_GATE_INTEGRITY_FILE_TIMEOUT  seconds for one replayed file     (120)
#   HARNESS_GATE_INTEGRITY_MAX_FILES     most test files replayed           (10)
#
# Self-contained on purpose: it declares everything it needs rather than
# assuming a shared library is already loaded, so sourcing it is one line
# wherever it is wanted.

# A malformed or all-zero value is one nobody can act on, and timeout(1) reads
# zero as "no cap at all" — the opposite of this file's contract.
gate_integrity_positive() {  # $1 = value, $2 = fallback
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *[1-9]*)     printf '%s' "$1" ;;
    *)           printf '%s' "$2" ;;
  esac
}
GATE_INTEGRITY_TIMEOUT=$(gate_integrity_positive "${HARNESS_GATE_INTEGRITY_TIMEOUT:-}" 300)
GATE_INTEGRITY_FILE_TIMEOUT=$(gate_integrity_positive "${HARNESS_GATE_INTEGRITY_FILE_TIMEOUT:-}" 120)
GATE_INTEGRITY_MAX_FILES=$(gate_integrity_positive "${HARNESS_GATE_INTEGRITY_MAX_FILES:-}" 10)
GATE_INTEGRITY_MAX_LITERALS=5

# What counts as a test file. Path-shaped rather than content-shaped, and
# deliberately narrow at the edges: `src/latest/x.js` is not a test, so every
# filename branch requires a separator in front of `test`/`spec`.
GATE_INTEGRITY_TEST_RE='(^|/)(tests?|specs?|__tests__|__specs__)/|(^|/)(conftest\.py|test_[^/]+|[^/]+[._-](tests?|specs?)\.[^/.]+)$'

# Config whose whole purpose is to decide what passes. Any edit is worth naming.
GATE_INTEGRITY_CI_RE='(^|/)\.github/workflows/|(^|/)\.gitlab-ci\.ya?ml$|(^|/)(\.eslintrc|eslint\.config)|(^|/)\.?ruff\.toml$|(^|/)(pytest\.ini|tox\.ini|\.flake8|\.coveragerc|codecov\.ya?ml|sonar-project\.properties|\.pre-commit-config\.ya?ml|biome\.jsonc?|\.golangci\.ya?ml|\.mocharc[^/]*)$|(^|/)(jest|vitest|karma|playwright|cypress)\.config\.[^/]+$'
# Files that are mostly something else and only sometimes the gate's rulebook:
# judged on what the hunk touches, not on being touched at all.
GATE_INTEGRITY_CI_MAYBE_RE='(^|/)(pyproject\.toml|setup\.cfg|package\.json|Makefile|justfile)$'
GATE_INTEGRITY_CI_HUNK_RE='(cov-fail-under|fail_under|--cov|coverage|addopts|testpaths|"test"|"lint"|eslint|ruff|flake8|jest|vitest|pytest|mocha)'

# The caller's cap when it has one (run-task.sh defines with_timeout), an
# equivalent when it does not. Deliberately not named with_timeout: another
# library may own that name, and sourcing order must not decide whose wins.
gate_integrity_capped() {  # $1 = seconds, rest = command + args
  if declare -F with_timeout >/dev/null 2>&1; then
    with_timeout "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$@"
  fi
}

gate_integrity_is_test_path() {  # $1 = repo-relative path
  printf '%s\n' "$1" | grep -qEi -- "$GATE_INTEGRITY_TEST_RE" && return 0
  # JVM and frontend suites commonly use FooTest.java / WidgetTest.tsx without
  # putting the file under a test directory.
  printf '%s\n' "$1" | grep -qE '(^|/)([^/]+Tests?|Test[^/]*)\.[^/.]+$'
}

# A config edit the brief asked for is not a finding. Literal and cheap: the
# path or its basename appearing anywhere in the brief is enough to stay quiet.
gate_integrity_brief_mentions() {  # $1 = brief path, $2 = repo-relative path
  [ -n "$1" ] && [ -f "$1" ] || return 1
  grep -qiF -- "$2" "$1" && return 0
  grep -qiF -- "$(basename "$2")" "$1"
}

# One flag: kind, file, and the detail a reviewer needs to go and find it.
gate_integrity_flag() {  # $1 = kind, $2 = file, $3 = detail, $4 = flags file
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$4"
}

gate_integrity_json_list() {  # $1 = file of lines; echoes a JSON array
  local j
  [ -f "$1" ] || { printf '[]'; return 0; }
  j=$(jq -R -s 'split("\n") | map(select(length > 0))' < "$1" 2>/dev/null) || j='[]'
  [ -n "$j" ] || j='[]'
  printf '%s' "$j"
}

gate_integrity_write_json() {  # $1 = out, $2 = base, $3 = head, $4 = status, $5 = reason, $6 = runner, $7 = work dir, $8 = flags file
  local out="$1" work="$7" disc nond notrun fl
  disc=$(gate_integrity_json_list "$work/discriminating")
  nond=$(gate_integrity_json_list "$work/non_discriminating")
  notrun=$(gate_integrity_json_list "$work/not_run")
  fl=$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
        | {kind: .[0], file: .[1], detail: (.[2] // "")})' < "$8" 2>/dev/null) || fl='[]'
  [ -n "$fl" ] || fl='[]'
  jq -n --arg base "$2" --arg head "$3" --arg status "$4" --arg reason "$5" \
        --arg runner "$6" --argjson disc "$disc" --argjson nond "$nond" \
        --argjson notrun "$notrun" --argjson flags "$fl" \
    '{base: $base, head: $head,
      replay: {status: $status, reason: $reason, runner: $runner,
               discriminating: ($disc | length),
               non_discriminating: ($nond | length),
               not_run: ($notrun | length),
               files: {discriminating: $disc, non_discriminating: $nond, not_run: $notrun}},
      flags: $flags, flag_count: ($flags | length)}' > "$out.tmp" 2>/dev/null \
    && mv "$out.tmp" "$out"
  rm -f "$out.tmp"
}

# Which scoped runner this repo has, if any. Detection is a probe, not a guess:
# a runner that would fail for its own reasons (pytest not installed, no test
# script) has to degrade to `not_run`, because the alternative reading — every
# replayed file "fails on base" — is the one that hides a non-discriminating
# test instead of surfacing it.
gate_integrity_runner() {  # $1 = tree, $2 = probe cap, $3 = test path; echoes a runner tag
  case "$3" in
    *.py)
      if command -v python3 >/dev/null 2>&1 \
         && ( cd "$1" 2>/dev/null \
              && gate_integrity_capped "$2" python3 -m pytest --version ) >/dev/null 2>&1; then
        printf 'pytest\n'; return 0
      fi
      return 1 ;;
  esac
  if [ -f "$1/package.json" ] \
     && grep -q '"test"[[:space:]]*:' "$1/package.json" 2>/dev/null; then
    if [ -f "$1/yarn.lock" ]; then
      command -v yarn >/dev/null 2>&1 || return 1
      printf 'yarn\n'; return 0
    fi
    if [ -f "$1/package-lock.json" ]; then
      command -v npm >/dev/null 2>&1 || return 1
      printf 'npm\n'; return 0
    fi
    if command -v npm >/dev/null 2>&1; then printf 'npm\n'; return 0; fi
    if command -v yarn >/dev/null 2>&1; then printf 'yarn\n'; return 0; fi
  fi
  if [ -x "$1/node_modules/.bin/vitest" ]; then printf 'vitest\n'; return 0; fi
  if [ -x "$1/node_modules/.bin/jest" ];   then printf 'jest\n';   return 0; fi
  return 1
}

# One test file against the tree it was copied into. stdin is closed for the
# reason every other child in this pipeline closes it: a watch-mode runner that
# inherits a live pipe waits on it forever.
gate_integrity_run_one() {  # $1 = tree, $2 = runner, $3 = file, $4 = cap; returns the runner's rc
  local t="$4"
  case "$2" in
    vitest) ( cd "$1" && gate_integrity_capped "$t" env CI=1 \
                node_modules/.bin/vitest run "$3" ) </dev/null ;;
    jest)   ( cd "$1" && gate_integrity_capped "$t" env CI=1 \
                node_modules/.bin/jest --runTestsByPath "$3" ) </dev/null ;;
    npm)    ( cd "$1" && gate_integrity_capped "$t" env CI=1 \
                npm test --silent -- "$3" ) </dev/null ;;
    yarn)   ( cd "$1" && gate_integrity_capped "$t" env CI=1 \
                yarn test --silent "$3" ) </dev/null ;;
    pytest) ( cd "$1" && gate_integrity_capped "$t" env CI=1 \
                python3 -m pytest -q "$3" ) </dev/null ;;
    *)      return 127 ;;
  esac
}

gate_integrity_runner_infra() {  # $1 = runner, $2 = rc, $3 = captured output
  case "$1:$2" in
    pytest:2|pytest:3|pytest:4|pytest:5) return 0 ;;
  esac
  case "$1" in
    jest|vitest)
      grep -qiE 'no tests? (found|matched)|no test files? found|no test suite' "$3" ;;
    npm|yarn)
      grep -qiE 'missing script:?[[:space:]]*"?test|no test specified|command not found' "$3" ;;
    *) return 1 ;;
  esac
}

# Half A. Writes the three per-file lists into $4 and echoes one tab-separated
# "<status> <reason> <runner>" line.
gate_integrity_replay() {  # $1 = worktree, $2 = base sha, $3 = test list, $4 = out dir, $5 = log
  local wt="$1" base="$2" list="$3" out="$4" log="$5"
  local scratch tree runner="" file_runner runner_out n=0 rc deadline remaining cap reason="" first_fail="" f
  : > "$out/discriminating"; : > "$out/non_discriminating"; : > "$out/not_run"

  if [ ! -s "$list" ]; then
    printf 'ok\t%s\t\n' "no new or changed test files on this branch"; return 0
  fi
  deadline=$(( $(date +%s) + GATE_INTEGRITY_TIMEOUT ))
  if ! scratch=$(mktemp -d "${TMPDIR:-/tmp}/gate-integrity.XXXXXX" 2>/dev/null); then
    cat "$list" >> "$out/not_run"
    printf 'not_run\t%s\t%s\n' "no scratch directory could be created" "$runner"
    return 0
  fi
  tree="$scratch/base"
  remaining=$(( deadline - $(date +%s) ))
  [ "$remaining" -gt 0 ] || remaining=1
  cap=120; [ "$remaining" -lt "$cap" ] && cap="$remaining"
  if ! gate_integrity_capped "$cap" \
        git -C "$wt" worktree add --detach --quiet "$tree" "$base" >> "$log" 2>&1; then
    rm -rf "$scratch"
    cat "$list" >> "$out/not_run"
    printf 'not_run\t%s\t%s\n' \
      "a scratch worktree at the base commit could not be created" "$runner"
    return 0
  fi
  # The base tree has no dependencies of its own and installing them would cost
  # more than this whole stage. The link is the compromise: node resolves
  # through it, and the code under test is still the base tree's.
  if [ -d "$wt/node_modules" ] && [ ! -e "$tree/node_modules" ]; then
    ln -s "$wt/node_modules" "$tree/node_modules" 2>/dev/null || true
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$GATE_INTEGRITY_MAX_FILES" ]; then
      printf '%s\n' "$f" >> "$out/not_run"
      reason="only the first $GATE_INTEGRITY_MAX_FILES test files were replayed"
      continue
    fi
    remaining=$(( deadline - $(date +%s) ))
    if [ "$remaining" -le 0 ]; then
      printf '%s\n' "$f" >> "$out/not_run"
      reason="the replay ran out of its ${GATE_INTEGRITY_TIMEOUT}s budget"
      continue
    fi
    if [ -L "$wt/$f" ]; then
      printf '%s\n' "$f" >> "$out/not_run"
      [ -n "$first_fail" ] || first_fail="a changed test path was a symbolic link"
      continue
    fi
    mkdir -p "$tree/$(dirname "$f")" 2>/dev/null
    if ! cp "$wt/$f" "$tree/$f" 2>/dev/null; then
      printf '%s\n' "$f" >> "$out/not_run"
      [ -n "$first_fail" ] \
        || first_fail="a changed test file could not be copied into the base tree"
      continue
    fi
    # Detect per file inside the base checkout. This keeps mixed Python/JS
    # repositories honest, and a test script added only by the patch cannot
    # manufacture a "test failure on base" where the base had no such script.
    cap=60; [ "$remaining" -lt "$cap" ] && cap="$remaining"
    file_runner=$(gate_integrity_runner "$tree" "$cap" "$f" || true)
    if [ -z "$file_runner" ]; then
      printf '%s\n' "$f" >> "$out/not_run"
      [ -n "$first_fail" ] || first_fail="no scoped test runner was detected on the base tree"
      continue
    fi
    if [ -z "$runner" ]; then runner="$file_runner"
    elif [ "$runner" != "$file_runner" ]; then runner=mixed
    fi
    remaining=$(( deadline - $(date +%s) ))
    if [ "$remaining" -le 0 ]; then
      printf '%s\n' "$f" >> "$out/not_run"
      reason="the replay ran out of its ${GATE_INTEGRITY_TIMEOUT}s budget"
      continue
    fi
    printf '=== %s ===\n' "$f" >> "$log"
    cap="$GATE_INTEGRITY_FILE_TIMEOUT"
    [ "$remaining" -lt "$cap" ] && cap="$remaining"
    runner_out="$out/runner-output"
    gate_integrity_run_one "$tree" "$file_runner" "$f" "$cap" > "$runner_out" 2>&1
    rc=$?
    cat "$runner_out" >> "$log"
    printf '(exit %s)\n' "$rc" >> "$log"
    # Exit code first, output second. The infra classifier reads what the runner
    # printed, so consulting it before the timeout and signal codes would make
    # the reason a race against how far a killed runner got.
    case "$rc" in
      0)
        printf '%s\n' "$f" >> "$out/non_discriminating"
        continue ;;
      124|142|137|143)
        printf '%s\n' "$f" >> "$out/not_run"
        [ -n "$first_fail" ] || first_fail="the runner outlived its ${cap}s cap"
        continue ;;
      *)
        # Anything above 128 is a signal, not a verdict a test runner reached.
        if [ "$rc" -gt 128 ]; then
          printf '%s\n' "$f" >> "$out/not_run"
          [ -n "$first_fail" ] || first_fail="the runner was killed (exit $rc)"
          continue
        fi ;;
    esac
    if gate_integrity_runner_infra "$file_runner" "$rc" "$runner_out"; then
      printf '%s\n' "$f" >> "$out/not_run"
      [ -n "$first_fail" ] \
        || first_fail="the runner exited without executing a test (exit $rc)"
      continue
    fi
    case "$rc" in
      126|127)
        printf '%s\n' "$f" >> "$out/not_run"
        [ -n "$first_fail" ] || first_fail="the runner could not be executed (exit $rc)" ;;
      *)
        printf '%s\n' "$f" >> "$out/discriminating" ;;
    esac
  done < "$list"

  gate_integrity_capped 60 git -C "$wt" worktree remove --force "$tree" >> "$log" 2>&1 || true
  rm -rf "$scratch"

  # A replay in which nothing could be judged is not a replay: say so, rather
  # than report three zero counts as if the base tree had been checked.
  if [ ! -s "$out/discriminating" ] && [ ! -s "$out/non_discriminating" ]; then
    printf 'not_run\t%s\t%s\n' "${first_fail:-${reason:-nothing could be replayed}}" "$runner"
  else
    printf 'ok\t%s\t%s\n' "${first_fail:-$reason}" "$runner"
  fi
}

# Half B's one pass over the diff: assertion deltas and skip markers per file,
# plus the literals a source line introduces that a changed test then expects.
# One `git diff` and one awk, so the cost is bounded by the size of the diff and
# not by the number of files in it.
gate_integrity_scan_diff() {  # $1 = worktree, $2 = range, $3 = test-path list
  git -C "$1" -c core.quotepath=false diff -U0 -M --no-color "$2" 2>/dev/null \
  | awk -v testlist="$3" -v maxlit="$GATE_INTEGRITY_MAX_LITERALS" '
    # `expect`, never `exp`: exp() is an awk built-in and cannot name an array.
    function keep(lit, kind, path) {
      if (lit !~ /[A-Za-z0-9]/) return
      if (lit ~ /^\.\.?\//) return
      if (kind == "src") { if (!(lit in src))    src[lit] = path }
      else               { if (!(lit in expect)) expect[lit] = path }
    }
    function harvest(text, kind, path,   s, lit) {
      if (text ~ /^[[:space:]]*(import|from|#include|using|package|require)[[:space:](]/) return
      s = text
      while (match(s, /"[^"][^"][^"][^"]*"/)) {
        lit = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        keep(lit, kind, path)
      }
      s = text
      while (match(s, sq)) {
        lit = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
        keep(lit, kind, path)
      }
      s = text
      while (match(s, /[0-9][0-9][0-9][0-9]+/)) {
        lit = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        keep(lit, kind, path)
      }
    }
    function assertions(text,   n) {
      n = 0
      while (match(text, /(^|[^a-z0-9_])(assert|expect|should|verify|xctassert|t\.(error|fatal))/)) {
        n++
        text = substr(text, RSTART + RLENGTH)
      }
      return n
    }
    function source_path(path) {
      return path ~ /\.(c|cc|cpp|cxx|h|hh|hpp|cs|dart|ex|exs|go|java|js|jsx|kt|kts|m|mm|php|py|rb|rs|scala|sh|swift|ts|tsx|vue)$/
    }
    BEGIN {
      # Built rather than written: a single quote cannot be spelled inside the
      # single-quoted awk program, and \x escapes are not portable.
      q = sprintf("%c", 39)
      sq = q "[^" q "][^" q "][^" q "][^" q "]*" q
      while ((getline l < testlist) > 0) if (l != "") is_test[l] = 1
      close(testlist)
    }
    /^--- / { next }
    /^\+\+\+ / {
      p = substr($0, 5)
      if (p == "/dev/null") { file = ""; next }
      sub(/^b\//, "", p)
      file = p
      next
    }
    file == "" { next }
    /^\+/ {
      line = substr($0, 2); low = tolower(line); count = assertions(low)
      if (is_test[file] && count > 0) {
        add_assert[file] += count
        harvest(line, "exp", file)
      }
      if (line ~ /(^|[^A-Za-z0-9_])((it|test|describe|context|suite)\.(only|skip|todo|failing)|xit\(|xdescribe\(|xtest\(|@pytest\.mark\.(skip|skipif|xfail)|pytest\.(skip|xfail)\(|unittest\.skip|t\.Skip\(|@Ignore|@Disabled|#\[ignore\])/ \
          || (is_test[file] && line ~ /(^|[^A-Za-z0-9_])(fit|fdescribe)\(|\.(skip|only)\(|xfail/)) {
        skip_n[file]++
        if (skip_n[file] == 1) {
          ex = line; sub(/^[[:space:]]+/, "", ex); skip_ex[file] = substr(ex, 1, 80)
        }
      }
      if (!is_test[file] && source_path(file)) harvest(line, "src", file)
      next
    }
    /^-/ {
      low = tolower(substr($0, 2))
      if (is_test[file]) del_assert[file] += assertions(low)
      next
    }
    END {
      for (f in del_assert) {
        a = (f in add_assert) ? add_assert[f] : 0
        if (del_assert[f] > a) printf "ASSERT\t%s\t%d\t%d\n", f, a, del_assert[f]
      }
      for (f in skip_n) printf "SKIP\t%s\t%d\t%s\n", f, skip_n[f], skip_ex[f]
      n = 0
      for (lit in src) {
        if (!(lit in expect)) continue
        if (++n > maxlit) break
        printf "LIT\t%s\t%s\t%s\n", src[lit], expect[lit], lit
      }
    }
  '
}

# The whole stage. Writes gate-integrity.json into the run dir and appends a
# human-readable block beside gate-latest.log in the worktree. Always returns 0.
gate_integrity_check() {  # $1 = worktree, $2 = base ref, $3 = run dir, $4 = brief, $5 = gate status
  local wt="$1" base_ref="$2" run_dir="$3" brief="${4:-}" gate_status="${5:-}"
  local work base head range replay_line status reason runner
  local flags tests json line st p1 p2 p3 path

  if ! work=$(mktemp -d "${TMPDIR:-/tmp}/gate-integrity-work.XXXXXX" 2>/dev/null); then
    work="$run_dir/.gate-integrity-work.$$"
    mkdir "$work" 2>/dev/null || return 0
  fi
  flags="$work/flags"; tests="$work/tests"
  : > "$flags"; : > "$tests"
  json="$run_dir/gate-integrity.json"

  base=$(git -C "$wt" merge-base "$base_ref" HEAD 2>/dev/null || echo "")
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")
  if [ -z "$base" ] || [ -z "$head" ]; then
    gate_integrity_write_json "$json" "" "" not_run \
      "the branch and its base could not be resolved" "" "$work" "$flags"
    rm -rf "$work"; return 0
  fi
  range="$base..$head"

  # Half B first: it is cheap, it needs nothing but the diff, and the test files
  # it identifies are what the replay works from.
  while IFS=$'\t' read -r st p1 p2; do
    [ -n "$st" ] || continue
    path="$p1"
    case "$st" in
      R*)
        if gate_integrity_is_test_path "$p1" \
           && ! gate_integrity_is_test_path "${p2:-}"; then
          gate_integrity_flag deleted_test "$p1" \
            "a test file this branch moves outside the test suite — a gate cannot fail on a test it no longer discovers" "$flags"
        fi
        [ -n "${p2:-}" ] && path="$p2" ;;
      C*) [ -n "${p2:-}" ] && path="$p2" ;;
    esac
    [ -n "$path" ] || continue
    case "$st" in
      D*)
        gate_integrity_is_test_path "$path" \
          && gate_integrity_flag deleted_test "$path" \
               "a test file this branch deletes — a gate cannot fail on a test that is gone" "$flags"
        ;;
      *)
        gate_integrity_is_test_path "$path" && printf '%s\n' "$path" >> "$tests" ;;
    esac
    if printf '%s\n' "$path" | grep -qE -- "$GATE_INTEGRITY_CI_RE"; then
      gate_integrity_brief_mentions "$brief" "$path" \
        || gate_integrity_flag ci_config_edit "$path" \
             "config that decides what passes, changed on a branch whose brief never mentions it" "$flags"
    elif printf '%s\n' "$path" | grep -qE -- "$GATE_INTEGRITY_CI_MAYBE_RE"; then
      if git -C "$wt" diff -U0 --no-color "$range" -- "$path" 2>/dev/null \
         | grep -E '^[-+]' | grep -qEi -- "$GATE_INTEGRITY_CI_HUNK_RE"; then
        gate_integrity_brief_mentions "$brief" "$path" \
          || gate_integrity_flag ci_config_edit "$path" \
               "its test, lint or coverage settings changed and the brief never mentions this file" "$flags"
      fi
    fi
    case "$st" in D*) continue ;; esac
  done <<EOF
$(git -C "$wt" -c core.quotepath=false diff --name-status -M "$range" 2>/dev/null)
EOF

  while IFS=$'\t' read -r st p1 p2 p3; do
    case "$st" in
      ASSERT) gate_integrity_flag assertions_removed "$p1" \
                "$p3 assertion(s) removed, $p2 added — a test that asserts less than it did" "$flags" ;;
      SKIP)   gate_integrity_flag skip_marker "$p1" \
                "$p2 skip/only marker(s) introduced, first: $p3" "$flags" ;;
      LIT)    gate_integrity_flag literal_echoed "$p2" \
                "expects the literal [$p3] that this same diff introduces in $p1 — a test copied from the implementation cannot contradict it" "$flags" ;;
    esac
  done <<EOF
$(gate_integrity_scan_diff "$wt" "$range" "$tests")
EOF

  # Half A. A tree the gate could not turn green tells the replay nothing: those
  # tests would fail against the base as loudly as they fail here.
  : > "$run_dir/gate-integrity-replay.log"
  if [ "$gate_status" = pass ] || [ -z "$gate_status" ]; then
    replay_line=$(gate_integrity_replay "$wt" "$base" "$tests" "$work" \
      "$run_dir/gate-integrity-replay.log")
  else
    : > "$work/discriminating"; : > "$work/non_discriminating"
    cp "$tests" "$work/not_run"
    replay_line=$(printf 'not_run\t%s\t' \
      "the gate did not pass on this tree, so a replay against the base would say nothing")
  fi
  status=$(printf '%s' "$replay_line" | cut -f1)
  reason=$(printf '%s' "$replay_line" | cut -f2)
  runner=$(printf '%s' "$replay_line" | cut -f3)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    gate_integrity_flag non_discriminating_test "$line" \
      "passes unchanged against the base tree — it cannot have caught what this branch changed" "$flags"
  done < "$work/non_discriminating"

  gate_integrity_write_json "$json" "$base" "$head" \
    "$status" "$reason" "$runner" "$work" "$flags"

  # The reviewer's file view is the worktree, so the block lands beside the gate
  # log it belongs with. Appended, so a resumed run keeps every round's findings.
  if [ -d "$wt/.harness" ] && [ -f "$json" ]; then
    { printf '=== gate integrity (%s) ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
      printf 'range: %s\n\n' "$range"
      gate_integrity_section "$json"
      printf '\n'
    } >> "$wt/.harness/gate-integrity.log" 2>/dev/null || true
  fi
  rm -rf "$work"
  return 0
}

# The reviewer's section, rendered from the JSON so the prompt and the worktree
# artifact can never disagree.
gate_integrity_section() {  # $1 = gate-integrity.json
  [ -f "$1" ] || return 0
  jq -r '
    def plural($n; $one; $many): if $n == 1 then $one else $many end;
    ["## Gate integrity flags",
     "A deterministic script — no model, and nothing in the pipeline gates on it — checked this branch for the signatures of a gate made green rather than earned. What follows is evidence to start checklist item 1 from, not a verdict: confirm every line against the diff yourself, and read an empty list as no evidence rather than as proof the gate is honest."]
    + (if .replay.status == "ok" then
         ["Replay against the base tree"
          + (if (.replay.runner // "") == "" then "" else " (\(.replay.runner))" end)
          + ": of the new or changed test files on this branch, \(.replay.discriminating) \(plural(.replay.discriminating; "fails"; "fail")) on unpatched code, as a test for this change should; "
          + "\(.replay.non_discriminating) \(plural(.replay.non_discriminating; "passes"; "pass")) there unchanged; "
          + "\(.replay.not_run) could not be run."
          + (if (.replay.reason // "") == "" then "" else " (\(.replay.reason))" end)]
       else
         ["Replay against the base tree: not run — \(.replay.reason // "no reason recorded"). Nothing follows from that either way; the structural checks below still ran."]
       end)
    + (if (.flags | length) == 0 then
         ["No flags: neither the replay nor the structural diff check came back with anything. Checklist item 1 still applies in full — this check is shallow by design and misses everything it does not name."]
       else
         ["Flags (\(.flags | length)):"] + [.flags[] | "- \(.kind) · \(.file) — \(.detail)"]
       end)
    + ["The gate has already run the checks this repo defines. Read .harness/gate-latest.log first; when it shows a linter already ran, cite those exact lines rather than re-running it."]
    | .[]' "$1" 2>/dev/null || true
}
