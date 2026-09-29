#!/usr/bin/env python3
"""Fingerprint the release source without inventing Git history in the target."""
import hashlib
import os
from pathlib import Path
import sys


def fingerprint(root):
    root = Path(root)
    if not (root / 'bootstrap-source-revisions.json').is_file() or (root / '.git').exists():
        raise ValueError('expected a source-only Standard release')
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        metadata = path.lstat()
        digest.update(str(path.relative_to(root)).encode() + b'\0')
        digest.update(str(metadata.st_mode).encode() + b'\0')
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open('rb') as stream:
                digest.update(hashlib.file_digest(stream, 'sha256').digest())
        digest.update(b'\0')
    return digest.hexdigest()


if __name__ == '__main__':
    print(fingerprint(sys.argv[1]))
