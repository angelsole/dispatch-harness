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
# presented to the janitor with a canned age. The zombie reap's live-process
# guard is exercised the other way round: `pgrep` is real, and a real process of
# this suite's own making serves one fixture run.
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
# One field of a fixture run's outcome, or `no-outcome-file` when none was
# written. The null test is explicit — jq's `//` folds false into it.
oc() {  # $1 = jq path, $2 = run id
  jq -r "$1 as \$v | if \$v == null then \"null\" else (\$v | tostring) end" \
    "$RUNS/$2/outcome.json" 2>/dev/null || printf 'no-outcome-file'
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
REAL_JQ=$(command -v jq)

mkdir -p "$AGENTS" "$RUNS" "$FAKES"
: > "$PS_FIXTURE"; : > "$LC_LOG"; : > "$GH_LOG"
printf 'Darwin\n' > "$UNAME_STATE"
printf 'authed\n' > "$GH_MODE"

# Born on main by flag, not by the runner's default: a bare whose HEAD dangles
# on a name nothing pushed clones out to no checkout at all, so the
# remote-writer fixture below commits onto an unborn branch and its push fails
# — a machine with init.defaultBranch=main hides that, a fresh runner does not.
git init -q --bare -b main "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# --- fakes -------------------------------------------------------------------
# gh answers a PR from the number at the end of its url, so each fixture run
# picks its verdict by picking a url: the state, the dates and the squash commit
# come out of $ROOT/pr-<n>.json (written below, once the fixture repo has real
# commits to name), the review-comment count out of the api branch. Modes:
# `denied` is an install that was never logged in (nothing can be read at all);
# `api-down` is a working install whose api endpoint errors — the outcome has to
# degrade to a null field, not fail the sweep.
cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
printf 'cwd:%s argv:%s\n' "\$PWD" "\$*" >> "$GH_LOG"
mode=\$(cat "$GH_MODE" 2>/dev/null || echo authed)
case "\${1:-}" in
  auth) [ "\$mode" = denied ] && exit 1; exit 0 ;;
  pr|api) [ "\$mode" = denied ] && exit 1 ;;
  *)    exit 1 ;;
esac
if [ "\${1:-}" = api ]; then
  [ "\$mode" = api-down ] && exit 1
  # Trailing *: the path is not the last word of the argv (--jq follows it).
  # The arms exit: the pr-view tail below would otherwise cat a pr-.json that
  # does not exist and turn a answered page into a failed call.
  case "\$*" in
    *"/pulls/1/comments"*) printf '201\n'; exit 0 ;;
    *"/pulls/2/comments"*) printf '101\n102\n103\n'; exit 0 ;;
    *) exit 0 ;;
  esac
fi
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
# the API said nothing this script may act on
[ "\${JANITOR_TEST_PR_VARIANT:-}" != closed ] \
  || { cat "$ROOT/pr-7.json" 2>/dev/null; exit; }
cat "$ROOT/pr-\${url##*/}.json" 2>/dev/null || exit 1
EOF

# The outcome-writing jq can be synchronized in the concurrency regression
# below. Both shells have already opened their output file when this wrapper
# starts: the long writer lands first, then the shorter writer completes.
cat > "$FAKES/jq" <<EOF
#!/usr/bin/env bash
sync="\${JANITOR_TEST_JQ_SYNC:-}"
is_outcome=0
prev=""
for a in "\$@"; do
  [ "\$prev" = --arg ] && [ "\$a" = checked ] && is_outcome=1
  prev="\$a"
done
if [ -n "\$sync" ] && [ "\$is_outcome" = 1 ]; then
  case "\${JANITOR_TEST_PR_VARIANT:-}" in
    merged)
      touch "\$sync.long-open"
      while [ ! -e "\$sync.short-open" ]; do sleep 0.01; done
      "$REAL_JQ" "\$@"
      rc=\$?
      touch "\$sync.long-output"
      exit \$rc
      ;;
    closed)
      touch "\$sync.short-open"
      while [ ! -e "\$sync.long-output" ] || [ ! -e "\${JANITOR_TEST_OUTCOME:-}" ]; do sleep 0.01; done
      exec "$REAL_JQ" "\$@"
      ;;
  esac
fi
exec "$REAL_JQ" "\$@"
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

chmod +x "$FAKES/gh" "$FAKES/jq" "$FAKES/ps" "$FAKES/uname" "$FAKES/launchctl"

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
  printf '{"ticket":"%s","status":"ready","worktree":"%s","branch":"feat/%s","base":"main","pr_url":"%s"}\n' \
    "$1" "$3" "$1" "$4" > "$d/result.json"
  printf 'the log that is never deleted\n' > "$d/feed.log"
}
mkwt() {  # $1 = branch, $2 = path
  git -C "$REPO" worktree add -q -b "$1" "$2" >/dev/null 2>&1
}

