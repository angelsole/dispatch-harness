#!/usr/bin/env bash
# Claude Code hook wrapper: projects one hook event onto the wall's ingest route.
#
# Run by every worker the harness launches (worker-settings.json wires it to
# PostToolUse, Stop and SessionEnd). Claude Code parses a hook's stdout as JSON
# and treats exit 2 as a block, so this script prints nothing and always exits 0.
set -u

# No wall, or a session the harness did not launch: leave without reading stdin,
# without jq and without curl. HARNESS_RUN_ID is the second half of the test so
# an operator's exported HARNESS_WALL_URL can never post a run-less event.
[ -n "${HARNESS_WALL_URL:-}" ] && [ -n "${HARNESS_RUN_ID:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

host=$(hostname -s 2>/dev/null) || host=""
[ -n "$host" ] || host=unknown

# Only the fields the wall draws, each capped at 200 characters. tool_response
# is deliberately absent: it carries whole file contents.
body=$(jq -c -M \
  --arg run "$HARNESS_RUN_ID" --arg host "$host" --argjson at "$(date +%s)" '
  def clip: if type == "string" then .[0:200] else "" end;
  (if type == "object" then . else {} end) as $e
  | (if ($e.tool_input | type) == "object" then $e.tool_input else {} end) as $ti
  | {run: $run, at: $at, host: $host,
     session_id: ($e.session_id | clip),
     cwd: ($e.cwd | clip),
     hook_event_name: ($e.hook_event_name | clip),
     prompt_id: ($e.prompt_id | clip),
     tool_name: ($e.tool_name | clip),
     reason: ($e.reason | clip),
     tool_input: {command: ($ti.command | clip),
                  file_path: ($ti.file_path | clip),
                  description: ($ti.description | clip)}}
  ' 2>/dev/null) || exit 0
[ -n "$body" ] || exit 0

auth=()
[ -n "${HARNESS_WALL_TOKEN:-}" ] \
  && auth=(-H "Authorization: Bearer $HARNESS_WALL_TOKEN")

# Backgrounded so a slow or dead wall never sits inside a tool call.
curl -sf -m 2 -X POST -H 'Content-Type: application/json' \
  ${auth[@]+"${auth[@]}"} -d "$body" -o /dev/null \
  "$HARNESS_WALL_URL/api/ingest/hook" </dev/null >/dev/null 2>&1 &

exit 0
