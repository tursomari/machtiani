#!/usr/bin/env bash
set -euo pipefail

key_file=/run/ixe/agent-state/forge/openrouter-api-key
test -s "$key_file"

key=$(tr -d '\r\n' < "$key_file")
test -n "$key"
export OPENROUTER_API_KEY=$key

forge info >/dev/null 2>&1
forge config set model open_router minimax/minimax-m3:free >/dev/null 2>&1

unset key
unset OPENROUTER_API_KEY
unlink "$key_file"

test -s "$HOME/.forge/.forge.db"
test "$(forge config get model --porcelain)" = minimax/minimax-m3:free
