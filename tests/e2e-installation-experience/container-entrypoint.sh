#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'IXE container startup failure: %s\n' "$*" >&2
  exit 1
}

test "$(id -u)" -eq 0 || fail 'entrypoint must run as root'
umask 077
install -d -o root -g installer -m 0770 /run/ixe
install -d -m 0755 /run/sshd

ssh-keygen -A >/dev/null

if test ! -f /run/ixe/standard-mode; then
  /usr/local/bin/nix daemon >/run/ixe/nix-daemon.log 2>&1 &
  printf '%s\n' "$!" > /run/ixe/nix-daemon.pid
else
  test ! -e /nix || fail 'Standard IXE requires a target without /nix'
fi

for attempt in $(seq 1 300); do
  test ! -f /run/ixe/abort || fail 'host aborted startup'
  if test -s /run/ixe/authorized_keys && test -f /run/ixe/prepared; then
    break
  fi
  test "$attempt" -lt 300 || fail 'timed out waiting for host preparation'
  sleep 1
done

install -d -o installer -g installer -m 0700 /home/installer/.ssh
install -o installer -g installer -m 0600 /run/ixe/authorized_keys \
  /home/installer/.ssh/authorized_keys

cat >/run/ixe/sshd_config <<'EOF'
Port 22
ListenAddress 0.0.0.0
Protocol 2
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers installer
UsePAM no
PrintMotd yes
PrintLastLog no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
SetEnv PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:/home/installer/.local/bin:/home/installer/.nix-profile/bin NIX_REMOTE=daemon
Subsystem sftp internal-sftp
PidFile /run/sshd/sshd.pid
EOF

if test -f /run/ixe/standard-mode; then
  sed -i 's|^SetEnv .*|SetEnv PATH=/usr/local/bin:/home/installer/.local/bin:/usr/bin:/bin|' /run/ixe/sshd_config
fi

if test ! -f /run/ixe/standard-mode; then
cat >/etc/motd <<'EOF'
Machtiani Installation Experience Evaluation

Run this command to begin the recorded installation session:

  dearmachine

After the installation agent exits and verification passes, an interactive
post-install exploration shell opens. Run dearmachine to try the concierge.
Type exit (or Ctrl+D) in that shell to finish the evaluation and collect artifacts.
If installation or verification fails, the evaluation finishes immediately.
EOF
fi

touch /run/ixe/ssh-ready
chmod 0600 /run/ixe/ssh-ready
if test -f /run/ixe/standard-mode; then
  exec /usr/sbin/sshd -D -e -f /run/ixe/sshd_config
fi
exec /nix/var/nix/profiles/ixe/bin/sshd -D -e -f /run/ixe/sshd_config
