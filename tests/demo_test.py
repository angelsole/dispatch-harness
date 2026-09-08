import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import demo

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ZkAAAAASUVORK5CYII=")
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys
root=pathlib.Path(os.environ['DEMO_TEST_ROOT'])
args=sys.argv[1:]; name=pathlib.Path(sys.argv[0]).name
with (root/'calls').open('a') as f:
    f.write(json.dumps({'name':name,'args':args,'env':{k:v for k,v in os.environ.items() if k.startswith('AGENT_BROWSER_')}})+'\n')
if name=='agent-browser':
    a=args[4:]
    if a[0]=='screenshot': pathlib.Path(a[1]).write_bytes((root/'fixture.png').read_bytes())
    if a[:2]==['record','start']:
        (root/'video-path').write_text(a[2])
        pathlib.Path(a[2]).write_bytes(b'\0\0\0\x18ftypmp42fixture')
    if a[0]=='wait' and a[1]=='#missing': sys.exit(1)
    if a[0]=='fill' and a[1]=='#mutate': pathlib.Path('index.html').write_text('changed during recording')
elif name=='shot-scraper':
    pathlib.Path('.harness/demo.mp4').write_bytes(b'\0\0\0\x18ftypmp42fixture')
    if (root/'legacy-fails').exists(): sys.exit(1)
elif name=='ffmpeg':
    pathlib.Path(args[-1]).write_bytes((root/'fixture.png').read_bytes())
elif name=='gh':
    if args==['pr','edit','--help']:
        print('gh pr edit' + (' --attach file' if (root/'native').exists() else ''))
    elif args[:2]==['pr','view']:
        if 'body,headRefOid' in args:
            head=subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()
            print(json.dumps({'body':(root/'body').read_text(), 'headRefOid':'outdated' if (root/'wrong-head').exists() else head}))
        else: print((root/'body').read_text())
    elif args[:2]==['repo','view']: print('team/app')
    elif args[:2]==['pr','edit']:
        if (root/'upload-fails').exists(): sys.exit(1)
        body=pathlib.Path(args[args.index('--body-file')+1]).read_text()
        for i,a in enumerate(args):
            if a=='--attach':
                body=body.replace(args[i+1], 'https://github.com/user-attachments/assets/'+pathlib.Path(args[i+1]).name)
                if (root/'partial-upload').exists():
                    (root/'body').write_text(body)
                    sys.exit(1)
        (root/'body').write_text(body)
    elif args[0]=='api':
        body=next(a[6:] for a in args if a.startswith('body=@'))
        (root/'body').write_text(pathlib.Path(body).read_text())
