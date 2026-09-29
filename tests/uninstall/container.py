"""Uninstall acceptance assertions, executed only inside run.py's container."""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest

assert os.environ.get('DEARMACHINE_UNINSTALL_CONTAINER') == '1'
NATIVE = os.environ['NATIVE']
INSTALLER = os.environ['INSTALLER']


def terminal(command, env):
    master, slave = pty.openpty()
    child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env,
                             start_new_session=True)
    os.close(slave)
    return child, master


def until(child, fd, text, timeout=20):
    output = b''
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], .1)[0]:
            try:
                part = os.read(fd, 65536)
            except OSError:
                break
            output += part
            if text.encode() in output:
                return output.decode(errors='replace')
        if child.poll() is not None:
            break
    raise AssertionError(f'missing {text!r}: {output.decode(errors="replace")}')


class Uninstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='uninstall-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path('/home/tester') if os.environ.get('DEARMACHINE_TEST_SYSTEMD') == '1' else Path(self.tmp.name) / 'home'
        self.home.mkdir(mode=0o700, exist_ok=True)
        self.env = dict(os.environ, HOME=str(self.home), TERM='xterm-256color',
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_DATA_HOME=str(self.home / 'data'),
                        XDG_STATE_HOME=str(self.home / 'state'),
                        XDG_CACHE_HOME=str(self.home / 'cache'),
                        XDG_RUNTIME_DIR=str(self.home / 'run'))
        if os.environ.get('DEARMACHINE_TEST_SYSTEMD') == '1':
            self.env['XDG_RUNTIME_DIR'] = '/run/user/1000'
        self.root = self.home / 'data/dearmachine'
        self.release = self.root / ('releases/' + 'a' * 40)
        (self.release / 'bin').mkdir(parents=True)
        self.public = self.home / '.local/bin'
        self.public.mkdir(parents=True)
        for name, target in [('dearmachine', NATIVE), ('machtiani-installer', INSTALLER)]:
            launcher = self.release / 'bin' / name
            launcher.write_text(f'#!/bin/sh\nexec "{target}" "$@"\n')
            launcher.chmod(0o700)
            (self.public / name).symlink_to(launcher)
        (self.root / 'current').symlink_to(self.release)
        (self.release / 'release.json').write_text(json.dumps({
            'binaries': {'dearmachine': NATIVE, 'machtiani-installer': INSTALLER}}))
        self.cli = str(self.public / 'dearmachine')
        self.db = self.home / '.dearmachine/pairs/fixture/state/dearmachine.db'
        self.db.parent.mkdir(parents=True, mode=0o700)
        (self.home / '.dearmachine').chmod(0o700)
        db = sqlite3.connect(self.db)
        db.execute('create table private_data(value text)')
        db.execute("insert into private_data values ('disposable-memory')")
        db.commit()
        db.close()
        marker = self.home / '.dearmachine/entrypoint/main/.machtiani/project.uuid'
        marker.parent.mkdir(parents=True)
        marker.write_text('e4d35b42-4d24-428a-80cb-e9291bf9a1bf\n')
        store = self.home / '.machtiani/e4d35b42-4d24-428a-80cb-e9291bf9a1bf'
        self.owned = [self.home / '.dearmachine', self.home / '.config/dearmachine',
                      self.home / 'state/machtiani-installer', self.home / 'cache/dearmachine',
                      self.home / 'data/machtiani-installer', self.root, store]
        for directory in self.owned:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'private-fixture').write_text('fake-secret-only')
        self.sentinels = [self.home / '.machtiani/config.toml', self.home / '.config/machtiani/credentials.env',
                          self.home / 'my-project/notes', self.home / '.local/bin/other-tool']
        for path in self.sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('preserve byte for byte')
        self.processes = []
        self.addCleanup(self.reap)

    def reap(self):
        for child, fd in self.processes:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            if fd is not None:
                os.close(fd)

    def start(self, command):
        child, fd = terminal(command, self.env)
        self.processes.append((child, fd))
        return child, fd

    def preserved(self):
        for path in self.sentinels:
            self.assertEqual(path.read_text(), 'preserve byte for byte')

    def confirm(self):
        child, fd = self.start([self.cli, 'uninstall'])
        until(child, fd, 'Type UNINSTALL')
        os.write(fd, b'UNINSTALL\n')
        return child, fd

    def test_decline_eof_and_noninteractive(self):
        for answer in (b'no\n', b'yes\n', b'\x04'):
            child, fd = self.start([self.cli, 'uninstall'])
            until(child, fd, 'Type UNINSTALL')
            os.write(fd, answer)
            until(child, fd, 'cancelled')
            self.assertEqual(child.wait(timeout=5), 0)
            self.assertTrue(self.db.exists())
            self.assertTrue(Path(self.cli).exists())
        result = subprocess.run([self.cli, 'uninstall'], input='UNINSTALL\n', text=True,
                                capture_output=True, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('interactive terminal', result.stderr)
        self.preserved()

    def test_running_supervisor_and_concierge_shutdown(self):
        # Real supervisor, credential-free child process. The child opens a
        # real SQLite database so deletion cannot be credited to test teardown.
        daemon = self.release / 'daemon.py'
        daemon.write_text('import sqlite3,sys,time\ndb=sqlite3.connect(sys.argv[1])\n'
                          'db.execute("select * from private_data").fetchall()\ntime.sleep(600)\n')
        supervisor = subprocess.Popen([self.cli, '_supervise', '--state-dir',
            str(self.home / '.dearmachine'), '--', os.environ['PYTHON'], str(daemon), str(self.db)], env=self.env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes.append((supervisor, None))
        socket = self.home / '.dearmachine/run/supervisor.sock'
        deadline = time.monotonic() + 10
        while not socket.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(socket.exists())
        # Actual concierge composition remains local and requires no model.
        concierge, screen = self.start([str(self.public / 'machtiani-installer'), '--concierge'])
        until(concierge, screen, 'Use /help')
        os.write(screen, b'/uninstall\r')
        until(concierge, screen, 'dearmachine uninstall')
        self.assertIsNone(supervisor.poll())
        self.assertTrue(self.db.exists())
        cancel, fd = self.start([self.cli, 'uninstall'])
        until(cancel, fd, 'Type UNINSTALL')
        os.write(fd, b'no\n')
        self.assertEqual(cancel.wait(timeout=5), 0)
        self.assertIsNone(supervisor.poll())
        child, fd = self.confirm()
        until(child, fd, 'DearMachine uninstalled.', timeout=25)
        self.assertEqual(child.wait(timeout=5), 0)
        supervisor.wait(timeout=5)
        concierge.wait(timeout=5)
        time.sleep(.3)
        for path in self.owned:
            self.assertFalse(path.exists(), str(path))
        self.assertFalse(Path(self.cli).is_symlink())
        self.assertFalse((self.public / 'machtiani-installer').is_symlink())
        self.assertEqual(sorted(p.name for p in self.public.iterdir()), ['other-tool'])
        self.preserved()

    def test_real_daemon_database_is_closed_before_removal(self):
        root = self.home / '.dearmachine'
        pair = 'dd7b350c-73e5-4a28-a95b-439a42dcf412'
        inbox = '47c464b3-a99c-497c-b03a-d3742886d3de'
        (root / 'pairs.toml').write_text(f'''version = 2
[[inboxes]]
id = "{inbox}"
transport = "agentmail"
provider_id = "disposable-fixture"
address = "machine@example.test"
[[pairs]]
id = "{pair}"
user_email = "owner@example.test"
inbox_id = "{inbox}"
''')
        (root / 'pairs.toml').chmod(0o600)
        (root / 'config').mkdir()
        (root / 'config/dearmachine.toml').write_text('version = 1\nbackends = ["codex"]\n')
        managed_config = self.home / '.config/dearmachine/machtiani/config.toml'
        managed_config.parent.mkdir()
        managed_config.write_text('# Private configuration already selected; no legacy migration.\n')
        env = dict(self.env, AGENTMAIL_API_KEY='disposable-not-a-real-key')
        log = Path(self.tmp.name) / 'daemon.log'
        with log.open('wb') as output:
            daemon = subprocess.Popen([self.cli, '_supervise', '--state-dir', str(root), '--',
                self.cli, 'up', '--foreground', '--project', str(self.home), '--entry-point-repo', '',
                '--agent-bin', '/bin/true', '--agent-manager', str(Path(NATIVE).with_name('agent-manager'))],
                env=env, stdout=output, stderr=output)
        self.processes.append((daemon, None))
        ready = root / 'run/dearmachine.ready'
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        daemon_log = root / 'log/dearmachine.log'
        self.assertTrue(ready.exists(), log.read_text() + (daemon_log.read_text() if daemon_log.exists() else ''))
        database = root / 'pairs' / pair / 'state/dearmachine.db'
        self.assertTrue(database.exists())
        # No network exists in this container. The actual client is alive with
        # its real SQLite handles while transport retries remain local failures.
        child, fd = self.confirm()
        until(child, fd, 'DearMachine uninstalled.', timeout=25)
        self.assertEqual(child.wait(timeout=5), 0)
        daemon.wait(timeout=5)
        self.assertFalse(database.exists())
        self.assertFalse(root.exists())
        self.preserved()

    def test_symlink_escape_and_busy_update(self):
        lock = self.root / 'update.lock'
        lock.mkdir()
        child, fd = self.start([self.cli, 'uninstall'])
        until(child, fd, 'busy')
        self.assertNotEqual(child.wait(timeout=5), 0)
        lock.rmdir()
        external = self.home / 'external'
        external.mkdir()
        (external / 'keep').write_text('keep')
        (self.home / '.dearmachine/external').symlink_to(external)
        child, fd = self.confirm()
        until(child, fd, 'DearMachine uninstalled.')
        self.assertEqual(child.wait(timeout=5), 0)
        self.assertEqual((external / 'keep').read_text(), 'keep')

    def test_unwritable_data_reports_failure_and_retains_binary(self):
        blocked = self.home / '.dearmachine/blocked'
        blocked.mkdir()
        (blocked / 'private').write_text('cannot-remove')
        blocked.chmod(0o500)
        try:
            child, fd = self.confirm()
            until(child, fd, 'uninstall incomplete')
            self.assertNotEqual(child.wait(timeout=5), 0)
            self.assertTrue(Path(self.cli).exists())
            self.assertTrue((blocked / 'private').exists())
        finally:
            blocked.chmod(0o700)

    def test_changed_root_after_confirmation_preview_aborts(self):
        child, fd = self.start([self.cli, 'uninstall'])
        until(child, fd, 'Type UNINSTALL')
        original = self.home / '.dearmachine'
        saved = self.home / 'saved'
        original.rename(saved)
        original.symlink_to(saved)
        os.write(fd, b'UNINSTALL\n')
        until(child, fd, 'target changed')
        self.assertNotEqual(child.wait(timeout=5), 0)
        self.assertTrue((saved / 'pairs/fixture/state/dearmachine.db').exists())
        self.preserved()

    def test_unresponsive_process_prevents_data_deletion(self):
        daemon = self.release / 'stubborn.py'
        daemon.write_text('import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint("ready", flush=True)\ntime.sleep(600)\n')
        stubborn, fd = self.start([os.environ['PYTHON'], str(daemon)])
        until(stubborn, fd, 'ready')
        child, fd = self.confirm()
        until(child, fd, 'Stopping DearMachine processes')
        self.assertEqual((self.home / '.dearmachine/uninstalling').read_text().strip(), str(child.pid))
        until(child, fd, 'did not stop', timeout=20)
        self.assertNotEqual(child.wait(timeout=5), 0)
        self.assertTrue(self.db.exists())
        self.assertTrue(Path(self.cli).exists())
        self.assertIsNone(stubborn.poll())
        self.assertFalse((self.home / '.dearmachine/uninstalling').exists())

    def test_independent_open_database_prevents_deletion(self):
        holder = Path(self.tmp.name) / 'reader.py'
        holder.write_text('import sys,time\nf=open(sys.argv[1], "rb")\nprint("ready",flush=True)\ntime.sleep(600)\n')
        reader, fd = self.start([os.environ['PYTHON'], str(holder), str(self.db)])
        until(reader, fd, 'ready')
        child, fd = self.confirm()
        until(child, fd, 'still has uninstall data open')
        self.assertNotEqual(child.wait(timeout=5), 0)
        self.assertTrue(self.db.exists())
        self.assertIsNone(reader.poll())

    def test_protected_product_process_prevents_deletion(self):
        protected = self.release / 'protected.py'
        protected.write_text('import ctypes,time\nassert ctypes.CDLL(None).prctl(4,0,0,0,0)==0\n'
                             'print("ready",flush=True)\ntime.sleep(600)\n')
        reader, fd = self.start([os.environ['PYTHON'], str(protected)])
        until(reader, fd, 'ready')
        child, fd = self.confirm()
        until(child, fd, 'protected product process')
        self.assertNotEqual(child.wait(timeout=5), 0)
        self.assertTrue(self.db.exists())
        self.assertIsNone(reader.poll())

    def test_second_installation_starts_without_old_data(self):
        child, fd = self.confirm()
        until(child, fd, 'DearMachine uninstalled.')
        self.assertEqual(child.wait(timeout=5), 0)
        # Recreate only software; invoking the new concierge must find no old
        # private state or model selection and must not recreate a database.
        self.release.mkdir(parents=True)
        (self.public / 'machtiani-installer').symlink_to(INSTALLER)
        child, fd = self.start([str(self.public / 'machtiani-installer'), '--concierge'])
        until(child, fd, 'Installation: absent')
        self.assertFalse(self.db.exists())
        self.preserved()

    def test_delete_running_executable_without_helper(self):
        # A copied native ELF, as opposed to the Nix wrapper, proves Linux
        # executable unlink semantics while the final verifier still runs.
        real = Path(NATIVE).with_name('.dearmachine-wrapped')
        if not real.exists():
            real = Path(NATIVE)
        shutil.copy2(real, self.release / 'bin/dearmachine')
        child, fd = self.confirm()
        until(child, fd, 'No cleanup helper remains.')
        self.assertEqual(child.wait(timeout=5), 0)
        self.assertFalse(self.release.exists())
        self.preserved()

    @unittest.skipUnless(os.environ.get('DEARMACHINE_TEST_SYSTEMD') == '1', 'separate --systemd container gate')
    def test_systemd_service(self):
        def control(*args):
            return subprocess.run(['systemctl', '--user', *args], env=self.env, check=True,
                                  text=True, capture_output=True).stdout.strip()
        subprocess.run([self.cli, 'systemd', 'on'], env=self.env, check=True)
        units = self.home / '.config/systemd/user'
        dropin = units / 'dearmachine-concierge.service.d'
        dropin.mkdir()
        (dropin / 'fixture.conf').write_text('[Service]\nExecStart=\n'
            f'ExecStart={NATIVE} _supervise --state-dir {self.home}/.dearmachine -- /bin/sleep 600\n')
        (units / 'independent.service').write_text('[Service]\nExecStart=/bin/sleep 600\n'
                                                   '[Install]\nWantedBy=default.target\n')
        control('daemon-reload')
        control('enable', '--now', 'dearmachine-concierge.service', 'independent.service')
        self.assertEqual(control('is-active', 'dearmachine-concierge.service'), 'active')
        cancel, fd = self.start([self.cli, 'uninstall'])
        until(cancel, fd, 'Type UNINSTALL')
        os.write(fd, b'no\n')
        self.assertEqual(cancel.wait(timeout=5), 0)
        self.assertEqual(control('is-active', 'dearmachine-concierge.service'), 'active')
        child, fd = self.confirm()
        until(child, fd, 'DearMachine uninstalled.', timeout=25)
        self.assertEqual(child.wait(timeout=5), 0)
        self.assertFalse((units / 'dearmachine-concierge.service').exists())
        self.assertFalse(dropin.exists())
        self.assertNotEqual(subprocess.run(['systemctl', '--user', 'is-active', '--quiet',
            'dearmachine-concierge.service'], env=self.env).returncode, 0)
        self.assertNotEqual(subprocess.run(['systemctl', '--user', 'is-enabled', '--quiet',
            'dearmachine-concierge.service'], env=self.env).returncode, 0)
        self.assertEqual(control('is-active', 'independent.service'), 'active')
        self.assertEqual(control('is-enabled', 'independent.service'), 'enabled')
        linger = subprocess.check_output(['loginctl', 'show-user', 'tester', '--property=Linger', '--value'], text=True)
        self.assertEqual(linger.strip(), 'yes')
        self.preserved()


if __name__ == '__main__':
    unittest.main(verbosity=2)
