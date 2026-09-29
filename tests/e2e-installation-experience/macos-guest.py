#!/usr/bin/env python3
"""Guest half of macos.py. Owns only one journaled temporary macOS home."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import time

sys.dont_write_bytecode = True


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def save(path, value):
    temporary = path.with_suffix('.writing')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2)
        stream.write('\n')
    temporary.replace(path)


def owned(root, token):
    if not re.fullmatch(r'/private/tmp/dmixe-[0-9a-f]{12}', str(root)):
        raise ValueError('Invalid guest root')
    if root.is_symlink() or root.resolve() != root or not root.is_dir():
        raise ValueError('Guest root was replaced')
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Guest directory ownership changed')
    marker = root / 'token'
    if marker.is_symlink() or marker.read_text() != token:
        raise ValueError('Guest ownership token changed')


def nix_adapter(root):
    if 'NIX_ADAPTER_SOURCE' in globals():
        import types
        value = types.ModuleType('macos_nix_cleanup')
        exec(NIX_ADAPTER_SOURCE, value.__dict__)
        return value
    return module('macos_nix', root / 'source/tests/e2e-installation-experience/macos-nix.py')


def run_info(root):
    return json.loads((root / 'run.json').read_text()) if (root / 'run.json').exists() else {}


def environment(root):
    # No host API keys, Nix profiles, shell startup files or agent sessions.
    home = root / 'home'
    env = dict(HOME=str(home), PATH=str(home / '.local/bin') + ':/usr/bin:/bin:/usr/sbin:/sbin',
                XDG_CONFIG_HOME=str(home / '.config'), XDG_DATA_HOME=str(home / '.local/share'),
                XDG_STATE_HOME=str(root / 'state'), XDG_CACHE_HOME=str(root / 'cache'),
                TMPDIR=str(root / 'tmp'), TERM='xterm-256color', LANG='en_US.UTF-8',
                SHELL='/bin/zsh', PYTHONDONTWRITEBYTECODE='1')
    if run_info(root).get('mode') == 'nix':
        env.update(nix_adapter(root).environment(root))
    return env


@contextmanager
def lock(root):
    with (root / 'session.lock').open('a') as stream:
        os.chmod(stream.name, 0o600)
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('The IXE terminal is still active; exit it before collecting or cleaning')
        yield


def runtime_inputs(source):
    """Conservative equality gate: only documentation and test changes may reuse a runtime."""
    values = {}
    for parent in ('dearmachine', 'machtiani-harness', 'dearmachine-concierge', 'scripts'):
        base = source / parent
        if not base.is_dir():
            raise ValueError('Runtime source provenance is incomplete')
        for path in base.rglob('*'):
            relative = path.relative_to(source)
            top_level_doc = len(relative.parts) == 2 and path.suffix == '.md'
            if any(part in ('tests', 'test', '__pycache__') for part in relative.parts) or relative.parts[1] == 'docs' or top_level_doc:
                continue
            if path.is_symlink():
                values[str(relative)] = ['link', os.readlink(path)]
            elif path.is_file():
                # Git tracks executable status, not checkout umask (0644 vs 0664).
                values[str(relative)] = [path.stat().st_mode & 0o111, hashlib.sha256(path.read_bytes()).hexdigest()]
    return values


def reuse_runtime(root, cache):
    cache = cache.resolve()
    source = root / 'source'
    manifest = json.loads((cache / 'distribution.json').read_text())
    expected = 'darwin-' + ('arm64' if platform.machine() == 'arm64' else 'x64')
    if manifest.get('platform') != expected or manifest.get('acquisition') != 'native' or manifest.get('method') != 'standard':
        raise ValueError('The cached runtime must be a native Standard release for this Mac architecture')
    if runtime_inputs(source) != runtime_inputs(cache / 'source'):
        raise ValueError('Cached runtime source/build inputs differ; build a matching native release first')
    release = root / 'release'
    release.mkdir()
    # APFS clones keep the old release immutable without copying gigabytes. No
    # hard links: a product write must never mutate the shared cached runtime.
    subprocess.run(['/bin/cp', '-cR', str(cache / 'runtime'), str(release / 'runtime')], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.copytree(source, release / 'source', symlinks=True)
    (release / 'bin').mkdir()
    native = module('native_build', source / 'scripts/macos-build.py')
    for tool in (release / 'runtime/tools/bin').iterdir():
        if tool.is_file() and os.access(tool, os.X_OK):
            native.write_launcher(release, tool.name, [tool], False)
    entries = {'machtiani-installer': 'app', 'machtiani-model-host': 'model-host', 'machtiani-installer-backend': 'backend-adapter'}
    for name, package in entries.items():
        native.write_launcher(release, name, [release / 'runtime/node/bin/node', release / 'runtime/installer/packages' / package / 'dist/bin.mjs'], False)
    for name in ('dearmachine', 'machtiani', 'agent-manager'):
        native.write_launcher(release, name, [release / 'runtime/native' / name], False)
    native.write_launcher(release, 'node', [release / 'runtime/node/bin/node'], False)
    for name in ('python3', 'git'):
        native.write_launcher(release, name, ['/usr/bin/' + name], False)
    save(release / 'distribution.json', manifest)
    native.validate_libraries(release)
    # Do not invent .complete: this is a repack, not acquisition-cache evidence.
    return release


def prepare(root, args):
    if (root / 'run.json').exists():
        raise ValueError('Guest preparation cannot overwrite an existing run')
    payload = root / 'source.tar'
    if hashlib.sha256(payload.read_bytes()).hexdigest() != args.sha256:
        raise ValueError('Transferred source checksum mismatch')
    # The host created this archive from its validated source-only snapshot.
    subprocess.run(['/usr/bin/tar', '-xpf', str(payload), '-C', str(root)], check=True)
    payload.unlink()
    for name in ('home', 'state', 'cache', 'tmp'):
        (root / name).mkdir(mode=0o700)
    common = module('standard_common', root / 'source/scripts/container-build.py')
    info = dict(version=1, phase='ready', platform=platform.machine(),
                mode='nix' if args.method == 'nix' else 'cached-runtime' if args.runtime_cache else 'native-build',
                source_before=common.fingerprint(root / 'source'))
    if args.method == 'nix':
        save(root / 'run.json', dict(info, phase='preparing'))
        info.update(nix_adapter(root).prepare(root, environment(root)))
    if args.runtime_cache:
        info['release'] = str(reuse_runtime(root, Path(args.runtime_cache)))
        info['runtime_source_before'] = common.fingerprint(Path(info['release']) / 'source')
    save(root / 'run.json', info)
    return info


def status(root):
    executable = root / 'home/.local/bin/dearmachine'
    if not executable.is_file():
        return {'installed': False, 'running': False, 'stopped': False}
    # Only the test's own launchers may be executed during collection/cleanup.
    if not executable.resolve().is_relative_to(root):
        raise ValueError('Installed launcher escapes the test root')
    if run_info(root).get('mode') == 'nix':
        if nix_adapter(root).receipt(root, run_info(root)) is None:
            raise ValueError('Expected a Nix installation in this evaluation')
    result = subprocess.run([str(executable), 'status'], env=environment(root), cwd=root / 'home',
                            capture_output=True, text=True, timeout=30)
    return {'installed': result.returncode == 0,
            'running': 'Dear Machine: running' in result.stdout,
            'stopped': 'Dear Machine: stopped' in result.stdout}


def session(root):
    with lock(root):
        info = json.loads((root / 'run.json').read_text())
        if info['phase'] != 'ready':
            raise ValueError('This session has already run; prepare a fresh evaluation')
        info['phase'] = 'running'
        save(root / 'run.json', info)
        env = environment(root)
        try:
            if info['mode'] == 'nix':
                print('Nix IXE: Nix and the bootstrap are prepared. Choose Nix in the Mac installer.', flush=True)
                launcher = root / 'bootstrap/bin/machtiani-installer'
            elif info['mode'] == 'native-build':
                print('Building the native Standard bootstrap in the private test home.', flush=True)
                build = subprocess.run(['/bin/sh', str(root / 'source/scripts/build-standard.sh'), '--bootstrap'],
                                       env=env, cwd=root / 'home', stdout=subprocess.PIPE, text=True, check=True)
                launcher = Path(build.stdout.strip())
                if not launcher.is_file() or not launcher.resolve().is_relative_to(root):
                    raise ValueError('Bootstrap returned a launcher outside this test')
            else:
                print('Cached-runtime IXE: native acquisition is excluded from this run.', flush=True)
                launcher = Path(info['release']) / 'bin/machtiani-installer'
            source = (Path(info['checkout']) if info['mode'] == 'nix' else
                      Path(info['release']) / 'source' if info['mode'] == 'cached-runtime' else root / 'source')
            result = subprocess.run([str(launcher), '--install', '--source-root', str(source)],
                                    env=env, cwd=root / 'home')
            info['installer_exit'] = result.returncode
            info['after_installer'] = status(root)
            save(root / 'run.json', info)
            if result.returncode or not info['after_installer']['installed']:
                print('Installation did not establish a configured client. Evidence remains private on this guest.', flush=True)
                return
            print('\nIXE exploration shell. Run dearmachine to reopen the concierge.\n'
                  'Exercise /status, /down, /up and /quit. Type exit here when finished.\n'
                  'Do not remove email resources until Dear Machine is stopped.', flush=True)
            subprocess.run(['/bin/zsh', '-f'], env=env, cwd=root / 'home')
        finally:
            info['phase'] = 'session-ended'
            save(root / 'run.json', info)
            print('IXE session ended. Run collect, stop the client, clean journaled email resources, then cleanup.', flush=True)


def verify(root):
    with lock(root):
        info = json.loads((root / 'run.json').read_text())
        common = module('standard_common', root / 'source/scripts/container-build.py')
        same = common.fingerprint(root / 'source') == info['source_before']
        if info.get('release'):
            same = same and common.fingerprint(Path(info['release']) / 'source') == info['runtime_source_before']
        pending, processed = 0, 0
        databases = list((root / 'home/.dearmachine/pairs').glob('*/state/dearmachine.db'))
        for db in databases:
            with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as connection:
                pending += connection.execute('SELECT count(*) FROM pending_messages').fetchone()[0]
                processed += connection.execute("SELECT count(*) FROM processed_messages WHERE outbound_message_id <> ''").fetchone()[0]
        launcher = root / 'home/.local/bin/dearmachine'
        if info['mode'] == 'nix':
            same = same and nix_adapter(root).verify_sources(root, info)
        elif launcher.is_file() and launcher.resolve().is_relative_to(root) and not info.get('release'):
            installed_source = launcher.resolve().parent.parent / 'source'
            same = same and installed_source.is_dir() and common.fingerprint(installed_source) == info['source_before']
        native = status(root)
        passed = (info['phase'] == 'session-ended' and info.get('installer_exit') == 0 and
                  info.get('after_installer', {}).get('running') and same and bool(databases) and not pending and processed > 0)
        return dict(passed=bool(passed), scope='basic native installation and outbound acceptance; human UX and delivered reply require separate review',
                    mode=info['mode'], platform=info['platform'], phase=info['phase'], source_unchanged=same,
                    installed=native['installed'], client_running=native['running'], pending=pending, processed_with_reply=processed,
                    private_evidence=str(root), credentials_exported=False)


def stop(root):
    with lock(root):
        if status(root)['installed']:
            subprocess.run([str(root / 'home/.local/bin/dearmachine'), 'down'], env=environment(root),
                           cwd=root / 'home', capture_output=True, check=True, timeout=30)
        result = status(root)
        if result['running']:
            raise ValueError('Client is still running')
        return result


def complete_zstd_frames(data):
    """Check RFC 8878 framing before Node decoding (which accepts truncation).

    This checks lengths and block boundaries, not compressed block contents;
    the native decoder remains responsible for decompression and checksums.
    https://www.rfc-editor.org/rfc/rfc8878.html#section-3
    """
    offset = 0
    def require(count):
        if count > len(data) - offset:
            raise ValueError('Truncated compressed evidence')
    while offset < len(data):
        require(4)
        magic = int.from_bytes(data[offset:offset + 4], 'little')
        offset += 4
        if 0x184d2a50 <= magic <= 0x184d2a5f:
            require(4)
            size = int.from_bytes(data[offset:offset + 4], 'little')
            offset += 4
            require(size)
            offset += size
            continue
        if magic != 0xfd2fb528:
            raise ValueError('Invalid compressed evidence frame')
        require(1)
        descriptor = data[offset]
        offset += 1
        if descriptor & 8:
            raise ValueError('Reserved compressed evidence header')
        single = bool(descriptor & 32)
        content_flag = descriptor >> 6
        content_bytes = (1 if single else 0) if content_flag == 0 else (2, 4, 8)[content_flag - 1]
        header_bytes = (0 if single else 1) + (0, 1, 2, 4)[descriptor & 3] + content_bytes
        require(header_bytes)
        offset += header_bytes
        while True:
            require(3)
            block = int.from_bytes(data[offset:offset + 3], 'little')
            offset += 3
            block_type = (block >> 1) & 3
            if block_type == 3:
                raise ValueError('Reserved compressed evidence block')
            size = 1 if block_type == 1 else block >> 3
            require(size)
            offset += size
            if block & 1:
                break
        if descriptor & 4:
            require(4)
            offset += 4


def decode_zstd(node, data):
    # Node returns the first frame. DSH appends frames, so consume every frame
    # and concatenate before scanning (a key can cross a frame boundary).
    complete_zstd_frames(data)
    script = """
