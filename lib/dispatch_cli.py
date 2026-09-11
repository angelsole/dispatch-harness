"""The user/agent interface: local conversation, durable runs, optional SSH."""
import argparse
import contextlib
import getpass
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import threading
import uuid

from planner import DEFAULT_MODELS, prompt as planner_prompt
from dispatch_runs import (DispatchError, atomic_write, brief_digest, command_on_host,
                           launch, read_json, read_text, run_directory, run_lock,
                           seat_probe_state, status, write_json, repair_command)

AUTH_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
             "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL",
             "CODEX_ACCESS_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN", "HARNESS_CODEX_HOME_FALLBACK")
COMMANDS = ("chat", "station", "stations", "init", "run", "status", "wait", "resume", "evidence", "doctor", "login", "ui")


def parser():
    p = argparse.ArgumentParser(prog="dispatch", description="Local-first coding tasks, with seats as OS users.",
        epilog="Examples: dispatch 'Fix checkout' | dispatch run --brief brief.md | "
               "dispatch status | dispatch resume RUN-ID | dispatch evidence RUN-ID --publish | dispatch ui")
    p.add_argument("command", nargs="?", default="chat", help="command or a quoted task description")
    p.add_argument("arguments", nargs="*")
    p.add_argument("--on", metavar="SSH_HOST", help="execute on an SSH host; default: this machine")
    p.add_argument("--owner", help="run as this seat; only the runtime's owning account may act for another seat")
    p.add_argument("--remote-harness", help="absolute installation path on the SSH host")
    p.add_argument("--repo", "--dir", dest="repo", help="repository/directory on the execution machine")
    p.add_argument("--planner", choices=("codex", "claude"), default=os.environ.get("DISPATCH_PLANNER", "codex"))
    p.add_argument("--model", default=os.environ.get("DISPATCH_MODEL"))
    p.add_argument("--hands-off", action="store_true",
                   help="chat/station: bypass planner permission checks (Codex also disables its sandbox)")
    p.add_argument("--brief", help="brief file; '-' reads stdin")
    p.add_argument("--id", help="run ID; generated when omitted")
    p.add_argument("--branch", help="task branch; generated when omitted")
    p.add_argument("--no-publish", action="store_true", help="finish with a reviewed local branch; no push or PR")
    p.add_argument("--json", action="store_true", help="machine-readable status/result")
    p.add_argument("--timeout", type=int, default=60, help="wait timeout in seconds (default 60)")
    p.add_argument("--pipeline", action="store_true", help="doctor: also check task execution dependencies")
    p.add_argument("--browser", action="store_true", help="login codex: use browser callback instead of device login")
    p.add_argument("--for-run", metavar="RUN_ID", help="login: use the account context saved with this task")
    p.add_argument("--capture", action="store_true", help="evidence: recapture the completed run's frontend storyboard")
    p.add_argument("--publish", action="store_true", help="evidence: upload saved media to this run's existing PR")
    return p


def executable(provider, env):
    return env.get({"codex": "CODEX_BIN", "claude": "CLAUDE_BIN"}.get(provider, ""), provider)


def _require_seat_allowed(owner, runtime):
    if not owner or owner == getpass.getuser():
        return
    # Acting for another seat means launching work inside a home this process
    # cannot reach. Only the account that owns the shared runtime (the service
    # user) may do that; everybody else gets the SSH instruction instead.
    if runtime.stat().st_uid != os.getuid():
        host = os.environ.get("DISPATCH_REMOTE_HOST") or socket.gethostname()
        raise DispatchError("logins and stations belong to the account holder: ssh " + owner + "@" + host +
                            ", then run station.sh there")


