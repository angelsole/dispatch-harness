#!/usr/bin/env bash
# The janitor's contract: of every worktree the harness still holds, exactly the
# ones whose PR is merged and whose tree is clean may go — and only through
# cleanup.sh. Everything else is named and left, including the cases where being
# wrong would destroy work: an OPEN PR, a dirty tree, a run still going, a run
# with no PR at all, and a PR whose state could not be read.
#
# Nothing real is contacted or killed. `gh`, `ps`, `uname` and `launchctl` are
# fake binaries on PATH answering from canned files — the technique
# tests/quartermaster.test.sh established — and $HOME is a fixture, so the
# LaunchAgent cases write into the sandbox. The worktrees are real worktrees of a
# real repo with a local bare remote, so the sweep is asserted by asking git,
# and the processes reaped are real processes of this suite's own making,
# presented to the janitor with a canned age.
#
# Usage: bash tests/janitor.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/janitor-test.XXXXXX")"
VICTIMS=""
# shellcheck disable=SC2064  # ROOT is fixed now; the victim list is read at exit.
trap 'for p in $VICTIMS; do kill -9 "$p" 2>/dev/null || true; done; rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }
nonzero()  { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1 (exited 0)"; fi; }
alive()    { if kill -0 "$2" 2>/dev/null; then ok "$1"; else bad "$1 (pid $2 is gone)"; fi; }
dead()     { if kill -0 "$2" 2>/dev/null; then bad "$1 (pid $2 is still running)"; else ok "$1"; fi; }

# The janitor prints one line per worktree it still sees and per process it would
# reap: `[janitor]   <verb> <id> <why> <path>`. The verb is the whole verdict.
verb() {  # $1 = captured output, $2 = run id or pid
  printf '%s\n' "$1" | awk -v id="$2" '$1 == "[janitor]" && $3 == id { print $2; exit }'
}
verbs() {  # $1 = captured output, $2 = verb -> how many lines carry it
  printf '%s\n' "$1" | awk -v v="$2" '$1 == "[janitor]" && $2 == v { n++ } END { print n+0 }'
}

# --- fixture: a repo with a real (local) origin -------------------------------
FHOME="$ROOT/home"; AGENTS="$FHOME/Library/LaunchAgents"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
FAKES="$ROOT/bin"
BARE="$ROOT/origin.git"; REPO="$ROOT/app"
PS_FIXTURE="$ROOT/ps.txt"
UNAME_STATE="$ROOT/fake-uname"
LC_LOG="$ROOT/launchctl.log"
GH_MODE="$ROOT/gh-mode"
GH_LOG="$ROOT/gh.log"

mkdir -p "$AGENTS" "$RUNS" "$FAKES"
: > "$PS_FIXTURE"; : > "$LC_LOG"; : > "$GH_LOG"
printf 'Darwin\n' > "$UNAME_STATE"
printf 'authed\n' > "$GH_MODE"

git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# --- fakes -------------------------------------------------------------------
# gh answers a PR's state from the number at the end of its url, so each fixture
# run picks its verdict by picking a url. Mode `denied` is an install that was
# never logged in: `auth status` fails and no state can be read at all.
cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
printf 'cwd:%s argv:%s\n' "\$PWD" "\$*" >> "$GH_LOG"
mode=\$(cat "$GH_MODE" 2>/dev/null || echo authed)
case "\${1:-}" in
  auth) [ "\$mode" = authed ] || exit 1; exit 0 ;;
  pr)   [ "\$mode" = authed ] || exit 1 ;;
  *)    exit 1 ;;
esac
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
case "\${url##*/}" in
  1|3|6) printf 'MERGED\n' ;;
  2)     printf 'OPEN\n' ;;
  7)     printf 'CLOSED\n' ;;
  *)     exit 1 ;;          # the API said nothing this script may act on
esac
EOF

# ps is faked for every invocation in this suite, not just the reaping cases:
# a --clean against the real process table could kill a real flutter_tester on
# the machine running the tests.
cat > "$FAKES/ps" <<EOF
#!/usr/bin/env bash
cat "$PS_FIXTURE" 2>/dev/null || true
EOF

