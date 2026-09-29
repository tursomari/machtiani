#!/usr/bin/env python3
"""Offline ownership and cleanup contracts for the optional IPE sender."""
import argparse
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('sender', Path(__file__).with_name('openmail-sender.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        with patch.dict(module.os.environ, OPENMAIL_API_KEY='fixture-only'):
            self.sender = module.Sender(Path(self.directory.name) / 'state.json')
        self.owned = dict(id='owned', address='ipe-123456abcdef-sender@example.test', podId='pod',
                          displayName='Machtiani IPE 123456abcdef sender', createdAt='2026-09-18')
        self.baseline = dict(inboxes=[], policies={'account': {}})
        self.state = dict(inbox=self.owned, baseline=self.baseline, receiver='receiver@example.test',
                          mailbox_name='ipe-123456abcdef-sender', display_name=self.owned['displayName'])

    def test_cleanup_deletes_only_verified_owned_identity_and_restores_baseline(self):
        self.sender.save(self.state)
        self.sender.pages = Mock(return_value=[self.owned])
        self.sender.request = Mock(side_effect=[self.owned, None])
        self.sender.snapshot = Mock(return_value=self.baseline)
        self.assertEqual(self.sender.cleanup(), {'cleaned': True})
        self.assertEqual(self.sender.request.call_args_list[-1].args, ('DELETE', '/v1/inboxes/owned'))
        self.assertTrue(self.sender.load()['cleaned'])

    def test_cleanup_refuses_baseline_inbox(self):
        self.state['baseline']['inboxes'] = [self.owned]
        self.sender.save(self.state)
        self.sender.pages = Mock(return_value=[self.owned])
        self.sender.request = Mock()
        with self.assertRaisesRegex(ValueError, 'baseline inbox'):
            self.sender.cleanup()
        self.sender.request.assert_not_called()

    def test_cleanup_refuses_changed_identity_without_deleting(self):
        self.sender.save(self.state)
        changed = dict(self.owned, displayName='someone else')
        self.sender.pages = Mock(return_value=[changed])
        self.sender.request = Mock(return_value=changed)
        with self.assertRaisesRegex(ValueError, 'identity changed'):
            self.sender.cleanup()
        self.assertEqual(self.sender.request.call_count, 1)

    def test_unresolved_create_intent_never_guesses_a_deletion(self):
        del self.state['inbox']
        for rows in ([], [self.owned, dict(self.owned, id='ambiguous')]):
            with self.subTest(count=len(rows)):
                self.sender.save(self.state)
                self.sender.pages = Mock(return_value=rows)
                self.sender.request = Mock()
                with self.assertRaisesRegex(ValueError, 'Ambiguous'):
                    self.sender.cleanup()
                self.sender.request.assert_not_called()

    def test_response_loss_recovers_complete_unique_create_identity(self):
        del self.state['inbox']
        self.sender.save(self.state)
        self.sender.pages = Mock(return_value=[self.owned])
        self.sender.request = Mock(side_effect=[self.owned, None])
        self.sender.snapshot = Mock(return_value=self.baseline)
        self.sender.cleanup()
        self.assertEqual(self.sender.load()['inbox'], self.owned)

    def test_sender_rejects_unowned_inbox_and_unpaired_recipient(self):
        self.sender.save(self.state)
        self.sender.request = Mock()
        with self.assertRaisesRegex(ValueError, 'this run'):
            self.sender.messages('unowned')
        with self.assertRaisesRegex(ValueError, 'recorded test pair'):
            self.sender.send(argparse.Namespace(inbox_id='owned', to='stranger@example.test'))
        self.sender.request.assert_not_called()

    def test_authenticated_redirects_are_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'redirect refused'):
            module.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example')

    def test_attachment_signed_url_never_receives_bearer_credential(self):
        api, storage = Mock(), Mock()
        api.open.side_effect = module.AttachmentLocation('https://storage.example/file?signature=fixture')
        storage.open.return_value.__enter__ = Mock(return_value=Mock(read=Mock(return_value=b'result')))
        storage.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(module.urllib.request, 'build_opener', side_effect=[api, storage]):
            self.assertEqual(self.sender.request('GET', '/v1/attachments/message/result.txt', raw=True), b'result')
        self.assertEqual(api.open.call_args.args[0].get_header('Authorization'), 'Bearer fixture-only')
        self.assertIsNone(storage.open.call_args.args[0].get_header('Authorization'))

    def test_attachment_redirect_rejects_insecure_or_userinfo_url(self):
        for url in ['http://storage.example/file', 'https://user:password@storage.example/file', 'file:///tmp/file']:
            with self.subTest(url=url):
                api = Mock()
                api.open.side_effect = module.AttachmentLocation(url)
                with patch.object(module.urllib.request, 'build_opener', return_value=api):
                    with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
                        self.sender.request('GET', '/v1/attachments/message/result.txt', raw=True)


if __name__ == '__main__':
    unittest.main()
