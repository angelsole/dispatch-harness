#!/usr/bin/env bash
# The feedback loop: lib/lessons.sh's distillation, lessons.sh's CLI, and the
# contract that hangs off them — the dispatch mounts the file, the implementer
# prompt points at it, the planner protocol tells the planner to read it, and
# the janitor refreshes it.
#
# Everything is fabricated under a temp root: a HARNESS_DIR with hand-written
# run dirs, and two real git repos (one of them sharing the other's basename, to
# pin the slug). No worker, no network, no writes outside it.
#
# The regression this suite exists for above all is the field collapse: rows are
# tab-separated and bash `read` treats tab as IFS *whitespace*, so a run with no
# outcome note used to shift every column after it one place left and render the
# claim where the filename belongs.
#
# Usage: bash tests/lessons.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
RT="$SRC/run-task.sh"
SKILL="$SRC/skills/dispatch/SKILL.md"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lessons-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has(){ if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

export HARNESS_DIR="$ROOT/harness"
mkdir -p "$HARNESS_DIR/runs"
# shellcheck source=lib/common.sh
. "$SRC/lib/common.sh"
# shellcheck source=lib/lessons.sh
. "$SRC/lib/lessons.sh"

# A timestamp N days back, in touch(1)'s format, on either date(1).
ago_stamp() {  # $1 = days
  date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M
}

mkrepo() {  # $1 = path, rest = files to track
  local d="$1"; shift
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@e.st; git -C "$d" config user.name Test
  local f
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo "x" > "$d/$f"; done
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm init >/dev/null 2>&1
}

# One run dir: findings, an age, and optionally an outcome.
# mkrun <id> <repo> <days-old> <promoted-json> [outcome-json]
mkrun() {
  local d="$HARNESS_DIR/runs/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/repo"
  printf '{"ticket":"%s","status":"ready"}\n' "$1" > "$d/result.json"
  printf '%s\n' "$4" > "$d/promoted.json"
  [ -n "${5:-}" ] && printf '%s\n' "$5" > "$d/outcome.json"
  touch -t "$(ago_stamp "$3")" "$d/result.json"
}

REPO="$ROOT/api"
TWIN="$ROOT/nested/api"          # same basename, different checkout
mkrepo "$REPO" src/pricing.ts src/loader.ts src/cache.ts src/a.ts src/b.ts src/c.ts \
                src/d.ts src/e.ts src/f.ts src/g.ts src/h.ts
mkrepo "$TWIN" src/other.ts

# $TMPDIR is /var/folders/… on macOS while pwd -P answers /private/var/folders/…
# The library canonicalises both; the fixture keeps the raw spelling on purpose,
# so that every lookup below is crossing that boundary the way a real one does.
CANON=$(cd "$REPO" && pwd -P)

echo "== the slug =="
A=$(lessons_slug "$REPO"); B=$(lessons_slug "$TWIN")
check "slug: keeps the basename readable" "${A%%-*}" "api"
if [ "$A" != "$B" ]; then ok "slug: two checkouts sharing a basename get different files"
else bad "slug: $REPO and $TWIN collide on [$A]"; fi
check "slug: stable across calls" "$(lessons_slug "$REPO")" "$A"
check "slug: one spelling per repo (/var vs /private/var)" "$(lessons_slug "$CANON")" "$A"

echo "== path policy =="
check "path: a leading ./ is stripped"      "$(lessons_rel_path './src/a.ts')" "src/a.ts"
check "path: an absolute path is refused"   "$(lessons_rel_path '/etc/passwd')" ""
check "path: an escaping path is refused"   "$(lessons_rel_path '../secrets')" ""
check "path: orchestration metadata is refused" "$(lessons_rel_path '.harness/brief.md')" ""

echo "== what enters, and what never does =="
# Two runs trip over pricing.ts; one of them also files a doubted finding and a
# finding on a file this repo does not track.
mkrun R1 "$REPO" 2 '[{"id":"F1","file":"src/pricing.ts","line":10,"claim":"rounding runs before the tier lookup"},
                     {"id":"F2","file":"src/pricing.ts","claim":"a doubt nobody confirmed","doubted":true},
                     {"id":"F3","file":"src/imaginary.ts","claim":"a path the reviewer invented"},
                     {"id":"F4","file":".harness/brief.md","claim":"metadata is not code"}]'