def resolve_owner(args, runtime):
    """The seat a command acts for, once validated; "" means the current user."""
    owner = args.owner if args.owner is not None else os.environ.get("HARNESS_OWNER", "")
    if not owner or owner == getpass.getuser():
        return ""
    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", owner):
        raise DispatchError("invalid seat name: " + owner)
    _require_seat_allowed(owner, runtime)
    if subprocess.run(["id", "-u", owner], capture_output=True).returncode:
        raise DispatchError("unknown seat " + owner + "; there is no user by that name on this machine")
    return owner


def account_environment(args, saved=None, runtime=None):
    env = dict(os.environ)
    env["PATH"] += os.pathsep + os.pathsep.join((str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"))
    if saved:
        # A saved request names the run's seat; the ambient HARNESS_OWNER and
        # any seat lookup belong to new runs, not to a run already pinned.
        owner = saved.get("account", "")
        if args.owner is not None and args.owner != owner:
            raise DispatchError("this run is pinned to account " + (owner or "current") + "; resume without --owner")
        _require_seat_allowed(owner, runtime)
    else:
        owner = resolve_owner(args, runtime) if runtime is not None else ""
    # A pinned run sheds ambient credentials even when it dispatches as the
    # current account: the overrides belong to whichever terminal resumed it.
    if owner or saved:
        for key in AUTH_VARS:
            env.pop(key, None)
        # Config-dir overrides were the old shared-account mechanism; with seats
        # they would only ever point a login at somebody else's credentials.
        for key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "GH_CONFIG_DIR"):
            env.pop(key, None)
    env["HARNESS_OWNER"] = owner
    return env


def crew_seats(runtime):
    """The seats this machine dispatches for: the accounts mapping, else QM_CREW.

    Shares the bridge's mapping so `dispatch stations` and the Quartermaster
    can never disagree about who the crew is.
    """
    names = []
    try:
        accounts = json.loads((runtime / "linear-dispatch.json").read_text()).get("accounts")
        if isinstance(accounts, dict):
            names = [value for value in accounts.values() if isinstance(value, str)]
    except (OSError, ValueError):
        names = []
    if not any(name.strip() for name in names):
        names = os.environ.get("QM_CREW", "").split()
    seats, seen = [], set()
    for name in sorted(names):
        if name and name not in seen:
            seen.add(name)
            seats.append(name)
    return seats


def auth_ok(provider, env):
    binary = executable(provider, env)
    argv = {"codex": ["login", "status"], "claude": ["auth", "status", "--json"],
            "gh": ["auth", "status", "--hostname", "github.com"]}[provider]
    try:
        out = subprocess.run([binary] + argv, env=env, capture_output=True, text=True, timeout=20)
        if provider == "claude":
            return out.returncode == 0 and json.loads(out.stdout).get("loggedIn") is True
        return out.returncode == 0
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return False


def emit(value, as_json):
    if as_json:
        print(json.dumps(value, indent=2))
        return
    if isinstance(value, list):
        if not value:
            print("No runs yet. Start with dispatch 'Describe the task'.")
        for item in value:
            emit(item, False)
        return
    print(f"{value['id']}: {value['state']} | account {value.get('account', 'current')}")
    if value.get("stage") and value["state"] == "running":
        print("  " + value["stage"])
    result = value.get("result") or {}
    if result.get("pr_url"):
        print("  " + result["pr_url"])
    evidence = result.get("evidence") or {}
    if evidence:
        print("  frontend evidence: " + evidence.get("status", "unknown"))
        if evidence.get("reason"):
            print("  " + evidence["reason"])
        for warning in evidence.get("warnings", []):
            print("  " + warning)
        if evidence.get("action"):
            print("  next: " + evidence["action"])
        if evidence.get("directory") and value.get("logs"):
            print("  media: " + str(Path(value["logs"]) / evidence["directory"]))
    if value.get("worktree"):
        print("  worktree: " + value["worktree"])
    if value.get("reason"):
        print("  " + value["reason"])
    if value.get("action"):
        print("  next: " + value["action"])
    elif value["state"] == "running":
        print("  watch: " + command_on_host(["dispatch", "wait", value["id"]]))


def repository(path, env):
    out = subprocess.run(["git", "-C", path or os.getcwd(), "rev-parse", "--show-toplevel"],
                         env=env, capture_output=True, text=True)
    if out.returncode:
        raise DispatchError("choose a Git repository with --repo, or run dispatch inside one")
    return out.stdout.strip()


def pipeline_issue(runtime, request, env, resuming=False):
    checkpoint = read_json(runtime / "runs" / request["id"] / "checkpoint.json") if resuming else {}
    binaries = ["git", "bash", "jq"]
    if not checkpoint:
        binaries.append(executable("claude", env))
    for binary in binaries:
        if not shutil.which(binary, path=env["PATH"]):
            return {"reason": "missing task dependency: " + binary, "action": "Install " + binary + ", then dispatch resume " + request["id"]}
    # Resolve the existing repo policy; do not guess the implementer's provider
    # from the planner model or require a Claude login for a z.ai worker.
    provider = read_text(runtime / "runs" / request["id"] / "implementer-provider")
    if not provider:
        out = subprocess.run(["bash", "-c", '. "$1/repos.conf.sh"; repo_config "$2"; printf "%s" "${IMPLEMENTER_PROVIDER:-$3}"',
                              "dispatch", str(runtime), request["repo"], env.get("IMPLEMENTER_PROVIDER", "anthropic")],
                             env=env, capture_output=True, text=True)
        if out.returncode:
            raise DispatchError("could not read repository configuration")
        provider = out.stdout.strip()
    if not checkpoint and provider == "anthropic":
        owner = request.get("account", "")
        if owner and owner != getpass.getuser():
            # The seat's home is closed to this process; ask from inside it.
            probe = seat_probe_state(runtime, owner)
            healthy = (bool(probe) and probe.get("claude") == "inside"
                       and probe.get("claude_auth") == "ok")
        else:
            healthy = auth_ok("claude", env)
        if not healthy:
            return {"provider": "claude", "reason": "Claude implementer login is unavailable; the task is saved.",
                    "action": repair_command("claude", request.get("account")) + " ; dispatch resume " + request["id"]}
    return None


def read_brief(path):
    text = sys.stdin.read() if path == "-" else Path(path).expanduser().read_text()
    if not text.strip():
        raise DispatchError("brief is empty")
    return text


def submit(args, runtime):
    if not args.brief:
        raise DispatchError("run needs --brief FILE; use dispatch 'task description' to have the planner write it")
    env = account_environment(args, runtime=runtime)
    repo = repository(args.repo, env)
    run_id = args.id or ("adhoc-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
    directory = run_directory(runtime, run_id)
    branch = args.branch or "task/" + run_id.lower()
    check = subprocess.run(["git", "check-ref-format", "--branch", branch], env=env, capture_output=True)
    if check.returncode or branch.startswith("-"):
        raise DispatchError("invalid task branch")
    text = read_brief(args.brief)
    # Group-writable run dir: the seat that executes the run writes status and
    # results here through the runtime's shared group.
    os.umask(0o007)
    directory.mkdir(parents=True, exist_ok=True, mode=0o770)
    with run_lock(directory) as lock:
        if any((directory / name).exists() for name in ("request.json", "result.json", "started", "status", "driver.pid", "arm", "publish", "worktree")) or is_running_legacy(directory):
            raise DispatchError("run already exists; use dispatch status " + run_id + " or dispatch resume " + run_id)
        request = {"version": 1, "id": run_id, "repo": repo, "branch": branch,
                   "account": env.get("HARNESS_OWNER", ""),
                   "operator": getpass.getuser(), "host": socket.gethostname(),
                   "created": time.time(), "publish": not args.no_publish and env.get("HARNESS_PUBLISH", "1") != "0"}
        atomic_write(directory / "brief.md", text)
        write_json(directory / "request.json", request)
        issue = pipeline_issue(runtime, request, env)
        if issue:
            write_json(directory / "waiting.json", issue)
        else:
            emit(launch(runtime, directory, request, env, lock), args.json)
            return 0
    emit(status(directory), args.json)
    return 3


def is_running_legacy(directory):
    # run_lock is held here; querying the CLI lock would see ourselves.
    from dispatch_runs import is_legacy_running
    return is_legacy_running(directory)


def resume(args, runtime):
    if len(args.arguments) != 1:
        raise DispatchError("resume needs one run ID")
    directory = run_directory(runtime, args.arguments[0])
    current = status(directory)
    if current["state"] == "running":
        saved = read_json(directory / "request.json")
        if args.owner is not None and args.owner != saved.get("account", ""):
            raise DispatchError("this run is pinned to another account; resume without --owner")
        emit(current, args.json)
        return 0
    with run_lock(directory) as lock:
        return resume_locked(args, runtime, directory, lock)


def resume_locked(args, runtime, directory, lock, *, background_evidence=False):
    """Shared resume operation; callers must own the run lock."""
    current = status(directory, running=is_running_legacy(directory))
    saved = read_json(directory / "request.json")
    if saved and args.owner is not None and args.owner != saved.get("account", ""):
        raise DispatchError("this run is pinned to account " + (saved.get("account") or "current") + "; resume without --owner")
    if current["state"] in ("ready", "ready_local"):
        result = current.get("result") or {}
        media = result.get("evidence") or {}
        if saved and media.get("head") and media.get("status") in ("failed", "not_run", "captured", "publish_failed"):
            if args.brief:
                raise DispatchError("this run's code is complete; use a new reviewed run for a changed brief")
            args.capture = media["status"] in ("failed", "not_run") or not media.get("artifacts")
            args.publish = bool(saved.get("publish", True) and result.get("pr_url"))
            if args.capture or args.publish:
                return evidence(args, runtime, held_lock=lock, background=background_evidence)
    if current["state"] in ("running", "ready", "ready_local"):
        emit(current, args.json)
        return 0
    if saved.get("publish", True) and os.environ.get("HARNESS_PUBLISH") == "0":
        raise DispatchError("this run is pinned to publishing; it cannot restart from a --no-publish session")
    request = read_json(directory / "request.json")
    if not request:
        result = read_json(directory / "result.json")
        repo = read_text(directory / "repo")
        branch = result.get("branch") or read_text(directory / "branch")
        if not repo or not branch:
            raise DispatchError("legacy run is missing repo/branch metadata; resume it with run-task.sh once")
        owner = read_text(directory / "owner")
        if args.owner is None:
            args.owner = owner
        request = {"version": 1, "id": directory.name, "repo": repo, "branch": branch,
                   "account": owner,
                   "host": socket.gethostname(), "publish": True}
        write_json(directory / "request.json", request)
    if request.get("host") != socket.gethostname():
        raise DispatchError("this run belongs to " + request["host"] + "; resume it on that host")
    env = account_environment(args, request, runtime=runtime)
    if args.brief:
        atomic_write(directory / "brief.md", read_brief(args.brief))
    last = read_json(directory / "launch.json")
    if current["state"] == "needs_input" and brief_digest(directory) == last.get("brief_sha256"):
        raise DispatchError(current["action"])
    issue = pipeline_issue(runtime, request, env, resuming=True)
    if issue:
        write_json(directory / "waiting.json", issue)
    else:
        emit(launch(runtime, directory, request, env, lock, resume=True), args.json)
        return 0
    emit(status(directory, running=False), args.json)
    return 3


def chat(args, runtime):
    env = account_environment(args, runtime=runtime)
    if env.get("HARNESS_OWNER"):
        # An interactive planner is the account holder's own session; acting for
        # a seat is what background runs (dispatch run) are for.
        host = os.environ.get("DISPATCH_REMOTE_HOST") or socket.gethostname()
        raise DispatchError("the interactive planner belongs to the account holder: ssh " + env["HARNESS_OWNER"] +
                            "@" + host + ", then run station.sh start there")
    if args.no_publish:
        env["HARNESS_PUBLISH"] = "0"
    provider = args.planner
    if not auth_ok(provider, env):
        raise DispatchError(provider + " login is unavailable; " + repair_command(provider, env.get("HARNESS_OWNER")))
    cwd = str(Path(args.repo or os.getcwd()).expanduser().resolve())
    if not Path(cwd).is_dir():
        raise DispatchError("working directory does not exist: " + cwd)
    (runtime / "runs").mkdir(parents=True, exist_ok=True)
    model = args.model or DEFAULT_MODELS[provider]
    command = [executable(provider, env)]
    if model:
        command += ["-m" if provider == "codex" else "--model", model]
    if args.hands_off:
        command += ["--dangerously-bypass-approvals-and-sandbox" if provider == "codex"
                    else "--dangerously-skip-permissions"]
    if provider == "codex":
        command += ["-C", cwd, "--add-dir", str(runtime / "runs")]
    else:
        # Claude discovers skills inside its config directory — the user's own
        # ~/.claude here; a seat's planner links its own in station.sh setup.
        for skill in ("dispatch", "briefed-dispatch", "dispatch-pixel"):
            source = runtime / "planner-skills" / skill
            target = Path.home() / ".claude" / "skills" / skill
            enabled = skill != "dispatch-pixel" or (Path.home() / ".agents/skills" / skill / "SKILL.md").is_file()
            if enabled and (source / "SKILL.md").is_file() and not target.exists() and not target.is_symlink():
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(source, target_is_directory=True)
    command += [planner_prompt(runtime, " ".join(args.arguments), no_publish=env.get("HARNESS_PUBLISH") == "0",
                               hands_off=args.hands_off)]
    permissions = "hands-off (checks bypassed)" if args.hands_off else "CLI defaults"
    print(f"dispatch: local {provider} planner ({model}) | account {env.get('HARNESS_OWNER') or 'current'} | permissions: {permissions} | {cwd}", flush=True)
    os.chdir(cwd)
    os.execvpe(command[0], command, env)


def evidence(args, runtime, *, held_lock=None, background=False):
    if len(args.arguments) != 1:
        raise DispatchError("evidence needs one run ID")
    directory = run_directory(runtime, args.arguments[0])
    current = status(directory)
    if not args.capture and not args.publish:
        if args.json:
            print(json.dumps({"id": directory.name, "state": current["state"],
                              "evidence": (current.get("result") or {}).get("evidence"),
                              "stage": current["stage"], "logs": str(directory)}, indent=2))
        else:
            emit(current, False)
            if not (current.get("result") or {}).get("evidence"):
                print("  No frontend evidence has been recorded for this run.")
        return 0
    with contextlib.nullcontext(held_lock) if held_lock is not None else run_lock(directory) as lock:
        if is_running_legacy(directory):
            raise DispatchError("this run has a live driver; wait for it to finish")
        # Re-read under the lock; status() would see this operation itself as a
        # running pipeline. An old ready result cannot stand in for a newer run.
        result = read_json(directory / "result.json")
        started = read_json(directory / "launch.json").get("started", 0)
        if (result.get("status") not in ("ready", "ready_local")
                or (directory / "result.json").stat().st_mtime < started):
            raise DispatchError("evidence retries require a completed ready or ready_local run")
        saved = read_json(directory / "request.json")
        if not saved:
            raise DispatchError("this run has no saved account context; evidence is available read-only")
        if saved.get("host") != socket.gethostname():
            raise DispatchError("retry evidence on the execution host: " + str(saved.get("host")))
        env = account_environment(args, saved, runtime=runtime)
        # Tokens are never saved with a request. An ambient token from another
        # session must not override the run's saved GitHub CLI profile.
        for key in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
            env.pop(key, None)
        if args.publish and (not saved.get("publish", True) or env.get("HARNESS_PUBLISH") == "0"):
            raise DispatchError("publishing is disabled for this run or session; use evidence --capture to save locally")
        if args.publish and not result.get("pr_url"):
            raise DispatchError("this run has no existing PR; evidence does not push code or create PRs")
        # Configuration is trusted host configuration, sourced under the saved
        # account. Values stay in the child's environment, never stdout/JSON.
        script = '''set -e
. "$1/repos.conf.sh"
repo_config "$2"
if [ -f "$1/demo.conf.sh" ]; then . "$1/demo.conf.sh"; fi
export DEMO_PORT="${DEMO_PORT:-}" DEMO_AUTH_FILE="${DEMO_AUTH_FILE:-}"
export SHOT_BIN="${SHOT_BIN:-$HOME/.local/bin/shot-scraper}"
export R2_REMOTE="${R2_REMOTE:-}" R2_PUBLIC="${R2_PUBLIC:-}"
runtime="$1"; shift 2
exec python3 "$runtime/lib/evidence_retry.py" "$@"
'''
        argv = ["bash", "-c", script, "dispatch-evidence", str(runtime), saved["repo"], str(directory)]
        if args.capture:
            argv.append("--capture")
        if args.publish:
            argv.append("--publish")
        # If the client goes away, the recorder retains the lock until its own
        # cleanup finishes. Browser/server children do not inherit it further.
        with (directory / "demo-driver.log").open("ab") as log:
            if background:
                process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                           stderr=log, start_new_session=True, pass_fds=(lock.fileno(),))
                threading.Thread(target=process.wait, daemon=True).start()
                emit({"id": directory.name, "state": "running", "account": saved.get("account") or "current",
                      "stage": "Recovering frontend evidence", "pid": process.pid}, args.json)
                return 0
            rc = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=log,
                                pass_fds=(lock.fileno(),)).returncode
    emit(status(directory, running=is_running_legacy(directory)) if held_lock is not None
         else status(directory), args.json)
    if rc:
        print("dispatch: evidence retry did not complete; see demo-driver.log and demo.log", file=sys.stderr)
    return rc


