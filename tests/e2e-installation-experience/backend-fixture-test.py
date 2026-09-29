"""Credential-free fixture contracts; optional cached-container verification."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name('backend-fixture.py')


class FixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('fixture', SCRIPT)
        cls.fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.fixture)

    def test_none_does_not_need_an_existing_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture.prepare(root, 'none')
            self.assertEqual((root / 'run/ixe/backend-fixture').read_text(), 'none\n')

    def test_cached_forge_is_retained_outside_the_users_access(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            forge = root / 'usr/local/bin/forge'
            forge.parent.mkdir(parents=True)
            forge.write_bytes(b'cached fixture')
            self.fixture.prepare(root, 'none')
            self.assertFalse(forge.exists())
            saved = root / 'run/ixe/disabled-backends/forge'
            self.assertEqual(saved.read_bytes(), b'cached fixture')
            self.assertEqual(saved.parent.stat().st_mode & 0o777, 0o700)
            self.fixture.prepare(root, 'none')
            self.assertEqual(saved.read_bytes(), b'cached fixture')

    def test_forge_selection_does_not_remove_the_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            forge = root / 'usr/local/bin/forge'
            forge.parent.mkdir(parents=True)
            forge.write_bytes(b'cached fixture')
            self.fixture.prepare(root, 'forge')
            self.assertEqual(forge.read_bytes(), b'cached fixture')

    def test_invalid_mode_fails_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                self.fixture.prepare(root, 'codex')
            self.assertEqual(list(root.iterdir()), [])

    def test_refuses_to_overwrite_a_retained_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            forge = root / 'usr/local/bin/forge'
            forge.parent.mkdir(parents=True)
            forge.write_bytes(b'first')
            self.fixture.prepare(root, 'none')
            forge.write_bytes(b'second')
            with self.assertRaises(ValueError):
                self.fixture.prepare(root, 'none')
            self.assertEqual(forge.read_bytes(), b'second')

    def test_cli_rejects_invalid_or_conflicting_fixtures_before_setup(self):
        for options, message in [
            (['--backend-fixture', 'unknown'], 'must be forge or none'),
            (['--backend-fixture', 'none', '--agent', 'forge'], 'requires the first-party installer'),
            (['--backend-fixture', 'none', '--forge-binary', str(SCRIPT)], 'conflicts'),
        ]:
            result = subprocess.run(['bash', str(SCRIPT.with_name('run.sh')), *options],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)


def container_check(image, forge):
    def run(*args, **kwargs):
        return subprocess.run(args, check=True, text=True, **kwargs)
    image_id = run('docker', 'image', 'inspect', '--format', '{{.Id}}', image, capture_output=True).stdout.strip()
    # Test both empty Standard and retained-Forge cached-image scenarios.
    for mode, seed in [('forge', True), ('none', False), ('none', True)]:
        container = run('docker', 'run', '--detach', '--network', 'none', '--entrypoint', '/bin/sh',
                        image_id, '-c', 'exec sleep infinity', capture_output=True).stdout.strip()
        try:
            run('docker', 'cp', str(SCRIPT), container + ':/opt/backend-fixture.py')
            if seed:
                run('docker', 'cp', str(forge), container + ':/usr/local/bin/forge')
                run('docker', 'exec', container, 'chmod', '0755', '/usr/local/bin/forge')
            run('docker', 'exec', container, 'python3', '/opt/backend-fixture.py', mode)
            if mode == 'none':
                run('docker', 'exec', '--user', 'installer', container, 'sh', '-eu', '-c',
                    'for c in codex forge omp; do ! command -v "$c"; done; '
                    'test ! -x /run/ixe/disabled-backends/forge')
            else:
                run('docker', 'exec', '--user', 'installer', container, 'forge', '--version')
            print(f'BACKEND_FIXTURE_OK: {mode}, cached Forge={seed}', flush=True)
            if mode == 'none' and not seed:
                # Detection must fail closed even when an unexpected binary
                # is not the IXE-owned Forge fixture. Never execute that binary.
                run('docker', 'cp', str(forge), container + ':/usr/local/bin/codex')
                run('docker', 'exec', container, 'chmod', '0755', '/usr/local/bin/codex')
                result = subprocess.run(['docker', 'exec', container, 'python3',
                    '/opt/backend-fixture.py', 'none'], text=True, capture_output=True)
                assert result.returncode != 0 and 'Unexpected supported backend' in result.stderr
                run('docker', 'exec', container, 'test', '-x', '/usr/local/bin/codex')
                print('BACKEND_FIXTURE_OK: unexpected backend rejected and preserved', flush=True)
        finally:
            run('docker', 'rm', '--force', container, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', help='Optional already-cached Standard IXE image; no build/pull/network')
    parser.add_argument('--forge-binary', type=Path)
    args = parser.parse_args()
    if args.image:
        if not args.forge_binary:
            parser.error('--image requires --forge-binary')
        container_check(args.image, args.forge_binary)
    else:
        unittest.main(argv=[sys.argv[0]])
