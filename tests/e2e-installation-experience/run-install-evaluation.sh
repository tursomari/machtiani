#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'IXE session failure: %s\n' "$*" >&2
  exit 1
}

test "$(id -u)" -eq 1000 || fail 'run this command as the installer user over SSH'
test -f /run/ixe/prepared || fail 'the host has not completed preparation'

umask 077
artifact_root=/run/ixe/artifacts
install -d -m 0700 "$artifact_root"
test ! -e /run/ixe/session-running || fail 'an installation session has already been started'
touch /run/ixe/session-running

export HOME=/home/installer
if test -f /run/ixe/standard-mode; then
  release=$(dirname "$(dirname "$(readlink -f "$HOME/.local/bin/dearmachine")")")
  export PATH=$HOME/.local/bin:$release/bin:/usr/local/bin:/usr/bin:/bin
  export IXE_STANDARD_SOURCE_ROOT=$release/source
  python3 /usr/local/libexec/ixe-standard-source.py "$IXE_STANDARD_SOURCE_ROOT" > /run/ixe/source-before
else
export PATH=$HOME/.local/bin:/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon
export NIX_CONFIG='experimental-features = nix-command flakes'
if test -f /run/ixe/curl-mode; then
  # Flight-friendly evaluation: fail explicitly if a required package is not
  # cached, rather than compiling it or substituting it over the network.
  export NIX_CONFIG="$NIX_CONFIG"$'\nmax-jobs = 0\nsubstitute = false'
fi
fi

set +e
script -qefc '/usr/local/libexec/ixe-agent-launch' \
  "$artifact_root/terminal.typescript"
agent_status=$?
set -e

set +e
/usr/local/libexec/ixe-verify \
  > "$artifact_root/verification.txt" 2>&1
verification_status=$?
set -e

printf '\nThe installation agent exited with status %s.\n' "$agent_status"
printf 'Postcondition verification exited with status %s.\n' "$verification_status"

if test "$agent_status" -eq 0 && test "$verification_status" -eq 0; then
  cat <<'EOF'

Installation complete. Entering the interactive post-install exploration shell.
You can now try the installed product: run `dearmachine` to launch the concierge.
When you are done exploring, type exit (or Ctrl+D) in this shell to finish the evaluation.
The container will stay running until you exit this shell.
EOF
  # Inherit the installer user's TTY and HOME/PATH/NIX environment. Skip startup
  # files so the base image's login profile cannot replace the session's PATH.
  # Exploration commands (including a nonzero exit) never change install results.
  PS1='ixe post-install \w \$ ' bash --noprofile --norc --login -i || true
fi

printf '%s\n' "$agent_status" > "$artifact_root/agent-exit-status"
printf '%s\n' "$verification_status" > "$artifact_root/verification-exit-status"

completion_tmp=/run/ixe/completed.tmp
{
  printf 'agent_status=%s\n' "$agent_status"
  printf 'verification_status=%s\n' "$verification_status"
} > "$completion_tmp"
chmod 0600 "$completion_tmp"
mv "$completion_tmp" /run/ixe/completed

printf 'The host-side IXE will now collect the private transcript and finish.\n'

test "$agent_status" -eq 0 && test "$verification_status" -eq 0
