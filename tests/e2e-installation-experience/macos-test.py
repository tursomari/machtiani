#!/usr/bin/env python3
"""Credential-free boundary checks for the macOS IXE adapter (runs on Linux too)."""
# This directory also contains operator.py; do not shadow Python's operator.
import os
import sys
sys.path = [entry for entry in sys.path if os.path.realpath(entry) != os.path.dirname(os.path.realpath(__file__))]
import importlib.util
import json
from pathlib import Path
import sqlite3
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


host, guest, nix = load('macos'), load('macos-guest'), load('macos-nix')


class MacIXE(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source'
        for name in ('dearmachine', 'machtiani-harness', 'dearmachine-concierge', 'scripts'):
            (self.source / name).mkdir(parents=True)
        (self.root / 'home').mkdir()
        (self.root / 'state').mkdir()

    def test_environment_does_not_inherit_credentials_or_host_paths(self):
        with patch.dict(os.environ, {'API_KEY': 'fake-sensitive-value', 'PATH': '/nix/bin', 'HOME': '/real/home'}):
            env = guest.environment(self.root)
        self.assertNotIn('API_KEY', env)
        self.assertEqual(env['PATH'].split(':'), [
            str(self.root / 'home/.local/bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin',
        ])
        self.assertEqual(env['HOME'], str(self.root / 'home'))
        self.assertEqual(env['XDG_STATE_HOME'], str(self.root / 'state'))

    def test_cleanup_retires_private_launchd_before_home_removal(self):
        state = self.root / 'home/.dearmachine'
        state.mkdir()
        (state / 'supervision.json').write_text('{"version":1,"useLaunchd":true}')
        launcher = self.root / 'home/.local/bin/dearmachine'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('fixture')
        with patch.object(guest.subprocess, 'run') as run:
            guest.cleanup_launchd(self.root)
        self.assertEqual([call.args[0][1:] for call in run.call_args_list],
                         [['persistence', 'off'], ['launchd', 'off']])
        self.assertTrue(all(call.kwargs['check'] for call in run.call_args_list))
        with patch.object(guest.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'fixture')):
            with self.assertRaises(subprocess.CalledProcessError):
                guest.cleanup_launchd(self.root)
        self.assertTrue(state.exists())

    def test_cleanup_without_launchd_does_not_call_new_cli_commands(self):
        with patch.object(guest.subprocess, 'run') as run:
            guest.cleanup_launchd(self.root)
            state = self.root / 'home/.dearmachine'
            (state / 'launchd').mkdir(parents=True)
            (state / 'supervision.json').write_text('{"version":1,"useLaunchd":false}')
            guest.cleanup_launchd(self.root)
        run.assert_not_called()

    def test_cleanup_retires_definition_without_saved_service_consent(self):
        definitions = self.root / 'home/.dearmachine/launchd'
        definitions.mkdir(parents=True)
        (definitions / 'fixture.plist').write_text('fixture')
        launcher = self.root / 'home/.local/bin/dearmachine'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('fixture')
        with patch.object(guest.subprocess, 'run') as run:
            guest.cleanup_launchd(self.root)
        self.assertEqual([call.args[0][1:] for call in run.call_args_list], [['launchd', 'off']])

    def test_cache_allows_guidance_but_rejects_runtime_changes(self):
        path = self.source / 'dearmachine-concierge/package.json'
        path.write_text('{"version":1}')
        before = guest.runtime_inputs(self.source)
        (self.source / 'dearmachine-concierge/README.md').write_text('new guidance')
        (self.source / 'dearmachine-concierge/tests').mkdir()
        (self.source / 'dearmachine-concierge/tests/extra.py').write_text('new test')
        self.assertEqual(guest.runtime_inputs(self.source), before)
        path.write_text('{"version":2}')
        self.assertNotEqual(guest.runtime_inputs(self.source), before)

    def test_embedded_markdown_is_a_runtime_input(self):
        path=self.source/'dearmachine/dearmachine/internal/entrypoint/seed/README.md'
        path.parent.mkdir(parents=True);path.write_text('embedded old')
        before=guest.runtime_inputs(self.source)
        path.write_text('embedded new')
        self.assertNotEqual(guest.runtime_inputs(self.source),before)

    def test_cache_ignores_umask_but_preserves_executable_bits(self):
        path=self.source/'scripts/build.sh';path.write_text('echo build');path.chmod(0o644)
        before=guest.runtime_inputs(self.source)
        path.chmod(0o664);self.assertEqual(guest.runtime_inputs(self.source),before)
        path.chmod(0o755);self.assertNotEqual(guest.runtime_inputs(self.source),before)

    def test_cache_rejects_tool_pin_and_symlink_changes(self):
        path = self.source / 'scripts/macos-dependencies.json'
        path.write_text('{"sha256":"old"}')
        before = guest.runtime_inputs(self.source)
        path.write_text('{"sha256":"new"}')
        self.assertNotEqual(guest.runtime_inputs(self.source), before)
        path.unlink(); path.symlink_to('other-file')
        self.assertNotEqual(guest.runtime_inputs(self.source), before)

    def test_cache_rejects_wrong_architecture_before_clone(self):
        cache = self.root / 'cache'; cache.mkdir()
        (cache / 'distribution.json').write_text(json.dumps(dict(platform='linux-x64', method='standard', acquisition='native')))
        with patch.object(guest.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'architecture'):
                guest.reuse_runtime(self.root, cache)
            run.assert_not_called()

    def test_active_terminal_blocks_other_operations(self):
        with guest.lock(self.root):
            with self.assertRaisesRegex(ValueError, 'still active'):
                with guest.lock(self.root):
                    self.fail('second lock admitted')

    def test_private_state_and_identity_validation(self):
        path = self.root / 'state.json'
        data = dict(version=1, id='a' * 12, remote='/private/tmp/dmixe-' + 'a' * 12)
        host.save(path, data)
        self.assertEqual(host.read_state(path), data)
        path.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'owner-only'):
            host.read_state(path)
        path.chmod(0o600);data['remote']='/private/tmp/unrelated';host.save(path, data)
        with self.assertRaisesRegex(ValueError, 'ownership'):
            host.read_state(path)

    def test_state_symlink_is_rejected(self):
        target = self.root / 'target'; target.write_text('{}');target.chmod(0o600)
        link = self.root / 'state.json';link.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'owner-only'):
            host.read_state(link)

    def test_launcher_outside_private_root_is_not_executed(self):
        launch = self.root / 'home/.local/bin/dearmachine';launch.parent.mkdir(parents=True)
        launch.symlink_to(shutil.which('true'))
        with patch.object(guest.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'escapes'):
                guest.status(self.root)
            run.assert_not_called()

    def test_ssh_arguments_and_remote_paths_are_quoted(self):
        state = dict(ssh=['ssh', '-F', '/tmp/config with spaces'], host='mac-test')
        with patch.object(host.subprocess, 'run') as run:
            host.remote(state, ['python3', '/tmp/file; touch bad'])
            argv = run.call_args.args[0]
        self.assertEqual(argv[-2], 'mac-test')
        self.assertEqual(argv[-1], "python3 '/tmp/file; touch bad'")
        self.assertIn('/tmp/config with spaces', argv)

    def fixture_run(self, *, processed=1, pending=0):
        module = self.source / 'scripts/container-build.py'
        module.write_text('def fingerprint(root):\n return "same"\n')
        guest.save(self.root / 'run.json', dict(phase='session-ended', mode='cached-runtime', platform='x86_64',
                   source_before='same', installer_exit=0, after_installer={'running':True}))
        database = self.root / 'home/.dearmachine/pairs/test/state/dearmachine.db'
        database.parent.mkdir(parents=True)
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE pending_messages(id)')
            db.execute('CREATE TABLE processed_messages(outbound_message_id)')
            for _ in range(pending):db.execute('INSERT INTO pending_messages VALUES(1)')
            for _ in range(processed):db.execute("INSERT INTO processed_messages VALUES('reply')")

    def test_verifier_requires_an_outbound_reply(self):
        self.fixture_run(processed=0)
        with patch.object(guest, 'status', return_value={'installed':True,'running':True}):
            result = guest.verify(self.root)
        self.assertFalse(result['passed'])

    def test_verifier_rejects_pending_work(self):
        self.fixture_run(pending=1)
        with patch.object(guest, 'status', return_value={'installed':True,'running':True}):
            self.assertFalse(guest.verify(self.root)['passed'])

    def test_verifier_allows_intentional_post_test_stop(self):
        self.fixture_run()
        with patch.object(guest, 'status', return_value={'installed':True,'running':False}):
            result = guest.verify(self.root)
        self.assertTrue(result['passed'])
        self.assertIn('human UX', result['scope'])

    def test_source_changes_fail_verification(self):
        self.fixture_run()
        info=json.loads((self.root/'run.json').read_text());info['source_before']='before';guest.save(self.root/'run.json',info)
        with patch.object(guest, 'status', return_value={'installed':True,'running':True}):
            self.assertFalse(guest.verify(self.root)['passed'])

    def test_failed_preparation_cleanup_preserves_other_processes(self):
        unrelated=self.root.parent/'unrelated-macos-ixe-test'
        with patch.object(guest,'status',return_value={'installed':False}), \
             patch.object(guest.subprocess,'check_output',return_value='123 /some/other/release/dearmachine\n'), \
             patch.object(guest.os,'kill') as kill:
            result=guest.cleanup(self.root)
        kill.assert_not_called();self.assertTrue(result['cleaned']);self.assertFalse(self.root.exists())

    def test_scan_reports_counts_without_exposing_values(self):
        guest.save(self.root/'run.json',dict(release=str(self.root/'release')))
        (self.root/'state/session.jsonl').write_text('accidental fake-key')
        (self.root/'home/credential-api-key').write_text('fake-key')
        result=guest.scan(self.root,['fake-key'])
        self.assertEqual(result['known_key_occurrences'],1)
        self.assertFalse(result['passed'])
        self.assertNotIn('fake-key',json.dumps(result))

    def test_compressed_scan_checks_decoded_bytes(self):
        guest.save(self.root/'run.json',dict(release=str(self.root/'release')))
        (self.root/'state/session.jsonl.zstd').write_bytes(b'compressed-data')
        with patch.object(guest,'decode_zstd',return_value=b'fake-key'):
            self.assertEqual(guest.scan(self.root,['fake-key'])['known_key_occurrences'],1)

    def test_real_zstd_multiframe_and_truncated_evidence(self):
        node=os.environ.get('MACOS_IXE_TEST_NODE') or shutil.which('node')
        if not node:
            self.skipTest('Node with Zstandard is not available')
        probe=subprocess.run([node,'-e',"process.exit(typeof require('node:zlib').zstdCompressSync === 'function' ? 0 : 1)"],capture_output=True)
        if probe.returncode:
            self.skipTest('Node lacks Zstandard support')
        compressed=subprocess.check_output([node,'-e',"const z=require('node:zlib');process.stdout.write(Buffer.concat([z.zstdCompressSync(Buffer.from('fake-ixe-')),z.zstdCompressSync(Buffer.from('regression-token'))]));"])
        self.assertEqual(guest.decode_zstd(node,compressed),b'fake-ixe-regression-token')
        with self.assertRaises(ValueError):
            guest.decode_zstd(node,compressed[:-1])
        with self.assertRaises(ValueError):
            guest.decode_zstd(node,compressed+b'garbage')

    def test_export_refuses_secret_and_empty_evidence(self):
        guest.save(self.root/'run.json',dict(release=str(self.root/'release')))
        with self.assertRaisesRegex(ValueError,'refused'):
            guest.scan(self.root,['fake-key'],export=True)
        (self.root/'state/session.jsonl').write_text('fake-key')
        with self.assertRaisesRegex(ValueError,'refused'):
            guest.scan(self.root,['fake-key'],export=True)

    def test_export_excludes_credential_stores(self):
        import io,tarfile
        guest.save(self.root/'run.json',dict(release=str(self.root/'release')))
        (self.root/'home/private-api-key').write_text('fake-key')
        (self.root/'state/session.jsonl').write_text('safe conversation')
        archive=guest.scan(self.root,['fake-key'],export=True)
        with tarfile.open(fileobj=io.BytesIO(archive),mode='r:gz') as bundle:
            self.assertEqual(bundle.getnames(),['state/session.jsonl'])
            self.assertEqual(bundle.getmembers()[0].mode,0o600)

    def test_cleanup_refuses_remaining_test_process(self):
        with patch.object(guest,'status',return_value={'installed':False}), \
             patch.object(guest.subprocess,'check_output',return_value='123 '+str(self.root/'home/.local/bin/omp')+'\n'):
            with self.assertRaisesRegex(ValueError,'still active'):
                guest.cleanup(self.root)
        self.assertTrue(self.root.exists())

    def test_cached_session_uses_manifest_source_and_is_single_use(self):
        release=self.root/'release';release.mkdir()
        guest.save(self.root/'run.json',dict(phase='ready',mode='cached-runtime',release=str(release)))
        with patch.object(guest.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run, \
             patch.object(guest,'status',return_value={'installed':False,'running':False}):
            guest.session(self.root)
        self.assertEqual(run.call_args.args[0][-2:],['--source-root',str(release/'source')])
        with self.assertRaisesRegex(ValueError,'already run'):
            guest.session(self.root)


    def test_cleanup_uses_matching_local_nix_helper_after_source_revision_changes(self):
        with patch.object(guest,'NIX_ADAPTER_SOURCE','VERSION = 7',create=True):
            self.assertEqual(guest.nix_adapter(self.root).VERSION,7)

    def test_nix_receipt_validates_revisions_roots_and_launcher_ownership(self):
        revision='a'*40;managed=self.root/'home/.local/share/dearmachine';release=managed/'releases'/revision
        (release/'bin').mkdir(parents=True);(release/'roots').mkdir();(managed/'sources'/revision).mkdir(parents=True)
        (managed/'current').symlink_to(release)
        info={'revisions':{'.':revision,'dearmachine':'b'*40,'machtiani-harness':'c'*40,'dearmachine-concierge':'d'*40}}
        binaries={}
        public=self.root/'home/.local/bin';public.mkdir(parents=True)
        for name in ('dearmachine','agent-manager','machtiani','machtiani-installer','machtiani-model-host'):
            component='dearmachine' if name in ('dearmachine','agent-manager') else 'machtiani-harness' if name=='machtiani' else 'dearmachine-concierge'
            store=Path('/nix/store/'+('e'*32)+'-'+component)
            binaries[name]=str(store/'bin'/name)
            (release/'bin'/name).write_text('fixture')
            (public/name).symlink_to(managed/'current/bin'/name)
            root=release/'roots'/component
            if not root.is_symlink():root.symlink_to(store)
        value={'method':'nix','revision':revision,'revisions':info['revisions'],'sourceRoot':str(managed/'sources'/revision),'remote':nix.REMOTE,'binaries':binaries}
        guest.save(release/'release.json',value)
        actual=Path.is_file
        with patch.object(Path,'is_file',lambda path: True if str(path).startswith('/nix/store/') else actual(path)):
            self.assertEqual(nix.receipt(self.root,info),value)
            (public/'dearmachine').unlink();(public/'dearmachine').symlink_to(self.root/'foreign')
            with self.assertRaisesRegex(ValueError,'launcher differs'):
                nix.receipt(self.root,info)
        value['revisions']={'.':'f'*40};guest.save(release/'release.json',value)
        with self.assertRaisesRegex(ValueError,'does not match'):
            nix.receipt(self.root,info)

    def test_nix_environment_exposes_only_private_profile_and_system_nix(self):
        guest.save(self.root/'run.json',dict(mode='nix'))
        with patch.object(guest,'nix_adapter',return_value=nix), patch.dict(os.environ,{'API_KEY':'secret','NIX_CONFIG':'access-tokens = secret'}):
            env=guest.environment(self.root)
        self.assertIn(nix.NIX_BIN,env['PATH'])
        self.assertIn(str(self.root/'home/.nix-profile/bin'),env['PATH'])
        self.assertEqual(env['GIT_CONFIG_GLOBAL'],str(self.root/'home/.gitconfig'))
        self.assertNotIn('secret',json.dumps(env))
        self.assertIn('nix-command flakes',env['NIX_CONFIG'])

    def test_nix_session_uses_git_checkout_and_nix_bootstrap(self):
        guest.save(self.root/'run.json',dict(phase='ready',mode='nix',checkout=str(self.root/'checkout')))
        with patch.object(guest,'nix_adapter',return_value=nix), \
             patch.object(guest.subprocess,'run',return_value=subprocess.CompletedProcess([],0)) as run, \
             patch.object(guest,'status',return_value={'installed':False,'running':False}):
            guest.session(self.root)
        self.assertEqual(run.call_args.args[0],[str(self.root/'bootstrap/bin/machtiani-installer'),'--install','--source-root',str(self.root/'checkout')])

    def test_nix_archive_digest_ignores_git_and_generated_provenance_only(self):
        source=self.root/'checkout';source.mkdir();(source/'code').write_text('code')
        before=nix.source_digest(source)
        (source/'.git').mkdir();(source/'.git/config').write_text('local config')
        (source/'bootstrap-source-revisions.json').write_text('{}')
        self.assertEqual(nix.source_digest(source),before)
        (source/'code').write_text('modified')
        self.assertNotEqual(nix.source_digest(source),before)

    def test_nix_source_export_contains_only_current_commit_and_tree(self):
        repo=self.root/'repo';repo.mkdir()
        def git(*args):
            return subprocess.check_output(['git','-C',str(repo),*args],stderr=subprocess.DEVNULL)
        git('init','-q');git('config','user.name','IXE test');git('config','user.email','ixe@example.invalid')
        (repo/'old-private-note').write_text('history-only-canary')
        git('add','.');git('commit','-qm','old')
        old=git('rev-parse','HEAD').decode().strip()
        git('rm','old-private-note');(repo/'file').write_text('current')
        git('add','.');git('commit','-qm','current')
        (repo/'.git/private-config').write_text('host-config-canary')
        records=nix.export_sources(repo,self.root/'transfer')
        target=self.root/'restored';target.mkdir()
        subprocess.run(['git','init','-q',str(target)],check=True)
        with (self.root/'transfer/0.pack').open('rb') as stream:
            subprocess.run(['git','-C',str(target),'index-pack','--stdin'],stdin=stream,stdout=subprocess.DEVNULL,check=True)
        self.assertNotEqual(subprocess.run(['git','-C',str(target),'cat-file','-e',old],stderr=subprocess.DEVNULL).returncode,0)
        self.assertEqual(subprocess.check_output(['git','-C',str(target),'show',records[0]['revision']+':file']),b'current')
        self.assertFalse((target/'.git/private-config').exists())
        streamed={}
        self.assertEqual(nix.export_sources(repo,self.root/'stream-transfer',streamed.__setitem__),records)
        self.assertTrue(streamed['0.pack'].startswith(b'PACK'))
        self.assertFalse((self.root/'stream-transfer/0.pack').exists())

    def test_nix_source_export_refuses_dirty_or_sensitive_tracked_files(self):
        repo=self.root/'repo';repo.mkdir()
        def git(*args):
            subprocess.run(['git','-C',str(repo),*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        git('init','-q');git('config','user.name','IXE test');git('config','user.email','ixe@example.invalid')
        (repo/'.env').write_text('fake-secret');git('add','.');git('commit','-qm','fixture')
        with self.assertRaisesRegex(ValueError,'Private or unsafe'):
            nix.export_sources(repo,self.root/'transfer')
        (repo/'untracked').write_text('file')
        with self.assertRaisesRegex(ValueError,'clean recursive'):
            nix.export_sources(repo,self.root/'transfer2')

    def test_nix_receipt_rejects_foreign_active_release(self):
        current=self.root/'home/.local/share/dearmachine/current';current.parent.mkdir(parents=True)
        current.symlink_to('/nix/store/unrelated')
        with self.assertRaisesRegex(ValueError,'escapes or differs'):
            nix.receipt(self.root,{'revisions':{'.':'a'*40}})

    def test_nix_shutdown_uses_private_home_protocol_not_pid_kill(self):
        with patch.object(nix,'receipt',return_value={'method':'nix'}), \
             patch.object(nix.subprocess,'run') as run, patch.object(nix.os,'kill') as kill:
            nix.shutdown(self.root,{'HOME':str(self.root/'home')},{})
        self.assertEqual(run.call_args.args[0], [str(self.root/'home/.local/bin/dearmachine'),'_update-control','stop'])
        self.assertEqual(run.call_args.kwargs['env']['HOME'],str(self.root/'home'))
        kill.assert_not_called()

    def test_nix_shutdown_refuses_active_supervisor_lock(self):
        import fcntl
        path=self.root/'home/.dearmachine/run/supervisor.lock';path.parent.mkdir(parents=True)
        with path.open('w') as stream, patch.object(nix,'receipt',return_value=None):
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError,'still owns'):
                nix.shutdown(self.root,{}, {})

    def test_nix_cleanup_rejects_process_with_open_private_files(self):
        with patch.object(nix.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='123456\n',stderr='')):
            with self.assertRaisesRegex(ValueError,'still has'):
                nix.assert_no_open_processes(self.root)
        with patch.object(nix.subprocess,'run',return_value=subprocess.CompletedProcess([],1,stdout='',stderr='')):
            nix.assert_no_open_processes(self.root)

    def test_nix_verification_rejects_wrong_source(self):
        self.fixture_run()
        info=guest.run_info(self.root);info['mode']='nix';guest.save(self.root/'run.json',info)
        with patch.object(guest,'nix_adapter',return_value=nix), \
             patch.object(nix,'verify_sources',return_value=False), \
             patch.object(guest,'status',return_value={'installed':True,'running':True}):
            self.assertFalse(guest.verify(self.root)['passed'])

    def test_key_scan_rejects_public_files_and_symlinks(self):
        key=self.root/'key';key.write_text('fake-key');key.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'owner-only'):
            host.scan_keys([key])
        key.chmod(0o600);self.assertEqual(json.loads(host.scan_keys([key])),['fake-key'])
        link=self.root/'link';link.symlink_to(key)
        with self.assertRaisesRegex(ValueError,'owner-only'):
            host.scan_keys([link])


if __name__ == '__main__':
    unittest.main()
