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
# The documentation is now two tiers: README.md is the product page and
# docs/*.md carries the operator reference, the ops guide, the wall and the
# design notes. Wherever this suite used to ask "is it in README", it now asks
# "is it in README *or* under docs/" — the same question about a bigger home,
# never a weaker one. Everything that has to stay on the front page (the
# prerequisites table, the review-integrity contract, the product-level script
# names) is still asserted against README alone, and four new families of check
# came with the split: the two copies of the pipeline diagram must be identical,
# every docs page must be reachable from README, every internal anchor must
# resolve, and no team-internal identifier may reappear.
#
# Read-only: touches nothing but tracked files and two temp scratch files. The
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
FLOW="$SRC/FLOW.md"
OPS="$SRC/docs/operations.md"
REF="$SRC/docs/reference.md"
WALLDOC="$SRC/docs/wall.md"
NOTES="$SRC/docs/design-notes.md"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
list_ok() {  # $1 = accumulated offenders, $2 = ok label, $3 = fail label
  if [ -z "$1" ]; then ok "$2"; else bad "$3:$1"; fi
}

# Every shipped script concatenated once: what the harness itself invokes.
# tests/ is excluded — a binary only the suites use is not a user prerequisite.
BLOB="$(mktemp "${TMPDIR:-/tmp}/docs-test.XXXXXX")"
DOCSBLOB="$(mktemp "${TMPDIR:-/tmp}/docs-test-docs.XXXXXX")"
trap 'rm -f "$BLOB" "$DOCSBLOB"' EXIT
( cd "$SRC" && git ls-files '*.sh' | grep -v '^tests/' | while IFS= read -r f; do cat "$f"; done ) > "$BLOB"
TRACKED="$(cd "$SRC" && git ls-files)"

# The documentation home: the product page plus every page under docs/. Built
# from git ls-files, so a docs page that is written but never committed does not
# count as documentation — the same rule the rest of this suite already applies.
DOC_FILES="$README"
for f in $(cd "$SRC" && git ls-files 'docs/*.md'); do
  DOC_FILES="$DOC_FILES $SRC/$f"
done
for f in $DOC_FILES; do cat "$f"; done > "$DOCSBLOB"

uses() { grep -qwF -- "$1" "$BLOB"; }

echo "== the documentation home =="
n=0
for f in $DOC_FILES; do n=$((n+1)); done
if [ "$n" -ge 5 ]; then ok "docs: documentation home is README + $((n-1)) pages under docs/"
else bad "docs: only $n documentation files found — extraction broken?"; fi

missing=''
for f in "$OPS" "$REF" "$WALLDOC" "$NOTES"; do
  [ -f "$f" ] || missing="$missing $(basename "$f")"
done
list_ok "$missing" "docs: the four reference pages exist" \
                   "docs: reference pages missing"

# A page nothing links to is a page nobody reads. README is the only entry
# point, so every docs page has to be reachable from it.
unlinked=''
for f in $DOC_FILES; do
  [ "$f" = "$README" ] && continue
  grep -qF -- "](docs/$(basename "$f")" "$README" || unlinked="$unlinked $(basename "$f")"
done
list_ok "$unlinked" "docs: every docs/ page is linked from README" \
                    "docs: docs/ pages README never links to"

