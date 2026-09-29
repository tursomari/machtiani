#!/usr/bin/env bash

# Container-side ForgeCode configuration and hermeticity assertions.

preflight_fail() {
  printf 'INSTALLATION PROCEDURE AGENT PREFLIGHT FAILURE: %s\n' "$*" >&2
  return 1
}

preflight_assert_snapshot_hygiene() {
  preflight_snapshot_root=$1
  test -d "$preflight_snapshot_root" || {
    preflight_fail "source snapshot is missing: $preflight_snapshot_root"
    return 1
  }

  preflight_bad_path=$(find "$preflight_snapshot_root" \
    \( -name .git -o -name .ssh -o -name .secrets -o -name '.env*' \
       -o -name .forge -o -name config.toml \
       -o \( -type f \( -iname credentials -o -iname credentials.json -o -name .credentials.json \) \) \
    \) -print -quit)
  test -z "$preflight_bad_path" || {
    preflight_fail "source snapshot contains forbidden host state: $preflight_bad_path"
    return 1
  }
}

preflight_assert_credentials() {
  preflight_credentials=$HOME/.forge/.credentials.json
  test -f "$preflight_credentials" && test ! -L "$preflight_credentials" || {
    preflight_fail 'Forge credential store is not a regular, non-symlink file.'
    return 1
  }
  test "$(stat -c '%a' "$preflight_credentials")" = 600 || {
    preflight_fail 'Forge credential store does not have mode 0600.'
    return 1
  }

  python3 - "$preflight_credentials" <<'PY'
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
try:
    records = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Forge credential store is invalid: {error}")
if not isinstance(records, list):
    raise SystemExit("Forge credential store is not a JSON array")
credential_id = os.environ["IPE_FORGE_PROVIDER_ID"]
credential_env = os.environ["IPE_LLM_CREDENTIAL_ENV"]
matches = [row for row in records if isinstance(row, dict) and row.get("id") == credential_id]
if len(matches) != 1:
    raise SystemExit(f"Forge credential store must contain exactly one {credential_id} record")
details = matches[0].get("auth_details")
if not isinstance(details, dict) or not isinstance(details.get("api_key"), str) or not details["api_key"]:
    raise SystemExit(f"Forge {credential_id} credential record has no API key")
if details["api_key"] != os.environ.get(credential_env):
    raise SystemExit(f"Forge {credential_id} credential record does not match the runtime environment")
PY
}

preflight_assert_forge_config() {
  if test "$IPE_LLM_PROFILE" = deepinfra-glm-5.3-flash-high; then
    python3 "${umbrella:-/workspace/machtiani}/tests/e2e-installation-procedure/lib/model-profile.py" check-forge
  fi
  # Forge renders a provider display name here while its configuration retains
  # the provider's machine identity.
  test "$(forge config get provider --porcelain)" = "$IPE_FORGE_PROVIDER_NAME" || {
    preflight_fail "Forge provider is not $IPE_FORGE_PROVIDER_ID."
    return 1
  }
  test "$(forge config get model --porcelain)" = "$IPE_LLM_MODEL" || {
    preflight_fail "Forge model is not $IPE_LLM_MODEL."
    return 1
  }
  test "$(forge config get reasoning-effort --porcelain)" = "$IPE_LLM_REASONING" || {
    preflight_fail "Forge reasoning effort is not $IPE_LLM_REASONING."
    return 1
  }

  forge list provider --porcelain | awk -v id="$IPE_FORGE_PROVIDER_ID" '$2 == id { found = 1 } END { exit !found }' || {
    preflight_fail "Forge provider list does not contain $IPE_FORGE_PROVIDER_ID."
    return 1
  }

  python3 - "$HOME/.forge/.forge.toml" <<'PY'
import os
from pathlib import Path
import sys
import tomllib

path = Path(sys.argv[1])
try:
    config = tomllib.loads(path.read_text(encoding="utf-8"))
except (OSError, tomllib.TOMLDecodeError) as error:
    raise SystemExit(f"Forge configuration is invalid: {error}")
session = config.get("session")
reasoning = config.get("reasoning")
if not isinstance(session, dict):
    raise SystemExit("Forge configuration has no [session] table")
if session.get("provider_id") != os.environ["IPE_FORGE_PROVIDER_ID"]:
    raise SystemExit("Forge [session] provider_id is wrong")
if session.get("model_id") != os.environ["IPE_LLM_MODEL"]:
    raise SystemExit("Forge [session] model_id is wrong")
if not isinstance(reasoning, dict):
    raise SystemExit("Forge configuration has no [reasoning] table")
if reasoning.get("effort") != os.environ["IPE_LLM_REASONING"] or reasoning.get("enabled") is not True:
    raise SystemExit("Forge [reasoning] has the wrong enabled effort")
PY
}

