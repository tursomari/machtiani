#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/installer
export XDG_STATE_HOME=$HOME/.local/state
export XDG_DATA_HOME=$HOME/.local/share
export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon
export DEARMACHINE_SOURCE_ROOT="$HOME/machtiani"

exec /nix/var/nix/profiles/ixe-installer/bin/dearmachine
