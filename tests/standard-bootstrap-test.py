#!/usr/bin/env python3
"""Exercise the real shell/curl bootstrap with a tiny, non-product fixture."""
import functools
import hashlib
import http.server
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-standard-download.py'
spec = importlib.util.spec_from_file_location('download', SCRIPT)
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='standard-bootstrap-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.web = self.root / 'web'
        self.web.mkdir()
        archive = self.web / 'runtime.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            script = b'#!/bin/sh\nexit 0\n'
            for name in ('bootstrap-runtime.sh', *('bin/' + name for name in (
                    'dearmachine', 'machtiani', 'machtiani-installer', 'machtiani-model-host', 'agent-manager', 'git-lfs', 'python3'))):
                info = tarfile.TarInfo(name)
                content = (b'#!/bin/sh\nif [ "$1" = _launcher-check ]; then touch "$HOME/launcher-check-called"; fi\n'
                           if name == 'bin/machtiani-installer' else script)
                info.size = len(content)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(content))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(self.web)))
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.script = download.render_bootstrap('http://127.0.0.1:' + str(self.server.server_port), digest, 'fixture')
        self.environment = dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.home / '.local/share'), PATH='/usr/bin:/bin')

    def run_bootstrap(self):
        return subprocess.run(['sh'], input=self.script, text=True, capture_output=True, env=self.environment)

    def test_installs_all_public_products_and_reuses_verified_cache(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('No Nix was installed', result.stdout)
        self.assertTrue((self.home / 'launcher-check-called').exists())
        for name in ('dearmachine', 'machtiani', 'machtiani-installer', 'machtiani-model-host', 'agent-manager'):
            self.assertTrue((self.home / '.local/bin' / name).is_symlink())
        (self.web / 'runtime.tar.gz').unlink()
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checksum_failure_does_not_activate_products(self):
        (self.web / 'runtime.tar.gz').write_bytes(b'corrupt')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum failed', result.stderr)
        self.assertFalse((self.home / '.local/bin/dearmachine').exists())

    def test_preserves_unrelated_existing_launcher(self):
        path = self.home / '.local/bin/dearmachine'
        path.parent.mkdir(parents=True)
        path.write_text('user-owned')
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), 'user-owned')

    def test_rejects_symlinked_release_directory(self):
        root = self.home / '.local/share/dearmachine'
        root.mkdir(parents=True)
        (root / 'releases').symlink_to(self.web)
        self.assertNotEqual(self.run_bootstrap().returncode, 0)

    def test_rejects_insecure_remote_download_urls(self):
        for url in ('http://example.test', 'https://user:password@example.test', 'https://example.test/?token=secret'):
            with self.assertRaises(ValueError):
                download.validate_url(url)


if __name__ == '__main__':
    unittest.main()
