# Dispatch from the Mini app in Linear

Delegate an issue to Mini to start a Dispatch run on the configured execution
host. Its title, description, conversation and Linear guidance become the task
brief. Progress, questions and the reviewed PR stay in the same agent session.

## Team workflow

1. Describe the change and its acceptance criteria in a Linear issue, then
   delegate it to Mini. The issue's configured team or project selects the repo.
   Its assignee selects the execution station. A comment mentioning Mini can also start a task with
   `/dispatch`; a casual mention asks whether to dispatch before starting work.
2. Mini acknowledges the task and starts the ordinary implementer, checks and
   review. An issue without a description asks for details in Linear first.
3. When the implementer asks a question, reply in that agent session. The answer
   is saved with the question in the existing brief and resumes that run.
4. The existing ticket-sync integration returns the reviewed draft PR. A route
   with `publish: false` keeps the reviewed branch local.

Reply `resume` or `retry` after resolving a stopped run's blocker, such as an
expired login. Login itself still belongs to the account holder on the execution
host. Linear's **Send stop request** stops that session's process group and
cancels its scheduled capacity retry. Stopping closes the session for further
execution; its files remain available.

This version consumes a described task directly; it does not run an interactive
planner before dispatch. It cannot inject new instructions into an implementer
that is already running. Replies are used at question/recovery boundaries; use
a new task for additional scope after completion. Completed or canceled issues
are not launched. An existing outbound session can control its saved CLI run
when the repository, account, host and operator match the enabled route.

## Select the execution station in Linear

Set the issue's **Assignee** to the person whose station should execute it,
then delegate the issue to **Mini**. Delegation leaves the human assignee in
place. Configure `accounts` as a map from stable Linear user UUIDs to saved
station names, such as `angel`, `emre` or `reinier`.

For a new run, Mini selects the issue's assignee, then the immediate parent
issue's assignee if the issue is unassigned, then the session's original human
creator if neither issue has an assignee. An assigned person without a mapping
does not fall through to another person's account. Mini asks for a configured
station in Linear before creating a run. Assign the task or repair the mapping,
then reply `dispatch` in that session.

Each run saves the chosen account and credential paths. Reassignment, another
person replying, and service restarts do not switch an existing run's account.
Removing an account from the mapping disables its Linear recovery controls.
The initial account selection source is recorded in `linear-origin.json`.

Here a station is a saved profile on the execution host, not a live planner
conversation. Each task starts its own process. This receiver executes on its
local host; routing to another physical machine is not implemented. Workspace
members allowed to operate the integration can assign tasks to mapped stations;
use `allowed_users` to restrict those operators. This mapping is not a macOS
security boundary. See [Mini credentials](mini-credentials.md).

## Enable on the execution host

Use the same machine for the wall server and its local Dispatch runtime. The
Mini can serve this role. A repo route refers to a checkout on that host; no VM,
SSH station, hosted database or separate task dashboard is needed by this bridge.

