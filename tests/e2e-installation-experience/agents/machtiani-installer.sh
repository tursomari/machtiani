#!/usr/bin/env bash

IXE_AGENT_LABEL='Machtiani Installer'
IXE_AGENT_STATE_NAME=machtiani-installer
IXE_AGENT_LOGIN_COMMAND='complete provider authentication in the installer wizard'

ixe_agent_validate_host() {
  test -n "${IXE_INSTALLER_SOURCE_ROOT:-}" || {
    printf '%s\n' 'Machtiani Installer adapter requires IXE_INSTALLER_SOURCE_ROOT' >&2
    return 1
  }
  test -f "$IXE_INSTALLER_SOURCE_ROOT/flake.nix" && \
    test -f "$IXE_INSTALLER_SOURCE_ROOT/packages/app/package.json" || {
      printf 'Invalid Machtiani Installer source root: %s\n' "$IXE_INSTALLER_SOURCE_ROOT" >&2
      return 1
    }
  if test "${self_test:-false}" = true; then
    return 0
  fi
}

ixe_agent_seed() {
  ixe_container_id=$1
  ixe_adapter_dir=$2

  docker cp "$ixe_adapter_dir/machtiani-installer-launch.sh" \
    "$ixe_container_id:/usr/local/libexec/ixe-agent-launch"
  docker exec "$ixe_container_id" sh -eu -c '
    chmod 0755 /usr/local/libexec/ixe-agent-launch
  '
  unset ixe_container_id ixe_adapter_dir
}

ixe_agent_check_login() {
  ixe_container_id=$1
  if docker exec "$ixe_container_id" test -f /run/ixe/standard-mode; then
    return 0 # Software and provider login are deliberately absent until curl/wizard.
  fi
  docker exec --user installer "$ixe_container_id" sh -eu -c '
    test -x /nix/var/nix/profiles/ixe-installer/bin/dearmachine
  '
  unset ixe_container_id
}

ixe_agent_collect() {
  ixe_container_id=$1
  ixe_artifact_dir=$2
  ixe_trajectory=$ixe_artifact_dir/machtiani-installer-dsh-trajectory.tar

  if docker exec "$ixe_container_id" sh -eu -c '
      cd /home/installer/.local/state/machtiani-installer/dsh
      test -d sessions
      find sessions -type f -newer /run/ixe/session-start -print -quit | grep -q .
    '; then
    docker exec "$ixe_container_id" sh -eu -c '
      cd /home/installer/.local/state/machtiani-installer/dsh
      find sessions -type f -newer /run/ixe/session-start -print0 |
        tar --null --files-from=- -cf -
    ' > "$ixe_trajectory"
    chmod 0600 "$ixe_trajectory"
  else
    printf '%s\n' 'No new DSH trajectory was found; use terminal.typescript.' \
      > "$ixe_artifact_dir/machtiani-installer-dsh-trajectory.txt"
    chmod 0600 "$ixe_artifact_dir/machtiani-installer-dsh-trajectory.txt"
  fi

  unset ixe_container_id ixe_artifact_dir ixe_trajectory
}
