"""Signed session deliveries drive real fixture Dispatch runs; no live services."""
import copy
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import linear_dispatch as ld
import dispatch_cli_test as fixture
from dispatch_runs import read_json, read_text, status

ORG = '11111111-1111-4111-8111-111111111111'
APP = '22222222-2222-4222-8222-222222222222'
OAUTH = '33333333-3333-4333-8333-333333333333'
SESSION = '44444444-4444-4444-8444-444444444444'
ISSUE = '55555555-5555-4555-8555-555555555555'
USER = '66666666-6666-4666-8666-666666666666'
OTHER_USER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
TEAM = '77777777-7777-4777-8777-777777777777'
PROJECT = '88888888-8888-4888-8888-888888888888'
ISSUE_DATA = {'id': ISSUE, 'identifier': 'TEAM-1', 'title': 'Add the requested feature',
              'description': 'Implement the feature. Verify it with the existing checks.',
              'url': 'https://linear.app/example/issue/TEAM-1', 'team': {'id': TEAM, 'key': 'TEAM'},
              'project': {'id': PROJECT}, 'state': {'type': 'unstarted'}}


def config(repo):
    return {'version': 1, 'organization_id': ORG, 'app_user_id': APP,
            'routes': [{'team': 'TEAM', 'repo': str(repo), 'publish': False}]}


def delivery(body=None, *, stop=False, number=1):
    event = {'type': 'AgentSessionEvent', 'action': 'created', 'organizationId': ORG,
             'oauthClientId': OAUTH, 'appUserId': APP, 'webhookTimestamp': time.time() * 1000,
             'promptContext': '<guidance>Keep the existing public interface.</guidance>',
             'agentSession': {'id': SESSION, 'appUserId': APP, 'organizationId': ORG,
                              'creatorId': USER, 'issue': copy.deepcopy(ISSUE_DATA)}}
    if body is not None or stop:
        event['action'] = 'prompted'
        event['agentActivity'] = {'id': f'99999999-9999-4999-8999-{number:012d}', 'userId': USER,
                                  'agentSessionId': SESSION, 'content': {'type': 'prompt', 'body': body or ''}}
        if stop:
            event['agentActivity']['signal'] = 'stop'
    return event


