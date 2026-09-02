#!/usr/bin/env bash
# The QUALITY_GATE contract, in four parts:
#   1. lib/quality-gate.sh judges exactly the files the branch touches — the
#      linters are stubbed, so what is asserted is the scoping, the generated
#      config (thresholds land where the knobs say), the suppression check and
#      the exit codes, with no network and no real toolchain.
#   2. repos.conf.sh composes the pinned repo's GATE_CMD as quality gate first,
#      original gate second, and resets the pin between repos.
#   3. A real run-task.sh invocation (fake workers, local bare remote — the
#      preprod suite's fixture shape) gets the quality posture in BOTH worker
#      prompts when pinned and byte-identical prompts when not, and its gate
#      round actually runs the quality gate.
#   4. The knob is documented where the other pins are.
#
# Usage: bash tests/quality-gate.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/quality-gate-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3"; else ok "$3"; fi; }

# --- stub linters: record argv + config, exit as told ------------------------
FAKES="$ROOT/bin"; mkdir -p "$FAKES"
cat > "$FAKES/oxlint-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$OX_ARGS"
prev=""
for a in "$@"; do [ "$prev" = "-c" ] && cp "$a" "$OX_CFG"; prev="$a"; done
exit "${OX_EXIT:-0}"
SH
cat > "$FAKES/ruff-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUFF_ARGS"
prev=""
for a in "$@"; do [ "$prev" = "--config" ] && cp "$a" "$RUFF_CFG"; prev="$a"; done
exit "${RUFF_EXIT:-0}"
SH
chmod +x "$FAKES/oxlint-stub" "$FAKES/ruff-stub"

# --- fixture repo for the unit half ------------------------------------------
UREPO="$ROOT/urepo"
git init -q "$UREPO"
git -C "$UREPO" config user.email t@t
git -C "$UREPO" config user.name  t
printf 'export const a = 1;\n'       > "$UREPO/good.ts"
printf 'export const gone = 1;\n'    > "$UREPO/dead.ts"
printf 'x = 1\n'                     > "$UREPO/util.py"
printf 'prose\n'                     > "$UREPO/note.txt"
git -C "$UREPO" add . && git -C "$UREPO" commit -qm base
git -C "$UREPO" branch -M main
git -C "$UREPO" checkout -qb feat
printf 'export const a = 2;\n'       > "$UREPO/good.ts"
printf 'export const b = 3;\n'       > "$UREPO/new.ts"
printf 'x = 2\n'                     > "$UREPO/util.py"
printf 'prose v2\n'                  > "$UREPO/note.txt"
git -C "$UREPO" rm -q dead.ts
git -C "$UREPO" add . && git -C "$UREPO" commit -qm change

run_qg() {  # runs quality-gate.sh in $UREPO with stubs; extra env as "K=V" args
  OUT="$ROOT/qg-out"; : > "$OUT"
  rm -f "$ROOT/ox-args" "$ROOT/ox-cfg" "$ROOT/ruff-args" "$ROOT/ruff-cfg"
  (cd "$UREPO" && env \
     QG_OXLINT_BIN="$FAKES/oxlint-stub" OX_ARGS="$ROOT/ox-args" OX_CFG="$ROOT/ox-cfg" \
     QG_RUFF_BIN="$FAKES/ruff-stub" RUFF_ARGS="$ROOT/ruff-args" RUFF_CFG="$ROOT/ruff-cfg" \
     "$@" bash "$SRC/lib/quality-gate.sh" --base main) > "$OUT" 2>&1
}

echo "== scoping: the gate judges the branch's files and nothing else =="
if run_qg; then ok "clean branch: exit 0"; else bad "clean branch: exit 0 (output: $(cat "$OUT"))"; fi
OX="$(cat "$ROOT/ox-args" 2>/dev/null || true)"
RF="$(cat "$ROOT/ruff-args" 2>/dev/null || true)"
has     "$OX" 'good.ts' "oxlint gets the modified TS file"
has     "$OX" 'new.ts'  "oxlint gets the added TS file"
has_not "$OX" 'dead.ts' "oxlint never sees the deleted file"
has_not "$OX" 'note.txt' "oxlint never sees a non-code file"
has_not "$OX" 'util.py' "oxlint never sees a Python file"
has     "$RF" 'util.py' "ruff gets the modified Python file"
has_not "$RF" 'good.ts' "ruff never sees a TS file"

