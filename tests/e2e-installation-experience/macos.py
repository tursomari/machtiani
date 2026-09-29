#!/usr/bin/env python3
"""Prepare and operate a private Standard or Nix IXE on an existing macOS SSH guest."""
# This directory also contains operator.py; do not shadow Python's operator.
import os
import sys
sys.path = [entry for entry in sys.path if os.path.realpath(entry) != os.path.dirname(os.path.realpath(__file__))]
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import uuid

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def save(path, value):
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.ixe-state-', delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def read_state(path):
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise ValueError('IXE state must be an owner-only regular file')
    value = json.loads(path.read_text())
    if value.get('version') != 1 or value['remote'] != '/private/tmp/dmixe-' + value['id']:
        raise ValueError('Invalid IXE ownership journal')
    if len(value['id']) != 12 or any(c not in '0123456789abcdef' for c in value['id']):
        raise ValueError('Invalid IXE identity')
    return value


def remote(state, argv, *, data=None, tty=False, capture=True):
    command = [*state['ssh'], '-tt' if tty else '-T', state['host'], shlex.join(map(str, argv))]
    return subprocess.run(command, input=data, stdout=subprocess.PIPE if capture else None,
                          stderr=None, check=True).stdout


def guest(state, action, *args, data=None):
    return remote(state, ['/usr/bin/python3', state['remote'] + '/guest.py',
                          '--root', state['remote'], '--token', state['token'], action, *args], data=data)


def check_source(source):
    for component in ('.', 'dearmachine', 'machtiani-harness', 'dearmachine-concierge'):
        repo = source / component
        status = subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=all'])
        if status:
            raise ValueError('Commit source changes before preparing an IXE: ' + component)
        if component != '.':
            expected = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD:' + component]).strip()
            actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD']).strip()
            if expected != actual:
                raise ValueError('Component does not match the umbrella pin: ' + component)


