"""Exercise the public interface, including checkpoint recovery across processes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['DISPATCH_TEST_DATA'])
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
claude_config_path = (pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])/'.claude.json'
                     if os.environ.get('CLAUDE_CONFIG_DIR') else pathlib.Path.home()/'.claude.json')
claude_config = json.loads(claude_config_path.read_text()) if claude_config_path.is_file() else {}
def event(kind):
    with (root/'events').open('a') as out:
        out.write(json.dumps({'kind':kind, 'args':args, 'codex':os.environ.get('CODEX_HOME'),
            'claude':os.environ.get('CLAUDE_CONFIG_DIR'), 'gh':os.environ.get('GH_CONFIG_DIR'),
            'token':os.environ.get('OPENAI_API_KEY'), 'owner':os.environ.get('HARNESS_OWNER'),
            'publish':os.environ.get('HARNESS_PUBLISH'),
            'mcp':list(claude_config.get('mcpServers',{}))})+'\n')
if name == 'claude' and args[:2] == ['auth','status']:
    good = not (root/'claude-expired').exists() and claude_config.get('loggedIn',True)
    print(json.dumps({'loggedIn':good})); sys.exit(0 if good else 1)
if name == 'codex' and args[:2] == ['login','status']:
    sys.exit(1 if (root/'codex-expired').exists() else 0)
if name == 'gh':
    if args[:2] == ['auth','status']:
        sys.exit(1 if (root/'gh-expired').exists() else 0)
    event('gh')
    if args[:2] in (['pr','view'],['pr','create']): print('https://github.test/team/app/pull/1')
    sys.exit(0)
if name in ('curl','osascript','caffeinate'):
    sys.exit(0)
if name == 'codex' and (not args or args[0] != 'exec'):
    event('chat'); sys.exit(0)
if name == 'claude' and '-p' not in args:
    event('chat'); sys.exit(0)
if name == 'claude' and '--output-format' in args:
    event('implement')
    while (root/'hold-worker').exists(): time.sleep(.05)
    harness=pathlib.Path('.harness'); harness.mkdir(exist_ok=True)
    if (root/'ask-question').exists():
        (harness/'QUESTIONS.md').write_text('Which colour?')
    else:
        with pathlib.Path('feature.txt').open('a') as out: out.write('feature line\n'*30)
        if (root/'demo.json').exists():
            (harness/'demo.json').write_text((root/'demo.json').read_text())
        (harness/'implementer-notes.md').write_text('Implemented the requested change.')
        subprocess.run(['git','add','feature.txt'],check=True,stdout=subprocess.DEVNULL)
        subprocess.run(['git','commit','-qm','feat: requested change'],check=True,stdout=subprocess.DEVNULL)
    print(json.dumps({'type':'result','subtype':'success','result':'done','session_id':'test-session','num_turns':1}))
else:
    event('review')
    if not (root/'review-fails').exists():
        pathlib.Path('.harness/review-notes.md').write_text('Reviewed the committed change against the brief.')
'''


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dispatch-cli-")
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.runtime = self.home / ".claude/harness"
        self.bin = self.root / "bin"
        self.bin.mkdir(); self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("HARNESS_", "CODEX_", "CLAUDE_", "DISPATCH_", "IMPLEMENTER_", "REVIEWER_", "QM_", "GIT_", "GH_", "GITHUB_", "ANTHROPIC_", "OPENAI_"))}
        self.env.update(HOME=str(self.home), HARNESS_DIR=str(self.runtime),
            PATH=str(self.bin) + os.pathsep + os.environ['PATH'], DISPATCH_TEST_DATA=str(self.root),
            HARNESS_PREFLIGHT="off", HARNESS_NOTIFY="0", HARNESS_VERIFY="0",
            HARNESS_GATE_INTEGRITY="0", HARNESS_MAX_RESUMES="0", HARNESS_ESCALATION="off",
            HARNESS_REVIEW_MIN_SECONDS="0", HARNESS_TICKET_SYNC="0")
        for name in ("claude", "codex", "gh", "curl", "osascript", "caffeinate"):
            target = self.bin / name; target.write_text(FAKE); target.chmod(0o755)
        self.shell(["bash", str(SOURCE / "install.sh"), "--copy", "--no-statusline", "--no-pixel"])
        self.cli = str(self.home / ".local/bin/dispatch")
        self.repo = self.root / "app"
        bare = self.root / "origin.git"
        self.shell(["git", "init", "-q", "--bare", str(bare)])
        self.shell(["git", "clone", "-q", str(bare), str(self.repo)])
        for key, value in (("user.email", "test@example.test"), ("user.name", "Fixture")):
            self.git("config", key, value)
        self.git("commit", "-qm", "initial", "--allow-empty")
        self.git("branch", "-M", "main"); self.git("push", "-qu", "origin", "main")
        (self.runtime / "repos.local.sh").write_text('repo_config_local() { BASE_BRANCH=main; GATE_CMD=\'printf "gate\\n" >> "$DISPATCH_TEST_DATA/gates"; true\'; }\n')
        self.brief = self.root / "brief.md"
        self.brief.write_text("# Add feature\n\nImplement the requested change and verify it.\n")

    def tearDown(self):
        (self.root / "hold-worker").unlink(missing_ok=True)
        # Avoid deleting fixtures from underneath a failed test's live driver.
        for pidfile in (self.runtime / "runs").glob("*/driver.pid"):
            try:
                pid = int(pidfile.read_text())
                output = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
                if str(self.runtime / "run-task.sh") in output:
                    os.killpg(pid, 15)
            except (OSError, ValueError):
                pass
        self.temp.cleanup()

    def shell(self, argv, check=True, **kwargs):
        return subprocess.run(argv, env=self.env, capture_output=True, text=True, check=check, **kwargs)

    def git(self, *args):
        return self.shell(["git", "-C", str(self.repo), *args]).stdout.strip()

    def call(self, *args, check=True):
        return self.shell([self.cli, *args], check=check, cwd=self.repo)

    def run_task(self, run_id="TASK-1", *extra):
        return self.call("run", "--id", run_id, "--brief", str(self.brief), "--json", *extra, check=False)

    def wait(self, run_id="TASK-1"):
        result = self.call("wait", run_id, "--timeout", "35", "--json", check=False)
        value = json.loads(result.stdout)
        if value["state"] == "running":
            self.fail("run did not finish: " + (self.runtime / "runs" / run_id / "launcher.log").read_text()[-5000:])
        return value

    def events(self, kind):
        path = self.root / "events"
        return [e for e in map(json.loads, path.read_text().splitlines()) if e['kind'] == kind] if path.exists() else []

    def test_local_chat_only_needs_selected_login(self):
        (self.root / "claude-expired").touch(); (self.root / "gh-expired").touch()
        out = self.call("Fix checkout's `price`", "--planner", "codex")
        self.assertIn("local codex", out.stdout)
        self.assertIn("gpt-6-astra", self.events('chat')[0]['args'])
        self.assertEqual(self.events('implement'), [])

    def test_frontend_missing_storyboard_reports_capture_failure_without_failing_code(self):
        self.brief.write_text(self.brief.read_text() + '\n## Demo storyboard\nShow the feature.\n')
        self.run_task('DEMO-MISSING', '--no-publish')
        result = self.wait('DEMO-MISSING')
        self.assertEqual(result['state'], 'ready_local', result)
        evidence = result['result']['evidence']
        self.assertEqual(evidence['status'], 'failed')
        self.assertIn('worker wrote no', evidence['reason'])
        self.assertIn('frontend evidence: failed', self.call('status', 'DEMO-MISSING').stdout)

    def test_frontend_local_run_keeps_commit_bound_screenshots(self):
        import socket
        import sys
        from demo_test import FAKE, PNG
        self.brief.write_text(self.brief.read_text() + '\n## Demo storyboard\nShow the feature.\n')
        binary = self.bin/'agent-browser'; binary.write_text(FAKE); binary.chmod(0o755)
        (self.root/'fixture.png').write_bytes(PNG)
        self.env.update(DEMO_TEST_ROOT=str(self.root), AGENT_BROWSER_BIN=str(binary))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        (self.root/'demo.json').write_text(json.dumps({
            'server':[sys.executable,'-m','http.server',str(port),'--bind','127.0.0.1'],
            'url':f'http://127.0.0.1:{port}/', 'steps':[['wait','#success']]}))
        self.run_task('DEMO-LOCAL', '--no-publish')
        result = self.wait('DEMO-LOCAL')
        self.assertEqual(result['state'], 'ready_local', result)
        evidence = result['result']['evidence']
        self.assertEqual(evidence['status'], 'captured', evidence)
        head = self.shell(['git','-C',result['worktree'],'rev-parse','HEAD']).stdout.strip()
        self.assertEqual(evidence['head'], head)
        self.assertTrue((Path(result['logs'])/evidence['artifacts'][0]['path']).is_file())
        self.assertEqual(self.events('gh'), [])
        output = self.call('status', 'DEMO-LOCAL').stdout
        self.assertIn('frontend evidence: captured', output)
        self.assertIn(str(Path(result['logs']) / evidence['directory']), output)
        gates = (self.root / 'gates').read_bytes()
        models = (len(self.events('implement')), len(self.events('review')))
        updated = json.loads(self.call('evidence', 'DEMO-LOCAL', '--capture', '--json').stdout)
        self.assertEqual(updated['state'], 'ready_local')
        self.assertEqual(updated['result']['evidence']['status'], 'captured')
        self.assertNotEqual(updated['result']['evidence']['directory'], evidence['directory'])
        self.assertEqual(updated['result']['attempt'], result['result']['attempt'])
        self.assertEqual(gates, (self.root / 'gates').read_bytes())
        self.assertEqual(models, (len(self.events('implement')), len(self.events('review'))))

    def test_local_claude_profile_discovers_shared_protocol(self):
        profile = self.home / 'accounts/teammate'
        profile.mkdir(parents=True)
        self.call('Inspect checkout', '--planner', 'claude', '--owner', 'teammate')
        self.assertTrue((profile / 'claude/skills/dispatch/SKILL.md').is_file())
        self.assertTrue((profile / 'claude/skills/dispatch/references/pipeline.md').is_file())

    def test_native_claude_keeps_login_and_project_connections(self):
        (self.home / '.claude.json').write_text(json.dumps({'loggedIn':True,'mcpServers':{'linear':{}}}))
        (self.home / '.claude/.claude.json').write_text(json.dumps({'loggedIn':False}))
        self.call('Inspect checkout', '--planner', 'claude')
        event = self.events('chat')[-1]
        self.assertIsNone(event['claude'])
        self.assertEqual(event['mcp'], ['linear'])
        self.call('login', 'claude')
        event = self.events('chat')[-1]
        self.assertEqual(event['args'][:2], ['auth', 'login'])
        self.assertIsNone(event['claude'])
        self.assertEqual(event['mcp'], ['linear'])

    def test_explicit_default_claude_directory_remains_explicit(self):
        self.env['CLAUDE_CONFIG_DIR'] = str(self.home / '.claude')
        (self.home / '.claude.json').write_text(json.dumps({'loggedIn':False}))
        (self.home / '.claude/.claude.json').write_text(json.dumps({'loggedIn':True,'mcpServers':{'profile-tracker':{}}}))
        self.call('Inspect checkout', '--planner', 'claude')
        event = self.events('chat')[-1]
        self.assertEqual(event['claude'], str(self.home / '.claude'))
        self.assertEqual(event['mcp'], ['profile-tracker'])
        self.call('login', 'claude')
        self.assertEqual(self.events('chat')[-1]['claude'], str(self.home / '.claude'))
        (self.root / 'claude-expired').touch()
        out = self.call('Inspect checkout', '--planner', 'claude', check=False)
        self.assertIn('CLAUDE_CONFIG_DIR=', out.stderr)

    def test_native_run_restores_absent_account_overrides_on_resume(self):
        (self.root / 'claude-expired').touch()
        value = json.loads(self.run_task().stdout)
        self.assertEqual(value['state'], 'waiting_for_auth')
        request = json.loads((self.runtime / 'runs/TASK-1/request.json').read_text())
        self.assertEqual(request['account_paths'], {})
        self.assertIn('dispatch login claude --for-run TASK-1', value['action'])
        self.assertNotEqual(self.call('doctor', '--for-run', 'TASK-1', check=False).returncode, 0)
        self.assertNotEqual(self.call('login', 'claude', '--for-run', 'TASK-1', '--owner', 'other', check=False).returncode, 0)
        (self.root / 'claude-expired').unlink()
        self.env.update(HARNESS_OWNER='other-station', CLAUDE_CONFIG_DIR=str(self.root/'other-claude'),
                        CODEX_HOME=str(self.root/'other-codex'), GH_CONFIG_DIR=str(self.root/'other-gh'))
        self.call('login', 'claude', '--for-run', 'TASK-1')
        self.assertIsNone(self.events('chat')[-1]['claude'])
        self.call('resume', 'TASK-1')
        self.assertEqual(self.wait()['state'], 'ready')
        implementer = self.events('implement')[0]
        self.assertIsNone(implementer['claude'])
        self.assertIsNone(implementer['gh'])
        self.assertEqual(implementer['owner'], '')

    def test_legacy_request_keeps_explicit_default_account_paths(self):
        (self.root / 'claude-expired').touch()
        self.run_task()
        path = self.runtime / 'runs/TASK-1/request.json'
        request = json.loads(path.read_text())
        request['account_paths'] = {key:str(self.home / suffix) for key,suffix in
                                   (('CLAUDE_CONFIG_DIR','.claude'),('CODEX_HOME','.codex'),('GH_CONFIG_DIR','.config/gh'))}
        path.write_text(json.dumps(request))
        (self.root / 'claude-expired').unlink()
        self.call('login', 'claude', '--for-run', 'TASK-1')
        self.assertEqual(self.events('chat')[-1]['claude'], str(self.home / '.claude'))
        self.call('resume', 'TASK-1')
        self.assertEqual(self.wait()['state'], 'ready')
        self.assertEqual(self.events('implement')[0]['claude'], str(self.home / '.claude'))

    def test_hands_off_is_explicit_for_each_planner(self):
        flags = {'codex': '--dangerously-bypass-approvals-and-sandbox',
                 'claude': '--dangerously-skip-permissions'}
        for provider, flag in flags.items():
            with self.subTest(provider=provider):
                normal = self.call('Inspect checkout', '--planner', provider)
                self.assertIn('permissions: CLI defaults', normal.stdout)
                self.assertFalse(set(flags.values()).intersection(self.events('chat')[-1]['args']))
                out = self.call('Fix checkout', '--planner', provider, '--hands-off', '--no-publish')
                event = self.events('chat')[-1]
                self.assertIn(flag, event['args'])
                self.assertEqual(len(set(flags.values()).intersection(event['args'])), 1)
                self.assertIn('permissions: hands-off', out.stdout)
                self.assertEqual(event['publish'], '0')
                self.assertIn('--no-publish', event['args'][-1])
                self.assertIn("this task's authorized scope", event['args'][-1])
                self.assertEqual(self.events('implement'), [])

    def test_hands_off_does_not_skip_login_or_apply_to_background_commands(self):
        for provider in ('codex', 'claude'):
            with self.subTest(provider=provider):
                (self.root / (provider + '-expired')).touch()
                out = self.call('Fix checkout', '--planner', provider, '--hands-off', check=False)
                self.assertNotEqual(out.returncode, 0)
                self.assertIn(provider + ' login is unavailable', out.stderr)
        self.assertEqual(self.events('chat'), [])
        for command in ('run', 'resume', 'status', 'wait', 'doctor', 'stations', 'login', 'init'):
            with self.subTest(command=command):
                out = self.call(command, '--hands-off', '--on', 'mini', check=False)
                self.assertNotEqual(out.returncode, 0)
                self.assertIn('--hands-off applies to chat or station', out.stderr)
        self.assertEqual(list((self.runtime / 'runs').glob('*')), [])

    def test_hands_off_survives_ssh_and_station_forwarding(self):
        remote_home = self.root / 'remote home'
        remote_runtime = remote_home / '.claude/harness'
        remote_runtime.parent.mkdir(parents=True)
        shutil.copytree(self.runtime, remote_runtime)
        script = self.bin / 'ssh'
        script.write_text('#!/usr/bin/env python3\nimport os, subprocess, sys\n'
                          'env=dict(os.environ); env.pop("HARNESS_DIR",None)\n'
                          f'env["HOME"]={str(remote_home)!r}\n'
                          'sys.exit(subprocess.run(["bash","-c",sys.argv[-1]],env=env).returncode)\n')
        script.chmod(0o755)
        (remote_home / 'accounts/teammate').mkdir(parents=True)
        for provider, flag in (('codex', '--dangerously-bypass-approvals-and-sandbox'),
                               ('claude', '--dangerously-skip-permissions')):
            with self.subTest(provider=provider):
                self.call("Fix checkout's price", '--planner', provider, '--hands-off',
                          '--on', 'mini', '--owner', 'teammate')
                event = self.events('chat')[-1]
                self.assertIn(flag, event['args'])
                self.assertIn("Fix checkout's price", event['args'][-1])
                self.assertEqual(event['owner'], 'teammate')
                self.assertEqual(event['codex'], str(remote_home / 'accounts/teammate/codex'))
        # The actual SSH-to-tmux launch is covered by station.test.sh. Here
        # observe the Python CLI's handoff to station.sh on both execution hosts.
        for runtime in (self.runtime, remote_runtime):
            (runtime / 'station.sh').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n')
        for extra in ([], ['--on', 'mini', '--owner', 'teammate']):
            out = self.call('station', '--planner', 'claude', '--model', 'fable', '--hands-off', *extra)
            self.assertIn('--hands-off', out.stdout.splitlines())
            self.assertIn('fable', out.stdout.splitlines())

    def test_no_publish_chat_carries_constraint_into_task_submission(self):
        self.call('Fix checkout', '--no-publish')
        event = self.events('chat')[0]
        self.assertEqual(event['publish'], '0')
        self.assertIn('--no-publish', event['args'][-1])
        self.env['HARNESS_PUBLISH'] = '0'
        self.run_task(); self.assertEqual(self.wait()['state'], 'ready_local')
        self.assertEqual(self.events('gh'), [])
        self.assertNotEqual(self.call('resume', 'TASK-1', '--no-publish', check=False).returncode, 0)

    def test_reviewed_local_branch_without_github(self):
        (self.root / "gh-expired").touch()
        self.assertEqual(self.run_task("TASK-1", "--no-publish").returncode, 0)
        value = self.wait()
        self.assertEqual(value['state'], 'ready_local', value)
        self.assertEqual(len(self.events('implement')), 1)
        self.assertGreaterEqual(len(self.events('review')), 1)
        self.assertEqual(self.events('gh'), [])
        self.assertEqual(self.git('branch', '--show-current'), 'main')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.call('resume', 'TASK-1')
        self.assertEqual(len(self.events('implement')), 1)
        cleanup = self.shell(['bash', str(self.runtime / 'cleanup.sh'), 'TASK-1'], check=False)
        self.assertNotEqual(cleanup.returncode, 0)
        self.assertTrue(Path(value['worktree']).is_dir())

    def test_auth_repair_resumes_publication_without_models_or_gate(self):
        self.env.update(HARNESS_VERIFY='1', HARNESS_VERIFY_PYTHON=shutil.which('python3'))
        (self.runtime / 'verifier-api-key').write_text('fixture-only')
        (self.runtime / 'verify.py').write_text(
            'import json,os,pathlib,sys\n'
            'root=pathlib.Path(os.environ["DISPATCH_TEST_DATA"])\n'
            'with (root/"verifies").open("a") as out: out.write("verify\\n")\n'
            '(pathlib.Path(sys.argv[1])/"verify.json").write_text(json.dumps({"score":0.9}))\n')
        (self.root / "gh-expired").touch()
        self.assertEqual(self.run_task().returncode, 0)
        value = self.wait()
        self.assertEqual(value['state'], 'waiting_for_auth', value)
        self.assertEqual(value['checkpoint'], 'validated', value)
        gates = (self.root / 'gates').read_text()
        reviews = len(self.events('review'))
        (self.root / "gh-expired").unlink()
        (self.root / "claude-expired").touch(); (self.root / "codex-expired").touch()
        self.call('resume', 'TASK-1')
        value = self.wait()
        self.assertEqual(value['state'], 'ready', value)
        self.assertEqual(len(self.events('implement')), 1)
        self.assertEqual(len(self.events('review')), reviews)
        self.assertEqual((self.root / 'gates').read_text(), gates)
        self.assertEqual((self.root / 'verifies').read_text(), 'verify\n')
        self.assertEqual(json.loads((self.runtime / 'runs/TASK-1/verify.json').read_text())['score'], 0.9)

    def test_changed_brief_invalidates_checkpoint(self):
        (self.root / "gh-expired").touch(); self.run_task(); self.wait()
        reviews = len(self.events('review'))
        self.brief.write_text('# Revised feature\nDifferent acceptance criteria.\n')
        self.call('resume', 'TASK-1', '--brief', str(self.brief)); self.wait()
        self.assertEqual(len(self.events('implement')), 2)
        self.assertGreater(len(self.events('review')), reviews)

    def test_changed_base_invalidates_checkpoint(self):
        (self.root / "gh-expired").touch(); self.run_task(); self.wait()
        (self.repo / 'upstream.txt').write_text('upstream change')
        self.git('add', 'upstream.txt'); self.git('commit', '-qm', 'upstream'); self.git('push', '-q')
        self.call('resume', 'TASK-1'); self.wait()
        self.assertEqual(len(self.events('implement')), 2)

    def test_changed_specs_invalidate_checkpoint(self):
        (self.root / "gh-expired").touch(); self.run_task(); self.wait()
        specs = self.runtime / 'runs/TASK-1/specs'
        specs.mkdir(); (specs / 'contract.md').write_text('Changed contract')
        self.call('resume', 'TASK-1'); self.wait()
        self.assertEqual(len(self.events('implement')), 2)

    def test_changed_gate_invalidates_checkpoint(self):
        (self.root / "gh-expired").touch(); self.run_task(); self.wait()
        config = self.runtime / 'repos.local.sh'
        config.write_text(config.read_text().replace('true', 'test -f feature.txt'))
        self.call('resume', 'TASK-1'); self.wait()
        self.assertEqual(len(self.events('implement')), 2)

    def test_custom_account_repair_and_resume_keep_same_profile(self):
        accounts = self.root / "custom ' accounts"
        (accounts / 'teammate').mkdir(parents=True)
        (self.root / 'claude-expired').touch()
        result = self.run_task('TASK-1', '--owner', 'teammate', '--accounts-dir', str(accounts))
        value = json.loads(result.stdout)
        self.assertIn('--for-run TASK-1', value['action'])
        (self.root / 'claude-expired').unlink()
        self.call('login', 'claude', '--for-run', 'TASK-1')
        self.assertEqual(self.events('chat')[-1]['claude'], str(accounts / 'teammate/claude'))
        self.call('resume', 'TASK-1'); self.wait()
        self.assertEqual(self.events('implement')[0]['claude'], str(accounts / 'teammate/claude'))
        self.assertNotEqual(self.call('resume', 'TASK-1', '--owner', 'someoneelse', check=False).returncode, 0)

    def test_review_failure_resumes_after_implementation_and_gate(self):
        (self.root / "review-fails").touch(); self.run_task(); first = self.wait()
        self.assertEqual(first['state'], 'review_failed', first)
        gates = (self.root / 'gates').read_text()
        (self.root / "review-fails").unlink()
        self.call('resume', 'TASK-1'); value = self.wait()
        self.assertEqual(value['state'], 'ready', value)
        self.assertEqual(len(self.events('implement')), 1)
        self.assertEqual((self.root / 'gates').read_text(), gates)

    def test_saved_task_survives_missing_implementer_login(self):
        (self.root / 'claude-expired').touch()
        result = self.run_task()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(json.loads(result.stdout)['state'], 'waiting_for_auth')
        (self.root / 'claude-expired').unlink()
        self.call('resume', 'TASK-1'); self.assertEqual(self.wait()['state'], 'ready')

    def test_account_pinned_and_credentials_not_serialized(self):
        account = self.home / 'accounts/teammate'
        account.mkdir(parents=True)
        self.env['OPENAI_API_KEY'] = 'ambient-secret-do-not-copy'
        self.run_task('TASK-1', '--owner', 'teammate', '--no-publish'); self.wait()
        event = self.events('implement')[0]
        self.assertEqual(event['owner'], 'teammate')
        self.assertIsNone(event['token'])
        self.assertEqual(event['claude'], str(account / 'claude'))
        request = (self.runtime / 'runs/TASK-1/request.json').read_text()
        self.assertNotIn('ambient-secret', request)
        checkpoint = (self.runtime / 'runs/TASK-1/checkpoint.json').read_text()
        self.assertNotIn(str(account), checkpoint)

    def test_duplicate_start_and_live_resume_do_not_duplicate_work(self):
        (self.root / 'hold-worker').touch()
        self.assertEqual(self.run_task().returncode, 0)
        self.assertNotEqual(self.run_task().returncode, 0)
        self.call('resume', 'TASK-1')
        (self.root / 'hold-worker').unlink(); self.wait()
        self.assertEqual(len(self.events('implement')), 1)

    def test_needs_input_requires_updated_brief(self):
        (self.root / 'ask-question').touch(); self.run_task()
        self.assertEqual(self.wait()['state'], 'needs_input')
        self.assertNotEqual(self.call('resume', 'TASK-1', check=False).returncode, 0)
        self.assertEqual(len(self.events('implement')), 1)

    def test_invalid_run_id_does_not_escape_runtime(self):
        result = self.run_task('../escape')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.runtime / 'escape').exists())

    def test_remote_arguments_and_brief_are_data(self):
        remote_home = self.root / 'remote home'
        remote_runtime = remote_home / '.claude/harness'
        remote_runtime.parent.mkdir(parents=True)
        shutil.copytree(self.runtime, remote_runtime)
        script = self.bin / 'ssh'
        script.write_text('#!/usr/bin/env python3\nimport os, subprocess, sys\n'
                          'env=dict(os.environ); env.pop("HARNESS_DIR",None)\n'
                          f'env["HOME"]={str(remote_home)!r}\n'
                          'sys.exit(subprocess.run(["bash","-c",sys.argv[-1]],env=env).returncode)\n')
        script.chmod(0o755)
        self.brief.write_text("# Quoted ' task\n$(touch NEVER-RUN) `touch NEVER-RUN`\n")
        # Simulate a task started with an explicitly selected remote profile.
        self.env['CLAUDE_CONFIG_DIR'] = str(remote_home / '.claude')
        (self.root / 'gh-expired').touch()
        result = self.call('run', '--on', 'mini', '--repo', str(self.repo), '--brief', str(self.brief),
                           '--id', 'REMOTE-1', '--json')
        self.assertEqual(json.loads(result.stdout)['state'], 'running')
        value = json.loads(self.call('wait', 'REMOTE-1', '--on', 'mini', '--timeout', '35', '--json').stdout)
        self.assertEqual(value['state'], 'waiting_for_auth', value)
        self.assertIn('dispatch login gh --for-run REMOTE-1 --on mini', value['action'])
        self.assertIn('dispatch resume REMOTE-1 --on mini', value['action'])
        (self.root / 'gh-expired').unlink()
        self.env['CLAUDE_CONFIG_DIR'] = str(self.home / '.claude')
        self.call('login', 'gh', '--for-run', 'REMOTE-1', '--on', 'mini')
        self.assertEqual(self.events('gh')[-1]['claude'], str(remote_home / '.claude'))
        self.call('resume', 'REMOTE-1', '--on', 'mini')
        value = json.loads(self.call('wait', 'REMOTE-1', '--on', 'mini', '--timeout', '35', '--json').stdout)
        self.assertEqual(value['state'], 'ready', value)
        self.assertEqual((remote_runtime / 'runs/REMOTE-1/brief.md').read_text(), self.brief.read_text())
        self.assertFalse((self.repo / 'NEVER-RUN').exists())


if __name__ == '__main__':
    class GateResult(unittest.TextTestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            print('  ok   ' + test._testMethodName, flush=True)
    unittest.main(verbosity=2, testRunner=unittest.TextTestRunner(resultclass=GateResult, verbosity=2))
