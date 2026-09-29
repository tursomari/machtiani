#!/usr/bin/env bash

IXE_AGENT_LABEL=Forge
IXE_AGENT_STATE_NAME=.forge
IXE_AGENT_LOGIN_COMMAND='forge provider login open_router'

ixe_agent_validate_host() {
  test -n "${IXE_FORGE_OPENROUTER_KEY_FILE:-}" || {
    printf '%s\n' \
      'Forge adapter requires IXE_FORGE_OPENROUTER_KEY_FILE' >&2
    return 1
  }
  case "$IXE_FORGE_OPENROUTER_KEY_FILE" in
    /*) ;;
    *)
      printf '%s\n' \
        'IXE_FORGE_OPENROUTER_KEY_FILE must be an absolute path' >&2
      return 1
      ;;
  esac
  test -f "$IXE_FORGE_OPENROUTER_KEY_FILE" && \
    test ! -L "$IXE_FORGE_OPENROUTER_KEY_FILE" && \
    test -s "$IXE_FORGE_OPENROUTER_KEY_FILE" || {
      printf 'Forge OpenRouter key must be a nonempty regular file: %s\n' \
        "$IXE_FORGE_OPENROUTER_KEY_FILE" >&2
      return 1
    }
  IXE_FORGE_OPENROUTER_KEY_SOURCE=$(readlink -f \
    "$IXE_FORGE_OPENROUTER_KEY_FILE")
  export IXE_FORGE_OPENROUTER_KEY_SOURCE
}

ixe_agent_seed() {
  ixe_container_id=$1
  ixe_adapter_dir=$2

  docker exec "$ixe_container_id" sh -eu -c '
    install -d -m 0700 -o installer -g installer /run/ixe/agent-state/forge
    ln -s /run/ixe/agent-state/forge /home/installer/.forge
  '
  docker cp "$IXE_FORGE_OPENROUTER_KEY_SOURCE" \
    "$ixe_container_id:/run/ixe/agent-state/forge/openrouter-api-key"
  docker cp "$ixe_adapter_dir/forge-seed.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-forge-seed"
  docker cp "$ixe_adapter_dir/forge-launch.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-agent-launch"
  docker cp "$ixe_adapter_dir/forge-interact.exp" \
    "$ixe_container_id:/usr/local/libexec/ixe-forge-interact"
  docker exec "$ixe_container_id" sh -eu -c '
    chown installer:installer /run/ixe/agent-state/forge/openrouter-api-key
    chmod 0600 /run/ixe/agent-state/forge/openrouter-api-key
    chmod 0755 /usr/local/libexec/ixe-forge-seed \
      /usr/local/libexec/ixe-agent-launch /usr/local/libexec/ixe-forge-interact
  '
  docker exec --user installer \
    --env HOME=/home/installer \
    --env PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin \
    "$ixe_container_id" /usr/local/libexec/ixe-forge-seed
  unset ixe_container_id ixe_adapter_dir
}

ixe_agent_check_login() {
  ixe_container_id=$1
  docker exec --user installer \
    --env HOME=/home/installer \
    --env PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin \
    "$ixe_container_id" sh -eu -c '
      test -z "${OPENROUTER_API_KEY:-}"
      test ! -e /run/ixe/agent-state/forge/openrouter-api-key
      test -s "$HOME/.forge/.forge.db"
      test "$(forge config get model --porcelain)" = minimax/minimax-m3:free
      forge info >/dev/null 2>&1
    '
  unset ixe_container_id
}

ixe_agent_collect() {
  ixe_container_id=$1
  ixe_artifact_dir=$2

  printf '%s\n' \
    'Forge does not expose a stable file trajectory; use terminal.typescript.' \
    > "$ixe_artifact_dir/forge-trajectory.txt"
  chmod 0600 "$ixe_artifact_dir/forge-trajectory.txt"

  ixe_key=$(tr -d '\r\n' < "$IXE_FORGE_OPENROUTER_KEY_SOURCE")
  if test -n "$ixe_key" && grep -RFl -- "$ixe_key" "$ixe_artifact_dir" >/dev/null; then
    unset ixe_key
    printf '%s\n' \
      'Forge conductor credential leaked into retained IXE evidence' >&2
    return 1
  fi
  unset ixe_container_id ixe_artifact_dir ixe_key
}
