#!/usr/bin/env bash
# The quartermaster contract: at 19:00 it reads the overnight queue out of
# Linear, estimates what each crew station has left from that station's own
# local Claude logs, decides how many runs fit, and either reports the plan or
# arms it through schedule.sh — idempotently, and without ever touching a model
# provider.
#
# Nothing real is contacted. `npx` (ccusage), `curl` (Linear + ntfy), `uname`
# and `launchctl` are fake binaries on PATH that answer from canned files and
# record what they were asked to do — the technique tests/schedule.test.sh uses
# — and schedule.sh itself is a stand-in beside the script under test, so the
# arming path is asserted argument by argument and variable by variable.
#
# Usage: bash tests/quartermaster.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/quartermaster-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 ($2 is missing)"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 is still there)"; else ok "$1"; fi; }
has()      { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }
file_has() { if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing [$2] in $1)"; fi; }

# --- fixture -----------------------------------------------------------------
FHOME="$ROOT/home"; AGENTS="$FHOME/Library/LaunchAgents"
HARNESS="$ROOT/harness"; RUNS="$HARNESS/runs"
ACCOUNTS="$ROOT/accounts"
SRCDIR="$ROOT/src"; FAKES="$ROOT/bin"
KEYFILE="$HARNESS/linear-api-key"
SCHED_CALLS="$ROOT/schedule-calls.log"
SCHED_LIST="$ROOT/schedule-list.txt"
CURL_LOG="$ROOT/curl.log"
COMMENTS="$ROOT/linear-comments.log"
NTFY_LOG="$ROOT/ntfy.log"
NPX_LOG="$ROOT/npx.log"
LC_LOG="$ROOT/launchctl.log"
LINEAR_JSON="$ROOT/linear.json"
LINEAR_FAIL="$ROOT/linear-fail"
UNAME_STATE="$ROOT/fake-uname"
CCUSAGE_DIR="$ROOT/ccusage"

mkdir -p "$AGENTS" "$RUNS" "$SRCDIR" "$FAKES" "$CCUSAGE_DIR" \
  "$ACCOUNTS/angel/claude" "$ACCOUNTS/angel/codex" "$ACCOUNTS/angel/gh" \
  "$ACCOUNTS/bea/claude"
: > "$SCHED_CALLS"; : > "$SCHED_LIST"; : > "$CURL_LOG"; : > "$COMMENTS"
: > "$NTFY_LOG"; : > "$NPX_LOG"; : > "$LC_LOG"
printf 'Darwin\n' > "$UNAME_STATE"
printf 'lin_api_TESTKEY\n' > "$KEYFILE"; chmod 600 "$KEYFILE"
printf 'HARNESS_NTFY_TOPIC="qm-test-topic"\n' > "$HARNESS/notify.conf"

cp "$SRC/quartermaster.sh" "$SRCDIR/quartermaster.sh"
chmod +x "$SRCDIR/quartermaster.sh"

git init -q "$ROOT/greenapp" >/dev/null 2>&1
REPO="$(cd "$ROOT/greenapp" && pwd)"

# --- fakes -------------------------------------------------------------------
# The scheduler stand-in: records its argv and the identity it was handed, then
# leaves the real marker behind so idempotency across reruns is genuine state,
# not a flag this suite invented.
cat > "$SRCDIR/schedule.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = --list ]; then cat "$SCHED_LIST"; exit 0; fi
{
  printf 'argv:%s\n'       "\$*"
  printf 'owner:%s\n'      "\${HARNESS_OWNER-<unset>}"
  printf 'claude:%s\n'     "\${CLAUDE_CONFIG_DIR-<unset>}"
  printf 'codex:%s\n'      "\${CODEX_HOME-<unset>}"
  printf 'gh:%s\n'         "\${GH_CONFIG_DIR-<unset>}"
  printf 'ghtoken:%s\n'    "\${GH_TOKEN-<unset>}"
  printf 'effort:%s\n'     "\${IMPLEMENTER_EFFORT-<unset>}"
  printf 'harnessdir:%s\n' "\${HARNESS_DIR-<unset>}"
} >> "$SCHED_CALLS"
if [ "\$1" = REFUSE-ME ]; then echo "[schedule] no such repo directory: \$2" >&2; exit 1; fi
mkdir -p "$RUNS/\$1"
date +%s > "$RUNS/\$1/scheduled"
echo "[schedule] \$1 armed for \$4"
EOF

