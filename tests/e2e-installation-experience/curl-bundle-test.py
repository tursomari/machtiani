import importlib.util
import io
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


class BundleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('bundle', ROOT / 'scripts/prepare-curl-bundle.py')
        cls.bundle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.bundle)

    def test_preview_accepts_only_loopback_http(self):
        self.bundle.validate_url('http://127.0.0.1:8765')
        for url in ('http://0.0.0.0:8765', 'http://example.test', 'http://user:password@127.0.0.1',
                    'http://127.0.0.1/path', 'http://127.0.0.1?token=fixture', 'file:///tmp'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.bundle.validate_url(url)

    def test_first_party_launch_instructions_put_bootstrap_before_wizard(self):
        runner = Path(__file__).with_name('run.sh').read_text()
        instructions = runner[runner.index("printf '\\nIXE is ready"):runner.index("printf '4. Interact")]
        for bundle in ('/fixture/download', ''):
            with self.subTest(bundle=bundle):
                result = subprocess.run(['bash', '-eu', '-c',
                    'backend_fixture=none; ssh_key=/fixture/key; ssh_port=12345; '
                    'agent_name=machtiani-installer; login_note="Choose and authenticate in the wizard"; '
                    'curl_base_url=http://127.0.0.1:8765; curl_bundle=$1;\n' + instructions,
                    'fixture', bundle], capture_output=True, text=True, check=True)
                self.assertLess(result.stdout.index('dearmachine'), result.stdout.index('Choose and authenticate'))
                if bundle:
                    self.assertLess(result.stdout.index('curl -fsSL'), result.stdout.index('dearmachine'))

    def test_standard_ixe_rejects_stale_guidance_but_allows_harness_only_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'repo'
            repo.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
            git('init', '-q')
            (repo / 'INSTALL.md').write_text('choose first\n')
            git('add', 'INSTALL.md')
            def commit():
                git('-c', 'commit.gpgSign=false', '-c', 'user.name=Fixture',
                    '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture')
                return git('rev-parse', 'HEAD')
            original = commit()
            bundle = root / 'bundle'
            bundle.mkdir()
            (bundle / 'runtime.tar.gz').write_bytes(b'checksum fixture, not an installable runtime')
            checksum = hashlib.sha256((bundle / 'runtime.tar.gz').read_bytes()).hexdigest()
            (bundle / 'manifest.json').write_text(json.dumps(dict(version=1, system='x86_64-linux',
                archive_sha256=checksum, release='fixture', revisions={'.': original, 'dearmachine-concierge': original})))
            (bundle / 'install').write_text(f'base_url=http://127.0.0.1:8765\narchive_sha={checksum}\nrelease_id=fixture\n')
            def validate():
                return subprocess.run(['bash', '-eu', '-c',
                    'source "$1"; backend_fixture=none; curl_bundle=$2; installer_source_root=$3; repo_root=$3; ixe_curl_validate',
                    'fixture', str(Path(__file__).with_name('standard-mode.sh')), str(bundle), str(repo)],
                    text=True, capture_output=True)
            self.assertEqual(validate().returncode, 0)
            (repo / 'test.txt').write_text('harness-only change\n')
            git('add', 'test.txt')
            commit()
            self.assertEqual(validate().returncode, 0)
            (repo / 'INSTALL.md').write_text('updated backend choice\n')
            git('add', 'INSTALL.md')
            commit()
            result = validate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('stale installer guidance', result.stderr)

    def test_source_archive_rejects_host_state_and_path_escapes(self):
        for name in ('.git/config', '.ssh/id_ed25519', '.secrets', '.env.local', '../outside', '/absolute'):
            entry = tarfile.TarInfo(name)
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.bundle.validate_member(entry)

    def test_source_archive_rejects_escaping_symlinks(self):
        entry = tarfile.TarInfo('docs/link')
        entry.type = tarfile.SYMTYPE
        entry.linkname = '../../outside'
        with self.assertRaises(ValueError):
            self.bundle.validate_member(entry)

    def test_source_archive_accepts_relative_documentation_link(self):
        entry = tarfile.TarInfo('INSTALL.md')
        entry.type = tarfile.SYMTYPE
        entry.linkname = 'docs/installation.md'
        self.bundle.validate_member(entry)

    def test_standard_snapshot_verification_detects_content_modes_and_links(self):
        spec = importlib.util.spec_from_file_location('snapshot', Path(__file__).with_name('standard-source.py'))
        snapshot = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(snapshot)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                snapshot.fingerprint(root)
            (root / 'bootstrap-source-revisions.json').write_text('{}')
            document = root / 'guide.md'
            document.write_text('first')
            initial = snapshot.fingerprint(root)
            self.assertEqual(snapshot.fingerprint(root), initial)
            document.write_text('second')
            changed = snapshot.fingerprint(root)
            self.assertNotEqual(initial, changed)
            document.chmod(0o600)
            self.assertNotEqual(changed, snapshot.fingerprint(root))
            (root / 'entry').symlink_to('guide.md')
            linked = snapshot.fingerprint(root)
            (root / 'entry').unlink()
            (root / 'entry').symlink_to('missing.md')
            self.assertNotEqual(linked, snapshot.fingerprint(root))
            (root / '.git').mkdir()
            with self.assertRaises(ValueError):
                snapshot.fingerprint(root)

    def test_server_exposes_only_regular_public_artifacts(self):
        spec = importlib.util.spec_from_file_location('server', Path(__file__).with_name('curl-server.py'))
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'install').write_text('public installer')
            (root / 'runtime.tar.gz').write_bytes(b'portable runtime')
            (root / '.bundle-cache.json').write_text('private metadata')
            (root / 'manifest.json').symlink_to(root / '.bundle-cache.json')
            http = server.http.server.ThreadingHTTPServer(('127.0.0.1', 0),
                lambda *a, **kw: server.Handler(*a, directory=directory, **kw))
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            try:
                base = f'http://127.0.0.1:{http.server_port}'
                with urllib.request.urlopen(base + '/install') as response:
                    self.assertEqual(response.read(), b'public installer')
                with urllib.request.urlopen(base + '/runtime.tar.gz') as response:
                    self.assertEqual(response.read(), b'portable runtime')
                for suffix in ('/', '/.bundle-cache.json', '/install?token=fixture', '/../anything', '/manifest.json'):
                    with self.subTest(path=suffix), self.assertRaises(urllib.error.HTTPError) as failure:
                        urllib.request.urlopen(base + suffix)
                    self.assertEqual(failure.exception.code, 404)
            finally:
                http.shutdown()
                http.server_close()


if __name__ == '__main__':
    unittest.main()
