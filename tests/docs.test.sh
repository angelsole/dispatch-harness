#!/usr/bin/env bash
# Docs-as-tests: assert this repo's documentation matches shipped reality.
#
# Three families of drift, all of which have actually happened here:
#   1. a hard dependency the scripts need that README's Prerequisites never
#      names (or a prerequisite the scripts stopped using),
#   2. install.sh's FILES array diverging from the files in the repo,
#   3. README/SKILL.md naming a script that does not exist — until PR #3 both
#      promised a statusline.sh the repo did not ship.
#
# Read-only: touches nothing but tracked files and one temp scratch file. The
# stage -> actor contract is deliberately not re-asserted here; it belongs to
# tests/statusline.test.sh.
#
# Usage: bash tests/docs.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
README="$SRC/README.md"
SKILL="$SRC/skills/dispatch/SKILL.md"
RELEASING="$SRC/RELEASING.md"
INSTALL="$SRC/install.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
list_ok() {  # $1 = accumulated offenders, $2 = ok label, $3 = fail label
  if [ -z "$1" ]; then ok "$2"; else bad "$3:$1"; fi
}

# Every shipped script concatenated once: what the harness itself invokes.
# tests/ is excluded — a binary only the suites use is not a user prerequisite.
BLOB="$(mktemp "${TMPDIR:-/tmp}/docs-test.XXXXXX")"
trap 'rm -f "$BLOB"' EXIT
( cd "$SRC" && git ls-files '*.sh' | grep -v '^tests/' | while IFS= read -r f; do cat "$f"; done ) > "$BLOB"
TRACKED="$(cd "$SRC" && git ls-files)"

uses() { grep -qwF -- "$1" "$BLOB"; }

# ---------------------------------------------------------------------------
# Prerequisites completeness
# ---------------------------------------------------------------------------
# Hard dependencies are listed rather than extracted: bash source does not
# distinguish an invocation from prose (README's "click the GIF to open the
# full video" is not a dependency on open(1)). Both directions are asserted —
# each name must be in README's Required block AND still be referenced by a
# shipped script — so dropping a dependency from the code fails here until the
# README drops it too. The command -v sweep below is the extracted half: it
# catches a *new* guarded dependency landing with no README line.
PREREQ_BINS='claude gh jq git bash curl perl lsof uuidgen'

# Optional features, example tooling, and this repo's own dev tooling: not
# needed to run the pipeline, but README must still say they exist.
DOCUMENTED_BINS='codex tmux shot-scraper rclone ffmpeg python3 docker nc npx shellcheck node rsync launchctl'

# Guarded at every call site and degrade silently when absent — README owes
# them nothing.
GRACEFUL_BINS='osascript caffeinate timeout'

echo "== README prerequisites vs. what the scripts need =="
PREREQ_SECTION="$(awk '/^## Prerequisites$/{f=1;next} /^## /{f=0} f' "$README")"
REQUIRED_BLOCK="$(printf '%s\n' "$PREREQ_SECTION" | awk '/^Required:/{f=1;next} /^Optional/{f=0} f')"
if printf '%s' "$REQUIRED_BLOCK" | grep -q '[^[:space:]]'; then
  ok "prereq: README Prerequisites has a Required block"
else
  bad "prereq: README Prerequisites has a Required block (extraction found nothing)"
fi

missing=''; unused=''
for b in $PREREQ_BINS; do
  printf '%s' "$REQUIRED_BLOCK" | grep -qF -- "\`$b\`" || missing="$missing $b"
  uses "$b" || unused="$unused $b"
done
list_ok "$missing" "prereq: README Required names every hard dependency" \
                   "prereq: hard dependencies absent from README Required"
list_ok "$unused"  "prereq: every documented hard dependency is still used" \
                   "prereq: README requires binaries no shipped script uses"

missing=''; unused=''
for b in $DOCUMENTED_BINS; do
  grep -qwF -- "$b" "$README" || missing="$missing $b"
  uses "$b" || unused="$unused $b"
done
list_ok "$missing" "prereq: README documents every optional dependency" \
                   "prereq: optional dependencies unmentioned in README"
list_ok "$unused"  "prereq: every optional dependency is still used" \
                   "prereq: README documents binaries no shipped script uses"

