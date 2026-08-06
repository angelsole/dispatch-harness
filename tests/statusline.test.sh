#!/usr/bin/env bash
# Smoke test for the run-feedback surface: statusline.sh rendering, the
# stage-text -> actor contract with run-task.sh, status.sh (one-shot modes
# unchanged + --watch), and install.sh's statusline wiring.
#
# Hermetic: every HARNESS_DIR, settings.json and git repo is fabricated under a
# temp root. The real ~/.claude is never read or written.
#
# Usage: bash tests/statusline.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SL="$SRC/statusline.sh"
ST="$SRC/status.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export NO_COLOR=1          # assert on text, not on SGR escapes
NOW=$(date +%s)

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
grep_ok()  { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
grep_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3"; else ok "$3"; fi; }
lines()    { printf '%s' "$1" | grep -c '' | tr -d ' '; }

if [ -x "$SL" ]; then ok "install: statusline.sh is executable"; else bad "install: statusline.sh is executable"; fi

# A run dir exactly as run-task.sh writes it.
mkrun() {  # $1 harness dir, $2 name, $3 status age, $4 started age, $5 stage, [$6 activity]
  local d="$1/runs/$2"
  mkdir -p "$d"
  printf '%s %s\n' "$((NOW - $3))" "$5" > "$d/status"
  printf '%s\n' "$((NOW - $4))" > "$d/started"
  printf '%s %s\n' "$(date '+%H:%M:%S')" "$5" >> "$d/timeline"
  [ $# -ge 6 ] && printf '%s\n' "$6" > "$d/activity"
  return 0
}

# --- a real branch to measure ±lines against ---------------------------------
WT="$ROOT/repo-fixture"
git init -q "$WT"
printf 'a\n' > "$WT/f.txt"
git -C "$WT" add -A
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m init
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" checkout -q -B work
printf 'b\nc\nd\n' >> "$WT/f.txt"
git -C "$WT" add -A
git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m more

# --- statusline: an active run ------------------------------------------------
echo "== statusline: active run =="
H1="$ROOT/h1"
mkrun "$H1" PROJ-1 20 420 "implementing — Opus (Claude sub)" "⏺ Edit src/app.ts"
printf '%s\n' "$WT" > "$H1/runs/PROJ-1/worktree"
printf 'origin/main\n' > "$H1/runs/PROJ-1/base"

OUT="$(HARNESS_DIR="$H1" bash "$SL" --runs-only </dev/null)"
check   "active: one run line" "$(lines "$OUT")" "1"
grep_ok "$OUT" "PROJ-1"            "active: shows the run id"
grep_ok "$OUT" "Opus"              "active: shows the actor"
grep_ok "$OUT" "⏺ Edit src/app.ts" "active: shows the current activity"
grep_ok "$OUT" "+3-0"              "active: shows ±lines vs. base"
grep_ok "$OUT" "7m"                "active: shows elapsed minutes"

# A worktree that was cleaned up (or does not exist yet) must not break the line.
printf '%s\n' "$ROOT/gone" > "$H1/runs/PROJ-1/worktree"
OUT="$(HARNESS_DIR="$H1" bash "$SL" --runs-only </dev/null)"
grep_ok "$OUT" "PROJ-1"  "active: renders without a worktree"
grep_not "$OUT" "+"      "active: no ±lines when the worktree is gone"
printf '%s\n' "$WT" > "$H1/runs/PROJ-1/worktree"

# --- statusline: waiting / hidden runs ---------------------------------------
echo "== statusline: waiting and hidden runs =="
mkrun "$H1" PROJ-2 300 900 "waiting — implementer needs your input (QUESTIONS.md)"
OUT="$(HARNESS_DIR="$H1" bash "$SL" --runs-only </dev/null)"
grep_ok "$OUT" "⏸ PROJ-2 needs input (5m)" "waiting: renders the needs-input form"
grep_ok "$OUT" "PROJ-1"                    "waiting: other runs still render"

H2="$ROOT/h2"
mkrun "$H2" DONE-1 10 600 "done: ready"
mkrun "$H2" OLD-1 25000 30000 "implementing — Opus (Claude sub)"
OUT="$(HARNESS_DIR="$H2" bash "$SL" --runs-only </dev/null)"
check "hidden: done + >6h-stale runs render nothing" "$OUT" ""

# --- statusline: modes --------------------------------------------------------
echo "== statusline: default vs --runs-only =="
H3="$ROOT/h3"; mkdir -p "$H3"
SESSION="$ROOT/session.json"
printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5"}}\n' "$WT" > "$SESSION"

OUT="$(HARNESS_DIR="$H3" bash "$SL" --runs-only </dev/null)"
check "runs-only: empty with no active runs" "$OUT" ""

OUT="$(HARNESS_DIR="$H3" bash "$SL" < "$SESSION")"
check   "default: first line even with no runs" "$(lines "$OUT")" "1"
grep_ok "$OUT" "repo-fixture" "default: cwd basename from the session JSON"
grep_ok "$OUT" "work"         "default: git branch of that cwd"
grep_ok "$OUT" "Opus 5"       "default: model display name"

OUT="$(HARNESS_DIR="$H1" bash "$SL" < "$SESSION")"
check "default: first line + one line per active run" "$(lines "$OUT")" "3"

# HARNESS_DIR must be honored — an unset one would read the real ~/.claude.
OUT="$(HARNESS_DIR="$ROOT/nowhere" bash "$SL" --runs-only </dev/null)"
check "runs-only: silent when HARNESS_DIR has no runs dir" "$OUT" ""

# --- the stage -> actor contract ---------------------------------------------
# Every literal stage() string the pipeline can write must map to a known actor.
# A rename that outruns statusline.sh's mapping shows up here as "?".
echo "== stage -> actor mapping (every stage() literal) =="
STAGES="$ROOT/stages.txt"
grep -hoE 'stage "[^"]+"' "$SRC/run-task.sh" "$SRC/sync-pr.sh" \
  | sed -e 's/^stage "//' -e 's/"$//' \
        -e 's/\$[A-Za-z_][A-Za-z0-9_]*/X/g' -e 's/\$[0-9]/X/g' \
  | sort -u > "$STAGES"
n=$(grep -c '' < "$STAGES" | tr -d ' ')
if [ "$n" -ge 20 ]; then ok "mapping: found $n stage literals"; else bad "mapping: only $n stage literals found — extraction broken?"; fi

MAPH="$ROOT/mapping"
unknown=''; miscounted=''
while IFS= read -r s; do
  [ -n "$s" ] || continue
  rm -rf "$MAPH"
  mkrun "$MAPH" MAP-1 5 300 "$s"
  out="$(HARNESS_DIR="$MAPH" bash "$SL" --runs-only </dev/null)"
  case "$s" in
    done:*)
      [ -z "$out" ] || miscounted="$miscounted
    finished run still rendered: $s" ;;
    *)
      if [ -z "$out" ]; then
        miscounted="$miscounted
    live run rendered nothing: $s"
      elif printf '%s' "$out" | grep -qF 'MAP-1 ?'; then
        unknown="$unknown
    $s"
      fi ;;
  esac
