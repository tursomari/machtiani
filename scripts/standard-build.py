#!/usr/bin/env python3
"""Standard acquisition: Docker on Linux, a native build on macOS."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys

# The supplied source snapshot is immutable, including Python cache files.
sys.dont_write_bytecode = True


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def target(system=None, machine=None):
    system, machine = system or platform.system(), machine or platform.machine()
    if system == 'Linux' and machine == 'x86_64':
        return 'linux-x64'
    if system == 'Darwin' and machine in ('x86_64', 'arm64'):
        return 'darwin-' + ('x64' if machine == 'x86_64' else 'arm64')
    raise ValueError('Standard builds support Linux x86-64 and macOS Intel/Apple Silicon.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--installer-root', type=Path)
    parser.add_argument('--bootstrap', action='store_true')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    selected = target()
    common = module('container_build', 'container-build.py')
    options = {}
    if selected.startswith('darwin-'):
        native = module('macos_build', 'macos-build.py')
        native.preflight()
        options = dict(builder=native.build_runtime, activate=False,
                       namespace='standard-bootstrap' if args.bootstrap else 'standard-releases', target=selected)
    home = Path(os.environ.get('HOME', ''))
    data = Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
    release = common.acquire(args.source_root.resolve(), home, data, args.bootstrap,
                             args.installer_root.resolve() if args.installer_root else None, args.output, **options)
    result = dict(release=str(release), manifest=str(release / 'distribution.json'),
                  launcher=str(release / 'bin/machtiani-installer'))
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
