"""Exercise archived evidence, account recovery and mutual exclusion via the CLI."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time
import unittest

import demo_test
from dispatch_runs import read_json, run_lock, write_json

SOURCE = Path(__file__).resolve().parents[1]


class EvidenceRetryTests(unittest.TestCase):
    # Share the deterministic browser/GitHub fixture without inheriting its tests.
    git = demo_test.DemoTests.git
    write_story = demo_test.DemoTests.write_story
    capture = demo_test.DemoTests.capture
    calls = demo_test.DemoTests.calls

    def setUp(self):
        demo_test.DemoTests.setUp(self)
        self.runtime = self.root / "harness"
        self.runtime.mkdir(); (self.runtime / "runs").mkdir()
        self.run.rmdir(); self.run = self.runtime / "runs/TASK-1"; self.run.mkdir()
        for name in ("lib", "repos.conf.sh", "dispatch.sh"):
            (self.runtime / name).symlink_to(SOURCE / name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("HARNESS_", "CLAUDE_", "CODEX_", "GH_", "GITHUB_", "ANTHROPIC_", "OPENAI_", "DISPATCH_"))}
        self.env.update(HARNESS_DIR=str(self.runtime))
        for name in ("claude", "codex"):
            path = self.bin / name
            path.write_text('#!/bin/sh\necho "unexpected model call" >&2\nexit 99\n'); path.chmod(0o755)
        manifest = self.capture()
        self.request = dict(repo=str(self.repo), account="", account_paths={}, publish=True, host=socket.gethostname())
        self.result = dict(status="ready", attempt=2, worktree=str(self.repo),
            pr_url="https://github.com/team/app/pull/12", evidence=manifest, demo_url="",
            gate="passed", metrics={"tokens": 1234}, review="passed")
        write_json(self.run / "request.json", self.request)
        write_json(self.run / "result.json", self.result)
        for name in ("checkpoint.json", "status", "timeline", "metrics.json", "attempt"):
            (self.run / name).write_text('{}\n' if name.endswith('.json') else 'original\n')
        self.original = {p.name: p.read_bytes() for p in self.run.iterdir() if p.name in (
            "checkpoint.json", "status", "timeline", "metrics.json", "attempt", "request.json")}

    def call(self, *args, check=True):
        result = subprocess.run([sys.executable, str(self.runtime / "lib/dispatch_cli.py"), *args],
                                env=self.env, capture_output=True, text=True, timeout=25)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def unchanged_verdict(self):
        result = read_json(self.run / "result.json")
        self.assertEqual({k: v for k, v in result.items() if k not in ("evidence", "demo_url")},
                         {k: v for k, v in self.result.items() if k not in ("evidence", "demo_url")})
        for name, data in self.original.items():
            self.assertEqual((self.run / name).read_bytes(), data, name)
        self.assertFalse((self.run / "evidence-operation.json").exists())

    def test_read_only_needs_no_login_worktree_or_saved_account(self):
        shutil.rmtree(self.repo); (self.run / "request.json").unlink()
        out = json.loads(self.call("evidence", "TASK-1", "--json").stdout)
        self.assertEqual(out["evidence"], self.result["evidence"])
        self.assertEqual(self.calls("gh"), [])
        self.result.pop("evidence"); write_json(self.run / "result.json", self.result)
        self.assertIn("No frontend evidence", self.call("evidence", "TASK-1").stdout)

    def test_recapture_recovers_failed_scene_without_changing_verdict(self):
        old = self.result["evidence"]["directory"]
        self.story["steps"] = [["wait", "#missing"]]; self.write_story()
        failed = self.call("evidence", "TASK-1", "--capture", "--json", check=False)
        self.assertEqual(failed.returncode, 1)
        self.assertEqual(json.loads(failed.stdout)["result"]["evidence"]["status"], "failed")
        self.story["steps"] = [["wait", "#success"]]; self.write_story()
        result = json.loads(self.call("evidence", "TASK-1", "--capture", "--json").stdout)
        self.assertEqual(result["result"]["evidence"]["status"], "captured")
        self.assertNotEqual(result["result"]["evidence"]["directory"], old)
        self.assertTrue((self.run / old / "result.png").is_file())
        self.assertEqual(self.calls("gh"), [])
        self.unchanged_verdict()

    def test_upload_survives_worktree_cleanup_and_is_idempotent(self):
        (self.root / "native").touch()
        worktree = self.root / "task-worktree"
        self.git("worktree", "add", "--detach", str(worktree), "HEAD")
        self.result["worktree"] = str(worktree); write_json(self.run / "result.json", self.result)
        self.git("worktree", "remove", str(worktree))
        browser_calls = len(self.calls("agent-browser"))
        result = json.loads(self.call("evidence", "TASK-1", "--publish", "--json").stdout)
        self.assertEqual(result["result"]["evidence"]["status"], "published")
        uploads = len([c for c in self.calls("gh") if "--attach" in c["args"]])
        self.call("evidence", "TASK-1", "--publish")
        self.assertEqual(uploads, len([c for c in self.calls("gh") if "--attach" in c["args"]]))
        self.assertEqual(browser_calls, len(self.calls("agent-browser")))
        self.unchanged_verdict()
        self.assertIn("cleaned up", self.call("evidence", "TASK-1", "--capture", check=False).stderr)

    def test_saved_custom_account_is_restored_and_conflicting_owner_refused(self):
        self.request.update(account="teammate", account_paths={k: str(self.root / "custom ' accounts" / k)
            for k in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "GH_CONFIG_DIR")})
        write_json(self.run / "request.json", self.request)
        self.env.update(HARNESS_OWNER="other", GH_CONFIG_DIR="/wrong", GH_TOKEN="ambient-fixture")
        (self.root / "native").touch()
        self.call("evidence", "TASK-1", "--publish")
        for call in self.calls("gh"):
            self.assertEqual(call["account"]["HARNESS_OWNER"], "teammate")
            self.assertIsNone(call["account"]["GH_TOKEN"])
            for key, value in self.request["account_paths"].items():
                self.assertEqual(call["account"][key], value)
        out = self.call("evidence", "TASK-1", "--capture", "--owner", "other", check=False)
        self.assertIn("pinned to account", out.stderr)

    def test_native_account_removes_station_overrides(self):
        self.env.update(HARNESS_OWNER="other", GH_CONFIG_DIR="/wrong", CODEX_HOME="/wrong",
                        CLAUDE_CONFIG_DIR="/wrong", GH_TOKEN="ambient-fixture")
        self.call("evidence", "TASK-1", "--capture")
        for key in ("GH_CONFIG_DIR", "CODEX_HOME", "CLAUDE_CONFIG_DIR"):
            self.assertIsNone(self.calls("agent-browser")[-1]["account"][key])
        self.assertEqual(self.calls("agent-browser")[-1]["account"]["HARNESS_OWNER"], "")
        self.assertIsNone(self.calls("agent-browser")[-1]["account"]["GH_TOKEN"])

    def test_expired_login_keeps_capture_and_gives_saved_account_repair(self):
        (self.root / "gh-expired").touch(); (self.root / "native").touch()
        self.env["DISPATCH_REMOTE_HOST"] = "mini"
        result = self.call("evidence", "TASK-1", "--capture", "--publish", "--json", check=False)
        self.assertEqual(result.returncode, 3, result.stderr)
        evidence = json.loads(result.stdout)["result"]["evidence"]
        self.assertEqual(evidence["status"], "publish_failed")
        self.assertIn("dispatch login gh --for-run TASK-1 --on mini", evidence["action"])
        self.assertIn("dispatch resume TASK-1 --on mini", evidence["action"])
        count = len(self.calls("agent-browser")); (self.root / "gh-expired").unlink()
        self.call("evidence", "TASK-1", "--publish")
        self.assertEqual(count, len(self.calls("agent-browser")))
        self.assertNotIn("action", read_json(self.run / "evidence.json"))
        self.unchanged_verdict()

    def test_no_publish_is_pinned_locally_and_across_remote_calls(self):
        self.request["publish"] = False; write_json(self.run / "request.json", self.request)
        self.assertIn("disabled", self.call("evidence", "TASK-1", "--publish", check=False).stderr)
        self.call("evidence", "TASK-1", "--capture")
        self.request["publish"] = True; write_json(self.run / "request.json", self.request)
        self.env["HARNESS_PUBLISH"] = "0"
        for extra in ([], ["--on", "mini"]):
            self.assertIn("disabled", self.call("evidence", "TASK-1", "--publish", *extra, check=False).stderr)
        self.assertEqual(self.calls("gh"), [])

    def test_no_pr_and_wrong_host_do_not_contact_github(self):
        self.result["pr_url"] = ""; write_json(self.run / "result.json", self.result)
        self.assertIn("no existing PR", self.call("evidence", "TASK-1", "--publish", check=False).stderr)
        self.request["host"] = "another-machine"; write_json(self.run / "request.json", self.request)
        self.assertIn("execution host", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
        self.assertEqual(self.calls("gh"), [])

    def test_changed_commit_and_stale_result_cannot_recapture(self):
        (self.repo / "index.html").write_text("new code")
        self.assertIn("worktree changed", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
        self.git("add", "."); self.git("commit", "-qm", "revised")
        self.assertIn("worktree changed", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
        write_json(self.run / "launch.json", {"started": time.time() + 10})
        self.assertIn("completed", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
        self.unchanged_verdict()

    def test_invalid_media_and_directory_never_upload_or_write_elsewhere(self):
        path = self.run / self.result["evidence"]["artifacts"][0]["path"]
        path.write_bytes(b"modified")
        result = self.call("evidence", "TASK-1", "--publish", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("--attach" in c["args"] for c in self.calls("gh")))
        manifest = read_json(self.run / "evidence.json"); manifest["directory"] = str(self.root)
        write_json(self.run / "evidence.json", manifest)
        self.assertIn("outside", self.call("evidence", "TASK-1", "--publish", check=False).stderr)
        self.assertFalse((self.root / "manifest.json").exists())

    def test_wrong_pr_head_does_not_edit_body(self):
        (self.root / "wrong-head").touch()
        body = (self.root / "body").read_text()
        result = self.call("evidence", "TASK-1", "--publish", "--json", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PR head differs", json.loads(result.stdout)["result"]["evidence"]["reason"])
        self.assertEqual(body, (self.root / "body").read_text())
        self.unchanged_verdict()

    def test_partial_upload_retry_replaces_the_evidence_block(self):
        (self.root / "native").touch(); (self.root / "partial-upload").touch()
        self.story["video"] = True; self.write_story()
        self.assertEqual(self.call("evidence", "TASK-1", "--capture", "--publish", check=False).returncode, 1)
        (self.root / "partial-upload").unlink()
        self.call("evidence", "TASK-1", "--publish")
        body = (self.root / "body").read_text()
        self.assertEqual(body.count(demo_test.demo.START), 1)
        self.assertEqual(body.count("https://github.com/user-attachments/"), 2)
        self.assertNotIn(str(self.run), body)
        self.assertIn("Keep this review note.", body)
        self.unchanged_verdict()

    def test_repaired_login_can_retry_a_manifest_with_existing_urls(self):
        (self.root / "native").touch()
        self.call("evidence", "TASK-1", "--publish")
        (self.root / "gh-expired").touch()
        self.assertEqual(self.call("evidence", "TASK-1", "--publish", check=False).returncode, 3)
        (self.root / "gh-expired").unlink()
        self.call("evidence", "TASK-1", "--publish")
        self.assertEqual(read_json(self.run / "evidence.json")["status"], "published")
        self.assertEqual((self.root / "body").read_text().count(demo_test.demo.START), 1)
        self.unchanged_verdict()

    def test_interrupted_upload_is_not_reported_as_published_and_can_retry(self):
        (self.root / "native").touch(); (self.root / "hold-upload").touch()
        proc = subprocess.Popen([sys.executable, str(self.runtime / "lib/dispatch_cli.py"),
            "evidence", "TASK-1", "--publish"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_IGN))
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any("--attach" in c["args"] for c in self.calls("gh")):
                    break
                time.sleep(.05)
            operation = read_json(self.run / "evidence-operation.json")
            self.assertEqual(operation.get("action"), "uploading")
            os.kill(operation["pid"], signal.SIGINT)
            proc.communicate(timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertEqual(read_json(self.run / "evidence.json")["status"], "publish_failed")
            self.unchanged_verdict()
        finally:
            (self.root / "hold-upload").unlink(missing_ok=True)
            if proc.poll() is None:
                proc.terminate(); proc.communicate(timeout=10)
        self.call("evidence", "TASK-1", "--publish")
        self.assertEqual(read_json(self.run / "evidence.json")["status"], "published")

    def test_lock_blocks_duplicates_and_interruption_cleans_owned_processes(self):
        with run_lock(self.run):
            self.assertIn("already running", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
        (self.root / "hold-browser").touch()
        proc = subprocess.Popen([sys.executable, str(self.runtime / "lib/dispatch_cli.py"),
            "evidence", "TASK-1", "--capture"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(c["args"][-2:] == ["wait", "#success"] for c in self.calls("agent-browser")[5:]):
                    break
                time.sleep(.05)
            operation = read_json(self.run / "evidence-operation.json")
            self.assertIn("pid", operation)
            status = json.loads(self.call("status", "TASK-1", "--json").stdout)
            self.assertEqual(status["state"], "running")
            self.assertIn("frontend evidence", status["stage"])
            self.assertIn("already running", self.call("evidence", "TASK-1", "--capture", check=False).stderr)
            os.kill(operation["pid"], signal.SIGHUP)
            proc.communicate(timeout=10)
            self.assertNotEqual(proc.returncode, 0)
            self.assertTrue(demo_test.demo.port_available(self.port))
            self.unchanged_verdict()
        finally:
            (self.root / "hold-browser").unlink(missing_ok=True)
            if proc.poll() is None:
                proc.terminate(); proc.communicate(timeout=10)

    def test_remote_retry_uses_noninteractive_ssh_and_saved_run(self):
        ssh = self.bin / "ssh"
        ssh.write_text('#!/usr/bin/env python3\nimport json,os,subprocess,sys\n'
            'open(os.environ["DEMO_TEST_ROOT"]+"/ssh-args","w").write(json.dumps(sys.argv))\n'
            'sys.exit(subprocess.run(["bash","-c",sys.argv[-1]]).returncode)\n')
        ssh.chmod(0o755)
        self.call("evidence", "TASK-1", "--capture", "--on", "mini", "--remote-harness", str(self.runtime))
        argv = json.loads((self.root / "ssh-args").read_text())
        self.assertIn("BatchMode=yes", argv)
        self.assertNotIn("-t", argv)
        self.assertIn("DISPATCH_REMOTE_HOST=mini", argv[-1])
        self.assertEqual(read_json(self.run / "result.json")["evidence"]["status"], "captured")
        self.env['HARNESS_PUBLISH'] = '0'
        result = self.call('resume', 'TASK-1', '--on', 'mini', '--remote-harness', str(self.runtime), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publishing is disabled', result.stderr)
        self.assertEqual(self.calls('gh'), [])
        self.unchanged_verdict()

    def test_resume_chooses_capture_then_publication_without_changing_code(self):
        (self.root / 'native').touch()
        self.result['evidence'].update(status='failed', artifacts=[])
        write_json(self.run / 'result.json', self.result)
        write_json(self.run / 'evidence.json', self.result['evidence'])
        self.call('resume', 'TASK-1')
        self.assertEqual(read_json(self.run / 'result.json')['evidence']['status'], 'published')
        self.unchanged_verdict()
        count = len(self.calls('agent-browser'))
        self.call('resume', 'TASK-1')
        self.assertEqual(count, len(self.calls('agent-browser')))

    def test_resume_uploads_existing_capture_and_preserves_local_only_runs(self):
        (self.root / 'native').touch()
        count = len(self.calls('agent-browser'))
        self.call('resume', 'TASK-1')
        self.assertEqual(count, len(self.calls('agent-browser')))
        self.assertEqual(read_json(self.run / 'result.json')['evidence']['status'], 'published')
        self.request['publish'] = False; write_json(self.run / 'request.json', self.request)
        self.result['status'] = 'ready_local'; write_json(self.run / 'result.json', self.result)
        uploads = len(self.calls('gh'))
        self.call('resume', 'TASK-1')
        self.assertEqual(uploads, len(self.calls('gh')))
        self.assertEqual(count, len(self.calls('agent-browser')))


if __name__ == "__main__":
    class GateResult(unittest.TextTestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            print('  ok   ' + test._testMethodName, flush=True)
    unittest.main(verbosity=2, testRunner=unittest.TextTestRunner(resultclass=GateResult, verbosity=2))