echo "== a bare --base name means origin/<name>, never the checkout's stale local branch =="
# The shape that bit OLYX-1887 (1 Sep 2026): the primary checkout's `main` sits
# where the human last pulled it; origin/main has since grown a legacy file past
# the ceiling; the branch is cut from origin/main and never touches that file.
SBARE="$ROOT/stale-origin.git"; SREPO="$ROOT/stale"
git init -q --bare "$SBARE"
git clone -q "$SBARE" "$SREPO" 2>/dev/null
git -C "$SREPO" config user.email t@t
git -C "$SREPO" config user.name  t
printf 'export const a = 1;\n' > "$SREPO/good.ts"
git -C "$SREPO" add . && git -C "$SREPO" commit -qm base
git -C "$SREPO" branch -M main
git -C "$SREPO" push -q -u origin main
# origin/main moves (a legacy TS file lands) while local main stays put.
git -C "$SREPO" checkout -q --detach origin/main
printf 'export const legacy = 1;\n' > "$SREPO/legacy.ts"
git -C "$SREPO" add . && git -C "$SREPO" commit -qm "legacy grows"
git -C "$SREPO" push -q origin HEAD:main
git -C "$SREPO" fetch -q origin
git -C "$SREPO" checkout -qb feat origin/main
printf 'prose\n' > "$SREPO/note.txt"
git -C "$SREPO" add . && git -C "$SREPO" commit -qm "branch: prose only"
OUT="$ROOT/qg-stale-out"; rm -f "$ROOT/ox-args"
(cd "$SREPO" && env QG_OXLINT_BIN="$FAKES/oxlint-stub" OX_ARGS="$ROOT/ox-args" OX_CFG="$ROOT/ox-cfg" \
   bash "$SRC/lib/quality-gate.sh" --base main) > "$OUT" 2>&1
has     "$(cat "$OUT")" 'changed vs origin/main' "the scope line names origin/main"
has     "$(cat "$OUT")" '0 code file(s) in scope' "a prose-only branch owns no code file"
has_not "$(cat "$ROOT/ox-args" 2>/dev/null || true)" 'legacy.ts' "the file the base moved is never judged"
OUT="$ROOT/qg-out"

echo "== the generated configs carry the thresholds =="
CFG="$(cat "$ROOT/ox-cfg" 2>/dev/null || true)"
RCFG="$(cat "$ROOT/ruff-cfg" 2>/dev/null || true)"
has "$CFG" '"complexity"'                 "oxlint config: complexity rule on"
has "$CFG" '["error", 21]'                "oxlint config: default complexity ceiling 21"
has "$CFG" '"max": 500'                   "oxlint config: default file-length ceiling 500"
has "$CFG" 'typescript/no-explicit-any'   "oxlint config: no-explicit-any on"
has "$CFG" '"no-unused-vars": "error"'    "oxlint config: dead code (unused vars) on"
has "$CFG" '"no-unreachable": "error"'    "oxlint config: dead code (unreachable) on"
has "$CFG" '"correctness": "off"'         "oxlint config: default categories off — only the bar is enforced"
has "$RCFG" 'max-complexity = 21'         "ruff config: default complexity ceiling 21"
has "$RCFG" 'C901'                        "ruff config: mccabe selected"

run_qg QG_MAX_COMPLEXITY=9 QG_MAX_FILE_LINES=120
has "$(cat "$ROOT/ox-cfg")"   '["error", 9]'        "QG_MAX_COMPLEXITY reaches the oxlint config"
has "$(cat "$ROOT/ox-cfg")"   '"max": 120'          "QG_MAX_FILE_LINES reaches the oxlint config"
has "$(cat "$ROOT/ruff-cfg")" 'max-complexity = 9'  "QG_MAX_COMPLEXITY reaches the ruff config"

echo "== verdicts: a linter failure fails the gate =="
if run_qg OX_EXIT=1; then bad "oxlint failure fails the gate"; else ok "oxlint failure fails the gate"; fi
has "$(cat "$OUT")" 'FAIL' "the failing check is named in the output"
if run_qg RUFF_EXIT=1; then bad "ruff failure fails the gate"; else ok "ruff failure fails the gate"; fi

