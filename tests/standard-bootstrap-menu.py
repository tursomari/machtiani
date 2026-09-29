#!/usr/bin/env python3
"""Verify the real standalone bootstrap menu in a private, unconfigured HOME."""
import argparse
import fcntl
import os
from pathlib import Path
import pty
import platform
import re
import select
import signal
import shutil
import struct
import termios
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--source-root', required=True, type=Path)
    parser.add_argument('--evidence-directory', required=True, type=Path)
    parser.add_argument('--expected-host', choices=['linux', 'darwin', 'nixos'], default=platform.system().lower())
    parser.add_argument('--expect-nix-prerequisite', action='store_true')
    parser.add_argument('--check-back', action='store_true')
    parser.add_argument('--quick-start-method', choices=['nix', 'standard'])
    parser.add_argument('--timeout', type=int, default=90, help='Seconds allowed, including a real Standard build')
    args = parser.parse_args()
    evidence = args.evidence_directory.resolve()
    evidence.mkdir(mode=0o700, parents=True)
    home = evidence / 'home'
    home.mkdir(mode=0o700)
    # Darwin Unix sockets have a short path limit; evidence paths can be deep.
    state = tempfile.TemporaryDirectory(prefix="dm-menu-", dir="/tmp")
    pid, terminal = pty.fork()
    if pid == 0:
        env = dict(HOME=str(home), PATH='/usr/bin:/bin:/usr/sbin:/sbin', TERM='xterm-256color', LANG='en_US.UTF-8', TMPDIR='/tmp', XDG_STATE_HOME=state.name)
        if args.expected_host == 'nixos' or args.quick_start_method == 'nix': env['PATH'] = '/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:' + env['PATH']
        if args.quick_start_method == 'nix' and (nix := shutil.which('nix')):
            env['PATH'] = str(Path(nix).resolve().parent) + ':' + env['PATH']
        for name in ('NIX_CONFIG', 'NIX_USER_CONF_FILES', 'NIX_CONF_DIR'):
            if name in os.environ: env[name] = os.environ[name]
        route = ['quick-start', '--method', args.quick_start_method] if args.quick_start_method else ['--install']
        os.execve(str(args.launcher.resolve()), [str(args.launcher.resolve()), *route, '--source-root', str(args.source_root.resolve())], env)
    fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    next_screen = 'This installer requires Nix flakes' if args.expect_nix_prerequisite else 'First, choose the AI service' if args.expected_host == 'nixos' or args.quick_start_method else 'How would you like to install Dear Machine?'
    stages = ['Welcome to Dear Machine', 'Would you like to see the shell commands', next_screen]
    stage, output, verified = 0, '', False
    selected_method_seen, method_menu_seen = False, False
    deadline = time.monotonic() + args.timeout
    try:
        with (evidence / 'menu.ansi').open('wb') as log:
            os.chmod(log.name, 0o600)
            while time.monotonic() < deadline:
                if not select.select([terminal], [], [], 1)[0]:
                    continue
                try: data = os.read(terminal, 65536)
                except OSError: break
                if not data: break
                log.write(data); log.flush()
                output = (output + data.decode(errors='replace'))[-262144:]
                plain = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', output)
                # A first Standard build can outgrow the rolling terminal buffer.
                # Retain the route evidence while continuing to drain build progress.
                selected = 'Standard' if args.quick_start_method == 'standard' else 'Nix'
                selected_method_seen |= 'Installation method: ' + selected in plain
                method_menu_seen |= 'How would you like to install Dear Machine?' in plain
                if stages[stage] in plain:
                    if stage == 2:
                        assert 'Container build' not in plain
                        if args.expected_host == 'nixos' or args.quick_start_method:
                            assert selected_method_seen
                            assert not method_menu_seen
                            assert 'Build using Docker' not in plain
                        else:
                            if not re.search(r'→\s+Nix', plain) or 'Standard' not in plain: continue
                            assert 'Use Nix-managed packages (recommended). NixOS is not required.' in plain
                            expected = 'Build directly on this Mac.' if args.expected_host == 'darwin' else 'Build using Docker. Install and run directly on this computer.'
                            if expected not in plain: continue
                            assert ('Build using Docker' if args.expected_host == 'darwin' else 'Build directly on this Mac') not in plain
                        if args.check_back:
                            os.write(terminal, b'\x1b')
                            stages.append('Would you like to continue with the installation now?')
                            stage = 3
                            output = ''
                            continue
                        verified = True
                        break
                    if stage == 3:
                        verified = True
                        break
                    os.write(terminal, b'\r')
                    stage += 1
                    output = ''
        assert verified, 'Bootstrap did not reach the expected setup screen; inspect the private transcript'
        assert not (home / '.dearmachine').exists(), 'Menu verification must not start/configure DearMachine'
        assert not (home / '.config/machtiani/model-profile.json').exists(), 'Menu must precede model setup'
        print('INSTALLER_HOST_FLOW_OK: ' + args.expected_host + ('; prerequisite guidance' if args.expect_nix_prerequisite else '; no existing installation or credentials'), flush=True)
    finally:
        # Close before reaping: Darwin can wait for undrained PTY output on exit.
        os.close(terminal)
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
        for _ in range(50):
            if os.waitpid(pid, os.WNOHANG)[0]: break
            time.sleep(0.1)
        else:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        state.cleanup()

if __name__ == '__main__': main()