# Any `command -v X` guard on something that is not a shell function is a
# dependency, and must be in one of the three lists above.
defined_as_function() { ( cd "$SRC" && git grep -qE "^[[:space:]]*$1\(\)[[:space:]]*\{" ); }
GUARDS="$(grep -ohE 'command -v [A-Za-z0-9_.-]+' "$BLOB" | sed 's/.*command -v //' | sort -u)"
n=$(printf '%s\n' "$GUARDS" | grep -c '' | tr -d ' ')
if [ "$n" -ge 5 ]; then ok "prereq: found $n command -v guards"; else bad "prereq: only $n command -v guards found — extraction broken?"; fi

unclassified=''
for b in $GUARDS; do
  case " $PREREQ_BINS $DOCUMENTED_BINS $GRACEFUL_BINS " in
    *" $b "*) continue ;;
  esac
  defined_as_function "$b" || unclassified="$unclassified $b"
done
list_ok "$unclassified" "prereq: every guarded dependency is classified" \
                        "prereq: guarded dependencies missing from this test and README"

# ---------------------------------------------------------------------------
# install.sh FILES <-> the repo
# ---------------------------------------------------------------------------
echo "== install.sh FILES vs. the repo =="
FILES_LIST="$(awk '/^FILES=\(/{f=1;next} f&&/^\)/{f=0} f' "$INSTALL" | tr -s ' \t' '\n\n' | sed '/^$/d')"
n=$(printf '%s\n' "$FILES_LIST" | grep -c '' | tr -d ' ')
if [ "$n" -ge 15 ]; then ok "install: FILES lists $n entries"; else bad "install: only $n FILES entries found — extraction broken?"; fi

missing=''
for f in $FILES_LIST; do
  [ -e "$SRC/$f" ] || missing="$missing $f"
done
list_ok "$missing" "install: every FILES entry exists in the repo" \
                   "install: FILES installs files that do not exist"

# Everything shipped at the top level is either installed or knowingly not.
NOT_INSTALLED='gate.sh install.sh'
orphan=''
for f in $(cd "$SRC" && git ls-files '*.sh' | grep -v '/'); do
  case " $(printf '%s' "$FILES_LIST" | tr '\n' ' ') $NOT_INSTALLED " in
    *" $f "*) ;;
    *) orphan="$orphan $f" ;;
  esac
done
list_ok "$orphan" "install: every top-level script is installed or listed as not-installed" \
                  "install: top-level scripts install.sh never installs"

# Each seeded config ships its *.example template.
SEEDS="$(grep -E '^seed[[:space:]]' "$INSTALL" | awk '{print $2}')"
n=$(printf '%s\n' "$SEEDS" | grep -c '' | tr -d ' ')
if [ "$n" -ge 3 ]; then ok "install: seeds $n local config files"; else bad "install: only $n seed lines found — extraction broken?"; fi

missing=''
for ex in $SEEDS; do
  [ -e "$SRC/$ex" ] || missing="$missing $ex"
done
list_ok "$missing" "install: every seeded config ships its .example template" \
                   "install: seeds from templates that do not exist"

# ---------------------------------------------------------------------------
# Shipped-claim regression
# ---------------------------------------------------------------------------
echo "== shipped claims: docs name only what the repo ships =="
claim() {  # $1 = label, $2 = file, $3 = literal the docs must still contain
  if grep -qF -- "$3" "$2"; then ok "claim: $1 mentions $3"; else bad "claim: $1 no longer mentions $3"; fi
}
claim README      "$README"    'statusline.sh'
claim README      "$README"    'quartermaster.sh'
claim README      "$README"    '--runs-only'
claim README      "$README"    'status.sh --watch'
claim SKILL.md    "$SKILL"     'statusline.sh'
claim SKILL.md    "$SKILL"     '--runs-only'
claim SKILL.md    "$SKILL"     'status.sh --watch'
claim README      "$README"    'tests/*.test.sh'
claim RELEASING.md "$RELEASING" 'tests/*.test.sh'
claim README      "$README"    'metrics.sh --report'
# The pipeline's self-report is only useful if its two loud values are documented
# where a human (and the planner) will look for them.
claim README      "$README"    'failed_silent'
claim SKILL.md    "$SKILL"     'failed_silent'
# The attempt lifecycle: a run that resumes itself out of a session limit, the
# guard that stops a shipped run being dispatched again, and where a finished
# attempt's telemetry now lives. All three change what an operator should expect
# to see, so none of them may live only in the code.
claim README      "$README"    'self-resuming at'
claim README      "$README"    'HARNESS_REDISPATCH=1'
claim README      "$README"    'attempts/<n>/'
claim README      "$README"    'attempts.log'
claim SKILL.md    "$SKILL"     'HARNESS_REDISPATCH=1'
# A brief that fails validation is moved, not armed and not deleted. An
# operator who finds their brief gone has to be able to look up where it went.
claim README      "$README"    'brief.rejected.md'