class FakeLinear:
    def __init__(self):
        self.issue_data = copy.deepcopy(ISSUE_DATA)
        self.activities = []
        self.fail_result = False

    def issue(self, iid):
        assert iid == ISSUE
        return copy.deepcopy(self.issue_data)

    def activity(self, sid, content):
        assert sid == SESSION
        if self.fail_result and content['body'] != 'Preparing this task for Dispatch.':
            self.fail_result = False
            raise ld.DispatchError('fixture API outage')
        self.activities.append(content)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Path(self.temp.name)
        self.config = config(self.runtime)
        self.store = ld.Store(self.runtime)

    def count(self):
        with self.store.connect() as db:
            return db.execute('SELECT count(*) FROM events').fetchone()[0]

    def fake_id(self, *seats):
        """A minimal `id` that knows only the named seats; all else delegates."""
        bin = self.runtime / 'bin'
        bin.mkdir(exist_ok=True)
        (bin / 'seats').write_text('\n'.join(seats) + '\n')
        (bin / 'id').write_text('#!/usr/bin/env python3\n'
                                'import os, pathlib, sys\n'
                                'seats = set((pathlib.Path(__file__).parent / "seats").read_text().split())\n'
                                'args = sys.argv[1:]\n'
                                'if len(args) == 2 and args[0] == "-u" and args[1] in seats:\n'
                                '    print(2000); sys.exit(0)\n'
                                'os.execv("/usr/bin/id", ["id"] + args)\n')
        (bin / 'id').chmod(0o755)
        patcher = mock.patch.dict(os.environ, PATH=str(bin) + os.pathsep + os.environ.get('PATH', ''))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_durable_deduplication_uses_session_and_activity_not_delivery_timestamp(self):
        event = delivery()
        self.assertEqual(self.store.enqueue(event, self.config), 200)
        event['webhookTimestamp'] += 5000
        self.assertEqual(ld.Store(self.runtime).enqueue(event, self.config), 200)
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.store.enqueue(delivery('Yes'), self.config), 200)
        self.assertEqual(self.store.enqueue(delivery('Yes'), self.config), 200)
        self.assertEqual(self.count(), 2)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)

    def test_app_identity_does_not_confuse_public_and_internal_oauth_ids(self):
        path = self.runtime / 'config.json'
        path.write_text(json.dumps(self.config))
        loaded = ld.configuration(path)
        event = delivery(); event['oauthClientId'] = 'wall-app-client-abc123'
        self.assertEqual(self.store.enqueue(event, loaded), 200)

    def test_wrong_workspace_app_actor_team_and_payload_are_refused(self):
        for field in ('organizationId', 'appUserId'):
            event = delivery(); event[field] = USER
            self.assertEqual(self.store.enqueue(event, self.config), 403)
        self.config['allowed_users'] = [APP]
        self.assertEqual(self.store.enqueue(delivery(), self.config), 403)
        self.config.pop('allowed_users')
        event = delivery(); event['agentSession']['issue']['team']['key'] = 'OTHER'
        self.assertEqual(self.store.enqueue(event, self.config), 403)
        for field, value in (('agentSession', []), ('agentActivity', ['bad'])):
            event = delivery('yes'); event[field] = value
            self.assertEqual(self.store.enqueue(event, self.config), 400)
        event = delivery('yes'); event['agentActivity']['agentSessionId'] = USER
        self.assertEqual(self.store.enqueue(event, self.config), 400)
        self.assertEqual(self.count(), 0)

    def test_proactive_sessions_do_not_authorize_new_dispatches(self):
        for creator in (None, APP):
            event = delivery(); event['agentSession']['creatorId'] = creator
            self.assertEqual(self.store.enqueue(event, self.config), 200)
        self.assertEqual(self.count(), 0)

    def test_project_route_wins_and_ambiguity_fails(self):
        self.config['routes'].append({'team': TEAM, 'project_id': PROJECT, 'repo': '/project'})
        worker = ld.Worker(self.runtime, self.config, self.store, FakeLinear())
        self.assertEqual(worker.route(ISSUE_DATA)['repo'], '/project')
        self.config['routes'].append({'team': 'TEAM', 'project_id': PROJECT, 'repo': '/ambiguous'})
        with self.assertRaises(ld.DispatchError):
            worker.route(ISSUE_DATA)

    def test_account_mapping_validation_rejects_paths_and_fixed_owner_mix(self):
        path = self.runtime / 'config.json'
        for accounts in ([], {}, {USER: '../angel'}, {'not-a-uuid': 'angel'}):
            path.write_text(json.dumps(dict(self.config, accounts=accounts)))
            with self.assertRaises(ld.DispatchError):
                ld.configuration(path)
        self.config['accounts'] = {USER: 'teammate'}
        path.write_text(json.dumps(self.config))
        self.assertEqual(ld.configuration(path)['accounts'][USER], 'teammate')
        self.config['routes'][0]['owner'] = 'angel'
        path.write_text(json.dumps(self.config))
        with self.assertRaises(ld.DispatchError):
            ld.configuration(path)

    def test_assignee_then_parent_then_delegator_selects_station(self):
        self.config['accounts'] = {USER: 'initiator', OTHER_USER: 'assigned'}
        self.fake_id('initiator', 'assigned')
        healthy = {'claude': 'inside', 'codex': 'inside', 'gh': 'inside', 'token': 'ok'}
        self.store.enqueue(delivery(), self.config)
        worker = ld.Worker(self.runtime, self.config, self.store, FakeLinear())
        session = self.store.session(SESSION)
        issue = copy.deepcopy(ISSUE_DATA)
        with mock.patch.object(ld, 'seat_probe_state', return_value=healthy):
            self.assertEqual(worker.execution_account(worker.route(issue), issue, session), ('initiator', 'session_creator'))
            issue['parent'] = {'assignee': {'id': OTHER_USER}}
            self.assertEqual(worker.execution_account(worker.route(issue), issue, session), ('assigned', 'parent_assignee'))
            issue['assignee'] = {'id': USER}
            self.assertEqual(worker.execution_account(worker.route(issue), issue, session), ('initiator', 'assignee'))
        issue['assignee'] = {'id': PROJECT}
        with self.assertRaises(ld.AccountSelection):
            worker.execution_account(worker.route(issue), issue, session)
        # A mapped name that is not a user on this machine is the same ask.
        self.config['accounts'][PROJECT] = 'ghost'
        issue['assignee'] = {'id': PROJECT}
        with self.assertRaises(ld.AccountSelection):
            worker.execution_account(worker.route(issue), issue, session)

    def test_missing_station_asks_without_borrowing_the_operator_login(self):
        self.config['accounts'] = {USER: 'missing-station'}
        self.fake_id()
        self.store.enqueue(delivery(), self.config)
        api = FakeLinear()
        ld.Worker(self.runtime, self.config, self.store, api).step()
        self.assertEqual(api.activities[-1]['type'], 'elicitation')
        self.assertIn('needs setup', api.activities[-1]['body'])
        self.assertFalse((self.runtime / 'runs').exists())

    def test_station_alias_cannot_borrow_another_persons_credentials(self):
        self.config['accounts'] = {USER: 'teammate'}
        self.fake_id('teammate')
        self.store.enqueue(delivery(), self.config)
        api = FakeLinear()
        with mock.patch.object(ld, 'seat_probe_state',
                               return_value={'claude': 'inside', 'codex': 'outside', 'gh': 'inside'}):
            ld.Worker(self.runtime, self.config, self.store, api).step()
        self.assertEqual(api.activities[-1]['type'], 'elicitation')
        self.assertIn('outside its home', api.activities[-1]['body'])
        self.assertFalse((self.runtime / 'runs').exists())

    def test_stop_before_created_survives_restart_and_never_launches(self):
        self.assertEqual(self.store.enqueue(delivery(stop=True), self.config), 200)
        self.assertEqual(self.store.enqueue(delivery(), self.config), 200)
        api = FakeLinear()
        worker = ld.Worker(self.runtime, self.config, ld.Store(self.runtime), api)
        while worker.step():
            pass
        self.assertFalse((self.runtime / 'runs').exists())
        self.assertEqual(len(api.activities), 1)
        self.assertIn('Stopped', api.activities[0]['body'])

    def test_incomplete_task_asks_in_linear_then_can_use_the_reply(self):
        api = FakeLinear(); api.issue_data['description'] = ''
        self.store.enqueue(delivery(), self.config)
        worker = ld.Worker(self.runtime, self.config, self.store, api)
        worker.step()
        self.assertEqual(api.activities[-1]['type'], 'elicitation')
        self.assertFalse((self.runtime / 'runs').exists())

    def test_a_casual_mention_does_not_start_coding(self):
        event = delivery()
        event['agentSession']['comment'] = {'body': 'What do you think, Mini?'}
        self.store.enqueue(event, self.config)
        api = FakeLinear()
        ld.Worker(self.runtime, self.config, self.store, api).step()
        self.assertEqual(api.activities[-1]['type'], 'elicitation')
        self.assertFalse((self.runtime / 'runs').exists())

    def test_mention_on_an_already_delegated_issue_still_requires_dispatch(self):
        event = delivery()
        event['agentSession']['comment'] = {'userId': USER, 'body': 'What do you think, Mini?'}
        event['agentSession']['sourceCommentId'] = PROJECT
        self.store.enqueue(event, self.config)
        api = FakeLinear(); api.issue_data['delegate'] = {'id': APP}
        ld.Worker(self.runtime, self.config, self.store, api).step()
        self.assertEqual(api.activities[-1]['type'], 'elicitation')
        self.assertFalse((self.runtime / 'runs').exists())

    def test_failed_issue_lookup_remains_pending_for_retry(self):
        self.store.enqueue(delivery(), self.config)
        api = FakeLinear()
        api.issue = mock.Mock(side_effect=ld.LinearUnavailable('fixture outage'))
        ld.Worker(self.runtime, self.config, self.store, api).step()
        with self.store.connect() as db:
            event = db.execute('SELECT done,attempts,outcome FROM events').fetchone()
        self.assertEqual(event['done'], 0)
        self.assertEqual(event['attempts'], 1)
        self.assertIsNone(event['outcome'])


