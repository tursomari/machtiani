#!/usr/bin/env python3
"""Package existing Nix outputs and committed sources for a loopback-only IXE.

Never builds, downloads, copies a live home, or exports Git history. Compression
streams to disk; repeated runs reuse a closure with the same store-path set.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import shlex
import shutil
import subprocess
import tarfile
from urllib.parse import urlsplit

COMPONENTS = ('dearmachine', 'machtiani-harness', 'dearmachine-concierge')


def run(*args):
    return subprocess.check_output(args)


def validate_url(value):
    url = urlsplit(value)
    if (url.scheme != 'http' or url.hostname != '127.0.0.1' or url.username or url.password
            or url.path not in ('', '/') or url.query or url.fragment or not url.port):
        raise ValueError('This preview requires http://127.0.0.1:PORT with no credentials or path')


def validate_member(entry):
    path = PurePosixPath(entry.name)
    if path.is_absolute() or '..' in path.parts or any(
        part in ('.git', '.ssh', '.secrets', '.codex', '.omp') or part.startswith('.env') for part in path.parts
    ):
        raise ValueError(f'Forbidden source archive entry: {entry.name}')
    if not (entry.isfile() or entry.isdir() or entry.issym()):
        raise ValueError(f'Unsupported archive entry: {entry.name}')
    if entry.issym():
        target = posixpath.normpath(posixpath.join(str(path.parent), entry.linkname))
        if target.startswith('/') or target == '..' or target.startswith('../'):
            raise ValueError(f'Escaping source symlink: {entry.name}')


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def store_path(value):
    if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-[A-Za-z0-9+._?=-]+', value):
        raise ValueError('Expected an existing top-level /nix/store package path')
    subprocess.run(['nix-store', '--check-validity', value], check=True)
    return Path(value)


def verify_installer_source(root, package):
    runtime = package / 'libexec/machtiani-installer'
    names = run('git', '-C', str(root), 'ls-files', '-z').decode().split('\0')
    selected = [name for name in names if name == 'package.json' or
                (name.startswith('packages/') and ('/src/' in name or name.endswith('/package.json')))]
    if not selected:
        raise ValueError('Installer source contains no runtime files')
    for name in selected:
        installed = runtime / name
        if not installed.is_file() or installed.read_bytes() != run('git', '-C', str(root), 'show', f'HEAD:{name}'):
            raise ValueError(f'Existing installer package does not match the selected source: {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--installer-store-path', required=True)
    parser.add_argument('--git-store-path', required=True)
    parser.add_argument('--extra-store-path', action='append', default=[])
    parser.add_argument('--base-url', default='http://127.0.0.1:8765')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    validate_url(args.base_url)
    root = args.source_root.resolve()
    if run('git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all').strip():
        raise ValueError('Commit the source worktree before preparing a bundle')
    revisions = {'.': run('git', '-C', str(root), 'rev-parse', 'HEAD').decode().strip()}
    for component in COMPONENTS:
        expected = run('git', '-C', str(root), 'rev-parse', f'HEAD:{component}').decode().strip()
        actual = run('git', '-C', str(root / component), 'rev-parse', 'HEAD').decode().strip()
        if expected != actual:
            raise ValueError(f'{component} does not match the umbrella pin')
        revisions[component] = expected
    installer = store_path(args.installer_store_path)
    git = store_path(args.git_store_path)
    if not (git / 'bin/git').is_file():
        raise ValueError('The Git package must contain bin/git')
    verify_installer_source(root / 'dearmachine-concierge', installer)
    packages = [str(installer), str(git), *(str(store_path(value)) for value in args.extra_store_path)]
    paths = sorted(set(run('nix-store', '--query', '--requisites', *packages).decode().splitlines()))
    cache_id = hashlib.sha256('\n'.join(paths).encode()).hexdigest()
    output = args.output.resolve()
    if output == root or output.is_relative_to(root):
        raise ValueError('Distribution artifacts must be outside the source worktree')
    marker = output / '.bundle-cache.json'
    if output.exists() and any(output.iterdir()) and not marker.is_file():
        raise ValueError('Refusing to write into an unrelated nonempty directory')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    previous = json.loads(marker.read_text()) if marker.exists() else {}
    payload = output / 'closure.nar.gz'
    if previous.get('cache_id') != cache_id or not payload.is_file() or sha256(payload) != previous.get('closure_sha256'):
        temporary = output / 'closure.nar.gz.tmp'
        print('Exporting already-built packages to a compressed local artifact; no builds or downloads.', flush=True)
        with temporary.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=1, mtime=0) as zipped:
            process = subprocess.Popen(['nix-store', '--export', *paths], stdout=subprocess.PIPE)
            try:
                shutil.copyfileobj(process.stdout, zipped, length=1024 * 1024)
            finally:
                process.stdout.close()
            if process.wait() != 0:
                raise RuntimeError('Nix closure export failed')
        temporary.replace(payload)
    else:
        print('Reusing the existing compressed closure artifact.', flush=True)
    closure_sha = sha256(payload)
    marker.write_text(json.dumps({'cache_id': cache_id, 'closure_sha256': closure_sha}) + '\n')

    source = output / 'source.tar.gz'
    with source.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=1, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w|') as archive:
            for component in ('.', *COMPONENTS):
                with tarfile.open(fileobj=io.BytesIO(run('git', '-C', str(root / component), 'archive', 'HEAD'))) as snapshot:
                    for member in snapshot:
                        validate_member(member)
                        content = snapshot.extractfile(member) if member.isfile() else None
                        if component != '.':
                            member.name = f'{component}/{member.name}'
                        member.uid = member.gid = member.mtime = 0
                        member.uname = member.gname = ''
                        archive.addfile(member, content)
            metadata = json.dumps(revisions, sort_keys=True).encode()
            entry = tarfile.TarInfo('bootstrap-source-revisions.json')
            entry.size = len(metadata)
            archive.addfile(entry, io.BytesIO(metadata))
    system = run('nix', '--offline', 'eval', '--impure', '--raw', '--expr', 'builtins.currentSystem').decode()
    release = revisions['.'][:12]
    values = dict(BASE_URL=args.base_url.rstrip('/'), INSTALLER_PATH=str(installer), GIT_PATH=str(git),
                  SOURCE_SHA=sha256(source), CLOSURE_SHA=closure_sha, SYSTEM=system, RELEASE=release)
    bootstrap = (root / 'scripts/curl-bootstrap.sh').read_text()
    for key, value in values.items():
        bootstrap = bootstrap.replace(f'@{key}@', shlex.quote(value))
    (output / 'install').write_text(bootstrap)
    manifest = dict(version=1, base_url=args.base_url.rstrip('/'), release=release, system=system,
                    revisions=revisions, installer_path=str(installer), git_path=str(git),
                    packages=packages, source_sha256=values['SOURCE_SHA'], closure_sha256=closure_sha,
                    install_sha256=sha256(output / 'install'))
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for name in ('install', 'manifest.json', 'closure.nar.gz', 'source.tar.gz'):
        (output / name).chmod(0o644)
    print(f'Bundle ready: {output}\nClosure size: {payload.stat().st_size} bytes (local file)', flush=True)


if __name__ == '__main__':
    main()
