#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

export HOME=/home/installer
if test -f /run/ixe/standard-mode; then
  test ! -e /nix || fail 'Standard installation introduced /nix'
  release=$(dirname "$(dirname "$(readlink -f "$HOME/.local/bin/dearmachine")")")
  export PATH=$HOME/.local/bin:$release/bin:/usr/local/bin:/usr/bin:/bin
else
export PATH=$HOME/.local/bin:/usr/local/bin:/nix/var/nix/profiles/ixe/bin:$HOME/.nix-profile/bin
export NIX_REMOTE=daemon
fi

for command_name in machtiani dearmachine agent-manager python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is not available"
done
expected_dearmachine="$HOME/.local/bin/dearmachine"
test "$(command -v dearmachine)" = "$expected_dearmachine" || \
  fail "dearmachine did not resolve to the installed native command"

test -s "$HOME/.machtiani/config.toml" || fail 'Machtiani global configuration is missing'
test -s "$HOME/.dearmachine/config/dearmachine.toml" || fail 'Dear Machine configuration is missing'
test -s "$HOME/.dearmachine/pairs.toml" || fail 'Dear Machine pair registry is missing'

grep -F 'response_tier = "formatted"' "$HOME/.dearmachine/config/dearmachine.toml" >/dev/null || \
  fail 'Dear Machine is not configured for formatted replies'

resolved_backends=$(mktemp /tmp/machtiani-ixe-resolved-backends.XXXXXX)
health_project=$(mktemp -d /tmp/machtiani-ixe-backend-health.XXXXXX)
cleanup_verification() {
  rm -f -- "$resolved_backends" "${after:-}"
  rm -rf -- "$health_project"
}
trap cleanup_verification EXIT

DEARMACHINE_BACKENDS=$(python3 - "$HOME/.dearmachine/config/dearmachine.toml" <<'BACKEND_SELECTION_PY'
import json
import sys
import tomllib

with open(sys.argv[1], 'rb') as stream:
    backends = tomllib.load(stream).get('backends')
if not isinstance(backends, list) or not backends or not all(isinstance(item, str) and item.strip() for item in backends):
    raise SystemExit('Dear Machine has no configured backend selection')
print(json.dumps(backends))
BACKEND_SELECTION_PY
)
export DEARMACHINE_BACKENDS
agent-manager backend list >"$resolved_backends"
selected_backend=$(python3 - "$resolved_backends" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    backends = stream.read().splitlines()
if not backends or not all(re.fullmatch(r'[A-Za-z0-9_.-]+', backend) for backend in backends):
    raise SystemExit("Dear Machine has no resolved selected backend")
print(backends[0])
PY
)

git -C "$health_project" init --quiet
(
  cd "$health_project"
  agent-manager backend health "$selected_backend"
)

if test -n "${DEEPSEEK_API_KEY:-}" && \
   grep -F -- "$DEEPSEEK_API_KEY" "$HOME/.machtiani/config.toml" >/dev/null; then
  fail 'Machtiani configuration contains a literal provider credential'
fi

dearmachine status

after=$(mktemp /tmp/machtiani-ixe-source-after.XXXXXX)
if test -f /run/ixe/standard-mode; then
  python3 /usr/local/libexec/ixe-standard-source.py "${IXE_STANDARD_SOURCE_ROOT:?}" > "$after"
else
  git -C "$HOME/machtiani" status --porcelain=v2 --untracked-files=all --ignore-submodules=none > "$after"
fi
cmp -s /run/ixe/source-before "$after" || fail 'installation changed the source checkout'

printf 'PASS: basic Dear Machine installation is present and healthy\n'
