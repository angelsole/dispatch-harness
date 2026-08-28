#!/usr/bin/env bash
# The owner-notify contract: a stage handoff reaches the run owner's own ntfy
# topic as well as the machine's room feed, the two pushes are identical
# beyond the topic, and with no per-owner topic configured nothing changes at
# all — the global-only run sends exactly one push per stage to exactly
# <server>/<topic>. And the one thing that must never happen: a topic value,
# a hard-to-guess secret by notify.conf.example's own rule, reaching stdout
# or any file in the run dir.
#
# Two halves. The unit half sources lib/notify.sh and pins ntfy_owner_key and
# ntfy_targets to the interface contract (folding, order, dedup, the empty
# cases). The integration half runs a real run-task.sh against a fabricated
# repo with fake claude / codex / npx / curl binaries — the
# tests/review-fallback.test.sh pattern — where the fake curl records one
# line per push, URL first. An adhoc ticket id means no Linear call, so every
# line in that log is a phone push; a reviewer that rejects means the run ends
# terminal without ever touching a PR. Nothing here reaches a network, and
# every write lands in the sandbox.
#
# Usage: bash tests/notify.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/notify-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# shellcheck source=../lib/notify.sh
. "$SRC/lib/notify.sh"

# ---------------------------------------------------------------------------
echo "== ntfy_owner_key: login -> env-var suffix =="
# ---------------------------------------------------------------------------
check "key: a plain login uppercases"        "$(ntfy_owner_key ran)"       "RAN"
check "key: a dot becomes an underscore"     "$(ntfy_owner_key angel.sole)" "ANGEL_SOLE"
check "key: a dash becomes an underscore"    "$(ntfy_owner_key x-y)"       "X_Y"
check "key: digits survive"                  "$(ntfy_owner_key user1)"     "USER1"
check "key: already upper stays put"         "$(ntfy_owner_key ANGEL)"     "ANGEL"
check "key: an empty owner prints nothing"   "$(ntfy_owner_key "")"        ""
ntfy_owner_key ""
check "key: an empty owner still returns 0"  "$?" "0"

# ---------------------------------------------------------------------------
echo "== ntfy_targets: who gets the push =="
# ---------------------------------------------------------------------------
# Each case's knobs ride the call itself, so no assignment can outlive its
# assertion — and the suite cannot inherit a stray topic from the machine it
# runs on.
unset HARNESS_NTFY_TOPIC HARNESS_NTFY_TOPIC_ANGEL
check "targets: nothing configured prints nothing" "$(ntfy_targets angel)" ""
ntfy_targets angel
check "targets: nothing configured still returns 0" "$?" "0"

check "targets: an owner with no private topic is global only" \
  "$(HARNESS_NTFY_TOPIC=room-feed ntfy_targets angel)" "room-feed"
check "targets: an unowned run is global only" \
  "$(HARNESS_NTFY_TOPIC=room-feed ntfy_targets "")" "room-feed"

check "targets: a private topic set to empty counts as unset" \
  "$(HARNESS_NTFY_TOPIC_ANGEL='' HARNESS_NTFY_TOPIC=room-feed ntfy_targets angel)" \
  "room-feed"

check "targets: the owner's phone first, then the room feed" \
  "$(HARNESS_NTFY_TOPIC_ANGEL=angel-feed HARNESS_NTFY_TOPIC=room-feed ntfy_targets angel)" \
  "$(printf 'angel-feed\nroom-feed')"

check "targets: a private topic equal to the global collapses to one push" \
  "$(HARNESS_NTFY_TOPIC_ANGEL=room-feed HARNESS_NTFY_TOPIC=room-feed ntfy_targets angel)" \
  "room-feed"

check "targets: no global configured means the owner's phone only" \
  "$(HARNESS_NTFY_TOPIC_ANGEL=angel-feed ntfy_targets angel)" "angel-feed"

# --- fixture: a repo, a harness dir, fake workers, a recording curl ----------
FHOME="$ROOT/home"; FAKES="$ROOT/bin"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
NTFY_LOG="$ROOT/ntfy.log"
CCUSAGE_JSON="$ROOT/ccusage.json"
mkdir -p "$FHOME" "$FAKES" "$RUNS"
: > "$NTFY_LOG"
printf '{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000}},
  {"id":"b2","isActive":true,"isGap":false,"tokenCounts":{"outputTokens":10000}}
]}\n' > "$CCUSAGE_JSON"