# The base branch a merged PR leaves behind: the landing itself ($M1), a
# follow-up touching one of its files, one touching nothing it changed ($F2),
# and a revert of the landing. The outcome's follow-up and revert counts are
# computed against exactly this history, so they are asserted on real git, not
# on a canned number.
printf 'landed\n'         > "$REPO/impl.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "feat: PR 1 lands"
M1=$(git -C "$REPO" rev-parse HEAD)
printf 'elsewhere\n'      > "$REPO/other.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "chore: touches nothing PR 1 changed"
F2=$(git -C "$REPO" rev-parse HEAD)
printf 'landed, then fixed\n' > "$REPO/impl.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -q -m "fix: follow-up on the PR's file"
rm "$REPO/impl.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "Revert \"feat: PR 1 lands\"" -m "This reverts commit $M1."
git -C "$REPO" push -q origin main
# Advance the remote from another clone. The run repository's origin/main is
# now stale until the janitor refreshes it, exactly as after a GitHub-side merge
# or a later base-branch push from another machine.
REMOTE_WRITER="$ROOT/remote-writer"
git clone -q "$BARE" "$REMOTE_WRITER" 2>/dev/null
git -C "$REMOTE_WRITER" config user.email t@t
git -C "$REMOTE_WRITER" config user.name t
printf 'remote follow-up\n' > "$REMOTE_WRITER/impl.txt"
git -C "$REMOTE_WRITER" add -A
git -C "$REMOTE_WRITER" commit -q \
  -m "docs: document the regression introduced by $F2"
REMOTE_FOLLOW=$(git -C "$REMOTE_WRITER" rev-parse HEAD)
git -C "$REMOTE_WRITER" push -q origin main

# What `gh pr view` answers per PR number: state, both dates, the squash commit
# and the files it changed — as objects with a path, the shape gh itself answers
# with, which is what the outcome's file list is read out of. Merged PRs share
# $M1 except PR 3, whose landing is the unrelated $F2 — so its follow-up count
# is zero against the same history. PR 5 gets no fixture: its poll has no
# answer at all.
mkpr() {  # $1 = number, $2 = state, $3 = createdAt, $4 = mergedAt|'', $5 = oid|'', $6 = files (json array)
  jq -n --arg state "$2" --arg created "$3" --arg merged "$4" --arg oid "$5" \
     --argjson files "$6" '{state:$state, createdAt:$created,
       mergedAt: (if $merged == "" then null else $merged end),
       mergeCommit: (if $oid == "" then null else {oid:$oid} end),
       files: $files}' > "$ROOT/pr-$1.json"
}
mkpr 1 MERGED 2026-08-20T09:00:00Z 2026-08-20T10:00:00Z "$M1" '[{"path":"impl.txt"}]'
mkpr 2 OPEN   2026-08-20T09:00:00Z ""                   ""    '[{"path":"impl.txt"}]'
mkpr 3 MERGED 2026-08-21T09:00:00Z 2026-08-21T09:30:00Z "$F2" '[{"path":"other.txt"}]'
mkpr 6 MERGED 2026-08-20T09:00:00Z 2026-08-20T10:00:00Z "$M1" '[{"path":"impl.txt"}]'
mkpr 7 CLOSED 2026-08-20T09:00:00Z ""                   ""    '[{"path":"impl.txt"}]'
mkpr 8 MERGED 2026-08-20T09:00:00Z 2026-08-20T10:00:00Z "$M1" '[{"path":"impl.txt"}]'

PR=https://github.com/acme/app/pull
WT_SWEEP="$ROOT/wt-merged-clean"
WT_OPEN="$ROOT/wt-open-pr"
WT_DIRTY="$ROOT/wt-merged-dirty"
WT_NOPR="$ROOT/wt-no-pr"
WT_UNKNOWN="$ROOT/wt-unreadable"
WT_LIVE="$ROOT/wt-still-running"
WT_CLOSED="$ROOT/wt-closed-pr"
WT_SETTLED="$ROOT/wt-settled-merged"
WT_REDISPATCHED="$ROOT/wt-redispatched-open"

mkwt feat/merged-clean  "$WT_SWEEP"
mkwt feat/open-pr       "$WT_OPEN"
mkwt feat/merged-dirty  "$WT_DIRTY"
mkwt feat/no-pr         "$WT_NOPR"
mkwt feat/unreadable    "$WT_UNKNOWN"
mkwt feat/still-running "$WT_LIVE"
mkwt feat/closed-pr     "$WT_CLOSED"
mkwt feat/settled-merged "$WT_SETTLED"
mkwt feat/redispatched-open "$WT_REDISPATCHED"
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
# A run cleanup.sh already promoted: nothing left to do, and not an error. Its
# PR/8 outcome is terminal and long settled, so it is the run the age knob has
# to leave alone — not even polled.
mkrun already-swept "done: ready"        "$ROOT/wt-gone" "$PR/8"
printf '{"pr_url":"%s","pr_state":"MERGED","merged_at":"2026-08-20T10:00:00Z","time_to_merge_s":3600,
"review_comment_count":0,"follow_up_commits":9,"reverted":false,"checked_at":"2026-01-01T00:00:00Z"}\n' "$PR/8" \
  > "$RUNS/already-swept/outcome.json"