cat > "$FAKES/uname" <<EOF
#!/usr/bin/env bash
cat "$UNAME_STATE"
EOF

cat > "$FAKES/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LC_LOG"
EOF

chmod +x "$FAKES/gh" "$FAKES/ps" "$FAKES/uname" "$FAKES/launchctl"

jan() {  # $1 = space-separated VAR=VAL overrides (may be empty), rest = argv
  local overrides="$1"; shift
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      GH_TOKEN=leak-me-not HARNESS_MIRROR= \
      $overrides bash "$SRC/janitor.sh" "$@" 2>&1
}

# --- fixture: one run per verdict --------------------------------------------
mkrun() {  # $1 = id, $2 = stage text, $3 = worktree ('' = none), $4 = pr url
  local d="$RUNS/$1"
  mkdir -p "$d"
  printf '%s %s\n' "$(date +%s)" "$2" > "$d/status"
  [ -n "$3" ] && printf '%s\n' "$3" > "$d/worktree"
  printf '{"ticket":"%s","status":"ready","worktree":"%s","branch":"feat/%s","pr_url":"%s"}\n' \
    "$1" "$3" "$1" "$4" > "$d/result.json"
  printf 'the log that is never deleted\n' > "$d/feed.log"
}
mkwt() {  # $1 = branch, $2 = path
  git -C "$REPO" worktree add -q -b "$1" "$2" >/dev/null 2>&1
}

PR=https://github.com/acme/app/pull
WT_SWEEP="$ROOT/wt-merged-clean"
WT_OPEN="$ROOT/wt-open-pr"
WT_DIRTY="$ROOT/wt-merged-dirty"
WT_NOPR="$ROOT/wt-no-pr"
WT_UNKNOWN="$ROOT/wt-unreadable"
WT_LIVE="$ROOT/wt-still-running"
WT_CLOSED="$ROOT/wt-closed-pr"

mkwt feat/merged-clean  "$WT_SWEEP"
mkwt feat/open-pr       "$WT_OPEN"
mkwt feat/merged-dirty  "$WT_DIRTY"
mkwt feat/no-pr         "$WT_NOPR"
mkwt feat/unreadable    "$WT_UNKNOWN"
mkwt feat/still-running "$WT_LIVE"
mkwt feat/closed-pr     "$WT_CLOSED"
printf 'work nobody has committed\n' > "$WT_DIRTY/scratch.txt"

mkrun merged-clean  "done: ready"        "$WT_SWEEP"   "$PR/1"
mkrun open-pr       "done: ready"        "$WT_OPEN"    "$PR/2"
mkrun merged-dirty  "done: ready"        "$WT_DIRTY"   "$PR/3"
mkrun no-pr         "done: gate_failed"  "$WT_NOPR"    ""
mkrun unreadable    "done: ready"        "$WT_UNKNOWN" "$PR/5"
# Merged, clean — and still working in that worktree. The stage line is the only
# thing standing between this run and having the floor pulled out from under it.
mkrun still-running "implementing — Opus (Claude sub)" "$WT_LIVE" "$PR/6"
mkrun closed-pr     "done: ready"        "$WT_CLOSED"  "$PR/7"
# A run cleanup.sh already promoted: nothing left to do, and not an error.
mkrun already-swept "done: ready"        "$ROOT/wt-gone" "$PR/1"
# A run whose stage line never landed. Merged and clean, and still not the
# janitor's to take: a run whose state cannot be read is not a run that is done.
WT_NOSTATUS="$ROOT/wt-no-status"
mkwt feat/no-status "$WT_NOSTATUS"
mkrun no-status     "done: ready"        "$WT_NOSTATUS" "$PR/1"
rm -f "$RUNS/no-status/status"
# The quartermaster's reports live under runs/ and are not runs.
mkdir -p "$RUNS/quartermaster"
printf '# last night\n' > "$RUNS/quartermaster/2026-08-18.md"

wt_count() { git -C "$REPO" worktree list | grep -c '' | tr -d ' '; }
WT_BEFORE=$(wt_count)
# The repo path as git itself reports it: on macOS the temp root is reached
# through a symlink, and git answers with the physical path.
REPO_REAL=$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")