cp "$SRC/repos.conf.sh" "$SRC/worker-settings.json" "$HARNESS/"
# repos.conf.sh reads the shared helpers from beside itself, the layout
# install.sh produces.
cp -R "$SRC/lib" "$HARNESS/lib"

BARE="$ROOT/origin.git"
REPO="$ROOT/notifyapp"
git init -q --bare "$BARE"
git clone -q "$BARE" "$REPO" 2>/dev/null
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git -C "$REPO" push -q -u origin main

cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
# Implementer stand-in: emits a stream-json event, commits, returns success.
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"fixture.txt"}}]}}\n'
date > fixture.txt
git add fixture.txt
git commit -q -m "feat: fixture change"
printf '{"type":"result","subtype":"success","session_id":"11111111-2222-3333-4444-555555555555"}\n'
SH
cat > "$FAKES/codex" <<'SH'
#!/usr/bin/env bash
# Reviewer stand-in: rejecting ends the run before the push/PR stage.
wt=""; prev=""
for a in "$@"; do
  [ "$prev" = "-C" ] && wt="$a"
  prev="$a"
done
printf 'fixture stop\n' > "$wt/.harness/REJECTED.md"
SH
cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
# ccusage stand-in: always healthy — capacity is another suite's job.
cat "$CCUSAGE_JSON"
EOF
cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
# ntfy push stand-in. One line per push, the URL first, so an assertion can
# demand the exact <server>/<topic> and see that nothing else was reached;
# the body's newlines fold to spaces so one push is one line.
url=""
for a in "\$@"; do case "\$a" in http*://*) url="\$a" ;; esac; done
{
  printf '%s ' "\$url"
  for a in "\$@"; do printf '%s ' "\$(printf '%s' "\$a" | tr '\n' ' ')"; done
  printf '\n'
} >> "$NTFY_LOG"
EOF
chmod +x "$FAKES/claude" "$FAKES/codex" "$FAKES/npx" "$FAKES/curl"

# The topic values under test. A dotted server hostname would make every URL
# a regex wildcard, so the fixture server has no dots.
SRV="https://ntfy-fixture"
ROOM="r00m-f33d-4a7c"
OWNED="0wn3rs-ph0ne-9f2d"

# The number of stage() calls a fixture made. stages.log also carries one
# "<epoch> __invocation__" marker per dispatch (run-task.sh's own resume
# bookkeeping, written without a push), so those lines are not stages.
stage_count() { grep -c -v '__invocation__' "$1" 2>/dev/null | tr -d ' '; }

RUN=""
dispatch() {  # $1 = ticket, $2 = VAR=VAL overrides (may be empty)
  local ticket="$1"
  RUN="$RUNS/$ticket"
  mkdir -p "$RUN"
  printf '# fixture task\n' > "$RUN/brief.md"
  : > "$NTFY_LOG"
  # The -u list is the hand-run safety net; the gate already clears these for
  # a suite it runs. Overrides come after, so a case that wants one of these
  # knobs still gets it.
  # shellcheck disable=SC2086
  env -u HARNESS_OWNER -u HARNESS_NTFY_TOPIC -u HARNESS_MIRROR \
      -u IMPLEMENTER_PROVIDER -u IMPLEMENTER_MODEL -u IMPLEMENTER_EFFORT \
      HOME="$FHOME" HARNESS_DIR="$HARNESS" PATH="$FAKES:$PATH" \
      CLAUDE_BIN="$FAKES/claude" CODEX_BIN="$FAKES/codex" \
      HARNESS_REVIEW_NETWORK=0 HARNESS_NOTIFY=0 \
      $2 \
      bash "$SRC/run-task.sh" "$ticket" "$REPO" "fix/$ticket" \
      > "$ROOT/run-$ticket.log" 2>&1 || true
}

