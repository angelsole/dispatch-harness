"""Durable requests and process ownership for the existing shell runner.

No credentials are serialized. The inherited lock belongs to the detached
process tree, so two clients cannot start the same task concurrently.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import time
import uuid


class DispatchError(Exception):
    pass


def command_on_host(argv):
    host = os.environ.get("DISPATCH_REMOTE_HOST")
    return shlex.join(argv + (["--on", host] if host else []))


def repair_command(provider, owner="", paths=None, run_id=None):
    if run_id:
        return command_on_host(["dispatch", "login", provider, "--for-run", run_id])
    paths = paths or {}
    argv = ["dispatch", "login", provider]
    if owner:
        argv += ["--owner", owner]
        root = str(Path(paths.get("CODEX_HOME", str(Path.home() / "accounts" / owner / "codex"))).parent.parent)
        if root != str(Path.home() / "accounts"):
            argv += ["--accounts-dir", root]
    else:
        cleared = []
        overrides = []
        for key in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "GH_CONFIG_DIR"):
            if key not in paths:
                continue
            if paths[key] is None:
                cleared += ["-u", key]
            else:
                # Even an explicit default path can select another CLI profile.
                overrides.append(f"{key}={paths[key]}")
        if cleared or overrides:
            argv = ["env", "-u", "HARNESS_OWNER"] + cleared + overrides + argv
    return command_on_host(argv)


def read_text(path):
    try:
        return Path(path).read_text().strip()
    except FileNotFoundError:
        return ""


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def atomic_write(path, value):
    path = Path(path)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        with temporary.open("x") as out:
            os.chmod(temporary, 0o600)
            out.write(value)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_json(path, value):
    atomic_write(path, json.dumps(value, indent=2) + "\n")


def run_directory(runtime, run_id):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,119}", run_id):
        raise DispatchError("run ID must start with a letter or digit and contain only letters, digits, '.', '_' or '-'")
    directory = runtime / "runs" / run_id
    if directory.is_symlink():
        raise DispatchError("run directory must not be a symlink")
    return directory


@contextlib.contextmanager
def run_lock(directory):
    with (directory / ".dispatch.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DispatchError("this run is already running; use dispatch status") from None
        # Do not LOCK_UN: the child inherits this open file description.
        yield lock


def is_running(directory):
    if (directory / ".dispatch.lock").exists():
        try:
            with run_lock(directory):
                pass
        except DispatchError:
            return True
    # Older run-task callers have a PID but no CLI lock. Check argv as well:
    # a recycled PID must not make an interrupted task look alive forever.
    return is_legacy_running(directory)


def status(directory):
    if not directory.is_dir():
        raise DispatchError("unknown run: " + directory.name)
    request = read_json(directory / "request.json")
    result = read_json(directory / "result.json")
    launch = read_json(directory / "launch.json")
    waiting = read_json(directory / "waiting.json")
    alive = is_running(directory)
    # A previous result stays available during retry; it is not this attempt's
    # verdict until write_result has run again.
    fresh_result = bool(result) and (directory / "result.json").stat().st_mtime >= launch.get("started", 0)
    state = "running" if alive else result.get("status", "interrupted") if fresh_result else "interrupted"
    if waiting and not alive:
        state = "waiting_for_auth" if waiting.get("provider") else "blocked"
    if fresh_result and result.get("status") in ("ready", "ready_local") and not alive:
        state = result["status"]
        waiting = {}
    if not launch and not result and not alive and not waiting:
        state = "prepared"
    stage = read_text(directory / "status").partition(" ")[2]
    operation = read_json(directory / "evidence-operation.json")
    if alive and isinstance(operation.get("pid"), int):
        proc = subprocess.run(["ps", "-o", "command=", "-p", str(operation["pid"])], capture_output=True, text=True)
        if "evidence_retry.py" in proc.stdout and str(directory) in proc.stdout:
            stage = "frontend evidence — " + operation.get("action", "retrying")
    response = {
        "id": directory.name, "state": state, "stage": stage,
        "account": request.get("account", read_text(directory / "owner")) or "current",
        "host": request.get("host", socket.gethostname()),
        "repo": request.get("repo", read_text(directory / "repo")),
        "worktree": result.get("worktree") or read_text(directory / "worktree"),
        "checkpoint": read_json(directory / "checkpoint.json").get("stage"),
        "result": result if fresh_result else None,
        "logs": str(directory),
    }
    if waiting:
        response["action"] = waiting.get("action", "")
        response["reason"] = waiting.get("reason", "")
        if waiting.get("provider") in ("codex", "claude", "gh"):
            response["action"] = repair_command(waiting["provider"], request.get("account", ""), request.get("account_paths"),
                                                directory.name if request else None)
            response["action"] += " ; " + command_on_host(["dispatch", "resume", directory.name])
    elif state == "needs_input":
        response["action"] = "Answer QUESTIONS.md in the brief, then dispatch resume " + directory.name
    elif state not in ("running", "ready", "ready_local"):
        response["action"] = command_on_host(["dispatch", "resume", directory.name])
    return response


def brief_digest(directory):
    return hashlib.sha256((directory / "brief.md").read_bytes()).hexdigest()


def launch(runtime, directory, request, env, lock, resume=False):
    if is_legacy_running(directory):
        raise DispatchError("this run already has a live driver")
    (directory / "waiting.json").unlink(missing_ok=True)
    started = time.time()
    # Explicit lifecycle flags; HARNESS_DIR is a path, never a fixture marker.
    env = dict(env, HARNESS_DIR=str(runtime), HARNESS_DETACH="0",
               DISPATCH_DETACHED="1", HARNESS_RESUME="1" if resume else "0",
               HARNESS_PUBLISH="1" if request.get("publish", True) else "0")
    write_json(directory / "launch.json", {"started": started, "brief_sha256": brief_digest(directory)})
    with (directory / "launcher.log").open("ab") as log:
        process = subprocess.Popen(
            ["bash", str(runtime / "run-task.sh"), directory.name, request["repo"], request["branch"]],
            cwd=request["repo"], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, pass_fds=(lock.fileno(),),
        )
    atomic_write(directory / "driver.pid", str(process.pid) + "\n")
    return {"id": directory.name, "state": "running", "pid": process.pid,
            "account": request.get("account") or "current", "logs": str(directory)}


def is_legacy_running(directory):
    pid = read_text(directory / "driver.pid")
    if not pid.isdigit():
        return False
    proc = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True)
    return bool(re.search(r"(?:run-task|sync-pr)\.sh\s+" + re.escape(directory.name) + r"(?:\s|$)", proc.stdout))