First set up the existing [Linear OAuth app and signed webhook](operations.md#ticket-sync):
`linear-agent-credentials`, `linear-webhook-secret`, the app's **Agent session
events** subscription, and its public HTTPS `/webhooks/linear` URL. Keep the
personal `linear-api-key` and `HARNESS_RUN_LINK_BASE` configured for the existing
attachment card and final issue-state update. The HTTP pages retain their
existing tailnet access boundary.

Copy `wall/linear-dispatch.example.json` to
`$HARNESS_DIR/linear-dispatch.json` and replace the example identifiers and paths:

```json
{
  "version": 1,
  "organization_id": "00000000-0000-4000-8000-000000000001",
  "app_user_id": "00000000-0000-4000-8000-000000000003",
  "accounts": {
    "00000000-0000-4000-8000-000000000004": "teammate"
  },
  "routes": [
    {"team": "TEAM", "repo": "/srv/repos/app", "publish": true}
  ]
}
```

The workspace and app user UUIDs must match the signed Linear delivery. They
are identifiers, not secrets. The webhook's app-specific signature and these
two identities authorize the caller; no additional OAuth identifier is needed.
The app-authenticated GraphQL query `query { viewer { id } organization { id } }`
provides the app user and workspace IDs.

`team` accepts a Linear team key or UUID. Add `project_id` to a route to select
a specific project; an exact project match takes precedence over the team's
default. Ambiguous mappings refuse execution. `accounts` selects profiles under
`QM_ACCOUNTS_DIR` or `~/accounts`. A profile symlink or a provider directory that
resolves outside its profile is refused before launch. The chosen account and
publication policy are pinned in `request.json`.
Legacy configurations without `accounts` retain fixed route `owner` selection
(or the operator's native profile if omitted). Do not combine route `owner`
with `accounts`; new team installations should use assignment routing.
Optional `allowed_users` restricts initiation and replies to a list of Linear
user UUIDs; otherwise users in the configured workspace and teams can operate
the app. Configure the app's visibility in Linear accordingly.

Validate the file locally, then enable it explicitly in the wall service's
environment and restart that service:

```bash
python3 lib/linear_dispatch.py check \
  --runtime "$HARNESS_DIR" --config "$HARNESS_DIR/linear-dispatch.json"
WALL_LINEAR_DISPATCH_CONFIG="$HARNESS_DIR/linear-dispatch.json" ./wall.sh
```

The check validates configuration syntax and paths; it does not log in, change
Linear, start a model, or verify the public webhook URL. The execution host needs
Python 3 with SQLite, Node 20+, and the usual Dispatch dependencies/accounts.
Install the updated harness on that host before enabling the configuration.
Changing routes requires restarting the wall. Unset `WALL_LINEAR_DISPATCH_CONFIG`
to return to the existing outbound-only behavior. `dispatch ui` never enables
the Linear execution bridge, even if it inherits the configuration variable.

## Delivery and recovery contract

The receiver verifies the raw-body HMAC and timestamp before forwarding an
event. The dispatcher then checks the workspace, app, team, actor and session
identity. Only `AgentSessionEvent` actions `created` and `prompted` are handled;
ordinary issue changes do not start work. Agent-created outbound sessions do
not authorize another dispatch.

Accepted events are committed to
`$HARNESS_DIR/linear-dispatch/events.sqlite3` before HTTP `200`. The database is
mode 600 in a mode-700 directory and contains private issue/conversation data.
Keep this directory on local disk. One dispatcher process owns its worker lock.
The Python worker runs independently of HTTP requests; a failed enqueue or an
unavailable worker returns `503` so Linear can retry. Invalid dispatch payloads
return `400`, identity/team mismatches `403`, and conflicting session bindings
`409`. Existing signature, timestamp and body-size checks remain unchanged.

A `created` event is deduplicated by workspace and session ID. A `prompted`
event additionally uses the activity ID. Receipts persist after completion and
across restarts. The bridge binds the original Linear session before launching;
the pipeline reuses it rather than creating a second timeline. Launch intent is
durable before execution, and answer/recovery operations use the existing run
lock and operation receipts. If a crash leaves a launch unconfirmed, Mini reports
that uncertainty instead of starting it again. A failed Linear status update
retries without repeating the dispatch. An API timeout may still duplicate a
status activity, since the remote acknowledgement can be lost.

The queue admits up to 1,000 unfinished events; further deliveries receive
`503`. Receipts are retained indefinitely in this first version. Do not delete
the database as routine cleanup: that removes delivery deduplication and session
stop history. Back it up with the run directories. No distributed worker routing
or concurrent multi-host database access is implemented.

`linear-dispatch/ticket-sync.log` contains app API diagnostics. To inspect queue
health locally without dumping issue bodies:

```bash
sqlite3 "$HARNESS_DIR/linear-dispatch/events.sqlite3" \
  'SELECT done, phase, count(*) FROM events GROUP BY done, phase;'
```

`tests/linear-dispatch.test.sh` covers signed HTTP ingress, durable retries,
identity and routing rejection, session reuse, launch/crash recovery, answers,
auth recovery and stopping, with real fixture worktrees and fake external
services. The existing Linear agent suite covers outbound stages and PR replies.
Production OAuth configuration and an actual Linear task remain a deployment
smoke test.

Linear's upstream contracts: [agent sessions and webhook payloads](https://linear.app/developers/agent-interaction)
and [stop signals](https://linear.app/developers/agent-signals).
