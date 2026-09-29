"""Print the Go -X flags that stamp `machtiani --version` for a snapshot build.

Source snapshots record each component's revision in
bootstrap-source-revisions.json, and their tracked working-tree state in
bootstrap-source-state.json when they were taken from a Git checkout. The
flags match the harness Nix flake: dev-<short revision>, the full harness
revision, and clean/dirty when the state is known.
"""
import json
import re
import sys
from pathlib import Path


def ldflags(source):
    source = Path(source)
    revisions = json.loads((source / 'bootstrap-source-revisions.json').read_text())
    commit = revisions.get('machtiani-harness', '')
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40,64}', commit):
        raise ValueError('bootstrap-source-revisions.json has no machtiani-harness revision')
    flags = ['-X main.Version=dev-' + commit[:7], '-X main.Commit=' + commit]
    state = source / 'bootstrap-source-state.json'
    if state.is_file():
        dirty = json.loads(state.read_text()).get('workingTree')
        if isinstance(dirty, bool):
            flags.append('-X main.Dirty=' + ('dirty' if dirty else 'clean'))
    return ' '.join(flags)


if __name__ == '__main__':
    print(ldflags(sys.argv[1] if len(sys.argv) > 1 else '.'))