# This repo was exported from a single-tenant working copy. Team-internal names
# leaking back into the docs is the one regression a reader outside the team
# would notice immediately. (wall/fixtures/ keeps its OLYX-* run ids on purpose:
# they are fixture data, not prose, and are not searched here.)
if ( cd "$SRC" && grep -qiE 'olyx|valoryx|angel\.sole' README.md docs/*.md ); then
  bad "docs: team-internal identifiers are back in README/docs"
else
  ok "docs: no team-internal identifiers in README or docs/"
fi

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
#
# Deliberately still README-only, unlike the knob sweep below. "What do I have
# to install?" is a question a reader asks once, before they have any reason to
# open docs/, and README's Prerequisites table is the single answer; letting a
# binary count as documented because a design note happens to mention it in
# passing would be a weaker check than the one this replaces.
DOCUMENTED_BINS='codex tmux shot-scraper rclone ffmpeg python3 docker nc npm npx yarn shellcheck node rsync launchctl magick tailscale'

# Guarded at every call site and degrade silently when absent — README owes
# them nothing.
GRACEFUL_BINS='osascript caffeinate timeout shasum pgrep'

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
# Product-level promises: these stay on the front page. A reader who never
# opens docs/ still has to learn that runs are watchable and that no arm ships
# an unread diff.
claim README      "$README"    'statusline.sh'
claim README      "$README"    'quartermaster.sh'
claim README      "$README"    'status.sh --watch'
claim SKILL.md    "$SKILL"     'statusline.sh'
claim SKILL.md    "$SKILL"     '--runs-only'
claim SKILL.md    "$SKILL"     'status.sh --watch'
claim README      "$README"    'tests/*.test.sh'
claim RELEASING.md "$RELEASING" 'tests/*.test.sh'
claim README      "$README"    'metrics.sh --report'
# Retargeted: the statusline wiring recipe (and the `--runs-only` escape hatch
# for an operator who already has a statusline command) moved to the reference
# with the rest of the monitoring surfaces. SKILL.md's copy is unchanged above.
claim reference.md "$REF"      '--runs-only'
# The pipeline's self-report is only useful if its two loud values are documented
# where a human (and the planner) will look for them.
claim README      "$README"    'failed_silent'
claim SKILL.md    "$SKILL"     'failed_silent'
# The review-integrity guarantee, in the words the code now keeps: no arm opens
# a PR on a diff nothing read. A README that still promises less than the
# pipeline delivers sends an operator looking for a skip that no longer exists.
claim README      "$README"    'every arm reviews or holds'
claim README      "$README"    'claude_only'
claim SKILL.md    "$SKILL"     'claude_only'
# The attempt lifecycle: a run that resumes itself out of a session limit, the
# guard that stops a shipped run being dispatched again, and where a finished
# attempt's telemetry now lives. All three change what an operator should expect
# to see, so none of them may live only in the code.
#
# Retargeted, not dropped: these are operator detail, and the operator guide is
# docs/operations.md now. The attempt telemetry paths are part of the run's
# paper trail, which the reference owns.
claim operations.md "$OPS"     'self-resuming at'
claim operations.md "$OPS"     'HARNESS_REDISPATCH=1'
claim reference.md  "$REF"     'attempts/<n>/'
claim reference.md  "$REF"     'attempts.log'
claim SKILL.md    "$SKILL"     'HARNESS_REDISPATCH=1'
# A ticket the planner creates must land where the team works, not as an orphan:
# one claim per field of the creation contract, so the skill cannot quietly drop
# a field and go back to writing tickets nobody is assigned to.
claim SKILL.md    "$SKILL"     'the dispatching user'
claim SKILL.md    "$SKILL"     'never an agent identity'
claim SKILL.md    "$SKILL"     "the team's current cycle"
claim SKILL.md    "$SKILL"     'fold the choice into this approval question'
claim SKILL.md    "$SKILL"     'the request came from or blocks'
# A brief that fails validation is moved, not armed and not deleted. An
# operator who finds their brief gone has to be able to look up where it went.
# It travels with the Quartermaster section it belongs to.
claim operations.md "$OPS"     'brief.rejected.md'
# The verifier costs a third-vendor API key, so how to turn it on has to be
# findable — and the one thing an operator must never get wrong about it is that
# nothing in the pipeline depends on the number it produces. The how-to and the
# schema field moved to the reference; the promise stays on the front page,
# because it is the claim a reader is most likely to over-read.
claim reference.md "$REF"      'install.sh --verifier'
claim reference.md "$REF"      'verifier-api-key'
claim README      "$README"    'It is advisory, and it never gates.'
claim reference.md "$REF"      'metrics.verifier'
# One distinctive literal per docs page: a canary that the page still carries
# the content it was split out to carry, rather than having been emptied into a
# link.
claim operations.md   "$OPS"     'Sleep, honestly'
claim reference.md    "$REF"     'repo_config_local()'
claim wall.md         "$WALLDOC" 'deleting the ledger razes the city'
claim design-notes.md "$NOTES"   'pipeline vitals'

# Every backtick-quoted *.sh name in the docs must resolve to a shipped file.
# A gitignored local config resolves through its *.example template; code spans
# containing a glob are patterns, not filenames, so they are skipped.
#
# Widened: the sweep used to read README + SKILL.md and now reads every page of
# the documentation home too, so a phantom script named only in a docs page is
# caught as loudly as one on the front page.
ships() {  # $1 = basename
  printf '%s\n' "$TRACKED" | grep -qE "(^|/)$(printf '%s' "$1" | sed 's/\./\\./g')(\.example)?$"
}
scripts_named_in() {  # $@ = files
  grep -ohE '`[^`*]*`' "$@" | grep -ohE '[A-Za-z0-9][A-Za-z0-9_.-]*\.sh' | sort -u
}
# shellcheck disable=SC2086
NAMED="$(scripts_named_in $DOC_FILES "$SKILL")"
n=$(printf '%s\n' "$NAMED" | grep -c '' | tr -d ' ')
if [ "$n" -ge 15 ]; then ok "claim: docs name $n scripts"; else bad "claim: only $n script names found — extraction broken?"; fi

phantom=''
for name in $NAMED; do
  ships "$name" || phantom="$phantom $name"
done
list_ok "$phantom" "claim: every script named in README/docs/SKILL.md ships" \
                   "claim: docs name scripts that do not exist"

# The front page keeps a real map of the repo rather than a link to one: the
# Repository layout table is what makes README readable on its own, and it is
# the first thing a rewrite quietly drops.
n=$(scripts_named_in "$README" | grep -c '' | tr -d ' ')
if [ "$n" -ge 15 ]; then ok "claim: README alone names $n scripts"
else bad "claim: README names only $n scripts — the layout table has thinned out"; fi

# Scripts are not the only top-level files that go stale in this table. Require
# every tracked top-level file explicitly; directories are represented by their
# own rows and are covered by the distinctive docs-page claims above.
LAYOUT_SECTION="$(awk '/^## Repository layout$/{f=1;next} /^## /{f=0} f' "$README")"
missing=''
for f in $(printf '%s\n' "$TRACKED" | awk 'index($0,"/")==0'); do
  printf '%s' "$LAYOUT_SECTION" | grep -qF -- "\`$f\`" || missing="$missing $f"
done
list_ok "$missing" "claim: Repository layout names every tracked top-level file" \
                   "claim: top-level files absent from Repository layout"

# ---------------------------------------------------------------------------
# Env knobs <-> the docs
# ---------------------------------------------------------------------------
# A knob nobody can find is a knob that does not exist. Every HARNESS_* env var
# run-task.sh honors must be named somewhere in the documentation home — README
# for the handful a newcomer needs, docs/ for the rest — or, for the ones whose
# home is a config file, in the shipped template that seeds it.
echo "== env knobs vs. the docs =="
# shellcheck disable=SC2046  # the globs are the point; these paths hold no spaces
KNOBS="$(grep -ohE 'HARNESS_[A-Z_]+' "$SRC/run-task.sh" \
  $(echo "$SRC"/lib/*.sh) $(echo "$SRC"/profiles/*/profile.sh) | sort -u)"
