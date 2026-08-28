#!/usr/bin/env bash
# Deterministic test gate for this repo: static checks on every shipped shell
# script, then every suite under tests/ — the suites run CONCURRENTLY.
#
# Two things changed from the serial gate, both for wall-clock:
#   1. Lint runs first and, when it fails, the suites do not run. A lint failure
#      is a ten-second fix; re-running ninety minutes of suites to learn about
#      six shellcheck warnings is what a whole afternoon was once spent on.
#      GATE_ALWAYS_ALL=1 restores "run both regardless".
#   2. The suites run GATE_JOBS at a time (default: the machine's core count).
#      Every suite already isolates itself — its own mktemp root, its own HOME
#      and HARNESS_DIR, dynamic ports — so the only thing serial execution ever
#      bought was legibility, and that is kept: results print in filename order,
#      each with the same one-line summary as before, a failing suite's
#      transcript right under its line. GATE_JOBS=1 is the old serial gate.
set -u
status=0
scripts=$(git ls-files '*.sh')
for f in $scripts; do
  bash -n "$f" || status=1
done
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -S warning $scripts || status=1
else
  echo "gate: shellcheck is required (brew install shellcheck / apt-get install shellcheck)" >&2
  status=1
fi
if [ "$status" -ne 0 ] && [ "${GATE_ALWAYS_ALL:-0}" != 1 ]; then
  echo "gate: lint failed — the suites did not run (GATE_ALWAYS_ALL=1 runs them anyway)"
  exit 1
fi

# The dispatch knobs a run pins at first dispatch, cleared for every suite.
# The harness dispatches THIS repo, and it selects a provider by exporting
# IMPLEMENTER_PROVIDER — which every fixture run-task.sh a suite spawns then
# inherits, pins, and dies on at the credential check for a vendor the fixture
# never asked for. Eleven suites failed that way, all of them reporting
# setup_failed for reasons nothing in their own fixture explains. A suite that
# wants one of these sets it itself; none of them may inherit one.
#
# HARNESS_DETACH=0 is the one knob set rather than cleared. run-task.sh re-execs
# itself into its own session before doing anything expensive, so a stopped
# launcher can no longer take a live pipeline down with it. Every suite here
# runs a fixture run-task.sh in the FOREGROUND and asserts on its exit status
# and its stdout — against a detaching driver each of those would read an
# instant 0 from the launcher half and assert on a pipeline that had not
# started yet. Pinned here, in the one place that already owns the suites'
# environment, rather than in each of the suites that would have to remember.
#
# HARNESS_WALL_URL/_TOKEN are cleared for a second reason: a station that fans
# its runs in to a wall would otherwise have every fixture run-task.sh here post
# its fake stages to the operator's real board.
GATE_ENV=(env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT
          -u REVIEWER_MODEL -u REVIEWER_EFFORT -u HARNESS_OWNER
          -u HARNESS_MAX_TURNS -u HARNESS_MAX_RESUMES
          -u HARNESS_SKIP_REVIEW -u HARNESS_REDISPATCH
          -u HARNESS_ESCALATION -u HARNESS_ESCALATION_STEPS
          -u HARNESS_PROFILES -u HARNESS_VISUAL_ROUNDS
          -u HARNESS_WALL_URL -u HARNESS_WALL_TOKEN
          HARNESS_DETACH=0 HARNESS_PREFLIGHT=off)
# HARNESS_PREFLIGHT=off: the capacity preflight shells out to `npx ccusage@latest`
# — a registry round-trip of 3-6 s — and 21 suites never fake npx, so every one
# of their fixture runs paid it for a config dir that has no logs to account.
# The four suites whose fixtures depend on it (the preflight itself, and the
# capacity deferrals it triggers) set HARNESS_PREFLIGHT=on themselves.

suites=()
for t in tests/*.test.sh; do [ -e "$t" ] && suites+=("$t"); done
[ "${#suites[@]}" -gt 0 ] || exit "$status"

jobs="${GATE_JOBS:-}"
if [ -z "$jobs" ]; then
  jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
fi
case "$jobs" in ''|*[!0-9]*|0) jobs=4 ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

# One suite per xargs slot. The child writes the transcript and a verdict file
# and prints nothing itself — the parent below is the only writer to stdout, so
# concurrent suites can never interleave their output.
cat > "$work/run-one" <<'RUNNER'
#!/usr/bin/env bash
set -u
t="$1"; work="$2"; shift 2
name=$(basename "$t")
started=$(date +%s)
if "$@" bash "$t" > "$work/$name.out" 2>&1; then verdict=ok; else verdict=FAIL; fi
printf '%s %s\n' "$verdict" "$(( $(date +%s) - started ))" > "$work/$name.verdict"
RUNNER
chmod +x "$work/run-one"

printf '%s\n' "${suites[@]}" | xargs -P "$jobs" -I{} "$work/run-one" {} "$work" "${GATE_ENV[@]}" &
xargs_pid=$!

# Print in filename order as soon as each suite in that order has finished:
# a suite that is still running holds the cursor, everything after it waits.
# Only a failing suite prints its transcript; a green one is worth exactly one
# line — plus its skips, if it has any. A suite that could not test a claim on
# this machine says so with a `  skip ` line, and a gate summary that swallowed
# those would read as coverage the run does not have.
for t in "${suites[@]}"; do
  name=$(basename "$t")
  while [ ! -s "$work/$name.verdict" ]; do
    if ! kill -0 "$xargs_pid" 2>/dev/null && [ ! -s "$work/$name.verdict" ]; then
      # xargs is gone and this suite never reported: count it as a failure.
      printf 'FAIL 0\n' > "$work/$name.verdict"
      echo "gate: $t produced no verdict — the runner died before it finished" >> "$work/$name.out"
    fi
    sleep 0.5
  done
  read -r verdict secs < "$work/$name.verdict"
  [ "$verdict" = ok ] || status=1
  counts=$(awk '
    /^  ok /   { passed++ }
    /^  FAIL / { failed++ }
    /^  skip / { skipped++ }
    END { printf "%d passed, %d failed%s", passed, failed,
            (skipped ? ", " skipped " SKIPPED" : "") }
  ' "$work/$name.out")
  grep '^  skip ' "$work/$name.out" || true
  printf 'gate: %-24s %-4s %3ds  %s\n' "$t" "$verdict" "$secs" "$counts"
  [ "$verdict" = ok ] || cat "$work/$name.out"
done
wait "$xargs_pid" 2>/dev/null || true

exit $status
