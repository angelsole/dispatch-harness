#!/usr/bin/env bash
# The PREPROD contract: with PREPROD=1 pinned for a repo, run-task.sh states the
# pre-production posture to BOTH workers; with it unset, both prompts are
# exactly the prompts the harness sent before the flag existed.
#
# Neither half can be asserted by reading run-task.sh — the prompts are built
# from a variable the config layer sets — so both runs are real run-task.sh
# invocations against a fabricated repo with a local bare remote and fake
# `claude` / `codex` binaries that record the prompt they were handed. The fake
# reviewer rejects, which stops the run before push/PR: nothing here reaches a
# network, and every write lands in a temp sandbox.
#
# Usage: bash tests/preprod.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/preprod-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3"; else ok "$3"; fi; }

# The seven posture points, one distinctive fragment each.
POINTS='Do not preserve backward compatibility.
simplest implementation that fully meets the current requirements
Grow the system in layers
Keep components modular
Prefer established, well-maintained libraries
Lean on the dependencies already in the project
Make architectural decisions for the long term'

# --- fixture: a repo with a real (local) origin ------------------------------
BARE="$ROOT/origin.git"
REPO="$ROOT/greenapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

# --- fake workers: record the prompt, then move the pipeline along -----------
FAKES="$ROOT/bin"; FHOME="$ROOT/home"; mkdir -p "$FAKES" "$FHOME"
cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
# Implementer stand-in: save the -p prompt, commit so the run reaches review.
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
# Reviewer stand-in: `codex exec` takes the prompt as its last argument and the
# worktree after -C. Rejecting ends the run before the push/PR stage.
wt=""; prev=""; last=""
for a in "$@"; do
  [ "$prev" = "-C" ] && wt="$a"
  prev="$a"; last="$a"
done
printf '%s' "$last" > "$CAPTURE_REVIEW"
printf 'fixture stop\n' > "$wt/.harness/REJECTED.md"
SH
chmod +x "$FAKES/claude" "$FAKES/codex"

run_pipeline() {  # $1 = ticket, $2 = 1 to pin PREPROD for the fixture repo
  local ticket="$1" h="$ROOT/harness-$1"
  mkdir -p "$h/runs/$ticket"
  cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$h/"
  cp -R "$SRC/lib" "$h/lib"   # repos.conf.sh reads the shared helpers from beside itself
  if [ "$2" = 1 ]; then
    cat > "$h/repos.local.sh" <<'SH'
repo_config_local() {
  case "$2" in
    greenapp|greenapp-*) PREPROD=1 ;;
  esac
}
SH
  fi
  printf '# fixture task\n' > "$h/runs/$ticket/brief.md"
  env -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
  CAPTURE_IMPL="$ROOT/impl-$ticket.txt" CAPTURE_REVIEW="$ROOT/review-$ticket.txt" \
  HOME="$FHOME" HARNESS_DIR="$h" \
  CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
  HARNESS_REVIEW_NETWORK=0 \
  HARNESS_NOTIFY=0 HARNESS_NTFY_TOPIC="" \
    bash "$SRC/run-task.sh" "$ticket" "$REPO" "fix/$ticket" > "$ROOT/run-$ticket.log" 2>&1
  return 0   # the fixture run ends in `rejected`, i.e. non-zero, by design
}

run_pipeline preprod-off 0
run_pipeline preprod-on  1

read_capture() { cat "$1" 2>/dev/null || true; }
OFF_IMPL="$(read_capture "$ROOT/impl-preprod-off.txt")"
OFF_REVIEW="$(read_capture "$ROOT/review-preprod-off.txt")"
ON_IMPL="$(read_capture "$ROOT/impl-preprod-on.txt")"
ON_REVIEW="$(read_capture "$ROOT/review-preprod-on.txt")"

# ---------------------------------------------------------------------------
# The runs actually happened (a broken fixture must not read as a green suite)
# ---------------------------------------------------------------------------
echo "== fixture runs reached both workers =="
has "$OFF_IMPL"   'You are the implementer stage of an automated pipeline.' "capture: implementer prompt (PREPROD unset)"
has "$OFF_REVIEW" 'You are the reviewer stage of an automated pipeline'     "capture: reviewer prompt (PREPROD unset)"
has "$ON_IMPL"    'You are the implementer stage of an automated pipeline.' "capture: implementer prompt (PREPROD=1)"
has "$ON_REVIEW"  'You are the reviewer stage of an automated pipeline'     "capture: reviewer prompt (PREPROD=1)"

