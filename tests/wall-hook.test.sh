#!/usr/bin/env bash
# lib/wall-hook.sh's contract with Claude Code and with the wall.
#
# The wrapper is forked once per tool call of every worker the harness runs, so
# its disabled path has to be free, and its enabled path has to be silent: the
# CLI parses hook stdout as JSON and treats exit 2 as a block on the tool. Both
# halves are asserted here against a fake `curl` on PATH — nothing is contacted.
#
# Usage: bash tests/wall-hook.test.sh
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/lib/wall-hook.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wall-hook-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
has()     { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing [$2])"; fi; }
has_not() { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (found [$2])"; else ok "$3"; fi; }

FAKES="$ROOT/bin"
CURL_LOG="$ROOT/curl.log"
BODY_FILE="$ROOT/curl-body.json"
mkdir -p "$FAKES"

# The fake curl records argv and the -d body, then exits with whatever
# CURL_EXIT says. The body lands outside any run dir on purpose: the point of
# several assertions below is what is NOT in it.
cat > "$FAKES/curl" <<EOF
#!/usr/bin/env bash
printf 'argv:%s\n' "\$*" >> "$CURL_LOG"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-d" ]; then printf '%s' "\$a" > "$BODY_FILE"; break; fi
  prev="\$a"
done
exit "\${CURL_EXIT:-0}"
EOF
chmod +x "$FAKES/curl"

EVENT='{"session_id":"sess-9","cwd":"/repo/greenapp-t1","prompt_id":"p-4",
  "permission_mode":"acceptEdits","hook_event_name":"PostToolUse",
  "transcript_path":"/home/x/.claude/projects/a/b.jsonl","tool_name":"Edit",
  "tool_input":{"file_path":"/repo/greenapp-t1/src/app.ts","command":"npm test",
                "description":"run the suite","secret_key":"NOT-FORWARDED"},
  "tool_response":"THE-WHOLE-FILE-CONTENTS-GO-HERE"}'

