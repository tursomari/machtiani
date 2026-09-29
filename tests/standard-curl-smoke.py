#!/usr/bin/env python3
"""Test an existing Standard download in a fresh, cached Debian container.

No image/package builds, host mounts, credentials, inference, or inboxes.
The container uses host networking only to reach the loopback artifact server.
"""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import threading
import time
from urllib.parse import urlsplit


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def uninstall_terminal(container, answer, *, busy=False):
    """Drive the actual human confirmation through docker exec's real PTY."""
    master, slave = pty.openpty()
    child = subprocess.Popen(['docker', 'exec', '-it', '--user', 'installer',
        '--env', 'HOME=/home/installer', container,
        '/home/installer/.local/bin/dearmachine', 'uninstall'],
        stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = b''
    answered = False
    deadline = time.monotonic() + 60
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break
                if not answered and b'Type UNINSTALL' in output:
                    os.write(master, answer.encode() + b'\n')
                    answered = True
            if child.poll() is not None:
                break
        code = child.wait(timeout=5)
        expected = b'DearMachine uninstalled.' if answer == 'UNINSTALL' else b'Uninstall cancelled'
        valid = code == 0 and answered and expected in output
        if busy:
            valid = code != 0 and not answered and b'installation is busy' in output
        if not valid:
            raise AssertionError(output.decode(errors='replace'))
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--download', required=True, type=Path)
    parser.add_argument('--image', required=True, help='Already-cached Debian image with curl, tar, gzip, useradd, and /bin/sh')
    args = parser.parse_args()
    root = args.download.resolve()
    for name in ('install', 'manifest.json', 'runtime.tar.gz'):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'expected a regular download artifact: {name}')
    manifest = json.loads((root / 'manifest.json').read_text())
    with (root / 'runtime.tar.gz').open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['archive_sha256']:
            raise ValueError('download checksum differs from its manifest')
    # Read one literal assignment; never execute a script on the host to get it.
    assignments = [line.removeprefix('base_url=') for line in (root / 'install').read_text().splitlines()
                   if line.startswith('base_url=')]
    if len(assignments) != 1 or len(shlex.split(assignments[0])) != 1:
        raise ValueError('expected one literal bootstrap base URL')
    base_url = shlex.split(assignments[0])[0]
    url = urlsplit(base_url)
    if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port
            or url.username or url.password or url.path or url.query or url.fragment):
        raise ValueError('this test requires an artifact server on literal loopback HTTP')
    # Resolve locally and run by immutable ID: docker must not pull an image.
    image = run('docker', 'image', 'inspect', '--format', '{{.Id}}', args.image,
                capture_output=True).stdout.strip()
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ('/install', '/manifest.json', '/runtime.tar.gz'):
                self.send_error(404)
                return
            requests.append(self.path)
            super().do_GET()

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', url.port), functools.partial(Handler, directory=str(root)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    container = None
    try:
        container = run('docker', 'run', '--detach', '--network', 'host', '--entrypoint', '/bin/sh', image,
                        '-c', 'exec sleep infinity', capture_output=True).stdout.strip()
        run('docker', 'exec', container, 'sh', '-eu', '-c',
            'test ! -e /nix; useradd --create-home --uid 1000 --shell /bin/bash installer')
        execute = ['docker', 'exec', '--user', 'installer', '--env', 'HOME=/home/installer', container]
        print('Testing the real curl bootstrap in a fresh container without /nix.', flush=True)
        run(*execute, 'bash', '-o', 'pipefail', '-c', f'curl -fsSL {shlex.quote(base_url + "/install")} | sh')
        run('docker', 'cp', str(Path(__file__).with_name('standard-runtime-smoke.py')),
            container + ':/opt/standard-runtime-smoke.py')
        run('docker', 'cp', str(Path(__file__).with_name('standard-agent-smoke.mjs')),
            container + ':/opt/standard-agent-smoke.mjs')
        run(*execute, 'sh', '-eu', '-c',
            'release=$(dirname "$(dirname "$(readlink "$HOME/.local/bin/dearmachine")")"); '
            '"$release/bin/python3" /opt/standard-runtime-smoke.py "$release"')
        if requests.count('/runtime.tar.gz') != 1:
            raise AssertionError('expected exactly one archive download')
        run('docker', 'cp', str(root / 'install'), container + ':/opt/standard-install.sh')
        server.shutdown()
        server.server_close()
        print('Repeating bootstrap with the server stopped to prove verified-cache reuse.', flush=True)
        run(*execute, 'sh', '/opt/standard-install.sh', timeout=60)
        # The verifier is this host process and the container's base shell,
        # so removal of every bundled runtime cannot erase its own evidence.
        run(*execute, 'sh', '-eu', '-c',
            'mkdir -p "$HOME/.dearmachine" "$HOME/.config/dearmachine" "$HOME/.config/machtiani"; '
            'chmod 700 "$HOME/.dearmachine"; '
            'printf fake-private-data > "$HOME/.config/dearmachine/fixture"; '
            'printf independent > "$HOME/.config/machtiani/keep"')
        run('docker', 'exec', '-d', '--user', 'installer', '--env', 'HOME=/home/installer', container,
            '/home/installer/.local/bin/dearmachine', '_supervise', '--state-dir', '/home/installer/.dearmachine',
            '--', '/bin/sleep', '600')
        run(*execute, 'sh', '-eu', '-c',
            'i=0; while ! test -S "$HOME/.dearmachine/run/supervisor.sock"; do '
            'i=$((i+1)); test "$i" -lt 100; sleep .1; done')
        uninstall_terminal(container, 'no')
        run(*execute, 'sh', '-eu', '-c',
            'test -S "$HOME/.dearmachine/run/supervisor.sock"; '
            'test -f "$HOME/.config/dearmachine/fixture"')
        uninstall_terminal(container, 'UNINSTALL')
        verify_removed = (
            'test ! -e "$HOME/.dearmachine"; test ! -e "$HOME/.config/dearmachine"; '
            'test ! -e "$HOME/.local/share/dearmachine"; '
            'for name in dearmachine agent-manager machtiani machtiani-installer machtiani-model-host; do '
            'test ! -e "$HOME/.local/bin/$name"; test ! -L "$HOME/.local/bin/$name"; done; '
            'test "$(cat "$HOME/.config/machtiani/keep")" = independent; test ! -e /nix')
        run(*execute, 'sh', '-eu', '-c', verify_removed)
        # Uninstall also removes downloads. Serve the same pinned artifacts
        # again and prove a real fresh bootstrap succeeds without old state.
        server = http.server.ThreadingHTTPServer(('127.0.0.1', url.port), functools.partial(Handler, directory=str(root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        run(*execute, 'sh', '/opt/standard-install.sh', timeout=300)
        run(*execute, 'sh', '-eu', '-c',
            'test ! -e "$HOME/.dearmachine"; test ! -e "$HOME/.config/dearmachine/fixture"; '
            '"$HOME/.local/bin/dearmachine" --help >/dev/null')
        uninstall_terminal(container, 'UNINSTALL')
        run(*execute, 'sh', '-eu', '-c', verify_removed)
        print('NO_NIX_CURL_OK: acquisition, runtime, cache reuse, confirmed running uninstall, fresh reinstall, full removal', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        if container:
            run('docker', 'rm', '--force', container, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
