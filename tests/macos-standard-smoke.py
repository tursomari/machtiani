#!/usr/bin/env python3
"""Execute a built Standard runtime inside macOS; no external model/mail calls."""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Run this gate inside macOS; Linux execution is not macOS verification.')
    root = Path(sys.argv[1]).resolve()
    manifest = json.loads((root / 'distribution.json').read_text())
    arch = 'arm64' if platform.machine() == 'arm64' else 'x64'
    assert manifest['platform'] == 'darwin-' + arch
    assert manifest['method'] == 'standard'
    with tempfile.TemporaryDirectory(prefix='standard-macos-smoke-') as directory:
        home = Path(directory)
        environment = dict(HOME=str(home), TMPDIR=directory, PATH=str(root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
                           XDG_CONFIG_HOME=str(home / '.config'), XDG_DATA_HOME=str(home / '.local/share'),
                           GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', LANG='en_US.UTF-8')
        def run(*args, expected=0, timeout=120):
            result = subprocess.run(list(map(str,args)), cwd=home, env=environment, text=True, capture_output=True, timeout=timeout)
            assert result.returncode == expected, (args, result.returncode, result.stderr[-3000:])
            return result.stdout
        for name in ('dearmachine', 'agent-manager', 'machtiani-installer', 'machtiani-model-host'):
            run(root / 'bin' / name, '--help')
        run(root / 'bin/machtiani', '--version')
        for name in ('node', 'python3', 'bash', 'rg'):
            run(root / 'bin' / name, '--version')
        run(root / 'bin/git', '--version')
        run(root / 'bin/git-lfs', 'version')
        run(root / 'runtime/vendor/claude', '--version')
        assert 'GNU sed' in run(root / 'bin/sed', '--version')
        assert 'coreutils' in run(root / 'bin/timeout', '--version')
        run(root / 'bin/node', '-e', 'require("node:child_process").execFileSync(process.execPath, ["-e", "console.log(42)"])')
        # Tests real packaged DSH/model-host streaming and native shell execution,
        # for installation and management, against a loopback-only HTTP model.
        run(root / 'bin/node', Path(__file__).with_name('standard-agent-smoke.mjs'),
            root / 'runtime/installer', root / 'source', home, 'workspace', timeout=180)
        repo = home / 'repo'
        run('git', 'init', '-q', repo)
        run('git', '-C', repo, 'lfs', 'install', '--local')
        run('git', '-C', repo, 'lfs', 'track', '*.bin')
        (repo / 'fixture.bin').write_bytes(b'Native macOS Standard LFS test\n')
        run('git', '-C', repo, 'add', '.gitattributes', 'fixture.bin')
        run('git', '-C', repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture')
        assert 'https://git-lfs.github.com/spec/v1' in run('git', '-C', repo, 'show', 'HEAD:fixture.bin')
        assert not (home / '.dearmachine').exists()
        print('MACOS_STANDARD_RUNTIME_OK: ' + arch + '; native products, provider runtime, GNU tools, agent tool round trips and Git LFS')

if __name__ == '__main__': main()