SETTLED_OUTCOME=$(cat "$RUNS/already-swept/outcome.json")
# The same aged terminal outcome can still have a worktree standing. It remains
# eligible for cleanup from the persisted state even though refresh has stopped.
mkrun settled-merged "done: ready" "$WT_SETTLED" "$PR/8"
printf '%s\n' "$SETTLED_OUTCOME" > "$RUNS/settled-merged/outcome.json"
# A deliberate re-dispatch can reuse the run directory for a different PR. Its
# old terminal outcome must not settle the new OPEN PR or authorize cleanup.
mkrun redispatched-open "done: ready" "$WT_REDISPATCHED" "$PR/2"
printf '%s\n' "$SETTLED_OUTCOME" > "$RUNS/redispatched-open/outcome.json"
# A run whose stage line never landed. Merged and clean, and still not the
# janitor's to take: a run whose state cannot be read is not a run that is done.
WT_NOSTATUS="$ROOT/wt-no-status"
mkwt feat/no-status "$WT_NOSTATUS"
mkrun no-status     "done: ready"        "$WT_NOSTATUS" "$PR/1"
rm -f "$RUNS/no-status/status"

# Zombies: runs whose process died without a terminal status. One fixture per
# verdict — stale and unserved (reaped), stale and served (never), fresh and
# just-under-the-knob (never), already terminal (never), merged-PR-stuck
# (reaped as shipped), an epoch-only status, a malformed one the mtime has to
# date, and an id pgrep cannot safely be asked about.
ZAG=$(date +%s);  ZAG=$((ZAG - 46800))    # 13h — over the 12h knob
ZEDGE=$(date +%s); ZEDGE=$((ZEDGE - 43000))  # just under it
mkrun zombie-stale  "demo — recording"              "" ""
printf '%s demo — recording\n' "$ZAG" > "$RUNS/zombie-stale/status"
mkrun zombie-fresh  "implementing — Opus (Claude sub)" "" ""
Z_FRESH=$(cat "$RUNS/zombie-fresh/status")
mkrun zombie-edge   "reviewing — Codex (ChatGPT sub)" "" ""
printf '%s reviewing — Codex (ChatGPT sub)\n' "$ZEDGE" > "$RUNS/zombie-edge/status"
Z_EDGE=$(cat "$RUNS/zombie-edge/status")
mkrun zombie-done   "done: ready"                  "" ""
printf '%s done: ready\n' "$ZAG" > "$RUNS/zombie-done/status"
Z_DONE=$(cat "$RUNS/zombie-done/status")
mkrun zombie-merged "sync failed — base moved"     "" "$PR/1"
printf '%s sync failed — base moved\n' "$ZAG" > "$RUNS/zombie-merged/status"
mkrun zombie-epoch  "implementing — Opus (Claude sub)" "" ""
printf '%s\n' "$ZAG" > "$RUNS/zombie-epoch/status"
mkrun zombie-junk   "whatever"                     "" ""
printf 'not a status line at all\n' > "$RUNS/zombie-junk/status"
touch -t "$(date -r "$ZAG" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$ZAG" '+%Y%m%d%H%M.%S')" \
  "$RUNS/zombie-junk/status"
mkrun "zombie odd"  "implementing — Opus (Claude sub)" "" ""
printf '%s implementing — Opus (Claude sub)\n' "$ZAG" > "$RUNS/zombie odd/status"
Z_ODD=$(cat "$RUNS/zombie odd/status")

# The load-bearing guard: a real process whose argv names the run the way a
# dispatch does, found by the real pgrep — never reaped, however stale.
cat > "$FAKES/run-task.sh" <<'EOF'
#!/usr/bin/env bash
sleep 600
EOF
chmod +x "$FAKES/run-task.sh"
mkrun zombie-live "implementing — Opus (Claude sub)" "" ""
printf '%s implementing — Opus (Claude sub)\n' "$ZAG" > "$RUNS/zombie-live/status"
Z_LIVE=$(cat "$RUNS/zombie-live/status")
bash "$FAKES/run-task.sh" zombie-live >/dev/null 2>&1 &
V_GUARD=$!
VICTIMS="$VICTIMS $V_GUARD"
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

out=$(jan "JANITOR_OUTCOME_MAX_AGE=fortnight" --report); rc=$?
nonzero "guard: a non-numeric outcome age refuses to run" "$rc"
has "$out" "JANITOR_OUTCOME_MAX_AGE must be whole days" "guard: it says what an outcome age has to be"