done < "$STAGES"
if [ -z "$unknown" ]; then ok "mapping: every stage literal maps to a known actor"
else bad "mapping: stage literals with no actor:$unknown"; fi
if [ -z "$miscounted" ]; then ok "mapping: live stages render, done: stages hide"
else bad "mapping: wrong visibility:$miscounted"; fi

actor_of() {  # $1 = stage text -> the actor column
  rm -rf "$MAPH"
  mkrun "$MAPH" MAP-1 5 300 "$1"
  HARNESS_DIR="$MAPH" bash "$SL" --runs-only </dev/null | awk '{print $3}'
}
check "actor: implementing -> Opus"   "$(actor_of 'implementing — Opus (Claude sub)')"                 "Opus"
check "actor: resuming -> Opus"       "$(actor_of 'resuming — Opus (Claude sub)')"                     "Opus"
check "actor: turn-ceiling resume -> Opus" "$(actor_of 'resuming: turn ceiling (1/2)')"                "Opus"
check "actor: review -> Codex"        "$(actor_of 'review — Codex (ChatGPT sub)')"                     "Codex"
check "actor: fix round -> Codex"     "$(actor_of 'fix round 2 — Codex (ChatGPT sub)')"                "Codex"
check "actor: test gate -> gate"      "$(actor_of 'test gate #1 (deterministic — no model)')"          "gate"
check "actor: push -> PR"             "$(actor_of 'push + draft PR (script — no model)')"              "PR"
check "actor: demo -> demo"           "$(actor_of 'demo — recording (script, no model)')"              "demo"
check "actor: review skipped is not Codex" "$(actor_of 'review skipped — no codex CLI found (Claude-only mode)')" "skipped"

# --- status.sh: one-shot modes unchanged --------------------------------------
echo "== status.sh: one-shot modes =="
HDR="$(printf '%-26s %-46s %-12s %s' RUN STAGE 'IN STAGE' TOTAL)"
OUT="$(HARNESS_DIR="$H1" bash "$ST")"
check   "table: header unchanged" "$(printf '%s' "$OUT" | sed -n 1p)" "$HDR"
grep_ok "$OUT" "PROJ-1"                           "table: lists the run"
grep_ok "$OUT" "implementing — Opus (Claude sub)" "table: lists its stage"

OUT="$(HARNESS_DIR="$H1" bash "$ST" PROJ-1)"
grep_ok "$OUT" "== PROJ-1 timeline =="            "ticket: prints the timeline"
grep_ok "$OUT" "implementing — Opus (Claude sub)" "ticket: timeline content"

if HARNESS_DIR="$H1" bash "$ST" NOPE >/dev/null 2>&1; then
  bad "ticket: unknown run should exit non-zero"
else
  ok "ticket: unknown run exits non-zero"
fi
check "table: empty harness dir" "$(HARNESS_DIR="$ROOT/nowhere" bash "$ST")" "no runs yet"