# Every backtick-quoted *.sh name in the docs must resolve to a shipped file.
# A gitignored local config resolves through its *.example template; code spans
# containing a glob are patterns, not filenames, so they are skipped.
ships() {  # $1 = basename
  printf '%s\n' "$TRACKED" | grep -qE "(^|/)$(printf '%s' "$1" | sed 's/\./\\./g')(\.example)?$"
}
NAMED="$(grep -ohE '`[^`*]*`' "$README" "$SKILL" | grep -ohE '[A-Za-z0-9][A-Za-z0-9_.-]*\.sh' | sort -u)"
n=$(printf '%s\n' "$NAMED" | grep -c '' | tr -d ' ')
if [ "$n" -ge 15 ]; then ok "claim: docs name $n scripts"; else bad "claim: only $n script names found — extraction broken?"; fi

phantom=''
for name in $NAMED; do
  ships "$name" || phantom="$phantom $name"
done
list_ok "$phantom" "claim: every script named in README/SKILL.md ships" \
                   "claim: docs name scripts that do not exist"

# ---------------------------------------------------------------------------
# Env knobs <-> the docs
# ---------------------------------------------------------------------------
# A knob nobody can find is a knob that does not exist. Every HARNESS_* env var
# run-task.sh honors must be named in README.md — or, for the ones whose home is
# a config file, in the shipped template that seeds it.
echo "== env knobs vs. the docs =="
KNOBS="$(grep -ohE 'HARNESS_[A-Z_]+' "$SRC/run-task.sh" | sort -u)"
n=$(printf '%s\n' "$KNOBS" | grep -c '' | tr -d ' ')
if [ "$n" -ge 10 ]; then ok "knobs: run-task.sh reads $n HARNESS_* knobs"; else bad "knobs: only $n HARNESS_* knobs found — extraction broken?"; fi

EXAMPLES="$(cd "$SRC" && git ls-files '*.example' | while IFS= read -r f; do cat "$f"; done)"
undocumented=''
for k in $KNOBS; do
  grep -qF -- "$k" "$README" && continue
  printf '%s' "$EXAMPLES" | grep -qF -- "$k" && continue
  undocumented="$undocumented $k"
done
list_ok "$undocumented" "knobs: every knob run-task.sh honors is documented" \
                        "knobs: knobs documented nowhere a user would look"

# ---------------------------------------------------------------------------
# Run outcomes <-> the planner's triage list
# ---------------------------------------------------------------------------
# Every status run-task.sh can write into result.json is a state the planner
# has to know what to do about. A new outcome that never reaches SKILL.md
# leaves the orchestrator staring at a word it has no instruction for — which
# is exactly what an undocumented `deferred_capacity` would have done.
echo "== run statuses vs. the planner's triage list =="
STATUSES="$(grep -ohE '(^|[^_A-Za-z])STATUS="[a-z_]+"' "$SRC/run-task.sh" \
  | tr -d ' \t' | sed -e 's/^STATUS="//' -e 's/"$//' | sort -u)"
n=$(printf '%s\n' "$STATUSES" | grep -c '' | tr -d ' ')
if [ "$n" -ge 8 ]; then ok "status: found $n run outcomes"; else bad "status: only $n run outcomes found — extraction broken?"; fi

undocumented=''
for s in $STATUSES; do
  grep -qF -- "$s" "$SKILL" || undocumented="$undocumented $s"
done
list_ok "$undocumented" "claim: SKILL.md triages every status run-task.sh writes" \
                        "claim: run outcomes the planner is given no instruction for"

echo
printf 'docs smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
