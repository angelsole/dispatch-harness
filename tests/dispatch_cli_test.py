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
            'publish':os.environ.get('HARNESS_PUBLISH'), 'oauth':os.environ.get('CLAUDE_CODE_OAUTH_TOKEN'),
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
        # Seats are OS users, so the fixtures fake the two binaries that talk to
        # the account database. `id` answers only for names registered through
        # self.seat() and delegates everything else to the real binary; `sudo`
        # replays env_reset (empty environment + the VAR=value pairs from the
        # command line + HOME from the fixture seat homes) and logs each
        # crossing. FAKE_SUDO_KEEP carries fixture plumbing a real sudoers file
        # would never see.
        (self.root / "seats").write_text("")
        (self.root / "seat-homes").mkdir()
        self.env.update(FAKE_SEAT_HOMES=str(self.root / "seat-homes"),
                        FAKE_SUDO_KEEP="DISPATCH_TEST_DATA DISPATCH_DETACHED",
                        FAKE_SUDO_LOG=str(self.root / "sudo.log"))
        target = self.bin / "id"
        target.write_text('#!/usr/bin/env python3\n'
                          'import os, pathlib, sys\n'
                          'seats = set((pathlib.Path(os.environ["FAKE_SEAT_HOMES"]).parent / "seats").read_text().split())\n'
                          'args = sys.argv[1:]\n'
                          'if len(args) == 2 and args[0] == "-u" and args[1] in seats:\n'
                          '    print(2000 + sorted(seats).index(args[1])); sys.exit(0)\n'
                          'os.execv("/usr/bin/id", ["id"] + args)\n')
        target.chmod(0o755)
        target = self.bin / "sudo"
        target.write_text('#!/usr/bin/env python3\n'
                          'import json, os, pathlib, re, sys\n'
                          'args = sys.argv[1:]; seat = None; pairs = []; i = 0\n'
                          'while i < len(args):\n'
                          '    if args[i] == "-u":\n'
                          '        seat = args[i + 1]; i += 2; continue\n'
                          '    if args[i].startswith("-"):\n'
                          '        i += 1; continue\n'
                          '    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", args[i]):\n'
                          '        pairs.append(args[i]); i += 1; continue\n'
                          '    break\n'
                          'command = args[i:]\n'
                          'if seat is None or not command:\n'
                          '    print("fake sudo: unsupported invocation: " + " ".join(sys.argv[1:]), file=sys.stderr); sys.exit(1)\n'
                          'env = {name: os.environ[name] for name in os.environ.get("FAKE_SUDO_KEEP", "").split()\n'
                          '       if name in os.environ}\n'
                          'env.update(dict(pair.split("=", 1) for pair in pairs))\n'
                          'env["HOME"] = str(pathlib.Path(os.environ["FAKE_SEAT_HOMES"]) / seat)\n'
                          'env["USER"] = env["LOGNAME"] = seat\n'
                          'env.setdefault("TERM", os.environ.get("TERM", "dumb"))\n'
                          'with open(os.environ["FAKE_SUDO_LOG"], "a") as out:\n'
                          '    out.write(json.dumps({"seat": seat, "pairs": pairs, "argv": command}) + "\\n")\n'
                          'os.execvpe(command[0], command, env)\n')
        target.chmod(0o755)
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

    def console(self, operation, body=None):
        return json.loads(self.shell(['python3', str(self.runtime / 'lib/dispatch_actions.py'), operation],
                                    input=json.dumps(body or {})).stdout)

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

    def seat(self, name, claude=True):
        """Register an OS-user seat and give it credential dirs in its own home.

        A seat without a claude dir is one whose probe answers 'missing' — the
        state a blocked run waits on.
        """
        seats = self.root / "seats"
        seats.write_text(seats.read_text() + name + "\n")
        home = self.root / "seat-homes" / name
        directories = [".codex", ".config/gh"] + ([".claude"] if claude else [])
        for directory in directories:
            (home / directory).mkdir(parents=True, exist_ok=True)
        return home

    def sudo_log(self):
        path = self.root / "sudo.log"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_local_chat_only_needs_selected_login(self):
        (self.root / "claude-expired").touch(); (self.root / "gh-expired").touch()
        out = self.call("Fix checkout's `price`", "--planner", "codex")
        self.assertIn("local codex", out.stdout)
        self.assertIn("gpt-6-astra", self.events('chat')[0]['args'])
        self.assertEqual(self.events('implement'), [])

    def test_ui_launches_private_local_console_without_starting_work(self):
        import re
        import selectors
        import urllib.error
        import urllib.request
        ledger = self.runtime / 'wall-city.jsonl'
        old_city = json.dumps(dict(id='OLD-1', epoch=1)) + '\n'
        ledger.write_text(old_city)
        self.env.update(WALL_INGEST_TOKEN='shared-wall-token', WALL_CITY=str(ledger))
        with subprocess.Popen([self.cli, 'ui'], env=self.env, cwd=self.repo,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            try:
                output = b''
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 10
                    while b'#control=' not in output and time.monotonic() < deadline:
                        if selector.select(timeout=.1):
                            chunk = os.read(process.stdout.fileno(), 4096)
                            if not chunk:
                                break
                            output += chunk
                match = re.search(rb'(http://127\.0\.0\.1:\d+)/console#control=([a-f0-9]{64})', output)
                self.assertIsNotNone(match, output.decode())
                origin, token = (part.decode() for part in match.groups())
                with urllib.request.urlopen(origin + '/console') as page:
                    self.assertIn(b'/console/control.js', page.read())
                    self.assertIn("frame-ancestors 'none'", page.headers['Content-Security-Policy'])
                request = urllib.request.Request(origin + '/api/control/runs',
                                                 headers={'Authorization': 'Bearer ' + token})
                with urllib.request.urlopen(request) as response:
                    self.assertEqual(json.load(response)['tasks'], [])
                with urllib.request.urlopen(origin + '/api/runs?view=console') as response:
                    self.assertEqual(json.load(response)['runs'], [])
                self.assertEqual(ledger.read_text(), old_city)
                request = urllib.request.Request(origin + '/api/ingest/stage', data=b'{}',
                                                 headers={'Authorization': 'Bearer shared-wall-token'})
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(request)
                self.assertEqual(error.exception.code, 404)
                self.assertEqual(self.events('implement'), [])
            finally:
                process.terminate()
                process.wait(timeout=5)

    def test_empty_start_bootstraps_both_planners_with_model_and_protocol(self):
        for provider, model in (('codex', 'gpt-6-astra'), ('claude', 'fable')):
            with self.subTest(provider=provider):
                self.call('--planner', provider)
                args = self.events('chat')[-1]['args']
                self.assertIn(model, args)
                self.assertIn(str(self.runtime / 'planner-skills/dispatch/SKILL.md'), args[-1])
                self.assertIn('No task has been supplied yet', args[-1])
                self.assertIn('reviewed result', args[-1])
                self.assertEqual(self.events('implement'), [])
        self.call('--planner', 'claude', '--model', 'custom-model')
        self.assertIn('custom-model', self.events('chat')[-1]['args'])

    def test_task_start_uses_same_protocol_without_losing_task_or_local_intent(self):
        task = 'Fix checkout without a tracker ticket'
        self.call(task, '--planner', 'claude', '--no-publish')
        args = self.events('chat')[-1]['args']
        self.assertIn('fable', args)
        self.assertIn(str(self.runtime / 'planner-skills/dispatch/SKILL.md'), args[-1])
        self.assertTrue(args[-1].endswith('Task: ' + task))
        self.assertIn('--no-publish', args[-1])
        self.assertNotIn('No task has been supplied yet', args[-1])

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
        storyboard = Path(result['worktree']) / '.harness/demo.json'
        original = storyboard.read_text(); storyboard.unlink()
        self.assertEqual(self.call('evidence', 'DEMO-LOCAL', '--capture', check=False).returncode, 1)
        storyboard.write_text(original)
        recovered = json.loads(self.call('resume', 'DEMO-LOCAL', '--json').stdout)
        self.assertEqual(recovered['state'], 'ready_local')
        self.assertEqual(recovered['result']['evidence']['status'], 'captured')
        self.assertEqual(models, (len(self.events('implement')), len(self.events('review'))))
        self.assertEqual(gates, (self.root / 'gates').read_bytes())

        # The console detaches evidence recovery and retains the same run lock.
        storyboard.unlink()
        self.assertEqual(self.call('evidence', 'DEMO-LOCAL', '--capture', check=False).returncode, 1)
        storyboard.write_text(original)
        task = self.console('list')['tasks'][0]
        body = dict(id=task['id'], action='resume', revision=task['revision'], operation_id='e' * 32)
        accepted = self.console('apply', body)
        self.assertEqual(accepted['state'], 'running', accepted)
        self.assertEqual(self.console('apply', body), accepted)
        recovered = self.wait('DEMO-LOCAL')
        self.assertEqual(recovered['state'], 'ready_local')
        self.assertEqual(recovered['result']['evidence']['status'], 'captured')
        self.assertEqual(models, (len(self.events('implement')), len(self.events('review'))))
        self.assertEqual(gates, (self.root / 'gates').read_bytes())

    def test_console_answer_resumes_saved_run_once(self):
        (self.root / 'ask-question').touch()
        self.run_task('QUESTION-1', '--no-publish')
        self.assertEqual(self.wait('QUESTION-1')['state'], 'needs_input')
        task = self.console('list')['tasks'][0]
        self.assertEqual(task['questions'], 'Which colour?')
        (self.root / 'ask-question').unlink()
        body = dict(id=task['id'], action='answer_resume', revision=task['revision'],
                    operation_id='a' * 32, answer='Use blue for the selected option.')
        accepted = self.console('apply', body)
        self.assertEqual(accepted['state'], 'running', accepted)
        self.assertEqual(self.console('apply', body), accepted)
        self.assertEqual(self.wait('QUESTION-1')['state'], 'ready_local')
        brief = (self.runtime / 'runs/QUESTION-1/brief.md').read_text()
        self.assertIn(self.brief.read_text(), brief)
        self.assertEqual(brief.count(body['answer']), 1)
        self.assertEqual(len(self.events('implement')), 2)
        self.assertEqual(self.events('gh'), [])

    def test_chat_links_the_shared_protocol_into_the_own_claude(self):
        self.call('Inspect checkout', '--planner', 'claude')
        skill = self.home / '.claude/skills/dispatch'
        self.assertTrue((skill / 'SKILL.md').is_file())
        self.assertTrue((skill / 'references/pipeline.md').is_file())
        # When the account's own copy is gone, chat relinks it from the shared
        # runtime — never from another account's home.
        shutil.rmtree(self.home / '.claude/skills')
        self.call('Fix checkout', '--planner', 'claude')
        self.assertTrue((skill / 'SKILL.md').is_file())
        self.assertEqual(skill.resolve(), (self.runtime / 'planner-skills/dispatch').resolve())
        self.seat('teammate')
        denied = self.call('Inspect checkout', '--planner', 'claude', '--owner', 'teammate', check=False)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn('ssh teammate@', denied.stderr)

    def test_native_claude_keeps_login_and_project_connections(self):
        (self.home / '.claude.json').write_text(json.dumps({'loggedIn':True,'mcpServers':{'linear':{}}}))
        (self.home / '.claude/.claude.json').write_text(json.dumps({'loggedIn':False}))
        self.call('Inspect checkout', '--planner', 'claude')
        event = self.events('chat')[-1]
        self.assertIsNone(event['claude'])
        self.assertEqual(event['mcp'], ['linear'])
        self.call('login', 'claude', '--browser')
        event = self.events('chat')[-1]
        self.assertEqual(event['args'][:2], ['auth', 'login'])
        self.assertIsNone(event['claude'])
        self.assertEqual(event['mcp'], ['linear'])

    def test_explicit_default_claude_directory_remains_explicit(self):
        self.env['CLAUDE_CONFIG_DIR'] = str(self.home / '.claude')
        (self.home / '.claude.json').write_text(json.dumps({'loggedIn':True,'mcpServers':{'linear':{}}}))
        (self.home / '.claude/.claude.json').write_text(json.dumps({'loggedIn':True,'mcpServers':{'profile-tracker':{}}}))
        self.call('Inspect checkout', '--planner', 'claude')
        event = self.events('chat')[-1]
        self.assertEqual(event['claude'], str(self.home / '.claude'))
        self.assertEqual(event['mcp'], ['profile-tracker'])
        # The login runs through station.sh, which clears config-directory
        # overrides: an explicit directory selects the planner's connection,
        # never whose credentials a login refreshes.
        self.call('login', 'claude', '--browser')
        login = self.events('chat')[-1]
        self.assertIsNone(login['claude'])
        self.assertEqual(login['mcp'], ['linear'])
        (self.root / 'claude-expired').touch()
        out = self.call('Inspect checkout', '--planner', 'claude', check=False)
        self.assertIn('claude login is unavailable', out.stderr)
        self.assertIn('dispatch login claude', out.stderr)

    def test_native_run_restores_saved_identity_over_ambient_owner(self):
        (self.root / 'claude-expired').touch()
        value = json.loads(self.run_task().stdout)
        self.assertEqual(value['state'], 'waiting_for_auth')
        request = json.loads((self.runtime / 'runs/TASK-1/request.json').read_text())
        self.assertEqual(request['account'], '')
        self.assertNotIn('account_paths', request)
        self.assertIn('dispatch login claude --for-run TASK-1', value['action'])
        self.assertNotEqual(self.call('doctor', '--for-run', 'TASK-1', check=False).returncode, 0)
        self.assertNotEqual(self.call('login', 'claude', '--for-run', 'TASK-1', '--owner', 'other', check=False).returncode, 0)
        (self.root / 'claude-expired').unlink()
        # A stale ambient HARNESS_OWNER names a seat for NEW runs only; this
        # run is pinned to the current account and resumes as itself.
        self.env.update(HARNESS_OWNER='other-station')
        self.call('resume', 'TASK-1')
        self.assertEqual(self.wait()['state'], 'ready')
        implementer = self.events('implement')[0]
        self.assertIsNone(implementer['claude'])
        self.assertIsNone(implementer['gh'])
        self.assertEqual(implementer['owner'], '')
        self.assertEqual(self.sudo_log(), [])

    def test_legacy_account_paths_in_a_request_are_ignored(self):
        (self.root / 'claude-expired').touch()
        self.run_task()
        path = self.runtime / 'runs/TASK-1/request.json'
        request = json.loads(path.read_text())
        request['account_paths'] = {key:str(self.home / suffix) for key,suffix in
                                   (('CLAUDE_CONFIG_DIR','.claude'),('CODEX_HOME','.codex'),('GH_CONFIG_DIR','.config/gh'))}
        path.write_text(json.dumps(request))
        (self.root / 'claude-expired').unlink()
        self.call('resume', 'TASK-1')
        self.assertEqual(self.wait()['state'], 'ready')
        # Nothing reads the old shared-account mechanism back: the run executes
        # with no re-exported config directories.
        self.assertIsNone(self.events('implement')[0]['claude'])

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
        remote_runtime = self.root / 'shared remote runtime'
        (remote_home / '.claude').mkdir(parents=True)
        shutil.copytree(self.runtime, remote_runtime)
        (remote_home / '.claude/harness-dir').write_text(str(remote_runtime) + '\n')
        script = self.bin / 'ssh'
        script.write_text('#!/usr/bin/env python3\nimport os, subprocess, sys\n'
                          'env=dict(os.environ); env.pop("HARNESS_DIR",None)\n'
                          f'env["HOME"]={str(remote_home)!r}\n'
                          'sys.exit(subprocess.run(["bash","-c",sys.argv[-1]],env=env).returncode)\n')
        script.chmod(0o755)
        self.seat('teammate')
        for provider in ('codex', 'claude'):
            with self.subTest(provider=provider):
                # An interactive planner is the account holder's own session:
                # even hands-off cannot hold it for another seat.
                out = self.call("Fix checkout's price", '--planner', provider, '--hands-off',
                                '--on', 'mini', '--owner', 'teammate', check=False)
                self.assertNotEqual(out.returncode, 0)
                self.assertIn('ssh teammate@', out.stderr)
        self.assertEqual(self.events('chat'), [])
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

    def test_seat_run_repair_points_into_the_seat_and_stays_pinned(self):
        self.seat('teammate', claude=False)
        result = self.run_task('TASK-1', '--owner', 'teammate')
        value = json.loads(result.stdout)
        self.assertEqual(value['state'], 'waiting_for_auth')
        self.assertIn('ssh teammate@', value['action'])
        self.assertIn('station.sh login claude', value['action'])
        self.assertNotIn('--for-run', value['action'])
        # The login lands inside the seat's own account; completing it from the
        # seat's side (its claude dir now exists) unblocks the saved run.
        (self.root / 'seat-homes/teammate/.claude').mkdir()
        self.call('resume', 'TASK-1')
        self.assertEqual(self.wait()['state'], 'ready')
        self.assertEqual(self.events('implement')[0]['owner'], 'teammate')
        self.assertNotEqual(self.call('resume', 'TASK-1', '--owner', 'someoneelse', check=False).returncode, 0)

    def test_cross_seat_run_requires_working_claude_auth_not_just_its_directory(self):
        self.seat('teammate')
        (self.root / 'claude-expired').touch()
        result = self.run_task('TASK-1', '--owner', 'teammate')
        value = json.loads(result.stdout)
        self.assertEqual(value['state'], 'waiting_for_auth')
        self.assertEqual(self.events('implement'), [])

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

    def test_seat_run_launches_through_sudo_with_explicit_pairs_only(self):
        home = self.seat('teammate')
        (home / '.claude/oauth-token').write_text('seat-token-never-in-argv\n')
        (home / '.claude/oauth-token').chmod(0o600)
        self.env['OPENAI_API_KEY'] = 'ambient-secret-do-not-copy'
        self.run_task('TASK-1', '--owner', 'teammate', '--no-publish'); self.wait()
        event = self.events('implement')[0]
        self.assertEqual(event['owner'], 'teammate')
        self.assertIsNone(event['token'])
        # The seat's own credentials are read inside the seat, never re-exported
        # as config directories by the launching account.
        self.assertIsNone(event['claude'])
        self.assertIsNone(event['codex'])
        self.assertIsNone(event['gh'])
        request = (self.runtime / 'runs/TASK-1/request.json').read_text()
        self.assertNotIn('ambient-secret', request)
        self.assertNotIn(str(home), request)
        launches = [entry for entry in self.sudo_log() if entry['argv'][0].endswith('run-task.sh')]
        self.assertTrue(launches)
        for entry in launches:
            self.assertEqual(entry['seat'], 'teammate')
            self.assertIn('HARNESS_OWNER=teammate', entry['pairs'])
            self.assertIn('HARNESS_DIR=' + str(self.runtime), entry['pairs'])
            # argv is ps(1)-visible: no token, no inherited secret, no config
            # directory override may ride the command line.
            for pair in entry['pairs']:
                self.assertFalse(pair.startswith(('OPENAI_API_KEY=', 'CLAUDE_CODE_OAUTH_TOKEN=',
                                                  'GH_TOKEN=', 'CLAUDE_CONFIG_DIR=', 'CODEX_HOME=',
                                                  'GH_CONFIG_DIR=')), pair)

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
        remote_runtime = self.root / 'shared remote runtime'
        (remote_home / '.claude').mkdir(parents=True)
        shutil.copytree(self.runtime, remote_runtime)
        (remote_home / '.claude/harness-dir').write_text(str(remote_runtime) + '\n')
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
        # The login runs as the account holder with ambient config-directory
        # overrides cleared: an override pointing into another home must not
        # steer whose credentials get refreshed.
        self.assertIsNone(self.events('gh')[-1]['claude'])
        self.call('resume', 'REMOTE-1', '--on', 'mini')
        value = json.loads(self.call('wait', 'REMOTE-1', '--on', 'mini', '--timeout', '35', '--json').stdout)
        self.assertEqual(value['state'], 'ready', value)
        self.assertEqual((remote_runtime / 'runs/REMOTE-1/brief.md').read_text(), self.brief.read_text())
        self.assertFalse((remote_home / '.claude/harness').exists())
        (remote_home / '.claude/harness-dir').unlink()
        value = json.loads(self.call('status', 'REMOTE-1', '--on', 'mini',
                                     '--remote-harness', str(remote_runtime), '--json').stdout)
        self.assertEqual(value['state'], 'ready', value)
        self.assertFalse((self.repo / 'NEVER-RUN').exists())


if __name__ == '__main__':
    class GateResult(unittest.TextTestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            print('  ok   ' + test._testMethodName, flush=True)
    unittest.main(verbosity=2, testRunner=unittest.TextTestRunner(resultclass=GateResult, verbosity=2))
