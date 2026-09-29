#!/usr/bin/env bash
# Sourced by run.sh. All files are copied into the disposable container; no
# image build, image commit, bind mount, or host HTTP listener is necessary.

ixe_curl_validate() {
  python3 - "$curl_bundle" "$repo_root" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlsplit

bundle, root = map(Path, sys.argv[1:])
manifest = json.loads((bundle / 'manifest.json').read_text())
revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
if manifest.get('version') != 1 or manifest['revisions']['.'] != revision:
    raise SystemExit('Curl bundle must match this committed umbrella revision')
url = urlsplit(manifest['base_url'])
if url.scheme != 'http' or url.hostname != '127.0.0.1' or not url.port or url.username or url.password or url.path or url.query or url.fragment:
    raise SystemExit('Curl IXE server must use container loopback HTTP')
for name, key in [('install', 'install_sha256'), ('source.tar.gz', 'source_sha256'), ('closure.nar.gz', 'closure_sha256')]:
    path = bundle / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f'Invalid bundle artifact: {name}')
    with path.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != manifest[key]:
            raise SystemExit(f'Curl bundle checksum mismatch: {name}')
PY
}

ixe_curl_seed() {
  docker exec "$container_id" install -d -m 0755 /run/ixe/distribution
  for artifact in install manifest.json source.tar.gz closure.nar.gz; do
    docker cp "$curl_bundle/$artifact" "$container_id:/run/ixe/distribution/$artifact"
  done
  docker cp "$script_dir/curl-server.py" "$container_id:/usr/local/libexec/ixe-curl-server.py"
  docker cp "$script_dir/agents/curl-launch.sh" "$container_id:/usr/local/libexec/ixe-agent-launch"
  # Warm Nix as root, not the user's profile/home. This previews the already-
  # cached branch without weakening the daemon's package-signature policy.
  docker exec "$container_id" bash -euo pipefail -c '
    chmod 0644 /run/ixe/distribution/* /usr/local/libexec/ixe-curl-server.py
    chmod 0755 /usr/local/libexec/ixe-agent-launch
    # The sparse SSH PATH omits these tools although the Nix base image has
    # them. Expose their resolved store paths, not root-private profile paths.
    for tool in nix-store gzip tar; do
      ln -sfn "$(readlink -f "$(command -v "$tool")")" "/usr/local/bin/$tool"
    done
    gzip -dc /run/ixe/distribution/closure.nar.gz | nix-store --import >/dev/null
    touch /run/ixe/curl-mode
    chmod 0644 /run/ixe/curl-mode
  '
}

ixe_curl_start_server() {
  curl_base_url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_url"])' "$curl_bundle/manifest.json")
  curl_port=${curl_base_url##*:}
  docker exec --detach --user installer "$container_id" python3 /usr/local/libexec/ixe-curl-server.py \
    --directory /run/ixe/distribution --port "$curl_port"
  for attempt in $(seq 1 30); do
    docker exec --user installer "$container_id" curl -fsS --output /dev/null "$curl_base_url/manifest.json" 2>/dev/null && break
    test "$attempt" -lt 30 || fail 'curl artifact server did not become ready'
    sleep 1
  done
  docker exec "$container_id" sh -c 'printf "%s\n" "Curl installation IXE (Nix and runtime cache already present)." "Run: curl -fsSL $1/install | sh" "Then run: dearmachine" > /etc/motd' sh "$curl_base_url"
  cp "$curl_bundle/manifest.json" "$artifact_dir/curl-manifest.json"
}