mkrun R2 "$REPO" 1 '[{"id":"F1","file":"src/pricing.ts","claim":"the tier edge compares with > not >="}]'
# A single-run trap, recent: survives. Its PR was reverted, so it outranks.
mkrun R3 "$REPO" 3 '[{"id":"F1","file":"src/loader.ts","claim":"the loader keys its cache by object identity"}]' \
                   '{"pr_state":"MERGED","reverted":true,"review_comment_count":0,"follow_up_commits":0}'
# A single-run trap, stale: evicted as an anecdote.
mkrun R4 "$REPO" 40 '[{"id":"F1","file":"src/cache.ts","claim":"an anecdote from six weeks ago"}]'
# Older than LESSONS_MAX_AGE: contributes nothing at all.
mkrun R5 "$REPO" 90 '[{"id":"F1","file":"src/a.ts","claim":"ancient history"}]'
# A different repo's run must not leak into this repo's file.
mkrun R6 "$TWIN" 1 '[{"id":"F1","file":"src/other.ts","claim":"belongs to the twin"}]'

N=$(lessons_render "$REPO")
FILE=$(lessons_file "$REPO")
check "render: reports the trap count it wrote" "$N" "2"
OUT=$(cat "$FILE")
has     "$OUT" 'src/pricing.ts'  "enters: a file two runs tripped over"
has     "$OUT" 'src/loader.ts'   "enters: a recent single-run trap"
has     "$OUT" 'rounding runs before the tier lookup' "enters: the reviewer's own words, verbatim"
has_not "$OUT" 'a doubt nobody confirmed'   "excluded: a finding the refuter could not confirm"
has_not "$OUT" 'src/imaginary.ts'           "excluded: a path this repo does not track"
has_not "$OUT" '.harness/brief.md'          "excluded: orchestration metadata"
has_not "$OUT" 'src/cache.ts'               "excluded: a one-run trap past LESSONS_SOLO_MAX_AGE"
has_not "$OUT" 'ancient history'            "excluded: a run past LESSONS_MAX_AGE"
has_not "$OUT" 'belongs to the twin'        "excluded: another repo's findings"
file_has "$FILE" 'edits are overwritten' "render: says the file is generated"

echo "== the field alignment regression =="
# R1/R2 have no outcome.json, so their notes column is empty. Tab is IFS
# whitespace: an empty column used to be swallowed and every field after it
# shifted left, rendering the CLAIM where the filename belongs.
if grep -q '^- `src/pricing.ts` — 2 runs, last ' "$FILE"; then
  ok "alignment: a trap with no outcome note still renders file, count and date in place"
else
  bad "alignment: the no-note row is malformed: $(grep -m1 'pricing' "$FILE")"
fi
file_has "$FILE" 'reverted' "render: names what the world charged for the PR"

echo "== ranking and the cap =="
# A reverted PR (1 + 3) outranks two quiet runs (1 + 1).
check "rank: the costliest trap is first" \
  "$(grep -m1 '^- `' "$FILE" | sed 's/^- `\([^`]*\)`.*/\1/')" "src/loader.ts"
for f in b c d e f g h; do
  mkrun "CAP-$f" "$REPO" 1 "[{\"id\":\"F1\",\"file\":\"src/$f.ts\",\"claim\":\"capped trap $f\"}]"
done
LESSONS_MAX_ENTRIES=3 lessons_render "$REPO" >/dev/null
check "cap: LESSONS_MAX_ENTRIES bounds the file" "$(grep -c '^- `' "$FILE")" "3"
LESSONS_MAX_CLAIMS=1 LESSONS_MAX_ENTRIES=8 lessons_render "$REPO" >/dev/null
check "cap: LESSONS_MAX_CLAIMS bounds a trap's quotes" \
  "$(awk '/^- `src\/pricing.ts`/{f=1;next} /^- `/{f=0} f' "$FILE" | grep -c '^  - ')" "1"