def remote(args, argv):
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:-]*", args.on):
        raise DispatchError("invalid SSH host")
    forwarded = []
    skip = False
    for arg in argv:
        if skip:
            skip = False
            continue
        if arg in ("--on", "--remote-harness"):
            skip = True
        elif not arg.startswith(("--on=", "--remote-harness=")):
            forwarded.append(arg)
    data = None
    if os.environ.get("HARNESS_PUBLISH") == "0" and not args.no_publish and (args.command in ("run", "chat") or args.command not in COMMANDS):
        forwarded.append("--no-publish")
    if args.brief:
        data = read_brief(args.brief)
        for i, arg in enumerate(forwarded):
            if arg == "--brief":
                forwarded[i + 1] = "-"
            elif arg.startswith("--brief="):
                forwarded[i] = "--brief=-"
    if args.command in ("run", "init") and not args.repo:
        # Resolve only the repo name locally. The remote home is expanded by
        # the remote CLI, never by the laptop's shell.
        name = Path(repository(None, os.environ)).name
        forwarded += ["--repo", "~/Projects/" + name]
    script = None
    if args.remote_harness:
        if not args.remote_harness.startswith("/"):
            raise DispatchError("--remote-harness needs an absolute remote path")
        script = shlex.quote(args.remote_harness + "/dispatch.sh")
    if script is None:
        command = ('IFS= read -r HARNESS_DIR < "$HOME/.claude/harness-dir" || '
                   '{ echo "dispatch: shared harness is not configured; run station.sh setup by absolute path or pass --remote-harness" >&2; exit 1; }; '
                   'case "$HARNESS_DIR" in /*) ;; *) echo "dispatch: invalid shared harness path" >&2; exit 1;; esac; '
                   'export HARNESS_DIR; exec bash "$HARNESS_DIR/dispatch.sh" ' + shlex.join(forwarded))
    else:
        command = ('export HARNESS_DIR=' + shlex.quote(args.remote_harness) +
                   '; exec bash ' + script + " " + shlex.join(forwarded))
    command = 'export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"; ' + command
    interactive = args.command in ("chat", "station", "login") or args.command not in COMMANDS
    if not interactive:
        command = "export DISPATCH_REMOTE_HOST=" + shlex.quote(args.on) + "; " + command
    if os.environ.get("HARNESS_PUBLISH") == "0" and args.command == "resume":
        command = "export HARNESS_PUBLISH=0; " + command
    ssh = ["ssh", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
    ssh += ["-t"] if interactive else ["-o", "BatchMode=yes"]
    return subprocess.run(ssh + [args.on, command], input=data, text=True).returncode


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    args = parser().parse_intermixed_args(argv)
    command = args.command if args.command in COMMANDS else "chat"
    if args.for_run and command != "login":
        raise DispatchError("--for-run is only supported by login")
    if (args.capture or args.publish) and command != "evidence":
        raise DispatchError("--capture and --publish are only supported by evidence")
    if command == "evidence" and args.publish and os.environ.get("HARNESS_PUBLISH") == "0":
        raise DispatchError("publishing is disabled for this session; use evidence --capture to save locally")
    if args.hands_off and command not in ("chat", "station"):
        raise DispatchError("--hands-off applies to chat or station; background workers use the harness's task permissions")
    if command == "ui" and args.on:
        raise DispatchError("the console controls local runs; open it on the execution machine")
    if args.on:
        return remote(args, argv)
    if args.remote_harness:
        raise DispatchError("--remote-harness needs --on")
    runtime = Path(os.environ.get("HARNESS_DIR", str(Path.home() / ".claude/harness"))).expanduser().absolute()
    if args.repo:
        args.repo = str(Path(args.repo).expanduser().absolute())
    if args.command not in COMMANDS:
        args.arguments.insert(0, args.command)
        args.command = "chat"
    if args.no_publish and args.command not in ("chat", "run"):
        raise DispatchError("--no-publish is supported for a new chat or run; publication is pinned on existing runs")
    if args.command == "ui":
        if args.arguments or args.owner or args.repo:
            raise DispatchError("ui uses saved run accounts and repositories; run dispatch ui without task options")
        node = shutil.which("node")
        server = Path(__file__).resolve().parents[1] / "wall/server.js"
        if not node or not server.is_file():
            raise DispatchError("the console needs Node 20+ and an up-to-date harness installation")
        env = dict(os.environ, WALL_CONTROL="1", WALL_HOST="127.0.0.1", WALL_PORT="0",
                   WALL_RUNS=str(runtime / "runs"), WALL_INGEST_TOKEN="", WALL_LINEAR_WEBHOOK_SECRET="")
        for key in ("HARNESS_SKIP_REVIEW", "HARNESS_REDISPATCH", "HARNESS_RESUME", "DISPATCH_REMOTE_HOST"):
            env.pop(key, None)
        os.execve(node, [node, str(server)], env)
    if args.command == "chat":
        chat(args, runtime)
    if args.command == "run":
        return submit(args, runtime)
    if args.command == "resume":
        return resume(args, runtime)
    if args.command == "evidence":
        return evidence(args, runtime)
    if args.command in ("status", "wait"):
        if len(args.arguments) > 1 or (args.command == "wait" and len(args.arguments) != 1):
            raise DispatchError(args.command + " needs one run ID" if args.command == "wait" else "status accepts one run ID")
        if not args.arguments:
            values = [status(d) for d in sorted((runtime / "runs").glob("*"), key=lambda d: d.stat().st_mtime, reverse=True)
                      if d.is_dir() and not d.is_symlink()]
            emit(values, args.json)
            return 0
        directory = run_directory(runtime, args.arguments[0])
        deadline = time.monotonic() + max(0, args.timeout)
        while True:
            value = status(directory)
            if args.command != "wait" or value["state"] != "running" or time.monotonic() >= deadline:
                emit(value, args.json)
                return 124 if args.command == "wait" and value["state"] == "running" else 0
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    saved = None
    if args.for_run:
        directory = run_directory(runtime, args.for_run)
        saved = read_json(directory / "request.json")
        if not saved:
            raise DispatchError("this run has no saved account context")
        if saved.get("host") != socket.gethostname():
            raise DispatchError("log in on the execution host: " + str(saved.get("host")))
    if args.command in ("station", "login"):
        if saved and saved.get("account") and saved["account"] != getpass.getuser():
            # The login for a seat-owned run cannot be held from another
            # account's terminal, even on the execution host.
            host = os.environ.get("DISPATCH_REMOTE_HOST") or socket.gethostname()
            raise DispatchError("this run dispatches as seat '" + saved["account"] + "'; its login belongs to that "
                                "account: ssh " + saved["account"] + "@" + host + ", then run station.sh login there")
        # station.sh acts for whoever runs it. Only an explicitly typed --owner
        # is forwarded, and station.sh itself answers it with the SSH path.
        command = ["bash", str(runtime / "station.sh")]
        command += ["start"] if args.command == "station" else ["login"] + args.arguments
        for flag, value in (("--dir", args.repo), ("--planner", args.planner), ("--model", args.model)):
            if value:
                command += [flag, value]
        if args.owner is not None:
            command += ["--owner", args.owner]
        if args.browser:
            command += ["--browser"]
        if args.hands_off:
            command += ["--hands-off"]
        os.execvpe(command[0], command, dict(os.environ, HARNESS_DIR=str(runtime)))
    env = account_environment(args, saved, runtime=runtime)
    if args.command == "init":
        return subprocess.run(["bash", str(runtime / "setup-repo.sh"), repository(args.repo, env), "--write"], env=env).returncode
    if args.command == "stations":
        values = []
        for seat in crew_seats(runtime):
            probe = seat_probe_state(runtime, seat)
            values.append({"account": seat,
                           **{provider: "signed_in" if probe and probe.get(provider) == "inside" else "login_needed"
                              for provider in ("codex", "claude", "gh")}})
        if args.json:
            print(json.dumps(values, indent=2))
        else:
            for item in values:
                print("{account}: codex={codex} claude={claude} gh={gh}".format(**item))
            print("Open a seat's station over ssh: ssh NAME@" + socket.gethostname() +
                  ". Login checks do not measure remaining credits.")
        return 0
    if args.command == "doctor":
        owner = env.get("HARNESS_OWNER")
        if owner:
            # The seat's planner login can only be asked about from inside it.
            probe = seat_probe_state(runtime, owner)
            healthy = bool(probe) and probe.get(args.planner) == "inside"
        else:
            healthy = auth_ok(args.planner, env)
        checks = {"planner": args.planner, "account": owner or "current",
                  "login": "signed_in" if healthy else "login_needed"}
        if not healthy:
            checks["action"] = repair_command(args.planner, owner)
        if args.pipeline:
            request = {"id": "doctor", "repo": repository(args.repo, env), "account": env.get("HARNESS_OWNER")}
            issue = pipeline_issue(runtime, request, env)
            checks["pipeline"] = issue or "available"
            healthy = healthy and not issue
        print(json.dumps(checks, indent=2) if args.json else "\n".join(f"{k}: {v}" for k, v in checks.items()))
        return 0 if healthy else 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (DispatchError, OSError) as error:
        print("dispatch: " + str(error), file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(130)
