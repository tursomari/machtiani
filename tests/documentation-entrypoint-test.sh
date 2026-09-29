#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
entrypoint=$repo_root/docs/README.md
test -f "$entrypoint"

required=(
  README.md
  BYOC.md
  INSTALL.md
  TESTING.md
  docs/dearmachine-guide.md
  docs/backend-management.md
  docs/machtiani-guide.md
  docs/installation/README.md
  dearmachine/README.md
  dearmachine/dearmachine/runbooks/README.md
  machtiani-harness/README.md
  machtiani-harness/docs/configuration.md
  dearmachine-concierge/README.md
  dearmachine-concierge/docs/concierge-user-stories.md
)

for path in "${required[@]}"; do
  test -e "$repo_root/$path"
  relative=${path#docs/}
  if [[ "$path" == docs/* ]]; then
    rg -F -- "($relative)" "$entrypoint" >/dev/null
  else
    rg -F -- "(../$path)" "$entrypoint" >/dev/null
  fi
done

for policy in 'Custom Chat Completions providers' 'non-secret credential reference' \
  '--endpoint' '--credential-variable' 'Keep the wizard'; do
  rg -F -- "$policy" "$repo_root/docs/installation/backends/forge.md" >/dev/null
done

for policy in 'Preserve the existing backend order' 'typed credential helper' \
  'Do not restart the installation procedure' 'The shared model profile remains unchanged' \
  'not a flag of ordinary `dearmachine up`' 'backend-specific private configuration'; do
  rg -F -- "$policy" "$repo_root/docs/backend-management.md" >/dev/null
done

for policy in 'Documentation describes intended and supported behavior.' \
  'is authoritative for facts' \
  'Source code and tests are the'; do
  rg -F -- "$policy" "$entrypoint" >/dev/null
done

# BYOC.md routes an outside agent into these maintained paths; keep them real.
for path in INSTALL.md docs/README.md docs/installation/README.md \
  docs/installation/06-always-on.md docs/installation-procedure.md \
  docs/backend-management.md docs/managed-nix-installation.md \
  docs/dearmachine-guide.md docs/uninstall.md scripts/credential-entry.sh \
  scripts/credential-entry.ps1 docs/standard-installation.md scripts/standard-build.py \
  docs/windows-native.md scripts/prepare-windows.ps1 \
  dearmachine/dearmachine/runbooks/README.md \
  dearmachine-concierge/packages/model-host/src/index.ts; do
  test -e "$repo_root/$path"
  rg -F -- "$path" "$repo_root/BYOC.md" >/dev/null
done
for policy in 'Do not start, drive, or converse with the built-in' \
  'Never ask the human to paste a secret into chat' \
  'nix run ./dearmachine-concierge -- install --source-root "$PWD"'; do
  rg -F -- "$policy" "$repo_root/BYOC.md" >/dev/null
done
for agent in claude codex omp; do
  rg -F -- "$agent \"Read BYOC.md and follow it.\"" "$repo_root/README.md" >/dev/null
done

echo 'documentation entry point contract passed'
python3 "$repo_root/tests/backend-guidance-test.py"
