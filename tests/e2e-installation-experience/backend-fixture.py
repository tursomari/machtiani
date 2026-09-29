"""Prepare and verify a backend fixture inside a new disposable IXE container."""
import os
from pathlib import Path
import subprocess
import sys


def prepare(root, mode):
    if mode not in ('forge', 'none'):
        raise ValueError('backend fixture must be forge or none')
    runtime = root / 'run/ixe'
    runtime.mkdir(parents=True, exist_ok=True)
    if mode == 'none':
        # Only the IXE-owned cached fixture is moved. Never alter an image,
        # host binary, Nix closure, or an unrelated executable discovered later.
        forge = root / 'usr/local/bin/forge'
        if forge.exists() or forge.is_symlink():
            if forge.is_symlink() or not forge.is_file():
                raise ValueError('expected the regular IXE Forge fixture')
            private = runtime / 'disabled-backends'
            private.mkdir(mode=0o700, exist_ok=True)
            private.chmod(0o700)
            saved = private / 'forge'
            if saved.exists() or saved.is_symlink():
                raise ValueError('refusing to overwrite a retained backend fixture')
            forge.rename(saved)
    marker = runtime / 'backend-fixture'
    marker.write_text(mode + '\n')
    marker.chmod(0o644)


def verify(mode):
    # Match the SSH/installer PATH, not root's development/conductor PATH.
    path = '/usr/local/bin:/nix/var/nix/profiles/ixe/bin:/home/installer/.local/bin:/home/installer/.nix-profile/bin'
    if Path('/run/ixe/standard-mode').exists():
        path = '/usr/local/bin:/home/installer/.local/bin:/usr/bin:/bin'
    script = ('test "$(command -v forge)" = /usr/local/bin/forge; '
              'test "$(forge --version)" = "forge 2.13.21"') if mode == 'forge' else '''
for candidate in codex forge omp; do
  if command -v "$candidate" >/dev/null 2>&1; then
    printf 'Unexpected supported backend on installer PATH: %s\n' "$candidate" >&2
    exit 1
  fi
done
test ! -x /run/ixe/disabled-backends/forge
'''
    subprocess.run(['setpriv', '--reuid=1000', '--regid=1000', '--clear-groups',
                    '/bin/bash', '-eu', '-c', script], check=True,
                   env={**os.environ, 'HOME': '/home/installer', 'PATH': path})


if __name__ == '__main__':
    if os.getuid() != 0 or len(sys.argv) != 2:
        raise SystemExit('run as root inside the disposable IXE container with forge or none')
    prepare(Path('/'), sys.argv[1])
    verify(sys.argv[1])