out=$(jan "JANITOR_ZOMBIE_HOURS=soon" --report); rc=$?
nonzero "guard: a non-numeric zombie age refuses to run" "$rc"
has "$out" "JANITOR_ZOMBIE_HOURS must be whole hours" "guard: it says what a zombie age has to be"

exists "guard: no guard removed a worktree" "$WT_SWEEP"

# ---------------------------------------------------------------------------
echo "== gh cannot answer: everything is unknown, nothing is swept =="
# ---------------------------------------------------------------------------
printf 'denied\n' > "$GH_MODE"
out=$(jan "" --clean); rc=$?
check "unauthed: --clean still exits 0" "$rc" "0"
has "$out" "gh is not authenticated" "unauthed: it says the state cannot be read"
has "$out" "--clean degraded to report-only" "unauthed: the whole pass explicitly becomes report-only"
check "unauthed: nothing is sweepable" "$(verbs "$out" sweep)" "0"
check "unauthed: the merged run is unknown, not merged" "$(verb "$out" merged-clean)" "keep"
has "$out" "PR state unreadable" "unauthed: an unreadable state is named as one"
check "unauthed: a zombie is only listed, never written" "$(verb "$out" zombie-stale)" "reap"
check "unauthed: the zombie's status is untouched" "$(cat "$RUNS/zombie-stale/status")" "$ZAG demo — recording"
exists "unauthed: the merged worktree is still there" "$WT_SWEEP"
absent "unauthed: no outcome is written off a state nobody could read" \
  "$RUNS/merged-clean/outcome.json"
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
  # This PATH has no pgrep either: the guard cannot run, so no zombie is even a
  # candidate — an absence nobody can prove reaps nothing.
  has "$out" "pgrep is unavailable — a stale status is never reaped without it" \
    "no gh: without pgrep the reap pass refuses to run"
  check "no gh: nothing is reapable" "$(verbs "$out" reap)" "0"
  exists "no gh: the merged worktree is still there" "$WT_SWEEP"
  check "no gh: the zombie's status is untouched" "$(cat "$RUNS/zombie-stale/status")" "$ZAG demo — recording"
fi

# ---------------------------------------------------------------------------
echo "== outcome: an api that errors degrades to a null, never a failed sweep =="
# ---------------------------------------------------------------------------
printf 'api-down\n' > "$GH_MODE"
out=$(jan "" --report); rc=$?
check "api-down: --report still exits 0" "$rc" "0"
check "api-down: the merged run's outcome still records the state" \
  "$(oc .pr_state merged-clean)" "MERGED"
check "api-down: and the follow-up count, which asks git and not the api" \
  "$(oc .follow_up_commits merged-clean)" "3"
check "api-down: the review count it could not read is null, not a zero it never counted" \
  "$(oc .review_comment_count merged-clean)" "null"
printf 'authed\n' > "$GH_MODE"

# ---------------------------------------------------------------------------
echo "== --report: one sweepable run, and nothing touched =="
# ---------------------------------------------------------------------------
: > "$GH_LOG"
out=$(jan "" --report); rc=$?
check "report: exits 0" "$rc" "0"
# The cwd is matched by its tail: cd normalises the doubled slash mktemp can
# leave in $TMPDIR, so the recorded path is not $WT_OPEN byte for byte.
file_has "$GH_LOG" "/wt-open-pr argv:pr view $PR/2 --json state,mergedAt,createdAt,mergeCommit,files" \
  "report: each PR is asked about from inside that run's own worktree"

check "report: merged + clean is the one to sweep"      "$(verb "$out" merged-clean)"  "sweep"
check "report: exactly two runs are sweepable"           "$(verbs "$out" sweep)"        "2"
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

echo "== --report: zombies are listed, never written =="
check "report: a stale status with no server is a zombie to reap" "$(verb "$out" zombie-stale)"  "reap"
check "report: a merged-PR zombie is one too"                     "$(verb "$out" zombie-merged)" "reap"
check "report: an epoch-only status is one too"                   "$(verb "$out" zombie-epoch)"  "reap"
check "report: a malformed status is dated by its mtime"          "$(verb "$out" zombie-junk)"   "reap"
check "report: a stale run a process is serving is guarded"       "$(verb "$out" zombie-live)"   "live"
check "report: a fresh status is no zombie"                       "$(verb "$out" zombie-fresh)"  ""
check "report: one just under the knob is no zombie either"       "$(verb "$out" zombie-edge)"   ""
check "report: a terminal status is never a zombie"               "$(verb "$out" zombie-done)"   ""
has "$out" "would write: done: reaped (stale — no live process, was: demo — recording)" \
  "report: it shows the status it would write"
has "$out" "would write: done: ready (reaped — PR merged)" "report: a merged zombie names its verdict"
has "$out" "was: no stage text" "report: an epoch-only reap says what it could not read"
has "$out" "was: not a status line at all" "report: a malformed reap keeps the old text"
has "$out" "zombies: statuses older than 12h" "report: the pass says what it looks for"
has "$out" "4 to reap, 1 guarded by a live process, 3 under 12h, 1 could not be judged" \
  "report: it counts every side of the reap"

