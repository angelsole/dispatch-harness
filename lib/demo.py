"""Capture frontend evidence independently of model sessions and media hosting.

The runner owns the verdict. A demo is advisory evidence of a particular commit,
never a substitute for the test gate or an assertion that the UI is correct.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote, urlsplit
import urllib.request
import uuid

from dispatch_runs import read_json, write_json

START = "<!-- dispatch-evidence:start -->"
END = "<!-- dispatch-evidence:end -->"
MEDIA = {".png", ".jpg", ".jpeg", ".gif", ".mp4", ".webm"}


class DemoError(Exception):
    pass


def stop(process):
    # Only terminate the process group we created; never kill by port number.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    process.wait()


def command(argv, cwd, log, env=None, timeout=60):
    # A server grandchild can inherit stdout after its wrapper exits. A regular
    # file lets us wait for the wrapper, then reap its group without hanging on
    # the grandchild's copy of a pipe (the old shot-scraper server leak).
    with tempfile.TemporaryFile() as output_file:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=output_file, stderr=log, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        finally:
            stop(process)
        output_file.seek(0)
        output = output_file.read()
    log.write(output); log.flush()
    if process.returncode:
        # Arguments may contain fixture input or a credential path; keep them
        # out of the PR and manifest. Raw tool output stays in the local log.
        raise DemoError(f"{Path(argv[0]).name} exited {process.returncode}; see demo.log")
    return output.decode(errors="replace").strip()


def revision(worktree):
    return subprocess.check_output(["git", "-C", str(worktree), "rev-parse", "HEAD"],
                                   stderr=subprocess.DEVNULL).decode().strip()


def clean(worktree):
    return not subprocess.check_output(
        ["git", "-C", str(worktree), "status", "--porcelain", "--untracked-files=all"]
    ).strip()


def requested(brief, worktree):
    return bool(re.search(r"^## Demo storyboard\s*$", brief, re.M | re.I)
                or any((worktree / ".harness" / name).is_file() for name in ("demo.json", "demo.yml")))


def port_available(port):
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, port), timeout=.2):
                return False
        except OSError:
            pass
    return True


def local_url(url):
    if not isinstance(url, str):
        raise DemoError("demo URL must be a string")
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
        raise DemoError("demo.json requires a localhost URL and its own dev server")
    if parsed.username or parsed.password:
        raise DemoError("put authentication in a saved browser state, not the URL")
    return parsed.port or (443 if parsed.scheme == "https" else 80)


def validate_story(story):
    if not isinstance(story, dict):
        raise DemoError("demo.json must be an object")
    server, steps = story.get("server"), story.get("steps")
    if not isinstance(server, list) or not server or not all(isinstance(s, str) and s for s in server):
        raise DemoError("demo.json needs a server command as an argv array")
    local_url(story.get("url", ""))
    if not isinstance(steps, list) or not 1 <= len(steps) <= 50:
        raise DemoError("demo.json needs 1–50 steps")
    # Selectors are stable CSS/text selectors, never refs from a past session.
    arity = {"click": 2, "fill": 3, "press": 2, "wait": 2, "screenshot": 2}
    for step in steps:
        if (not isinstance(step, list) or not step or not all(isinstance(s, str) for s in step)
                or step[0] not in arity or len(step) != arity[step[0]]
                or not step[1] or step[1].startswith(("-", "@e"))):
            raise DemoError("invalid demo step; use click, fill, press, wait, or screenshot with stable selectors")
        if step[0] == "screenshot" and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,60}\.png", step[1]):
            raise DemoError("screenshot names must be simple .png filenames")
    interactions = [s for s in steps if s[0] != "screenshot" and not (s[0] == "wait" and s[1].isdigit())]
    if not interactions or interactions[-1][0] != "wait":
        raise DemoError("end the interaction with a wait for a visible success selector, not only pauses")
    if sum(s[0] == "screenshot" for s in steps) > 10:
        raise DemoError("use at most ten screenshots per storyboard")
    viewport = story.get("viewport", {"width": 1280, "height": 800})
    if not isinstance(viewport, dict) or any(type(viewport.get(k)) is not int or not 320 <= viewport[k] <= 2560
                                            for k in ("width", "height")):
        raise DemoError("viewport width/height must be integers between 320 and 2560")
    if type(story.get("video", False)) is not bool:
        raise DemoError("video must be true or false")
    return viewport


def agent_capture(story, worktree, destination, log, auth):
    viewport = validate_story(story)
    binary = shutil.which(os.environ.get("AGENT_BROWSER_BIN", "agent-browser"))
    if not binary:
        raise DemoError("agent-browser is missing; install agent-browser and run agent-browser install on this host")
    if not port_available(local_url(story["url"])):
        raise DemoError("demo port is busy; use a free port allowed by the app's CORS settings")
    # No ambient profile, CDP attachment, provider, or auto-restored state. Each
    # recording uses an independent session even on a shared execution host.
    env = {k: v for k, v in os.environ.items() if not k.startswith("AGENT_BROWSER_")}
    if os.environ.get("AGENT_BROWSER_EXECUTABLE_PATH"):
        env["AGENT_BROWSER_EXECUTABLE_PATH"] = os.environ["AGENT_BROWSER_EXECUTABLE_PATH"]
    browser = [binary, "--session", "dispatch-" + uuid.uuid4().hex]
    # Explicit empty config avoids picking up agent-browser.json from the repo
    # or the user's home (which can request a shared Chrome profile).
    config = destination / "browser-config.json"
    config.write_text("{}\n")
    browser += ["--config", str(config)]
    deadline = time.monotonic() + 600
    def call(*args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DemoError("demo exceeded the ten-minute capture limit")
        return command(browser + list(args), worktree, log, env, timeout=min(60, remaining))
    warnings = []
    server = subprocess.Popen(story["server"], cwd=worktree, stdin=subprocess.DEVNULL,
                              stdout=log, stderr=log, start_new_session=True)
    recording = False
    try:
        ready_deadline = time.monotonic() + 60
        while True:
            if server.poll() is not None:
                raise DemoError("demo dev server exited before capture; see demo.log")
            try:
                with urllib.request.urlopen(story["url"], timeout=1):
                    break
            except (OSError, ValueError):
                if time.monotonic() >= ready_deadline:
                    raise DemoError("demo dev server did not become ready within 60s; see demo.log")
                time.sleep(.2)
        if auth and auth.is_file():
            call("--state", str(auth), "open", story["url"])
        else:
            call("open", story["url"])
        call("set", "viewport", str(viewport["width"]), str(viewport["height"]))
        if story.get("video"):
            if shutil.which("ffmpeg"):
                call("record", "start", str(destination / "demo.mp4"))
                recording = True
            else:
                warnings.append("Video skipped: ffmpeg is missing; screenshots were requested instead.")
        for step in story["steps"]:
            if step[0] == "screenshot":
                call("screenshot", str(destination / step[1]))
            else:
                call(*step)
        call("screenshot", str(destination / "result.png"))
        if recording:
            call("record", "stop")
            recording = False
        if server.poll() is not None:
            raise DemoError("demo dev server exited during capture; see demo.log")
    finally:
        with contextlib.suppress(Exception):
            if recording:
                command(browser + ["record", "stop"], worktree, log, env, timeout=15)
        with contextlib.suppress(Exception):
            command(browser + ["close"], worktree, log, env, timeout=15)
        stop(server)
    return warnings


def legacy_capture(worktree, destination, log, auth):
    binary = shutil.which(os.environ.get("SHOT_BIN", str(Path.home() / ".local/bin/shot-scraper")))
    if not binary:
        raise DemoError("shot-scraper is missing; install it or use an agent-browser demo.json storyboard")
    port = os.environ.get("DEMO_PORT", "")
    if not port or not port.isdigit():
        raise DemoError("legacy demo.yml requires DEMO_PORT in the repo configuration")
    if not port_available(int(port)):
        raise DemoError("demo port is busy; no recording was attempted")
    started = time.time_ns()
    argv = [binary, "video", ".harness/demo.yml", "--mp4"]
    if auth and auth.is_file():
        argv += ["--auth", str(auth)]
    command(argv, worktree, log, timeout=600)
    videos = [p for p in (worktree / ".harness").iterdir()
              if p.suffix in (".mp4", ".webm") and not p.is_symlink() and p.is_file()
              and p.stat().st_mtime_ns >= started and p.stat().st_size]
    if not videos:
        raise DemoError("shot-scraper produced no fresh video; see demo.log")
    video = max(videos, key=lambda p: p.stat().st_mtime_ns)
    shutil.copyfile(video, destination / ("demo" + video.suffix))
    if shutil.which("ffmpeg"):
        command(["ffmpeg", "-y", "-sseof", "-0.1", "-i", str(video), "-frames:v", "1",
                 str(destination / "result.png")], worktree, log)
    return []


def save_manifest(run, destination, manifest):
    write_json(destination / "manifest.json", manifest)
    write_json(run / "evidence.json", manifest)


def capture(run, worktree, attempt, auth=None):
    head = revision(worktree)
    destination = run / "evidence" / (head[:12] + "-" + uuid.uuid4().hex[:12])
    destination.mkdir(parents=True, mode=0o700)
    manifest = dict(version=1, head=head, attempt=attempt, status="not_run", reason="",
                    directory=str(destination.relative_to(run)), artifacts=[], warnings=[])
    save_manifest(run, destination, manifest)
    with (run / "demo.log").open("wb") as log:
        try:
            if not clean(worktree):
                raise DemoError("commit or discard worktree changes before recording frontend evidence")
            story = worktree / ".harness/demo.json"
            if story.is_file():
                manifest["provider"] = "agent-browser"
                manifest["warnings"] = agent_capture(json.loads(story.read_text()), worktree, destination, log, auth)
            elif (worktree / ".harness/demo.yml").is_file():
                manifest["provider"] = "shot-scraper"
                manifest["warnings"] = legacy_capture(worktree, destination, log, auth)
            else:
                raise DemoError("frontend brief requested a demo, but the worker wrote no demo.json or demo.yml")
            if revision(worktree) != head or not clean(worktree):
                raise DemoError("worktree changed during recording; evidence cannot be attached to this commit")
            for path in sorted(destination.iterdir()):
                if path.suffix not in MEDIA or path.is_symlink() or not path.is_file() or not path.stat().st_size:
                    continue
                manifest["artifacts"].append(dict(path=str(path.relative_to(run)),
                    sha256=hashlib.sha256(path.read_bytes()).hexdigest(), bytes=path.stat().st_size,
                    kind="video" if path.suffix in (".mp4", ".webm") else "screenshot"))
            if not manifest["artifacts"]:
                raise DemoError("capture produced no media")
            manifest.update(status="captured", reason="Saved on the execution host.")
        except (DemoError, OSError, ValueError, subprocess.SubprocessError) as exc:
            manifest.update(status="failed", reason=str(exc) if isinstance(exc, DemoError)
                            else f"capture failed ({type(exc).__name__}); see demo.log", artifacts=[])
            log.write((str(exc) + "\n").encode())
    save_manifest(run, destination, manifest)
    return manifest


def section(manifest, run=None):
    lines = [START, "## Frontend evidence", "", f"Commit: `{manifest['head']}`", ""]
    if manifest["status"] == "published":
        lines.append("Captured the storyboard successfully. Visual review is still required.")
    else:
        lines.append(f"Evidence: **{manifest['status']}**. " + manifest.get("reason", ""))
    for warning in manifest.get("warnings", []):
        lines.extend(["", warning])
    for item in manifest.get("artifacts", []):
        target = item.get("url") or (str(run / item["path"]) if run else None)
        if not target:
            continue
        if item["kind"] == "screenshot" or run:
            # gh turns a standalone video image-reference into a player URL.
            # Keeping that reference inside the markers makes reattachment
            # replace the previous recording instead of accumulating videos.
            lines.extend(["", f"![{Path(item['path']).stem}](<{target}>)"])
        elif item.get("url"):
            lines.extend(["", f"[Watch recording](<{target}>)"])
    lines.extend(["", END])
    return "\n".join(lines)


def replace_section(body, replacement):
    pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    if pattern.search(body):
        return pattern.sub(lambda _: replacement, body, count=1)
    return body.rstrip() + "\n\n" + replacement + "\n"


def publish(run, worktree, pr, manifest):
    destination = run / manifest["directory"]
    native = False
    pr_state = None
    live_body = run / "pr-body-evidence.md"
    with (run / "demo.log").open("ab") as log:
        try:
            if revision(worktree) != manifest["head"] or not clean(worktree):
                raise DemoError("PR worktree differs from the captured commit; record evidence again")
            paths = []
            for item in manifest.get("artifacts", []):
                path = run / item["path"]
                if (path.is_symlink() or not path.resolve().is_relative_to(destination.resolve())
                        or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]):
                    raise DemoError("evidence file changed since capture; record evidence again")
                paths.append(path)
            pr_state = json.loads(command(["gh", "pr", "view", pr, "--json", "body,headRefOid"], worktree, log))
            if pr_state.get("headRefOid") != manifest["head"]:
                raise DemoError("PR head differs from the captured commit; record evidence again")
            if manifest["status"] == "published" and manifest.get("pr_url") == pr:
                return manifest
            body = pr_state["body"]
            help_text = command(["gh", "pr", "edit", "--help"], worktree, log)
            native = "--attach" in help_text and bool(paths)
            remote, public = os.environ.get("R2_REMOTE"), os.environ.get("R2_PUBLIC")
            if paths and native:
                manifest.update(status="published", reason="", publisher="github")
            elif paths and remote and public:
                if urlsplit(public).scheme != "https":
                    raise DemoError("R2_PUBLIC must be an HTTPS URL")
                # Repo/run/commit/capture scoping keeps parallel hosts and retries
                # from silently replacing what an older PR showed.
                repo = subprocess.check_output(["git", "-C", str(worktree), "remote", "get-url", "origin"])
                prefix = hashlib.sha256(repo.strip()).hexdigest()[:12] + "/" + run.name + "/" + destination.name
                for item, path in zip(manifest["artifacts"], paths):
                    key = prefix + "/" + path.name
                    command(["rclone", "copyto", str(path), remote.rstrip("/") + "/" + key,
                             "--s3-no-check-bucket"], worktree, log, timeout=120)
                    item["url"] = public.rstrip("/") + "/" + quote(key, safe="/")
                manifest.update(status="published", reason="", publisher="rclone")
            elif paths:
                manifest.update(status="captured", reason="Saved on the execution host. Update GitHub CLI to a version with gh pr edit --attach, or configure demo.conf.sh for uploads.")
            live_body.write_text(replace_section(body, section(manifest, run if native else None)))
            if native:
                argv = ["gh", "pr", "edit", pr, "--body-file", str(live_body)]
                for path in paths:
                    argv += ["--attach", str(path)]
                command(argv, worktree, log, timeout=180)
                uploaded_body = command(["gh", "pr", "view", pr, "--json", "body", "-q", ".body"], worktree, log)
                block = uploaded_body.split(START, 1)[-1].split(END, 1)[0]
                urls = re.findall(r"https://[^\s<>\)]+", block)
                if len(urls) != len(paths) or str(run) in block:
                    raise DemoError("GitHub returned incomplete attachment references; inspect the PR and demo.log")
                for item, url in zip(manifest["artifacts"], urls):
                    item["url"] = url
            else:
                slug = command(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], worktree, log)
                command(["gh", "api", f"repos/{slug}/pulls/{pr.rstrip('/').split('/')[-1]}", "-X", "PATCH",
                         "-F", "body=@" + str(live_body)], worktree, log)
            manifest["pr_url"] = pr
        except (DemoError, OSError, ValueError, subprocess.SubprocessError) as exc:
            manifest.update(status="publish_failed", reason=str(exc) if isinstance(exc, DemoError)
                            else f"evidence publishing failed ({type(exc).__name__}); see demo.log")
            log.write((str(exc) + "\n").encode())
            # gh may upload some files and then return nonzero. Keep successful
            # attachments but remove unresolved local file references and make
            # the partial result explicit in our section. Never rewrite a newer
            # commit's PR while trying to repair an upload.
            if pr_state and pr_state.get("headRefOid") == manifest["head"]:
                with contextlib.suppress(Exception):
                    state = json.loads(command(["gh", "pr", "view", pr, "--json", "body,headRefOid"], worktree, log))
                    if state.get("headRefOid") == manifest["head"]:
                        body = state["body"]
                        if native and START in body and END in body:
                            block = body.split(START, 1)[1].split(END, 1)[0]
                            block = "\n".join(line for line in block.splitlines() if str(run) not in line)
                            block = block.replace("Captured the storyboard successfully. Visual review is still required.",
                                "Evidence upload incomplete; some attachments may be missing. See the run's demo.log.")
                            live_body.write_text(replace_section(body, START + block + "\n" + END))
                        else:
                            live_body.write_text(replace_section(body, section(manifest)))
                        slug = command(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], worktree, log)
                        command(["gh", "api", f"repos/{slug}/pulls/{pr.rstrip('/').split('/')[-1]}", "-X", "PATCH",
                                 "-F", "body=@" + str(live_body)], worktree, log)
    save_manifest(run, destination, manifest)
    return manifest


def main():
    def interrupted(_signum, _frame):
        raise InterruptedError("demo interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("capture", "publish", "section"))
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--worktree", type=Path, required=True)
    parser.add_argument("--attempt", type=int, default=1)
    parser.add_argument("--auth", type=Path)
    parser.add_argument("--pr")
    args = parser.parse_args()
    if args.action == "capture":
        brief = (args.run / "brief.md").read_text()
        if requested(brief, args.worktree):
            capture(args.run, args.worktree, args.attempt, args.auth)
    elif args.action == "publish":
        if not args.pr:
            parser.error("publish requires --pr")
        publish(args.run, args.worktree, args.pr, read_json(args.run / "evidence.json"))
    else:
        print(section(read_json(args.run / "evidence.json")))


if __name__ == "__main__":
    main()