# ---------------------------------------------------------------------------
echo "== guards =="
# ---------------------------------------------------------------------------
out=$(jan "" --nonsense); rc=$?
check "guard: an unknown option exits 2" "$rc" "2"
has "$out" "janitor.sh --clean" "guard: an unknown option prints the usage"

out=$(jan "" --clean extra); rc=$?
check "guard: a stray argument exits 2" "$rc" "2"

out=$(jan "" --install --tomorrow); rc=$?
check "guard: --install rejects an unknown mode" "$rc" "2"
has "$out" "--install takes --report or --clean" "guard: --install names the modes it takes"

out=$(jan "JANITOR_PROC_MATCH=" --clean); rc=$?
nonzero "guard: an empty process match refuses to run" "$rc"
has "$out" "JANITOR_PROC_MATCH must not be empty" "guard: it says why an empty match is refused"

out=$(jan "JANITOR_PROC_AGE=soon" --report); rc=$?
nonzero "guard: a non-numeric age refuses to run" "$rc"
has "$out" "JANITOR_PROC_AGE must be whole seconds" "guard: it says what an age has to be"

exists "guard: no guard removed a worktree" "$WT_SWEEP"

# ---------------------------------------------------------------------------
echo "== gh cannot answer: everything is unknown, nothing is swept =="
# ---------------------------------------------------------------------------
printf 'denied\n' > "$GH_MODE"
out=$(jan "" --clean); rc=$?
check "unauthed: --clean still exits 0" "$rc" "0"
has "$out" "gh is not authenticated" "unauthed: it says the state cannot be read"
check "unauthed: nothing is sweepable" "$(verbs "$out" sweep)" "0"
check "unauthed: the merged run is unknown, not merged" "$(verb "$out" merged-clean)" "keep"
has "$out" "PR state unreadable" "unauthed: an unreadable state is named as one"
exists "unauthed: the merged worktree is still there" "$WT_SWEEP"
printf 'authed\n' > "$GH_MODE"

# `gh` missing entirely is a different message and the same restraint. Asserted
# under a PATH built of links to the real tools, minus gh — skipped rather than
# faked if this machine cannot produce one.
NOGH="$ROOT/bin-nogh"; mkdir -p "$NOGH"
for b in bash sh sed cat jq git du awk sort grep tr perl mktemp rm date id \
         dirname basename sleep chmod ls; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOGH/$b"
done
cp "$FAKES/ps" "$FAKES/uname" "$FAKES/launchctl" "$NOGH/"
if PATH="$NOGH" command -v gh >/dev/null 2>&1 \
   || ! PATH="$NOGH" command -v jq >/dev/null 2>&1 \
   || ! PATH="$NOGH" command -v git >/dev/null 2>&1; then
  skip "janitor: no-gh PATH could not be built on this machine"