class LifecycleTests(unittest.TestCase):
    shell = fixture.DispatchTests.shell
    git = fixture.DispatchTests.git
    call = fixture.DispatchTests.call
    wait = fixture.DispatchTests.wait
    run_task = fixture.DispatchTests.run_task
    seat = fixture.DispatchTests.seat
    sudo_log = fixture.DispatchTests.sudo_log

    def setUp(self):
        fixture.DispatchTests.setUp(self)
        self.env = {k: v for k, v in self.env.items() if not k.startswith(('WALL_', 'LINEAR_'))}
        self.patch_env = mock.patch.dict(os.environ, self.env, clear=True)
        self.patch_env.start()
        self.config = config(self.repo)
        self.store = ld.Store(self.runtime)
        self.api = FakeLinear()
        self.worker = ld.Worker(self.runtime, self.config, self.store, self.api)
        self.run_id = 'TEAM-1-linear-' + SESSION.replace('-', '')
        self.run = self.runtime / 'runs' / self.run_id

    def tearDown(self):
        fixture.DispatchTests.tearDown(self)
        self.patch_env.stop()

    def send(self, event):
        self.assertEqual(self.store.enqueue(event, self.config), 200)
        self.assertTrue(self.worker.step())

    def test_delegation_launches_a_reviewed_run_bound_to_the_original_session(self):
        event = delivery()
        event['agentSession']['commentId'] = PROJECT
        event['agentSession']['comment'] = {'id': PROJECT, 'userId': None,
                                           'body': 'This thread is for an agent session with mini.'}
        self.api.issue_data['delegate'] = {'id': APP}
        self.send(event)
        result = self.wait(self.run_id)
        self.assertEqual(result['state'], 'ready_local')
        self.assertEqual(read_text(self.run / 'linear-session'), SESSION)
        request = read_json(self.run / 'request.json')
        self.assertEqual(request['repo'], str(self.repo))
        self.assertFalse(request['publish'])
        self.assertIn('Keep the existing public interface', read_text(self.run / 'brief.md'))
        self.store.enqueue(delivery(), self.config)
        self.assertFalse(self.worker.step())
        self.assertEqual(len(list((self.runtime / 'runs').iterdir())), 1)

    def test_reply_resumes_same_run_and_records_answer_once(self):
        (self.root / 'ask-question').touch()
        self.send(delivery())
        self.assertEqual(self.wait(self.run_id)['state'], 'needs_input')
        (self.root / 'ask-question').unlink()
        self.send(delivery('Use blue.'))
        self.assertEqual(self.wait(self.run_id)['state'], 'ready_local')
        self.store.enqueue(delivery('Use blue.'), self.config)
        self.assertFalse(self.worker.step())
        brief = read_text(self.run / 'brief.md')
        self.assertEqual(brief.count('Use blue.'), 1)
        self.assertIn('Decision recorded in Linear', brief)

    def test_parent_selected_station_stays_pinned_after_reassignment_and_restart(self):
        self.config['accounts'] = {USER: 'initiator', OTHER_USER: 'assigned'}
        for owner in self.config['accounts'].values():
            self.seat(owner)
        self.api.issue_data['parent'] = {'assignee': {'id': OTHER_USER}}
        (self.root / 'ask-question').touch()
        self.send(delivery())
        self.assertEqual(self.wait(self.run_id)['state'], 'needs_input')
        request = read_json(self.run / 'request.json')
        self.assertEqual(request['account'], 'assigned')
        self.assertNotIn('account_paths', request)
        self.assertEqual(read_json(self.run / 'linear-origin.json')['account_source'], 'parent_assignee')
        launches = [entry for entry in self.sudo_log() if entry['argv'][0].endswith('run-task.sh')]
        self.assertTrue(launches)
        for entry in launches:
            self.assertEqual(entry['seat'], 'assigned')
            self.assertIn('HARNESS_OWNER=assigned', entry['pairs'])
            self.assertFalse([pair for pair in entry['pairs']
                              if pair.startswith(('CLAUDE_CODE_OAUTH_TOKEN=', 'GH_TOKEN=',
                                                  'CLAUDE_CONFIG_DIR=', 'CODEX_HOME=', 'GH_CONFIG_DIR='))])
        self.api.issue_data['assignee'] = {'id': USER}
        (self.root / 'ask-question').unlink()
        self.worker = ld.Worker(self.runtime, self.config, ld.Store(self.runtime), self.api)
        self.send(delivery('Use blue.'))
        self.assertEqual(self.wait(self.run_id)['state'], 'ready_local')
        self.assertEqual(read_json(self.run / 'request.json')['account'], 'assigned')
        events = [json.loads(line) for line in (self.root / 'events').read_text().splitlines()]
        for event in events:
            if event.get('kind') == 'implement':
                self.assertEqual(event['owner'], 'assigned')
                self.assertIsNone(event['claude'])
                self.assertIsNone(event['codex'])

    def test_auth_block_is_saved_and_can_resume_from_linear(self):
        (self.root / 'claude-expired').touch()
        self.send(delivery())
        self.assertEqual(status(self.run)['state'], 'waiting_for_auth')
        self.assertEqual(self.api.activities[-1]['type'], 'error')
        (self.root / 'claude-expired').unlink()
        self.send(delivery('resume'))
        self.assertEqual(self.wait(self.run_id)['state'], 'ready_local')

    def test_activity_outage_and_worker_restart_do_not_redispatch(self):
        self.api.fail_result = True
        self.send(delivery())
        self.assertEqual(self.wait(self.run_id)['state'], 'ready_local')
        before = (self.root / 'events').read_text()
        with self.store.connect() as db:
            db.execute('UPDATE events SET due=0')
        ld.Worker(self.runtime, self.config, ld.Store(self.runtime), self.api).step()
        self.assertEqual((self.root / 'events').read_text(), before)
        self.assertEqual(self.api.activities[-1]['type'], 'response')

    def test_crash_after_launch_is_recovered_without_a_second_launch(self):
        import dispatch_cli
        submit = dispatch_cli.submit
        def crash(*args):
            submit(*args)
            raise SystemExit('simulated worker crash')
        self.store.enqueue(delivery(), self.config)
        with mock.patch('dispatch_cli.submit', side_effect=crash):
            with self.assertRaises(SystemExit):
                self.worker.step()
        self.wait(self.run_id)
        with mock.patch('dispatch_cli.submit') as again:
            ld.Worker(self.runtime, self.config, ld.Store(self.runtime), self.api).step()
            again.assert_not_called()
        self.assertEqual(self.api.activities[-1]['type'], 'response')

    def test_stop_interrupts_owned_process_group_and_prevents_resume(self):
        (self.root / 'hold-worker').touch()
        self.send(delivery())
        deadline = time.monotonic() + 10
        while not (self.root / 'events').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.send(delivery(stop=True))
        self.assertNotEqual(status(self.run)['state'], 'running')
        self.assertTrue((self.run / 'linear-stopped').exists())
        self.assertIn('Stopped', self.api.activities[-1]['body'])
        self.send(delivery('resume', number=2))
        self.assertNotEqual(status(self.run)['state'], 'running')

    def test_stop_during_auth_preflight_prevents_the_pending_launch(self):
        import dispatch_cli
        preflight = dispatch_cli.pipeline_issue
        def stop_during_preflight(*args, **kwargs):
            result = preflight(*args, **kwargs)
            self.store.enqueue(delivery(stop=True), self.config)
            return result
        with mock.patch('dispatch_cli.pipeline_issue', side_effect=stop_during_preflight):
            self.send(delivery())
        self.worker.step()
        self.assertFalse((self.run / 'launch.json').exists())
        self.assertFalse((self.run / 'driver.pid').exists())
        self.assertIn('Stopped', self.api.activities[-1]['body'])

    def test_stop_also_terminates_the_bound_evidence_operation(self):
        self.send(delivery())
        self.wait(self.run_id)
        script = self.runtime / 'lib/evidence_retry.py'
        script.write_text('import time\ntime.sleep(30)\n')
        process = subprocess.Popen([sys.executable, str(script), str(self.run)], start_new_session=True)
        try:
            (self.run / 'evidence-operation.json').write_text(json.dumps({'pid': process.pid}))
            self.send(delivery(stop=True))
            self.assertIsNotNone(process.wait(timeout=3))
            self.assertIn('Stopped', self.api.activities[-1]['body'])
        finally:
            if process.poll() is None:
                process.kill(); process.wait()

    def test_existing_outbound_session_reuses_its_run(self):
        self.run_task('TEAM-1', '--no-publish')
        self.wait('TEAM-1')
        directory = self.runtime / 'runs/TEAM-1'
        (directory / 'linear-session').write_text(SESSION)
        self.send(delivery())
        self.assertEqual(self.store.session(SESSION)['run'], 'TEAM-1')
        self.assertFalse(self.run.exists())

    def test_signed_http_ingress_is_durable_and_stop_can_arrive_during_launch(self):
        cfg = self.root / 'linear-config.json'; cfg.write_text(json.dumps(self.config))
        # curl is a fixture returning no JSON. The API cannot start any work,
        # but the real server/worker protocol must acknowledge durable storage.
        env = dict(self.env, WALL_PORT='0', WALL_HOST='127.0.0.1', WALL_RUNS=str(self.runtime / 'runs'),
                   WALL_LINEAR_WEBHOOK_SECRET='fixture-secret', WALL_LINEAR_DISPATCH_CONFIG=str(cfg))
        server = subprocess.Popen(['node', str(fixture.SOURCE / 'wall/server.js')], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: server.poll() is None and server.kill())
        port = None
        for _ in range(10):
            line = server.stdout.readline()
            if 'http://localhost:' in line or 'http://127.0.0.1:' in line:
                port = int(line.split('http://')[1].split(':')[1].split('/')[0]); break
        self.assertIsNotNone(port)
        def post(event, signed=True):
            raw = json.dumps(event).encode()
            headers = {'Content-Type': 'application/json'}
            if signed:
                headers['linear-signature'] = hmac.new(b'fixture-secret', raw, hashlib.sha256).hexdigest()
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            conn.request('POST', '/webhooks/linear', body=raw, headers=headers)
            response = conn.getresponse(); response.read(); code = response.status; conn.close()
            return code
        self.assertEqual(post(delivery(), signed=False), 401)
        old = delivery(); old['webhookTimestamp'] -= 120000
        self.assertEqual(post(old), 401)
        foreign = delivery(); foreign['organizationId'] = USER
        self.assertEqual(post(foreign), 403)
        self.assertEqual(post(delivery()), 200)
        self.assertEqual(post(delivery()), 200)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT count(*) FROM events').fetchone()[0], 1)
        self.assertFalse(self.run.exists())
        # Make the app API available and deliberately hold the model auth probe.
        # HTTP replies must remain usable while submit() emits its own output.
        (self.runtime / 'linear-agent-credentials').write_text('client_id=' + OAUTH + '\nclient_secret=fixture\n')
        (self.runtime / 'linear-agent-token').write_text(json.dumps({'access_token': 'fixture', 'expires_at': int(time.time()) + 200000}))
        (self.root / 'linear-issue.json').write_text(json.dumps(ISSUE_DATA))
        (self.bin / 'curl').write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
