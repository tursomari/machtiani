"""No credentials, SSH, or provider calls: operator input safety contracts."""
import importlib.util
import os
import socket
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('operator_bridge', Path(__file__).with_name('operator.py'))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
mail_spec = importlib.util.spec_from_file_location('operator_mail', Path(__file__).with_name('operator-mail.py'))
mail = importlib.util.module_from_spec(mail_spec)
mail_spec.loader.exec_module(mail)


class OperatorTest(unittest.TestCase):
    def test_lost_reply_is_tolerated_and_next_client_can_receive_results(self):
        # A delayed screen/action response can outlive the client's timeout.
        # Losing its reply must not close the SSH session or repeat the action.
        sender, receiver = socket.socketpair()
        try:
            receiver.close()
            self.assertFalse(bridge.send_reply(sender, {'alive': True}))
        finally:
            sender.close()
        sender, receiver = socket.socketpair()
        try:
            self.assertTrue(bridge.send_reply(sender, {'alive': True}))
            self.assertEqual(receiver.recv(1024), b'{"alive": true}\n')
        finally:
            sender.close()
            receiver.close()

    def test_mail_cleanup_requires_run_identity_and_never_baseline_inboxes(self):
        state = {'run_id': 'fixture-run', 'baseline': ['permanent']}
        row = {'inbox_id': 'temporary', 'email': 'fixture@example.test',
               'client_id': 'ixe-operator-fixture-run-sender',
               'metadata': {'machtiani_ipe_run': 'fixture-run', 'machtiani_ipe_role': 'sender'}}
        self.assertTrue(mail.owned(row, state, 'sender'))
        self.assertFalse(mail.owned(row, state, 'receiver'))
        self.assertFalse(mail.owned(dict(row, inbox_id='permanent'), state, 'sender'))
        self.assertFalse(mail.owned(dict(row, client_id='another-run'), state, 'sender'))
        self.assertFalse(mail.owned(dict(row, metadata={}), state, 'sender'))
        self.assertFalse(mail.owned(dict(row, inbox_id=''), state, 'sender'))

    def test_secret_file_requires_private_single_line_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture'
            path.write_text('fake-test-key\n')
            path.chmod(0o600)
            self.assertEqual(bridge.read_credential(path), 'fake-test-key')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                bridge.read_credential(path)
            path.chmod(0o600)
            path.write_text('one\ntwo')
            with self.assertRaises(ValueError):
                bridge.read_credential(path)
            path.write_text('one\x1btwo')
            with self.assertRaises(ValueError):
                bridge.read_credential(path)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises((ValueError, OSError)):
                bridge.read_credential(link)

    def test_stale_secret_label_is_not_an_active_field(self):
        screen = bridge.Screen()
        screen.feed('Secure API key — input hidden\r\n› ')
        self.assertTrue(screen.secure())
        screen.feed('\x1b[2J\x1b[HOrdinary conversation\r\n› ')
        self.assertFalse(screen.secure())

    def test_mask_probe_requires_mask_and_no_echo(self):
        screen = bridge.Screen()
        screen.feed('Secure API key — input hidden\r\n› ' + '•' * 8)
        self.assertTrue(screen.masked('canary12'))
        screen.feed('\x1b[2J\x1b[HSecure API key — input hidden\r\n› canary12')
        self.assertFalse(screen.masked('canary12'))

    def test_split_secrets_are_never_returned_to_the_terminal(self):
        guard = bridge.OutputGuard(['fake-secret'])
        self.assertEqual(guard.feed('hello fake-'), 'hello ')
        with self.assertRaises(bridge.SecretExposure):
            guard.feed('secret goodbye')

    def test_nonsecret_prefix_is_released(self):
        guard = bridge.OutputGuard(['fake-secret'])
        self.assertEqual(guard.feed('fa'), '')
        self.assertEqual(guard.feed('st'), 'fast')

    def test_no_terminal_controls_in_normal_text(self):
        bridge.normal_text('Yes, use Forge. Please keep the chosen model.')
        for text in ('bad\x1b', 'two\ncommands', 'secret\x00', ''):
            with self.assertRaises(ValueError):
                bridge.normal_text(text)

    @unittest.skipUnless(os.environ.get('IXE_OPERATOR_TUI_RUNTIME'), 'optional real packaged TUI test')
    def test_real_masked_tui_accepts_a_fixture_key_not_chat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / 'fixture.key'
            key.write_text('fake-operator-test-key')
            key.chmod(0o600)
            # Dynamic import keeps the machine-specific runtime outside source.
            script = '''
const { InstallerTui } = await import(process.env.IXE_OPERATOR_TUI_RUNTIME);
const { readFile } = await import('node:fs/promises');
const tui = new InstallerTui();
tui.start();
const secret = await tui.askSecret('Fixture secure entry');
const expected = await readFile(process.env.HOME + '/fixture.key', 'utf8');
if (secret !== expected) throw new Error('fixture key mismatch');
await tui.dispose();
console.log('FIXTURE_SECRET_ACCEPTED');
'''
            terminal = bridge.Terminal(['env', 'HOME=' + str(root), os.environ['IXE_OPERATOR_NODE'],
                                       '--input-type=module', '-e', script], {'fixture': key})
            try:
                terminal.drain(1)
                self.assertTrue(terminal.screen.secure(), terminal.screen.lines())
                with self.assertRaises(ValueError):
                    terminal.act({'action': 'text', 'text': 'do not type into a secure field'})
                result = terminal.act({'action': 'secret', 'name': 'fixture'})
                self.assertIn('FIXTURE_SECRET_ACCEPTED', result['screen'])
                self.assertNotIn('fake-operator-test-key', result['screen'])
            finally:
                os.close(terminal.fd)
                os.waitpid(terminal.pid, 0)


if __name__ == '__main__':
    unittest.main()
