#!/usr/bin/env bash
# Standard specialization of the existing IXE curl hooks. No Nix import.
ixe_curl_validate() {
  if test "$backend_fixture" = forge; then
    test -n "$forge_binary" && test -f "$forge_binary" || fail '--forge-binary must supply the existing pinned Forge fixture'
    test "$(sha256sum "$forge_binary" | cut -d ' ' -f 1)" = 4ae6d86cdd001e649e1b435d99243d7249d169e30b24529e350f9dfec798f29a || \
      fail 'Forge fixture does not match the reviewed Linux x86-64 binary'
  fi
  python3 - "$curl_bundle" "$installer_source_root" "$repo_root" <<'PY'
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
from urllib.parse import urlsplit

bundle = Path(sys.argv[1])
for name in ('install', 'manifest.json', 'runtime.tar.gz'):
    path = bundle / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit('Standard download artifacts must be regular files')
manifest = json.loads((bundle / 'manifest.json').read_text())
if manifest.get('version') != 1 or manifest.get('system') != 'x86_64-linux':
    raise SystemExit('Expected a Linux x86-64 Standard download')
with (bundle / 'runtime.tar.gz').open('rb') as stream:
    if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest['archive_sha256']:
        raise SystemExit('Standard runtime checksum mismatch')
assignments = {}
for line in (bundle / 'install').read_text().splitlines():
    key, separator, value = line.partition('=')
    if separator and key in ('base_url', 'archive_sha', 'release_id'):
        parsed = shlex.split(value)
        if key in assignments or len(parsed) != 1:
            raise SystemExit('Malformed bootstrap assignment')
        assignments[key] = parsed[0]
url = urlsplit(assignments['base_url'])
if (url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port
        or url.username or url.password or url.path or url.query or url.fragment):
    raise SystemExit('Standard IXE must serve artifacts on container loopback')
if assignments['archive_sha'] != manifest['archive_sha256'] or assignments['release_id'] != manifest['release']:
    raise SystemExit('Bootstrap does not match the runtime manifest')
# Documentation/test-only follow-ups can reuse the verified package. Never
# reuse an older installer when its runtime source has changed.
subprocess.run(['git', '-C', sys.argv[2], 'diff', '--exit-code',
    manifest['revisions']['dearmachine-concierge'], 'HEAD', '--', 'packages/*/src',
    'package.json', 'pnpm-lock.yaml', 'flake.nix'], check=True, stdout=subprocess.DEVNULL)
# The agent consumes the downloaded guidance, not the runner's checkout.
# A newer harness must not silently exercise an older conversation contract.
if subprocess.run(['git', '-C', sys.argv[3], 'diff', '--quiet',
    manifest['revisions']['.'], 'HEAD', '--', 'INSTALL.md', 'docs/']).returncode != 0:
    raise SystemExit('Standard download contains stale installer guidance; repackage cached binaries with current source')
print('Using tested Standard release ' + manifest['release'])
PY
}

ixe_curl_seed() {
  docker exec "$container_id" sh -eu -c 'test -f /run/ixe/standard-mode; test ! -e /nix; install -d -m 0755 /run/ixe/distribution'
  for artifact in install manifest.json runtime.tar.gz; do
    docker cp "$curl_bundle/$artifact" "$container_id:/run/ixe/distribution/$artifact"
  done
  if test "$backend_fixture" = forge; then
    docker cp "$forge_binary" "$container_id:/usr/local/bin/forge"
    docker exec "$container_id" chmod 0755 /usr/local/bin/forge
  fi
  docker cp "$script_dir/curl-server.py" "$container_id:/usr/local/libexec/ixe-curl-server.py"
  docker cp "$script_dir/agents/curl-launch.sh" "$container_id:/usr/local/libexec/ixe-agent-launch"
  docker exec "$container_id" sh -eu -c '
    chmod 0644 /run/ixe/distribution/* /usr/local/libexec/ixe-curl-server.py /usr/local/libexec/ixe-standard-source.py
    chmod 0755 /usr/local/libexec/ixe-agent-launch
    touch /run/ixe/curl-mode
    chmod 0644 /run/ixe/curl-mode
  '
}

ixe_curl_start_server() {
  curl_base_url=$(python3 - "$curl_bundle/install" <<'PY'
from pathlib import Path
import shlex
import sys
print(next(shlex.split(line.partition('=')[2])[0] for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith('base_url=')))
PY
)
  curl_port=${curl_base_url##*:}
  docker exec --detach --user installer "$container_id" python3 /usr/local/libexec/ixe-curl-server.py \
    --directory /run/ixe/distribution --port "$curl_port"
  for attempt in $(seq 1 30); do
    docker exec --user installer "$container_id" curl -fsS --output /dev/null "$curl_base_url/manifest.json" 2>/dev/null && break
    test "$attempt" -lt 30 || fail 'Standard artifact server did not become ready'
    sleep 1
  done
  docker exec "$container_id" sh -c 'printf "%s\n" "Standard installation IXE: this container has no Nix." "Run: curl -fsSL $1/install | sh" "Then: dearmachine" "Choose Standard installation for this preview; the Nix alternative is not ready." > /etc/motd' sh "$curl_base_url"
  cp "$curl_bundle/manifest.json" "$artifact_dir/curl-manifest.json"
}
