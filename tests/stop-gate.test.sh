#!/usr/bin/env bash
# lib/stop-gate.sh's contract: an armed implementer session may not end with
# zero commits — unless it asked (QUESTIONS.md), rejected (REJECTED.md), ran
# out of nudges, or anything at all is uncertain, in which case the stop is
# always allowed. The disabled path must be free and silent, exactly like
# wall-hook.sh's: this hook runs on every Stop of every worker.
#
# Usage: bash tests/stop-gate.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/lib/stop-gate.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/stop-gate-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

# A worktree the way run-task.sh leaves one: a branch cut from a base ref.
WT="$ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$WT" branch basepoint
git -C "$WT" checkout -q -b work
mkdir -p "$WT/.harness"

STATE="$ROOT/stop-gate.blocks"
run_hook() {  # env pairs as args, e.g. run_hook HARNESS_STOP_GATE=on
  env -i PATH="$PATH" HOME="$ROOT" "$@" bash "$HOOK" </dev/null
}
armed() {
  run_hook HARNESS_STOP_GATE=on \
    HARNESS_STOP_GATE_WORKTREE="$WT" HARNESS_STOP_GATE_BASE=basepoint \
    HARNESS_STOP_GATE_STATE="$STATE" "$@"
}

echo "== disarmed and uncertain paths allow the stop =="
out=$(run_hook); check "unarmed: silent" "$out" ""; check "unarmed: exit 0" "$?" "0"
out=$(run_hook HARNESS_STOP_GATE=on)
check "armed without a worktree: silent allow" "$out" ""
out=$(run_hook HARNESS_STOP_GATE=on \
  HARNESS_STOP_GATE_WORKTREE="$ROOT/no-such-dir" HARNESS_STOP_GATE_BASE=basepoint)
check "missing worktree dir: silent allow" "$out" ""
out=$(armed HARNESS_STOP_GATE_BASE=no-such-ref)
check "unresolvable base ref: silent allow" "$out" ""

echo "== zero commits is refused, with the state named =="
echo dirty > "$WT/file.txt"; git -C "$WT" add file.txt
out=$(armed)
has "$out" '"decision":"block"' "dirty tree, no commits: the stop is blocked"
has "$out" "staged or unstaged changes" "dirty: the reason names the uncommitted work"
has "$out" "QUESTIONS.md" "dirty: and offers the sanctioned way out"
printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && ok "block output is valid JSON" || bad "block output is valid JSON"
check "first block is counted" "$(cat "$STATE")" "1"

git -C "$WT" -c user.name=t -c user.email=t@t stash -q
out=$(armed)
has "$out" '"decision":"block"' "clean tree, no commits: still blocked"
has "$out" "neither commits nor questions" "clean: the reason states the rule"
has "$out" "REJECTED.md" "clean: a reasoned rejection is offered too"
check "second block is counted" "$(cat "$STATE")" "2"

echo "== the nudge budget releases the run to die honestly =="
out=$(armed)
check "third stop: past the cap, allowed" "$out" ""
check "and the count stops moving" "$(cat "$STATE")" "2"
echo 0 > "$STATE"
out=$(armed HARNESS_STOP_GATE_MAX=0)
check "HARNESS_STOP_GATE_MAX=0 disables the nudges" "$out" ""
out=$(armed HARNESS_STOP_GATE_MAX=junk)
has "$out" '"decision":"block"' "an unparseable cap falls back to the default, still guarding"
echo 0 > "$STATE"

echo "== sanctioned stops pass with zero commits =="
echo "why?" > "$WT/.harness/QUESTIONS.md"
out=$(armed); check "QUESTIONS.md on file: allowed" "$out" ""
rm "$WT/.harness/QUESTIONS.md"
: > "$WT/.harness/QUESTIONS.md"       # zero bytes is not a question
out=$(armed); has "$out" '"decision":"block"' "an EMPTY QUESTIONS.md does not open the door"
rm "$WT/.harness/QUESTIONS.md"; echo 0 > "$STATE"
echo "wrong approach" > "$WT/.harness/REJECTED.md"
out=$(armed); check "REJECTED.md on file: allowed" "$out" ""
rm "$WT/.harness/REJECTED.md"

echo "== a commit is the other key =="
git -C "$WT" -c user.name=t -c user.email=t@t stash pop -q
git -C "$WT" -c user.name=t -c user.email=t@t commit -qam "real work"
echo 0 > "$STATE"
out=$(armed)
check "one commit past base: allowed" "$out" ""
check "and no nudge is spent on it" "$(cat "$STATE")" "0"

echo "== the wiring run-task.sh and worker-settings.json promise =="
python3 - "$SRC/worker-settings.json" <<'PYEOF' && ok "settings: stop-gate.sh is wired to Stop" || bad "settings: stop-gate.sh is wired to Stop"
import json,sys
d=json.load(open(sys.argv[1]))
cmds=[h.get("command","") for grp in d["hooks"]["Stop"] for h in grp["hooks"]]
assert any("stop-gate.sh" in c for c in cmds)
assert any("wall-hook.sh" in c for c in cmds), "the wall still hears the stop"
PYEOF
wired=$(grep -c 'HARNESS_STOP_GATE_WORKTREE="\$WORKTREE"' "$SRC/run-task.sh")
check "run-task.sh arms the gate for implementer segments" "$wired" "1"
grep -q 'HARNESS_STOP_GATE_STATE="\$RUN_DIR/stop-gate.blocks"' "$SRC/run-task.sh" \
  && ok "the nudge count lives in the run dir" || bad "the nudge count lives in the run dir"
# The gate must be an implementer-only affair: every other claude invocation —
# the claude-only review, the refute pass, the fix rounds — shares
# worker-settings.json and must NOT carry the arming var. So every mention of
# HARNESS_STOP_GATE in run-task.sh has to sit inside opus_attempt itself.
outside=$(awk '/^opus_attempt\(\) \{/{f=1} f&&/^\}/{f=0;next} !f' "$SRC/run-task.sh" \
  | grep -c 'HARNESS_STOP_GATE' || true)
check "no stage outside opus_attempt arms the gate" "$outside" "0"
inside=$(awk '/^opus_attempt\(\) \{/{f=1} f&&/^\}/{f=0;next} f' "$SRC/run-task.sh" \
  | grep -c 'HARNESS_STOP_GATE' || true)
check "and opus_attempt arms all four variables" "$inside" "4"

echo
printf 'stop gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
