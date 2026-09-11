# Credentials on Mini

Mini's Linear app identity belongs to the integration. Model and GitHub logins
belong to a seat — an OS user on the execution host. Map the issue assignee to
that seat in `linear-dispatch.json`; see [station selection](linear-dispatch.md#select-the-execution-station-in-linear).
Each task runs separately from the person's interactive planner conversation.

## Keep persistent logins on the execution host

A seat's logins live inside its own home: `~/.claude`, `~/.codex` and
`~/.config/gh`. Log in as the seat, over ssh — no token is ever pasted into a
Linear task:

```bash
ssh -t dana@mini 'station.sh login codex'
ssh -t dana@mini 'station.sh login claude'
ssh -t dana@mini 'station.sh login gh'
```

(`dispatch login PROVIDER --on dana@mini` is the same thing through the CLI.)
For repair, the run's saved seat names whose account it is; a login for a
seat-owned run cannot be held from another account's terminal, even on the
execution host — the error says exactly which ssh command to run. Then reply
`resume` in the Linear session. A revoked login may need the account
holder again. A successful login-status check confirms configured credentials;
the next provider request can still fail because of refresh, entitlement or
quota. Mini already reports a saved run's auth blocker in its Linear session.

Codex caches its login under its `CODEX_HOME` — the seat's `~/.codex` — or in
the OS credential store and refreshes ChatGPT tokens during use. Keep the
updated cache on Mini between
runs. Do not regularly overwrite it with a laptop's older copy. For a headless
login the CLI supports device authentication. `cli_auth_credentials_store =
"keyring"` requires an available credential store; `auto` can fall back to a
file. Choose storage deliberately when onboarding, rather than changing it
under a live worker. [Codex authentication](https://learn.chatgpt.com/docs/auth).

Claude's harness login is a token file: `claude setup-token` on your laptop
prints a token, `station.sh login claude` (or `station.sh setup`) reads the
paste without echoing it into `~/.claude/oauth-token`, mode 600, first line the
token. The station exports it to the planner as `CLAUDE_CODE_OAUTH_TOKEN`.
`station.sh login claude --browser` runs the interactive browser flow instead.
Claude's own macOS storage is the Keychain; do not store the macOS
login/Keychain password in a launchd plist.
[Claude authentication](https://code.claude.com/docs/en/authentication).

GitHub CLI uses the system credential store when available and can fall back
to `hosts.yml`. `gh auth status` reports the source. Protect a file-backed token
with mode 600 and check the effective account rather than assuming a shared
Keychain entry belongs to the seat.
[GitHub CLI authentication](https://cli.github.com/manual/gh_auth_login).

The Linear client secret and webhook signing secret remain in the runtime's
mode-600 credential files. `lib/linear.sh` mints and caches the app token and
re-mints it near expiry or on a 401. The personal Linear API key used for ticket
sync needs operator rotation if revoked. No credential is stored in the
assignment map, issue description, or shared database.

## The boundary on a shared Mac

Each seat is a macOS user: its home is mode 700, its credential files mode 600,
its Keychain its own. File permissions now separate people for real, because
processes run as different OS users — the boundary the old shared-account
station folders could only approximate.

The service account that runs the wall, the Linear bridge and the Quartermaster
crosses into a seat through exactly one door: `seat_exec`, allowed by the
sudoers fragment for `run-task.sh`, `capacity.sh` and `seat-probe.sh`, nothing
else. Symlinking a person's model or GitHub profile out of their home is
rejected before launch — that is the shape that would silently borrow another
person's auth. A home directory cannot prove that two independently stored
tokens belong to different people, but it does keep each person's files,
Keychain entries and process credentials apart.

Keep the service under its stable operator account, with launchd configured to
restart it. After reboot, check the service and the effective credential stores
from that same account. A locked Keychain may require the operator to unlock
the login session. Back up secrets only through encrypted, access-controlled
storage; exclude them from source control and diagnostic exports.
