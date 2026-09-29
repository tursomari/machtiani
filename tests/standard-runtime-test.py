#!/usr/bin/env python3
"""Fast, credential-free contracts for portable release relocation."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/relocate-standard-runtime.py'
spec = importlib.util.spec_from_file_location('relocator', SCRIPT)
relocator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relocator)
producer_spec = importlib.util.spec_from_file_location('producer', SCRIPT.with_name('prepare-standard-runtime.py'))
producer = importlib.util.module_from_spec(producer_spec)
producer_spec.loader.exec_module(producer)


class RelocationTests(unittest.TestCase):
    def test_launchers_find_user_backends_after_reopen_with_minimal_path(self):
        with tempfile.TemporaryDirectory(prefix='standard-path-') as directory:
            root = Path(directory)
            home = root / 'user home'
            local_bin = home / '.local/bin'
            local_bin.mkdir(parents=True)
            (local_bin / 'omp').write_text('#!/bin/sh\nprintf "existing-backend\\n"\n')
            (local_bin / 'omp').chmod(0o700)
            command = root / 'runtime/client/bin/dearmachine'
            command.parent.mkdir(parents=True)
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$PATH"\nexec omp\n')
            command.chmod(0o700)
            plan = dict(symlinks={}, elfs=[], texts=[], patcher_loader='absent',
                        patcher_libraries='', patcher='absent', environment={},
                        commands={'dearmachine': '/nix/store/client/bin/dearmachine'})
            (root / 'relocation.json').write_text(json.dumps(plan))
            relocator.relocate(root)
            for inherited in ('/custom/bin:/usr/bin:/bin', '/usr/bin:/bin:' + str(local_bin)):
                for reopen in range(2):
                    result = subprocess.run([root / 'bin/dearmachine'],
                                            env={'HOME': str(home), 'PATH': inherited},
                                            text=True, capture_output=True, check=True)
                    path, backend = result.stdout.splitlines()
                    self.assertEqual(backend, 'existing-backend')
                    self.assertTrue(path.startswith(str(root / 'bin') + ':' + inherited))
                    self.assertEqual(path.split(':').count(str(local_bin)), 1)

    def test_container_prefix_and_bootstrap_support_a_release_path_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='container runtime ') as directory:
            root = Path(directory)
            command = root / 'runtime/native/installer'
            command.parent.mkdir(parents=True)
            command.write_text('#!/bin/sh\nprintf "%s" "${MACHTIANI_DISTRIBUTION-unset}"\n')
            command.chmod(0o700)
            plan = dict(runtime_prefix='/__dearmachine_runtime__/', bootstrap_only=True,
                        symlinks={}, elfs=[], texts=[], patcher_loader='absent',
                        patcher_libraries='', patcher='absent', environment={},
                        commands={'dearmachine': '/__dearmachine_runtime__/native/installer'})
            (root / 'relocation.json').write_text(json.dumps(plan))
            relocator.relocate(root)
            result = subprocess.run([root / 'bin/dearmachine'], env={'PATH': '/usr/bin:/bin'},
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout, 'unset')

    def test_node_addons_use_their_own_node_library_closure(self):
        plan = {'node_addon_root': 'runtime/installer/node_modules/',
                'node_libraries': '/nix/store/node-libc/lib:/nix/store/node-cxx/lib'}
        library = dict(path='runtime/installer/node_modules/vips/libvips.so',
                       interpreter='', rpath='$ORIGIN/deps', needed=['libresolv.so.2'])
        self.assertEqual(relocator.elf_rpath(library, plan),
                         '$ORIGIN/deps:/nix/store/node-libc/lib:/nix/store/node-cxx/lib')
        other = dict(library, path='runtime/other/lib/libthing.so')
        self.assertEqual(relocator.elf_rpath(other, plan), '$ORIGIN/deps')
        executable = dict(library, interpreter='/nix/store/other-libc/lib/ld-linux.so')
        self.assertEqual(relocator.elf_rpath(executable, plan), '$ORIGIN/deps:/nix/store/other-libc/lib')
        self.assertEqual(relocator.elf_rpath(dict(library, needed=[]), plan), '$ORIGIN/deps')

    def test_origin_relative_native_libraries_remain_unmodified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'runtime/installer/node_modules/vips/lib'
            native.mkdir(parents=True)
            library = native / 'libvips.so'
            library.write_bytes(b'original ELF fixture')
            libc = root / 'runtime/node-libc/lib'
            libc.mkdir(parents=True)
            (libc / 'libresolv.so.2').write_bytes(b'resolver fixture')
            entry = dict(path=str(library.relative_to(root)), interpreter='', rpath='$ORIGIN/', needed=['libresolv.so.2'])
            plan = dict(node_addon_root='runtime/installer/node_modules/', node_libraries='/nix/store/node-libc/lib')
            self.assertEqual(relocator.elf_rpath(entry, plan), '$ORIGIN/')
            relocator.supply_origin_libraries(root, entry, plan)
            self.assertEqual((native / 'libresolv.so.2').resolve(), libc / 'libresolv.so.2')
            self.assertFalse((native / 'libresolv.so.2').readlink().is_absolute())
            self.assertEqual(library.read_bytes(), b'original ELF fixture')
            relocator.supply_origin_libraries(root, entry, plan)
            # A nonexistent patcher proves relocation never rewrites this ELF.
            plan.update(symlinks={}, elfs=[entry], texts=[], patcher_loader='absent-loader',
                        patcher_libraries='', patcher='absent-patcher', environment={},
                        commands={'dearmachine': '/nix/store/client/bin/dearmachine'})
            (root / 'relocation.json').write_text(json.dumps(plan))
            relocator.relocate(root)
            self.assertEqual(library.read_bytes(), b'original ELF fixture')

    def test_origin_dependencies_cannot_escape_or_overwrite_vendor_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / 'runtime/installer/node_modules/vips/lib'
            native.mkdir(parents=True)
            (native / 'existing.so').write_bytes(b'vendor')
            libc = root / 'runtime/node-libc/lib'
            libc.mkdir(parents=True)
            (libc / 'existing.so').write_bytes(b'node')
            entry = dict(path=str((native / 'vips.so').relative_to(root)), interpreter='',
                         rpath='$ORIGIN', needed=['existing.so', '../escape', '/absolute'])
            plan = dict(node_addon_root='runtime/installer/node_modules/', node_libraries='/nix/store/node-libc/lib')
            relocator.supply_origin_libraries(root, entry, plan)
            self.assertEqual((native / 'existing.so').read_bytes(), b'vendor')
            self.assertFalse((native.parent / 'escape').exists())
            (libc / 'escape.so').symlink_to('/etc/passwd')
            with self.assertRaisesRegex(ValueError, 'escapes the release'):
                relocator.supply_origin_libraries(root, dict(entry, needed=['escape.so']), plan)

    def test_bootstrap_links_can_be_rewritten_in_readonly_copied_directories(self):
        with tempfile.TemporaryDirectory(prefix='standard-links-') as temp:
            root = Path(temp)
            parent = root / 'runtime/package/lib'
            parent.mkdir(parents=True)
            (parent / 'config').symlink_to('/nix/store/dependency/config')
            parent.chmod(0o555)
            producer.relativize_store_links(root)
            self.assertEqual((parent / 'config').readlink(), Path('../../dependency/config'))

    def test_compiled_shell_paths_preserve_elf_offsets_and_suffixes(self):
        shell = b'/nix/store/' + b'a' * 32 + b'-bash-5.3/bin/bash'
        original = b'prefix\0' + shell + b'\0suffix'
        result = relocator.portable_shell_literals(original)
        self.assertEqual(len(result), len(original))
        self.assertEqual(result[:7], original[:7])
        self.assertTrue(result.endswith(b'/bin/sh\0suffix'))
        self.assertNotIn(b'/nix/store/', result)
        self.assertEqual(relocator.portable_shell_literals(b'/nix/store/not-a-shell'), b'/nix/store/not-a-shell')

    def test_rejects_escaping_members(self):
        for name in ('../outside', '/outside'):
            with self.assertRaises(ValueError):
                relocator.member(Path('/release'), name)

    def test_rewrites_wrappers_and_links_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix='standard-runtime-') as temp:
            root = Path(temp)
            (root / 'runtime').mkdir()
            (root / 'runtime/wrapper').write_text('#!/nix/store/bash/bin/bash\n')
            (root / 'link').symlink_to('/nix/store/python/bin/python3')
            plan = dict(symlinks={'link': '/nix/store/python/bin/python3'}, elfs=[],
                        texts=['runtime/wrapper'], patcher_loader='loader', patcher_libraries='', patcher='patcher',
                        environment={'SSL_CERT_FILE': '/nix/store/cert/bundle'},
                        commands={'dearmachine': '/nix/store/client/bin/dearmachine'})
            (root / 'relocation.json').write_text(json.dumps(plan))
            relocator.relocate(root)
            self.assertEqual((root / 'link').readlink(), root / 'runtime/python/bin/python3')
            self.assertNotIn('/nix/store/', (root / 'runtime/wrapper').read_text())
            script = (root / 'bin/dearmachine').read_text()
            self.assertIn('MACHTIANI_DISTRIBUTION=', script)
            self.assertNotIn('/nix/store/', script)
            relocator.relocate(root)
            (root / '.relocated').write_text('/old/location')
            with self.assertRaises(ValueError):
                relocator.relocate(root)

    def test_rejects_unsupported_shebang_path_before_mutation(self):
        with tempfile.TemporaryDirectory(prefix='standard runtime ') as temp:
            with self.assertRaisesRegex(ValueError, 'without whitespace'):
                relocator.relocate(Path(temp))


if __name__ == '__main__':
    unittest.main()