else
  out=$(env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$NOGH" \
    bash "$SRC/janitor.sh" --clean 2>&1); rc=$?
  check "no gh: --clean still exits 0" "$rc" "0"
  has "$out" "gh is not installed" "no gh: it says the binary is missing"
  check "no gh: nothing is sweepable" "$(verbs "$out" sweep)" "0"
  exists "no gh: the merged worktree is still there" "$WT_SWEEP"
fi

# ---------------------------------------------------------------------------
echo "== --report: one sweepable run, and nothing touched =="
# ---------------------------------------------------------------------------
: > "$GH_LOG"
out=$(jan "" --report); rc=$?
check "report: exits 0" "$rc" "0"
# The cwd is matched by its tail: cd normalises the doubled slash mktemp can
# leave in $TMPDIR, so the recorded path is not $WT_OPEN byte for byte.
file_has "$GH_LOG" "/wt-open-pr argv:pr view $PR/2 --json state" \
  "report: each PR is asked about from inside that run's own worktree"

check "report: merged + clean is the one to sweep"      "$(verb "$out" merged-clean)"  "sweep"
check "report: exactly one run is sweepable"            "$(verbs "$out" sweep)"        "1"
check "report: an OPEN PR is kept"                      "$(verb "$out" open-pr)"       "keep"
check "report: a merged but dirty worktree is kept"     "$(verb "$out" merged-dirty)"  "keep"
check "report: a run with no PR is kept"                "$(verb "$out" no-pr)"         "keep"
check "report: an unreadable PR state is kept"          "$(verb "$out" unreadable)"    "keep"
check "report: a run that is still going is kept"       "$(verb "$out" still-running)" "keep"
check "report: a CLOSED, unmerged PR is kept"           "$(verb "$out" closed-pr)"     "keep"
check "report: a run with no stage line is kept"        "$(verb "$out" no-status)"     "keep"
has "$out" "PR is OPEN — review fixes land here" "report: it says why an open PR's worktree stays"
has "$out" "merged, but dirty (1 uncommitted)" "report: it counts what is uncommitted"
has "$out" "still running" "report: a live run is named as one, not as a merged PR"
has "$out" "no pr_url" "report: a run that never opened a PR is named as one"
has "$out" "no status line — cannot tell if it is done" "report: an unreadable run state is named as one"

# A run whose worktree cleanup.sh already removed is not a finding, and the
# quartermaster's report directory is not a run.
has "$out" "1 of 9 runs had no worktree left" "report: an already-promoted run is counted, not reported"
has "$out" "7 kept" "report: the seven it may not touch are counted"
has "$out" "1 worktree(s) sweepable" "report: the sweepable count is on the summary line"
has "$out" "kept: 1 open · 1 closed · 1 dirty · 1 unknown · 1 no-pr · 2 unfinished" \
  "report: the summary breaks the kept runs down by reason"
has "$out" "--report touched nothing" "report: it says it did nothing"

echo "== --report is side-effect-free =="
for w in "$WT_SWEEP" "$WT_OPEN" "$WT_DIRTY" "$WT_NOPR" "$WT_UNKNOWN" "$WT_LIVE" "$WT_CLOSED" \
         "$WT_NOSTATUS"; do
  exists "report: $(basename "$w") is untouched" "$w"
done
check "report: git still knows every worktree" "$(wt_count)" "$WT_BEFORE"
exists "report: the dirty file was not committed away" "$WT_DIRTY/scratch.txt"
absent "report: no LaunchAgent was written" "$AGENTS/com.olyx.janitor.plist"

# ---------------------------------------------------------------------------
echo "== --clean: the merged clean worktree, and only that one =="
# ---------------------------------------------------------------------------
out=$(jan "" --clean); rc=$?
check "clean: exits 0" "$rc" "0"
absent "clean: the merged clean worktree is gone" "$WT_SWEEP"
for w in "$WT_OPEN" "$WT_DIRTY" "$WT_NOPR" "$WT_UNKNOWN" "$WT_LIVE" "$WT_CLOSED" "$WT_NOSTATUS"; do
  exists "clean: $(basename "$w") is still there" "$w"
done
check "clean: git dropped exactly one worktree" "$(wt_count)" "$((WT_BEFORE - 1))"
has_not "$(git -C "$REPO" worktree list)" "wt-merged-clean" "clean: git no longer lists the swept worktree"
has     "$(git -C "$REPO" worktree list)" "wt-open-pr"      "clean: git still lists the open PR's worktree"

has "$out" "1 worktree(s) swept" "clean: the summary counts the sweep"
has "$out" "removed worktree $WT_SWEEP" "clean: cleanup.sh is what removed it, and says so"
has "$out" "run logs kept at $RUNS/merged-clean" "clean: cleanup.sh kept the run's logs"
has "$out" "pruned worktree metadata in $REPO_REAL" "clean: the repo it touched was pruned"

echo "== --clean never deletes a run's paper trail =="
exists "clean: the swept run's directory survives"   "$RUNS/merged-clean"
exists "clean: its result.json survives"             "$RUNS/merged-clean/result.json"
exists "clean: its log survives"                     "$RUNS/merged-clean/feed.log"
exists "clean: the quartermaster's reports survive"  "$RUNS/quartermaster/2026-08-18.md"

echo "== --clean twice: the second pass has nothing to do =="
out=$(jan "" --clean); rc=$?
check "again: exits 0" "$rc" "0"
check "again: nothing is sweepable" "$(verbs "$out" sweep)" "0"
has "$out" "0 worktree(s) swept" "again: it says it swept nothing"
has "$out" "2 of 9 runs had no worktree left" "again: the swept run joins the already-clean ones"
check "again: still seven kept" "$(verbs "$out" keep)" "7"

echo "== the branch deletion is cleanup.sh's, on cleanup.sh's terms =="
# feat/merged-clean was never pushed, so the local branch stays: this suite
# asserts the janitor delegates, not that it re-implements the rule.
if git -C "$REPO" show-ref --verify --quiet refs/heads/feat/merged-clean; then
  ok "clean: an unpushed branch is kept (cleanup.sh's rule, unchanged)"
else
  bad "clean: an unpushed branch was deleted — cleanup.sh's rule was bypassed"
fi

# ---------------------------------------------------------------------------
echo "== old test runners are reaped, young ones are not =="
# ---------------------------------------------------------------------------
# Spawned from a subshell that exits immediately, so each victim is reparented
# and `kill -0` reports its real liveness rather than a zombie's.
spawn() { ( sleep 600 >/dev/null 2>&1 & echo $! ); }
V_OLD1=$(spawn); V_YOUNG=$(spawn); V_OLD2=$(spawn); V_OTHER=$(spawn)
VICTIMS="$V_OLD1 $V_YOUNG $V_OLD2 $V_OTHER"

# One line per ps etime shape: days, just under the limit, just over it.
{
  printf '%s 2-03:04:05 %s\n' "$V_OLD1"  "$ROOT/flutter/cache/flutter_tester"
  printf '%s 01:59:59 %s\n'   "$V_YOUNG" "$ROOT/flutter/cache/flutter_tester"
  printf '%s 02:00:01 %s\n'   "$V_OLD2"  "$ROOT/flutter/cache/flutter_tester"
  printf '%s 05:00:00 %s\n'   "$V_OTHER" "/bin/sleep"
} > "$PS_FIXTURE"

out=$(jan "" --report); rc=$?
check "procs: --report exits 0" "$rc" "0"
check "procs: a two-day-old runner is listed"     "$(verb "$out" "$V_OLD1")"  "kill"
check "procs: one a second over the limit is too" "$(verb "$out" "$V_OLD2")"  "kill"
check "procs: one a second under it is not"       "$(verb "$out" "$V_YOUNG")" ""
check "procs: an unrelated old process is not"    "$(verb "$out" "$V_OTHER")" ""
has "$out" "processes: flutter_tester older than 2h00m" "procs: the report says what it looks for"
has "$out" "2 to kill, 1 younger than 2h00m left alone" "procs: it counts both sides"
has "$out" "up 51h04m" "procs: it says how long the oldest has been up"
alive "procs: --report killed nothing (old #1)" "$V_OLD1"
alive "procs: --report killed nothing (old #2)" "$V_OLD2"

out=$(jan "" --clean); rc=$?
check "reap: --clean exits 0" "$rc" "0"
check "reap: the two-day-old runner was killed" "$(verb "$out" "$V_OLD1")" "killed"
has "$out" "2 killed, 0 survived, 1 younger than 2h00m left alone" "reap: it reports what it killed"
dead  "reap: the two-day-old runner is gone" "$V_OLD1"
dead  "reap: the one just over the limit is gone" "$V_OLD2"
alive "reap: the young runner is left alone" "$V_YOUNG"
alive "reap: the unrelated process is left alone" "$V_OTHER"

echo "== JANITOR_PROC_AGE and JANITOR_PROC_MATCH move the line =="
out=$(jan "JANITOR_PROC_AGE=60" --report)
check "knob: a one-minute age catches the young runner too" "$(verb "$out" "$V_YOUNG")" "kill"
out=$(jan "JANITOR_PROC_MATCH=sleep" --report)
check "knob: the match selects by process name" "$(verb "$out" "$V_OTHER")" "kill"
check "knob: and only by process name" "$(verb "$out" "$V_YOUNG")" ""
: > "$PS_FIXTURE"

# ---------------------------------------------------------------------------
echo "== --install / --uninstall: the daily agent =="
# ---------------------------------------------------------------------------
PLIST="$AGENTS/com.olyx.janitor.plist"
WRAPPER="$RUNS/janitor/janitor-agent.sh"

printf 'Linux\n' > "$UNAME_STATE"
out=$(jan "" --install); rc=$?
nonzero "install: refuses to arm launchd on a non-Mac" "$rc"
absent  "install: nothing was written on a non-Mac" "$PLIST"
printf 'Darwin\n' > "$UNAME_STATE"

out=$(jan "JANITOR_PROC_AGE=3600 GH_CONFIG_DIR=$ROOT/gh-config" --install); rc=$?
check  "install: exits 0" "$rc" "0"
exists "install: writes the plist" "$PLIST"
exists "install: writes the wrapper" "$WRAPPER"
check  "install: the wrapper is mode 600 (it holds an env snapshot)" \
  "$(ls -l "$WRAPPER" | cut -c2-10)" "rw-------"
file_has "$PLIST" "<string>com.olyx.janitor</string>" "install: the label follows the harness convention"
file_has "$PLIST" "<key>Hour</key>"      "install: the agent is a calendar interval"
file_has "$PLIST" "<integer>9</integer>" "install: it fires at 9"
file_has "$PLIST" "<integer>0</integer>" "install: on the hour"
file_has "$PLIST" "<string>--report</string>" \
  "install: the installed agent only reports — the plist argument is the trust dial"
file_has "$WRAPPER" "export HARNESS_DIR=" "install: the wrapper carries the harness dir launchd would not give it"
file_has "$WRAPPER" "export PATH="        "install: and the PATH"
file_has "$WRAPPER" "export JANITOR_PROC_AGE=" "install: and the janitor's own knobs"
file_has "$WRAPPER" "export GH_CONFIG_DIR="    "install: and the gh identity that reads a PR's state"
has_not "$(cat "$WRAPPER")" "GH_TOKEN" "install: no token rides along to override that identity"
file_has "$LC_LOG" "bootstrap gui/$(id -u) $PLIST" "install: the agent is loaded into launchd"
has "$out" "janitor.sh --install --clean" "install: says how to flip the dial to sweeping"

out=$(jan "" --install --clean); rc=$?
check "install: re-installing exits 0" "$rc" "0"
file_has "$PLIST" "<string>--clean</string>" "install: --install --clean flips the trust dial"
file_has "$LC_LOG" "bootout gui/$(id -u)/com.olyx.janitor" "install: the old agent was booted out first"

out=$(jan "JANITOR_AT=07:05" --install); rc=$?
check "install: JANITOR_AT exits 0" "$rc" "0"
file_has "$PLIST" "<integer>7</integer>" "install: JANITOR_AT moves the hour"
file_has "$PLIST" "<integer>5</integer>" "install: JANITOR_AT moves the minute"

out=$(jan "JANITOR_AT=teatime" --install); rc=$?
nonzero "install: a bad JANITOR_AT exits non-zero" "$rc"
has "$out" "JANITOR_AT must be HH:MM" "install: a bad JANITOR_AT says what it wanted"

out=$(jan "" --uninstall); rc=$?
check  "uninstall: exits 0" "$rc" "0"
absent "uninstall: the plist is gone" "$PLIST"
absent "uninstall: the wrapper is gone" "$WRAPPER"
exists "uninstall: the directory it logged into is kept" "$RUNS/janitor"

out=$(jan "" --uninstall)
has "$out" "nothing installed" "uninstall: a second one is not an error"

# ---------------------------------------------------------------------------
echo "== shipped and documented like its siblings =="
# ---------------------------------------------------------------------------
file_has "$SRC/install.sh" 'janitor.sh' "docs: install.sh installs the script"
file_has "$SRC/README.md"  'janitor.sh' "docs: README names it"
file_has "$SRC/docs/operations.md" 'janitor.sh --clean' "docs: operations documents the acting mode"
for k in JANITOR_AT JANITOR_PROC_AGE JANITOR_PROC_MATCH JANITOR_GH_TIMEOUT; do
  file_has "$SRC/docs/operations.md" "$k" "docs: operations documents $k"
done

echo
printf 'janitor: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
