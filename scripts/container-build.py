#!/usr/bin/env python3
"""Build a private Linux runtime with Docker. No Git metadata or home enters Docker."""
import argparse
from contextlib import contextmanager, nullcontext
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

COMPONENTS = ('dearmachine', 'machtiani-harness', 'dearmachine-concierge')
PUBLIC_COMMANDS = ('dearmachine', 'machtiani', 'agent-manager', 'machtiani-installer', 'machtiani-model-host')
EXCLUDED = {'.git', '.secrets', '.ssh', '.codex', '.omp', '.dearmachine', '.machtiani', 'node_modules', 'dist', '__pycache__', 'result'}


def command(*args, capture=False, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else sys.stderr, **kwargs).stdout


def copy_checkout(source, destination):
    """Only tracked working files; source archives have an explicit provenance marker."""
    source, destination = Path(source), Path(destination)
    if (source / '.git').exists():
        paths = command('git', '-C', source, 'ls-files', '-z', capture=True).split('\0')
    else:
        paths = [str(path.relative_to(source)) for path in source.rglob('*') if not path.is_dir()]
    for name in sorted(set(paths)):
        if not name:
            continue
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Source path escapes its checkout')
        if any(part in ('.machtiani', '.dearmachine') for part in relative.parts):
            continue  # Repository-local product metadata is not needed to build.
        if any(part in EXCLUDED or part.startswith('.env') for part in relative.parts):
            raise ValueError('Forbidden source path: ' + name)
        source_path = source / relative
        if source_path.is_dir() and not source_path.is_symlink():
            continue  # Gitlink; components are copied explicitly by the caller.
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if source_path.is_symlink():
            link = os.readlink(source_path)
            resolved = os.path.normpath(str(relative.parent / link))
            if os.path.isabs(link) or resolved == '..' or resolved.startswith('../'):
                raise ValueError('Source symlink escapes its checkout: ' + name)
            target.symlink_to(link)
        elif source_path.is_file():
            shutil.copy2(source_path, target)
        else:
            raise ValueError('Missing or unsupported source file: ' + name)


def fingerprint(root):
    digest = hashlib.sha256()
    for path in sorted(Path(root).rglob('*')):
        if path.is_dir() and not path.is_symlink():
            continue
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(str(stat.S_IMODE(path.lstat().st_mode)).encode() + b'\0')
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        else:
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
    return digest.hexdigest()


