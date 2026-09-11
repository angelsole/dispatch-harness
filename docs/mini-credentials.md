# Credentials on Mini

Mini's Linear app identity belongs to the integration. Model and GitHub logins
belong to an execution profile. Map the issue assignee to that profile in
`linear-dispatch.json`; see [station selection](linear-dispatch.md#select-the-execution-station-in-linear).
Each task runs separately from the person's interactive planner conversation.

## Keep persistent logins on the execution host

Use `dispatch login PROVIDER --on mini --owner NAME` to authenticate the chosen
profile on Mini. The browser flow authorizes that host; no token needs to be
pasted into a Linear task. For repair, use the run's saved account context:

```bash
dispatch login codex --on mini --for-run RUN-ID
dispatch login claude --on mini --for-run RUN-ID
dispatch login gh --on mini --for-run RUN-ID
```

Then reply `resume` in the Linear session. A revoked login may need the account
holder again. A successful login-status check confirms configured credentials;
the next provider request can still fail because of refresh, entitlement or
quota. Mini already reports a saved run's auth blocker in its Linear session.

Codex caches its login under `CODEX_HOME` or in the OS credential store and
refreshes ChatGPT tokens during use. Keep the updated cache on Mini between
runs. Do not regularly overwrite it with a laptop's older copy. For a headless
login the CLI supports device authentication. `cli_auth_credentials_store =
"keyring"` requires an available credential store; `auto` can fall back to a
file. Choose storage deliberately when onboarding, rather than changing it
under a live worker. [Codex authentication](https://learn.chatgpt.com/docs/auth).

Claude uses macOS Keychain for its normal macOS credential storage. A custom
config directory alone should not be treated as credential isolation. Existing
profile credential files also need protection. Let `claude auth login` manage
the login; do not store the macOS login/Keychain password in a launchd plist.
[Claude authentication](https://code.claude.com/docs/en/authentication).

GitHub CLI uses the system credential store when available and can fall back
to `hosts.yml`. `gh auth status` reports the source. Protect a file-backed token
with mode 600 and check the effective account rather than assuming
`GH_CONFIG_DIR` isolates a shared Keychain entry.
[GitHub CLI authentication](https://cli.github.com/manual/gh_auth_login).

The Linear client secret and webhook signing secret remain in the runtime's
mode-600 credential files. `lib/linear.sh` mints and caches the app token and
re-mints it near expiry or on a 401. The personal Linear API key used for ticket
sync needs operator rotation if revoked. No credential is stored in the
assignment map, issue description, or shared database.

## The boundary on a shared Mac

Use mode 700 on each account directory and mode 600 on credential files. Avoid
symlinking a person's model or GitHub profile to another person's directory.
The Linear assignment router rejects provider directories outside the selected
profile. It cannot prove that two independently stored tokens belong to
different people or isolate entries in a shared macOS Keychain.

With shared station folders, all profiles run as the same macOS operator. File
permissions separate that user from other OS users; they do not separate
processes running as that operator.
For actual separation between people's credentials, use distinct macOS users
with their own homes and Keychains, or isolated workers with dedicated service
credentials. Merely adding station folders or VMs sharing those folders does
not provide that separation. The current Linear bridge does not switch OS users.

Keep the service under its stable operator account, with launchd configured to
restart it. After reboot, check the service and the effective credential stores
from that same account. A locked Keychain may require the operator to unlock
the login session. Back up secrets only through encrypted, access-controlled
storage; exclude them from source control and diagnostic exports.