echo "== the Python file-length ceiling is counted here =="
{ for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "y$i = $i"; done; } > "$UREPO/long.py"
git -C "$UREPO" add long.py && git -C "$UREPO" commit -qm long
if run_qg QG_MAX_FILE_LINES=10; then bad "an over-long Python file fails the gate"; else ok "an over-long Python file fails the gate"; fi
has "$(cat "$OUT")" 'python file length' "the file-length check is the one that failed"
if run_qg; then ok "the same file passes at the default ceiling"; else bad "the same file passes at the default ceiling"; fi
git -C "$UREPO" rm -q long.py && git -C "$UREPO" commit -qm unlong

echo "== a test file's length follows its subject: exempt unless given its own ceiling =="
{ for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "y$i = $i"; done; } > "$UREPO/test_long.py"
git -C "$UREPO" add test_long.py && git -C "$UREPO" commit -qm testlong
if run_qg QG_MAX_FILE_LINES=10; then ok "an over-long Python test file passes the default ceiling"; else bad "an over-long Python test file passes the default ceiling (output: $(cat "$OUT"))"; fi
if run_qg QG_MAX_FILE_LINES=10 QG_TEST_MAX_FILE_LINES=11; then bad "QG_TEST_MAX_FILE_LINES gives test files a ceiling"; else ok "QG_TEST_MAX_FILE_LINES gives test files a ceiling"; fi
has "$(cat "$OUT")" 'test_long.py: 12 lines' "the over-long test file is the one named"
if run_qg QG_MAX_FILE_LINES=10 QG_TEST_MAX_FILE_LINES=12; then ok "a test file under its own ceiling passes"; else bad "a test file under its own ceiling passes"; fi
git -C "$UREPO" rm -q test_long.py && git -C "$UREPO" commit -qm untestlong
run_qg
CFG="$(cat "$ROOT/ox-cfg")"
has "$CFG" '"**/*.test.*"'                "oxlint config: test files are an override"
has "$CFG" '"max-lines": "off"'           "oxlint config: max-lines off for test files by default"
has "$CFG" '"no-unused-vars": "error"'    "oxlint config: the other rules still reach test files"
run_qg QG_TEST_MAX_FILE_LINES=1500
has "$(cat "$ROOT/ox-cfg")" '"max": 1500' "QG_TEST_MAX_FILE_LINES reaches the oxlint override"

echo "== suppressions added by the branch fail the gate =="
printf '// eslint-disable-next-line no-unused-vars\nexport const c = 4;\n' > "$UREPO/new.ts"
git -C "$UREPO" add new.ts && git -C "$UREPO" commit -qm suppress
if run_qg; then bad "an added eslint-disable fails the gate"; else ok "an added eslint-disable fails the gate"; fi
has "$(cat "$OUT")" 'suppression' "the suppression check names itself"
if run_qg QG_SUPPRESSIONS=0; then ok "QG_SUPPRESSIONS=0 waives the check"; else bad "QG_SUPPRESSIONS=0 waives the check"; fi

echo "== a branch with no code files skips the linters =="
git -C "$UREPO" checkout -qb prose-only main
printf 'prose v3\n' > "$UREPO/note.txt"
git -C "$UREPO" add note.txt && git -C "$UREPO" commit -qm prose
if run_qg; then ok "prose-only branch passes"; else bad "prose-only branch passes"; fi
if [ -f "$ROOT/ox-args" ]; then bad "oxlint was never invoked"; else ok "oxlint was never invoked"; fi
has "$(cat "$OUT")" 'skip (no JS/TS files in scope)' "the skip is disclosed, not silent"
git -C "$UREPO" checkout -q feat

echo "== --all widens the scope to every tracked file =="
(cd "$UREPO" && env QG_OXLINT_BIN="$FAKES/oxlint-stub" OX_ARGS="$ROOT/ox-args" OX_CFG="$ROOT/ox-cfg" \
   QG_RUFF_BIN="$FAKES/ruff-stub" RUFF_ARGS="$ROOT/ruff-args" RUFF_CFG="$ROOT/ruff-cfg" \
   bash "$SRC/lib/quality-gate.sh" --all) > "$OUT" 2>&1