def private_directory(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError('Installation paths must be absolute')
    # Check existing ancestors before creating anything; never traverse a symlink.
    for parent in reversed([path, *path.parents][:-1]):
        if parent.is_symlink():
            raise ValueError('Symbolic-link installation directory: ' + str(parent))
        if parent.exists():
            info = parent.stat()
            if not stat.S_ISDIR(info.st_mode) or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
                raise ValueError('Unsafe installation directory: ' + str(parent))
        else:
            parent.mkdir(mode=0o700)
    if path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o022:
        raise ValueError('Installation directory must be owned and writable only by its owner')


def check_launchers(home, release):
    for name in PUBLIC_COMMANDS:
        path = home / '.local/bin' / name
        if os.path.lexists(path) and (not path.is_symlink() or os.readlink(path) != str(release / 'bin' / name)):
            raise ValueError('Existing ' + str(path) + ' was left unchanged. Remove it through its owning installer before switching methods.')


def snapshot(source, destination, installer_root=None):
    copy_checkout(source, destination)
    if not (source / '.git').exists():
        if not (source / 'bootstrap-source-revisions.json').is_file():
            raise ValueError('A source archive requires revision metadata')
        return
    revisions = {}
    for component in ('.', *COMPONENTS):
        checkout = installer_root if component == 'dearmachine-concierge' and installer_root else source / component
        if component != '.':
            copy_checkout(checkout, destination / component)
        if (checkout / '.git').exists():
            revisions[component] = command('git', '-C', checkout, 'rev-parse', 'HEAD', capture=True).strip()
        else:
            revisions.update(json.loads((source / 'bootstrap-source-revisions.json').read_text()))
    (destination / 'bootstrap-source-state.json').write_text(json.dumps({'workingTree': any(
        subprocess.run(['git', '-C', str(installer_root if component == 'dearmachine-concierge' and installer_root else source / component),
                        'diff', '--quiet', 'HEAD', '--ignore-submodules=all']).returncode != 0
        for component in ('.', *COMPONENTS))}) + '\n')
    (destination / 'bootstrap-source-revisions.json').write_text(json.dumps(revisions, sort_keys=True) + '\n')


def preflight():
    machine = platform.machine()
    if platform.system() != 'Linux' or machine not in ('x86_64', 'aarch64'):
        raise ValueError('Container build currently supports Linux x86-64 and ARM64 hosts only')
    try:
        details = json.loads(command('docker', 'info', '--format', '{{json .}}', capture=True, timeout=15))
    except FileNotFoundError as error:
        raise ValueError('Docker is not available. Install Docker for Linux, then rerun this command.\n'
                         'Installation instructions: https://docs.docker.com/engine/install/') from error
    except subprocess.SubprocessError as error:
        raise ValueError('Docker is installed but its engine could not be reached. Start Docker and make sure '
                         '`docker info` succeeds as your normal user, then rerun this command.\n'
                         'Setup instructions: https://docs.docker.com/engine/install/linux-postinstall/') from error
    expected = ('x86_64', 'amd64') if machine == 'x86_64' else ('aarch64', 'arm64')
    if details['OSType'] != 'linux' or details['Architecture'] not in expected:
        raise ValueError('Docker must build Linux ' + machine + ' images for this host')
    try:
        command('docker', 'buildx', 'version', capture=True, timeout=15)
    except (FileNotFoundError, subprocess.SubprocessError) as error:
        raise ValueError('Docker is available, but its Buildx plugin is missing or could not run. '
                         'Install or repair the Buildx plugin supplied by your Docker package provider.\n'
                         'For Ubuntu/Debian using Docker\'s official apt repository: sudo apt install docker-buildx-plugin\n'
                         'Installation instructions: https://docs.docker.com/engine/install/\n'
                         'Once `docker buildx version` succeeds, rerun this command. '
                         'BuildKit is included with modern Docker; no separate BuildKit installation is needed.') from error


DOCKER_HUB_AUTH_KEYS = frozenset((
    'docker.io', 'index.docker.io', 'registry-1.docker.io',
    'https://index.docker.io/v1/', 'https://registry-1.docker.io',
))


@contextmanager
def docker_build_environment():
    """Use anonymous public-image pulls if Docker Hub's configured helper is absent."""
    environment = dict(os.environ, DOCKER_BUILDKIT='1')
    config_root = Path(os.environ.get('DOCKER_CONFIG') or Path.home() / '.docker').expanduser().resolve()
    config_path = config_root / 'config.json'
    if not config_path.is_file():
        yield environment
        return
    config = json.loads(config_path.read_text())
    helpers = config.get('credHelpers', {})
    hub_helpers = [helper for registry, helper in helpers.items()
                   if registry in DOCKER_HUB_AUTH_KEYS] if isinstance(helpers, dict) else []
    candidates = hub_helpers or [config.get('credsStore')]
    missing = [helper for helper in candidates if isinstance(helper, str) and helper and
               shutil.which('docker-credential-' + helper) is None]
    if not missing:
        yield environment
        return

    # The Dockerfile's external images are public. Keep the user's context,
    # Buildx state and proxy settings, but never change their saved config or
    # copy registry credentials into the temporary anonymous-pull config.
    with tempfile.TemporaryDirectory(prefix='dearmachine-docker-config-') as temporary:
        temporary_root = Path(temporary)
        for entry in config_root.iterdir():
            if entry.name != 'config.json':
                (temporary_root / entry.name).symlink_to(entry)
        anonymous = {key: value for key, value in config.items()
                     if key not in ('auths', 'credsStore', 'credHelpers')}
        temporary_config = temporary_root / 'config.json'
        temporary_config.write_text(json.dumps(anonymous) + '\n')
        temporary_config.chmod(0o600)
        print('Docker Hub credential helper ' + ', '.join(sorted(set(missing))) +
              ' is unavailable; using a temporary anonymous-pull Docker config for public images.',
              file=sys.stderr)
        yield dict(environment, DOCKER_CONFIG=str(temporary_root))


def build_runtime(source, output, bootstrap=False):
    preflight()
    target = 'bootstrap' if bootstrap else 'release'
    with tempfile.TemporaryDirectory(prefix='dearmachine-docker-') as temporary:
        iidfile = Path(temporary) / 'image-id'
        with docker_build_environment() as environment:
            command('docker', 'build', '--progress=plain', '--target', target,
                    '--iidfile', iidfile, '-f', source / 'scripts/container/Dockerfile', source,
                    env=environment)
        image_id = iidfile.read_text().strip()
        container = command('docker', 'create', image_id, '/bin/true', capture=True).strip()
        try:
            command('docker', 'cp', container + ':/release/.', output)
        finally:
            command('docker', 'rm', container)
        print('Built image: ' + image_id, file=sys.stderr)


@contextmanager
def acquisition_lock(home, data):
    """Share the native updater/uninstaller lock for every managed build."""
    marker = home / '.dearmachine/uninstalling'
    if os.path.lexists(marker):
        raise ValueError('An uninstall may be active; inspect ' + str(marker))
    root = data / 'dearmachine'
    private_directory(root)
    lock = root / 'update.lock'
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ValueError('Installation is busy; inspect ' + str(lock)) from error
    try:
        if os.path.lexists(marker):
            raise ValueError('An uninstall may be active; inspect ' + str(marker))
        yield
    finally:
        lock.rmdir()


def acquire(source, home, data, bootstrap=False, installer_root=None, output=None, *,
            builder=None, activate=True, namespace=None, target=None):
    if not home.is_absolute() or home == Path('/'):
        raise ValueError('A non-root absolute HOME is required')
    with acquisition_lock(home, data) if output is None else nullcontext():
        return acquire_locked(source, home, data, bootstrap, installer_root, output,
                              builder=builder, activate=activate, namespace=namespace, target=target)


def acquire_locked(source, home, data, bootstrap=False, installer_root=None, output=None, *,
                   builder=None, activate=True, namespace=None, target=None):
    if output is not None and any(os.path.commonpath([str(output.absolute()), str(checkout.resolve())]) == str(checkout.resolve())
                                  for checkout in (source, installer_root or source)):
        raise ValueError('Build output must be outside the source checkout')
    with tempfile.TemporaryDirectory(prefix='dearmachine-source-') as temporary:
        context = Path(temporary) / 'source'
        snapshot(source, context, installer_root)
        identity = fingerprint(context)
        if target:
            identity = hashlib.sha256((target + ':' + identity).encode()).hexdigest()
        release = output or data / 'dearmachine' / (namespace or ('bootstrap' if bootstrap else 'container-releases')) / identity
        if not release.is_absolute() or ':' in str(release) or '\n' in str(release):
            raise ValueError('Release path must be absolute without a colon or newline')
        if output is None and not bootstrap:
            private_directory(home / '.local/bin')
            check_launchers(home, release)
        private_directory(release.parent)
        lock = release.parent / ('.' + release.name + '.lock')
        try:
            lock.mkdir(mode=0o700)
        except FileExistsError as error:
            raise ValueError('Another build may be running; inspect ' + str(lock) + ' before retrying') from error
        try:
            if release.exists() or release.is_symlink():
                if release.is_symlink() or not (release / '.complete').is_file() or (release / '.complete').read_text() != identity:
                    raise ValueError('Incomplete or unrelated release retained at ' + str(release) + '; inspect it before retrying')
                print('Reusing the verified build; no dependency downloads requested.', file=sys.stderr)
            else:
                release.mkdir(mode=0o700)
                try:
                    (builder or build_runtime)(context, release, bootstrap)
                    if activate:
                        command('sh', release / 'bootstrap-runtime.sh')
                    probes = [('machtiani-installer', '--help'), ('git', '--version'), ('git-lfs', 'version')]
                    if not bootstrap:
                        probes += [('dearmachine', '--help'), ('agent-manager', '--help'), ('machtiani', '--version')]
                    for name, argument in probes:
                        command(release / 'bin' / name, argument, capture=True, timeout=30)
                    (release / '.complete').write_text(identity)
                except BaseException:
                    # This attempt created the release and has not exposed public launchers.
                    shutil.rmtree(release)
                    raise
            if output is None and not bootstrap:
                check_launchers(home, release)
                created = []
                try:
                    for name in PUBLIC_COMMANDS:
                        path = home / '.local/bin' / name
                        if not os.path.lexists(path):
                            path.symlink_to(release / 'bin' / name)
                            created.append(path)
                except BaseException:
                    for path in created:
                        path.unlink()
                    raise
                # Configure the user's future shells only after public launchers exist.
                # Bootstrap-only and exported builds must not modify shell settings.
                command(release / 'bin/machtiani-installer', 'configure-shell',
                        env={**os.environ, 'HOME': str(home)})
            return release
        finally:
            lock.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--installer-root', type=Path, help='Development worktree override; sources are copied, never mounted')
    parser.add_argument('--bootstrap', action='store_true', help='Build only the installer runtime and print its launcher')
    parser.add_argument('--output', type=Path, help='Export and verify in this new directory without creating public launchers')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    home = Path(os.environ.get('HOME', ''))
    data = Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
    release = acquire(args.source_root.resolve(), home, data, args.bootstrap,
                      args.installer_root.resolve() if args.installer_root else None, args.output)
    result = {'release': str(release), 'manifest': str(release / 'distribution.json'),
              'launcher': str(release / 'bin/machtiani-installer')}
    print(json.dumps(result) if args.json else result['launcher'] if args.bootstrap else 'Installed Dear Machine at ' + str(release))


if __name__ == '__main__':
    def cancelled(signum, frame):
        raise KeyboardInterrupt('Build cancelled')
    signal.signal(signal.SIGTERM, cancelled)
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(str(error) or 'Build cancelled', file=sys.stderr)
        sys.exit(1)
