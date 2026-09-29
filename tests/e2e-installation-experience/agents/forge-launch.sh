#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/installer
export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon

exec expect /usr/local/libexec/ixe-forge-interact \
  "$HOME/machtiani/INSTALL.md"