const z = require('node:zlib'), f = require('node:fs');
let input = f.readFileSync(0); const chunks = [];
while (input.length) {
  const result = z.zstdDecompressSync(input, {info: true});
  const consumed = result.engine.bytesWritten;
  if (!Number.isInteger(consumed) || consumed <= 0 || consumed > input.length)
    throw new Error('Invalid compressed evidence frame');
  chunks.push(result.buffer); input = input.subarray(consumed);
}
process.stdout.write(Buffer.concat(chunks));
"""
    return subprocess.run([str(node), '-e', script], input=data, capture_output=True, check=True).stdout


def scan(root, keys, export=False):
    if not keys or not all(isinstance(key, str) and key for key in keys):
        raise ValueError('Credential scan requires approved key values on stdin')
    info = json.loads((root / 'run.json').read_text())
    if info.get('mode') == 'nix':
        node = root / 'toolchain/bin/node'
    elif info.get('release'):
        node = Path(info['release']) / 'bin/node'
    else:
        launcher = root / 'home/.local/bin/dearmachine'
        if not launcher.is_file() or not launcher.resolve().is_relative_to(root):
            raise ValueError('No owned runtime available to decode evidence')
        node = launcher.resolve().parent / 'node'
    count = hits = 0
    archive_buffer = io.BytesIO()
    archive = tarfile.open(fileobj=archive_buffer, mode="w:gz") if export else None
    needles = [key.encode() for key in keys]
    for base in (root / 'state', root / 'home'):
        for path in base.rglob('*'):
            if path.is_symlink() or not path.is_file():
                continue
            if not (path.name.endswith(('.log', '.jsonl', '.jsonl.zstd')) or
                    ('sessions' in path.parts and path.suffix == '.json')):
                continue
            data = path.read_bytes()
            if path.name.endswith('.zstd'):
                data = decode_zstd(node, data)
            count += 1
            hits += sum(data.count(key) for key in needles)
            if archive is not None:
                name = str(path.relative_to(root)) + ('.decoded' if path.name.endswith('.zstd') else '')
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o600
                archive.addfile(member, io.BytesIO(data))
    if archive is not None:
        archive.close()
        if hits or count == 0:
            raise ValueError('Evidence export refused: scan failed or no trajectories were available')
        return archive_buffer.getvalue()
    return dict(passed=hits == 0 and count > 0, files_scanned=count, known_key_occurrences=hits,
                compressed_trajectories_decoded=True, private_credential_stores_excluded=True)


def cleanup_launchd(root):
    """Retire only this private home's native service before deleting its state."""
    consent = root / 'home/.dearmachine/supervision.json'
    definitions = root / 'home/.dearmachine/launchd'
    use_launchd = bool(json.loads(consent.read_text()).get('useLaunchd')) if consent.exists() else False
    configured = use_launchd or any(definitions.glob('*.plist'))
    if not configured:
        return
    launcher = root / 'home/.local/bin/dearmachine'
    if not launcher.is_file():
        raise ValueError('Native launchd cleanup is unavailable; private home retained')
    # The CLI validates exact label, plist and supervisor ownership. Do not
    # guess launchctl targets, kill launchd-owned PIDs, or delete plists here.
    commands = [('persistence', 'off')] if use_launchd else []
    for command in [*commands, ('launchd', 'off')]:
        subprocess.run([str(launcher), *command], env=environment(root), cwd=root / 'home',
                       capture_output=True, check=True, timeout=35)


