#!/usr/bin/env python3
"""Guest-side acquisition exercise. Stops before provider authentication.

The VM runner owns isolation. Runtime assertions are delegated to the existing
shared smoke gate; live installation remains the IXE/QSE's responsibility.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time


def exercise(source, evidence):
    assert not Path('/nix').exists(), 'the guest must not contain Nix'
    evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (evidence / 'bootstrap.log').open('wb') as log:
        receipt = subprocess.check_output(['python3', str(source / 'scripts/container-build.py'),
            '--source-root', str(source), '--bootstrap', '--json'], stderr=log, timeout=3600)
    launcher = json.loads(receipt)['launcher']
    pid, terminal = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm-256color'
        os.execv(launcher, [launcher, '--install', '--source-root', str(source)])
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    stages = ['Welcome to Dear Machine', 'Would you like to see the shell commands',
              'How would you like to install Dear Machine?', 'First, choose the AI service']
    stage = 0
    output = ''
    reached_provider = False
    deadline = time.monotonic() + 3600
    try:
        with (evidence / 'wizard.ansi').open('wb') as transcript:
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 1)[0]:
                    try:
                        data = os.read(terminal, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    transcript.write(data)
                    transcript.flush()
                    output = (output + data.decode(errors='replace'))[-262144:]
                    if stage < len(stages) and stages[stage] in output:
                        if stage == 3:
                            reached_provider = True
                            os.write(terminal, b'/quit\r')
                            break
                        if stage == 2:
                            assert 'Standard' in output and 'Nix' in output
                        # Continue; keep commands brief; default Standard.
                        os.write(terminal, b'\r')
                        stage += 1
                        output = ''
            assert reached_provider, 'wizard did not complete the real Docker build; inspect guest evidence'
    finally:
        os.close(terminal)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
    installed = Path.home() / '.local/bin/dearmachine'
    release = installed.resolve().parents[1]
    manifest = json.loads((release / 'distribution.json').read_text())
    assert manifest['method'] == 'standard'
    assert not (Path.home() / '.dearmachine').exists(), 'acquisition must not start/configure a daemon'
    with (evidence / 'runtime-smoke.log').open('wb') as log:
        subprocess.run([str(release / 'bin/python3'), str(source / 'tests/standard-runtime-smoke.py'), str(release)],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    (evidence / 'result.json').write_text(json.dumps({'status': 'ok', 'method': 'standard',
        'wizardBuild': True, 'providerAuthenticated': False, 'runtimeSmoke': True}) + '\n')
    print('CONTAINER_BUILD_VM_OK: bootstrap, wizard build, installed runtime; no provider credentials')


if __name__ == '__main__':
    exercise(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