has     "$(cat "$ROOT/ox-args")" 'good.ts' "--all: unchanged tracked TS is in scope"
has_not "$(cat "$ROOT/ox-args")" 'note.txt' "--all: non-code files still are not"

# ---------------------------------------------------------------------------
echo "== repos.conf.sh composes the pinned repo's GATE_CMD =="
# Canonicalized: repos.conf.sh embeds `cd && pwd` of itself into GATE_CMD, and
# a macOS TMPDIR's trailing slash would otherwise put a // in the expectation.
H="$ROOT/conf-harness"; mkdir -p "$H"; H="$(cd "$H" && pwd)"
cp "$SRC/repos.conf.sh" "$H/"
cp -R "$SRC/lib" "$H/lib"
cat > "$H/repos.local.sh" <<'SH'
repo_config_local() {
  case "$2" in
    qgapp|qgapp-*) QUALITY_GATE=1; BASE_BRANCH=main ;;
    qgbare|qgbare-*) QUALITY_GATE=1; BASE_BRANCH=main ;;
  esac
}
SH
QGAPP="$ROOT/qgapp"; mkdir -p "$QGAPP"; printf '{}' > "$QGAPP/package.json"
QGBARE="$ROOT/qgbare"; mkdir -p "$QGBARE"
PLAIN="$ROOT/plainapp"; mkdir -p "$PLAIN"; printf '{}' > "$PLAIN/package.json"
conf_check() {
  export HARNESS_DIR="$H"
  # shellcheck disable=SC1091
  . "$H/repos.conf.sh"
  repo_config "$QGAPP"
  [ "$GATE_CMD" = "bash '$H/lib/quality-gate.sh' --base 'main' && { npm test; }" ] \
    || { echo "pinned+detected: GATE_CMD=[$GATE_CMD]"; return 1; }
  repo_config "$QGBARE"
  [ "$GATE_CMD" = "bash '$H/lib/quality-gate.sh' --base 'main'" ] \
    || { echo "pinned, no detected gate: GATE_CMD=[$GATE_CMD]"; return 1; }
  repo_config "$PLAIN"
  [ -z "$QUALITY_GATE" ] || { echo "unpinned repo: QUALITY_GATE=[$QUALITY_GATE]"; return 1; }
  [ "$GATE_CMD" = "npm test" ] || { echo "unpinned repo: GATE_CMD=[$GATE_CMD]"; return 1; }
}
if out=$( (conf_check) 2>&1 ); then
  ok "conf: quality gate first, repo gate second, pin reset between repos"
else
  bad "conf: quality gate first, repo gate second, pin reset between repos — $out"
fi

# ---------------------------------------------------------------------------
echo "== pipeline: the posture reaches both workers, the gate really runs =="
BARE="$ROOT/origin.git"; PREPO="$ROOT/qapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$PREPO" 2>/dev/null
git -C "$PREPO" config user.email t@t
git -C "$PREPO" config user.name  t
git -C "$PREPO" commit -q --allow-empty -m init
git -C "$PREPO" branch -M main
git -C "$PREPO" push -q -u origin main

cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then printf '%s' "$a" > "$CAPTURE_IMPL"; break; fi
  prev="$a"
done
date > fixture.txt
git add fixture.txt
git commit -q -m "feat: fixture change"
SH
cat > "$FAKES/codex" <<'SH'
#!/usr/bin/env bash
wt=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-C" ] && wt="$a"
  prev="$a"; last="$a"
done
printf '%s' "$last" > "$CAPTURE_REVIEW"
printf 'fixture stop\n' > "$wt/.harness/REJECTED.md"
SH
chmod +x "$FAKES/claude" "$FAKES/codex"

