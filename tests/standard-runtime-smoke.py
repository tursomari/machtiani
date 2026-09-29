#!/usr/bin/env python3
"""Container-side portability gate; no provider, inbox, or host installation.

Run with the bundled Python and the absolute activated release path. The host
runner must copy this file and the release, never a Git checkout or credentials.
"""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    assert not Path('/nix').exists(), 'this gate requires a target without /nix'
    root = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='standard-smoke-') as directory:
        home = Path(directory)
        environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
            XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
            PATH=str(root / 'bin') + ':/usr/bin:/bin', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        def run(*args, expected=0, stdin=None, cwd=home):
            result = subprocess.run(args, input=stdin, cwd=cwd, env=environment,
                text=True, capture_output=True, timeout=30)
            assert result.returncode == expected, (args, result.returncode, result.stderr[-2000:])
            return result.stdout
        for command in ('dearmachine', 'agent-manager', 'machtiani-installer'):
            run(command, '--help')
        run('machtiani', '--version')
        assert 'Usage: machtiani-model-host' in run('machtiani-model-host', '--help')
        run('machtiani-model-host', expected=2)
        manifest = json.loads((root / 'distribution.json').read_text())
        deployed = manifest.get('installerLayout') == 'deployed'
        if 'installerRuntime' in manifest:
            installer_runtime = root / manifest['installerRuntime']
            claude = sorted({path.resolve() for path in (installer_runtime / 'node_modules').glob('**/@anthropic-ai/claude-agent-sdk-linux-x64/claude') if path.is_file()})
        else:
            claude = list((root / 'runtime').glob('*/libexec/machtiani-installer/vendor/claude/claude-nix'))
            installer_runtime = claude[0].parents[2] if claude else None
        assert len(claude) == 1, 'the release must contain the pinned Claude runtime'
        run(str(claude[0]), '--version')
        for command in ('node', 'python3', 'curl', 'sqlite3', 'git', 'rg', 'bash'):
            run(command, '--version')
        run('git', 'lfs', 'version')
        # Exercise child exec and loading Python's dynamically linked modules.
        run('python3', '-c', 'import ssl, sqlite3, subprocess; subprocess.run(["git", "--version"], check=True)')
        run('node', '-e', 'require("node:child_process").execFileSync(process.execPath, ["-e", "console.log(42)"])')
        run('node', str(Path(__file__).with_name('standard-agent-smoke.mjs')),
            str(installer_runtime), str(root / 'source'), str(home), 'deployed' if deployed else 'workspace')
        repository = home / 'repo'
        run('git', 'init', '-q', str(repository))
        run('git', '-C', str(repository), 'lfs', 'install', '--local')
        run('git', '-C', str(repository), 'lfs', 'track', '*.bin')
        (repository / 'example.bin').write_bytes(b'portable LFS round trip\n')
        run('git', '-C', str(repository), 'add', '.gitattributes', 'example.bin')
        run('git', '-C', str(repository), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'fixture')
        pointer = run('git', '-C', str(repository), 'show', 'HEAD:example.bin')
        assert 'https://git-lfs.github.com/spec/v1' in pointer
        # Profile validation/inference belongs to the model-host suite and IXE;
        # help output alone is not a successful provider check.
        assert not (home / '.dearmachine').exists(), 'smoke must not install/start a daemon'
        print('NO_NIX_RUNTIME_OK: product entrypoints, Node/Python child exec, Git LFS filter')


def container_smoke(image, base_image='debian:bookworm-slim'):
    """Exercise a raw runtime image without sharing a host path or socket."""
    containers = []
    def docker(*args, **kwargs):
        return subprocess.run(['docker', *map(str, args)], check=True, **kwargs)
    try:
        source = docker('create', image, '/bin/true', capture_output=True, text=True).stdout.strip()
        containers.append(source)
        target = docker('run', '--pull=never', '--detach', '--network=none', base_image,
                        'sleep', 'infinity', capture_output=True, text=True).stdout.strip()
        containers.append(target)
        docker('exec', target, 'sh', '-eu', '-c',
               'test ! -e /nix; ! command -v node; ! command -v python3; ! command -v go; ! command -v docker; mkdir -p /opt/runtime /tmp/smoke-home')
        copy = subprocess.Popen(['docker', 'cp', source + ':/release/.', '-'], stdout=subprocess.PIPE)
        try:
            docker('exec', '-i', target, 'tar', '-xf', '-', '-C', '/opt/runtime', stdin=copy.stdout)
        finally:
            copy.stdout.close()
            if copy.wait() != 0:
                raise RuntimeError('Could not transfer the raw runtime')
        docker('exec', target, 'chown', '-R', '1000:1000', '/opt/runtime', '/tmp/smoke-home')
        docker('exec', '--user', '1000:1000', '-e', 'HOME=/tmp/smoke-home', target,
               'sh', '/opt/runtime/bootstrap-runtime.sh')
        # Copy the current shared gate so test-only edits need no image rebuild.
        for name in ('standard-runtime-smoke.py', 'standard-agent-smoke.mjs'):
            docker('cp', Path(__file__).with_name(name), target + ':/tmp/' + name)
        docker('exec', '--user', '1000:1000', '-e', 'HOME=/tmp/smoke-home', target,
               '/opt/runtime/bin/python3', '/tmp/standard-runtime-smoke.py', '/opt/runtime')
    finally:
        for container in reversed(containers):
            subprocess.run(['docker', 'rm', '--force', container], check=False, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == '--image':
        container_smoke(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'debian:bookworm-slim')
    else:
        main()