# ---------------------------------------------------------------------------
# PREPROD unset: no posture anywhere
# ---------------------------------------------------------------------------
echo "== PREPROD unset: prompts are untouched =="
has_not "$OFF_IMPL"   'NOT in production yet'         "off: implementer prompt carries no posture"
has_not "$OFF_IMPL"   'backward compatibility'        "off: implementer prompt says nothing about back-compat"
has_not "$OFF_REVIEW" 'NOT in production yet'         "off: reviewer prompt carries no posture"
has_not "$OFF_REVIEW" 'backward-compatibility shims'  "off: reviewer prompt keeps the stock checklist"

# ---------------------------------------------------------------------------
# PREPROD=1: the posture is appended, and appending is ALL that changed
# ---------------------------------------------------------------------------
echo "== PREPROD=1: posture appended to both prompts =="
IMPL_DELTA="${ON_IMPL#"$OFF_IMPL"}"
REVIEW_DELTA="${ON_REVIEW#"$OFF_REVIEW"}"
if [ -n "$OFF_IMPL" ] && [ "$IMPL_DELTA" != "$ON_IMPL" ]; then
  ok "on: implementer prompt is the unset prompt plus an appended block"
else
  bad "on: implementer prompt is the unset prompt plus an appended block"
fi
if [ -n "$OFF_REVIEW" ] && [ "$REVIEW_DELTA" != "$ON_REVIEW" ]; then
  ok "on: reviewer prompt is the unset prompt plus an appended block"
else
  bad "on: reviewer prompt is the unset prompt plus an appended block"
fi

has "$IMPL_DELTA"   'This repo is NOT in production yet' "on: implementer block names the posture"
has "$REVIEW_DELTA" 'This repo is NOT in production yet' "on: reviewer block names the posture"

while IFS= read -r point; do
  has "$IMPL_DELTA"   "$point" "on: implementer block keeps point [${point:0:40}]"
  has "$REVIEW_DELTA" "$point" "on: reviewer block keeps point [${point:0:40}]"
done <<EOF
$POINTS
EOF

# The reviewer needs the posture spelled out as a review instruction, or it
# spends its round demanding the shims the implementer was told not to write.
has     "$REVIEW_DELTA" 'do NOT request backward-compatibility shims, fallbacks, or migration paths' \
  "on: reviewer block forbids demanding back-compat"
has_not "$IMPL_DELTA"   'do NOT request backward-compatibility shims' \
  "on: the review-only instruction stays out of the implementer prompt"

# ---------------------------------------------------------------------------
# Config plumbing: PREPROD is per-repo, and never leaks to the next repo
# ---------------------------------------------------------------------------
echo "== repo_config resets PREPROD between repos =="
pin_check() {
  export HARNESS_DIR="$ROOT/harness-preprod-on"
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/repos.conf.sh"
  repo_config "$REPO"; [ "$PREPROD" = 1 ] || { echo "pinned repo: PREPROD=[$PREPROD]"; return 1; }
  repo_config "$BARE"; [ -z "$PREPROD" ] || { echo "unpinned repo: PREPROD=[$PREPROD]"; return 1; }
}
if ( pin_check >/dev/null ); then
  ok "conf: pinned repo gets PREPROD=1, the next repo gets none"
else
  bad "conf: pinned repo gets PREPROD=1, the next repo gets none"
fi

echo "== PREPROD is documented where the other pins are =="
doc_has() {  # $1 = file, $2 = label
  if grep -q 'PREPROD' "$SRC/$1"; then ok "docs: $2 documents PREPROD"; else bad "docs: $2 documents PREPROD"; fi
}
doc_has repos.conf.sh          "repos.conf.sh header"
doc_has repos.local.sh.example "repos.local.sh.example"
doc_has README.md              "README"

echo
printf 'preprod: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
