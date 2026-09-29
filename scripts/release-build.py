#!/usr/bin/env python3
"""Build one release target's download artifacts from a committed checkout.

The runtime is built unrelocated (with Docker on Linux, natively on macOS) and
packaged with its checksum-pinned bootstrap. The packaged archive is then
extracted, relocated where needed, and probed in a scratch directory. Output
names follow dearmachine-<tag>-<target>.*.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile

# The checkout is copied into the build context; keep it free of cache files.
sys.dont_write_bytecode = True

# Release target -> (Nix-style system, `uname -s`, `uname -m`) of its build host.
TARGETS = {'linux-x64': ('x86_64-linux', 'Linux', 'x86_64'), 'linux-arm64': ('aarch64-linux', 'Linux', 'aarch64'),
           'darwin-x64': ('x86_64-darwin', 'Darwin', 'x86_64'), 'darwin-arm64': ('aarch64-darwin', 'Darwin', 'arm64')}
PROBES = (('machtiani-installer', '--help'), ('git', '--version'), ('git-lfs', 'version'),
          ('dearmachine', '--help'), ('agent-manager', '--help'), ('machtiani', '--version'))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def validate_tag(value):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?', value):
        raise ValueError('release tag must look like v1.2.3 or v1.2.3-rc.1')


def validate_repository(value):
    if not re.fullmatch(r'[A-Za-z0-9-]+/[A-Za-z0-9._-]+', value):
        raise ValueError('repository must be <owner>/<name>')


def artifact_prefix(tag, target):
    return 'dearmachine-' + tag + '-' + target


def remove_tree(path):
    # Runtime trees can contain read-only directories.
    subprocess.run(['chmod', '-R', 'u+rwX', str(path)], check=True)
    shutil.rmtree(path)


def build(source, output, tag, repository, target):
    common = module('container_build', 'container-build.py')
    download = module('standard_download', 'prepare-standard-download.py')
    base_url = 'https://github.com/' + repository + '/releases/download/' + tag
    prefix = artifact_prefix(tag, target)
    system, kernel, machine = TARGETS[target]
    if (platform.system(), platform.machine()) != (kernel, machine):
        raise ValueError(f'build {target} on a {kernel} {machine} host')
    # Keep at most two runtime-sized trees on disk at once.
    with tempfile.TemporaryDirectory(prefix='dearmachine-release-') as temporary:
        work = Path(temporary)
        context = work / 'source'
        common.snapshot(source, context)
        harness = json.loads((context / 'bootstrap-source-revisions.json').read_text())['machtiani-harness']
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        if kernel == 'Linux':
            common.build_runtime(context, runtime)
        else:
            module('macos_build', 'macos-build.py').build_runtime(context, runtime)
            (runtime / 'bootstrap-runtime.sh').write_text(
                '#!/bin/sh\n# macOS releases are position independent; there is nothing to relocate.\nexit 0\n')
        remove_tree(context)
        try:
            release = download.package(runtime, output, base_url, prefix, system)
            remove_tree(runtime)
            # Relocate (Linux) and probe the shipped archive at a different path.
            check = work / 'check'
            check.mkdir(mode=0o700)
            common.command('tar', '-xzf', output / (prefix + '.tar.gz'), '-C', check)
            common.command('sh', check / 'bootstrap-runtime.sh')
            for name, argument in PROBES:
                result = common.command(check / 'bin' / name, argument, capture=True, timeout=60)
                if name == 'machtiani' and 'commit: ' + harness not in result.splitlines():
                    raise ValueError('machtiani --version does not report the harness revision ' + harness)
        except BaseException:
            if output.exists():
                remove_tree(output)
            raise
        return release


def describe(error):
    """Keep failures readable; a copy error can list thousands of files."""
    if isinstance(error, shutil.Error) and error.args and isinstance(error.args[0], list):
        entries = error.args[0]
        return f'{len(entries)} files could not be copied; first: {entries[0][2]}' if entries else 'Copy failed'
    text = str(error) or 'Build cancelled'
    return text if len(text) <= 2000 else text[:2000] + f' ... ({len(text)} characters)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True, choices=TARGETS)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--repository', required=True, help='GitHub <owner>/<name> that publishes the release')
    parser.add_argument('--output', required=True, type=Path, help='New directory outside the checkout')
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    validate_tag(args.tag)
    validate_repository(args.repository)
    source = args.source_root.resolve()
    output = args.output.resolve()
    if output.is_relative_to(source):
        raise ValueError('output must be outside the source checkout')
    release = build(source, output, args.tag, args.repository, args.target)
    print(f'Release artifacts for {args.target} ready in {output} (release {release})', flush=True)


if __name__ == '__main__':
    def cancelled(signum, frame):
        raise KeyboardInterrupt('Build cancelled')
    signal.signal(signal.SIGTERM, cancelled)
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(describe(error), file=sys.stderr)
        sys.exit(1)
