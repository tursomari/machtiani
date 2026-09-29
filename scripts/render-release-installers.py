#!/usr/bin/env python3
"""Render install.sh and install.ps1 for one GitHub release.

The rendered scripts verify the release's SHA256SUMS attestation with
`gh attestation verify`, pinned to the repository, release workflow, and source
ref given here, before checking and installing any archive.
"""
import argparse
from pathlib import Path
import re
import shlex
from urllib.parse import urlsplit

WORKFLOW = '.github/workflows/release.yml'


def validate(repository, tag, source_ref, download_url):
    if not re.fullmatch(r'[A-Za-z0-9-]+/[A-Za-z0-9._-]+', repository):
        raise ValueError('repository must be <owner>/<name>')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?', tag):
        raise ValueError('release tag must look like v1.2.3 or v1.2.3-rc.1')
    if not re.fullmatch(r'refs/(tags|heads)/[A-Za-z0-9._/-]+', source_ref) or '..' in source_ref:
        raise ValueError('source ref must be a refs/tags/ or refs/heads/ name')
    url = urlsplit(download_url)
    if (url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password
            or url.query or url.fragment or (url.scheme == 'http' and url.hostname != '127.0.0.1')):
        raise ValueError('download URL must use HTTPS, or HTTP on 127.0.0.1 for local testing')


def powershell_quote(value):
    return "'" + value.replace("'", "''") + "'"


def render(repository, tag, source_ref, download_url=None):
    download_url = (download_url or f'https://github.com/{repository}/releases/download/{tag}').rstrip('/')
    validate(repository, tag, source_ref, download_url)
    values = dict(REPOSITORY=repository, TAG=tag, SOURCE_REF=source_ref,
                  SIGNER_WORKFLOW=f'{repository}/{WORKFLOW}', DOWNLOAD_URL=download_url)
    scripts = {}
    for name, template, quote in (('install.sh', 'release-install.sh', shlex.quote),
                                  ('install.ps1', 'release-install.ps1', powershell_quote)):
        text = Path(__file__).with_name(template).read_text()
        for key, value in values.items():
            text = text.replace('@' + key + '@', quote(value))
        if re.search(r'@[A-Z_]+@', text):
            raise ValueError(f'{template} has an unrendered placeholder')
        scripts[name] = text
    return scripts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True, help='GitHub <owner>/<name> that publishes the release')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source-ref', required=True, help='Ref the release workflow ran on, such as refs/tags/v1.2.3')
    parser.add_argument('--download-url', help='Override the release download URL (local testing only)')
    parser.add_argument('--output', required=True, type=Path, help='Existing directory for the rendered scripts')
    args = parser.parse_args()
    for name, text in render(args.repository, args.tag, args.source_ref, args.download_url).items():
        path = args.output / name
        if path.exists():
            raise ValueError(f'refusing to overwrite {path}')
        path.write_text(text)
        path.chmod(0o644)
        print(path)


if __name__ == '__main__':
    main()
