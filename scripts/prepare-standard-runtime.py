#!/usr/bin/env python3
"""Produce a relocatable Linux x86-64 runtime from existing reviewed Nix outputs.

Nix is a producer tool only. This command never builds, fetches, or copies a
user home. The destination must be a new directory outside the source tree.
"""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile

spec = importlib.util.spec_from_file_location('source_bundle', Path(__file__).with_name('prepare-curl-bundle.py'))
source_bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_bundle)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def store_root(path):
    path = Path(path)
    if path.parts[:3] != ('/', 'nix', 'store') or len(path.parts) < 4:
        raise ValueError('producer inputs must be existing Nix runtime outputs')
    return Path('/nix/store') / path.parts[3]


def relative_store(path):
    return 'runtime/' + str(path).removeprefix('/nix/store/')


def relativize_store_links(root):
    """Bootstrap libraries must resolve before the bundled Python can start."""
    for directory, dirs, files in os.walk(root / 'runtime'):
        parent = Path(directory)
        parent.chmod(parent.stat().st_mode | 0o700)
        for name in [*dirs, *files]:
            path = Path(directory) / name
            if path.is_symlink() and os.readlink(path).startswith('/nix/store/'):
                target = root / relative_store(os.readlink(path))
                path.unlink()
                path.symlink_to(os.path.relpath(target, path.parent))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--installer', required=True, type=Path)
    parser.add_argument('--dearmachine', required=True, type=Path)
    parser.add_argument('--harness', required=True, type=Path)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--patchelf', required=True, type=Path)
    parser.add_argument('--tool-package', action='append', default=[], type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.source_root.resolve()
    destination = args.output.resolve()
    if destination == root or destination.is_relative_to(root) or destination.exists():
        raise ValueError('output must be a new directory outside the source tree')
    if output('uname', '-sm') != 'Linux x86_64':
        raise ValueError('this producer currently supports Linux x86-64 only')
    revisions = {}
    for component in ('.', *source_bundle.COMPONENTS):
        checkout = root / component
        if output('git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=all'):
            raise ValueError(f'commit the source changes before packaging: {component}')
        revision = output('git', '-C', str(checkout), 'rev-parse', 'HEAD')
        if component != '.' and revision != output('git', '-C', str(root), 'rev-parse', f'HEAD:{component}'):
            raise ValueError(f'component differs from the umbrella pin: {component}')
        revisions[component] = revision
    source_bundle.verify_installer_source(root / 'dearmachine-concierge', args.installer)
    expected = output('nix', 'eval', '--offline', '--raw', str(root / 'dearmachine') + '#default.outPath')
    if str(args.dearmachine) != expected:
        raise ValueError('dearmachine output does not match the selected derivation')
    # Harness builds carry a build timestamp; two clean builds of one commit
    # need not have identical store paths. Verify the full embedded revision.
    version = output(str(args.harness / 'bin/machtiani'), '--version').splitlines()
    if f"commit: {revisions['machtiani-harness']}" not in version or 'dirty: clean' not in version:
        raise ValueError('machtiani-harness output does not report the selected clean revision')
    commands = {}
    for package in args.tool_package:
        if not (package / 'bin').is_dir():
            continue
        for path in sorted((package / 'bin').iterdir()):
            if path.is_file() and os.access(path, os.X_OK) and not path.name.startswith('.'):
                commands[path.name] = str(path)
    commands.update({name: str(args.installer / 'bin' / name) for name in (
        'machtiani-installer', 'machtiani-model-host', 'machtiani-installer-backend')})
    commands.update(dearmachine=str(args.dearmachine / 'bin/dearmachine'),
                    machtiani=str(args.harness / 'bin/machtiani'),
                    **{'agent-manager': str(args.dearmachine / 'bin/agent-manager'), 'python3': str(args.python)})
    required = ('node', 'git', 'git-lfs', 'bash', 'rg', 'curl', 'sqlite3', 'cp', 'sleep', 'sed')
    if any(name not in commands for name in required):
        raise ValueError('tool packages must supply: ' + ', '.join(required))
    packages = {str(store_root(path)) for path in [*commands.values(), args.python, args.patchelf, *args.tool_package]}
    paths = sorted(set(output('nix-store', '--query', '--requisites', *sorted(packages)).splitlines()))
    destination.mkdir(mode=0o700)
    runtime = destination / 'runtime'
    runtime.mkdir()
    print(f'Copying {len(paths)} cached runtime outputs (no builds or downloads).', flush=True)
    for name in paths:
        source = Path(name)
        target = runtime / source.name
        if source.is_dir():
            shutil.copytree(source, target, symlinks=True)
        else:
            shutil.copy2(source, target, follow_symlinks=False)
    relativize_store_links(destination)
    plan = dict(symlinks={}, texts=[], elfs=[], commands=commands, environment={})
    patchelf = str(args.patchelf)
    def field(flag, path):
        result = subprocess.run([patchelf, flag, str(path)], text=True, capture_output=True)
        return result.stdout.strip() if result.returncode == 0 else ''
    node = Path(commands['node']).resolve()
    plan['node_libraries'] = field('--print-rpath', node)
    if not plan['node_libraries'] or not field('--print-interpreter', node):
        raise ValueError('the producer must resolve the bundled Node ELF and its library closure')
    plan['node_addon_root'] = relative_store(args.installer / 'libexec/machtiani-installer/node_modules') + '/'
    for directory, dirs, files in os.walk(runtime):
        for name in [*dirs, *files]:
            path = Path(directory) / name
            relative = str(path.relative_to(destination))
            if path.is_symlink():
                target = os.readlink(path)
                if target.startswith('/nix/store/'):
                    if str(store_root(target)) not in paths:
                        raise ValueError('runtime has a dangling external store symlink')
                    plan['symlinks'][relative] = target
                elif target.startswith('/') and not target.startswith(('/bin/', '/usr/bin/')):
                    raise ValueError('unexpected external runtime symlink')
                continue
            path.chmod(path.stat().st_mode | 0o200 | (0o100 if path.is_dir() else 0))
            if not path.is_file():
                continue
            with path.open('rb') as stream:
                magic = stream.read(4)
                if magic == b'\x7fELF':
                    plan['elfs'].append(dict(path=relative, interpreter=field('--print-interpreter', path),
                                             rpath=field('--print-rpath', path), needed=field('--print-needed', path).splitlines()))
                elif path.stat().st_size < 16_777_216:
                    data = magic + stream.read()
                    if b'/nix/store/' in data and b'\0' not in data:
                        plan['texts'].append(relative)
    for prefix, executable in (('python', args.python.resolve()), ('patcher', args.patchelf.resolve())):
        plan[prefix] = relative_store(executable)
        plan[prefix + '_loader'] = relative_store(field('--print-interpreter', executable))
        plan[prefix + '_libraries'] = field('--print-rpath', executable)
    certs = [Path(path) / 'etc/ssl/certs/ca-bundle.crt' for path in paths]
    certificate = next((str(path) for path in certs if path.is_file()), None)
    if certificate is None:
        raise ValueError('the runtime closure must include a CA certificate bundle')
    git_root = store_root(commands['git'])
    plan['environment'].update(SSL_CERT_FILE=certificate, GIT_SSL_CAINFO=certificate, NODE_EXTRA_CA_CERTS=certificate,
                               GIT_EXEC_PATH=str(git_root / 'libexec/git-core'), GIT_TEMPLATE_DIR=str(git_root / 'share/git-core/templates'))
    (destination / 'relocation.json').write_text(json.dumps(plan) + '\n')
    shutil.copy2(Path(__file__).with_name('relocate-standard-runtime.py'), destination)
    bootstrap = '#!/bin/sh\nset -eu\nroot=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)\n'
    bootstrap += f'export PYTHONHOME="$root/{relative_store(store_root(args.python))}"\n'
    libraries = plan['python_libraries'].replace('/nix/store/', '$root/runtime/')
    bootstrap += f'exec "$root/{plan["python_loader"]}" --library-path "{libraries}" "$root/{plan["python"]}" "$root/relocate-standard-runtime.py" "$root"\n'
    (destination / 'bootstrap-runtime.sh').write_text(bootstrap)
    (destination / 'distribution.json').write_text(json.dumps(dict(version=1, sourceRoot='source', binaries=dict(
        dearmachine='bin/dearmachine', machtiani='bin/machtiani', modelHost='bin/machtiani-model-host', agentManager='bin/agent-manager'
    )), indent=2) + '\n')
    source = destination / 'source'
    source.mkdir()
    for component in ('.', *source_bundle.COMPONENTS):
        archive = subprocess.check_output(['git', '-C', str(root / component), 'archive', 'HEAD'])
        with tarfile.open(fileobj=io.BytesIO(archive)) as snapshot:
            for entry in snapshot:
                source_bundle.validate_member(entry)
            snapshot.extractall(source / component, filter='data')
    (source / 'bootstrap-source-revisions.json').write_text(json.dumps(revisions) + '\n')
    print(f'Portable runtime prepared: {destination}', flush=True)


if __name__ == '__main__':
    main()
