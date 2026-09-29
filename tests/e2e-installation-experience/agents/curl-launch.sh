#!/usr/bin/env bash
set -euo pipefail
export HOME=/home/installer
export XDG_STATE_HOME=$HOME/.local/state
export XDG_DATA_HOME=$HOME/.local/share
if test -f /run/ixe/standard-mode; then
  export PATH=/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin
else
export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon
fi
test -x "$HOME/.local/bin/dearmachine" || {
  printf 'Run the curl bootstrap before starting this IXE.\n' >&2
  exit 1
}
# The downloaded launcher supplies its matching downloaded source/docs.
exec "$HOME/.local/bin/dearmachine"
