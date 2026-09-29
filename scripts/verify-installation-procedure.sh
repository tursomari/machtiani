#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_file="$repo_root/docs/installation-procedure.md"
source_section="$source_file"

readme="$repo_root/README.md"
for required in \
  '## Install - Linux, macOS or Windows' \
  '## Or install from source (Nix also supported)' \
  'Read BYOC.md and follow it.' \
  'nix run ./dearmachine-concierge -- quick-start --source-root "$PWD"' \
  'installer=$(sh scripts/build-standard.sh --bootstrap)' \
  '"$installer" quick-start --method standard --source-root "$PWD"' \
  'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\quick-start.ps1' \
  'Dear Machine walks you through models and providers' \
  'https://github.com/tursomari/machtiani/releases/latest/download/install.sh' \
  '**At my desk.**' \
  'Run `dearmachine` anytime'; do
  if ! grep -Fq -- "$required" "$readme"; then
    printf 'README is missing the simple installation surface: %s\n' "$required" >&2
    exit 1
  fi
done
if grep -Fq -- '<!-- installation-procedure:' "$readme"; then
  printf 'README must link to the detailed procedure instead of embedding it.\n' >&2
  exit 1
fi
if grep -Fq 'Then make sure `~/.local/bin`' "$readme"; then
  printf 'Quick start must enter guided setup without a separate PATH or launch step.\n' >&2
  exit 1
fi

for required in \
  'Backend agents are user-installed prerequisites' \
  'private shared model profile created by the Machtiani Installer wizard' \
  'transport = "model-host"' \
  'model = "@machtiani/planner"' \
  'model = "@machtiani/shell-agent"' \
  'model = "@machtiani/sync"' \
  'shell_agent_model = "dearmachine-shell-agent"' \
  'machtiani auth status --model dearmachine' \
  'must not install or upgrade one unless the user' \
  'explicitly asks' \
  "'<selected-backend-id>'" \
  'dearmachine/docs/custom-backend-guide.md' \
  'Do not run `setup-agents` afterward' \
  'dearmachine up --create' \
  '--resume' \
  "--email '<your-email-address>'" \
  '--new-inbox' \
  "used for Dear Machine's state and memory management" \
  'dearmachine status' \
  'dearmachine down' \
  'dearmachine up --foreground' \
  'AgentMail, OpenMail, and Sendmux' \
  '--transport agentmail' \
  '--transport openmail' \
  '--transport sendmux' \
  "--inbox '<existing-inbox-address-or-uuid>'"; do
  if ! grep -Fq -- "$required" "$source_section"; then
    printf 'Installation Procedure is missing the streamlined DearMachine contract: %s\n' "$required" >&2
    exit 1
  fi
done

if grep -Fq -- 'choose the DeepSeek catalogue preset' "$source_section"; then
  printf 'Installation Procedure must not override the user-selected Machtiani provider and model.\n' >&2
  exit 1
fi

for backend_specific_default in \
  'Forge-only default' \
  'backends = ["forge"]' \
  'command -v dearmachine agent-manager machtiani forge'; do
  if grep -Fq -- "$backend_specific_default" "$source_section"; then
    printf 'Installation Procedure exposes a backend-specific default: %s\n' \
      "$backend_specific_default" >&2
    exit 1
  fi
done

if grep -Fq -- 'curl --fail --location --output "$HOME/.local/bin/forge"' "$source_section"; then
  printf 'Installation Procedure must not install the user-owned Forge backend.\n' >&2
  exit 1
fi

if grep -Fq -- 'DEARMACHINE_LIVE_' "$source_section"; then
  printf 'Installation Procedure must keep live-test mutation gates out of user setup.\n' >&2
  exit 1
fi

for retired in '--inbox-id' '--db' '--pidfile' 'DEARMACHINE_ALLOW' 'nohup dearmachine' \
  'dearmachine init --entry-point-repo "$HOME/.dearmachine/entrypoint/main"'; do
  if grep -Fq -- "$retired" "$source_section"; then
    printf 'Installation Procedure still contains retired DearMachine syntax: %s\n' "$retired" >&2
    exit 1
  fi
done

if ! git -C "$repo_root" check-ignore --no-index --quiet -- .secrets; then
  printf 'Installation Procedure credential file .secrets is not ignored.\n' >&2
  exit 1
fi

if grep -Eq '<selected-model-id>|<selected-reasoning-effort>' "$source_section"; then
  printf 'Managed model configuration must follow component selectors, not freeze the initial choice.\n' >&2
  exit 1
fi