# ---------------------------------------------------------------------------
echo "== global topic only: one push per stage, the exact URL, nothing else =="
# This is the byte-identical-to-before shape: no per-owner topic exists, so
# the owner machinery must change nothing about what the room feed receives.
# ---------------------------------------------------------------------------
T=adhoc-notify-room
dispatch "$T" "HARNESS_NTFY_SERVER=$SRV HARNESS_NTFY_TOPIC=$ROOM"
STAGES=$(stage_count "$RUNS/$T/stages.log")
check "room: the run reaches a terminal state" "$(jq -r .status "$RUNS/$T/result.json" 2>/dev/null)" "rejected"
check "room: the run dispatched unowned" "$(cat "$RUNS/$T/owner")" ""
check "room: exactly one push per stage handoff (not more, not fewer)" \
  "$(grep -c '' "$NTFY_LOG" | tr -d ' ')" "$STAGES"
check "room: every push hits exactly <server>/<topic>" \
  "$(grep -c "^$SRV/$ROOM " "$NTFY_LOG" | tr -d ' ')" "$STAGES"

echo "== no topic at all: the run completes and pushes nothing =="
T=adhoc-notify-silent
dispatch "$T" ""
check "silent: the run still reaches its terminal state" \
  "$(jq -r .status "$RUNS/$T/result.json" 2>/dev/null)" "rejected"
check "silent: not one push was attempted" "$(grep -c '' "$NTFY_LOG" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== an owned run: the owner's phone and the room feed both hear it =="
# ---------------------------------------------------------------------------
T=adhoc-notify-owner
dispatch "$T" "HARNESS_OWNER=zed HARNESS_NTFY_SERVER=$SRV HARNESS_NTFY_TOPIC_ZED=$OWNED HARNESS_NTFY_TOPIC=$ROOM"
STAGES=$(stage_count "$RUNS/$T/stages.log")
check "owner: the run reaches the same terminal state" \
  "$(jq -r .status "$RUNS/$T/result.json" 2>/dev/null)" "rejected"
check "owner: the run pins zed as its owner" "$(cat "$RUNS/$T/owner")" "zed"
check "owner: the owner's topic gets one push per stage" \
  "$(grep -cF "$SRV/$OWNED " "$NTFY_LOG" | tr -d ' ')" "$STAGES"
check "owner: and so does the room feed" \
  "$(grep -cF "$SRV/$ROOM " "$NTFY_LOG" | tr -d ' ')" "$STAGES"
check "owner: nothing beyond those two targets" \
  "$(grep -c '' "$NTFY_LOG" | tr -d ' ')" "$((2 * STAGES))"
check "owner: the owner's push is first in every pair" \
  "$(awk 'NR%2==1' "$NTFY_LOG" | grep -cF "$SRV/$OWNED " | tr -d ' ')" "$STAGES"
check "owner: the room push is always second" \
  "$(awk 'NR%2==0' "$NTFY_LOG" | grep -cF "$SRV/$ROOM " | tr -d ' ')" "$STAGES"
# stage() builds one body and one header set, then sends them to each target:
# strip the leading URL from every line and each pair must match exactly.
if awk 'BEGIN{bad=0} NR%2==1{sub(/^[^ ]+ /,"");last=$0;next} {sub(/^[^ ]+ /,"")} $0!=last{bad=1} END{exit bad}' "$NTFY_LOG"; then
  ok "owner: each stage's two pushes are identical beyond the topic"
else
  bad "owner: a stage's two pushes differ beyond the topic"
fi

# ---------------------------------------------------------------------------
echo "== a topic value never reaches stdout or the run dir =="
# ---------------------------------------------------------------------------
# The captured stdout lives outside the run dir (a foreground fixture never
# writes dispatch.log), so both places are grepped directly.
if grep -rF "$ROOM" "$RUNS/adhoc-notify-room" "$ROOT/run-adhoc-notify-room.log" >/dev/null 2>&1; then
  bad "secret: the room topic leaked from the global-only run"
else
  ok "secret: the room topic appears in neither stdout nor the run dir"
fi
if grep -rF -e "$ROOM" -e "$OWNED" "$RUNS/adhoc-notify-owner" "$ROOT/run-adhoc-notify-owner.log" >/dev/null 2>&1; then
  bad "secret: a topic value leaked from the owned run"
else
  ok "secret: neither topic appears in stdout or the run dir"
fi

echo
printf 'notify: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