def cleanup(root):
    with lock(root):
        current = status(root) if (root / 'home').exists() else {'installed': False}
        if current['installed']:
            subprocess.run([str(root / 'home/.local/bin/dearmachine'), 'down'], env=environment(root),
                           cwd=root / 'home', capture_output=True, check=True, timeout=30)
            if status(root)['running']:
                raise ValueError('Client is still running; refusing to remove its home')
        cleanup_launchd(root)
        info = run_info(root)
        if info.get('mode') == 'nix':
            nix_adapter(root).shutdown(root, environment(root), info)
            nix_adapter(root).assert_no_open_processes(root)
        # Native down leaves an idle supervisor. Terminate only a native product
        # executable inside this exact owned root, never a shared VM process.
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
        for line in output.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2:
                continue
            pid, command = int(parts[0]), parts[1]
            path = Path(command)
            if pid != os.getpid() and path.is_relative_to(root) and path.name == 'dearmachine':
                identity = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
                if identity.stdout.strip() != command:
                    raise ValueError('Owned process identity changed; home retained')
                os.kill(pid, signal.SIGTERM)
                for _ in range(50):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.1)
                else:
                    raise ValueError('Owned product did not stop; home retained')
        remaining = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
        for line in remaining.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and int(parts[0]) != os.getpid() and Path(parts[1]).is_relative_to(root):
                raise ValueError('Another test process is still active; home retained')
        shutil.rmtree(root)
        return dict(cleaned=True, guest_home_removed=True, shared_vm_untouched=True,
                    external_resources='operator confirmed cleanup separately')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--token', required=True)
    parser.add_argument('action', choices=['prepare', 'session', 'verify', 'stop', 'scan', 'evidence', 'cleanup'])
    parser.add_argument('--sha256')
    parser.add_argument('--runtime-cache')
    parser.add_argument('--method', choices=['standard', 'nix'], default='standard')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        raise ValueError('This helper runs only inside macOS')
    if args.action == 'cleanup' and not args.root.exists() and not args.root.is_symlink():
        if not re.fullmatch(r'/private/tmp/dmixe-[0-9a-f]{12}', str(args.root)):
            raise ValueError('Invalid guest root')
        print(json.dumps(dict(cleaned=True, already_absent=True)))
        return
    owned(args.root, args.token)
    if args.action == 'session':
        session(args.root)
    else:
        if args.action == 'prepare':
            value = prepare(args.root, args)
        elif args.action == 'verify':
            value = verify(args.root)
        elif args.action == 'stop':
            value = stop(args.root)
        elif args.action in ('scan', 'evidence'):
            with lock(args.root):
                value = scan(args.root, json.load(sys.stdin), export=args.action == 'evidence')
            if args.action == 'evidence':
                sys.stdout.buffer.write(value)
                return
        else:
            value = cleanup(args.root)
        print(json.dumps(value))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError, sqlite3.Error) as error:
        print('macOS IXE guest failed: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