n=$(printf '%s\n' "$KNOBS" | grep -c '' | tr -d ' ')
if [ "$n" -ge 10 ]; then ok "knobs: run-task.sh reads $n HARNESS_* knobs"; else bad "knobs: only $n HARNESS_* knobs found — extraction broken?"; fi

EXAMPLES="$(cd "$SRC" && git ls-files '*.example' | while IFS= read -r f; do cat "$f"; done)"
undocumented=''
for k in $KNOBS; do
  grep -qF -- "$k" "$DOCSBLOB" && continue
  printf '%s' "$EXAMPLES" | grep -qF -- "$k" && continue
  undocumented="$undocumented $k"
done
list_ok "$undocumented" "knobs: every knob run-task.sh honors is documented" \
                        "knobs: knobs documented nowhere a user would look"

# The quartermaster's own knobs never had a sweep. They do now. The contract
# keeps the table with the operational narrative and also makes reference.md the
# lookup for every environment variable, so both pages must carry the complete
# set. Only names actually read from the environment count: `${QM_X:-default}`
# is a knob; a plain assignment (QM_DIR) is an internal path.
QM_KNOBS="$(grep -ohE 'QM_[A-Z_]+:-' "$SRC/quartermaster.sh" | sed 's/:-$//' | sort -u)"
n=$(printf '%s\n' "$QM_KNOBS" | grep -c '' | tr -d ' ')
if [ "$n" -ge 10 ]; then ok "knobs: quartermaster.sh reads $n QM_* knobs"; else bad "knobs: only $n QM_* knobs found — extraction broken?"; fi

missing_ops=''; missing_ref=''
for k in $QM_KNOBS; do
  grep -qF -- "$k" "$OPS" || missing_ops="$missing_ops $k"
  grep -qF -- "$k" "$REF" || missing_ref="$missing_ref $k"
done
list_ok "$missing_ops" "knobs: operations carries every QM_* knob" \
                       "knobs: QM_* knobs missing from operations"
list_ok "$missing_ref" "knobs: reference carries every QM_* knob" \
                       "knobs: QM_* knobs missing from reference"

