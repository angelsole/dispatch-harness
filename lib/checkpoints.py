"""Conservative checkpoint fingerprints. No model can assert a checkpoint.

Only clean, committed trees without optional profiles can reuse stages. The
runner earns checkpoints; this helper binds them to their inputs and evidence.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from dispatch_runs import atomic_write, read_json


def git(worktree, *args):
    return subprocess.check_output(["git", "-C", str(worktree), *args], stderr=subprocess.DEVNULL)


def signature(worktree, run, runtime, base, config):
    if git(worktree, "status", "--porcelain", "--untracked-files=all").strip():
        raise ValueError("dirty worktree")
    if config["profiles"]:
        raise ValueError("profile stages require a fresh run")
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    for ref in ("HEAD", base):
        digest.update(git(worktree, "rev-parse", ref))
    paths = [run / "brief.md", runtime / "run-task.sh", runtime / "worker-settings.json",
             runtime / "repos.conf.sh", runtime / "repos.local.sh"]
    paths += sorted((runtime / "lib").glob("*.sh"))
    paths += sorted((runtime / "lib").glob("*.py"))
    paths += sorted((run / "specs").rglob("*"))
    paths += sorted((worktree / ".harness/specs").rglob("*"))
    paths += [worktree / ".harness/implementer-notes.md"]
    for root in [worktree] + [worktree / p for p in config["env_subdirs"].split()]:
        paths += sorted(root.glob(".env*"))
    for path in paths:
        digest.update(str(path).encode())
        if path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()


def main():
    action, stage, worktree, run, runtime, base = sys.argv[1:]
    worktree, run, runtime = Path(worktree), Path(run), Path(runtime)
    data = json.load(sys.stdin)
    fingerprint = signature(worktree, run, runtime, base, data["config"])
    path = run / "checkpoint.json"
    if action == "save":
        # Only the digest leaves memory. Expanded repo commands may contain
        # credentials; account configuration paths are not review evidence.
        data.pop("config", None)
        if stage == "validated":
            for name in ("review-notes.md", "findings.json", "refuted.json", "promoted.json"):
                source = worktree / ".harness" / name
                if source.is_file():
                    data.setdefault("evidence", {})[name] = hashlib.sha256(source.read_bytes()).hexdigest()
        data.update(version=1, stage=stage, signature=fingerprint)
        atomic_write(path, json.dumps(data) + "\n")
    else:
        checkpoint = read_json(path)
        if checkpoint.get("signature") != fingerprint or checkpoint.get("version") != 1:
            return 1
        if checkpoint.get("stage") not in ("implemented", "gated", "validated"):
            return 1
        for name, expected in checkpoint.get("evidence", {}).items():
            if name not in ("review-notes.md", "findings.json", "refuted.json", "promoted.json"):
                return 1
            source = worktree / ".harness" / name
            if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
                return 1
        print(checkpoint["stage"])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        sys.exit(1)