# --- status.sh --watch --------------------------------------------------------
echo "== status.sh --watch =="
WOUT="$ROOT/watch.out"
HARNESS_WATCH_INTERVAL=0.2 HARNESS_DIR="$H1" bash "$ST" --watch > "$WOUT" 2>&1 &
wpid=$!
sleep 1
kill "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
frames=$(grep -ao '\[H' "$WOUT" | grep -c '' | tr -d ' ')
if [ "$frames" -ge 2 ]; then
  ok "watch: redraws in place ($frames frames, each home+erase — no stacking)"
else
  bad "watch: expected >=2 in-place redraws, got $frames"
fi
WATCHED="$(cat "$WOUT")"
grep_ok "$WATCHED" "PROJ-1"            "watch: lists the run"
grep_ok "$WATCHED" "Opus"              "watch: actor column"
grep_ok "$WATCHED" "⏺ Edit src/app.ts" "watch: activity column"
grep_ok "$WATCHED" "ACTIVITY"          "watch: column headers"
if HARNESS_WATCH_INTERVAL=fast HARNESS_DIR="$H1" bash "$ST" --watch >/dev/null 2>&1; then
  bad "watch: invalid refresh interval should exit non-zero"
else
  ok "watch: invalid refresh interval exits non-zero"
fi

# --- install.sh: statusline wiring -------------------------------------------
echo "== install.sh: statusline wiring =="
inst() {  # $1 = harness dir, $2 = settings file, rest = install.sh args
  local h="$1" s="$2"; shift 2
  HOME="$ROOT/home" HARNESS_DIR="$h" CLAUDE_SKILLS_DIR="$h/skills" \
    CLAUDE_SETTINGS_FILE="$s" bash "$SRC/install.sh" "$@" </dev/null 2>&1
}
inst_tty() {  # $1 = harness dir, $2 = settings file; explicit consent in a PTY
  local h="$1" s="$2" cmd
  if script -q /dev/null true </dev/null >/dev/null 2>&1; then
    HOME="$ROOT/home" HARNESS_DIR="$h" CLAUDE_SKILLS_DIR="$h/skills" \
      CLAUDE_SETTINGS_FILE="$s" script -q /dev/null \
      bash "$SRC/install.sh" --statusline </dev/null 2>&1
  else
    printf -v cmd 'bash %q --statusline' "$SRC/install.sh"
    HOME="$ROOT/home" HARNESS_DIR="$h" CLAUDE_SKILLS_DIR="$h/skills" \
      CLAUDE_SETTINGS_FILE="$s" script -qec "$cmd" /dev/null </dev/null 2>&1
  fi
}
backups() { find "$ROOT" -maxdepth 1 -name "$(basename "$1").bak-*" | grep -c '' | tr -d ' '; }

SA="$ROOT/settingsA.json"; printf '{"model":"opus"}\n' > "$SA"
OUT="$(inst_tty "$ROOT/instA" "$SA")"
check "consent: statusLine written"  "$(jq -r '.statusLine.command' "$SA")" "$ROOT/instA/statusline.sh"
check "consent: type is command"     "$(jq -r '.statusLine.type' "$SA")"    "command"
check "consent: other keys survive"  "$(jq -r '.model' "$SA")"              "opus"
check "consent: one timestamped backup" "$(backups "$SA")" "1"
check "consent: backup holds the original" \
  "$(cat "$ROOT"/settingsA.json.bak-*)" '{"model":"opus"}'
if [ -x "$ROOT/instA/statusline.sh" ]; then ok "install: statusline.sh installed executable"; else bad "install: statusline.sh installed executable"; fi

SB="$ROOT/settingsB.json"; printf '{"statusLine":{"type":"command","command":"/my/own"}}\n' > "$SB"
BEFORE="$(cat "$SB")"
OUT="$(inst "$ROOT/instB" "$SB" --statusline)"
check   "existing: settings.json untouched" "$(cat "$SB")" "$BEFORE"
check   "existing: no backup written"       "$(backups "$SB")" "0"
grep_ok "$OUT" "already defines a statusLine" "existing: says so"
grep_ok "$OUT" "--runs-only"                  "existing: prints the compose one-liner"

SC="$ROOT/settingsC.json"; printf '{}\n' > "$SC"
OUT="$(inst "$ROOT/instC" "$SC" --statusline)"
check   "non-interactive: settings.json untouched" "$(cat "$SC")" "{}"
check   "non-interactive: no backup written"       "$(backups "$SC")" "0"
grep_ok "$OUT" "not a terminal"  "non-interactive: explains why"
grep_ok "$OUT" "statusLine"      "non-interactive: prints manual instructions"

SD="$ROOT/settingsD.json"; printf '{}\n' > "$SD"
OUT="$(inst "$ROOT/instD" "$SD" --no-statusline)"
check   "--no-statusline: settings.json untouched" "$(cat "$SD")" "{}"
grep_ok "$OUT" "--runs-only" "--no-statusline: still prints the instructions"

echo
printf 'statusline smoke: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