# ---------------------------------------------------------------------------
# Run outcomes <-> the planner's triage list
# ---------------------------------------------------------------------------
# Every status run-task.sh can write into result.json is a state the planner
# has to know what to do about. A new outcome that never reaches SKILL.md
# leaves the orchestrator staring at a word it has no instruction for — which
# is exactly what an undocumented `deferred_capacity` would have done.
echo "== run statuses vs. the planner's triage list =="
# shellcheck disable=SC2046  # a profile's outcome_status hook writes STATUS too
STATUSES="$(grep -ohE '(^|[^_A-Za-z])STATUS="[a-z_]+"' "$SRC/run-task.sh" \
  $(echo "$SRC"/profiles/*/profile.sh) \
  | tr -d ' \t' | sed -e 's/^STATUS="//' -e 's/"$//' | sort -u)"
n=$(printf '%s\n' "$STATUSES" | grep -c '' | tr -d ' ')
if [ "$n" -ge 8 ]; then ok "status: found $n run outcomes"; else bad "status: only $n run outcomes found — extraction broken?"; fi

undocumented=''
for s in $STATUSES; do
  grep -qF -- "$s" "$SKILL" || undocumented="$undocumented $s"
done
list_ok "$undocumented" "claim: SKILL.md triages every status run-task.sh writes" \
                        "claim: run outcomes the planner is given no instruction for"

# ---------------------------------------------------------------------------
# The pipeline diagram, in two places
# ---------------------------------------------------------------------------
# README inlines FLOW.md's sequence diagram so the front page is readable on its
# own. Two copies drift: before this check they already had seven lines of
# difference, README's being the accurate one. Whichever is edited, both move.
# (harness-flow.html is deliberately not compared — it is a hand-laid poster,
# not a mirror of this block.)
echo "== the pipeline diagram, in both copies =="
first_mermaid() {  # $1 = markdown file -> the first fenced mermaid block's body
  awk '/^```mermaid$/{f=1;next} f&&/^```$/{exit} f{print}' "$1"
}
README_MMD="$(first_mermaid "$README")"
FLOW_MMD="$(first_mermaid "$FLOW")"
n=$(printf '%s\n' "$README_MMD" | grep -c '' | tr -d ' ')
if [ "$n" -ge 20 ]; then ok "diagram: README's mermaid block is $n lines"
else bad "diagram: only $n lines extracted from README — extraction broken?"; fi

if [ "$README_MMD" = "$FLOW_MMD" ]; then
  ok "diagram: README and FLOW.md carry the same sequence diagram"
else
  bad "diagram: README and FLOW.md's mermaid blocks have drifted apart"
fi

# ---------------------------------------------------------------------------
# Internal links resolve
# ---------------------------------------------------------------------------
# Splitting one file into five multiplied the cross-references, and nothing used
# to check them: a section link that survives a rename as a dead anchor is
# invisible in review and obvious to a reader. GitHub's slug rule — lowercase,
# spaces to hyphens, drop punctuation other than - and _ — is reimplemented
# here, and only in-repo targets are followed (http/mailto are somebody else's
# problem).
echo "== internal links resolve =="
anchors_of() {  # $1 = markdown file -> one GitHub anchor slug per heading
  awk '/^```/{f=!f; next} !f && /^#+ /{print}' "$1" \
    | sed -e 's/^#*[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | tr 'A-Z' 'a-z' \
    | sed -e 's/[^a-z0-9 _-]//g' -e 's/ /-/g'
}

checked=0; dead=''
for f in $DOC_FILES; do
  dir="$(dirname "$f")"
  for target in $(grep -ohE '\]\([^)[:space:]]*#[^)[:space:]]*\)' "$f" \
                  | sed -e 's/^](//' -e 's/)$//'); do
    case "$target" in http*|mailto:*) continue ;; esac
    path="${target%%#*}"
    anchor="${target#*#}"
    dest="$f"
    [ -n "$path" ] && dest="$dir/$path"
    checked=$((checked+1))
    if [ ! -f "$dest" ]; then
      dead="$dead $(basename "$f")->$target(no-file)"
    elif ! anchors_of "$dest" | grep -qxF -- "$anchor"; then
      dead="$dead $(basename "$f")->$target"
    fi
  done
done
if [ "$checked" -ge 20 ]; then ok "links: $checked internal anchors checked"
else bad "links: only $checked anchors found — extraction broken?"; fi
list_ok "$dead" "links: every internal anchor resolves to a heading" \
                "links: anchors that resolve to nothing"

echo
printf 'docs smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
