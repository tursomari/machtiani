#!/usr/bin/env python3
"""Exercise the rendered release installer against a tiny, non-product release.

A stub gh serves release files from a local directory and reports a chosen
attestation result; a loopback server stands in for GitHub release downloads
when gh is unavailable. Consent is answered through a real pseudo-terminal.
"""
import functools
import hashlib
import http.server
import importlib.util
import io
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import threading
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
TAG = 'v0.1.0-rc.1'
PREFIX = 'dearmachine-' + TAG + '-linux-x64'
BUNDLE = 'attestation.sigstore.json'
PRODUCTS = ('dearmachine', 'machtiani', 'machtiani-installer', 'machtiani-model-host', 'agent-manager')


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


download = load('download', 'prepare-standard-download.py')
renderer = load('renderer', 'render-release-installers.py')

GH_STUB = '''#!/bin/sh
# Test double for gh: logs calls and serves files from $GH_RELEASE_DIR.
printf '%s\\n' "$*" >> "$GH_LOG"
if [ -n "${GH_FOREIGN:-}" ]; then
  printf 'Usage: gh [OPTIONS] COMMAND [ARGS]...\nTry "gh --help" for help.\n\nError: No such option: %s\n' "$1" >&2
  exit 2
fi
if [ "$1" = --version ]; then echo "gh version ${GH_VERSION:-2.101.0} (2026-09-15)"; exit 0; fi
case "$1 $2" in
  'auth status') exit "${GH_AUTH_STATUS:-0}" ;;
  'attestation verify') echo 'stub verification output'; exit "${GH_VERIFY_STATUS:-0}" ;;
  'release download')
    shift 3
    directory=.
    patterns=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dir) directory=$2; shift 2 ;;
        --pattern) patterns="$patterns $2"; shift 2 ;;
        *) shift ;;
      esac
    done
    for name in $patterns; do cp "$GH_RELEASE_DIR/$name" "$directory/$name" || exit 1; done
    exit 0 ;;
esac
exit 2
'''


