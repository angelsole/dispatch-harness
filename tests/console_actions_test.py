"""Recovery contracts: saved decisions, stale tabs, identities and retry receipts."""
import fcntl
import getpass
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import dispatch_actions as actions
from dispatch_runs import DispatchError, write_json, read_json


class ConsoleActionsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.runtime = Path(self.temp.name)
        self.run = self.runtime / 'runs/TASK-1'
        self.run.mkdir(parents=True)
        self.env = mock.patch.dict(os.environ, {'HARNESS_PUBLISH': '1'})
        self.env.start()
        write_json(self.run / 'request.json', {'version': 1, 'id': 'TASK-1', 'repo': str(self.runtime), 'branch': 'test',
                   'operator': getpass.getuser(), 'host': socket.gethostname(), 'account': 'saved-owner',
                   'publish': True})
        write_json(self.run / 'result.json', {'status': 'needs_input'})
        (self.run / 'brief.md').write_text('# Fix checkout\nKeep the original requirements.\n')
        (self.run / 'QUESTIONS.md').write_text('Should guests be allowed to check out?\n')
        write_json(self.run / 'checkpoint.json', {'stage': 'gated'})
        self.body = {'id': 'TASK-1', 'action': 'answer_resume', 'operation_id': 'a' * 32,
                     'revision': self.view()['revision'], 'answer': 'Yes, keep guest checkout available.'}

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def view(self):
        return actions.view(self.runtime, 'TASK-1')

    def launch(self, args, runtime, directory, lock, **kwargs):
        # The lifecycle receives the same lock and sees the durable answer.
        self.assertIn(self.body['answer'], (directory / 'brief.md').read_text())
        with (directory / '.dispatch.lock').open('a+') as other:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertTrue(kwargs['background_evidence'])
        print(json.dumps({'id': 'TASK-1', 'state': 'running'}))
        return 0

    def test_question_checkpoint_and_saved_identity(self):
        task = self.view()
        self.assertIn('guests', task['questions'])
        self.assertEqual(task['account'], 'saved-owner')
        self.assertEqual(task['checkpoint']['stage'], 'gated')
        self.assertIn('checked before reuse', task['checkpoint']['description'])

    def test_answer_saved_once_and_duplicate_operation_replayed(self):
        with mock.patch('dispatch_cli.resume_locked', side_effect=self.launch) as resume:
            result = actions.apply(self.runtime, self.body)
            self.assertEqual(result['state'], 'running')
            self.assertTrue(result['answer_saved'])
            self.assertEqual(actions.apply(self.runtime, self.body), result)
            self.assertEqual(resume.call_count, 1)
        brief = (self.run / 'brief.md').read_text()
        self.assertIn('Keep the original requirements.', brief)
        self.assertEqual(brief.count(self.body['answer']), 1)
        self.assertIn('guests', brief)
        receipt = read_json(self.run / 'console-operations' / ('a' * 32 + '.json'))
        self.assertEqual(receipt['answer'], self.body['answer'])
        self.assertEqual(receipt['operator'], getpass.getuser())

    def test_stale_question_and_brief_cannot_be_answered(self):
        for name in ('brief.md', 'QUESTIONS.md', 'checkpoint.json', 'request.json'):
            original = (self.run / name).read_text()
            (self.run / name).write_text(original + '\n')
            with self.assertRaisesRegex(DispatchError, 'changed'):
                actions.apply(self.runtime, self.body)
            (self.run / name).write_text(original)
        self.assertFalse((self.run / 'console-operations').exists())

    def test_cannot_change_operation_body_under_same_id(self):
        with mock.patch('dispatch_cli.resume_locked', side_effect=self.launch):
            actions.apply(self.runtime, self.body)
        with self.assertRaisesRegex(DispatchError, 'different request'):
            actions.apply(self.runtime, dict(self.body, answer='No'))

    def test_corrupt_receipt_does_not_replay_an_unconfirmed_operation(self):
        receipts = self.run / 'console-operations'
        receipts.mkdir()
        receipt = receipts / (self.body['operation_id'] + '.json')
        original = (self.run / 'brief.md').read_bytes()
        for content in ('{', '', '[]', '{}', '{"response": {}}'):
            with self.subTest(content=content):
                receipt.write_text(content)
                with mock.patch('dispatch_cli.resume_locked') as resume:
                    with self.assertRaisesRegex(DispatchError, 'operation receipt'):
                        actions.apply(self.runtime, self.body)
                    resume.assert_not_called()
                self.assertEqual((self.run / 'brief.md').read_bytes(), original)

    def test_live_run_lock_prevents_mutation(self):
        original = (self.run / 'brief.md').read_bytes()
        with (self.run / '.dispatch.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.view()['actions'], [])
            with self.assertRaises(DispatchError):
                actions.apply(self.runtime, self.body)
        self.assertEqual((self.run / 'brief.md').read_bytes(), original)

    def test_remote_operator_and_legacy_runs_are_read_only(self):
        request = read_json(self.run / 'request.json')
        for changed in (dict(request, host='other-machine'), dict(request, operator='other-user'), {}):
            write_json(self.run / 'request.json', changed)
            task = self.view()
            self.assertEqual(task['actions'], [])
            self.assertTrue(task['disabled_reason'])
            with self.assertRaises(DispatchError):
                actions.apply(self.runtime, dict(self.body, revision=task['revision']))

    def test_blank_answers_and_arbitrary_actions_are_rejected(self):
        for patch in ({'answer': '  '}, {'answer': 'x' * 33000}, {'action': 'shell'},
                      {'command': 'touch forbidden'}, {'id': '../escape'}, {'operation_id': '../escape'}):
            with self.assertRaises(DispatchError):
                actions.apply(self.runtime, dict(self.body, **patch))
        self.assertFalse((self.run / 'console-operations').exists())

    def test_incomplete_or_unrecognized_requests_cannot_enable_actions(self):
        original = read_json(self.run / 'request.json')
        for key in ('version', 'id', 'repo', 'branch', 'account', 'publish'):
            changed = dict(original)
            changed.pop(key)
            with self.subTest(missing=key):
                write_json(self.run / 'request.json', changed)
                self.assertEqual(self.view()['actions'], [])
        for patch in ({'version': 2}, {'version': True}, {'id': 'OTHER-1'},
                      {'publish': 'false'}, {'account': 7},
                      {'repo': 'relative'}, {'branch': '-invalid'}, {'account': 'invalid owner'}):
            with self.subTest(patch=patch):
                write_json(self.run / 'request.json', dict(original, **patch))
                task = self.view()
                self.assertEqual(task['actions'], [])
                with self.assertRaises(DispatchError):
                    actions.apply(self.runtime, dict(self.body, revision=task['revision']))
        self.assertFalse((self.run / 'console-operations').exists())

    def test_corrupt_metadata_cannot_turn_a_stopped_run_into_prepared_work(self):
        for content in ('{', '', '[]', 'null', '{}', '{"status": null}'):
            with self.subTest(content=content):
                (self.run / 'result.json').write_text(content)
                with self.assertRaisesRegex(DispatchError, 'metadata is read-only'):
                    self.view()
                with self.assertRaises(DispatchError):
                    actions.apply(self.runtime, self.body)
        self.assertFalse((self.run / 'console-operations').exists())

    def test_missing_brief_cannot_enable_recovery(self):
        (self.run / 'brief.md').unlink()
        for state in ('needs_input', 'setup_failed', 'interrupted'):
            write_json(self.run / 'result.json', {'status': state})
            self.assertEqual(self.view()['actions'], [])
            self.assertIn('brief', self.view()['disabled_reason'])

    def test_saving_answer_preserves_original_brief_whitespace(self):
        original = '\n  # Keep this formatting\n\nRequirements.\n\n'
        (self.run / 'brief.md').write_text(original)
        self.body['revision'] = self.view()['revision']
        with mock.patch('dispatch_cli.resume_locked', side_effect=self.launch):
            actions.apply(self.runtime, self.body)
        self.assertTrue((self.run / 'brief.md').read_text().startswith(original))

    def test_symlinked_metadata_or_receipts_are_rejected(self):
        original = (self.run / 'brief.md').read_text()
        target = self.runtime / 'outside.md'
        target.write_text('must not change')
        (self.run / 'brief.md').unlink()
        (self.run / 'brief.md').symlink_to(target)
        with self.assertRaises(DispatchError):
            actions.apply(self.runtime, self.body)
        self.assertEqual(target.read_text(), 'must not change')
        (self.run / 'brief.md').unlink()
        (self.run / 'brief.md').write_text(original)
        (self.run / 'console-operations').symlink_to(self.runtime, target_is_directory=True)
        with self.assertRaises(DispatchError):
            actions.apply(self.runtime, self.body)

    def test_auth_handoff_uses_saved_run_and_no_secret(self):
        write_json(self.run / 'waiting.json', {'provider': 'codex', 'reason': 'Sign in again', 'action': 'untrusted shell'})
        task = self.view()
        self.assertEqual(task['login'], ['dispatch', 'login', 'codex', '--for-run', 'TASK-1'])
        self.assertEqual(task['actions'][0]['id'], 'resume')
        self.assertNotIn('untrusted shell', json.dumps(task))

    def test_scheduled_retry_is_not_started_again(self):
        write_json(self.run / 'result.json', {'status': 'deferred_capacity'})
        self.assertEqual(self.view()['actions'], [])

    def test_finished_run_does_not_offer_an_obsolete_login_handoff(self):
        write_json(self.run / 'waiting.json', {'provider': 'codex', 'reason': 'Old login failure'})
        write_json(self.run / 'result.json', {'status': 'ready_local'})
        self.assertIsNone(self.view()['login'])

    def test_missing_evidence_uses_resume_without_editing_brief(self):
        write_json(self.run / 'result.json', {'status': 'ready', 'pr_url': 'https://example.test/pr/1',
                   'evidence': {'head': 'abc', 'status': 'publish_failed', 'artifacts': ['shot']}})
        task = self.view()
        self.assertEqual(task['actions'], [{'id': 'resume', 'label': 'Recover frontend evidence'}])
        body = dict(self.body, action='resume', answer='', revision=task['revision'])
        before = (self.run / 'brief.md').read_bytes()
        with mock.patch('dispatch_cli.resume_locked') as resume:
            def recover(*args, **kwargs):
                self.assertTrue(kwargs['background_evidence'])
                print(json.dumps({'state': 'running'}))
                return 0
            resume.side_effect = recover
            actions.apply(self.runtime, body)
        self.assertEqual((self.run / 'brief.md').read_bytes(), before)

    def test_evidence_login_failure_shows_saved_account_handoff_and_reason(self):
        write_json(self.run / 'result.json', {'status': 'ready', 'pr_url': 'https://example.test/pr/1',
                   'evidence': {'head': 'abc', 'status': 'publish_failed', 'artifacts': ['shot'],
                                'auth_provider': 'gh', 'reason': 'GitHub login is unavailable.',
                                'action': 'untrusted shell'}})
        task = self.view()
        self.assertEqual(task['login'], ['dispatch', 'login', 'gh', '--for-run', 'TASK-1'])
        self.assertEqual(task['reason'], 'GitHub login is unavailable.')
        self.assertIn('Check login', task['actions'][0]['label'])
        self.assertNotIn('untrusted shell', json.dumps(task))

    def test_saved_answer_survives_recovery_failure(self):
        with mock.patch('dispatch_cli.resume_locked', side_effect=DispatchError('Fix repository configuration')):
            result = actions.apply(self.runtime, self.body)
        self.assertEqual(result['state'], 'failed')
        self.assertTrue(result['answer_saved'])
        self.assertIn(self.body['answer'], (self.run / 'brief.md').read_text())
        self.assertEqual(actions.apply(self.runtime, self.body), result)


if __name__ == '__main__':
    unittest.main()
