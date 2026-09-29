#!/usr/bin/env python3
"""Credential-free contracts for the production Docker build and activation."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build', Path(__file__).resolve().parents[1] / 'scripts/container-build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class ContainerBuildTests(unittest.TestCase):
    def test_managed_build_holds_uninstall_update_lock_and_releases_on_failure(self):
        for bootstrap in (False, True):
            with self.subTest(bootstrap=bootstrap), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                lock = home / 'data/dearmachine/update.lock'
                def snapshot(source, context, installer):
                    self.assertTrue(lock.is_dir(), 'build must exclude uninstall before snapshotting')
                    raise RuntimeError('fixture failure')
                with patch.object(build, 'snapshot', side_effect=snapshot):
                    with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
                        build.acquire(home / 'source', home, home / 'data', bootstrap=bootstrap)
                self.assertFalse(lock.exists())

    def test_busy_update_or_uninstall_prevents_build_and_preserves_owner_lock(self):
        for marker in ('data/dearmachine/update.lock', '.dearmachine/uninstalling'):
            with self.subTest(marker=marker), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                path = home / marker
                build.private_directory(path.parent)
                if marker.endswith('.lock'):
                    path.mkdir()
                else:
                    path.write_text('fixture-owner')
                with patch.object(build, 'snapshot') as snapshot, patch.object(build, 'build_runtime'):
                    with self.assertRaisesRegex(ValueError, 'busy|uninstall'):
                        build.acquire(home / 'source', home, home / 'data')
                    snapshot.assert_not_called()
                self.assertTrue(path.exists())

    def test_snapshot_copies_working_sources_but_excludes_untracked_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'source'
            root.mkdir()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'file.txt').write_text('first')
            subprocess.run(['git', '-C', str(root), 'add', 'file.txt'], check=True)
            (root / 'file.txt').write_text('working revision')
            (root / '.secrets').mkdir()
            (root / '.secrets/key').write_text('test-only-placeholder')
            target = Path(directory) / 'snapshot'
            build.copy_checkout(root, target)
            self.assertEqual((target / 'file.txt').read_text(), 'working revision')
            self.assertFalse((target / '.secrets').exists())
            self.assertFalse((target / '.git').exists())

    def test_snapshot_rejects_tracked_secret_paths_and_escaping_links(self):
        for name, target in [('.env', None), ('escape', '/etc/passwd')]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'source'
                root.mkdir()
                subprocess.run(['git', 'init', '-q', str(root)], check=True)
                if target:
                    (root / name).symlink_to(target)
                else:
                    (root / name).write_text('fixture')
                subprocess.run(['git', '-C', str(root), 'add', name], check=True)
                with self.assertRaises(ValueError):
                    build.copy_checkout(root, Path(directory) / 'snapshot')

    def test_activation_preserves_conflicting_launchers_before_any_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.local/bin/machtiani'
            binary.parent.mkdir(parents=True)
            binary.write_text('independent installation')
            with self.assertRaisesRegex(ValueError, 'Existing'):
                build.check_launchers(home, home / 'release')
            self.assertEqual(binary.read_text(), 'independent installation')
            self.assertFalse((binary.parent / 'dearmachine').exists())

    def test_owned_launchers_can_be_reused_but_not_redirected_to_another_release(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / '.local/bin/dearmachine'
            binary.parent.mkdir(parents=True)
            binary.symlink_to(home / 'release/bin/dearmachine')
            build.check_launchers(home, home / 'release')
            with self.assertRaisesRegex(ValueError, 'Existing'):
                build.check_launchers(home, home / 'other-release')

    def test_private_directory_rejects_symlinks_and_shared_writable_parents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'real').mkdir()
            (root / 'link').symlink_to(root / 'real')
            with self.assertRaises(ValueError):
                build.private_directory(root / 'link/child')
            (root / 'real').chmod(0o777)
            with self.assertRaises(ValueError):
                build.private_directory(root / 'real/child')

    def test_content_identity_changes_with_source_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'file'
            path.write_text('one')
            first = build.fingerprint(root)
            path.write_text('two')
            second = build.fingerprint(root)
            path.chmod(0o755)
            self.assertNotEqual(first, second)
            self.assertNotEqual(second, build.fingerprint(root))

    def test_failed_build_removes_only_its_partial_release_and_creates_no_launchers(self):
        for failure in (RuntimeError('fixture failure'), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                source = home / 'source'
                source.mkdir()
                def snapshot(unused_source, context, unused_installer):
                    context.mkdir()
                    (context / 'file').write_text('source')
                def failed(context, release, bootstrap):
                    (release / 'partial').write_text('partial')
                    raise failure
                with patch.object(build, 'snapshot', side_effect=snapshot), patch.object(build, 'build_runtime', side_effect=failed):
                    with self.assertRaises(type(failure)):
                        build.acquire(source, home, home / 'data')
                self.assertEqual(list((home / '.local/bin').iterdir()), [])
                self.assertEqual(list((home / 'data/dearmachine/container-releases').iterdir()), [])
                self.assertTrue(source.exists())

    def test_conflicting_installation_prevents_building_or_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / '.local').mkdir(mode=0o700)
            (home / '.local/bin').mkdir(mode=0o700)
            (home / '.local/bin/machtiani').write_text('keep this installation')
            def snapshot(source, context, installer):
                context.mkdir()
                (context / 'file').write_text('source')
            with patch.object(build, 'snapshot', side_effect=snapshot), patch.object(build, 'build_runtime') as compile:
                with self.assertRaisesRegex(ValueError, 'Existing'):
                    build.acquire(home / 'source', home, home / 'data')
                compile.assert_not_called()
            self.assertEqual((home / '.local/bin/machtiani').read_text(), 'keep this installation')

    def test_missing_docker_is_actionable_and_does_not_choose_nix(self):
        with patch.object(build, 'command', side_effect=FileNotFoundError()), patch.object(build.platform, 'system', return_value='Linux'), patch.object(build.platform, 'machine', return_value='x86_64'):
            with self.assertRaisesRegex(ValueError, 'Docker.*not available'):
                build.preflight()

    def test_missing_docker_hub_helper_uses_private_anonymous_config_without_changing_saved_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config_root = Path(directory) / 'docker'
            config_root.mkdir()
            (config_root / 'contexts').mkdir()
            (config_root / 'buildx').mkdir()
            saved = {'credsStore': 'missing-helper', 'auths': {'https://index.docker.io/v1/': {'auth': 'fixture-only-placeholder'}},
                     'currentContext': 'remote', 'proxies': {'default': {'httpProxy': 'http://proxy.example'}}}
            config_path = config_root / 'config.json'
            original = json.dumps(saved) + '\n'
            config_path.write_text(original)
            with patch.dict(os.environ, {'DOCKER_CONFIG': str(config_root)}), patch.object(build.shutil, 'which', return_value=None):
                with build.docker_build_environment() as environment:
                    temporary_root = Path(environment['DOCKER_CONFIG'])
                    self.assertNotEqual(temporary_root, config_root)
                    self.assertEqual(environment['DOCKER_BUILDKIT'], '1')
                    self.assertEqual(json.loads((temporary_root / 'config.json').read_text()),
                                     {'currentContext': 'remote', 'proxies': saved['proxies']})
                    self.assertTrue((temporary_root / 'contexts').is_symlink())
                    self.assertTrue((temporary_root / 'buildx').is_symlink())
                    self.assertEqual((temporary_root / 'config.json').stat().st_mode & 0o777, 0o600)
                self.assertFalse(temporary_root.exists())
            self.assertEqual(config_path.read_text(), original)

    def test_available_docker_hub_helper_preserves_user_config(self):
        with tempfile.TemporaryDirectory() as directory:
            config_root = Path(directory)
            (config_root / 'config.json').write_text(json.dumps({'credsStore': 'working-helper'}))
            with patch.dict(os.environ, {'DOCKER_CONFIG': str(config_root)}), patch.object(build.shutil, 'which', return_value='/bin/helper'):
                with build.docker_build_environment() as environment:
                    self.assertEqual(environment['DOCKER_CONFIG'], str(config_root))

    def test_embedded_provider_payload_is_preserved_and_excluded_from_elf_rewrites(self):
        location = Path(__file__).resolve().parents[1] / 'scripts/container/prepare-runtime.py'
        spec = importlib.util.spec_from_file_location('packaging', location)
        packaging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packaging)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / 'runtime/vendor/claude'
            executable.parent.mkdir(parents=True)
            payload = b'\x7fELF' + b'embedded application data with absolute offsets' * 100
            executable.write_bytes(payload)
            plan = {'node_libraries': packaging.PREFIX + 'sysroot/lib', 'texts': []}
            with patch.object(packaging, 'ROOT', root), patch.object(packaging, 'output', side_effect=AssertionError('must not rewrite the payload')):
                packaging.preserve_embedded_executable(executable, plan)
                packaging.inventory(plan)
            self.assertEqual(executable.with_name('claude.unmodified').read_bytes(), payload)
            self.assertEqual(plan['elfs'], [])
            self.assertIn('--library-path', executable.read_text())
            self.assertIn('runtime/vendor/claude', plan['texts'])

    def test_vm_uses_a_private_disk_and_loopback_ssh_without_host_shares(self):
        location = Path(__file__).resolve().parent / 'e2e-installation-experience/container-build-vm.py'
        spec = importlib.util.spec_from_file_location('vm', location)
        vm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vm)
        arguments = vm.qemu_arguments(Path('/fixture/guest.qcow2'), Path('/fixture/seed.iso'), 23456, 6144, 4)
        self.assertIn('user,id=network,hostfwd=tcp:127.0.0.1:23456-:22', arguments)
        for forbidden in ('-virtfs', '-fsdev', 'docker.sock', 'SSH_AUTH_SOCK'):
            self.assertNotIn(forbidden, ' '.join(arguments))
        with self.assertRaises(ValueError):
            vm.qemu_arguments(Path('/guest'), Path('/seed'), 22, 0, 128)


if __name__ == '__main__':
    unittest.main()