@unittest.skipUnless(platform.system() == 'Linux' and platform.machine() == 'x86_64', 'linux-x64 fixture')
class ReleaseInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='release-install-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.release = self.root / 'release'
        self.release.mkdir()
        self.requests = []

        archive = self.release / (PREFIX + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ('bootstrap-runtime.sh', *('bin/' + name for name in (*PRODUCTS, 'git-lfs', 'python3'))):
                content = b'#!/bin/sh\nexit 0\n'
                info = tarfile.TarInfo(name)
                info.size = len(content)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(content))

        requests = self.requests

        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                super().do_GET()

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(self.release)))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        url = 'http://127.0.0.1:' + str(self.server.server_port)

        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.release / (PREFIX + '.bootstrap.sh')).write_text(
            download.render_bootstrap(url, digest, 'fixture', PREFIX + '.tar.gz'))
        # The stub verifier does not read it; real releases publish a signed bundle.
        (self.release / BUNDLE).write_text('{"placeholder": true}\n')
        self.write_sums()
        self.script = renderer.render('example-owner/example-repo', TAG, 'refs/tags/' + TAG, url)['install.sh']

        self.fake_bin = self.root / 'fake-bin'
        self.fake_bin.mkdir()
        (self.fake_bin / 'gh').write_text(GH_STUB)
        (self.fake_bin / 'gh').chmod(0o755)
        self.gh_log = self.root / 'gh.log'
        self.environment = dict(HOME=str(self.home), XDG_DATA_HOME=str(self.home / '.local/share'),
                                TMPDIR=str(self.root), PATH=str(self.fake_bin) + ':/usr/bin:/bin',
                                GH_LOG=str(self.gh_log), GH_RELEASE_DIR=str(self.release))

    def write_sums(self):
        lines = []
        for path in sorted(self.release.iterdir()):
            if path.name not in ('SHA256SUMS', BUNDLE):
                lines.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n')
        (self.release / 'SHA256SUMS').write_text(''.join(lines))

    def without_gh(self):
        self.environment['PATH'] = '/usr/bin:/bin'

    def run_installer(self, answer=None):
        """Pipe the script to sh as curl would; optionally answer on a terminal."""
        if answer is None:
            return subprocess.run(['sh'], input=self.script, text=True, capture_output=True,
                                  env=self.environment, start_new_session=True)
        master, slave = os.openpty()
        slave_name = os.ttyname(slave)
        os.close(slave)

        def controlling_terminal():
            os.setsid()
            os.close(os.open(slave_name, os.O_RDWR))

        try:
            os.write(master, (answer + '\n').encode())
            return subprocess.run(['sh'], input=self.script, text=True, capture_output=True,
                                  env=self.environment, preexec_fn=controlling_terminal)
        finally:
            os.close(master)

    def assert_installed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in PRODUCTS:
            self.assertTrue((self.home / '.local/bin' / name).is_symlink(), name)

    def assert_not_installed(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / '.local/bin/dearmachine').exists())
        self.assertFalse((self.home / '.local/share/dearmachine/releases').exists() and
                         any((self.home / '.local/share/dearmachine/releases').iterdir()))
        self.assertEqual([path for path in self.root.iterdir() if path.name.startswith('dearmachine-install.')], [])

    def test_verified_install_checks_attestation_and_uses_gh_downloads(self):
        result = self.run_installer()
        self.assert_installed(result)
        self.assertIn('Release verified.', result.stderr)
        calls = self.gh_log.read_text()
        self.assertIn('attestation verify', calls)
        self.assertIn('--repo example-owner/example-repo', calls)
        self.assertIn('--signer-workflow example-owner/example-repo/.github/workflows/release.yml', calls)
        self.assertIn('--source-ref refs/tags/' + TAG, calls)
        self.assertIn('--deny-self-hosted-runners', calls)
        self.assertIn('--bundle ', calls)
        self.assertLess(calls.index('attestation verify'), calls.index('--pattern ' + PREFIX))
        self.assertEqual(self.requests, [])

    def test_failed_attestation_stops_without_offering_to_continue(self):
        self.environment['GH_VERIFY_STATUS'] = '1'
        result = self.run_installer(answer='yes')
        self.assert_not_installed(result)
        self.assertIn('could not be verified', result.stderr)
        self.assertNotIn('Type yes', result.stderr)
        self.assertNotIn(PREFIX, self.gh_log.read_text())

    def test_checksum_mismatch_stops_before_bootstrap(self):
        (self.release / (PREFIX + '.tar.gz')).write_bytes(b'altered')
        result = self.run_installer()
        self.assert_not_installed(result)
        self.assertIn('does not match the release checksums', result.stderr)

    def test_release_without_this_target_says_so(self):
        (self.release / 'SHA256SUMS').write_text('0' * 64 + '  dearmachine-' + TAG + '-windows-x64.zip\n')
        result = self.run_installer()
        self.assert_not_installed(result)
        self.assertIn('has no download for linux-x64', result.stderr)

    def test_missing_gh_without_terminal_installs_nothing(self):
        self.without_gh()
        result = self.run_installer()
        self.assert_not_installed(result)
        self.assertIn("gh isn't installed", result.stderr)
        self.assertIn('https://cli.github.com', result.stderr)
        self.assertIn('no terminal to confirm', result.stderr)
        self.assertEqual(self.requests, [])

    def test_missing_gh_and_declined_installs_nothing(self):
        self.without_gh()
        for answer in ('', 'no', 'y', 'YES'):
            with self.subTest(answer=answer):
                result = self.run_installer(answer=answer)
                self.assert_not_installed(result)
                self.assertIn('Stopped. Nothing was installed.', result.stderr)
        self.assertEqual(self.requests, [])

    def test_missing_gh_and_yes_installs_with_checksums_only(self):
        self.without_gh()
        result = self.run_installer(answer='yes')
        self.assert_installed(result)
        self.assertIn('Continuing without the release check.', result.stderr)
        self.assertEqual(sorted(self.requests), sorted(['/SHA256SUMS', '/' + PREFIX + '.bootstrap.sh', '/' + PREFIX + '.tar.gz']))

    def test_outdated_gh_explains_update_and_never_runs_old_verifier(self):
        for version in ('2.55.0', '2.67.1', '1.99.0'):
            with self.subTest(version=version):
                self.environment['GH_VERSION'] = version
                self.gh_log.write_text('')
                result = self.run_installer(answer='')
                self.assert_not_installed(result)
                self.assertIn('too old', result.stderr)
                self.assertIn('2.68.0 or newer', result.stderr)
                self.assertNotIn('attestation verify', self.gh_log.read_text())

    def test_other_program_named_gh_is_explained_not_called_outdated(self):
        self.environment['GH_FOREIGN'] = '1'
        result = self.run_installer(answer='')
        self.assert_not_installed(result)
        self.assertIn('a different program with the same name', result.stderr)
        self.assertIn('conda deactivate', result.stderr)
        self.assertNotIn('too old', result.stderr)
        result = self.run_installer(answer='yes')
        self.assert_installed(result)
        self.assertNotIn('attestation verify', self.gh_log.read_text())

    def test_supported_gh_versions_verify(self):
        for version in ('2.68.0', '2.101.0', '3.0.0'):
            with self.subTest(version=version):
                self.environment['GH_VERSION'] = version
                self.gh_log.write_text('')
                result = self.run_installer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('attestation verify', self.gh_log.read_text())

    def test_signed_out_gh_verifies_with_published_bundle_without_asking(self):
        self.environment['GH_AUTH_STATUS'] = '1'
        result = self.run_installer()
        self.assert_installed(result)
        self.assertIn('Release verified.', result.stderr)
        self.assertNotIn('Type yes', result.stderr)
        calls = self.gh_log.read_text()
        self.assertIn('attestation verify', calls)
        self.assertIn('--bundle ', calls)
        self.assertNotIn('release download', calls)
        self.assertEqual(sorted(self.requests), sorted(['/SHA256SUMS', '/' + BUNDLE, '/' + PREFIX + '.bootstrap.sh', '/' + PREFIX + '.tar.gz']))

    def test_signed_out_gh_without_bundle_explains_sign_in_and_accepts_yes(self):
        self.environment['GH_AUTH_STATUS'] = '1'
        (self.release / BUNDLE).unlink()
        result = self.run_installer(answer='yes')
        self.assert_installed(result)
        self.assertIn('can only be checked while gh is signed in', result.stderr)
        self.assertIn('gh auth login', result.stderr)
        self.assertNotIn('attestation verify', self.gh_log.read_text())

    def test_signed_in_gh_without_bundle_verifies_online(self):
        (self.release / BUNDLE).unlink()
        result = self.run_installer()
        self.assert_installed(result)
        calls = self.gh_log.read_text()
        self.assertIn('attestation verify', calls)
        self.assertNotIn('--bundle', calls)
        self.assertEqual(self.requests, [])


