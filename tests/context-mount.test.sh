#!/usr/bin/env bash
# Smoke test for the spec-attachment mount: run-task.sh's mount_specs() and the
# contract that hangs off it — the mount runs before the implementer, both
# worker prompts point at it, and the planner-side docs say how specs get there.
#
# mount_specs() is lifted out of run-task.sh by source extraction: the script
# runs its whole pipeline on source, so it cannot be sourced. Same technique the
# other suites use to read install.sh's FILES array and the stage() literals.
#
# Hermetic: every run dir and worktree is fabricated under a temp root. No
# worker, no network, no writes outside it.
#
# Usage: bash tests/context-mount.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
RT="$SRC/run-task.sh"
TPL="$SRC/brief-template.md"
SKILL="$SRC/skills/dispatch/SKILL.md"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/context-mount-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
grep_ok()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
file_has() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- lift mount_specs() out of run-task.sh -----------------------------------
FUNC="$(awk '/^mount_specs\(\)/{f=1} f{print} f&&/^}$/{exit}' "$RT")"
grep_ok "$FUNC" 'cp -R' "extract: mount_specs() lifted from run-task.sh"
eval "$FUNC"

# A run dir + worktree laid out the way run-task.sh's context mount finds them:
# the brief and the workers' notes are the neighbours the mount must not disturb.
mkrun() {  # $1 = fixture name -> sets RUN, WT
  RUN="$ROOT/$1/run"; WT="$ROOT/$1/wt"
  mkdir -p "$RUN" "$WT/.harness"
  printf 'the brief\n' > "$WT/.harness/brief.md"
  printf 'the notes\n' > "$WT/.harness/implementer-notes.md"
}

echo "== no specs in the run dir: today's behaviour, unchanged =="
mkrun bare
mount_specs "$RUN" "$WT"; check "bare: succeeds" "$?" "0"
absent "bare: no specs dir invented"   "$WT/.harness/specs"
check  "bare: brief untouched" "$(cat "$WT/.harness/brief.md")" "the brief"

echo "== run dir with specs: mirrored into the worktree =="
mkrun mounted
mkdir -p "$RUN/specs/annex"
printf 'tier rules\n' > "$RUN/specs/margin.md"
printf 'annexed\n'    > "$RUN/specs/annex/tables.md"
mount_specs "$RUN" "$WT"; check "mount: succeeds" "$?" "0"
check "mount: file contents travel"  "$(cat "$WT/.harness/specs/margin.md")"      "tier rules"
check "mount: nested dirs travel"    "$(cat "$WT/.harness/specs/annex/tables.md")" "annexed"
check "mount: brief still there"     "$(cat "$WT/.harness/brief.md")"             "the brief"

echo "== resume with a revised spec set: replaced, not merged =="
# Same run dir, re-converted by the planner: one file rewritten, one dropped,
# one added. A resumed worker must see exactly this set and nothing else.
printf 'tier rules v2\n' > "$RUN/specs/margin.md"
rm -rf "$RUN/specs/annex"
printf 'new sheet\n' > "$RUN/specs/pricing.md"
mount_specs "$RUN" "$WT"; check "resume: succeeds" "$?" "0"
check  "resume: revised file replaced" "$(cat "$WT/.harness/specs/margin.md")" "tier rules v2"
exists "resume: added file mounted"    "$WT/.harness/specs/pricing.md"
absent "resume: dropped file gone"     "$WT/.harness/specs/annex"

echo "== no run-dir specs on a later invocation: existing context is untouched =="
rm -rf "$RUN/specs"
mount_specs "$RUN" "$WT"; check "withdrawn: succeeds" "$?" "0"
check "withdrawn: existing spec context untouched" \
  "$(cat "$WT/.harness/specs/margin.md")" "tier rules v2"
exists "withdrawn: existing spec set untouched" "$WT/.harness/specs/pricing.md"
check  "withdrawn: notes left alone" "$(cat "$WT/.harness/implementer-notes.md")" "the notes"

echo "== wiring: mounted before the implementer, and both workers told =="
call_line=$(grep -nF 'mount_specs "$RUN_DIR" "$WORKTREE"' "$RT" | cut -d: -f1)
impl_line=$(grep -nF 'IMPLEMENTER_PROMPT="You are the implementer' "$RT" | cut -d: -f1)
if [ -n "$call_line" ] && [ -n "$impl_line" ] && [ "$call_line" -lt "$impl_line" ]; then
  ok "wiring: mount_specs runs in the context mount, before the implementer"
else
  bad "wiring: mount_specs must run before the implementer (call=[$call_line] implementer=[$impl_line])"
fi
grep_ok "$(awk '/^IMPLEMENTER_PROMPT="/,/^$/' "$RT")" '.harness/specs/' \
  "wiring: the implementer prompt points at .harness/specs/"
grep_ok "$(grep -F 'OPUS_PROMPT="The orchestrator updated' "$RT")" '.harness/specs/' \
  "wiring: the resumed implementer is told to re-read .harness/specs/"
grep_ok "$(grep -F 'Context (all inside .harness/)' "$RT")" 'specs/' \
  "wiring: the reviewer's context line names specs/"

echo "== planner side: how specs reach the run dir is documented =="
file_has "$TPL"   '## Attached specs'        "template: brief-template.md ships the Attached specs section"
file_has "$TPL"   '.harness/specs/'          "template: Attached specs names the mount path"
file_has "$SKILL" 'npx -y @firecrawl/anydoc' "skill: the planner converts attachments with anydoc"
file_has "$SKILL" '/specs/'                  "skill: conversion output lands in the run dir's specs/"

echo
printf 'context mount: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