elif name=='rclone' and (root/'upload-fails').exists(): sys.exit(1)
'''


class DemoTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dispatch-demo-")
        self.root = Path(self.tmp.name).resolve()
        self.repo, self.run, self.bin = (self.root / p for p in ("app", "run", "bin"))
        for path in (self.repo, self.run, self.bin): path.mkdir()
        self.env = patch.dict(os.environ, {"DEMO_TEST_ROOT": str(self.root),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "AGENT_BROWSER_BIN": str(self.bin / "agent-browser"),
            "SHOT_BIN": str(self.bin / "shot-scraper"), "R2_REMOTE": "", "R2_PUBLIC": ""})
        self.env.start(); self.addCleanup(self.env.stop); self.addCleanup(self.tmp.cleanup)
        for name in ("agent-browser", "gh", "shot-scraper", "ffmpeg", "rclone"):
            path = self.bin / name; path.write_text(FAKE); path.chmod(0o755)
        (self.root / "fixture.png").write_bytes(PNG)
        (self.root / "body").write_text("User's PR description.\n\nKeep this review note.\n")
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.test")
        self.git("config", "user.name", "Fixture")
        self.git("remote", "add", "origin", "https://github.com/team/app.git")
        (self.repo / "index.html").write_text("<h1 id='success'>Success</h1>")
        (self.repo / ".gitignore").write_text(".harness/\n")
        self.git("add", "."); self.git("commit", "-qm", "fixture")
        (self.repo / ".harness").mkdir()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0)); self.port = s.getsockname()[1]
        self.story = dict(server=[sys.executable, "-m", "http.server", str(self.port), "--bind", "127.0.0.1"],
                          url=f"http://127.0.0.1:{self.port}/", steps=[["wait", "#success"]])
        self.write_story()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def write_story(self):
        (self.repo / ".harness/demo.json").write_text(json.dumps(self.story))

    def capture(self):
        return demo.capture(self.run, self.repo, 2)

    def publish(self, manifest):
        return demo.publish(self.run, self.repo, "https://github.com/team/app/pull/12", manifest)

    def calls(self, name):
        return [c for c in map(json.loads, (self.root / "calls").read_text().splitlines()) if c["name"] == name]

    def test_captures_without_storage_and_cleans_server(self):
        result = self.capture()
        self.assertEqual(result["status"], "captured", result)
        self.assertEqual(result["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(result["attempt"], 2)
        self.assertEqual(len(result["artifacts"]), 1)
        self.assertTrue((self.run / result["artifacts"][0]["path"]).is_file())
        self.assertTrue(demo.port_available(self.port))
        self.assertEqual(self.calls("gh"), [])

    def test_isolated_sessions_and_config(self):
        with patch.dict(os.environ, {"AGENT_BROWSER_AUTO_CONNECT": "1", "AGENT_BROWSER_PROFILE": "personal"}):
            first = self.capture(); second = self.capture()
        calls = self.calls("agent-browser")
        self.assertTrue(all(not c["env"] for c in calls))
        self.assertEqual(len({c["args"][1] for c in calls}), 2)
        self.assertNotEqual(first["directory"], second["directory"])

    def test_busy_port_leaves_listener_alive(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", self.port)); s.listen()
            result = self.capture()
            self.assertEqual(result["status"], "failed")
            self.assertIn("busy", result["reason"])
            self.assertFalse(demo.port_available(self.port))

    def test_failed_scene_keeps_partial_media_out_of_manifest(self):
        self.story["steps"] = [["screenshot", "partial.png"], ["wait", "#missing"]]
        self.write_story(); result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["artifacts"], [])
        self.assertTrue(demo.port_available(self.port))
        self.assertEqual(self.calls("agent-browser")[-1]["args"][-1], "close")

    def test_missing_binary_explains_remedy(self):
        with patch.dict(os.environ, {"AGENT_BROWSER_BIN": "/no-such/agent-browser"}):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("install agent-browser", result["reason"])

    def test_video_and_screenshot(self):
        self.story["video"] = True; self.write_story()
        result = self.capture()
        self.assertEqual({a["kind"] for a in result["artifacts"]}, {"video", "screenshot"})

    def test_missing_ffmpeg_still_captures_screenshot(self):
        self.story["video"] = True; self.write_story()
        original = shutil.which
        with patch.object(shutil, "which", side_effect=lambda name: None if name == "ffmpeg" else original(name)):
            result = self.capture()
        self.assertEqual(result["status"], "captured")
        self.assertEqual(len(result["artifacts"]), 1)
        self.assertIn("ffmpeg", result["warnings"][0])

    def test_dirty_or_mutating_worktree_cannot_publish_evidence(self):
        (self.repo / "index.html").write_text("dirty")
        self.assertEqual(self.capture()["status"], "failed")
        self.git("checkout", "--", "index.html")
        self.story["steps"] = [["fill", "#mutate", "x"], ["wait", "#success"]]
        self.write_story(); result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("changed during", result["reason"])

    def test_native_upload_preserves_body_and_has_no_storage_dependency(self):
        (self.root / "native").touch()
        result = self.publish(self.capture())
        self.assertEqual(result["status"], "published", result)
        body = (self.root / "body").read_text()
        self.assertIn("Keep this review note.", body)
        self.assertIn("https://github.com/user-attachments/", body)
        self.assertNotIn(str(self.run), body)
        self.assertEqual(self.calls("rclone"), [])
        self.assertEqual(body.count(demo.START), 1)

    def test_older_gh_retains_capture_and_explains_missing_upload(self):
        result = self.publish(self.capture())
        self.assertEqual(result["status"], "captured")
        self.assertIn("Update GitHub CLI", result["reason"])
        self.assertNotIn(str(self.run), (self.root / "body").read_text())

    def test_rclone_fallback_uses_immutable_capture_paths(self):
        with patch.dict(os.environ, {"R2_REMOTE": "r2:bucket", "R2_PUBLIC": "https://demos.example.test"}):
            first = self.publish(self.capture()); second = self.publish(self.capture())
        self.assertEqual(first["status"], "published", first)
        self.assertNotEqual(first["artifacts"][0]["url"], second["artifacts"][0]["url"])
        self.assertEqual((self.root / "body").read_text().count(demo.START), 1)

    def test_upload_failure_is_distinct_from_capture(self):
        (self.root / "native").touch(); (self.root / "upload-fails").touch()
        result = self.publish(self.capture())
        self.assertEqual(result["status"], "publish_failed")
        self.assertTrue((self.run / result["artifacts"][0]["path"]).is_file())
        self.assertIn('publish_failed', (self.root / 'body').read_text())

    def test_storage_upload_failure_is_reported_on_the_pr(self):
        (self.root/'upload-fails').touch()
        with patch.dict(os.environ, {'R2_REMOTE':'r2:bucket','R2_PUBLIC':'https://demos.example.test'}):
            result = self.publish(self.capture())
        self.assertEqual(result['status'], 'publish_failed')
        self.assertIn('publish_failed', (self.root/'body').read_text())

    def test_pr_head_must_match_and_repeat_publish_is_idempotent(self):
        (self.root / 'native').touch()
        result = self.publish(self.capture())
        count = len([c for c in self.calls('gh') if '--attach' in c['args']])
        self.publish(result)
        self.assertEqual(count, len([c for c in self.calls('gh') if '--attach' in c['args']]))
        (self.root / 'wrong-head').touch()
        self.assertEqual(self.publish(result)['status'], 'publish_failed')
        self.assertEqual(count, len([c for c in self.calls('gh') if '--attach' in c['args']]))

    def test_partial_native_upload_keeps_successful_assets_and_reports_failure(self):
        (self.root/'native').touch(); (self.root/'partial-upload').touch()
        self.story['video'] = True; self.write_story()
        result = self.publish(self.capture())
        self.assertEqual(result['status'], 'publish_failed')
        body = (self.root/'body').read_text()
        self.assertIn('upload incomplete', body)
        self.assertIn('https://github.com/user-attachments/', body)
        self.assertNotIn(str(self.run), body)
        self.assertIn('Keep this review note.', body)

    def test_changed_commit_or_media_refuses_upload(self):
        result = self.capture()
        (self.run / result["artifacts"][0]["path"]).write_bytes(b"tampered")
        self.assertEqual(self.publish(result)["status"], "publish_failed")
        result = self.capture()
        (self.repo / "new.txt").write_text("new revision")
        self.git("add", "."); self.git("commit", "-qm", "new revision")
        self.assertIn("differs", self.publish(result)["reason"])

    def test_legacy_capture_no_longer_requires_upload_config(self):
        (self.repo / ".harness/demo.json").unlink()
        (self.repo / ".harness/demo.yml").write_text("server: []\n")
        with patch.dict(os.environ, {"DEMO_PORT": str(self.port)}):
            result = self.capture()
        self.assertEqual(result["status"], "captured", result)
        self.assertEqual(result["provider"], "shot-scraper")

    def test_legacy_scene_failure_cannot_reuse_video(self):
        (self.repo / ".harness/demo.json").unlink()
        (self.repo / ".harness/demo.yml").write_text("server: []\n")
        (self.root / "legacy-fails").touch()
        with patch.dict(os.environ, {"DEMO_PORT": str(self.port)}):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["artifacts"], [])

    def test_missing_storyboard_is_visible(self):
        (self.repo / ".harness/demo.json").unlink()
        result = self.capture()
        self.assertIn("worker wrote no", result["reason"])
        result = self.publish(result)
        self.assertEqual(result["status"], "failed")
        self.assertIn("worker wrote no", (self.root / "body").read_text())

    def test_storyboard_validation_rejects_paths_and_ambient_refs(self):
        for step in (["screenshot", "../secret.png"], ["click", "@e1"], ["eval", "1"]):
            with self.subTest(step=step), self.assertRaises(demo.DemoError):
                demo.validate_story(dict(self.story, steps=[step, ["wait", "#success"]]))


if __name__ == "__main__":
    class GateResult(unittest.TextTestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            print('  ok   ' + test._testMethodName, flush=True)
    unittest.main(verbosity=2, testRunner=unittest.TextTestRunner(resultclass=GateResult, verbosity=2))