# ccusage stand-in. Answers only from a canned file chosen by the station whose
# CLAUDE_CONFIG_DIR it was handed — which is also the assertion that capacity
# accounting is per-station and local-file only.
cat > "$FAKES/npx" <<EOF
#!/usr/bin/env bash
printf '%s | CLAUDE_CONFIG_DIR=%s\n' "\$*" "\${CLAUDE_CONFIG_DIR-<unset>}" >> "$NPX_LOG"
station=\$(basename "\$(dirname "\${CLAUDE_CONFIG_DIR:-/nowhere/none}")")
f="$CCUSAGE_DIR/\$station.json"
[ -f "\$f" ] || { echo "ccusage: no usage data" >&2; exit 1; }
cat "\$f"
EOF

cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*://*) url="\$a" ;; esac; done
printf 'curl %s\n' "\$*" >> "$CURL_LOG"
case "\$url" in
  *api.linear.app*)
    body=\$(cat)
    [ -f "$LINEAR_FAIL" ] && exit 7
    case "\$body" in
      *commentCreate*)
        printf '%s\n' "\$body" >> "$COMMENTS"
        printf '{"data":{"commentCreate":{"success":true}}}\n' ;;
      *) cat "$LINEAR_JSON" ;;
    esac ;;
  *ntfy*)
    printf '%s\n' "\$*" >> "$NTFY_LOG" ;;
  *)
    printf 'UNEXPECTED %s\n' "\$url" >> "$CURL_LOG"; exit 1 ;;
esac
EOF

cat > "$FAKES/uname" <<EOF
#!/usr/bin/env bash
cat "$UNAME_STATE"
EOF

cat > "$FAKES/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LC_LOG"
EOF

chmod +x "$SRCDIR/schedule.sh" "$FAKES/npx" "$FAKES/curl" "$FAKES/uname" "$FAKES/launchctl"

# --- canned data -------------------------------------------------------------
# One completed block at 400k output tokens is the ceiling; the active block has
# spent 100k of it; the gap block must be ignored entirely.
cat > "$CCUSAGE_DIR/angel.json" <<'EOF'
{"blocks":[
  {"id":"b1","isActive":false,"isGap":false,"tokenCounts":{"outputTokens":400000,"inputTokens":9}},
  {"id":"b2","isActive":false,"isGap":true,"tokenCounts":{"outputTokens":9999999}},
  {"id":"b3","isActive":true,"isGap":false,"tokenCounts":{"outputTokens":100000,"inputTokens":9}}
]}
EOF
# bea has no canned file at all: ccusage fails for that station, on purpose.

issue() {  # $1 id, $2 identifier, $3 title, $4 priority, $5 email, $6 state type
  printf '{"id":"%s","identifier":"%s","title":"%s","priority":%s,"createdAt":"2026-08-0%s",' \
    "$1" "$2" "$3" "$4" "1"
  printf '"assignee":{"email":"%s"},"state":{"type":"%s"}}' "$5" "$6"
}
{
  printf '{"data":{"issues":{"nodes":['
  issue id-a1 OLYX-A1 "Fix the boiler"      1 angel.sole@olyx.nl backlog;   printf ','
  issue id-a2 OLYX-A2 "Paint the hull"      2 angel.sole@olyx.nl unstarted; printf ','
  issue id-a3 OLYX-A3 "Sweep the deck"      3 Angel.Sole@olyx.nl backlog;   printf ','
  issue id-a4 OLYX-A4 "Nobody wrote it"     4 angel.sole@olyx.nl backlog;   printf ','
  issue id-a6 OLYX-A6 "Underway already"    0 angel.sole@olyx.nl backlog;   printf ','
  issue id-a7 OLYX-A7 "Shipped last night"  0 angel.sole@olyx.nl backlog;   printf ','
  issue id-a8 OLYX-A8 "Armed elsewhere"     0 angel.sole@olyx.nl backlog;   printf ','
  issue id-a9 OLYX-A9 "Headerless brief"    0 angel.sole@olyx.nl backlog;   printf ','
  issue id-b1 OLYX-B1 "Bea's overnight"     1 bea.torres@olyx.nl backlog;   printf ','
  issue id-z1 OLYX-Z1 "Nobody's station"    1 sam.jones@olyx.nl  backlog
  printf ']}}}\n'
} > "$LINEAR_JSON"

