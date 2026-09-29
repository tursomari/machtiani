#!/usr/bin/env bash
set -euo pipefail

export HOME=/home/installer
export CODEX_HOME=$HOME/.codex
export PATH=/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.local/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon

prompt=$(<"$HOME/machtiani/INSTALL.md")
exec codex \
  --dangerously-bypass-approvals-and-sandbox \
  --no-alt-screen \
  --model gpt-5.6-luna \
  -c 'model_reasoning_effort="high"' \
  --cd "$HOME/machtiani" \
  "$prompt"