# $1 = label, rest = VAR=VALUE overrides. Runs the wrapper with the event on
# stdin and leaves OUT / RC / BODY behind; the background curl is waited for by
# polling the log, since the wrapper returns before it finishes.
run_hook() {
  : > "$CURL_LOG"; rm -f "$BODY_FILE"
  OUT=$(printf '%s' "$EVENT" | env PATH="$FAKES:$PATH" "$@" bash "$HOOK" 2>/dev/null)
  RC=$?
  local i=0
  while [ "$i" -lt 40 ] && [ ! -s "$CURL_LOG" ]; do sleep 0.05; i=$((i + 1)); done
  CALLS=$(grep -c '^argv:' "$CURL_LOG" 2>/dev/null | tr -d ' ')
  BODY=$(cat "$BODY_FILE" 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
echo "== the wall is not configured: the fork costs a fork =="
# ---------------------------------------------------------------------------
run_hook -u HARNESS_WALL_URL -u HARNESS_WALL_TOKEN -u HARNESS_RUN_ID
check "off: exits 0" "$RC" "0"
check "off: says nothing on stdout" "$OUT" ""
check "off: never runs curl" "$CALLS" "0"

# The other half of the guard: a station with the URL exported must not turn a
# worker the harness never launched into a run-less report.
run_hook HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID= -u HARNESS_WALL_TOKEN
check "off: an empty run id exits 0 even with a URL set" "$RC" "0"
check "off: and still never runs curl" "$CALLS" "0"
check "off: and still says nothing" "$OUT" ""

# ---------------------------------------------------------------------------
echo "== configured: one POST, and only the projected fields =="
# ---------------------------------------------------------------------------
run_hook HARNESS_WALL_URL=http://wall.invalid:4711 HARNESS_RUN_ID=T-1 \
         HARNESS_WALL_TOKEN=shhh
check "on: exits 0" "$RC" "0"
check "on: still says nothing on stdout" "$OUT" ""
check "on: exactly one POST" "$CALLS" "1"
CALL=$(cat "$CURL_LOG")
has "$CALL" "http://wall.invalid:4711/api/ingest/hook" "on: to the hook route"
has "$CALL" "Authorization: Bearer shhh" "on: carrying the shared token"
has "$CALL" "-m 2" "on: with a two-second ceiling"

check "body: the run id is the harness's, not the event's" \
  "$(printf '%s' "$BODY" | jq -r .run)" "T-1"
check "body: the event name survives" \
  "$(printf '%s' "$BODY" | jq -r .hook_event_name)" "PostToolUse"
check "body: so does the tool" "$(printf '%s' "$BODY" | jq -r .tool_name)" "Edit"
check "body: and the session" "$(printf '%s' "$BODY" | jq -r .session_id)" "sess-9"
check "body: at is an epoch" \
  "$(printf '%s' "$BODY" | jq -r '.at | (type == "number" and . > 1700000000)')" "true"
check "body: the host is named" \
  "$(printf '%s' "$BODY" | jq -r '.host | length > 0')" "true"
check "body: exactly the projected keys" \
  "$(printf '%s' "$BODY" | jq -r 'keys_unsorted | sort | join(",")')" \
  "at,cwd,hook_event_name,host,prompt_id,reason,run,session_id,tool_input,tool_name"
check "body: tool_input is only the three fields" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input | keys_unsorted | sort | join(",")')" \
  "command,description,file_path"
has_not "$BODY" "THE-WHOLE-FILE-CONTENTS" "body: tool_response is never forwarded"
has_not "$BODY" "NOT-FORWARDED" "body: nor any other tool_input key"
has_not "$BODY" "transcript_path" "body: nor the transcript path"
has_not "$BODY" "permission_mode" "body: nor the permission mode"

# ---------------------------------------------------------------------------
echo "== long strings are clipped, not sent =="
# ---------------------------------------------------------------------------
LONG=$(node -e 'process.stdout.write("x".repeat(900))' 2>/dev/null \
       || printf 'x%.0s' $(seq 1 900))
EVENT="{\"session_id\":\"s\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",
        \"tool_input\":{\"command\":\"$LONG\",\"file_path\":\"$LONG\",\"description\":\"$LONG\"}}"
run_hook HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID=T-2 -u HARNESS_WALL_TOKEN
check "clip: the command is capped at 200 characters" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input.command | length')" "200"
check "clip: and so is the file path" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input.file_path | length')" "200"
check "clip: and the description" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input.description | length')" "200"
check "clip: a token-less wall gets no Authorization header" \
  "$(grep -c 'Authorization' "$CURL_LOG" | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
echo "== nothing the wall does can reach the tool call =="
# ---------------------------------------------------------------------------
# exit 2 blocks the tool and any stdout is parsed as JSON, so a wall that is
# down, a hook payload that is not JSON, and a payload with no tool_input at all
# all have to end the same way: silence and 0.
EVENT='{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}'
run_hook HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID=T-3 CURL_EXIT=7
check "down: a refused connection still exits 0" "$RC" "0"
check "down: and still says nothing" "$OUT" ""
check "down: the POST was still attempted" "$CALLS" "1"
check "down: a Stop event carries no tool_input values" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input | to_entries | map(.value) | unique | join("")')" ""

EVENT='not json at all'
run_hook HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID=T-4
check "junk: an unparseable payload exits 0" "$RC" "0"
check "junk: and says nothing" "$OUT" ""
check "junk: and posts nothing" "$CALLS" "0"

EVENT='{"hook_event_name":"SessionEnd","reason":"clear","tool_input":"a string"}'
run_hook HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID=T-5
check "shape: a non-object tool_input exits 0" "$RC" "0"
check "shape: and still posts" "$CALLS" "1"
check "shape: with the SessionEnd reason" "$(printf '%s' "$BODY" | jq -r .reason)" "clear"
check "shape: and an empty tool_input projection" \
  "$(printf '%s' "$BODY" | jq -r '.tool_input.command')" ""

# A machine without jq or curl is a machine where this does nothing at all,
# rather than one where every tool call prints an error into the CLI's parser.
EVENT='{"session_id":"s","hook_event_name":"Stop"}'
: > "$CURL_LOG"
OUT=$(printf '%s' "$EVENT" | env PATH="$ROOT/empty-path" \
  HARNESS_WALL_URL=http://wall.invalid HARNESS_RUN_ID=T-6 bash "$HOOK" 2>/dev/null)
RC=$?
check "deps: no jq and no curl on PATH exits 0" "$RC" "0"
check "deps: silently" "$OUT" ""

# ---------------------------------------------------------------------------
echo "== worker-settings.json wires it, and changes nothing else =="
# ---------------------------------------------------------------------------
WS="$SRC/worker-settings.json"
if jq -e . "$WS" >/dev/null 2>&1; then ok "settings: it is valid JSON"; else bad "settings: it is valid JSON"; fi
check "settings: three hook events, and only those" \
  "$(jq -r '.hooks | keys_unsorted | sort | join(",")' "$WS")" \
  "PostToolUse,SessionEnd,Stop"
# SessionStart is deliberately absent: measured against `claude -p --settings`,
# it does not fire from a settings file, and the run's own first stage report is
# the "started" signal anyway.
check "settings: no SessionStart hook is claimed" \
  "$(jq -r '.hooks | has("SessionStart")' "$WS")" "false"
check "settings: every event runs the wrapper, on no matcher, capped at 5s" \
  "$(jq -r '[.hooks[][] | .hooks[] | "\(.type)|\(.command)|\(.timeout)"] | unique | join(" ")' "$WS")" \
  'command|bash "${HARNESS_DIR:-$HOME/.claude/harness}/lib/wall-hook.sh"|5'
check "settings: PostToolUse claims every tool, with no matcher" \
  "$(jq -r '[.hooks.PostToolUse[] | has("matcher")] | any' "$WS")" "false"
# The containment boundary is not what this change is about: the deny list and
# the allow list stay exactly what they were.
check "settings: the deny list is untouched" \
  "$(jq -r '.permissions.deny | join(",")' "$WS")" \
  "Bash(git push:*),Bash(git checkout:*),Bash(git switch:*),Bash(gh:*)"
check "settings: the allow list still allows the worker to work" \
  "$(jq -r '[.permissions.allow[] | select(. == "Edit" or . == "Write" or . == "Bash(npm:*)")] | length' "$WS")" \
  "3"
check "settings: nothing was granted that reaches a remote" \
  "$(jq -r '[.permissions.allow[] | select(test("git push|git checkout|git switch|^Bash\\(gh"))] | length' "$WS")" \
  "0"
if [ "$(tail -c 1 "$WS" | od -An -c | tr -d ' ')" = '\n' ]; then
  ok "settings: the file ends with a newline"
else
  bad "settings: the file ends with a newline"
fi

echo
printf 'wall hook: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
