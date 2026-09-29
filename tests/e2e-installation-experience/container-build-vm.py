#!/usr/bin/env python3
"""Provision an isolated Linux VM for the existing installer's Docker acquisition.

Requires an existing checksum-verified Ubuntu 24.04 amd64 cloud image, QEMU/KVM,
qemu-img, genisoimage, SSH and Python. No host filesystem or socket is shared.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('container_build', ROOT / 'scripts/container-build.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def qemu_arguments(disk, seed, port, memory, cpus):
    if not 2048 <= memory <= 32768 or not 1 <= cpus <= 16:
        raise ValueError('Choose 2048–32768 MiB RAM and 1–16 virtual CPUs')
    return ['qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-smp', str(cpus),
            '-m', str(memory), '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
            '-drive', 'file=' + str(disk) + ',format=qcow2,if=virtio',
            '-drive', 'file=' + str(seed) + ',format=raw,media=cdrom,readonly=on',
            '-netdev', 'user,id=network,hostfwd=tcp:127.0.0.1:' + str(port) + '-:22',
            '-device', 'virtio-net-pci,netdev=network', '-no-reboot']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-image', required=True, type=Path)
    parser.add_argument('--base-sha256', required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--installer-root', type=Path)
    parser.add_argument('--artifacts', required=True, type=Path)
    parser.add_argument('--memory-mib', type=int, default=6144)
    parser.add_argument('--cpus', type=int, default=4)
    args = parser.parse_args()
    for tool in ('qemu-system-x86_64', 'qemu-img', 'genisoimage', 'ssh', 'ssh-keygen', 'scp'):
        if not shutil.which(tool):
            raise ValueError('Missing VM prerequisite: ' + tool)
    with open('/dev/kvm', 'rb+') as device:
        if fcntl.ioctl(device.fileno(), 0xAE00, 0) != 12:
            raise ValueError('KVM is unavailable')
    base = args.base_image.resolve()
    digest = hashlib.sha256()
    with base.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != args.base_sha256:
        raise ValueError('Cloud image checksum mismatch')
    artifacts = args.artifacts.resolve()
    if artifacts.exists():
        raise ValueError('Artifacts must be a new directory')
    artifacts.mkdir(parents=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='dearmachine-vm-', dir=artifacts.parent) as directory:
        work = Path(directory)
        run('ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', work / 'key')
        public = (work / 'key.pub').read_text().strip()
        seed = work / 'seed.iso'
        userdata = {'users': [{'name': 'installer', 'shell': '/bin/bash', 'groups': ['docker'],
                    'sudo': ['ALL=(ALL) NOPASSWD:ALL'], 'lock_passwd': True,
                    'ssh_authorized_keys': [public]}], 'groups': ['docker'],
                    'ssh_pwauth': False, 'package_update': True,
                    'packages': ['docker.io', 'docker-buildx', 'git', 'python3'],
                    'runcmd': [['systemctl', 'enable', '--now', 'docker']]}
        (work / 'user-data').write_text('#cloud-config\n' + json.dumps(userdata))
        (work / 'meta-data').write_text(json.dumps({'instance-id': str(uuid.uuid4()), 'local-hostname': 'dearmachine-build-test'}))
        run('genisoimage', '-quiet', '-output', seed, '-volid', 'cidata', '-joliet', '-rock',
            work / 'user-data', work / 'meta-data')
        disk = work / 'guest.qcow2'
        run('qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'qcow2', '-b', base, disk, '48G')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        source = work / 'source'
        builder.snapshot(args.source_root.resolve(), source, args.installer_root.resolve() if args.installer_root else None)
        archive = work / 'source.tar'
        with tarfile.open(archive, 'w') as stream:
            stream.add(source, arcname='source')
        ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=accept-new',
               '-o', 'UserKnownHostsFile=' + str(work / 'known_hosts'), '-o', 'IdentitiesOnly=yes',
               '-i', str(work / 'key'), '-p', str(port), 'installer@127.0.0.1']
        with (artifacts / 'console.log').open('wb') as console:
            vm = subprocess.Popen(qemu_arguments(disk, seed, port, args.memory_mib, args.cpus),
                                  stdin=subprocess.DEVNULL, stdout=console, stderr=subprocess.STDOUT)
            connected = False
            try:
                deadline = time.monotonic() + 900
                while time.monotonic() < deadline:
                    if vm.poll() is not None:
                        raise ValueError('VM exited during startup; inspect console.log')
                    probe = subprocess.run([*ssh, 'test -f /var/lib/cloud/instance/boot-finished && docker info >/dev/null'],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if probe.returncode == 0:
                        connected = True
                        break
                    time.sleep(3)
                if not connected:
                    raise ValueError('VM initialization timed out; inspect console.log')
                with archive.open('rb') as stream:
                    run(*ssh, 'tar -xf -', stdin=stream)
                run(*ssh, 'python3 source/tests/e2e-installation-experience/container-build-guest.py source evidence')
            finally:
                if connected:
                    with (artifacts / 'guest-evidence.tar').open('wb') as stream:
                        subprocess.run([*ssh, 'tar -cf - evidence .local/state/machtiani-installer/container-build.log 2>/dev/null'], stdout=stream)
                vm.terminate()
                try:
                    vm.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    vm.kill()
                    vm.wait()
        (artifacts / 'result.json').write_text(json.dumps({'status': 'ok', 'baseSHA256': args.base_sha256,
            'cpus': args.cpus, 'memoryMiB': args.memory_mib}) + '\n')
        print('VM gate passed. Evidence: ' + str(artifacts))


if __name__ == '__main__':
    main()
