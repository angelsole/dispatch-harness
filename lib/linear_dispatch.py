"""Linear agent sessions -> durable, account-pinned local Dispatch runs.

The wall verifies HMAC before sending JSON over stdin. The stdin thread only
validates and commits deliveries; one worker owns lifecycle mutations. SQLite
receipts and ordinary run locks make webhook retries safe across restarts.
"""
import argparse
import contextlib
import fcntl
import getpass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time

from dispatch_runs import DispatchError, atomic_write, read_json, read_text, run_directory, status

UUID = re.compile(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}\Z")
ROOT = Path(__file__).resolve().parents[1]


class LinearUnavailable(DispatchError):
    """No authoritative API result; keep the delivery pending for retry."""


class AccountSelection(DispatchError):
    """The task needs an explicitly mapped execution identity before launch."""


def uid(value):
    return isinstance(value, str) and UUID.fullmatch(value)


def configuration(path):
    config = json.loads(Path(path).read_text())
    if not isinstance(config, dict) or config.get("version") != 1 or not all(uid(config.get(k)) for k in
            ("organization_id", "app_user_id")):
        raise DispatchError("Linear config needs version 1 and organization/app user UUIDs")
    routes = config.get("routes")
    if not isinstance(routes, list) or not routes:
        raise DispatchError("Linear config needs at least one repository route")
    keys = set()
    for route in routes:
        if not isinstance(route, dict):
            raise DispatchError("A Linear route must be an object")
        team = route.get("team", "")
        project = route.get("project_id", "")
        if not isinstance(team, str) or not (uid(team) or re.fullmatch(r"[A-Z][A-Z0-9]*", team)):
            raise DispatchError("Invalid Linear route team")
        if not isinstance(project, str) or (project and not uid(project)):
            raise DispatchError("Invalid Linear route project UUID")
        if (team, project) in keys:
            raise DispatchError("Ambiguous Linear repository routes")
        keys.add((team, project))
        repo = route.get("repo")
        if not isinstance(repo, str) or not Path(repo).is_absolute() or not Path(repo).is_dir():
            raise DispatchError("A Linear route must name an existing absolute repository path")
        if type(route.get("publish", True)) is not bool:
            raise DispatchError("Linear route publish must be boolean")
        if not isinstance(route.get("owner", ""), str) or (route.get("owner") and not
                re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", route["owner"])):
            raise DispatchError("Invalid Linear execution account")
    users = config.get("allowed_users", [])
    if not isinstance(users, list) or not all(uid(user) for user in users):
        raise DispatchError("allowed_users must contain Linear user UUIDs")
    accounts = config.get("accounts")
    if accounts is not None:
        if (not isinstance(accounts, dict) or not accounts or
                any(not uid(user) or not isinstance(owner, str) or not
                    re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", owner)
                    for user, owner in accounts.items())):
            raise DispatchError("accounts must map Linear user UUIDs to saved station names")
        if any("owner" in route for route in routes):
            raise DispatchError("Use accounts for assignment routing or fixed route owners, not both")
    return config


class Store:
    def __init__(self, runtime):
        self.root = runtime / "linear-dispatch"
        if self.root.is_symlink():
            raise DispatchError("Linear dispatch storage must not be a symlink")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.path = self.root / "events.sqlite3"
        if self.path.is_symlink():
            raise DispatchError("Linear dispatch database must not be a symlink")
        with self.connect() as db:
            db.executescript("""
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY, session TEXT NOT NULL, payload TEXT NOT NULL,
                phase TEXT NOT NULL DEFAULT '', operation TEXT, outcome TEXT,
                done INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0,
                due REAL NOT NULL DEFAULT 0, received REAL NOT NULL);
              CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, issue TEXT NOT NULL, context TEXT NOT NULL,
                run TEXT, stopped INTEGER NOT NULL DEFAULT 0);
            """)
        os.chmod(self.path, 0o600)

    @contextlib.contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=2)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def enqueue(self, payload, config):
        if not isinstance(payload, dict):
            return 400
        if payload.get("type") != "AgentSessionEvent" or payload.get("action") not in ("created", "prompted"):
            return 200
        # The app-specific signature, organization and app-user identity pin
        # the caller. OAuth's public clientId and internal application id are
        # different identifiers and neither is needed for this boundary.
        if any(payload.get(field) != config[key] for field, key in
               (("organizationId", "organization_id"), ("appUserId", "app_user_id"))):
            return 403
        session = payload.get("agentSession") or {}
        if not isinstance(session, dict):
            return 400
        issue = session.get("issue") or {}
        activity = payload.get("agentActivity") or {}
        if not all(isinstance(x, dict) for x in (session, issue, activity)):
            return 400
        sid = session.get("id")
        if (not uid(sid) or not uid(issue.get("id")) or
                session.get("organizationId") != config["organization_id"] or
                session.get("appUserId") != config["app_user_id"] or
                not re.fullmatch(r"[A-Z][A-Z0-9]*-[0-9]+", str(issue.get("identifier", "")))):
            return 400
        team = issue.get("team") or {}
        if not isinstance(team, dict):
            return 400
        if not any(r["team"] in (team.get("key"), team.get("id")) for r in config["routes"]):
            return 403
        prompted = payload["action"] == "prompted"
        actor = activity.get("userId") if prompted else session.get("creatorId")
        # Proactive sessions created by our existing outbound integration do not
        # authorize another run. Their human replies may bind to the saved run.
        if not prompted and (not actor or actor == config["app_user_id"]):
            return 200
        if not uid(actor) or (config.get("allowed_users") and actor not in config["allowed_users"]):
            return 403
        if prompted:
            content = activity.get("content") or {}
            if (not uid(activity.get("id")) or activity.get("agentSessionId") != sid or
                    not isinstance(content, dict) or content.get("type") != "prompt" or
                    (activity.get("signal") != "stop" and
                     (not isinstance(content.get("body"), str) or not content["body"].strip() or
                      len(content["body"].encode()) > 32000))):
                return 400
        key = hashlib.sha256((config["organization_id"] + sid + payload["action"] +
                              (activity["id"] if prompted else "")).encode()).hexdigest()
        with self.connect() as db:
            if db.execute("SELECT 1 FROM events WHERE id=?", (key,)).fetchone():
                return 200
            if db.execute("SELECT count(*) FROM events WHERE done=0").fetchone()[0] >= 1000:
                return 503
            saved = db.execute("SELECT issue FROM sessions WHERE id=?", (sid,)).fetchone()
            if saved and saved["issue"] != issue["id"]:
                return 409
            db.execute("INSERT OR IGNORE INTO sessions(id,issue,context) VALUES(?,?,?)",
                       (sid, issue["id"], json.dumps(payload)))
            if not prompted:
                db.execute("UPDATE sessions SET context=? WHERE id=?", (json.dumps(payload), sid))
            db.execute("INSERT INTO events(id,session,payload,received) VALUES(?,?,?,?)",
                       (key, sid, json.dumps(payload), time.time()))
            if prompted and activity.get("signal") == "stop":
                db.execute("UPDATE sessions SET stopped=1 WHERE id=?", (sid,))
                run = db.execute("SELECT run FROM sessions WHERE id=?", (sid,)).fetchone()[0]
                if run:
                    directory = run_directory(self.root.parent, run)
                    if directory.is_dir():
                        atomic_write(directory / "linear-stopped", str(time.time()) + "\n")
        return 200

    def session(self, sid):
        with self.connect() as db:
            return dict(db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone())

    def save_event(self, eid, **values):
        with self.connect() as db:
            db.execute("UPDATE events SET " + ",".join(k + "=?" for k in values) + " WHERE id=?",
                       (*values.values(), eid))