brief_for() {  # $1 = ticket, $2 = branch ('' writes a brief with no headers)
  mkdir -p "$RUNS/$1"
  if [ -z "$2" ]; then
    printf '# a brief the planner never finished\n\nNo header lines here.\n' > "$RUNS/$1/brief.md"
  else
    { printf '# %s\n\n' "$1"
      printf -- '- **Ticket**: %s\n' "$1"
      printf -- '- **Repo**: %s\n' "$REPO"
      printf -- '- **Branch**: %s\n' "$2"
      printf -- '- **Base**: main\n'
    } > "$RUNS/$1/brief.md"
  fi
}
brief_for OLYX-A1 fix/a1
brief_for OLYX-A2 fix/a2
brief_for OLYX-A3 fix/a3
brief_for OLYX-A6 fix/a6
brief_for OLYX-A7 fix/a7
brief_for OLYX-A8 fix/a8
brief_for OLYX-A9 ''
brief_for OLYX-B1 fix/b1
# OLYX-A4 deliberately has no brief at all.

# Already running: a status line whose stage is not `done:`.
printf '%s implement: worker\n' "$(date +%s)" > "$RUNS/OLYX-A6/status"
# Already delivered: a result.json carrying a PR url.
printf '{"pr_url":"https://github.com/olyx/app/pull/7","status":"delivered"}\n' \
  > "$RUNS/OLYX-A7/result.json"
# A schedule only `schedule.sh --list` knows about — no marker on disk. Parked
# until its own scenario below, so the baseline queue stays readable.
LIST_ROW="TICKET                   FIRES                WHEN
OLYX-A8                  Fri 07 Aug 23:30     in 4h30m"

# Run history for the median: three finished runs at 40k / 50k / 60k output
# tokens. The median is 50000 and nothing else in the fixture carries usage.
hist() {
  mkdir -p "$RUNS/$1"
  printf '{"status":"delivered","metrics":{"implementer_usage":{"output_tokens":%s}}}\n' \
    "$2" > "$RUNS/$1/result.json"
}
hist HIST-1 40000
hist HIST-2 60000
hist HIST-3 50000

TODAY=$(date '+%Y-%m-%d')
REPORT="$RUNS/quartermaster/$TODAY.md"

