"""Evidence-only retries, run under the CLI's saved account and inherited lock."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import demo
from dispatch_runs import DispatchError, command_on_host, read_json, repair_command, write_json


def retry(run, capture, publish):
    result = read_json(run / "result.json")
    request = read_json(run / "request.json")
    if result.get("status") not in ("ready", "ready_local") or not request:
        raise DispatchError("evidence retries require a completed run with saved account context")
    manifest = read_json(run / "evidence.json") or result.get("evidence") or {}
    saved = result.get("evidence") or {}
    if (not manifest.get("head") or manifest.get("head") != saved.get("head")
            or manifest.get("attempt") != result.get("attempt")):
        raise DispatchError("this run has no matching commit-bound evidence record")
    if manifest.get("directory"):
        demo.capture_directory(run, manifest["directory"])
    repo = Path(request["repo"])
    worktree = Path(result.get("worktree") or "/nonexistent-dispatch-worktree")
    if not repo.is_dir():
        raise DispatchError("the saved repository is unavailable on this host")
    if capture:
        if not worktree.is_dir():
            raise DispatchError("the worktree was cleaned up; existing media can still be uploaded with --publish")
        if demo.revision(worktree) != manifest["head"] or not demo.clean(worktree):
            raise DispatchError("the worktree changed since this run completed; use a new reviewed run for revised code")
    elif not manifest.get("artifacts") or manifest.get("status") not in ("captured", "published", "publish_failed"):
        raise DispatchError("no successful capture is available; use evidence --capture first")
    operation = run / "evidence-operation.json"
    original_directory = manifest.get("directory")

    def stage(action):
        write_json(operation, {"pid": os.getpid(), "action": action, "started": time.time()})

    try:
        if capture:
            stage("capturing")
            auth = Path(os.environ.get("DEMO_AUTH_FILE") or str(run.parents[1] / "auth" / (repo.name + ".json")))
            manifest = demo.capture(run, worktree, result.get("attempt", 1), auth)
            if manifest["status"] != "captured":
                manifest["action"] = command_on_host(["dispatch", "resume", run.name])
                return 1
        if publish:
            stage("uploading")
            try:
                check = subprocess.run(["gh", "auth", "status", "--hostname", "github.com"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, timeout=20)
                authenticated = check.returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                authenticated = False
            if not authenticated:
                manifest.update(status="publish_failed", reason="GitHub login is unavailable; the captured media is saved.",
                    auth_provider="gh",
                    action=repair_command("gh", run_id=run.name) + " ; " +
                           command_on_host(["dispatch", "resume", run.name]))
                return 3
            manifest.pop("action", None)
            manifest.pop("auth_provider", None)
            # Archived media is independent of a worktree. Its hashes and the
            # live PR's head prove which commit it represents, even after cleanup.
            manifest = demo.publish(run, repo, result["pr_url"], manifest, check_worktree=False)
            return 0 if manifest["status"] == "published" else 1
        return 0
    except (KeyboardInterrupt, InterruptedError):
        # capture() may already have written a fresh not_run manifest before an
        # interrupt. Keep that attempted capture separate from older good media.
        latest = read_json(run / "evidence.json")
        if latest.get("directory") != original_directory:
            manifest = latest
        uploading = read_json(operation).get("action") == "uploading"
        manifest.update(status="publish_failed" if uploading else "failed",
                        reason="Evidence retry interrupted; inspect saved media before retrying.")
        manifest["action"] = command_on_host(["dispatch", "resume", run.name])
        return 130
    finally:
        try:
            if manifest.get("directory"):
                demo.save_manifest(run, run / manifest["directory"], manifest)
            # Only evidence fields change. The reviewed verdict, gate, attempts,
            # metrics and recovery checkpoint continue to describe the code run.
            latest_result = read_json(run / "result.json")
            latest_result["evidence"] = manifest
            latest_result["demo_url"] = next((a["url"] for a in manifest.get("artifacts", [])
                                              if a.get("kind") == "video" and a.get("url")), "")
            write_json(run / "result.json", latest_result)
        finally:
            operation.unlink(missing_ok=True)


def main():
    def interrupted(_signum, _frame):
        raise InterruptedError("evidence retry interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    # Background shells can pass down SIGINT=ignored. The recorder must still
    # respond to an explicit cancellation and clean up the processes it owns.
    signal.signal(signal.SIGINT, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    if not args.capture and not args.publish:
        parser.error("choose --capture and/or --publish")
    return retry(args.run, args.capture, args.publish)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (DispatchError, demo.DemoError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print("evidence: " + str(exc), file=sys.stderr)
        sys.exit(2)