# A run whose worktree cleanup.sh already removed is not a finding, the
# quartermaster's report directory is not a run, and neither are the zombies —
# worktree-less ghosts are exactly what this pass is for.
has "$out" "10 of 20 runs had no worktree left" "report: the worktree-less runs are counted, not reported"
has "$out" "8 kept" "report: the eight it may not touch are counted"
has "$out" "2 worktree(s) sweepable" "report: the sweepable count is on the summary line"
has "$out" "kept: 2 open · 1 closed · 1 dirty · 1 unknown · 1 no-pr · 2 unfinished" \
  "report: the summary breaks the kept runs down by reason"
has "$out" "--report swept and reaped nothing" "report: it says it did nothing"
has "$out" "outcomes: 8 written · 2 settled (terminal, over 14 days old) · 1 not readable" \
  "report: the outcome counts are on the summary line"

echo "== --report is side-effect-free =="
for w in "$WT_SWEEP" "$WT_OPEN" "$WT_DIRTY" "$WT_NOPR" "$WT_UNKNOWN" "$WT_LIVE" "$WT_CLOSED" \
         "$WT_NOSTATUS" "$WT_SETTLED" "$WT_REDISPATCHED"; do
  exists "report: $(basename "$w") is untouched" "$w"
done
check "report: git still knows every worktree" "$(wt_count)" "$WT_BEFORE"
exists "report: the dirty file was not committed away" "$WT_DIRTY/scratch.txt"
absent "report: no LaunchAgent was written" "$AGENTS/com.olyx.janitor.plist"
check "report: the stale zombie's status is unwritten" "$(cat "$RUNS/zombie-stale/status")" "$ZAG demo — recording"
absent "report: no reap line reached stages.log" "$RUNS/zombie-stale/stages.log"
absent "report: nor timeline" "$RUNS/zombie-stale/timeline"

# ---------------------------------------------------------------------------
echo "== outcome.json: the ground truth a finished run leaves behind =="
# ---------------------------------------------------------------------------
# Every number below is computed against the fixture repo's refreshed history:
# three commits after $M1 touch impl.txt (a follow-up, the revert, and one pushed
# from another clone), none touch
# other.txt, and the revert's message names $M1.
check "outcome: a merged run records the PR state"      "$(oc .pr_state merged-clean)" "MERGED"
check "outcome: when it merged"                          "$(oc .merged_at merged-clean)" "2026-08-20T10:00:00Z"
check "outcome: how long the PR took to merge"           "$(oc .time_to_merge_s merged-clean)" "3600"
check "outcome: how many review comments humans left"    "$(oc .review_comment_count merged-clean)" "1"
check "outcome: base commits after the merge touching its files" \
  "$(oc .follow_up_commits merged-clean)" "3"
check "outcome: the base ref was refreshed from remote" \
  "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" "$REMOTE_FOLLOW"
check "outcome: a revert commit naming the squash SHA"   "$(oc .reverted merged-clean)" "true"
# The api count that failed in the api-down pass is re-read now that it answers.
check "outcome: a field that was null is refreshed, not left behind" \
  "$(oc .review_comment_count merged-clean)" "1"

check "outcome: an OPEN PR has no merge facts to record" "$(oc .pr_state open-pr)" "OPEN"
check "outcome: open means no merged_at"                 "$(oc .merged_at open-pr)" "null"
check "outcome: and no time-to-merge"                    "$(oc .time_to_merge_s open-pr)" "null"
check "outcome: its review comments are still the signal" "$(oc .review_comment_count open-pr)" "3"
check "outcome: no git facts are invented for it"        "$(oc .follow_up_commits open-pr)" "null"
check "outcome: a CLOSED PR is recorded as closed"       "$(oc .pr_state closed-pr)" "CLOSED"
check "outcome: closed, so terminal, and never merged"   "$(oc .merged_at closed-pr)" "null"
# A different landing commit on the same history: no commit after $F2 touches
# other.txt. The later documentation commit mentions $F2 in prose but does not
# carry git-revert's exact trailer, so it must not be labeled as a revert.
check "outcome: a PR nothing followed up on reads zero"  "$(oc .follow_up_commits merged-dirty)" "0"
check "outcome: and is not reverted"                     "$(oc .reverted merged-dirty)" "false"
# The api answers an empty page and exit 0 for PR 3: zero comments, not the
# blank line a sloppier count would turn into one.
check "outcome: a PR nobody commented on counts zero"    "$(oc .review_comment_count merged-dirty)" "0"
check "outcome: a live run's PR fate is recorded too"    "$(oc .pr_state still-running)" "MERGED"
# The merged zombie's reap (asserted in --clean below) reads exactly this file:
# the poll the sweep already made is the whole merge-detection cost.
check "outcome: a merged zombie's PR fate is recorded"   "$(oc .pr_state zombie-merged)" "MERGED"
exists "outcome: the repo the git facts came from is kept in the run dir" "$RUNS/merged-clean/repo"
# The state nobody could read is not an outcome: PR 5 has no pr-5 fixture, so
# the poll fails and nothing is written that would pretend to knowledge.
absent "outcome: an unreadable PR writes no outcome"     "$RUNS/unreadable/outcome.json"

