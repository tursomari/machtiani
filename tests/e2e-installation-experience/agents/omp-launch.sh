#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/installer
export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon
export PI_CODING_AGENT_DIR=/run/ixe/agent-state/omp

prompt=$(<"$HOME/machtiani/INSTALL.md")
model=$(<"$PI_CODING_AGENT_DIR/ixe-model")
exec /usr/local/libexec/ixe-omp-exec \
  --model "$model" \
  --thinking medium \
  --approval-mode yolo \
  --no-title \
  --cwd "$HOME/machtiani" \
  "$prompt"
