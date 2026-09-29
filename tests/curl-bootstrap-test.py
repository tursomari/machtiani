"""Exercise the served POSIX bootstrap with local HTTP and a fake Nix store."""
import hashlib
import http.server
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.web = self.root / 'web'
        self.web.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.package = self.root / 'package'
        (self.package / 'bin').mkdir(parents=True)
        self.executable(self.package / 'bin/dearmachine', '#!/bin/sh\nif [ "$1" = _launcher-check ]; then touch "$HOME/launcher-check-called"; fi\nprintf "fixture launcher\\n"\n')
        self.log = self.root / 'nix-calls'
        self.executable(self.bin / 'nix', '#!/bin/sh\nexit 0\n')
        self.executable(self.bin / 'nix-store', '''#!/bin/sh
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  --check-validity) test "${CACHE_HIT:-0}" = 1 ;;
  --import) cat >/dev/null ;;
  --add-root) while test "$#" -gt 0; do test "$1" != --realise || exit 0; shift; done ;;
  *) exit 91 ;;
esac
''')
        self.payload = self.web / 'closure.nar.gz'
        import gzip
        self.payload.write_bytes(gzip.compress(b'fixture Nix export'))
        self.source = self.web / 'source.tar.gz'
        with tarfile.open(self.source, 'w:gz') as archive:
            for name in ('INSTALL.md', 'docs/README.md', 'dearmachine-concierge/package.json',
                         'dearmachine/flake.nix', 'machtiani-harness/flake.nix'):
                content = b'fixture\n'
                entry = tarfile.TarInfo(name)
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
            lambda *a, **kw: QuietHandler(*a, directory=str(self.web), **kw))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.values = {
            'BASE_URL': f'http://127.0.0.1:{self.server.server_port}',
            'INSTALLER_PATH': str(self.package),
            'GIT_PATH': str(Path(shutil.which('git')).parent.parent),
            'SOURCE_SHA': hashlib.sha256(self.source.read_bytes()).hexdigest(),
            'CLOSURE_SHA': hashlib.sha256(self.payload.read_bytes()).hexdigest(),
            'SYSTEM': 'x86_64-linux', 'RELEASE': 'fixture-release',
        }
        self.environment = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:{os.environ["PATH"]}',
                                CALL_LOG=str(self.log))

    def executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def run_bootstrap(self, **environment):
        text = (ROOT / 'scripts/curl-bootstrap.sh').read_text()
        for name, value in self.values.items():
            text = text.replace(f'@{name}@', shlex.quote(value))
        return subprocess.run([shutil.which('sh')], input=text, text=True, capture_output=True,
                              env=dict(self.environment, **environment))

    def test_installs_from_pipe_and_retains_versioned_source(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.home / '.local/bin/dearmachine'), result.stdout)
        self.assertTrue((self.home / 'launcher-check-called').exists())
        launcher = self.home / '.local/bin/dearmachine'
        self.assertTrue(os.access(launcher, os.X_OK))
        self.assertIn('DEARMACHINE_SOURCE_ROOT', launcher.read_text())
        source = self.home / '.local/share/machtiani/bootstrap/fixture-release/source'
        self.assertTrue((source / 'docs/README.md').is_file())
        subprocess.run(['git', '-C', str(source), 'rev-parse', '--verify', 'HEAD'], check=True, capture_output=True)
        self.assertIn('--import', self.log.read_text())

    def test_cache_hit_skips_closure_download(self):
        self.payload.unlink()
        result = self.run_bootstrap(CACHE_HIT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('--import', self.log.read_text())

    def test_bad_checksum_never_imports_or_installs(self):
        self.payload.write_bytes(b'corrupt')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('--import', self.log.read_text())
        self.assertFalse((self.home / '.local/bin/dearmachine').exists())

    def test_existing_launcher_is_not_overwritten(self):
        launcher = self.home / '.local/bin/dearmachine'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('existing user installation')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(launcher.read_text(), 'existing user installation')
        self.assertFalse(self.log.exists())

    def test_mismatched_architecture_fails_before_nix_changes(self):
        self.values['SYSTEM'] = 'aarch64-linux'
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_bootstrap_configures_shell_precedence(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / 'launcher-check-called').exists())

    def test_missing_nix_is_explicit_and_does_not_bootstrap_over_network(self):
        (self.bin / 'nix').unlink()
        (self.bin / 'uname').symlink_to(shutil.which('uname'))
        result = self.run_bootstrap(PATH=str(self.bin))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Nix is required for this local preview', result.stderr)
        self.assertFalse(self.log.exists())

    def test_repeat_is_safe_and_does_not_import_again(self):
        first = self.run_bootstrap()
        self.assertEqual(first.returncode, 0, first.stderr)
        result = self.run_bootstrap(CACHE_HIT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().count('--import'), 1)


if __name__ == '__main__':
    unittest.main()
