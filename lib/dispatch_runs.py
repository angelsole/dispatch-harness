"""Durable requests and process ownership for the existing shell runner.

No credentials are serialized. The inherited lock belongs to the detached
process tree, so two clients cannot start the same task concurrently.
"""
import contextlib
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import time
import threading
import uuid


class DispatchError(Exception):
    pass


def command_on_host(argv):
    host = os.environ.get("DISPATCH_REMOTE_HOST")
    return shlex.join(argv + (["--on", host] if host else []))


def repair_command(provider, owner="", run_id=None):
    owner = owner or ""
    if owner and owner != getpass.getuser():
        # A seat's logins live inside its own account; only that account can
        # hold the interactive terminal a login needs.
        host = os.environ.get("DISPATCH_REMOTE_HOST") or socket.gethostname()
        return shlex.join(["ssh", owner + "@" + host, "station.sh login " + provider])
    argv = ["dispatch", "login", provider]
    if run_id:
        argv += ["--for-run", run_id]
    return command_on_host(argv)


def seat_probe_state(runtime, seat):
    """One `provider=state` line per credential dir, read as the seat; None = no answer.

    A seat's home is 0700, so its login state cannot be inspected from another
    account: the probe runs through seat_exec (the one harness command the
    sudoers fragment admits besides run-task.sh and capacity.sh).
    """
    script = '. "$1/lib/common.sh"; seat_exec "$2" "PATH=$PATH" "HARNESS_DIR=$1" -- "$1/seat-probe.sh"'
    try:
        out = subprocess.run(["bash", "-c", script, "seat-probe", str(runtime), seat],
                             env=dict(os.environ, HARNESS_DIR=str(runtime)),
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode:
        return None
    state = {}
    for line in out.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep and key in ("claude", "codex", "gh", "token"):
            state[key] = value
    return state or None


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
            # Run files live in the shared runtime: group-writable so the seat
            # executing a run can read and replace its own bookkeeping.
            os.chmod(temporary, 0o660)
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


def status(directory, *, running=None):
    if not directory.is_dir():
        raise DispatchError("unknown run: " + directory.name)
    request = read_json(directory / "request.json")
    result = read_json(directory / "result.json")
    launch = read_json(directory / "launch.json")
    waiting = read_json(directory / "waiting.json")
    alive = is_running(directory) if running is None else running
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
            response["action"] = repair_command(waiting["provider"], request.get("account", ""),
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
    if (directory / "linear-stopped").exists():
        raise DispatchError("This Linear session was stopped; delegate a new session to start another task")
    if is_legacy_running(directory):
        raise DispatchError("this run already has a live driver")
    (directory / "waiting.json").unlink(missing_ok=True)
    started = time.time()
    # Explicit lifecycle flags; HARNESS_DIR is a path, never a fixture marker.
    env = dict(env, HARNESS_DIR=str(runtime), HARNESS_DETACH="0",
               DISPATCH_DETACHED="1", HARNESS_RESUME="1" if resume else "0",
               HARNESS_PUBLISH="1" if request.get("publish", True) else "0")
    write_json(directory / "launch.json", {"started": started, "brief_sha256": brief_digest(directory)})
    argv = [str(runtime / "run-task.sh"), directory.name, request["repo"], request["branch"]]
    owner = request.get("account") or ""
    if owner and owner != getpass.getuser():
        # The run's identity is a seat: cross the account boundary through
        # seat_exec, which rebuilds the child's environment from explicit
        # VAR=value pairs (every HARNESS_* knob in env rides the sweep). sudo
        # closes inherited fds above stdio, so the CLI lock ends at that
        # boundary — the run then relies on driver.pid liveness, the class
        # is_running already documents for older run-task callers. run-task.sh
        # writes driver.pid itself and HARNESS_DETACH=0 rides the pairs, so it
        # stays this child's process and the reaper below still sees it exit.
        script = ('set -eu\n'
                  'umask 002\n'
                  'HARNESS_DIR="$1"; seat="$2"; shift 2\n'
                  '. "$HARNESS_DIR/lib/common.sh"\n'
                  'seat_run "$seat" "$@"\n')
        argv = ["bash", "-c", script, "dispatch-seat", str(runtime), owner] + argv
    else:
        argv = ["bash"] + argv
    with (directory / "launcher.log").open("ab") as log:
        process = subprocess.Popen(
            argv,
            cwd=request["repo"], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, pass_fds=(lock.fileno(),),
        )
    # The CLI may exit immediately; the Linear worker may live for weeks. Reap
    # completed children in either host without waiting for the task here.
    threading.Thread(target=process.wait, daemon=True).start()
    atomic_write(directory / "driver.pid", str(process.pid) + "\n")
    return {"id": directory.name, "state": "running", "pid": process.pid,
            "account": request.get("account") or "current", "logs": str(directory)}


def is_legacy_running(directory):
    pid = read_text(directory / "driver.pid")
    if not pid.isdigit():
        return False
    proc = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True)
    return bool(re.search(r"(?:run-task|sync-pr)\.sh\s+" + re.escape(directory.name) + r"(?:\s|$)", proc.stdout))