preflight_health_check() {
  preflight_health_root=$(mktemp -d /tmp/machtiani-forge-health.XXXXXX)
  chmod 0700 "$preflight_health_root"
  preflight_health_repo=$preflight_health_root/repository
  preflight_health_output=$preflight_health_root/stdout
  preflight_health_error=$preflight_health_root/stderr
  preflight_health_prompt=$preflight_health_root/prompt
  preflight_health_clean=$preflight_health_root/clean
  preflight_health_agent_dir=$HOME/.forge/agents
  preflight_health_agent=$preflight_health_agent_dir/installation-procedure-health.md
  mkdir -p "$preflight_health_agent_dir"
  chmod 0700 "$preflight_health_agent_dir"

  umask 077
  printf '%s\n' \
    '---' \
    'id: "installation-procedure-health"' \
    'title: "Installation Procedure health check"' \
    'description: "No-tools connectivity health check"' \
    'tool_supported: false' \
    'tools: []' \
    'max_turns: 1' \
    'reasoning:' \
    '  enabled: true' \
    "  effort: \"$IPE_LLM_REASONING\"" \
    '---' \
    '' \
    'Return a direct answer without tools.' > "$preflight_health_agent"
  chmod 0600 "$preflight_health_agent"

  mkdir "$preflight_health_repo"
  git -C "$preflight_health_repo" init --quiet --initial-branch=main
  printf 'Forge health fixture.\n' > "$preflight_health_repo/README.md"
  git -C "$preflight_health_repo" -c user.name='Installation Procedure Preflight' \
    -c user.email='installation-procedure@example.invalid' add -- README.md
  git -C "$preflight_health_repo" -c user.name='Installation Procedure Preflight' \
    -c user.email='installation-procedure@example.invalid' commit --quiet -m 'test: seed forge health fixture'
  git -C "$preflight_health_repo" status --porcelain > "$preflight_health_clean"
  test ! -s "$preflight_health_clean" || {
    preflight_fail 'disposable Forge health repository is initially dirty.'
    return 1
  }

  printf '%s\n' \
    'This is a no-tools health check. Do not call or request any tool.' \
    'Reply with exactly this token and no other text: QS-FORGE-HEALTH-OK' \
    > "$preflight_health_prompt"
  chmod 0600 "$preflight_health_prompt" "$preflight_health_output" "$preflight_health_error" 2>/dev/null || true

  if ! timeout --signal=TERM --kill-after=5s 180s \
    forge --directory "$preflight_health_repo" --agent installation-procedure-health \
    < "$preflight_health_prompt" > "$preflight_health_output" 2> "$preflight_health_error"; then
    preflight_fail 'bounded Forge no-tools health check failed.'
    return 1
  fi
  chmod 0600 "$preflight_health_output" "$preflight_health_error"

  python3 - "$preflight_health_output" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
text = re.sub(r"\x1b(?:[@-_][0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))", "", text)
lines = [line.strip() for line in text.splitlines() if line.strip()]
if lines.count("QS-FORGE-HEALTH-OK") != 1:
    raise SystemExit("Forge health response did not contain exactly one standalone health token")
PY

  git -C "$preflight_health_repo" status --porcelain > "$preflight_health_clean"
  test ! -s "$preflight_health_clean" || {
    preflight_fail 'Forge modified the disposable no-tools health repository.'
    return 1
  }
}

ipe_agent_preflight() {
  preflight_umbrella=${1:-/workspace/machtiani}
  preflight_pid_one_command=
  if test -r /proc/1/cmdline; then
    preflight_pid_one_command=$(tr '\0' ' ' < /proc/1/cmdline)
  fi
  case "$preflight_pid_one_command" in
    *container-agent.sh*) ;;
    *)
      preflight_fail 'container supervisor is not healthy as PID 1.'
      return 1
      ;;
  esac
  test -n "${!IPE_LLM_CREDENTIAL_ENV:-}" || {
    preflight_fail "$IPE_LLM_CREDENTIAL_ENV is not set."
    return 1
  }
  command -v forge >/dev/null 2>&1 || {
    preflight_fail 'forge is not on PATH.'
    return 1
  }
  test "$(forge --version)" = 'forge 2.13.21' || {
    preflight_fail 'forge --version is not exactly forge 2.13.21.'
    return 1
  }
  preflight_assert_snapshot_hygiene "$preflight_umbrella"

  # Forge 2.13.21 drops reasoning effort for its generic OpenAI adapter.
  # Its Requesty wire adapter emits reasoning_effort. Override that adapter's
  # endpoint and credential source explicitly; no request goes to Requesty.
  if test "$IPE_LLM_PROFILE" = deepinfra-glm-5.3-flash-high; then
    python3 "$preflight_umbrella/tests/e2e-installation-procedure/lib/model-profile.py" seed-forge
  fi

  # Direct mode is the only v2.13.21 path that performs the documented
  # one-time environment credential migration. Empty stdin makes it fail
  # safely before provider/model selection; all output remains private.
  preflight_migration_root=$(mktemp -d /tmp/machtiani-forge-migration.XXXXXX)
  chmod 0700 "$preflight_migration_root"
  preflight_migration_stdout=$preflight_migration_root/stdout
  preflight_migration_stderr=$preflight_migration_root/stderr
  chmod 0600 "$preflight_migration_stdout" "$preflight_migration_stderr" 2>/dev/null || true
  forge </dev/null > "$preflight_migration_stdout" 2> "$preflight_migration_stderr" || true
  chmod 0600 "$preflight_migration_stdout" "$preflight_migration_stderr"
  preflight_assert_credentials

  forge config set model "$IPE_FORGE_PROVIDER_ID" "$IPE_LLM_MODEL" \
    > "$preflight_migration_stdout" 2> "$preflight_migration_stderr" || {
      preflight_fail 'Forge rejected the pinned model configuration.'
      return 1
    }
  forge config set reasoning-effort "$IPE_LLM_REASONING" \
    > "$preflight_migration_stdout" 2> "$preflight_migration_stderr" || {
      preflight_fail "Forge rejected $IPE_LLM_REASONING reasoning effort."
      return 1
    }

  preflight_assert_forge_config
  preflight_health_check
}