echo "== nothing to say =="
rm -rf "${HARNESS_DIR:?}/runs"/*
lessons_render "$REPO" >/dev/null
if [ -e "$FILE" ]; then bad "empty: a repo with no traps left its file behind"
else ok "empty: a repo with no traps has its file removed, not emptied"; fi
check "empty: --show prints nothing" "$(bash "$SRC/lessons.sh" --show "$REPO")" ""
bash "$SRC/lessons.sh" --show "$REPO" >/dev/null 2>&1
check "empty: --show still succeeds" "$?" "0"

echo "== the CLI =="
mkrun C1 "$REPO" 1 '[{"id":"F1","file":"src/pricing.ts","claim":"one for the cli"}]'
mkrun C2 "$REPO" 2 '[{"id":"F1","file":"src/pricing.ts","claim":"two for the cli"}]'
REFRESH=$(bash "$SRC/lessons.sh" --refresh 2>&1)
has "$REFRESH" "trap(s)" "cli: --refresh reports what it wrote"
has "$(bash "$SRC/lessons.sh" --show "$REPO")" 'src/pricing.ts' "cli: --show prints the repo's traps"
check "cli: --path answers where the file lives" \
  "$(bash "$SRC/lessons.sh" --path "$REPO")" "$FILE"
check "cli: --path resolves a subdirectory to its repo root" \
  "$(bash "$SRC/lessons.sh" --path "$REPO/src")" "$FILE"
has "$(bash "$SRC/lessons.sh" --list)" "$CANON" "cli: --list names the repo in its canonical spelling"
bash "$SRC/lessons.sh" --nonsense >/dev/null 2>&1
check "cli: an unknown flag is refused" "$?" "2"

echo "== the staleness gate =="
touch "$FILE"
BEFORE=$(harness_mtime "$FILE")
lessons_refresh_if_stale "$REPO"
check "stale: a fresh file is not regenerated" "$(harness_mtime "$FILE")" "$BEFORE"
touch -t "$(ago_stamp 2)" "$FILE"
lessons_refresh_if_stale "$REPO"
if [ "$(harness_mtime "$FILE")" != "$(date -j -f %Y%m%d%H%M "$(ago_stamp 2)" +%s 2>/dev/null || echo x)" ]; then
  ok "stale: a file past LESSONS_STALE_HOURS is regenerated"
else
  bad "stale: an old file was left alone"
fi

echo "== the dispatch mounts it =="
# mount_lessons() is lifted out of run-task.sh by source extraction: the script
# runs its whole pipeline on source, so it cannot be sourced.
FUNC="$(awk '/^mount_lessons\(\)/{f=1} f{print} f&&/^}$/{exit}' "$RT")"
has "$FUNC" 'lessons_refresh_if_stale' "extract: mount_lessons() lifted from run-task.sh"
eval "$FUNC"
WT="$ROOT/wt"; mkdir -p "$WT/.harness"
bash "$SRC/lessons.sh" --refresh "$REPO" >/dev/null
mount_lessons "$REPO" "$WT"
if [ -s "$WT/.harness/lessons.md" ]; then ok "mount: the repo's traps land at .harness/lessons.md"
else bad "mount: nothing was mounted"; fi
file_has "$WT/.harness/lessons.md" 'src/pricing.ts' "mount: with the traps in it"
# Within LESSONS_STALE_HOURS the dispatch reuses the last distillation rather
# than rebuilding it on every run — that is what the gate is for.
rm -rf "${HARNESS_DIR:?}/runs"/*
mount_lessons "$REPO" "$WT"
if [ -s "$WT/.harness/lessons.md" ]; then ok "mount: a fresh distillation is reused, not rebuilt per run"
else bad "mount: the staleness gate did not hold the file"; fi
# Once the file itself is gone — the janitor removed it, or the repo never had
# traps — the mount takes the previous run's copy away with it.
rm -f "$(lessons_file "$REPO")"
mount_lessons "$REPO" "$WT"
if [ -e "$WT/.harness/lessons.md" ]; then bad "mount: a stale lessons.md outlived its source"
else ok "mount: a repo with no traps unmounts the previous run's file"; fi

echo "== the contract =="
file_has "$RT" '.harness/lessons.md' "contract: the implementer prompt names the mounted file"
file_has "$RT" 'advisory context, never a task' "contract: and says it is advisory"
file_has "$SKILL" 'lessons.sh --show' "contract: the planner protocol tells the planner to read it"
file_has "$SRC/janitor.sh" 'distil_lessons' "contract: the janitor refreshes it"
file_has "$SRC/janitor.sh" 'lessons_refresh_all' "contract: through the library, not its own copy"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