def prepare(args):
    if args.method == "nix" and args.runtime_cache:
        raise ValueError("Nix IXE cannot use a Standard runtime cache")
    source = args.source_root.resolve()
    check_source(source)
    if args.ssh_host.startswith('-') or any(c.isspace() for c in args.ssh_host):
        raise ValueError('Use an SSH host alias or user@host')
    state_path = args.state.resolve()
    if state_path.exists():
        raise ValueError('Use a new state file; existing evaluations are never replaced')
    state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if state_path.parent.stat().st_mode & 0o077:
        raise ValueError('The state directory must be private (mode 0700)')
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
           '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3']
    if args.ssh_config:
        ssh += ['-F', str(args.ssh_config.resolve())]
    identity = uuid.uuid4().hex[:12]
    state = dict(version=1, id=identity, token=uuid.uuid4().hex, ssh=ssh, host=args.ssh_host,
                 remote='/private/tmp/dmixe-' + identity, phase='preparing',
                 mode='nix' if args.method == 'nix' else 'cached-runtime' if args.runtime_cache else 'native-build')
    # Persist intent before touching the guest, including interrupted preparation.
    with state_path.open('x') as stream:
        os.chmod(state_path, 0o600)
        json.dump(state, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    if remote(state, ['uname', '-s']).strip() != b'Darwin':
        raise ValueError('The SSH target must run macOS, not a Linux container')
    with tempfile.TemporaryDirectory(prefix='macos-ixe-source-') as temporary:
        temporary = Path(temporary)
        snapshot = temporary / 'source'
        common = module('standard_common', source / 'scripts/container-build.py')
        common.snapshot(source, snapshot)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as bundle:
            bundle.add(snapshot, arcname='source')
            if args.method == 'nix':
                def write_pack(name, data):
                    member = tarfile.TarInfo('nix-transfer/' + name)
                    member.size, member.mode = len(data), 0o600
                    bundle.addfile(member, io.BytesIO(data))
                module('macos_nix', HERE / 'macos-nix.py').export_sources(source, temporary / 'nix-transfer', write_pack)
                bundle.add(temporary / 'nix-transfer/repositories.json', arcname='nix-transfer/repositories.json')
        payload = buffer.getvalue()
        buffer.close()
        state['source_sha256'] = hashlib.sha256(payload).hexdigest()
        state['revisions'] = json.loads((snapshot / 'bootstrap-source-revisions.json').read_text())
        save(state_path, state)
        # Exclusive mkdir establishes ownership. Never reuse an existing remote path.
        remote(state, ['/bin/sh', '-c', 'umask 077; mkdir "$1" && printf "%s" "$2" > "$1/token"',
                       'ixe', state['remote'], state['token']])
        remote(state, ['/bin/sh', '-c', 'umask 077; cat > "$1/source.tar"', 'ixe', state['remote']], data=payload)
        remote(state, ['/bin/sh', '-c', 'umask 077; cat > "$1/guest.py"', 'ixe', state['remote']],
               data=(HERE / 'macos-guest.py').read_bytes())
        options = ['--sha256', state['source_sha256'], '--method', args.method]
        if args.runtime_cache:
            options += ['--runtime-cache', args.runtime_cache]
        # Transfer is complete; release potentially large packs before guest builds.
        shutil.rmtree(temporary)
        details = json.loads(guest(state, 'prepare', *options))
    state.update(phase='ready', guest=details)
    save(state_path, state)
    print('macOS IXE ready (' + state['mode'] + '). No credentials or backend state were copied.')
    print('Connect from this host:')
    print(shlex.join([sys.executable, str(HERE / 'macos.py'), 'connect', '--state', str(state_path)]))
    print('After exit, run collect to verify evidence, then cleanup to remove this guest home.')


def scan_keys(paths):
    values = []
    for path in paths:
        if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
            raise ValueError('Scan keys must be owner-only regular files')
        value = path.read_text().strip()
        if not value or len(value) > 16384 or any(c.isspace() for c in value):
            raise ValueError('Scan key must be a single nonempty token')
        values.append(value)
    return json.dumps(values).encode()


def collect(args, state):
    # Conversation export is optional and requires a decoded credential scan.
    evidence = json.loads(guest(state, 'verify'))
    evidence['conversation_archive'] = None
    save(args.state.resolve().parent / 'verification.json', evidence)
    if args.key_file:
        keys = scan_keys(args.key_file)
        scan = json.loads(guest(state, 'scan', data=keys))
        save(args.state.resolve().parent / 'credential-scan.json', scan)
        if not scan['passed']:
            raise ValueError('Credential scan failed; private guest evidence retained, export refused')
        archive = guest(state, 'evidence', data=keys)
        destination = args.state.resolve().parent / ('private-trajectories-' + uuid.uuid4().hex[:12] + '.tar.gz')
        with destination.open('xb') as stream:
            os.chmod(destination, 0o600)
            stream.write(archive)
        evidence['conversation_archive'] = destination.name
        save(args.state.resolve().parent / 'verification.json', evidence)
    state['phase'] = 'verified' if evidence['passed'] else 'verification-failed'
    save(args.state.resolve(), state)
    print(json.dumps(evidence, indent=2))
    if not evidence['passed']:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    for name in ('prepare', 'connect', 'collect', 'stop', 'scan', 'cleanup'):
        sub = commands.add_parser(name)
        sub.add_argument('--state', type=Path, required=True, help='Private local ownership journal')
        if name == 'prepare':
            sub.add_argument('--method', choices=['standard', 'nix'], default='standard', help='Evaluation path; the actual wizard still offers both choices')
            sub.add_argument('--source-root', type=Path, default=HERE.parents[1])
            sub.add_argument('--ssh-host', required=True, help='Existing OpenSSH host alias')
            sub.add_argument('--ssh-config', type=Path)
            sub.add_argument('--runtime-cache', help='Existing native Standard release path ON THE MAC; skips acquisition')
        if name in ('scan', 'collect'):
            sub.add_argument('--key-file', type=Path, action='append', required=name == 'scan', help='Owner-only approved key file; values are never printed')
        if name == 'cleanup':
            sub.add_argument('--external-resources-cleaned', action='store_true',
                             help='Confirm any run-owned email resources were cleaned using their ownership journal')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args)
        return
    state = read_state(args.state)
    if state['phase'] == 'cleaned':
        print('This IXE has already been cleaned.')
        return
    if args.action == 'connect':
        if state['phase'] != 'ready':
            raise ValueError('Only a freshly prepared IXE can be connected; reconnecting must not replay installation')
        state['phase'] = 'connected'
        save(args.state.resolve(), state)
        remote(state, ['/usr/bin/python3', state['remote'] + '/guest.py', '--root', state['remote'],
                       '--token', state['token'], 'session'], tty=True, capture=False)
        state['phase'] = 'session-ended'
        save(args.state.resolve(), state)
    elif args.action == 'collect':
        collect(args, state)
    elif args.action == 'stop':
        print(guest(state, 'stop').decode())
    elif args.action == 'scan':
        result = json.loads(guest(state, 'scan', data=scan_keys(args.key_file)))
        save(args.state.resolve().parent / 'credential-scan.json', result)
        print(json.dumps(result))
        if not result['passed']:
            raise SystemExit(1)
    else:
        if not args.external_resources_cleaned:
            raise ValueError('Clean only journaled external test resources, then pass --external-resources-cleaned (also valid when none were created)')
        # Use the local reviewed helper even if preparation failed before its
        # upload. The guest still checks the exact private root/token first.
        cleanup_helper = ('NIX_ADAPTER_SOURCE = ' + repr((HERE / 'macos-nix.py').read_text()) + '\n').encode() + (HERE / 'macos-guest.py').read_bytes()
        result = json.loads(remote(state, ['/usr/bin/python3', '-', '--root', state['remote'],
                                          '--token', state['token'], 'cleanup'],
                                   data=cleanup_helper))
        save(args.state.resolve().parent / 'cleanup.json', result)
        state['phase'] = 'cleaned'
        save(args.state.resolve(), state)
        print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Never print arbitrary remote output, which might include private values.
        print('macOS IXE failed: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
