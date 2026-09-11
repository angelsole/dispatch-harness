"""Authenticated console operations over the ordinary Dispatch lifecycle.

The HTTP adapter passes JSON on stdin, never a shell command. Saved host and
operator identity, revision checks, receipts, and the run lock bound mutations.
"""
import contextlib
import getpass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import socket
import sys
import time

from dispatch_runs import (DispatchError, atomic_write, read_json, read_text,
                           run_directory, run_lock, status, write_json)

FILES = ("request.json", "launch.json", "result.json", "waiting.json", "brief.md",
         "QUESTIONS.md", "checkpoint.json", "status", "worktree", "owner", "driver.pid",
         "evidence-operation.json", "evidence.json", "repo", "branch", "implementer-provider")
RETRYABLE = {"prepared", "interrupted", "waiting_for_auth", "blocked", "gate_failed",
             "implementer_failed", "setup_failed", "push_failed", "pr_failed", "capacity_failed",
             "review_failed", "dirty_worktree_failed", "driver_failed"}


def metadata(directory):
    """Bound reads and refuse links before the lifecycle consumes run metadata."""
    digest = hashlib.sha256()
    for name in FILES:
        path = directory / name
        if path.is_symlink():
            raise DispatchError("linked run metadata is read-only")
        if path.exists():
            if not path.is_file() or path.stat().st_size > 1024 * 1024:
                raise DispatchError("run metadata is too large or is not a regular file")
            value = path.read_bytes()
            if name.endswith(".json"):
                try:
                    record = json.loads(value)
                except (ValueError, UnicodeError):
                    raise DispatchError("unreadable run metadata is read-only") from None
                if not isinstance(record, dict):
                    raise DispatchError("unrecognized run metadata is read-only")
                if name == "result.json" and (not isinstance(record.get("status"), str)
                                               or not record["status"]):
                    raise DispatchError("incomplete run metadata is read-only")
        else:
            value = b""
        digest.update(name.encode() + b"\0" + hashlib.sha256(value).digest())
    lock = directory / ".dispatch.lock"
    if lock.is_symlink() or (lock.exists() and not lock.is_file()):
        raise DispatchError("linked run locks are read-only")
    return digest.hexdigest()