class RenderTests(unittest.TestCase):
    def test_renders_every_placeholder_with_quoting(self):
        scripts = renderer.render('example-owner/example-repo', TAG, 'refs/tags/' + TAG)
        self.assertIn("repository=example-owner/example-repo", scripts['install.sh'])
        self.assertIn("$repository = 'example-owner/example-repo'", scripts['install.ps1'])
        self.assertIn('https://github.com/example-owner/example-repo/releases/download/' + TAG, scripts['install.sh'])
        for text in scripts.values():
            self.assertNotRegex(text, r'@[A-Z_]+@')

    def test_rejects_unsafe_values(self):
        cases = [('owner/repo; rm -rf /', TAG, 'refs/tags/' + TAG, None),
                 ('owner/repo', 'latest', 'refs/tags/latest', None),
                 ('owner/repo', TAG, 'refs/tags/../x', None),
                 ('owner/repo', TAG, 'refs/pull/1/merge', None),
                 ('owner/repo', TAG, 'refs/tags/' + TAG, 'http://example.test')]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                renderer.render(*case)

    def test_packager_names_release_artifacts(self):
        self.assertEqual(download.artifact_names(), ('runtime.tar.gz', 'install', 'manifest.json'))
        self.assertEqual(download.artifact_names(PREFIX), (PREFIX + '.tar.gz', PREFIX + '.bootstrap.sh', PREFIX + '.manifest.json'))
        with self.assertRaises(ValueError):
            download.artifact_names('../escape')
        script = download.render_bootstrap('https://example.test/releases', 'a' * 64, 'fixture', PREFIX + '.tar.gz')
        self.assertIn('archive_name=' + PREFIX + '.tar.gz', script)
        self.assertIn("expected_platform='Linux x86_64'", script)
        with self.assertRaises(ValueError):
            download.render_bootstrap('https://example.test/releases', 'a' * 64, 'fixture', system='riscv64-linux')

    @unittest.skipUnless(platform.system() == 'Linux' and platform.machine() == 'x86_64', 'needs a non-ARM64 host')
    def test_bootstrap_refuses_other_platforms(self):
        script = download.render_bootstrap('https://example.test/releases', 'a' * 64, 'fixture', system='aarch64-linux')
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run(['sh'], input=script, text=True, capture_output=True,
                                    env=dict(HOME=home, PATH='/usr/bin:/bin'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('This download is for Linux aarch64 computers.', result.stderr)
        script = download.render_bootstrap('https://example.test/releases', 'a' * 64, 'fixture', system='aarch64-darwin')
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run(['sh'], input=script, text=True, capture_output=True,
                                    env=dict(HOME=home, PATH='/usr/bin:/bin'))
        self.assertIn('This download is for Darwin arm64 computers.', result.stderr)


if __name__ == '__main__':
    unittest.main()
