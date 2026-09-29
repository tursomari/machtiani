#!/usr/bin/env python3
"""Offline Standard dispatch, archive trust and native launcher checks."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
standard = load('standard', 'scripts/standard-build.py')
native = load('native', 'scripts/macos-build.py')
common = load('common', 'scripts/container-build.py')
version = load('version', 'scripts/machtiani-version-ldflags.py')

class StandardBuildTests(unittest.TestCase):
    def test_version_stamp_matches_the_nix_format(self):
        harness = 'a' * 40
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / 'bootstrap-source-revisions.json').write_text(json.dumps({'.': 'b' * 40, 'machtiani-harness': harness}))
            self.assertEqual(version.ldflags(source), f'-X main.Version=dev-aaaaaaa -X main.Commit={harness}')
            for dirty, label in ((False, 'clean'), (True, 'dirty')):
                (source / 'bootstrap-source-state.json').write_text(json.dumps({'workingTree': dirty}))
                self.assertTrue(version.ldflags(source).endswith(' -X main.Dirty=' + label))
            (source / 'bootstrap-source-revisions.json').write_text(json.dumps({'.': 'b' * 40}))
            with self.assertRaisesRegex(ValueError, 'machtiani-harness'): version.ldflags(source)

    def test_every_standard_build_stamps_machtiani(self):
        dockerfile = (ROOT / 'scripts/container/Dockerfile').read_text()
        self.assertIn('machtiani-version-ldflags.py', dockerfile)
        self.assertIn('-ldflags="-s -w $stamp" -o /out/machtiani', dockerfile)
        self.assertIn("-ldflags=' + flags", (ROOT / 'scripts/macos-build.py').read_text())
        windows = (ROOT / 'scripts/build-windows.ps1').read_text()
        self.assertIn("'-ldflags',$stamp,'-o',(Join-Path $runtime 'products\\machtiani.exe')", windows)

    def test_platform_dispatch(self):
        for system, cpu, expected in [('Linux', 'x86_64', 'linux-x64'), ('Darwin', 'x86_64', 'darwin-x64'), ('Darwin', 'arm64', 'darwin-arm64')]:
            self.assertEqual(standard.target(system, cpu), expected)
        for system, cpu in [('Linux', 'aarch64'), ('Windows', 'AMD64'), ('Darwin', 'ppc')]:
            with self.assertRaises(ValueError): standard.target(system, cpu)

    def test_native_acquisition_uses_platform_specific_cache_and_skips_elf_relocation(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            calls = []
            def snapshot(source, destination, installer_root=None):
                destination.mkdir()
                (destination / 'fixture').write_text('same source')
            def builder(source, output, bootstrap):
                calls.append(output)
            with patch.object(common, 'snapshot', side_effect=snapshot), patch.object(common, 'command') as command:
                options = dict(bootstrap=True, builder=builder, activate=False, namespace='standard-bootstrap')
                intel = common.acquire(home / 'source', home, home / 'data', target='darwin-x64', **options)
                arm = common.acquire(home / 'source', home, home / 'data', target='darwin-arm64', **options)
                reused = common.acquire(home / 'source', home, home / 'data', target='darwin-x64', **options)
                self.assertNotEqual(intel, arm)
                self.assertEqual(intel, reused)
                self.assertEqual(len(calls), 2)
                self.assertFalse(any('bootstrap-runtime.sh' in str(call) for call in command.call_args_list))
                self.assertFalse((home / '.local/bin').exists())

    def test_shell_setup_runs_only_after_installing_public_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            def snapshot(source, destination, installer_root=None):
                destination.mkdir()
                (destination / 'fixture').write_text('source')
            def builder(source, release, bootstrap):
                (release / 'bin').mkdir()
                for name in common.PUBLIC_COMMANDS:
                    (release / 'bin' / name).write_text('fixture launcher')
            calls = []
            def command(*args, **kwargs):
                if len(args) > 1 and args[1] == 'configure-shell':
                    self.assertTrue((home / '.local/bin/dearmachine').is_symlink())
                    self.assertEqual(kwargs['env']['HOME'], str(home))
                    calls.append(args)
            with patch.object(common, 'snapshot', side_effect=snapshot), patch.object(common, 'command', side_effect=command):
                options = dict(builder=builder, activate=False, namespace='standard-releases', target='darwin-x64')
                common.acquire(home / 'source', home, home / 'data', **options)
                common.acquire(home / 'source', home, home / 'data', **options)
                self.assertEqual(len(calls), 2)  # Reuse repairs a previously missing PATH too.
                common.acquire(home / 'source', home, home / 'data', output=home / 'export', **options)
                self.assertEqual(len(calls), 2)

    def test_native_build_does_not_inherit_provider_keys_or_host_compiler_hooks(self):
        with patch.dict(os.environ, {'DEEPINFRA_API_KEY': 'fixture-secret', 'NODE_OPTIONS': '--require /fixture/hook',
                                     'CPATH': '/nix/fixture', 'PATH': '/nix/fixture/bin', 'HOME': '/fixture/home'}, clear=True):
            env = native.build_environment(['/private/tools/bin'])
            self.assertNotIn('DEEPINFRA_API_KEY', env)
            self.assertNotIn('NODE_OPTIONS', env)
            self.assertNotIn('CPATH', env)
            self.assertNotIn('/nix', env['PATH'])
            self.assertEqual(env['HOME'], '/fixture/home')

    def test_missing_developer_tools_does_not_run_xcrun_or_download(self):
        with patch.object(native.platform, 'system', return_value='Darwin'), patch.object(native.platform, 'machine', return_value='arm64'), patch.object(native.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)) as command:
            with self.assertRaisesRegex(ValueError, 'xcode-select --install'): native.preflight()
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0], ['/usr/bin/xcode-select', '-p'])

    def test_rejects_archive_escape_and_symlink_escape(self):
        for name, link in [('../escape', None), ('root/link', '../../escape'), ('root/hard', '/etc/passwd')]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory); archive = root / 'bad.tar'
                with tarfile.open(archive, 'w') as stream:
                    entry = tarfile.TarInfo(name)
                    if link:
                        entry.type = tarfile.SYMTYPE; entry.linkname = link
                    stream.addfile(entry)
                with self.assertRaises(ValueError): native.extract(archive, root / 'out')
                self.assertFalse((root / 'escape').exists())

    def test_zip_extraction_preserves_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = root / 'safe.zip'
            with zipfile.ZipFile(archive, 'w') as stream:
                entry = zipfile.ZipInfo('git-lfs/git-lfs'); entry.external_attr = 0o100755 << 16
                stream.writestr(entry, '#!/bin/sh\nexit 0\n')
            unpacked = native.extract(archive, root / 'out')
            self.assertTrue(os.access(unpacked / 'git-lfs', os.X_OK))

    def test_zip_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); archive = root / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as stream: stream.writestr('../escape', 'bad')
            with self.assertRaises(ValueError): native.extract(archive, root / 'out')

    def test_checksum_mismatch_leaves_no_download(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(native.urllib.request, 'urlopen', return_value=io.BytesIO(b'corrupt')):
            cache = Path(directory)
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                native.download(cache, dict(url='https://example.test/payload', sha256='0' * 64))
            self.assertEqual(list(cache.iterdir()), [])

    def test_verified_cache_works_offline(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory, patch.object(native.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            cache = Path(directory); digest = hashlib.sha256(b'payload').hexdigest()
            (cache / digest).write_bytes(b'payload')
            self.assertEqual(native.download(cache, dict(url='https://example.test/payload', sha256=digest)), cache / digest)

    def test_launcher_quotes_paths_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix="standard ' $ space ") as directory:
            root = Path(directory); (root / 'bin').mkdir()
            command = root / 'fixture'
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$MACHTIANI_DISTRIBUTION" "$1"\n')
            command.chmod(0o755)
            native.write_launcher(root, 'test', [command], False)
            result = subprocess.check_output([str(root / 'bin/test'), 'argument with spaces'], text=True)
            self.assertEqual(result.splitlines(), [str(root / 'distribution.json'), 'argument with spaces'])

    def test_launcher_resolves_root_when_bundled_dirname_shadows_system_dirname(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            (root / 'runtime/tools/bin').mkdir(parents=True)
            tool = root / 'runtime/tools/bin/dirname'
            tool.write_text('#!/bin/sh\nexec /usr/bin/dirname "$@"\n')
            tool.chmod(0o755)
            native.write_launcher(root, 'dirname', [tool], False)
            result = subprocess.run([str(root / 'bin/dirname'), '/a/b'],
                                    env=dict(os.environ, PATH=str(root / 'bin') + ':/usr/bin:/bin'),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '/a')

    def test_launcher_finds_its_release_through_symlinks_after_a_move(self):
        with tempfile.TemporaryDirectory(prefix='standard release ') as directory:
            base = Path(directory)
            root = base / 'built'; (root / 'bin').mkdir(parents=True)
            command = root / 'runtime/native/fixture'; command.parent.mkdir(parents=True)
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$MACHTIANI_DISTRIBUTION" "$0"\n')
            command.chmod(0o755)
            native.write_launcher(root, 'test', [command], False)
            moved = base / 'installed'; root.rename(moved)
            links = base / 'links'; links.mkdir()
            (links / 'test').symlink_to(moved / 'bin/test')
            (links / 'relative').symlink_to('test')
            for launcher in (links / 'test', links / 'relative'):
                result = subprocess.check_output([str(launcher)], text=True)
                self.assertEqual(result.splitlines(), [str(moved / 'distribution.json'), str(moved / 'runtime/native/fixture')])

    def test_vendor_library_identity_is_not_treated_as_a_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'runtime').mkdir()
            library = root / 'runtime/libfixture.dylib'
            library.write_bytes(b'\xcf\xfa\xed\xfe')
            own_id = '/build/vendor/libfixture.dylib'
            def inspect(args, **kwargs):
                if args[1] == '-D': return str(library) + ':\n' + own_id + '\n'
                return str(library) + ':\n\t' + own_id + ' (compatibility version 0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1)\n'
            with patch.object(native.subprocess, 'check_output', side_effect=inspect):
                native.validate_libraries(root)
            def external(args, **kwargs):
                text = inspect(args, **kwargs)
                return text + ('\t/nix/store/fixture/libdependency.dylib (compatibility version 1)\n' if args[1] == '-L' else '')
            with patch.object(native.subprocess, 'check_output', side_effect=external):
                with self.assertRaisesRegex(ValueError, 'external library'):
                    native.validate_libraries(root)

    def test_pins_have_no_unresolved_downloads(self):
        pins = json.loads((ROOT / 'scripts/macos-dependencies.json').read_text())
        for entry in pins.values():
            self.assertNotIn('error', entry)
            self.assertRegex(entry['sha256'], r'^[0-9a-f]{64}$')
            self.assertTrue(entry['url'].startswith('https://'))

if __name__ == '__main__': unittest.main()
