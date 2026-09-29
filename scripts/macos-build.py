#!/usr/bin/env python3
"""Build a private native macOS Standard runtime with Apple's developer tools."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile
import stat
import sys


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, stdout=kwargs.pop('stdout', sys.stderr),
                          **kwargs)


def preflight():
    if platform.system() != 'Darwin' or platform.machine() not in ('x86_64', 'arm64'):
        raise ValueError('The native Standard builder requires macOS Intel or Apple Silicon.')
    # xcode-select -p does not open an installation dialog, unlike xcrun/git.
    selected = subprocess.run(['/usr/bin/xcode-select', '-p'], capture_output=True, text=True)
    if selected.returncode:
        raise ValueError('Apple Command Line Tools are required. Run `xcode-select --install`, complete the installation, then retry Standard.')
    run('/usr/bin/xcrun', '--find', 'clang', stderr=subprocess.PIPE)
    run('/usr/bin/git', '--version')


def download(cache, entry):
    url, expected = entry['url'], entry['sha256']
    if not url.startswith('https://') or len(expected) != 64:
        raise ValueError('Invalid pinned dependency')
    target = cache / expected
    if target.is_file():
        if hashlib.sha256(target.read_bytes()).hexdigest() == expected:
            return target
        target.unlink()
    temporary = cache / (expected + '.download')
    try:
        with urllib.request.urlopen(url, timeout=90) as source, temporary.open('wb') as output:
            shutil.copyfileobj(source, output)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise ValueError('Dependency checksum mismatch: ' + url)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def extract(archive, destination):
    destination.mkdir(parents=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for entry in source.infolist():
                name = Path(entry.filename)
                mode = entry.external_attr >> 16
                if name.is_absolute() or '..' in name.parts or stat.S_ISLNK(mode):
                    raise ValueError('Unsafe dependency ZIP member')
                path = destination / name
                if entry.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(source.read(entry))
                    path.chmod(0o755 if mode & 0o111 else 0o644)
        children = list(destination.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            raise ValueError('Expected one dependency archive root')
        return children[0]
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError('Unsafe dependency archive member')
            if member.issym() or member.islnk():
                link = name.parent / member.linkname if member.issym() else Path(member.linkname)
                if Path(member.linkname).is_absolute() or not (destination / link).resolve().is_relative_to(destination.resolve()):
                    raise ValueError('Dependency archive link escapes extraction root')
        source.extractall(destination)
    children = list(destination.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        raise ValueError('Expected one dependency archive root')
    return children[0]


# Launchers find the release root from their own location, following the
# ~/.local/bin symlinks, so a release works wherever it is unpacked.
LAUNCHER_ROOT = '''self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case $link in /*) self=$link ;; *) self=$(/usr/bin/dirname -- "$self")/$link ;; esac
done
root=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$self")/.." && pwd)
'''


def launcher_word(root, value):
    """Quote a launcher argument; paths inside the release are root-relative."""
    path = Path(value)
    if path.is_absolute() and path.is_relative_to(root):
        relative = path.relative_to(root).as_posix()
        if any(character in relative for character in '"$`\\\n'):
            raise ValueError('Unsupported character in release path: ' + relative)
        return '"$root/' + relative + '"'
    return shlex.quote(str(value))


def write_launcher(root, name, command, bootstrap):
    environment = dict(DEARMACHINE_SOURCE_ROOT=root / 'source',
                       DEARMACHINE_CONCIERGE_BIN=root / 'bin/machtiani-installer',
                       MACHTIANI_CLAUDE_EXECUTABLE=root / 'runtime/vendor/claude')
    if not bootstrap:
        environment.update(MACHTIANI_DISTRIBUTION=root / 'distribution.json',
                           DEARMACHINE_NATIVE_BIN=root / 'runtime/native/dearmachine')
    paths = [root / 'bin', root / 'runtime/tools/bin', root / 'runtime/node/bin']
    script = '#!/bin/sh\nset -eu\n' + LAUNCHER_ROOT
    for key, value in environment.items():
        script += 'export ' + key + '=' + launcher_word(root, value) + '\n'
    script += 'export PATH=' + ':'.join(launcher_word(root, path) for path in paths) + ':"${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"\n'
    script += 'exec ' + ' '.join(launcher_word(root, x) for x in command) + ' "$@"\n'
    path = root / 'bin' / name
    path.write_text(script)
    path.chmod(0o755)


def validate_libraries(root):
    # Official Node/Go binaries and our compiled tools must not depend on
    # Homebrew, Nix or build-directory libraries left outside the release.
    magics = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
    for path in (root / 'runtime').rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in magics:
                continue
        identities = subprocess.check_output(['/usr/bin/otool', '-D', str(path)], text=True)
        # otool -L includes a dylib's LC_ID_DYLIB alongside its dependencies.
        # That identifier can retain the vendor's build path; it is not a load.
        own_ids = {line.strip() for line in identities.splitlines() if line.strip().startswith(('/', '@')) and not line.rstrip().endswith(':')}
        output = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
        for line in output.splitlines()[1:]:
            library = line.strip().split(' (', 1)[0]
            if library in own_ids:
                continue
            if library.startswith('/') and not library.startswith(('/usr/lib/', '/System/Library/', str(root) + '/')):
                raise ValueError('Runtime file ' + str(path.relative_to(root)) + ' depends on an external library: ' + library)


def build_environment(paths):
    # Only basic process settings and explicit network proxy settings cross
    # into dependency builds. Provider keys and host compiler flags do not.
    allowed = ('HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
               'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
    environment = {name: os.environ[name] for name in allowed if name in os.environ}
    environment.update(PATH=':'.join(map(str, paths)) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                       GOTOOLCHAIN='local', CGO_ENABLED='1', CC='/usr/bin/clang', CXX='/usr/bin/clang++',
                       CI='true', PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN='false')
    return environment


def build_runtime(source, root, bootstrap=False):
    preflight()
    # The caller's snapshot includes only tracked sources, never their HOME.
    pins = json.loads((source / 'scripts/macos-dependencies.json').read_text())
    arch = 'arm64' if platform.machine() == 'arm64' else 'x64'
    goarch = 'arm64' if arch == 'arm64' else 'amd64'
    rgarch = 'aarch64' if arch == 'arm64' else 'x86_64'
    cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) / 'dearmachine/standard-downloads'
    # Reuse the acquisition path's ownership/symlink checks, including ancestors.
    import importlib.util
    spec = importlib.util.spec_from_file_location('standard_common', source / 'scripts/container-build.py')
    common = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(common)
    spec = importlib.util.spec_from_file_location('machtiani_version', source / 'scripts/machtiani-version-ldflags.py')
    version = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(version)
    stamp = None if bootstrap else version.ldflags(source)
    common.private_directory(cache)
    lock = cache / '.lock'
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ValueError('Another Standard dependency download may be running; inspect ' + str(lock)) from error
    try:
        archives = {name: download(cache, pins[name]) for name in (
            'node-' + arch, 'go-' + goarch, 'git-lfs-' + goarch, 'rg-' + rgarch, 'pnpm', 'bash', 'coreutils', 'sed')}
    finally:
        lock.rmdir()
    (root / 'runtime').mkdir()
    (root / 'bin').mkdir()
    shutil.copytree(source, root / 'source', symlinks=True)
    with tempfile.TemporaryDirectory(prefix='dearmachine-native-') as temporary:
        work = Path(temporary)
        unpacked = {name: extract(archive, work / name) for name, archive in archives.items()}
        shutil.copytree(unpacked['node-' + arch], root / 'runtime/node', symlinks=True)
        tools = root / 'runtime/tools'
        (tools / 'bin').mkdir(parents=True)
        build_bin = work / 'bin'
        build_bin.mkdir()
        pnpm_launcher = build_bin / 'pnpm'
        pnpm_launcher.write_text('#!/bin/sh\nexec ' + shlex.quote(str(root / 'runtime/node/bin/node')) + ' ' +
                                 shlex.quote(str(unpacked['pnpm'] / 'bin/pnpm.mjs')) + ' \"$@\"\n')
        pnpm_launcher.chmod(0o755)
        env = build_environment([build_bin, tools / 'bin', root / 'runtime/node/bin', unpacked['go-' + goarch] / 'bin'])
        jobs = str(min(os.cpu_count() or 2, 4))
        for name in ('bash', 'coreutils', 'sed'):
            print('Building Standard runtime dependency: ' + name, file=sys.stderr)
            arguments = ['./configure', '--prefix=' + str(tools), '--disable-nls']
            if name == 'coreutils':
                # Never link a host OpenSSL (such as Homebrew's) into the release.
                arguments += ['--without-libgmp', '--without-openssl']
            run(*arguments, cwd=unpacked[name], env=env)
            run('/usr/bin/make', '-j' + jobs, cwd=unpacked[name], env=env)
            run('/usr/bin/make', 'install', cwd=unpacked[name], env=env)
        for name, binary in [('git-lfs-' + goarch, 'git-lfs'), ('rg-' + rgarch, 'rg')]:
            shutil.copy2(unpacked[name] / binary, tools / 'bin' / binary)
            (tools / 'bin' / binary).chmod(0o755)
        for tool in (tools / 'bin').iterdir():
            if tool.is_file() and os.access(tool, os.X_OK):
                write_launcher(root, tool.name, [tool], bootstrap)
        write_launcher(root, 'node', [root / 'runtime/node/bin/node'], bootstrap)
        write_launcher(root, 'python3', ['/usr/bin/python3'], bootstrap)
        # Apple Git remains supplied by the explicitly required Command Line Tools.
        write_launcher(root, 'git', ['/usr/bin/git'], bootstrap)
        for name in ('git-lfs', 'rg'):
            write_launcher(root, name, [tools / 'bin' / name], bootstrap)
        installer = work / 'installer'
        shutil.copytree(source / 'dearmachine-concierge', installer, symlinks=True)
        pnpm = [root / 'runtime/node/bin/node', unpacked['pnpm'] / 'bin/pnpm.mjs']
        env['npm_config_python'] = '/usr/bin/python3'
        print('Building Standard installer and model host', file=sys.stderr)
        run(*pnpm, 'install', '--frozen-lockfile', '--network-concurrency=4', '--child-concurrency=2', '--fetch-timeout=600000', cwd=installer, env=env)
        run(*pnpm, 'build', cwd=installer, env=env)
        shutil.rmtree(installer / 'node_modules')
        for path in (installer / 'packages').glob('*/node_modules'):
            shutil.rmtree(path)
        run(*pnpm, 'install', '--prod', '--offline', '--frozen-lockfile', cwd=installer, env=env)
        runtime = root / 'runtime/installer'
        runtime.mkdir()
        shutil.copy2(installer / 'package.json', runtime / 'package.json')
        shutil.copytree(installer / 'node_modules', runtime / 'node_modules', symlinks=True)
        for package in (installer / 'packages').iterdir():
            if not (package / 'dist').is_dir():
                continue
            dest = runtime / 'packages' / package.name
            dest.mkdir(parents=True)
            shutil.copy2(package / 'package.json', dest / 'package.json')
            shutil.copytree(package / 'dist', dest / 'dist', symlinks=True)
            if (package / 'node_modules').is_dir():
                shutil.copytree(package / 'node_modules', dest / 'node_modules', symlinks=True)
        claude = sorted({path.resolve() for path in (runtime / 'node_modules').glob('**/@anthropic-ai/claude-agent-sdk-darwin-' + arch + '/claude') if path.is_file()})
        if len(claude) != 1:
            raise ValueError('Expected one pinned native Claude runtime')
        (root / 'runtime/vendor').mkdir()
        (root / 'runtime/vendor/claude').symlink_to(os.path.relpath(claude[0], root / 'runtime/vendor'))
        entries = {'machtiani-installer': 'app', 'machtiani-model-host': 'model-host', 'machtiani-installer-backend': 'backend-adapter'}
        for name, package in entries.items():
            write_launcher(root, name, [root / 'runtime/node/bin/node', runtime / 'packages' / package / 'dist/bin.mjs'], bootstrap)
        if bootstrap:
            write_launcher(root, 'dearmachine', [root / 'bin/machtiani-installer'], True)
        else:
            native = root / 'runtime/native'
            native.mkdir()
            for component, name, package in [('dearmachine/dearmachine', 'dearmachine', './cmd/dearmachine'),
                                             ('dearmachine/dearmachine', 'agent-manager', './cmd/agent-manager'),
                                             ('machtiani-harness/agent', 'machtiani', './cmd/machtiani')]:
                flags = '-s -w ' + stamp if name == 'machtiani' else '-s -w'
                run(unpacked['go-' + goarch] / 'bin/go', 'build', '-trimpath', '-buildvcs=false', '-ldflags=' + flags,
                    '-o', native / name, package, cwd=source / component, env=dict(env, CGO_ENABLED='0' if name == 'machtiani' else '1'))
                write_launcher(root, name, [native / name], False)
            manifest = dict(version=1, method='standard', acquisition='native', platform='darwin-' + arch, sourceRoot='source',
                            binaries=dict(dearmachine='bin/dearmachine', agentManager='bin/agent-manager', machtiani='bin/machtiani', modelHost='bin/machtiani-model-host'),
                            installerRuntime='runtime/installer', installerLayout='workspace')
            (root / 'distribution.json').write_text(json.dumps(manifest) + '\n')
            (root / 'distribution.json').chmod(0o600)
    validate_libraries(root)
