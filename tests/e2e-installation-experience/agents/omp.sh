#!/usr/bin/env bash

IXE_AGENT_LABEL=OMP
IXE_AGENT_STATE_NAME=.omp
IXE_AGENT_LOGIN_COMMAND='omp auth-broker login openai-codex'

ixe_agent_validate_host() {
  command -v omp >/dev/null 2>&1 || {
    printf 'OMP adapter requires omp on the host PATH\n' >&2
    return 1
  }
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:aarch64) ;;
    *)
      printf 'OMP IXE currently requires a Linux x86_64 or aarch64 host\n' >&2
      return 1
      ;;
  esac

  IXE_OMP_STATE_SOURCE=${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}
  test -d "$IXE_OMP_STATE_SOURCE" && test ! -L "$IXE_OMP_STATE_SOURCE" || {
    printf 'OMP state must be a real directory: %s\n' "$IXE_OMP_STATE_SOURCE" >&2
    return 1
  }
  test -f "$IXE_OMP_STATE_SOURCE/agent.db" && test ! -L "$IXE_OMP_STATE_SOURCE/agent.db" || {
    printf 'OMP authentication database must be a regular file: %s\n' \
      "$IXE_OMP_STATE_SOURCE/agent.db" >&2
    return 1
  }
  IXE_OMP_ENTRY=$(readlink -f "$(command -v omp)")
  test -f "$IXE_OMP_ENTRY" && test -x "$IXE_OMP_ENTRY" || {
    printf 'Cannot resolve the host OMP executable from %s\n' "$(command -v omp)" >&2
    return 1
  }
  omp --version 2>/dev/null | grep -E '^omp/[0-9]+' >/dev/null || {
    printf 'Host OMP executable did not report a supported version\n' >&2
    return 1
  }

  IXE_OMP_MODEL=${IXE_OMP_MODEL:-gpt-5.6-luna}
  case "$IXE_OMP_MODEL" in
    ''|*[!A-Za-z0-9._:/+-]*)
      printf 'Invalid OMP IXE model identifier: %s\n' "$IXE_OMP_MODEL" >&2
      return 1
      ;;
  esac
  IXE_OMP_PROVIDER=openai-codex
  IXE_OMP_OPENROUTER_KEY_SOURCE=
  if test -n "${IXE_OMP_OPENROUTER_KEY_FILE:-}"; then
    case "$IXE_OMP_OPENROUTER_KEY_FILE" in
      /*) ;;
      *)
        printf '%s\n' 'IXE_OMP_OPENROUTER_KEY_FILE must be an absolute path' >&2
        return 1
        ;;
    esac
    test -f "$IXE_OMP_OPENROUTER_KEY_FILE" && \
      test ! -L "$IXE_OMP_OPENROUTER_KEY_FILE" && \
      test -s "$IXE_OMP_OPENROUTER_KEY_FILE" || {
        printf 'OMP OpenRouter key must be a nonempty regular file: %s\n' \
          "$IXE_OMP_OPENROUTER_KEY_FILE" >&2
        return 1
      }
    IXE_OMP_OPENROUTER_KEY_SOURCE=$(readlink -f \
      "$IXE_OMP_OPENROUTER_KEY_FILE")
    IXE_OMP_PROVIDER=openrouter
  fi
  export IXE_OMP_STATE_SOURCE IXE_OMP_ENTRY IXE_OMP_MODEL \
    IXE_OMP_PROVIDER IXE_OMP_OPENROUTER_KEY_SOURCE
}

ixe_agent_seed() {
  ixe_container_id=$1
  ixe_adapter_dir=$2
  ixe_runtime_root=$3
  ixe_auth_snapshot=$ixe_runtime_root/omp-agent.db

  python3 - "$IXE_OMP_STATE_SOURCE/agent.db" "$ixe_auth_snapshot" \
    "$IXE_OMP_OPENROUTER_KEY_SOURCE" <<'PY'
import json
import sqlite3
import sys

source_path, destination_path, openrouter_key_path = sys.argv[1:]
source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
destination = sqlite3.connect(destination_path)
try:
    source.backup(destination)
    if destination.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='auth_credentials'"
    ).fetchone() is None:
        raise SystemExit("OMP authentication database lacks auth_credentials")
    if openrouter_key_path:
        with open(openrouter_key_path, encoding="utf-8") as key_file:
            key = key_file.read().strip()
        if not key:
            raise SystemExit("OMP OpenRouter key is empty")
        destination.execute(
            "DELETE FROM auth_credentials "
            "WHERE provider = ? AND credential_type = ?",
            ("openrouter", "api_key"),
        )
        destination.execute(
            "INSERT INTO auth_credentials "
            "(provider, credential_type, data, identity_key) VALUES (?, ?, ?, NULL)",
            ("openrouter", "api_key", json.dumps({"key": key}, separators=(",", ":"))),
        )
        destination.commit()
finally:
    destination.close()
    source.close()
PY
  chmod 0600 "$ixe_auth_snapshot"

  docker exec "$ixe_container_id" mkdir -p \
    /opt/ixe/agents/omp/bin /run/ixe/agent-state/omp
  docker cp "$IXE_OMP_ENTRY" \
    "$ixe_container_id:/opt/ixe/agents/omp/bin/omp"
  docker cp "$ixe_auth_snapshot" \
    "$ixe_container_id:/run/ixe/agent-state/omp/agent.db"
  docker cp "$ixe_adapter_dir/omp-exec.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-omp-exec"
  docker cp "$ixe_adapter_dir/omp-launch.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-agent-launch"
  docker exec "$ixe_container_id" sh -eu -c '
    chmod 0755 /opt/ixe/agents/omp/bin/omp \
      /usr/local/libexec/ixe-omp-exec /usr/local/libexec/ixe-agent-launch
    chown -R installer:installer /opt/ixe/agents/omp /run/ixe/agent-state/omp
    chmod 0700 /run/ixe/agent-state/omp
    chmod 0600 /run/ixe/agent-state/omp/agent.db
  '
  docker exec --env IXE_OMP_MODEL="$IXE_OMP_MODEL" "$ixe_container_id" \
    sh -eu -c '
      printf "%s\n" "$IXE_OMP_MODEL" > /run/ixe/agent-state/omp/ixe-model
      chown installer:installer /run/ixe/agent-state/omp/ixe-model
      chmod 0600 /run/ixe/agent-state/omp/ixe-model
    '
  unset ixe_container_id ixe_adapter_dir ixe_runtime_root ixe_auth_snapshot
}

ixe_agent_check_login() {
  ixe_container_id=$1
  docker exec --user installer \
    --env HOME=/home/installer \
    --env PI_CODING_AGENT_DIR=/run/ixe/agent-state/omp \
    --env OMP_SKIP_SETUP=1 \
    --env PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin \
    "$ixe_container_id" /usr/local/libexec/ixe-omp-exec \
      token "$IXE_OMP_PROVIDER" >/dev/null 2>&1
}

ixe_agent_collect() {
  ixe_container_id=$1
  ixe_artifact_dir=$2
  ixe_trajectory=$ixe_artifact_dir/omp-trajectory.tar

  if docker exec "$ixe_container_id" sh -eu -c '
      cd /run/ixe/agent-state/omp
      test -d sessions
      find sessions -type f -newer /run/ixe/session-start -print -quit | grep -q .
    '; then
    docker exec "$ixe_container_id" sh -eu -c '
      cd /run/ixe/agent-state/omp
      find sessions -type f -newer /run/ixe/session-start -print0 |
        tar --null --files-from=- -cf -
    ' > "$ixe_trajectory"
    chmod 0600 "$ixe_trajectory"
  else
    printf '%s\n' 'No new file-based OMP trajectory was found; use terminal.typescript.' \
      > "$ixe_artifact_dir/omp-trajectory.txt"
    chmod 0600 "$ixe_artifact_dir/omp-trajectory.txt"
  fi
  if test -n "$IXE_OMP_OPENROUTER_KEY_SOURCE"; then
    ixe_key=$(tr -d '\r\n' < "$IXE_OMP_OPENROUTER_KEY_SOURCE")
    if test -n "$ixe_key" && grep -RFl -- "$ixe_key" "$ixe_artifact_dir" >/dev/null; then
      unset ixe_key
      printf '%s\n' \
        'OMP conductor credential leaked into retained IXE evidence' >&2
      return 1
    fi
    unset ixe_key
  fi
  unset ixe_container_id ixe_artifact_dir ixe_trajectory
}