# The age knob: a terminal outcome older than the knob is not even polled, and
# the file is left exactly as it was.
check "outcome: a settled outcome is not rewritten" "$(cat "$RUNS/already-swept/outcome.json")" "$SETTLED_OUTCOME"
has_not "$(cat "$GH_LOG")" "$PR/8" "outcome: a settled outcome is not even polled"
check "outcome: a settled standing run is still sweepable" "$(verb "$out" settled-merged)" "sweep"
check "outcome: a reused run refreshes against its current PR" \
  "$(oc .pr_state redispatched-open)" "OPEN"
check "outcome: the replacement PR is recorded with the outcome" \
  "$(oc .pr_url redispatched-open)" "$PR/2"
check "outcome: an old merged PR cannot authorize cleanup of the new one" \
  "$(verb "$out" redispatched-open)" "keep"
check "outcome: exactly one api call per refreshed run" \
  "$(grep -c "pulls/2/comments" "$GH_LOG" | tr -d ' ')" "2"

# Two independent sweeps may refresh the same run at once (for example, the
# scheduled pass and an operator's manual report). The synchronized jq wrapper
# makes the shorter CLOSED write finish after the longer MERGED write. A shared
# temp inode leaves trailing bytes; unique same-directory temps leave one whole
# atomic result.
RACE_HARNESS="$ROOT/race-harness"
RACE_RUN="$RACE_HARNESS/runs/race"
RACE_OUTCOME="$RACE_RUN/outcome.json"
RACE_SYNC="$ROOT/outcome-race"
mkdir -p "$RACE_RUN"
printf '%s %s\n' "$(date +%s)" "done: ready" > "$RACE_RUN/status"
printf '{"ticket":"race","status":"ready","worktree":"%s","branch":"feat/race","base":"main","pr_url":"%s"}\n' \
  "$WT_OPEN" "$PR/1" > "$RACE_RUN/result.json"
jan "HARNESS_DIR=$RACE_HARNESS JANITOR_TEST_JQ_SYNC=$RACE_SYNC JANITOR_TEST_OUTCOME=$RACE_OUTCOME JANITOR_TEST_PR_VARIANT=merged" \
  --report > "$ROOT/race-merged.log" &
RACE_MERGED_PID=$!
jan "HARNESS_DIR=$RACE_HARNESS JANITOR_TEST_JQ_SYNC=$RACE_SYNC JANITOR_TEST_OUTCOME=$RACE_OUTCOME JANITOR_TEST_PR_VARIANT=closed" \
  --report > "$ROOT/race-closed.log" &
RACE_CLOSED_PID=$!
wait "$RACE_MERGED_PID"; RACE_MERGED_RC=$?
wait "$RACE_CLOSED_PID"; RACE_CLOSED_RC=$?
check "outcome concurrency: both overlapping reports complete" \
  "$RACE_MERGED_RC,$RACE_CLOSED_RC" "0,0"
if jq -e . "$RACE_OUTCOME" >/dev/null 2>&1; then
  ok "outcome concurrency: the final outcome is valid JSON"
else
  bad "outcome concurrency: overlapping writers corrupted outcome.json"
fi
check "outcome concurrency: the later complete write wins atomically" \
  "$(jq -r '.pr_state // ""' "$RACE_OUTCOME" 2>/dev/null)" "CLOSED"
RACE_TEMPS=0
for f in "$RACE_OUTCOME".tmp.*; do [ ! -e "$f" ] || RACE_TEMPS=$((RACE_TEMPS + 1)); done
check "outcome concurrency: no writer leaves a temp file" "$RACE_TEMPS" "0"

# ---------------------------------------------------------------------------
echo "== --clean: merged clean worktrees, including settled ones =="
# ---------------------------------------------------------------------------
out=$(jan "" --clean); rc=$?
check "clean: exits 0" "$rc" "0"
absent "clean: the merged clean worktree is gone" "$WT_SWEEP"
absent "clean: the settled merged worktree is gone" "$WT_SETTLED"
for w in "$WT_OPEN" "$WT_DIRTY" "$WT_NOPR" "$WT_UNKNOWN" "$WT_LIVE" "$WT_CLOSED" "$WT_NOSTATUS" "$WT_REDISPATCHED"; do
  exists "clean: $(basename "$w") is still there" "$w"
done
check "clean: git dropped exactly two worktrees" "$(wt_count)" "$((WT_BEFORE - 2))"
has_not "$(git -C "$REPO" worktree list)" "wt-merged-clean" "clean: git no longer lists the swept worktree"
has     "$(git -C "$REPO" worktree list)" "wt-open-pr"      "clean: git still lists the open PR's worktree"

