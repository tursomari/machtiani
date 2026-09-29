#!/usr/bin/env bash

IXE_AGENT_LABEL=Codex
IXE_AGENT_STATE_NAME=.codex
IXE_AGENT_LOGIN_COMMAND='codex login --device-auth'

ixe_agent_validate_host() {
  command -v codex >/dev/null 2>&1 || {
    printf 'Codex adapter requires codex on the host PATH\n' >&2
    return 1
  }
  IXE_CODEX_STATE_SOURCE=${CODEX_HOME:-$HOME/.codex}
  test -d "$IXE_CODEX_STATE_SOURCE" && test ! -L "$IXE_CODEX_STATE_SOURCE" || {
    printf 'Codex state must be a real directory: %s\n' "$IXE_CODEX_STATE_SOURCE" >&2
    return 1
  }
  IXE_CODEX_ENTRY=$(readlink -f "$(command -v codex)")
  IXE_CODEX_PACKAGE=$(CDPATH= cd -- "$(dirname -- "$IXE_CODEX_ENTRY")/.." && pwd -P)
  test -f "$IXE_CODEX_PACKAGE/package.json" || {
    printf 'Cannot resolve the host Codex package from %s\n' "$IXE_CODEX_ENTRY" >&2
    return 1
  }
  export IXE_CODEX_STATE_SOURCE IXE_CODEX_ENTRY IXE_CODEX_PACKAGE
}

ixe_agent_seed() {
  ixe_container_id=$1
  ixe_adapter_dir=$2

  docker exec "$ixe_container_id" mkdir -p \
    /home/installer/.codex /opt/ixe/agents/codex

  tar --ignore-failed-read --warning=no-file-changed \
    --exclude='./tmp' --exclude='./.tmp' \
    --exclude='./thread-writer-locks' --exclude='./mcp-oauth-locks' \
    --exclude='*.lock' --exclude='*.sock' --exclude='*-wal' --exclude='*-shm' \
    -C "$IXE_CODEX_STATE_SOURCE" -cf - . | \
    docker exec -i "$ixe_container_id" tar -xf - -C /home/installer/.codex

  tar -C "$IXE_CODEX_PACKAGE" -cf - . | \
    docker exec -i "$ixe_container_id" tar -xf - -C /opt/ixe/agents/codex

  docker cp "$ixe_adapter_dir/codex-launch.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-agent-launch"
  docker exec "$ixe_container_id" sh -eu -c '
    chmod 0755 /usr/local/libexec/ixe-agent-launch /opt/ixe/agents/codex/bin/codex.js
    ln -sf /opt/ixe/agents/codex/bin/codex.js /usr/local/bin/codex
  '
  unset ixe_container_id ixe_adapter_dir
}

ixe_agent_check_login() {
  ixe_container_id=$1
  docker exec --user installer \
    --env HOME=/home/installer --env CODEX_HOME=/home/installer/.codex \
    --env PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin \
    "$ixe_container_id" codex login status >/dev/null 2>&1
}

ixe_agent_collect() {
  ixe_container_id=$1
  ixe_artifact_dir=$2
  ixe_trajectory=$ixe_artifact_dir/codex-trajectory.tar

  if docker exec "$ixe_container_id" sh -eu -c '
      cd /home/installer/.codex
      test -d sessions
      find sessions -type f -newer /run/ixe/session-start -print -quit | grep -q .
    '; then
    docker exec "$ixe_container_id" sh -eu -c '
      cd /home/installer/.codex
      find sessions -type f -newer /run/ixe/session-start -print0 |
        tar --null --files-from=- -cf -
    ' > "$ixe_trajectory"
    chmod 0600 "$ixe_trajectory"
  else
    printf '%s\n' 'No new file-based Codex trajectory was found; use terminal.typescript.' \
      > "$ixe_artifact_dir/codex-trajectory.txt"
    chmod 0600 "$ixe_artifact_dir/codex-trajectory.txt"
  fi
  unset ixe_container_id ixe_artifact_dir ixe_trajectory
}
