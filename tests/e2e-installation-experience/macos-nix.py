#!/usr/bin/env python3
"""Nix-specific preparation and ownership checks for the macOS IXE adapter."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

REMOTE = 'https://macos-ixe.invalid/source.git'
NIX_BIN = '/nix/var/nix/profiles/default/bin'


def git(repo, *args, **kwargs):
    return subprocess.check_output(['git', '-C', str(repo), *args], **kwargs)


def export_sources(source, destination, write_pack=None):
    """Transfer exact current commits/trees, never history, Git config or hooks."""
    destination.mkdir()
    records = []
    def visit(repo, prefix, expected=None):
        revision = git(repo, 'rev-parse', 'HEAD').decode().strip()
        if expected is not None and revision != expected:
            raise ValueError('Nix IXE requires initialized, pinned recursive submodules: ' + prefix)
        if git(repo, 'status', '--porcelain', '--untracked-files=all'):
            raise ValueError('Nix IXE requires clean recursive submodules: ' + prefix)
        children = []
        for entry in git(repo, 'ls-tree', '-rz', revision).split(b'\0'):
            if not entry:
                continue
            metadata, raw_name = entry.split(b'\t', 1)
            mode, kind, oid = metadata.decode().split()
            name = raw_name.decode()
            path = Path(name)
            project_id = (name == '.machtiani/project.uuid' and kind == 'blob' and mode in ('100644', '100755') and
                          re.fullmatch(rb'[0-9a-fA-F-]{36}\s*', git(repo, 'cat-file', 'blob', oid)) is not None)
            if path.is_absolute() or any(p in ('.git', '.ssh', '.secrets', '.dearmachine') or (p == '.machtiani' and not project_id) or
                    (p.startswith('.env') and p != '.env.example') for p in path.parts) or '..' in path.parts:
                raise ValueError('Private or unsafe tracked path in Nix source: ' + name)
            if mode == '120000':
                target = git(repo, 'cat-file', 'blob', oid).decode().strip()
                resolved = os.path.normpath(str(path.parent / target))
                if os.path.isabs(target) or resolved == '..' or resolved.startswith('../'):
                    raise ValueError('Source symlink escapes checkout: ' + name)
            if kind == 'commit':
                children.append((name, oid))
        objects = [revision, *[line.split()[0] for line in git(repo, 'rev-list', '--objects', revision + '^{tree}').decode().splitlines()]]
        name = str(len(records)) + '.pack'
        command = ['git', '-C', str(repo), 'pack-objects', '--stdout']
        packed_input = ('\n'.join(objects) + '\n').encode()
        if write_pack is None:
            with (destination / name).open('wb') as stream:
                subprocess.run(command, input=packed_input, stdout=stream, check=True)
        else:
            write_pack(name, subprocess.check_output(command, input=packed_input))
        records.append(dict(path=prefix, revision=revision, pack=name))
        for child, oid in children:
            visit(repo / child, child if prefix == '.' else prefix + '/' + child, oid)
    visit(source, '.')
    (destination / 'repositories.json').write_text(json.dumps(records))
    return records


def environment(root):
    home = root / 'home'
    return dict(PATH=':'.join(map(str, [home / '.local/bin', home / '.nix-profile/bin',
                     root / 'toolchain/bin', Path(NIX_BIN)])) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                NIX_CONFIG='extra-experimental-features = nix-command flakes\n',
                GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(home / '.gitconfig'),
                GIT_TERMINAL_PROMPT='0')


def source_digest(source):
    """Compare archive content, ignoring Git administration and generated provenance."""
    digest = hashlib.sha256()
    for base, directories, files in os.walk(source, followlinks=False):
        directories[:] = sorted(d for d in directories if d != '.git')
        for name in sorted(files + [d for d in directories if (Path(base) / d).is_symlink()]):
            path = Path(base) / name
            relative = path.relative_to(source)
            if any(p.startswith('.env') for p in relative.parts) or str(relative) in (
                    'bootstrap-source-revisions.json', 'bootstrap-source-state.json'):
                continue  # ManagedNix intentionally omits .env templates from its archive.
            digest.update(str(relative).encode() + b'\0')
            digest.update(str(path.lstat().st_mode & 0o111).encode() + b'\0')
            digest.update(os.readlink(path).encode() if path.is_symlink() else path.read_bytes())
    return digest.hexdigest()


def prepare(root, env):
    nix = Path(NIX_BIN) / 'nix'
    if not nix.is_file():
        raise ValueError('Install Nix on the Mac before preparing a Nix IXE; first-time OS provisioning is separate')
    subprocess.run([str(nix), 'store', 'ping'], env=env, check=True, stdout=subprocess.DEVNULL)
    checkout = root / 'checkout'
    records = json.loads((root / 'nix-transfer/repositories.json').read_text())
    for record in records:
        target = checkout / record['path']
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'init', '-q', str(target)], env=env, check=True)
        with (root / 'nix-transfer' / record['pack']).open('rb') as stream:
            subprocess.run(['git', '-C', str(target), 'index-pack', '--stdin'], stdin=stream,
                           env=env, stdout=subprocess.DEVNULL, check=True)
        (target / '.git/shallow').write_text(record['revision'] + '\n')
        subprocess.run(['git', '-C', str(target), 'update-ref', 'refs/heads/main', record['revision']], env=env, check=True)
        subprocess.run(['git', '-C', str(target), 'symbolic-ref', 'HEAD', 'refs/heads/main'], env=env, check=True)
        subprocess.run(['git', '-C', str(target), 'reset', '--hard', '-q', record['revision']], env=env, check=True)
    shutil.rmtree(root / 'nix-transfer')
    subprocess.run(['git', '-C', str(checkout), 'remote', 'add', 'origin', REMOTE], env=env, check=True)
    # An isolated source origin makes unpublished revisions reviewable, without
    # copying developer credentials or changing the shared account's Git config.
    config = root / 'home/.gitconfig'
    subprocess.run(['git', 'config', '--file', str(config), 'url.' + checkout.as_uri() + '.insteadOf', REMOTE], env=env, check=True)
    config.chmod(0o600)
    print('Preparing the Nix installer and pinned command-line tools; no product configuration is seeded.', file=__import__('sys').stderr)
    source = root / 'source/dearmachine-concierge'
    subprocess.run([str(nix), 'build', '--out-link', str(root / 'bootstrap'), 'path:' + str(source)], env=env, check=True)
    expression = ('let f = builtins.getFlake ' + json.dumps('path:' + str(source)) + '; '
                  'p = import (if builtins.currentSystem == "x86_64-darwin" then f.inputs.nixpkgs-intel-darwin else f.inputs.nixpkgs) {}; '
                  'in p.buildEnv { name = "macos-ixe-tools"; paths = [ p.git p.git-lfs p.nodejs_24 ]; }')
    subprocess.run([str(nix), 'build', '--impure', '--expr', expression,
                    '--out-link', str(root / 'toolchain')], env=env, check=True)
    return dict(checkout=str(checkout), checkout_before=source_digest(checkout),
                revisions={r['path']: r['revision'] for r in records},
                bootstrap=str(root / 'bootstrap'), nix_preinstalled=True,
                source_origin='isolated local Git mirror; published updates are excluded')


def receipt(root, info):
    managed = root / 'home/.local/share/dearmachine'
    current = managed / 'current'
    if not current.exists() and not current.is_symlink():
        return None
    revision = info['revisions']['.']
    release = managed / 'releases' / revision
    if not current.is_symlink() or current.resolve() != release or not release.resolve().is_relative_to(root):
        raise ValueError('Nix active release escapes or differs from this evaluation')
    path = release / 'release.json'
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o077:
        raise ValueError('Nix receipt must be private and owned')
    value = json.loads(path.read_text())
    source = managed / 'sources' / revision
    if (value.get('method') != 'nix' or value.get('revision') != revision or
            value.get('revisions') != info['revisions'] or value.get('sourceRoot') != str(source) or
            value.get('remote') != REMOTE or not source.resolve().is_relative_to(root)):
        raise ValueError('Nix receipt does not match the evaluated source')
    for name in ('dearmachine', 'agent-manager', 'machtiani', 'machtiani-installer', 'machtiani-model-host'):
        binary = value.get('binaries', {}).get(name, '')
        if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^\s/]+/bin/' + name, binary) or not Path(binary).is_file():
            raise ValueError('Invalid Nix product store path')
        component = 'dearmachine' if name in ('dearmachine', 'agent-manager') else 'machtiani-harness' if name == 'machtiani' else 'dearmachine-concierge'
        if (release / 'roots' / component).resolve() != Path(binary).parent.parent:
            raise ValueError('Nix product root differs from its receipt')
        launcher = root / 'home/.local/bin' / name
        if not launcher.is_symlink() or launcher.resolve() != release / 'bin' / name:
            raise ValueError('Nix launcher differs from its owned release')
    return value


def verify_sources(root, info):
    installed = receipt(root, info)
    return bool(installed and source_digest(Path(info['checkout'])) == info['checkout_before'] and
                source_digest(Path(installed['sourceRoot'])) == info['checkout_before'])


def shutdown(root, env, info):
    # The product protocol addresses this HOME's private socket and checks its
    # supervisor lock. Never kill by a shared /nix/store executable or bare PID.
    if receipt(root, info) is not None:
        subprocess.run([str(root / 'home/.local/bin/dearmachine'), '_update-control', 'stop'],
                       env=env, cwd=root / 'home', capture_output=True, check=True, timeout=30)
    lock = root / 'home/.dearmachine/run/supervisor.lock'
    if lock.exists():
        import fcntl
        with lock.open('r') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('Nix supervisor still owns the test home')
    pidfile = root / 'home/.dearmachine/run/dearmachine.pid'
    if pidfile.exists():
        try:
            pid = int(pidfile.read_text().strip())
            if pid <= 0:
                raise ValueError('Invalid client PID; home retained')
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise ValueError('Client PID remains live; home retained')


def assert_no_open_processes(root):
    # Nix executables live outside the private directory. Detect remaining
    # users by open files/cwd under this home, never by shared executable name.
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '+D', str(root)], capture_output=True, text=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise ValueError('Cannot confirm Nix test processes are gone; home retained')
    pids = {int(line) for line in result.stdout.splitlines() if line.strip()}
    if pids - {os.getpid()}:
        raise ValueError('Another Nix test process still has the private directory open; home retained')
