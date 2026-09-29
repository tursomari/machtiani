#!/usr/bin/env python3
"""Create a checksum-pinned curl download from a prepared, unrelocated runtime."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shlex
import tarfile
from urllib.parse import urlsplit


def validate_url(value):
    url = urlsplit(value)
    if (url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password
            or url.query or url.fragment or (url.scheme == 'http' and url.hostname != '127.0.0.1')):
        raise ValueError('use HTTPS, or HTTP on 127.0.0.1 for local testing, without credentials or query parameters')


def validate_prefix(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value):
        raise ValueError('artifact name prefix may contain only letters, digits, dot, underscore, and hyphen')


def artifact_names(prefix=None):
    """Return the archive, bootstrap, and manifest names for one download."""
    if prefix is None:
        return 'runtime.tar.gz', 'install', 'manifest.json'
    validate_prefix(prefix)
    return prefix + '.tar.gz', prefix + '.bootstrap.sh', prefix + '.manifest.json'


# Nix-style system name -> `uname -sm` on that system.
SYSTEMS = {'x86_64-linux': 'Linux x86_64', 'aarch64-linux': 'Linux aarch64',
           'x86_64-darwin': 'Darwin x86_64', 'aarch64-darwin': 'Darwin arm64'}


def render_bootstrap(base_url, checksum, release, archive_name='runtime.tar.gz', system='x86_64-linux'):
    validate_url(base_url)
    if system not in SYSTEMS:
        raise ValueError('unsupported system: ' + system)
    script = Path(__file__).with_name('standard-bootstrap.sh').read_text()
    for key, value in dict(BASE_URL=base_url.rstrip('/'), ARCHIVE_NAME=archive_name,
                           ARCHIVE_SHA=checksum, RELEASE_ID=release, PLATFORM=SYSTEMS[system]).items():
        script = script.replace('@' + key + '@', shlex.quote(value))
    return script


def package(runtime, output, base_url, prefix=None, system='x86_64-linux'):
    """Archive an unrelocated runtime and render its checksum-pinned bootstrap."""
    validate_url(base_url)
    archive_name, bootstrap_name, manifest_name = artifact_names(prefix)
    runtime = Path(runtime).resolve()
    output = Path(output).resolve()
    if output.exists() or output.is_relative_to(runtime):
        raise ValueError('output must be a new directory outside the runtime')
    # macOS runtimes are position independent and have no relocation plan.
    required = ('distribution.json', 'bootstrap-runtime.sh') + (('relocation.json',) if system.endswith('-linux') else ())
    for name in required:
        if not (runtime / name).is_file():
            raise ValueError(f'prepared runtime is missing {name}')
    if (runtime / '.relocated').exists():
        raise ValueError('do not distribute a runtime already relocated for a particular machine')
    revisions = json.loads((runtime / 'source/bootstrap-source-revisions.json').read_text())
    output.mkdir(mode=0o700)
    archive = output / archive_name
    with archive.open('wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=1, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w|') as tar:
            def metadata(member):
                member.uid = member.gid = member.mtime = 0
                member.uname = member.gname = ''
                return member
            for path in sorted(runtime.iterdir()):
                tar.add(path, arcname=path.name, filter=metadata)
    with archive.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    release = revisions['.'][:12] + '-' + checksum[:12]
    (output / bootstrap_name).write_text(render_bootstrap(base_url, checksum, release, archive_name, system))
    (output / manifest_name).write_text(json.dumps(dict(version=1, system=system, release=release,
        revisions=revisions, archive_sha256=checksum, archive_bytes=archive.stat().st_size), indent=2) + '\n')
    for path in output.iterdir():
        path.chmod(0o644)
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--base-url', default='http://127.0.0.1:8765')
    parser.add_argument('--name-prefix', help='Name artifacts <prefix>.tar.gz, <prefix>.bootstrap.sh and <prefix>.manifest.json')
    args = parser.parse_args()
    release = package(args.runtime, args.output, args.base_url, args.name_prefix)
    print(f'Local download ready: {args.output.resolve()}\nRelease: {release}', flush=True)


if __name__ == '__main__':
    main()