qm() {  # $1 = space-separated VAR=VAL overrides (may be empty), rest = argv
  local overrides="$1"; shift
  # shellcheck disable=SC2086
  env HOME="$FHOME" HARNESS_DIR="$HARNESS" QM_ACCOUNTS_DIR="$ACCOUNTS" \
      LINEAR_API_KEY_FILE="$KEYFILE" PATH="$FAKES:$PATH" GH_TOKEN=leak-me-not \
      $overrides bash "$SRCDIR/quartermaster.sh" "$@" 2>&1
}
section() {  # $1 = station: that station's slice of the report
  awk -v s="## $1" '$0 == s {f = 1; next} /^## /{f = 0} f' "$REPORT"
}
markers() {
  local m n=0
  for m in "$RUNS"/*/scheduled; do [ -f "$m" ] && n=$((n + 1)); done
  printf '%s' "$n"
}
arm_calls() { grep -c '^argv:' "$SCHED_CALLS" 2>/dev/null | tr -d ' '; }

# ---------------------------------------------------------------------------
echo "== guards =="
# ---------------------------------------------------------------------------
out=$(qm "" --nonsense); rc=$?
check "guard: an unknown option exits 2" "$rc" "2"
has "$out" "quartermaster.sh --arm" "guard: an unknown option prints the usage"

out=$(qm "" --arm extra); rc=$?
check "guard: a stray argument exits 2" "$rc" "2"

out=$(qm "" --install --tomorrow); rc=$?
check "guard: --install rejects an unknown mode" "$rc" "2"
has "$out" "--install takes --report or --arm" "guard: --install names the modes it takes"
check "guard: no run was armed by any guard" "$(arm_calls)" "0"

# ---------------------------------------------------------------------------
echo "== --report: the plan, and nothing else =="
# ---------------------------------------------------------------------------
out=$(qm "" --report); rc=$?
check "report: exits 0" "$rc" "0"
exists "report: writes the dated report" "$REPORT"
has "$out" "report: $REPORT" "report: says where the report went"

check "report: armed nothing" "$(arm_calls)" "0"
check "report: left no schedule markers" "$(markers)" "0"
absent "report: wrote no LaunchAgent" "$AGENTS/com.olyx.quartermaster.plist"
check "report: posted no Linear comment" "$(grep -c '' < "$COMMENTS" | tr -d ' ')" "0"

file_has "$REPORT" "# Quartermaster — $TODAY"           "report: is titled with tonight's date"
file_has "$REPORT" "Mode: **report**"                    "report: names its own mode"
file_has "$REPORT" "Queue: 10 tagged issue(s)"           "report: counts the tagged queue"
file_has "$REPORT" "Run cost: median 50000 implementer output tokens over 3 sampled run(s)." \
  "report: takes the median implementer output tokens over the run history"
file_has "$REPORT" "no model provider was contacted"     "report: states the local-only rule"

ANGEL=$(section angel)
has "$ANGEL" "~75% of the block's output budget left (300000 of 400000 tokens; 100000 spent)" \
  "capacity: remaining is the completed-block ceiling minus the active block"
has "$ANGEL" "Room for: 3 run(s) at 50000 tokens each (safety 0.5, cap 3)" \
  "capacity: N = floor(remaining x safety / median cost)"
has "$ANGEL" "### Would arm"                    "report: labels the plan as hypothetical"
has "$ANGEL" "**23:30** \`OLYX-A1\`"            "queue: the top priority takes the first fire time"
has "$ANGEL" "**02:00** \`OLYX-A2\`"            "queue: the second takes the second fire time"
has "$ANGEL" "**04:30** \`OLYX-A3\`"            "queue: the third takes the third fire time"
has "$ANGEL" "$REPO (fix/a1)"                   "brief: the repo and branch come from the brief header"
has "$ANGEL" "### Needs a brief"                "report: has a needs-a-brief section"
has "$ANGEL" "\`OLYX-A4\` Nobody wrote it"      "eligibility: a tagged ticket with no brief is never armed"
has "$ANGEL" "### Skipped"                      "report: has a skipped section"
has "$ANGEL" "already running (implement: worker)" "eligibility: a live run is skipped, with its stage"
has "$ANGEL" "already delivered (https://github.com/olyx/app/pull/7)" \
  "eligibility: a delivered run is skipped, with its PR"
has "$ANGEL" "the brief has no **Repo** / **Branch** header line" \
  "brief: a headerless brief is skipped rather than guessed at"
has "$ANGEL" "### Beyond tonight's capacity" \
  "capacity: briefed work past N is listed rather than dropped"
has_not "$ANGEL" "OLYX-B1"                      "crew: angel's section holds none of bea's work"

BEA=$(section bea)
has "$BEA" "Capacity: **unknown**"              "capacity: a station ccusage cannot account for says so"
has "$BEA" "Room for: 1 run(s) — the conservative QM_FALLBACK_N default" \
  "capacity: an unusable estimate falls back to QM_FALLBACK_N"
has "$BEA" "**23:30** \`OLYX-B1\`"              "crew: bea's own queue gets bea's first fire time"

UNKNOWN=$(section "Unknown stations")
has "$UNKNOWN" "OLYX-Z1"                        "mapping: a ticket with no station on this machine is reported"
has "$UNKNOWN" "sam.jones@olyx.nl maps to \`sam\`" \
  "mapping: the local part up to the first dot is the station name"

# ---------------------------------------------------------------------------
echo "== the report reaches the phone =="
# ---------------------------------------------------------------------------
file_has "$NTFY_LOG" "Title: quartermaster $TODAY (report)" "ntfy: one push, titled with the date and mode"
file_has "$NTFY_LOG" "qm-test-topic"                        "ntfy: uses the topic from notify.conf"
file_has "$NTFY_LOG" "angel · ~75% left · 3 fit · would arm OLYX-A1 23:30" \
  "ntfy: the summary carries capacity, N and the plan per crew member"
file_has "$NTFY_LOG" "1 need a brief"                       "ntfy: the summary counts what needs a brief"
file_has "$NTFY_LOG" "median 50000 tok/run"                 "ntfy: the summary carries the run cost"

mv "$HARNESS/notify.conf" "$ROOT/notify.conf.parked"
out=$(qm "" --report)
has "$out" "no HARNESS_NTFY_TOPIC in notify.conf — report file only" \
  "ntfy: no topic configured degrades to the report file"
mv "$ROOT/notify.conf.parked" "$HARNESS/notify.conf"

# ---------------------------------------------------------------------------
echo "== a schedule that is already armed =="
# ---------------------------------------------------------------------------
printf '%s\n' "$LIST_ROW" > "$SCHED_LIST"
qm "" --report >/dev/null
ANGEL=$(section angel)
has "$ANGEL" "already armed (schedule.sh --list)" \
  "eligibility: a schedule only --list knows about still counts as armed"
has "$ANGEL" "**02:00** \`OLYX-A1\`" \
  "capacity: the fire time an existing schedule holds is not handed out twice"
has "$ANGEL" "Room for: 3 run(s)" \
  "capacity: an existing schedule spends a slot without changing N"
: > "$SCHED_LIST"

# ---------------------------------------------------------------------------
echo "== the knobs =="
# ---------------------------------------------------------------------------
qm "QM_MAX_PER_CREW=2" --report >/dev/null
has "$(section angel)" "Room for: 2 run(s)" "knobs: QM_MAX_PER_CREW caps N"

qm "QM_SAFETY=0.1" --report >/dev/null
ANGEL=$(section angel)
has "$ANGEL" "Room for: 0 run(s)"              "knobs: QM_SAFETY scales N down"
has "$ANGEL" "### Beyond tonight's capacity"   "knobs: work that does not fit is listed, not dropped"
has_not "$ANGEL" "### Would arm"               "knobs: with no room, nothing is planned"

qm "QM_FALLBACK_N=2" --report >/dev/null
has "$(section bea)" "Room for: 2 run(s) — the conservative" "knobs: QM_FALLBACK_N sets the unknown-capacity default"

qm "QM_TOKEN_LIMIT=1000000" --report >/dev/null
has "$(section angel)" "(900000 of 1000000 tokens" "knobs: QM_TOKEN_LIMIT pins the ceiling ccusage would guess"

qm "QM_TIMES=05:00" --report >/dev/null
ANGEL=$(section angel)
has "$ANGEL" "**05:00** \`OLYX-A1\`"           "knobs: QM_TIMES sets the fire times"
has "$ANGEL" "### Beyond tonight's capacity"   "knobs: running out of fire times caps the plan"

qm "QM_PAGE=2" --report >/dev/null
file_has "$REPORT" "Linear returned a full page of 2 — there may be more waiting than this." \
  "queue: a queue longer than one page is said out loud, not silently truncated"
qm "" --report >/dev/null
has_not "$(cat "$REPORT")" "there may be more waiting" \
  "queue: a queue that fits in one page says nothing about truncation"

# ---------------------------------------------------------------------------
echo "== degrading without a queue =="
# ---------------------------------------------------------------------------
out=$(qm "LINEAR_API_KEY_FILE=$ROOT/no-such-key" --report); rc=$?
check "degrade: a missing API key still exits 0" "$rc" "0"
file_has "$REPORT" "Queue: **unavailable** — no readable Linear API key at $ROOT/no-such-key" \
  "degrade: the report says the key is missing rather than pretending the queue is empty"
file_has "$REPORT" "## angel" "degrade: capacity is still reported without a queue"

: > "$LINEAR_FAIL"
out=$(qm "" --report); rc=$?
check "degrade: an unreachable Linear still exits 0" "$rc" "0"
file_has "$REPORT" "Queue: **unavailable** — Linear did not answer" \
  "degrade: a transport failure is named in the report"
rm -f "$LINEAR_FAIL"

out=$(qm "QM_ACCOUNTS_DIR=$ROOT/no-such-crew" --report); rc=$?
check "degrade: no crew directory still exits 0" "$rc" "0"
file_has "$REPORT" "there is nobody to dispatch for" "degrade: an empty crew is stated plainly"

check "degrade: nothing was armed through any of that" "$(arm_calls)" "0"
check "degrade: no markers appeared" "$(markers)" "0"

# ---------------------------------------------------------------------------
echo "== --arm: hands the plan to schedule.sh =="
# ---------------------------------------------------------------------------
: > "$NTFY_LOG"
out=$(qm "" --arm); rc=$?
check "arm: exits 0" "$rc" "0"
check "arm: armed exactly the four runs that fit" "$(arm_calls)" "4"
file_has "$SCHED_CALLS" "argv:OLYX-A1 $REPO fix/a1 23:30" "arm: ticket, repo, branch and time reach schedule.sh"
file_has "$SCHED_CALLS" "argv:OLYX-A2 $REPO fix/a2 02:00" "arm: the second run takes the second fire time"
file_has "$SCHED_CALLS" "argv:OLYX-A3 $REPO fix/a3 04:30" "arm: the third run takes the third fire time"
file_has "$SCHED_CALLS" "argv:OLYX-B1 $REPO fix/b1 23:30" "arm: each crew member's times start again at the first slot"
file_has "$SCHED_CALLS" "owner:angel"                     "arm: HARNESS_OWNER is the station"
file_has "$SCHED_CALLS" "claude:$ACCOUNTS/angel/claude"   "arm: CLAUDE_CONFIG_DIR is the station's"
file_has "$SCHED_CALLS" "codex:$ACCOUNTS/angel/codex"     "arm: CODEX_HOME is the station's"
file_has "$SCHED_CALLS" "gh:$ACCOUNTS/angel/gh"           "arm: GH_CONFIG_DIR is the station's"
file_has "$SCHED_CALLS" "owner:bea"                       "arm: bea's runs go out under bea's identity"
file_has "$SCHED_CALLS" "claude:$ACCOUNTS/bea/claude"     "arm: bea's runs carry bea's Claude config"
file_has "$SCHED_CALLS" "effort:high"                     "arm: IMPLEMENTER_EFFORT is pinned high"
file_has "$SCHED_CALLS" "harnessdir:$HARNESS"             "arm: the harness dir travels with the schedule"
if grep -q '^ghtoken:leak-me-not' "$SCHED_CALLS"; then
  bad "arm: a global GH_TOKEN must not override the station's gh config"
else
  ok "arm: a global GH_TOKEN never overrides the station's gh config"
fi

file_has "$REPORT" "Mode: **arm**"                        "arm: the report names the mode it ran in"
has "$(section angel)" "### Armed"                        "arm: the report labels what it actually did"
check "arm: commented on every armed issue" "$(grep -c 'commentCreate' "$COMMENTS" | tr -d ' ')" "4"
file_has "$COMMENTS" "id-a1"                              "arm: the comment goes to the Linear issue id"
file_has "$COMMENTS" "Armed for 23:30 by the quartermaster" "arm: the comment says when it was armed"
file_has "$NTFY_LOG" "armed OLYX-A1 23:30"                "arm: the push reports what was armed"

# ---------------------------------------------------------------------------
echo "== idempotence: the same evening, twice =="
# ---------------------------------------------------------------------------
before=$(arm_calls)
out=$(qm "" --arm); rc=$?
check "rerun: exits 0" "$rc" "0"
check "rerun: armed nothing a second time" "$(arm_calls)" "$before"
ANGEL=$(section angel)
has "$ANGEL" "already armed for"  "rerun: the armed tickets are skipped, with their fire time"
has "$ANGEL" "### Beyond tonight's capacity" \
  "rerun: the slots already spent are counted against N"
has_not "$ANGEL" "### Armed"      "rerun: nothing new is claimed for angel"
has "$(section bea)" "### Nothing to arm" "rerun: a crew member with a full plan has nothing left"
check "rerun: posted no further comments" "$(grep -c 'commentCreate' "$COMMENTS" | tr -d ' ')" "4"

# ---------------------------------------------------------------------------
echo "== schedule.sh refusing an arm =="
# ---------------------------------------------------------------------------
brief_for REFUSE-ME fix/refuse
printf '{"data":{"issues":{"nodes":[%s]}}}\n' \
  "$(issue id-r1 REFUSE-ME 'Doomed' 1 angel.sole@olyx.nl backlog)" > "$LINEAR_JSON"
out=$(qm "" --arm); rc=$?
check "refusal: a schedule.sh failure still exits 0" "$rc" "0"
file_has "$REPORT" "**schedule.sh refused**" "refusal: the report says the arm did not take"
absent "refusal: no marker was left behind" "$RUNS/REFUSE-ME/scheduled"

# ---------------------------------------------------------------------------
echo "== the hard rule: no model provider, ever =="
# ---------------------------------------------------------------------------
has_not "$(cat "$CURL_LOG")" "anthropic" "hard rule: no Anthropic endpoint was contacted"
has_not "$(cat "$CURL_LOG")" "openai"    "hard rule: no OpenAI endpoint was contacted"
if grep -v -e 'api\.linear\.app' -e 'ntfy' "$CURL_LOG" | grep -q 'http'; then
  bad "hard rule: curl reached a host other than Linear and ntfy"
else
  ok "hard rule: curl only ever reached Linear and ntfy"
fi
file_has "$NPX_LOG" "ccusage@latest blocks --json --offline" \
  "hard rule: ccusage is asked for local blocks, offline"
if grep -v 'ccusage' "$NPX_LOG" | grep -q '[^[:space:]]'; then
  bad "hard rule: npx was used for something other than ccusage"
else
  ok "hard rule: npx is only ever used for ccusage"
fi
has_not "$(cat "$REPORT")" "lin_api_TESTKEY" "secrets: the API key never lands in the report"
has_not "$(cat "$NTFY_LOG")" "lin_api_TESTKEY" "secrets: the API key never lands in the push"

# ---------------------------------------------------------------------------
echo "== --install / --uninstall: the daily 19:00 agent =="
# ---------------------------------------------------------------------------
PLIST="$AGENTS/com.olyx.quartermaster.plist"
WRAPPER="$RUNS/quartermaster/quartermaster-agent.sh"

printf 'Linux\n' > "$UNAME_STATE"
out=$(qm "" --install); rc=$?
check "install: refuses to arm launchd on a non-Mac" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
absent "install: nothing was written on a non-Mac" "$PLIST"
printf 'Darwin\n' > "$UNAME_STATE"

out=$(qm "" --install); rc=$?
check "install: exits 0" "$rc" "0"
exists "install: writes the plist" "$PLIST"
exists "install: writes the wrapper" "$WRAPPER"
check "install: the wrapper is mode 600 (it holds an env snapshot)" \
  "$(ls -l "$WRAPPER" | cut -c2-10)" "rw-------"
file_has "$PLIST" "<string>com.olyx.quartermaster</string>" "install: the label follows the harness convention"
file_has "$PLIST" "<key>Hour</key>"       "install: the agent is a calendar interval"
file_has "$PLIST" "<integer>19</integer>" "install: it fires at 19"
file_has "$PLIST" "<integer>0</integer>"  "install: on the hour"
file_has "$PLIST" "<string>--report</string>" \
  "install: the installed agent only reports — the plist argument is the trust dial"
file_has "$WRAPPER" "export HARNESS_DIR=" "install: the wrapper carries the harness dir launchd would not give it"
file_has "$WRAPPER" "export PATH="        "install: and the PATH"
has_not "$(cat "$WRAPPER")" "GH_TOKEN"    "install: no global token rides along to override a station"
file_has "$LC_LOG" "bootstrap gui/$(id -u) $PLIST" "install: the agent is loaded into launchd"
has "$out" "quartermaster.sh --install --arm" "install: says how to flip the dial to arming"

out=$(qm "" --install --arm); rc=$?
check "install: re-installing exits 0" "$rc" "0"
file_has "$PLIST" "<string>--arm</string>" "install: --install --arm flips the trust dial"
check "install: the old agent was booted out first" \
  "$(grep -c "^bootout gui/$(id -u)/com.olyx.quartermaster$" "$LC_LOG" | tr -d ' ')" "2"

out=$(qm "QM_AT=07:05" --install); rc=$?
check "install: QM_AT exits 0" "$rc" "0"
file_has "$PLIST" "<integer>7</integer>" "install: QM_AT moves the hour"
file_has "$PLIST" "<integer>5</integer>" "install: QM_AT moves the minute"

out=$(qm "QM_AT=teatime" --install); rc=$?
check "install: a bad QM_AT exits non-zero" "$([ $rc -ne 0 ] && echo yes || echo no)" "yes"
has "$out" "QM_AT must be HH:MM" "install: a bad QM_AT says what it wanted"

out=$(qm "" --uninstall); rc=$?
check "uninstall: exits 0" "$rc" "0"
absent "uninstall: the plist is gone" "$PLIST"
absent "uninstall: the wrapper is gone" "$WRAPPER"
exists "uninstall: the reports are kept" "$REPORT"

out=$(qm "" --uninstall)
has "$out" "nothing installed" "uninstall: a second removal is a no-op"

echo
printf 'quartermaster: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
