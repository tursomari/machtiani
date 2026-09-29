#!/usr/bin/env python3
"""Container-side packaging. Reuses the existing runtime relocator on the host."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path('/release')
PREFIX = '/__dearmachine_runtime__/'
SYSROOT = ROOT / 'runtime/sysroot'
# Debian multiarch directory and ELF loader of the build image's architecture.
TRIPLET, LOADER, NODE_PLATFORM = {'x86_64': ('x86_64-linux-gnu', '/lib64/ld-linux-x86-64.so.2', 'linux-x64'),
                                  'aarch64': ('aarch64-linux-gnu', '/lib/ld-linux-aarch64.so.1', 'linux-arm64')}[platform.machine()]
LIB = '/usr/lib/' + TRIPLET
TOOLS = ['bash', 'cat', 'chmod', 'cp', 'curl', 'cut', 'date', 'dirname', 'env', 'find',
         'gawk', 'git', 'git-lfs', 'grep', 'head', 'id', 'ln', 'ls', 'mkdir', 'mv',
         'patchelf', 'ps', 'python3', 'readlink', 'realpath', 'rg', 'rm', 'sed',
         'sha256sum', 'sleep', 'sort', 'sqlite3', 'stat', 'tail', 'tar', 'touch',
         'tr', 'uname', 'uniq', 'wc', 'which', 'xargs', 'zsh']


def output(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ''


def runtime(path):
    return PREFIX + 'sysroot' + str(path)


def copy(path):
    source = Path(path)
    target = SYSROOT / str(source).lstrip('/')
    if source.is_dir():
        shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target, follow_symlinks=True)
    return target


def inventory(plan):
    plan['elfs'] = []
    libraries = plan['node_libraries']
    for path in sorted((ROOT / 'runtime').rglob('*')):
        if str(path.relative_to(ROOT)) in plan.get('unmodified_elfs', []):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        interpreter = output('patchelf', '--print-interpreter', str(path))
        if interpreter:
            resolved = Path(interpreter).resolve()
            if not (SYSROOT / str(resolved).lstrip('/')).exists():
                copy(resolved)
            interpreter = runtime(resolved)
        rpath = output('patchelf', '--print-rpath', str(path))
        needed = output('patchelf', '--print-needed', str(path)).splitlines()
        if not interpreter and not needed:
            continue  # Static Go executables and the ELF loader need no relocation.
        # Preserve origin-only vendor libraries; the relocator supplies links.
        if rpath not in ('$ORIGIN', '$ORIGIN/'):
            rpath = ':'.join(filter(None, (rpath, libraries)))
        plan['elfs'].append(dict(path=str(path.relative_to(ROOT)), interpreter=interpreter,
                                 rpath=rpath, needed=needed))


def preserve_embedded_executable(path, plan):
    """Bun embeds application data; changing its ELF layout can break startup."""
    payload = path.with_name(path.name + '.unmodified')
    path.rename(payload)
    plan.setdefault('unmodified_elfs', []).append(str(payload.relative_to(ROOT)))
    loader = runtime(Path(LOADER).resolve())
    executable = PREFIX + str(payload.relative_to(ROOT / 'runtime'))
    path.write_text('#!/bin/sh\nexec "' + loader + '" --library-path "' +
                    plan['node_libraries'] + '" "' + executable + '" "$@"\n')
    path.chmod(0o755)
    plan['texts'].append(str(path.relative_to(ROOT)))


def main():
    if '--products' in sys.argv:
        plan = json.loads((ROOT / 'relocation.json').read_text())
        for name in ('dearmachine', 'agent-manager', 'machtiani'):
            plan['commands'][name] = PREFIX + 'native/' + name
        plan['bootstrap_only'] = False
        inventory(plan)
        (ROOT / 'relocation.json').write_text(json.dumps(plan))
        manifest = dict(version=1, method='standard', acquisition='container', sourceRoot='source', binaries=dict(
            dearmachine='bin/dearmachine', agentManager='bin/agent-manager',
            machtiani='bin/machtiani', modelHost='bin/machtiani-model-host'),
            installerRuntime='runtime/installer', installerLayout='workspace')
        (ROOT / 'distribution.json').write_text(json.dumps(manifest) + '\n')
        return
    SYSROOT.mkdir(parents=True)
    commands = {}
    for name in TOOLS:
        path = shutil.which(name)
        if path:
            path = Path(path).resolve()
            copy(path)
            commands[name] = runtime(path)
    copy('/usr/local/bin/node')
    commands['node'] = runtime('/usr/local/bin/node')
    for path in (LIB, '/usr/lib/python3.11', '/usr/lib/git-core', '/usr/share/git-core',
                 '/usr/share/terminfo', '/usr/share/zsh', '/etc/ssl/certs', '/usr/share/ca-certificates'):
        copy(path)
    # Remove static archives, build metadata and Python bytecode from runtime data.
    for path in SYSROOT.rglob('*'):
        if path.is_file() and (path.suffix in ('.a', '.pyc') or path.name.endswith('.la')):
            path.unlink()
    shutil.copytree('/payload/installer', ROOT / 'runtime/installer', symlinks=True)
    shutil.copy2('/packaging/relocate-standard-runtime.py', ROOT / 'relocate-standard-runtime.py')
    libraries = runtime(LIB)
    loader = runtime(Path(LOADER).resolve())
    plan = dict(runtime_prefix=PREFIX, bootstrap_only=True, symlinks={}, texts=[], elfs=[], commands=commands,
                patcher='runtime/sysroot/usr/bin/patchelf', patcher_loader='runtime/' + loader.removeprefix(PREFIX),
                patcher_libraries=libraries, node_libraries=libraries, node_addon_root='runtime/installer/node_modules/',
                environment=dict(SSL_CERT_FILE=runtime('/etc/ssl/certs/ca-certificates.crt'),
                    GIT_SSL_CAINFO=runtime('/etc/ssl/certs/ca-certificates.crt'),
                    NODE_EXTRA_CA_CERTS=runtime('/etc/ssl/certs/ca-certificates.crt'),
                    GIT_EXEC_PATH=runtime('/usr/lib/git-core'), GIT_TEMPLATE_DIR=runtime('/usr/share/git-core/templates')),
                command_environments={'python3': {'PYTHONHOME': runtime('/usr')}})
    claude = sorted({path.resolve() for path in (ROOT / 'runtime/installer/node_modules').glob('**/@anthropic-ai/claude-agent-sdk-' + NODE_PLATFORM + '/claude') if path.is_file()})
    if len(claude) != 1:
        raise ValueError('Expected one pinned Claude executable in the production dependency graph; found ' + str(len(claude)))
    preserve_embedded_executable(claude[0], plan)
    plan['environment']['MACHTIANI_CLAUDE_EXECUTABLE'] = PREFIX + str(claude[0].relative_to(ROOT / 'runtime'))
    # Absolute distribution symlinks must resolve inside the copied sysroot.
    for path in SYSROOT.rglob('*'):
        if path.is_symlink():
            target = os.readlink(path)
            if target.startswith('/'):
                copied = SYSROOT / str(Path(target).resolve()).lstrip('/')
                if not copied.exists():
                    path.unlink()  # development or host-only link, not a runtime dependency
                else:
                    path.unlink()
                    path.symlink_to(os.path.relpath(copied, path.parent))
    entries = {'machtiani-installer': 'packages/app/dist/bin.mjs',
               'machtiani-model-host': 'packages/model-host/dist/bin.mjs',
               'machtiani-installer-backend': 'packages/backend-adapter/dist/bin.mjs'}
    launchers = ROOT / 'runtime/launchers'
    launchers.mkdir()
    for name, entry in entries.items():
        path = launchers / name
        path.write_text('#!/bin/sh\nexec "' + runtime('/usr/local/bin/node') + '" "' + PREFIX + 'installer/' + entry + '" "$@"\n')
        path.chmod(0o755)
        plan['texts'].append(str(path.relative_to(ROOT)))
        plan['commands'][name] = PREFIX + 'launchers/' + name
    # A bootstrap has no native executable; its launcher enters the TS wizard.
    plan['commands']['dearmachine'] = plan['commands']['machtiani-installer']
    inventory(plan)
    (ROOT / 'relocation.json').write_text(json.dumps(plan))
    (ROOT / 'bootstrap-runtime.sh').write_text(f'''#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
export PYTHONHOME="$root/runtime/sysroot/usr"
exec "$root/runtime/sysroot{Path(LOADER).resolve()}" --library-path "$root/runtime/sysroot{LIB}" "$root/runtime/sysroot/usr/bin/python3.11" "$root/relocate-standard-runtime.py" "$root"
''')


if __name__ == '__main__':
    main()