data = json.loads(sys.argv[sys.argv.index('-d') + 1])
if 'agentActivityCreate' in data['query']:
    print(json.dumps({'data': {'agentActivityCreate': {'success': True}}}))
else:
    issue=json.loads((pathlib.Path(os.environ['DISPATCH_TEST_DATA'])/'linear-issue.json').read_text())
    print(json.dumps({'data': {'issue': issue}}))
''')
        (self.bin / 'claude').write_text(fixture.FAKE.replace(
            "    good = not (root/'claude-expired').exists()",
            "    while (root/'hold-auth').exists(): time.sleep(.05)\n    good = not (root/'claude-expired').exists()"))
        (self.root / 'hold-auth').touch()
        with self.store.connect() as db:
            db.execute('UPDATE events SET due=0')
        deadline = time.monotonic() + 10
        while not (self.run / 'request.json').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue((self.run / 'request.json').exists())
        self.assertEqual(post(delivery(stop=True)), 200)
        self.assertTrue((self.run / 'linear-stopped').exists())
        (self.root / 'hold-auth').unlink()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.store.connect() as db:
                pending = db.execute('SELECT count(*) FROM events WHERE done=0').fetchone()[0]
            if not pending:
                break
            time.sleep(.05)
        self.assertEqual(pending, 0)
        self.assertFalse((self.run / 'driver.pid').exists())
        server.terminate(); server.wait(timeout=5)
        server.stdout.close(); server.stderr.close()


if __name__ == '__main__':
    unittest.main()
