#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'IXE container preparation failure: %s\n' "$*" >&2
  exit 1
}

test "$(id -u)" -eq 0 || fail 'preparation must run as root'
test -f /home/installer/machtiani/INSTALL.md || fail 'source snapshot lacks INSTALL.md'
test -x /usr/local/libexec/ixe-agent-launch || fail 'agent launch adapter is missing'
test -f /run/ixe/backend-fixture || fail 'backend fixture was not prepared and verified'
if test -f /run/ixe/standard-mode; then
  test ! -e /nix || fail 'Standard IXE requires a target without /nix'
  install -d -o installer -g installer -m 0700 /run/ixe/artifacts
  printf '[user]\n name = Machtiani IXE Operator\n email = installation-experience@example.invalid\n[init]\n defaultBranch = main\n' > /home/installer/.gitconfig
  chown -R installer:installer /home/installer
  chmod 0700 /home/installer
  touch /run/ixe/session-start /run/ixe/prepared
  chmod 0600 /run/ixe/session-start /run/ixe/prepared
  exit 0
fi
export IXE_PREP_GIT=/nix/var/nix/profiles/ixe-prep/bin/git
test -x "$IXE_PREP_GIT" || fail 'private preparation-only Git is missing'

install -d -o installer -g installer -m 0700 /run/ixe/artifacts
install -d -o installer -g installer -m 0700 /home/installer/.config/nix
install -d -o installer -g installer -m 0755 /opt/ixe/agents
printf '%s\n' 'experimental-features = nix-command flakes' \
  > /home/installer/.config/nix/nix.conf
chown installer:installer /home/installer/.config/nix/nix.conf
chmod 0600 /home/installer/.config/nix/nix.conf
chown -R installer:installer /home/installer /opt/ixe/agents
chmod 0700 /home/installer
test ! -e /home/installer/machtiani/.git || fail 'source snapshot contains host Git state'

run_installer() {
  setpriv --reuid=1000 --regid=1000 --clear-groups /bin/bash -c "$1"
}

run_installer '
  set -euo pipefail
  export HOME=/home/installer
  export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
  export NIX_REMOTE=daemon
  export NIX_CONFIG="experimental-features = nix-command flakes"
  test "$SSL_CERT_FILE" = /nix/var/nix/profiles/ixe/etc/ssl/certs/ca-bundle.crt
  test -r "$SSL_CERT_FILE"
  for system_ca_path in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
    test -r "$system_ca_path"
    test "$(readlink -f "$system_ca_path")" = "$(readlink -f "$SSL_CERT_FILE")"
  done
  test "$(command -v curl)" = /nix/var/nix/profiles/ixe/bin/curl
  curl --version >/dev/null
  "$IXE_PREP_GIT" config --global user.name "Machtiani IXE Operator"
  "$IXE_PREP_GIT" config --global user.email "installation-experience@example.invalid"
  "$IXE_PREP_GIT" config --global init.defaultBranch main

  for component in machtiani-harness dearmachine dearmachine-concierge; do
    "$IXE_PREP_GIT" -C "$HOME/machtiani/$component" init --quiet --initial-branch=main
    "$IXE_PREP_GIT" -C "$HOME/machtiani/$component" add -A
    "$IXE_PREP_GIT" -C "$HOME/machtiani/$component" commit --quiet -m "test: seed installation experience snapshot"
  done

  "$IXE_PREP_GIT" -C "$HOME/machtiani" init --quiet --initial-branch=main
  "$IXE_PREP_GIT" -C "$HOME/machtiani" add -A
  "$IXE_PREP_GIT" -C "$HOME/machtiani" commit --quiet -m "test: seed installation experience snapshot"

  origin_root=$(mktemp -d /tmp/machtiani-ixe-origins.XXXXXX)
  "$IXE_PREP_GIT" init --quiet --bare --initial-branch=main "$origin_root/umbrella.git"
  "$IXE_PREP_GIT" -C "$HOME/machtiani" remote add origin "file://$origin_root/umbrella.git"
  "$IXE_PREP_GIT" -C "$HOME/machtiani" push --quiet --set-upstream origin main

  "$IXE_PREP_GIT" init --quiet --bare --initial-branch=main "$origin_root/machtiani-harness.git"
  "$IXE_PREP_GIT" -C "$HOME/machtiani/machtiani-harness" remote add origin "file://$origin_root/machtiani-harness.git"
  "$IXE_PREP_GIT" -C "$HOME/machtiani/machtiani-harness" push --quiet --set-upstream origin main

  "$IXE_PREP_GIT" -C "$HOME/machtiani" status --porcelain=v2 --untracked-files=all --ignore-submodules=none > /run/ixe/source-before
  touch /run/ixe/session-start
'

unlink /nix/var/nix/profiles/ixe-prep
unset IXE_PREP_GIT

chown installer:installer /run/ixe/source-before /run/ixe/session-start
chmod 0600 /run/ixe/source-before /run/ixe/session-start
touch /run/ixe/prepared
chmod 0600 /run/ixe/prepared
