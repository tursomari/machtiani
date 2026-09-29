#!/usr/bin/env python3
"""Run offline uninstall acceptance with copied candidate runtimes in tmpfs.

No host mounts, credentials, Git metadata, network, or product installation
is exposed to deletion. Only the systemd variant relaxes AppArmor and adds
SYS_ADMIN, to remount its private cgroup namespace writable.
"""
import argparse
from pathlib import Path
import subprocess
import time
import uuid


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--installer', required=True, type=Path)
    parser.add_argument('--python', required=True, type=Path)
    parser.add_argument('--image', default='debian:bookworm-slim', help='Cached image; resolved to immutable ID, never pulled')
    parser.add_argument('--systemd', action='store_true', help='Boot real systemd with private writable cgroups')
    args = parser.parse_args()
    binaries = [p.resolve() for p in (args.native, args.installer, args.python)]
    roots = set()
    for binary in binaries:
        if binary.parts[:3] != ('/', 'nix', 'store') or not binary.is_file():
            parser.error('supply exact candidate executables from existing Nix outputs')
        roots.add(str(Path('/nix/store') / binary.parts[3]))
    base = output('docker', 'image', 'inspect', '--format', '{{.Id}}', args.image)
    closure = sorted(set(output('nix-store', '--query', '--requisites', *sorted(roots)).splitlines()))
    # Bound runtime storage using NAR sizes, allowing tar/block overhead.
    nar_bytes = sum(int(output('nix-store', '--query', '--size', path)) for path in closure)
    tmpfs_bytes = nar_bytes * 2 + 128 * 1024 * 1024
    native, installer, python = map(str, binaries)
    name = 'dearmachine-uninstall-test-' + uuid.uuid4().hex
    command = ['docker', 'create', '--name', name, '--network=none', '--user=root',
               '--tmpfs', f'/nix/store:rw,exec,size={tmpfs_bytes},mode=0755',
               '--tmpfs', '/run', '--tmpfs', '/run/lock',
               '--env', 'HOME=/home/tester', '--env', 'DEARMACHINE_UNINSTALL_CONTAINER=1',
               '--env', f'NATIVE={native}', '--env', f'INSTALLER={installer}', '--env', f'PYTHON={python}']
    if args.systemd:
        if output('docker', 'info', '--format', '{{.CgroupVersion}}') != '2':
            parser.error('the systemd gate requires cgroup v2')
        command += ['--cap-add=SYS_ADMIN', '--cgroupns=private']
        if 'apparmor' in output('docker', 'info', '--format', '{{json .SecurityOptions}}'):
            # docker-default denies mount even with SYS_ADMIN. Only this
            # disposable offline container gets the exception; seccomp stays on.
            command += ['--security-opt', 'apparmor=unconfined']
        boot = ('test "$(cat /proc/1/cgroup)" = "0::/"; '
                'mount -o remount,rw /sys/fs/cgroup; exec /lib/systemd/systemd')
    else:
        command += ['--cap-drop=ALL']
        boot = 'exec sleep infinity'
    command += ['--entrypoint', '/bin/sh', base, '-ec', boot]
    container = None
    try:
        container = output(*command)
        print(f'Cached base: {base}; runtime tmpfs limit: {tmpfs_bytes} bytes', flush=True)
        run('docker', 'start', container)
        if args.systemd:
            for _ in range(100):
                if subprocess.run(['docker', 'exec', container, 'systemctl', 'is-active', '--quiet', 'dbus'],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    break
                if output('docker', 'inspect', '--format', '{{.State.Running}}', container) != 'true':
                    raise RuntimeError('container-local systemd exited during startup')
                time.sleep(.1)
            else:
                raise RuntimeError('container-local systemd/dbus did not become ready')
            run('docker', 'exec', container, 'useradd', '--create-home', '--uid', '1000', 'tester')
        # Stream once into container memory, avoiding duplicate on-disk image layers.
        with subprocess.Popen(['tar', '--mode=u+rwX', '-C', '/nix/store', '-cf', '-',
                               *[Path(p).name for p in closure]], stdout=subprocess.PIPE) as archive:
            try:
                subprocess.run(['docker', 'exec', '-i', container, 'tar', '--no-same-owner', '-xf', '-', '-C', '/nix/store'],
                               stdin=archive.stdout, check=True)
            finally:
                archive.stdout.close()
            if archive.wait() != 0:
                raise RuntimeError('runtime closure archive failed')
        subprocess.run(['docker', 'exec', '-i', container, '/bin/sh', '-ec',
                        'cat > /run/uninstall-test.py; chmod 0644 /run/uninstall-test.py'],
                       input=Path(__file__).with_name('container.py').read_bytes(), check=True)
        test = ['docker', 'exec', '--user=1000:1000', '--env', 'HOME=/home/tester']
        if args.systemd:
            run('docker', 'exec', container, 'loginctl', 'enable-linger', 'tester')
            run('docker', 'exec', container, 'systemctl', 'start', 'user@1000.service')
            test += ['--env', 'XDG_RUNTIME_DIR=/run/user/1000',
                     '--env', 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus',
                     '--env', 'DEARMACHINE_TEST_SYSTEMD=1']
        test += [container, python, '/run/uninstall-test.py']
        if args.systemd:
            test.append('Uninstall.test_systemd_service')
        run(*test)
    finally:
        if container:
            subprocess.run(['docker', 'logs', container], check=False)
            run('docker', 'rm', '--force', container)


if __name__ == '__main__':
    main()