run_pipeline() {  # $1 = ticket, $2 = 1 to pin QUALITY_GATE for the fixture repo
  local ticket="$1" h="$ROOT/harness-$1"
  mkdir -p "$h/runs/$ticket"
  cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$h/"
  cp -R "$SRC/lib" "$h/lib"
  if [ "$2" = 1 ]; then
    cat > "$h/repos.local.sh" <<'SH'
repo_config_local() {
  case "$2" in
    qapp|qapp-*) QUALITY_GATE=1 ;;
  esac
}
SH
  fi
  printf '# fixture task\n' > "$h/runs/$ticket/brief.md"
  env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
  CAPTURE_IMPL="$ROOT/impl-$ticket.txt" CAPTURE_REVIEW="$ROOT/review-$ticket.txt" \
  HOME="$ROOT/home" HARNESS_DIR="$h" \
  CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
  HARNESS_DETACH=0 HARNESS_PREFLIGHT=off HARNESS_REVIEW_NETWORK=0 \
  HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC="" \
    bash "$SRC/run-task.sh" "$ticket" "$PREPO" "fix/$ticket" > "$ROOT/run-$ticket.log" 2>&1
  return 0   # the fixture run ends in `rejected`, i.e. non-zero, by design
}
mkdir -p "$ROOT/home"
run_pipeline qg-off 0
run_pipeline qg-on  1

read_capture() { cat "$1" 2>/dev/null || true; }
OFF_IMPL="$(read_capture "$ROOT/impl-qg-off.txt")"
OFF_REVIEW="$(read_capture "$ROOT/review-qg-off.txt")"
ON_IMPL="$(read_capture "$ROOT/impl-qg-on.txt")"
ON_REVIEW="$(read_capture "$ROOT/review-qg-on.txt")"

has "$OFF_IMPL"   'You are the implementer stage of an automated pipeline.' "capture: implementer prompt (unpinned)"
has "$ON_IMPL"    'You are the implementer stage of an automated pipeline.' "capture: implementer prompt (pinned)"
has "$OFF_REVIEW" 'You are the reviewer stage of an automated pipeline'     "capture: reviewer prompt (unpinned)"
has "$ON_REVIEW"  'You are the reviewer stage of an automated pipeline'     "capture: reviewer prompt (pinned)"

has_not "$OFF_IMPL"   'machine-checked quality bar' "off: implementer prompt carries no quality posture"
has_not "$OFF_REVIEW" 'machine-checked quality bar' "off: reviewer prompt carries no quality posture"

IMPL_DELTA="${ON_IMPL#"$OFF_IMPL"}"
REVIEW_DELTA="${ON_REVIEW#"$OFF_REVIEW"}"
if [ -n "$OFF_IMPL" ] && [ "$IMPL_DELTA" != "$ON_IMPL" ]; then
  ok "on: implementer prompt is the unpinned prompt plus an appended block"
else
  bad "on: implementer prompt is the unpinned prompt plus an appended block"
fi
if [ -n "$OFF_REVIEW" ] && [ "$REVIEW_DELTA" != "$ON_REVIEW" ]; then
  ok "on: reviewer prompt is the unpinned prompt plus an appended block"
else
  bad "on: reviewer prompt is the unpinned prompt plus an appended block"
fi

while IFS= read -r point; do
  has "$IMPL_DELTA"   "$point" "on: implementer block keeps point [${point:0:40}]"
  has "$REVIEW_DELTA" "$point" "on: reviewer block keeps point [${point:0:40}]"
done <<'EOF'
machine-checked quality bar
Cyclomatic complexity at most 21
500 lines of code per file
Zero `any` types
Zero dead code
Zero suppressions
EOF
has     "$REVIEW_DELTA" 'Judge the diff against this bar' "on: reviewer block tells the reviewer to enforce it"
has_not "$IMPL_DELTA"   'Judge the diff against this bar' "on: the review-only instruction stays out of the implementer prompt"

GATE_LOG="$(cat "$ROOT/harness-qg-on/runs/qg-on/gate-1.log" 2>/dev/null || true)"
has "$GATE_LOG" 'quality: gate passed' "on: gate round 1 actually ran the quality gate"
has "$(cat "$ROOT/harness-qg-on/runs/qg-on/gate-rounds.log" 2>/dev/null || true)" '1 pass' \
  "on: the composed gate passed the round"

# ---------------------------------------------------------------------------
echo "== QUALITY_GATE is documented where the other pins are =="
doc_has() {
  if grep -q 'QUALITY_GATE' "$SRC/$1"; then ok "docs: $2 documents QUALITY_GATE"; else bad "docs: $2 documents QUALITY_GATE"; fi
}
doc_has repos.conf.sh          "repos.conf.sh header"
doc_has repos.local.sh.example "repos.local.sh.example"
doc_has README.md              "README"
doc_has docs/reference.md      "reference"

echo
printf 'quality-gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