class Linear:
    def __init__(self, runtime, store):
        self.runtime, self.store = runtime, store

    def call(self, query, variables):
        # Reuse the existing app OAuth cache, refresh, locks and protected header
        # files. All dynamic JSON travels over stdin, never through shell code.
        env = dict(os.environ, HARNESS_DIR=str(self.runtime), RUN_DIR=str(self.store.root),
                   TICKET="linear-dispatch")
        script = '. "$1"; body=$(cat); linear_agent_call "Linear dispatcher" "$body"'
        try:
            out = subprocess.run(["bash", "-c", script, "linear-dispatch", str(ROOT / "lib/linear.sh")],
                                 input=json.dumps({"query": query, "variables": variables}),
                                 env=env, capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise LinearUnavailable("Linear app API unavailable; the event is saved for retry") from None
        if out.returncode:
            raise LinearUnavailable("Linear app API unavailable; the event is saved for retry")
        try:
            data = json.loads(out.stdout)
        except ValueError:
            raise LinearUnavailable("Linear returned an unreadable response") from None
        if not isinstance(data, dict) or data.get("errors") or not isinstance(data.get("data"), dict):
            raise LinearUnavailable("Linear rejected the dispatcher API request")
        return data["data"]

    def activity(self, sid, content):
        result = self.call("mutation($input: AgentActivityCreateInput!){agentActivityCreate(input:$input){success}}",
                           {"input": {"agentSessionId": sid, "content": content}})
        if not result.get("agentActivityCreate", {}).get("success"):
            raise DispatchError("Linear did not accept the activity")

    def issue(self, iid):
        return self.call("query($id:String!){issue(id:$id){id identifier title description url "
                         "team{id key} project{id} state{type} delegate{id} assignee{id name} "
                         "parent{assignee{id name}}}}", {"id": iid}).get("issue")


def message(kind, body):
    return {"type": kind, "body": body[:10000]}


class Worker:
    def __init__(self, runtime, config, store, linear):
        self.runtime, self.config, self.store, self.linear = runtime, config, store, linear
        self.stop_lock = threading.Lock()

    def route(self, issue):
        team = issue.get("team") or {}
        candidates = [r for r in self.config["routes"] if r["team"] in (team.get("key"), team.get("id"))]
        project = (issue.get("project") or {}).get("id")
        exact = [r for r in candidates if r.get("project_id") and r["project_id"] == project]
        matches = exact or [r for r in candidates if not r.get("project_id")]
        if len(matches) != 1:
            raise DispatchError("This task needs a repository mapping. Configure its Linear team or project on the Mini execution host, then reply to retry.")
        return matches[0]

    def execution_account(self, route, issue, session):
        accounts = self.config.get("accounts")
        if accounts is None:
            return route.get("owner", ""), "route"
        assignee = issue.get("assignee")
        source = "assignee"
        if not assignee:
            assignee = (issue.get("parent") or {}).get("assignee")
            source = "parent_assignee"
        if not assignee:
            context = json.loads(session["context"])
            assignee = {"id": (context.get("agentSession") or {}).get("creatorId")}
            source = "session_creator"
        owner = accounts.get(assignee.get("id"))
        if not owner:
            raise AccountSelection("The task's responsible person has no configured Mini station. "
                                   "Assign the issue to someone with a station, or map that person's Linear user "
                                   "to their station, then reply `dispatch`. No other person's login was selected.")
        root = Path(os.environ.get("QM_ACCOUNTS_DIR", str(Path.home() / "accounts"))).expanduser().resolve()
        profile = root / owner
        if not profile.is_dir() or profile.is_symlink():
            raise AccountSelection("Station `" + owner + "` needs setup on Mini. Complete its logins, then reply `dispatch`.")
        for provider in ("claude", "codex", "gh"):
            # A profile alias must not silently borrow another person's auth.
            if not (profile / provider).resolve().is_relative_to(profile):
                raise AccountSelection("Station `" + owner + "` links " + provider + " to credentials outside its profile. "
                                       "Give it its own login before dispatching this task.")
        return owner, source

    def account_allowed(self, route, account):
        if "accounts" in self.config:
            return account in self.config["accounts"].values()
        return account == route.get("owner", "")

    def bind_existing(self, sid, issue_id):
        matches = []
        for directory in (self.runtime / "runs").glob("*"):
            if directory.is_dir() and not directory.is_symlink() and read_text(directory / "linear-session") == sid:
                cached = read_json(directory / "linear-issue.json")
                iid = ((cached.get("data") or {}).get("issue") or {}).get("id")
                if iid and iid != issue_id:
                    raise DispatchError("The saved Linear session belongs to another issue")
                matches.append(directory.name)
        if len(matches) > 1:
            raise DispatchError("Multiple runs share this Linear session; an operator must resolve the binding")
        return matches[0] if matches else None

    def capture(self, function, *args, **kwargs):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            function(*args, **kwargs)
        return json.loads(out.getvalue())

    def describe(self, directory):
        current = status(directory)
        state = current["state"]
        if state == "running":
            account = read_json(directory / "request.json").get("account", "")
            return message("thought", "Dispatch is working on this task. " +
                           ("Station: `" + account + "`. " if account else "") +
                           "Progress and the reviewed result will appear here.")
        if state == "needs_input":
            return message("elicitation", read_text(directory / "QUESTIONS.md") + "\n\nReply here to continue.")
        if state in ("ready", "ready_local"):
            result = current.get("result") or {}
            return message("response", "The reviewed work is ready. " + result.get("pr_url", "") +
                           ("\nLocal branch: " + result.get("branch", "") if state == "ready_local" else ""))
        return message("error", "The task is saved but needs attention (" + state + "). " +
                       current.get("reason", "") + "\n" + current.get("action", "") +
                       "\nAfter resolving it, reply `resume` here.")

    def start_run(self, event, session, issue, extra=""):
        if self.store.session(session["id"])["stopped"]:
            return message("response", "Stopped before execution started.")
        route = self.route(issue)
        description = issue.get("description") or ""
        if not description.strip() and not extra.strip():
            return message("elicitation", "What should change, and how will we know it works? Add those details to the task or reply here.")
        if (issue.get("state") or {}).get("type") in ("completed", "canceled"):
            return message("error", "This task is already completed or canceled. Reopen it before dispatching.")
        owner, account_source = self.execution_account(route, issue, session)
        run_id = issue["identifier"] + "-linear-" + session["id"].replace("-", "")
        directory = run_directory(self.runtime, run_id)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if any(directory.iterdir()):
            raise DispatchError("The target run already exists; an operator must inspect it before dispatching")
        context = json.loads(session["context"])
        brief = ("# " + issue["title"] + "\n\n- **Ticket**: " + issue["url"] +
                 "\n- **Repo**: " + route["repo"] + "\n\n## Problem\n\n" + description +
                 "\n\n## Linear conversation and guidance\n\n" + (context.get("promptContext") or "") +
                 "\n\n" + extra + "\n\n## Execution contract\n\n"
                 "Implement the task within this repository. Inspect its instructions and relevant code first. "
                 "Use the task's acceptance criteria and run the relevant checks. If a product decision or "
                 "acceptance criterion is missing, write QUESTIONS.md using the harness protocol and pause. "
                 "Do not invent requirements or expand the scope.\n")
        atomic_write(directory / "linear-session", session["id"] + "\n")
        atomic_write(directory / "linear-origin.json", json.dumps({"session": session["id"],
                     "issue": issue["id"], "organization": self.config["organization_id"],
                     "account": owner, "account_source": account_source}))
        atomic_write(directory / "linear-brief.md", brief)
        with self.store.connect() as db:
            db.execute("UPDATE sessions SET run=? WHERE id=?", (run_id, session["id"]))
        self.store.save_event(event["id"], phase="launching")
        # A stop committed while we were fetching context always wins over launch.
        if self.store.session(session["id"])["stopped"]:
            return message("response", "Stopped before execution started.")
        from dispatch_cli import parser, submit
        argv = ["run", "--repo", route["repo"], "--brief", str(directory / "linear-brief.md"),
                "--id", run_id, "--owner", owner, "--json"]
        if not route.get("publish", True):
            argv.append("--no-publish")
        self.capture(submit, parser().parse_intermixed_args(argv), self.runtime)
        return self.describe(directory)

    def stop(self, directory):
        with self.stop_lock:
            return self.stop_locked(directory)

    def stop_locked(self, directory):
        self.check_run(directory)
        atomic_write(directory / "linear-stopped", str(time.time()) + "\n")
        from dispatch_runs import is_legacy_running
        pid = None
        if is_legacy_running(directory):
            pid = int(read_text(directory / "driver.pid"))
        else:
            evidence_pid = read_json(directory / "evidence-operation.json").get("pid")
            if type(evidence_pid) is int and evidence_pid > 1:
                out = subprocess.run(["ps", "-o", "command=", "-p", str(evidence_pid)],
                                     capture_output=True, text=True)
                command = re.escape(str(self.runtime / "lib/evidence_retry.py")) + r"\s+" + re.escape(str(directory)) + r"(?:\s|$)"
                if re.search(command, out.stdout):
                    pid = evidence_pid
        if pid:
            if os.getpgid(pid) != pid:
                raise DispatchError("Cannot stop this driver safely: it does not own its process group")
            def alive():
                # macOS can return EPERM for killpg(0) after the last live
                # member exits. Inspect membership, excluding zombies.
                out = subprocess.run(["ps", "-axo", "pgid=,stat="], capture_output=True, text=True, check=True)
                return any(len(row) == 2 and row[0] == str(pid) and not row[1].startswith("Z")
                           for row in (line.split() for line in out.stdout.splitlines()))

            def send(sig):
                try:
                    os.killpg(pid, sig)
                except (ProcessLookupError, PermissionError):
                    if alive():
                        raise

            send(signal.SIGTERM)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if not alive():
                    break
                time.sleep(0.05)
            else:
                send(signal.SIGKILL)
                time.sleep(0.05)
                if alive():
                    raise DispatchError("The stop signal was sent, but some task processes are still present")
        elif status(directory)["state"] == "running":
            raise DispatchError("A task operation is active but its process cannot be identified safely; inspect it on the execution host")
        if any((directory / name).exists() for name in ("scheduled", "scheduled-run.sh")):
            subprocess.run(["bash", str(self.runtime / "schedule.sh"), "--cancel", directory.name],
                           env=dict(os.environ, HARNESS_DIR=str(self.runtime)), check=True,
                           capture_output=True, timeout=10)
        return message("response", "Stopped. The saved work remains available; delegate a new session to start another task.")

    def check_run(self, directory):
        from dispatch_actions import metadata, valid_request
        metadata(directory)
        request = read_json(directory / "request.json")
        if (not valid_request(request, directory.name) or request["host"] != socket.gethostname() or
                request["operator"] != getpass.getuser()):
            raise DispatchError("This session's run must be controlled by its saved operator on its execution host")
        if not any(Path(r["repo"]).resolve() == Path(request["repo"]).resolve() and
                   self.account_allowed(r, request["account"]) for r in self.config["routes"]):
            raise DispatchError("This run's repository and account are not enabled for Linear dispatch")

    def handle(self, event):
        payload = json.loads(event["payload"])
        session = self.store.session(event["session"])
        activity = payload.get("agentActivity") or {}
        if not session["run"]:
            existing = self.bind_existing(session["id"], session["issue"])
            if existing:
                issue = self.linear.issue(session["issue"])
                route = self.route(issue)
                request = read_json(run_directory(self.runtime, existing) / "request.json")
                if (Path(request.get("repo", "")).resolve() != Path(route["repo"]).resolve() or
                        not self.account_allowed(route, request.get("account"))):
                    raise DispatchError("This existing run does not match the task's configured repository and account")
                with self.store.connect() as db:
                    db.execute("UPDATE sessions SET run=? WHERE id=?", (existing, session["id"]))
                session["run"] = existing
        directory = run_directory(self.runtime, session["run"]) if session["run"] else None
        if activity.get("signal") == "stop":
            return self.stop(directory) if directory and (directory / "request.json").exists() else message("response", "Stopped before execution started.")
        if session["stopped"]:
            return message("response", "This session is stopped. Delegate a new session to start another task.")
        if event["phase"] == "launching":
            # The launch intent was committed before touching the lifecycle. A
            # crash here is surfaced, never retried as a second dispatch.
            if directory and (directory / "request.json").exists():
                return self.describe(directory)
            return message("error", "Dispatch was interrupted while starting. An operator must inspect the saved run before retrying.")
        if directory and (directory / "request.json").exists():
            self.check_run(directory)
            if payload["action"] == "created":
                return self.describe(directory)
            from dispatch_actions import apply, view
            current = view(self.runtime, directory.name)
            body = (activity.get("content") or {}).get("body", "")
            if (not event["operation"] and body.strip().lower() in ("resume", "retry", "reanudar", "reintentar") and
                    current["state"] in ("running", "ready", "ready_local") and not current["actions"]):
                return self.describe(directory)
            if event["operation"]:
                operation = json.loads(event["operation"])
            elif current["state"] == "needs_input":
                operation = {"id": directory.name, "action": "answer_resume", "answer": body,
                             "revision": current["revision"], "operation_id": event["id"][:32]}
            elif body.strip().lower() in ("resume", "retry", "reanudar", "reintentar"):
                operation = {"id": directory.name, "action": "resume", "revision": current["revision"],
                             "operation_id": event["id"][:32]}
            else:
                return message("thought" if current["state"] == "running" else "response",
                               "This run cannot accept live instructions. Reply to a pending question here, or send `resume` to recover a stopped run. Use a new task for additional scope.")
            self.store.save_event(event["id"], operation=json.dumps(operation))
            result = apply(self.runtime, operation, source="Linear")
            if result["state"] in ("failed", "accepted"):
                return message("error", result["message"])
            return self.describe(directory)
        issue = self.linear.issue(session["issue"])
        if not issue or issue.get("id") != session["issue"]:
            return message("error", "The Linear task is unavailable to this app.")
        original = json.loads(session["context"])
        origin_session = original.get("agentSession") or {}
        comment = origin_session.get("comment") or {}
        # Linear creates a root comment without a user for a delegated session.
        # Its mere presence does not mean that a human casually mentioned us.
        delegated_thread = ((issue.get("delegate") or {}).get("id") == self.config["app_user_id"] and
                            "userId" in comment and comment["userId"] is None and
                            not origin_session.get("sourceCommentId"))
        mentioned = bool(origin_session.get("commentId") or comment) and not delegated_thread
        command = (activity.get("content") or {}).get("body", "").strip().lower()
        explicit = bool(re.search(r"(?:^|\s)/dispatch(?:\s|$)", (comment.get("body") or "").split('\n')[0]))
        if (mentioned or original["action"] != "created") and not explicit and command not in ("dispatch", "/dispatch"):
            return message("elicitation", "To run this task, reply `dispatch` here, or delegate the issue to Mini.")
        extra = (activity.get("content") or {}).get("body", "")
        if command in ("dispatch", "/dispatch", "resume", "retry", "reanudar", "reintentar"):
            extra = ""
        return self.start_run(event, session, issue, extra)

    def step(self):
        with self.store.connect() as db:
            event = db.execute("SELECT * FROM events WHERE done=0 AND due<=? "
                               "ORDER BY CASE WHEN json_extract(payload,'$.agentActivity.signal')='stop' "
                               "THEN 0 ELSE 1 END, received LIMIT 1", (time.time(),)).fetchone()
        if not event:
            return False
        event = dict(event)
        try:
            stop_event = (json.loads(event["payload"]).get("agentActivity") or {}).get("signal") == "stop"
            if self.store.session(event["session"])["stopped"] and not stop_event:
                self.store.save_event(event["id"], done=1)
                return True
            outcome = json.loads(event["outcome"]) if event["outcome"] else None
            if outcome and outcome["type"] in ("thought", "elicitation"):
                saved = self.store.session(event["session"])
                if saved["run"]:
                    directory = run_directory(self.runtime, saved["run"])
                    if (directory / "request.json").exists():
                        outcome = self.describe(directory)
            if not outcome:
                # A first activity makes Linear's automatically created session
                # responsive. API failure leaves the event pending for retry.
                session = self.store.session(event["session"])
                if not event["phase"] and not session["stopped"]:
                    self.linear.activity(event["session"], message("thought", "Preparing this task for Dispatch."))
                    self.store.save_event(event["id"], phase="announced")
                try:
                    outcome = self.handle(event)
                except LinearUnavailable:
                    raise
                except AccountSelection as exc:
                    outcome = message("elicitation", str(exc))
                except (DispatchError, OSError, ValueError, subprocess.SubprocessError) as exc:
                    outcome = message("error", str(exc))
                self.store.save_event(event["id"], outcome=json.dumps(outcome))
            if self.store.session(event["session"])["stopped"] and not stop_event:
                self.store.save_event(event["id"], done=1)
                return True
            self.linear.activity(event["session"], outcome)
            self.store.save_event(event["id"], done=1)
        except (DispatchError, OSError, ValueError, subprocess.SubprocessError):
            attempts = event["attempts"] + 1
            self.store.save_event(event["id"], attempts=attempts, due=time.time() + min(300, 2 ** min(attempts, 8)))
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("serve", "check"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = configuration(args.config)
    if args.command == "check":
        print("Linear dispatcher configuration is valid (" + str(len(config["routes"])) + " routes).")
        return
    os.umask(0o077)
    runtime = args.runtime.resolve()
    if os.environ.get("WALL_RUNS") and Path(os.environ["WALL_RUNS"]).resolve() != runtime / "runs":
        raise DispatchError("Linear dispatch must run on the wall's execution host, using its local runs directory")
    os.environ["HARNESS_DIR"] = str(runtime)
    from dispatch_cli import AUTH_VARS
    for key in AUTH_VARS:
        os.environ.pop(key, None)
    for key in ("HARNESS_SKIP_REVIEW", "HARNESS_REDISPATCH", "HARNESS_RESUME", "DISPATCH_REMOTE_HOST"):
        os.environ.pop(key, None)
    os.environ["HARNESS_TICKET_SYNC"] = "1"
    store = Store(runtime)
    with (store.root / "worker.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        worker = Worker(runtime, config, store, Linear(runtime, store))
        def work():
            while True:
                try:
                    busy = worker.step()
                except Exception:
                    busy = False
                time.sleep(0.05 if busy else 0.5)
        protocol = sys.stdout
        threading.Thread(target=work, daemon=True).start()
        for line in sys.stdin:
            request = {}
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    request = {}
                    raise ValueError("The worker protocol expects an object")
                code = store.enqueue(request["payload"], config)
            except (ValueError, KeyError, TypeError, AttributeError):
                code = 400
            except (OSError, sqlite3.Error):
                code = 503
            print(json.dumps({"id": request.get("id"), "code": code}), file=protocol, flush=True)
            if code == 200 and isinstance(request.get("payload"), dict):
                payload = request["payload"]
                if (payload.get("type") == "AgentSessionEvent" and payload.get("action") == "prompted" and
                        (payload.get("agentActivity") or {}).get("signal") == "stop"):
                    # Stop is handled independently of a slow API/auth call in
                    # the normal queue. The marker also blocks a pending launch.
                    def stop_now(sid):
                        try:
                            saved = store.session(sid)
                            if saved["run"]:
                                directory = run_directory(runtime, saved["run"])
                                if (directory / "request.json").exists():
                                    worker.stop(directory)
                        except (DispatchError, OSError, ValueError, subprocess.SubprocessError):
                            pass  # the durable event reports any failure
                    threading.Thread(target=stop_now, args=(payload["agentSession"]["id"],), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except (DispatchError, OSError, ValueError, sqlite3.Error) as error:
        print("linear-dispatch: " + str(error), file=sys.stderr)
        sys.exit(1)