has "$out" "2 worktree(s) swept" "clean: the summary counts the sweep"
has "$out" "removed worktree $WT_SWEEP" "clean: cleanup.sh is what removed it, and says so"
has "$out" "run logs kept at $RUNS/merged-clean" "clean: cleanup.sh kept the run's logs"
has "$out" "pruned worktree metadata in $REPO_REAL" "clean: the repo it touched was pruned"

echo "== --clean: zombies are reaped, the guarded one is not =="
check "reap: the stale zombie is reaped"        "$(verb "$out" zombie-stale)"  "reaped"
check "reap: the merged zombie is reaped"       "$(verb "$out" zombie-merged)" "reaped"
check "reap: the epoch-only zombie is reaped"   "$(verb "$out" zombie-epoch)"  "reaped"
check "reap: the malformed zombie is reaped"    "$(verb "$out" zombie-junk)"   "reaped"
check "reap: the guarded zombie is only named"  "$(verb "$out" zombie-live)"   "live"
check "reap: the status turns terminal with reason and prior stage" \
  "$(sed -n '1s/^[0-9]* //p' "$RUNS/zombie-stale/status")" \
  "done: reaped (stale — no live process, was: demo — recording)"
zt=$(cut -d' ' -f1 < "$RUNS/zombie-stale/status")
case "$zt" in *[!0-9]*|'') bad "reap: the new status carries an epoch (got [$zt])" ;;
                    *)     ok   "reap: the new status carries an epoch" ;; esac
check "reap: a merged PR reaps as ready, not as a generic zombie" \
  "$(sed -n '1s/^[0-9]* //p' "$RUNS/zombie-merged/status")" "done: ready (reaped — PR merged)"
check "reap: an epoch-only status says it had no stage text" \
  "$(sed -n '1s/^[0-9]* //p' "$RUNS/zombie-epoch/status")" \
  "done: reaped (stale — no live process, was: no stage text)"
check "reap: a malformed status is reaped with its old text kept" \
  "$(sed -n '1s/^[0-9]* //p' "$RUNS/zombie-junk/status")" \
  "done: reaped (stale — no live process, was: not a status line at all)"
file_has "$RUNS/zombie-stale/stages.log" "done: reaped (stale — no live process, was: demo — recording)" \
  "reap: stages.log carries the honest line"
file_has "$RUNS/zombie-stale/timeline" "done: reaped (stale — no live process, was: demo — recording)" \
  "reap: and so does timeline"
check "reap: the guarded run's status is untouched" "$(cat "$RUNS/zombie-live/status")" "$Z_LIVE"
alive "reap: the guard process itself survives" "$V_GUARD"
check "reap: a fresh status is untouched"        "$(cat "$RUNS/zombie-fresh/status")" "$Z_FRESH"
check "reap: one under the knob is untouched"    "$(cat "$RUNS/zombie-edge/status")"  "$Z_EDGE"
check "reap: a terminal status is untouched"     "$(cat "$RUNS/zombie-done/status")"  "$Z_DONE"
check "reap: an unaskable id is untouched"       "$(cat "$RUNS/zombie odd/status")"   "$Z_ODD"
has "$out" "4 reaped, 1 guarded by a live process, 3 under 12h, 1 could not be judged" \
  "reap: the summary counts both sides"
exists "reap: the reaped run's dir survives"      "$RUNS/zombie-stale"
exists "reap: and its result.json survives"       "$RUNS/zombie-stale/result.json"
exists "reap: and its feed.log survives"          "$RUNS/zombie-stale/feed.log"

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
has "$out" "12 of 20 runs had no worktree left" "again: the swept runs join the already-clean one"
check "again: still eight kept" "$(verbs "$out" keep)" "8"

echo "== a reaped zombie is done, and never reaped twice =="
check "again: the reaped status is left as written" \
  "$(sed -n '1s/^[0-9]* //p' "$RUNS/zombie-stale/status")" \
  "done: reaped (stale — no live process, was: demo — recording)"
