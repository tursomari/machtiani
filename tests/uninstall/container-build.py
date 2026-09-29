#!/usr/bin/env python3
"""Prove uninstall of a production Docker-built runtime in an offline container.

Uses cached images only. No host mounts, credentials, Git or Docker socket enter
the test container; the verifier and its shell survive runtime self-removal.
"""
import argparse
import importlib.util
from pathlib import Path
import subprocess


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-image', required=True, help='Cached production release image, before relocation')
    parser.add_argument('--image', default='debian:bookworm-slim', help='Cached base image with useradd and a POSIX shell')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('curl_smoke', root / 'tests/standard-curl-smoke.py')
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    images = [run('docker', 'image', 'inspect', '--format', '{{.Id}}', name,
                  capture_output=True).stdout.strip() for name in (args.runtime_image, args.image)]
    print('Testing runtime/base images:', *images, flush=True)
    containers = []
    home = '/home/installer'
    release = home + '/.local/share/dearmachine/container-releases/fixture'
    try:
        source = run('docker', 'create', images[0], '/bin/true', capture_output=True).stdout.strip()
        containers.append(source)
        target = run('docker', 'run', '--detach', '--network=none', images[1],
                     'sleep', 'infinity', capture_output=True).stdout.strip()
        containers.append(target)
        run('docker', 'exec', target, 'sh', '-eu', '-c',
            'test ! -e /nix; useradd --create-home --uid 1000 installer; mkdir -p ' + release)
        copy = subprocess.Popen(['docker', 'cp', source + ':/release/.', '-'], stdout=subprocess.PIPE)
        try:
            run('docker', 'exec', '-i', target, 'tar', '-xf', '-', '-C', release, stdin=copy.stdout)
        finally:
            copy.stdout.close()
            if copy.wait() != 0:
                raise RuntimeError('Could not copy raw runtime')
        run('docker', 'cp', root / 'scripts/container-build.py', target + ':/tmp/builder.py')
        run('docker', 'exec', target, 'chown', '-R', '1000:1000', home)
        execute = ['docker', 'exec', '--user', 'installer', '--env', 'HOME=' + home, target]
        run(*execute, 'sh', release + '/bootstrap-runtime.sh')
        # Invoke production activation with a source-snapshot/build fixture:
        # acquisition itself was proved by the production image build. Here the
        # source identity is fixed and the existing relocated payload is reused.
        activate = (
            'import runpy,pathlib; b=runpy.run_path("/tmp/builder.py"); '
            'b["acquire_locked"].__globals__["snapshot"]=lambda *args: None; '
            'b["acquire_locked"].__globals__["fingerprint"]=lambda *args: "fixture"; '
            'home=pathlib.Path.home(); '
            '(home/".local/share/dearmachine/container-releases/fixture/.complete").write_text("fixture"); '
            'b["acquire"](pathlib.Path("/unused"),home,home/".local/share")')
        run(*execute, release + '/bin/python3', '-c', activate)
        run(*execute, 'sh', '-eu', '-c',
            'mkdir -p "$HOME/.dearmachine" "$HOME/.config/dearmachine" "$HOME/.config/machtiani"; '
            'chmod 700 "$HOME/.dearmachine"; '
            'printf disposable > "$HOME/.config/dearmachine/fixture"; '
            'printf independent > "$HOME/.config/machtiani/keep"')
        run('docker', 'exec', '-d', '--user', 'installer', '--env', 'HOME=' + home, target,
            home + '/.local/bin/dearmachine', '_supervise', '--state-dir', home + '/.dearmachine',
            '--', '/bin/sleep', '600')
        run(*execute, 'sh', '-eu', '-c',
            'i=0; while ! test -S "$HOME/.dearmachine/run/supervisor.sock"; do '
            'i=$((i+1)); test "$i" -lt 100; sleep .1; done')
        # A real concurrent process holds the production builder's shared lock.
        hold = ('import runpy,pathlib,time; b=runpy.run_path("/tmp/builder.py"); '
                'home=pathlib.Path.home(); '\
                '\nwith b["acquisition_lock"](home,home/".local/share"):\n'
                ' pathlib.Path("/tmp/build-ready").touch()\n'
                ' while not pathlib.Path("/tmp/build-release").exists(): time.sleep(.05)\n'
                'pathlib.Path("/tmp/build-done").touch()\n')
        run('docker', 'exec', '-d', '--user', 'installer', '--env', 'HOME=' + home, target,
            release + '/bin/python3', '-c', hold)
        run(*execute, 'sh', '-eu', '-c',
            'i=0; while ! test -f /tmp/build-ready; do i=$((i+1)); test "$i" -lt 100; sleep .1; done')
        smoke.uninstall_terminal(target, 'UNINSTALL', busy=True)
        run(*execute, 'sh', '-eu', '-c',
            'test -S "$HOME/.dearmachine/run/supervisor.sock"; '
            'test -f "$HOME/.config/dearmachine/fixture"; touch /tmp/build-release; '
            'i=0; while ! test -f /tmp/build-done; do i=$((i+1)); test "$i" -lt 100; sleep .1; done')
        smoke.uninstall_terminal(target, 'no')
        run(*execute, 'sh', '-eu', '-c',
            'test -S "$HOME/.dearmachine/run/supervisor.sock"; test -f "$HOME/.config/dearmachine/fixture"')
        smoke.uninstall_terminal(target, 'UNINSTALL')
        run(*execute, 'sh', '-eu', '-c',
            'test ! -e "$HOME/.dearmachine"; test ! -e "$HOME/.config/dearmachine"; '
            'test ! -e "$HOME/.local/share/dearmachine"; '
            'for name in dearmachine agent-manager machtiani machtiani-installer machtiani-model-host; do '
            'test ! -e "$HOME/.local/bin/$name"; test ! -L "$HOME/.local/bin/$name"; done; '
            'test "$(cat "$HOME/.config/machtiani/keep")" = independent; test ! -e /nix')
        print('CONTAINER_BUILD_UNINSTALL_OK: active-build refusal, cancellation, shutdown, software/private-data removal', flush=True)
    finally:
        for container in reversed(containers):
            subprocess.run(['docker', 'rm', '--force', container], check=False, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