def valid_request(request, run_id):
    """Only complete, recognized requests can authorize the saved lifecycle."""
    if type(request.get("version")) is not int or request["version"] != 1 or request.get("id") != run_id:
        return False
    for key in ("repo", "branch", "host", "operator"):
        if not isinstance(request.get(key), str) or not request[key] or "\0" in request[key]:
            return False
    if not Path(request["repo"]).is_absolute() or request["branch"].startswith("-"):
        return False
    account = request.get("account")
    if not isinstance(account, str) or (account and not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", account)):
        return False
    paths = request.get("account_paths")
    if not isinstance(paths, dict) or type(request.get("publish")) is not bool:
        return False
    allowed = {"CLAUDE_CONFIG_DIR", "CODEX_HOME", "GH_CONFIG_DIR"}
    return not (set(paths) - allowed) and all(
        isinstance(value, str) and "\0" not in value and Path(value).is_absolute()
        for value in paths.values())


def view(runtime, run_id, *, locked=False):
    directory = run_directory(runtime, run_id)
    revision = metadata(directory)
    from dispatch_runs import is_legacy_running
    current = status(directory, running=is_legacy_running(directory)) if locked else status(directory)
    request = read_json(directory / "request.json")
    state = current["state"]
    questions = read_text(directory / "QUESTIONS.md")
    brief = read_text(directory / "brief.md")
    media = (current.get("result") or {}).get("evidence") or {}
    disabled = ""
    if not request:
        disabled = "This older run has no saved execution account. Continue it through the planner."
    elif not valid_request(request, run_id):
        disabled = "The saved request is incomplete or unsupported. Ask the planner to inspect this run."
    elif request.get("host") != socket.gethostname():
        disabled = "Open Dispatch on the execution machine: " + str(request.get("host", "unknown"))
    elif request.get("operator") != getpass.getuser():
        disabled = "Only the operator who started this run can control it here."
    elif request.get("publish", True) and os.environ.get("HARNESS_PUBLISH") == "0":
        disabled = "This session cannot resume a run that is pinned to publishing."
    elif state == "running":
        disabled = "Work is running. Decisions can be submitted after it stops."
    elif state == "deferred_capacity":
        disabled = "A retry is already scheduled."
    elif state in RETRYABLE | {"needs_input"} and not brief:
        disabled = "The task brief is missing or empty. Ask the planner to inspect this run."
    actions = []
    if not disabled:
        if state == "needs_input" and questions and (directory / "brief.md").is_file():
            actions.append({"id": "answer_resume", "label": "Save answer and resume"})
        elif state in RETRYABLE:
            actions.append({"id": "resume", "label": "Check login and resume" if state == "waiting_for_auth" else "Resume run"})
        elif state in ("ready", "ready_local"):
            capture = media.get("status") in ("failed", "not_run") or not media.get("artifacts")
            publish = bool(request.get("publish", True) and (current.get("result") or {}).get("pr_url"))
            if media.get("head") and media.get("status") in ("failed", "not_run", "captured", "publish_failed") and (capture or publish):
                actions.append({"id": "resume", "label": "Check login and recover frontend evidence"
                                if media.get("auth_provider") == "gh" else "Recover frontend evidence"})
        if state == "needs_input" and not actions:
            disabled = "The question or brief is missing. Ask the planner to inspect this run."
    checkpoint = read_json(directory / "checkpoint.json").get("stage")
    names = {"implemented": "Implementation", "gated": "Checks", "validated": "Review and checks"}
    checkpoint_text = (names[checkpoint] + " saved. Its inputs will be checked before reuse."
                       if checkpoint in names else "No saved checkpoint. Recovery runs the required stages again.")
    if state == "needs_input":
        checkpoint_text += " Saving an answer changes the brief, so earlier stages must be checked again."
    waiting = read_json(directory / "waiting.json")
    provider = (waiting.get("provider") if state == "waiting_for_auth" else
                media.get("auth_provider") if state in ("ready", "ready_local") and actions else None)
    login = (["dispatch", "login", provider, "--for-run", run_id]
             if provider in ("codex", "claude", "gh") and not disabled else None)
    reason = current.get("reason", "") or (media.get("reason", "") if state in ("ready", "ready_local") else "")
    return {"id": run_id, "revision": revision, "state": state, "host": current["host"],
            "account": current["account"], "repo": current["repo"],
            "title": next((line.lstrip("# ") for line in brief.splitlines() if line.strip()), run_id),
            "stage": current["stage"], "reason": reason,
            "questions": questions if state == "needs_input" else "", "actions": actions,
            "disabled_reason": disabled, "checkpoint": {"stage": checkpoint, "description": checkpoint_text},
            "login": login, "pr_url": (current.get("result") or {}).get("pr_url", ""),
            "evidence": ((current.get("result") or {}).get("evidence") or {}).get("status", "")}


def apply(runtime, body, *, source="console"):
    if set(body) - {"id", "action", "revision", "operation_id", "answer"}:
        raise DispatchError("unexpected action fields")
    for key in ("id", "action", "revision", "operation_id"):
        if not isinstance(body.get(key), str):
            raise DispatchError("missing action field: " + key)
    operation_id = body["operation_id"]
    if not re.fullmatch(r"[a-f0-9]{32}", operation_id):
        raise DispatchError("invalid operation ID")
    directory = run_directory(runtime, body["id"])
    metadata(directory)
    receipts = directory / "console-operations"
    if receipts.is_symlink():
        raise DispatchError("linked operation receipts are read-only")
    receipt = receipts / (operation_id + ".json")
    if receipt.is_symlink():
        raise DispatchError("linked operation receipts are read-only")
    fingerprint = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()

    def previous():
        if not receipt.exists():
            return None
        if not receipt.is_file() or receipt.stat().st_size > 1024 * 1024:
            raise DispatchError("unreadable operation receipt; ask the planner to inspect this run")
        try:
            saved = json.loads(receipt.read_text())
        except (ValueError, UnicodeError):
            raise DispatchError("unreadable operation receipt; ask the planner to inspect this run") from None
        if not isinstance(saved, dict) or not isinstance(saved.get("response"), dict) or not saved["response"]:
            raise DispatchError("incomplete operation receipt; ask the planner to inspect this run")
        if saved.get("fingerprint") != fingerprint:
            raise DispatchError("operation ID was already used for a different request")
        return saved["response"]

    # An accepted operation may retain the run lock in a detached child.
    # Replaying its receipt does not need or attempt another mutation.
    prior = previous()
    if prior:
        return prior
    with run_lock(directory) as lock:
        prior = previous()
        if prior:
            return prior
        current = view(runtime, body["id"], locked=True)
        if body["revision"] != current["revision"]:
            raise DispatchError("This run changed. Refresh its details before submitting.")
        if body["action"] not in {action["id"] for action in current["actions"]}:
            raise DispatchError(current["disabled_reason"] or "This action is no longer available.")
        answer = body.get("answer", "")
        if not isinstance(answer, str) or len(answer.encode()) > 32000:
            raise DispatchError("Answer must be text of at most 32 KB.")
        if body["action"] == "answer_resume" and not answer.strip():
            raise DispatchError("Write an answer before resuming.")
        if body["action"] != "answer_resume" and answer:
            raise DispatchError("This action does not accept an answer.")
        receipts.mkdir(mode=0o700, exist_ok=True)
        response = {"id": body["id"], "operation_id": operation_id, "state": "accepted",
                    "message": "Request recorded; its outcome is not confirmed. Refresh task details before submitting again."}
        record = {"fingerprint": fingerprint, "at": time.time(), "operator": getpass.getuser(),
                  "action": body["action"], "answer": answer, "revision": body["revision"], "response": response}
        # Write intent before touching the brief or launching. A lost response
        # can be replayed; an interrupted operation is never launched twice.
        write_json(receipt, record)
        try:
            if body["action"] == "answer_resume":
                brief = (directory / "brief.md").read_text()
                heading = "Decision recorded in Linear" if source == "Linear" else "Decision recorded in the console"
                atomic_write(directory / "brief.md", brief + "\n\n## " + heading + "\n\n"
                             + current["questions"] + "\n\nAnswer:\n\n" + answer.strip() + "\n")
                response["answer_saved"] = True
            from dispatch_cli import parser, resume_locked
            args = parser().parse_args(["resume", body["id"], "--json"])
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                rc = resume_locked(args, runtime, directory, lock, background_evidence=True)
            result = json.loads(output.getvalue())
            response.update(state=result["state"], message=("Recovery started." if rc == 0 else
                            "The task is saved but still needs attention. Check the updated details."))
        except (DispatchError, OSError, ValueError) as exc:
            response.update(state="failed", message=str(exc))
        record["response"] = response
        write_json(receipt, record)
        return response


def main():
    runtime = Path(os.environ["HARNESS_DIR"]).expanduser().resolve()
    operation = sys.argv[1]
    body = json.loads(sys.stdin.read(65537))
    if operation == "list":
        tasks = []
        for directory in sorted((runtime / "runs").glob("*")):
            if not directory.is_dir() or directory.is_symlink():
                continue
            try:
                tasks.append(view(runtime, directory.name))
            except (DispatchError, OSError, ValueError, TypeError, AttributeError):
                # The ordinary wall can still show a partial historical record.
                continue
        return {"tasks": tasks}
    if operation == "apply":
        # A console may have been opened from a different account's terminal.
        # Only saved CLI profiles may authorize recovery, including native runs.
        from dispatch_cli import AUTH_VARS
        for key in AUTH_VARS:
            os.environ.pop(key, None)
        return apply(runtime, body)
    raise DispatchError("unknown console operation")


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except (DispatchError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(1)