check "again: stages.log carries the reap exactly once" \
  "$(grep -cF "done: reaped (stale" "$RUNS/zombie-stale/stages.log" | tr -d ' ')" "1"
has "$out" "0 reaped, 1 guarded by a live process" "again: only the guarded zombie remains a finding"

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
V_OLD1=$(spawn); V_YOUNG=$(spawn); V_EDGE=$(spawn); V_OLD2=$(spawn)
V_SIMILAR=$(spawn); V_BAD_TIME=$(spawn); V_OTHER=$(spawn)
VICTIMS="$V_OLD1 $V_YOUNG $V_EDGE $V_OLD2 $V_SIMILAR $V_BAD_TIME $V_OTHER"

# Cover every boundary that could turn a report into the wrong kill: days, just
# under / exactly on / just over the limit, a similar name, and malformed etime.
{
  printf '%s 2-03:04:05 %s\n' "$V_OLD1"  "$ROOT/flutter/cache/flutter_tester"
  printf '%s 01:59:59 %s\n'   "$V_YOUNG" "$ROOT/flutter/cache/flutter_tester"
  printf '%s 02:00:00 %s\n'   "$V_EDGE"  "$ROOT/flutter/cache/flutter_tester"
  printf '%s 02:00:01 %s\n'   "$V_OLD2"  "$ROOT/flutter/cache/flutter_tester"
  printf '%s 05:00:00 %s\n'   "$V_SIMILAR" "$ROOT/flutter/cache/flutter_tester_helper"
  printf '%s 01:99:00 %s\n'   "$V_BAD_TIME" "$ROOT/flutter/cache/flutter_tester"
  printf '%s 05:00:00 %s\n'   "$V_OTHER" "/bin/sleep"
} > "$PS_FIXTURE"

out=$(jan "" --report); rc=$?
check "procs: --report exits 0" "$rc" "0"
check "procs: a two-day-old runner is listed"     "$(verb "$out" "$V_OLD1")"  "kill"
check "procs: one a second over the limit is too" "$(verb "$out" "$V_OLD2")"  "kill"
check "procs: one a second under it is not"       "$(verb "$out" "$V_YOUNG")" ""
check "procs: one exactly on the limit is not older" "$(verb "$out" "$V_EDGE")" ""
check "procs: a similar process name is not a match" "$(verb "$out" "$V_SIMILAR")" ""
check "procs: malformed elapsed time is not actionable" "$(verb "$out" "$V_BAD_TIME")" ""
check "procs: an unrelated old process is not"    "$(verb "$out" "$V_OTHER")" ""
has "$out" "processes: flutter_tester older than 2h00m" "procs: the report says what it looks for"
has "$out" "2 to kill, 2 not older than 2h00m left alone" "procs: it counts both sides"
has "$out" "up 51h04m" "procs: it says how long the oldest has been up"
alive "procs: --report killed nothing (old #1)" "$V_OLD1"
alive "procs: --report killed nothing (old #2)" "$V_OLD2"

printf 'denied\n' > "$GH_MODE"
out=$(jan "" --clean); rc=$?
check "degraded reap: --clean still exits 0" "$rc" "0"
has "$out" "no worktrees or processes will be touched" "degraded reap: the no-side-effect boundary is explicit"
check "degraded reap: an old runner is only reported" "$(verb "$out" "$V_OLD1")" "kill"
alive "degraded reap: the old runner is left alone" "$V_OLD1"
printf 'authed\n' > "$GH_MODE"

out=$(jan "" --clean); rc=$?
check "reap: --clean exits 0" "$rc" "0"
check "reap: the two-day-old runner was killed" "$(verb "$out" "$V_OLD1")" "killed"
has "$out" "2 killed, 0 survived, 2 not older than 2h00m left alone" "reap: it reports what it killed"
dead  "reap: the two-day-old runner is gone" "$V_OLD1"
dead  "reap: the one just over the limit is gone" "$V_OLD2"
alive "reap: the young runner is left alone" "$V_YOUNG"
alive "reap: the runner exactly at the limit is left alone" "$V_EDGE"
alive "reap: the similarly named process is left alone" "$V_SIMILAR"
alive "reap: the runner with malformed elapsed time is left alone" "$V_BAD_TIME"
alive "reap: the unrelated process is left alone" "$V_OTHER"

echo "== JANITOR_PROC_AGE and JANITOR_PROC_MATCH move the line =="
out=$(jan "JANITOR_PROC_AGE=60" --report)
check "knob: a one-minute age catches the young runner too" "$(verb "$out" "$V_YOUNG")" "kill"
out=$(jan "JANITOR_PROC_MATCH=sleep" --report)
check "knob: the match selects by process name" "$(verb "$out" "$V_OTHER")" "kill"
check "knob: and only by process name" "$(verb "$out" "$V_YOUNG")" ""
: > "$PS_FIXTURE"

echo "== JANITOR_ZOMBIE_HOURS moves the other line =="
out=$(jan "JANITOR_ZOMBIE_HOURS=48" --report)
check "knob: a 48h window leaves the 13h zombie alone" "$(verb "$out" zombie-stale)" ""
out=$(jan "JANITOR_ZOMBIE_HOURS=1" --report)
check "knob: a 1h window still respects the live guard" "$(verb "$out" zombie-live)" "live"

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
for k in JANITOR_AT JANITOR_PROC_AGE JANITOR_PROC_MATCH JANITOR_GH_TIMEOUT JANITOR_OUTCOME_MAX_AGE JANITOR_ZOMBIE_HOURS; do
  file_has "$SRC/docs/operations.md" "$k" "docs: operations documents $k"
done

echo
printf 'janitor: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
