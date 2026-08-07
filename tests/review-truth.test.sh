#!/usr/bin/env bash
# Telling the truth about the review stage.
#
# An unreviewed diff says so on the PR itself. A dead review stage used to leave
# nothing on the PR but a missing "## Review notes" section — the failure lived
# in result.json and a notification nobody re-reads. Now the body opens with the
# warning, worded by cause, and a later dispatch that does get a review
# regenerates a body without it.
#
# Nothing real is contacted. `claude` (implementer), `codex` (reviewer), `gh`
# (the PR) and `curl` (ntfy) are fake binaries on PATH driven by mode files, and
# every run is a real run-task.sh invocation against a fabricated repo with a
# local bare remote — the technique tests/pipeline-telemetry.test.sh uses.
#
# Usage: bash tests/review-truth.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-truth-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# The warning, verbatim. Anything that rewords it has to reword it here too —
# which is the point: the two causes read differently and both are pinned.
WARN_DEAD='> ⚠️ **This diff is unreviewed.** The Codex review stage produced no evidence. A human review is required before merge.'
WARN_NOCODEX='> ⚠️ **This diff is unreviewed.** The Codex review stage is not installed on this machine. A human review is required before merge.'

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
CODEX_MODE="$ROOT/codex-mode"
PR_BODIES="$ROOT/pr-bodies"

mkdir -p "$FHOME" "$RUNS" "$SRCDIR" "$FAKES" "$PR_BODIES"
printf 'notes\n' > "$CODEX_MODE"

cp "$SRC/run-task.sh" "$SRCDIR/run-task.sh"
chmod +x "$SRCDIR/run-task.sh"
cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"

cat > "$HARNESS/repos.local.sh" <<'EOF'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) INSTALL_CMD=''; GATE_CMD='true' ;;
  esac
}
EOF

BARE="$ROOT/origin.git"
REPO="$ROOT/greenapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# --- fakes -------------------------------------------------------------------
# Implementer stand-in: a diff big enough that the review floor applies to it.
cat > "$FAKES/claude" <<'EOF'
#!/usr/bin/env bash
seq 1 30 >> impl.txt
git add -A
git commit -q -m "feat: fixture change"
EOF

# Reviewer stand-in: `instant` is the confirmed failure — it returns at once
# having touched nothing at all.
cat > "$FAKES/codex" <<EOF
#!/usr/bin/env bash
wt=""; prev=""
for a in "\$@"; do
  if [ "\$prev" = "-C" ]; then wt="\$a"; break; fi
  prev="\$a"
done
case "\$(cat "$CODEX_MODE")" in
  instant) echo "codex: done" ;;
  notes)   printf '# review\n\nEverything is sound.\n' > "\$wt/.harness/review-notes.md" ;;
esac
EOF

cat > "$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# The PR step. `pr create` keeps the body it was handed, so the assertions can
# read what GitHub would actually have received rather than the file behind it.
cat > "$FAKES/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr create")
    body=""; prev=""
    for a in "\$@"; do
      if [ "\$prev" = "--body-file" ]; then body="\$a"; break; fi
      prev="\$a"
    done
    branch=""; prev=""
    for a in "\$@"; do
      if [ "\$prev" = "--head" ]; then branch="\$a"; break; fi
      prev="\$a"
    done
    [ -n "\$body" ] && cp "\$body" "$PR_BODIES/\$(basename "\$branch")"
    echo "https://example.invalid/pr/1"
    ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/curl" "$FAKES/gh"

# --- the harness under test ---------------------------------------------------
dispatch() {  # $1 = run id, $2 = space-separated VAR=VAL overrides (may be empty)
  local ticket="$1" overrides="$2"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC=review-truth-test \
      $overrides \
      bash "$SRCDIR/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1
  return 0
}
result()  { jq -r "$1 // \"\"" "$RUN/result.json" 2>/dev/null; }
pr_body() { cat "$PR_BODIES/$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo "== an unreviewed diff says so on the PR itself =="
# ---------------------------------------------------------------------------
printf 'instant\n' > "$CODEX_MODE"
dispatch PR-DEAD ""
check "dead review: the run still ships, as it always did" "$(result .status)" "ready"
check "dead review: and is recorded as the silent failure it is" \
  "$(result .review)" "failed_silent"
check "dead review: the PR body LEADS with the warning — above the Ref line" \
  "$(pr_body PR-DEAD | sed -n 1p)" "$WARN_DEAD"
has "$(pr_body PR-DEAD)" "Ref: PR-DEAD" "dead review: the body it always had follows"
file_has "$RUN/pr-body.md" "$WARN_DEAD" "dead review: and the body file on disk agrees"

# A review that took real time and left nothing is no_evidence rather than
# failed_silent — a different classification, the same unreviewed diff.
dispatch PR-NOEVIDENCE "HARNESS_REVIEW_MIN_SECONDS=0"
check "no_evidence: recorded as before" "$(result .review)" "no_evidence"
check "no_evidence: nothing proved anything about this diff either" \
  "$(pr_body PR-NOEVIDENCE | sed -n 1p)" "$WARN_DEAD"

# A machine with no codex CLI reviews nothing — for a reason worth wording
# differently, because the fix is installing something, not reading a log.
dispatch PR-NOCODEX "CODEX_BIN=$ROOT/no-such-codex"
check "no codex: the arm says review-less" "$(result .arm)" "no_review"
check "no codex: the warning names the cause" \
  "$(pr_body PR-NOCODEX | sed -n 1p)" "$WARN_NOCODEX"

# ---------------------------------------------------------------------------
echo "== a reviewed diff's PR is exactly the PR it was before =="
# ---------------------------------------------------------------------------
printf 'notes\n' > "$CODEX_MODE"
dispatch PR-REVIEWED ""
check "reviewed: recorded as a real review" "$(result .review)" "reviewed"
check "reviewed: the body still opens on the Ref line" \
  "$(pr_body PR-REVIEWED | sed -n 1p)" "Ref: PR-REVIEWED"
has_not "$(pr_body PR-REVIEWED)" "This diff is unreviewed" \
  "reviewed: no warning anywhere in the body"
has "$(pr_body PR-REVIEWED)" "## Review notes" "reviewed: the review notes are there"

# The ablation arm is an experimental condition its operator chose, not a stage
# that died — it is measured, not warned about.
dispatch PR-SKIPARM "HARNESS_SKIP_REVIEW=1"
check "skip arm: review recorded as skipped" "$(result .review)" "skipped"
has_not "$(pr_body PR-SKIPARM)" "This diff is unreviewed" \
  "skip arm: the deliberate no-review arm carries no warning"

# ---------------------------------------------------------------------------
echo "== a later dispatch that gets a review regenerates a body without it =="
# ---------------------------------------------------------------------------
printf 'instant\n' > "$CODEX_MODE"
dispatch PR-REDISPATCH ""
file_has "$RUN/pr-body.md" "$WARN_DEAD" "re-dispatch: the first run's body warns"
printf 'notes\n' > "$CODEX_MODE"
dispatch PR-REDISPATCH ""
check "re-dispatch: the second run really did review" "$(result .review)" "reviewed"
if grep -qF -- "$WARN_DEAD" "$RUN/pr-body.md"; then
  bad "re-dispatch: the warning is gone with the regenerated body"
else
  ok "re-dispatch: the warning is gone with the regenerated body"
fi
file_has "$RUN/pr-body.md" "## Review notes" "re-dispatch: replaced by the notes"

echo
printf 'review truth: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
