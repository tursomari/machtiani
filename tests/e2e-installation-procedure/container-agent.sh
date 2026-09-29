#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'INSTALLATION PROCEDURE AGENT FAILURE: %s\n' "$*" >&2
  exit 1
}

umbrella=/workspace/machtiani
runtime_root=/run/machtiani-ipe-agent
completion_sentinel=$runtime_root/forge-complete
preflight_sentinel=$runtime_root/preflight-complete

prepare_checkout() {
  git config --global user.name 'Machtiani IPE Agent'
  git config --global user.email 'installation-procedure-agent@example.invalid'
  git config --global init.defaultBranch main

  git -C "$umbrella/machtiani-harness" init --quiet --initial-branch=main
  # The context contains only archived tracked files. Include all of them,
  # including tracked-but-ignored files, instead of maintaining a stale list.
  git -C "$umbrella/machtiani-harness" add -f -A
  git -C "$umbrella/machtiani-harness" commit --quiet -m 'test: seed post-clone Machtiani snapshot'
  agent_origin=$(mktemp -d /tmp/machtiani-agent-origin.XXXXXX)/origin.git
  git init --quiet --bare --initial-branch=main "$agent_origin"
  git -C "$umbrella/machtiani-harness" remote add origin "file://$agent_origin"
  git -C "$umbrella/machtiani-harness" push --quiet --set-upstream origin main

  git -C "$umbrella/dearmachine" init --quiet --initial-branch=main
  git -C "$umbrella/dearmachine" add -f -A
  git -C "$umbrella/dearmachine" commit --quiet -m 'test: seed post-clone dearmachine snapshot'

  git -C "$umbrella/dearmachine-concierge" init --quiet --initial-branch=main
  git -C "$umbrella/dearmachine-concierge" add -f -A
  git -C "$umbrella/dearmachine-concierge" commit --quiet -m 'test: seed post-clone installer snapshot'

  git -C "$umbrella" init --quiet --initial-branch=main
  git -C "$umbrella" add -f -A
  git -C "$umbrella" commit --quiet -m 'test: seed post-clone umbrella snapshot'
  umbrella_origin=$(mktemp -d /tmp/machtiani-umbrella-origin.XXXXXX)/origin.git
  git init --quiet --bare --initial-branch=main "$umbrella_origin"
  git -C "$umbrella" remote add origin "file://$umbrella_origin"
  git -C "$umbrella" push --quiet --set-upstream origin main
  git -C "$umbrella" submodule init --quiet
  test -z "$(git -C "$umbrella" status --porcelain --untracked-files=all)" || \
    fail 'reconstructed checkout is not clean'
}

assemble_forge_prompt() {
  prompt_asset=$umbrella/tests/e2e-installation-procedure/forge-follow-prompt.md
  runbook=$umbrella/docs/installation-procedure.md
  assembled_prompt=$runtime_root/forge-prompt.md
  python3 - "$prompt_asset" "$runbook" "$assembled_prompt" <<'PY'
from pathlib import Path
import os
import sys

asset_path, runbook_path, output_path = map(Path, sys.argv[1:])
asset = asset_path.read_bytes()
runbook = runbook_path.read_bytes()
marker = b"<!-- RUNBOOK_APPEND -->"
runtime_marker = b"<!-- RUNTIME_PREREQUISITES_APPEND -->"
if asset.count(marker) != 1:
    raise SystemExit("Forge prompt asset must contain exactly one runbook marker")
if asset.count(runtime_marker) != 1:
    raise SystemExit("Forge prompt asset must contain exactly one runtime-prerequisites marker")
receiver_id = os.environ.get("IPE_RECEIVER_INBOX_ID", "")
receiver_address = os.environ.get("IPE_RECEIVER_ADDRESS", "")
pair_email = os.environ.get("IPE_PAIR_EMAIL", "")
if not receiver_id or not receiver_address or not pair_email or any(char in receiver_id + receiver_address + pair_email for char in "\r\n\0"):
    raise SystemExit("temporary receiver prerequisites are missing or unsafe")
runtime = f'''## Runtime prerequisites (provided by the harness, not from the runbook)

- The isolated user home is `{os.environ["HOME"]}`. Preserve this `HOME` in every command; do not install into `/` or `/root`.
- The selected backend is Forge (`forge`, `/usr/local/bin/forge`), already authenticated for the selected model. Verify its executable as the procedure directs; do not install another backend.
- The dedicated temporary AgentMail inbox ID for this run is `{receiver_id}`.
- Its address is `{receiver_address}`.
- The dedicated temporary pair email address is `{pair_email}`.
- The authorized one-line AgentMail credential file is already present at `$HOME/.config/dearmachine/agentmail-api-key` with mode `0600`.
- The prerequisite private shared model profile is already present at `$HOME/.config/machtiani/model-profile.json`, referencing a private credential file. It selects `{os.environ["IPE_MACHTIANI_PROVIDER_ID"]}`, exact model `{os.environ["IPE_LLM_MODEL"]}`, and `{os.environ["IPE_LLM_REASONING"]}` reasoning. Use the documented model-host transport and preserve this profile; do not substitute a direct-provider configuration.
- The default entry-point repository is absent. Do not run `dearmachine init`;
  this run verifies that the documented `up --create` command initializes it.

- For this isolated test, use the published existing-inbox alternative: replace `--email '<your-email-address>' --new-inbox --transport agentmail` with `--email '{pair_email}' --inbox '{receiver_id}' --transport agentmail`. Do not create a third inbox and do not execute the optional second-pair example.
- This run exercises formatted attachment replies. `dearmachine setup-agents` initially writes `response_tier = "plain"`; after setup-agents completes and before starting the client, change that exact setting in `$HOME/.dearmachine/config/dearmachine.toml` to `response_tier = "formatted"`. Start the client with `--config "$HOME/.dearmachine/config/dearmachine.toml"` so the running process demonstrably loads that file. Do not change the configuration after starting the client.

These are runtime facts only. Derive every setup and execution step from the published Installation Procedure below.
'''.encode()
assembled = asset.replace(runtime_marker, runtime, 1).replace(marker, runbook, 1)
descriptor = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    os.write(descriptor, assembled)
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

assert_agent_postconditions() {
  dearmachine_config=$HOME/.dearmachine/config/dearmachine.toml
  project_marker=$umbrella/.machtiani/project.uuid
  entrypoint=$HOME/.dearmachine/entrypoint/main
  pidfile=$HOME/.dearmachine/run/dearmachine.pid
  readyfile=$HOME/.dearmachine/run/dearmachine.ready
  registry=$HOME/.dearmachine/pairs.toml
  client_log=$HOME/.dearmachine/log/dearmachine.log

  python3 "$umbrella/tests/e2e-installation-procedure/lib/model-profile.py" check
  python3 - "$dearmachine_config" <<'PYCONFIG'
from pathlib import Path
import sys
import tomllib

config = tomllib.loads(Path(sys.argv[1]).read_text())
if config != {"version": 1, "backends": ["forge"], "response_tier": "formatted"}:
    raise SystemExit("DearMachine configuration must contain version 1, the forge backend, and response_tier=formatted")
PYCONFIG

  preflight_assert_forge_config
  test -s "$project_marker" || fail 'Machtiani project marker is missing'
  project_json=$runtime_root/machtiani-project.json
  (cd "$umbrella" && machtiani project show --json) > "$project_json"
  chmod 0600 "$project_json"
  python3 - "$project_json" "$umbrella" <<'PY'
import json
from pathlib import Path
import sys

project = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if project.get("status") != "initialized":
    raise SystemExit("Machtiani project is not initialized")
if Path(project.get("project_root", "")).resolve() != Path(sys.argv[2]).resolve():
    raise SystemExit("Machtiani project root does not match the Installation Procedure checkout")
store = Path(project.get("store", ""))
if not store.is_dir():
    raise SystemExit("Machtiani project store is missing")
PY

  test -d "$entrypoint/.git" || fail 'DearMachine entry-point Git skeleton is missing'
  test -f "$entrypoint/README.md" || fail 'DearMachine entry-point README is missing'
  test -f "$entrypoint/process/README.md" || fail 'DearMachine process skeleton is missing'
  test "$(git -C "$entrypoint" rev-list --count HEAD)" -eq 2 || \
    fail 'DearMachine automatic entry-point bootstrap does not contain exactly two commits'
  test -f "$pidfile" && test ! -L "$pidfile" || fail 'DearMachine pidfile is missing or unsafe'
  test -f "$readyfile" && test ! -L "$readyfile" || fail 'DearMachine readiness file is missing or unsafe'
  read -r dearmachine_pid < "$pidfile"
  case "$dearmachine_pid" in
    ''|*[!0-9]*) fail 'DearMachine pidfile is invalid' ;;
  esac
  kill -0 "$dearmachine_pid" 2>/dev/null || fail 'Forge-started DearMachine process is not alive'
  test "$(sed -n '1p' "$readyfile")" = "$dearmachine_pid" || fail 'DearMachine readiness owner differs from daemon owner'
  tr '\0' ' ' < "/proc/$dearmachine_pid/cmdline" | grep -Fq dearmachine || \
    fail 'DearMachine pidfile does not identify a DearMachine process'
  pair_id=$(python3 - "$registry" "${IPE_RECEIVER_INBOX_ID:?}" "${IPE_RECEIVER_ADDRESS:?}" "${IPE_PAIR_EMAIL:?}" <<'PY'
from pathlib import Path
import sys
import tomllib

registry=tomllib.loads(Path(sys.argv[1]).read_text())
receiver_id,receiver_address,pair_email=sys.argv[2:]
if registry.get("version") != 2 or len(registry.get("pairs",[])) != 1 or len(registry.get("inboxes",[])) != 1:
    raise SystemExit("DearMachine registry does not contain exactly one version-2 pair and inbox")
pair=registry["pairs"][0]
inbox=registry["inboxes"][0]
if pair.get("user_email","").casefold()!=pair_email.casefold() or pair.get("inbox_id")!=inbox.get("id"):
    raise SystemExit("DearMachine pair registry identity is wrong")
if inbox.get("provider_id")!=receiver_id or inbox.get("address","").casefold()!=receiver_address.casefold() or inbox.get("transport")!="agentmail":
    raise SystemExit("DearMachine registered the wrong AgentMail inbox")
print(pair["id"])
PY
  )
  database=$HOME/.dearmachine/pairs/$pair_id/state/dearmachine.db
  runtime_config=$HOME/.dearmachine/config/runtime.toml
  test -f "$runtime_config" && test ! -L "$runtime_config" || fail 'DearMachine runtime profile is missing or unsafe'
  test "$(stat -c '%a' "$runtime_config")" = 600 || fail 'DearMachine runtime profile mode is not 0600'
  python3 - "$runtime_config" "$entrypoint" "$dearmachine_config" <<'PY'
from pathlib import Path
import sys
import tomllib

profile = tomllib.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
entrypoint = Path(sys.argv[2]).resolve()
config = Path(sys.argv[3]).resolve()
if profile.get("version") != 1:
    raise SystemExit("DearMachine runtime profile has the wrong version")
if Path(profile.get("project", "")).resolve() != entrypoint:
    raise SystemExit("DearMachine runtime profile did not retain the selected project")
if Path(profile.get("entry_point_repo", "")).resolve() != entrypoint:
    raise SystemExit("DearMachine runtime profile did not retain the selected entry point")
if Path(profile.get("device_config", "")).resolve() != config:
    raise SystemExit("DearMachine runtime profile did not retain the selected device configuration")
if profile.get("poll_interval") != "5s" or profile.get("concurrency") != 3:
    raise SystemExit("DearMachine runtime profile did not retain launch tuning")
if profile.get("magnifica_humanitas") is not False or profile.get("verbose") is not True:
    raise SystemExit("DearMachine runtime profile did not retain behavior flags or defaulted quotes on")
PY
  python3 - "/proc/$dearmachine_pid/cmdline" "$runtime_root/plain-up-restarted" <<'PY'
from pathlib import Path
import sys

argv = [part.decode(errors="replace") for part in Path(sys.argv[1]).read_bytes().split(b"\0") if part]
plain_restart = Path(sys.argv[2]).is_file()
def value(flag):
    if flag not in argv or argv.index(flag) + 1 >= len(argv):
        raise SystemExit(f"DearMachine command is missing {flag}")
    return argv[argv.index(flag) + 1]
if len(argv)<3 or argv[1:3] != ["up", "--foreground"]:
    raise SystemExit("DearMachine is not running through the foreground lifecycle child")
if plain_restart:
    if argv[3:]:
        raise SystemExit(f"plain-up lifecycle child unexpectedly received explicit run flags: {argv[3:]}")
    raise SystemExit(0)
expected_config = Path.home() / ".dearmachine" / "config" / "dearmachine.toml"
if Path(value("--config")).resolve() != expected_config.resolve():
    raise SystemExit("DearMachine command does not explicitly use the verified formatted-tier configuration")
if value("--poll-interval") != "5s":
    raise SystemExit("DearMachine poll interval is not the documented short interval")
if "--verbose" not in argv:
    raise SystemExit("DearMachine verbose logging is not enabled")
if "--magnifica-humanitas" in argv:
    raise SystemExit("DearMachine magnifica humanitas flag is enabled without an explicit opt-in")
for retired in ("--inbox-id","--db","--pidfile","--allow"):
    if retired in argv:
        raise SystemExit(f"DearMachine command still uses retired flag {retired}")
PY
  test -f "$database" && test ! -L "$database" || fail 'DearMachine private database is missing or unsafe'
  test -f "$client_log" && test ! -L "$client_log" || fail 'DearMachine private log is missing or unsafe'
  test "$(stat -c '%a' "$client_log")" = 600 || fail 'DearMachine private log mode is not 0600'
  grep -Fq 'poll:' "$client_log" || fail 'DearMachine first poll is not recorded in the private log'
  if grep -Eiq 'auth(entication|orization)?[^[:alnum:]]*(error|fail)|invalid api key|configuration error' "$client_log"; then
    fail 'DearMachine private log contains an authentication or configuration error'
  fi
}

restart_with_plain_up() {
  export AGENTMAIL_API_KEY_FILE=$HOME/.config/dearmachine/agentmail-api-key
  dearmachine down
  unrelated=$(mktemp -d /tmp/machtiani-plain-up.XXXXXX)
  (cd "$unrelated" && dearmachine up)
  printf 'ok\n' > "$runtime_root/plain-up-restarted"
  chmod 0600 "$runtime_root/plain-up-restarted"
}

ipe_run_forge_follow() {
  prepare_checkout
  assemble_forge_prompt
  forge_stdout=$runtime_root/forge.stdout
  forge_stderr=$runtime_root/forge.stderr
  : > "$forge_stdout"
  : > "$forge_stderr"
  chmod 0600 "$forge_stdout" "$forge_stderr"

  set +e
  # Nix realization can exceed Forge's five-minute default tool deadline.
  # Keep each build bounded without killing it halfway through installation.
  FORGE_TOOL_TIMEOUT_SECS=1800 \
  timeout --signal=TERM --kill-after=10s 60m \
    forge --directory "$umbrella" \
    < "$runtime_root/forge-prompt.md" > "$forge_stdout" 2> "$forge_stderr"
  forge_status=$?
  set -e
  printf '%s\n' "$forge_status" > "$runtime_root/forge-status"
  chmod 0600 "$runtime_root/forge-status"

  set +e
  (
    set -Ee
    trap 'printf "Postcondition failed at line %s (status %s)\n" "$LINENO" "$?" >&2' ERR
    assert_agent_postconditions
    restart_with_plain_up
    assert_agent_postconditions
  ) > "$runtime_root/postconditions.log" 2>&1
  postcondition_status=$?
  set -e
  printf '%s\n' "$postcondition_status" > "$runtime_root/postcondition-status"
  chmod 0600 "$runtime_root/postcondition-status"

  test "$forge_status" -eq 0 || fail "Forge follow process exited with status $forge_status"
  test "$postcondition_status" -eq 0 || fail 'agent follow postconditions failed'
}

run_worker() {
  unset MACHTIANI_SESSION_ID MACHTIANI_SESSION_TEMP_ROOT MINISWE_FINAL_DIR
  unset TMPDIR TEMPDIR TMP TEMP
  export HOME
  HOME=$(mktemp -d /tmp/machtiani-agent-home.XXXXXX)
  chmod 0700 "$HOME"
  export DEARMACHINE_HOME="$HOME/.dearmachine"
  export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/root/.nix-profile/bin:/usr/local/bin:$PATH"
  export MACHTIANI_THEME=none
  export MACHTIANI_GLYPHS=ascii
  export FORGE_UPDATES__FREQUENCY=never
  export FORGE_UPDATES__AUTO_UPDATE=false
  umask 077

  test ! -e "$HOME/.dearmachine/entrypoint/main" || \
    fail 'default entry point exists before the automatic-initialization test'

  test -n "${!IPE_LLM_CREDENTIAL_ENV:-}" || fail "$IPE_LLM_CREDENTIAL_ENV is not set"
  test -n "${AGENTMAIL_API_KEY:-}" || fail 'AGENTMAIL_API_KEY is not set'
  test -n "${IPE_RECEIVER_INBOX_ID:-}" || fail 'IPE_RECEIVER_INBOX_ID is not set'
  test -n "${IPE_RECEIVER_ADDRESS:-}" || fail 'IPE_RECEIVER_ADDRESS is not set'
  test -n "${IPE_PAIR_EMAIL:-}" || fail 'IPE_PAIR_EMAIL is not set'
  printf '%s\n' "$HOME" > "$runtime_root/home-path"
  chmod 0600 "$runtime_root/home-path"

  agentmail_key_file=$HOME/.config/dearmachine/agentmail-api-key
  mkdir -p "$(dirname -- "$agentmail_key_file")"
  printf '%s\n' "$AGENTMAIL_API_KEY" > "$agentmail_key_file"
  chmod 0600 "$agentmail_key_file"
  unset AGENTMAIL_API_KEY
  python3 "$umbrella/tests/e2e-installation-procedure/lib/model-profile.py" seed

  # shellcheck source=lib/preflight.sh
  source "$umbrella/tests/e2e-installation-procedure/lib/preflight.sh"
  ipe_agent_preflight "$umbrella"
  printf 'ok\n' > "$preflight_sentinel"
  chmod 0600 "$preflight_sentinel"
  ipe_run_forge_follow
}

supervise() {
  test "$$" -eq 1 || fail 'container-agent.sh must run as container PID 1'
  mkdir -p "$runtime_root"
  chmod 0700 "$runtime_root"
  worker_pid=

  terminate() {
    if test -n "${worker_pid:-}" && kill -0 "$worker_pid" 2>/dev/null; then
      kill -TERM "$worker_pid" 2>/dev/null || true
      wait "$worker_pid" 2>/dev/null || true
    fi
    exit 143
  }
  trap terminate HUP INT TERM

  nix --extra-experimental-features 'nix-command flakes' \
    develop path:/workspace/machtiani/machtiani-harness#smoke -c \
    bash "$umbrella/tests/e2e-installation-procedure/container-agent.sh" --worker &
  worker_pid=$!
  set +e
  wait "$worker_pid"
  worker_status=$?
  set -e
  worker_pid=

  completion_tmp=$runtime_root/.forge-complete.tmp
  printf 'forge_exit_status=%s\n' "$worker_status" > "$completion_tmp"
  chmod 0600 "$completion_tmp"
  mv -- "$completion_tmp" "$completion_sentinel"

  # Forge may deliberately leave DearMachine running. PID 1 records completion
  # and remains a passive reaper; it never starts or rescues that client.
  while :; do
    wait -n 2>/dev/null || sleep 1
  done
}

case "${1:-}" in
  --worker) run_worker ;;
  --postconditions-worker)
    HOME=$(sed -n '1p' "$runtime_root/home-path")
    export HOME
    export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/root/.nix-profile/bin:/usr/local/bin:$PATH"
    source "$umbrella/tests/e2e-installation-procedure/lib/preflight.sh"
    assert_agent_postconditions
    ;;
  --postconditions)
    exec nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c \
      bash "$umbrella/tests/e2e-installation-procedure/container-agent.sh" --postconditions-worker
    ;;
  '') supervise ;;
  *) fail 'usage: container-agent.sh [--worker|--postconditions]' ;;
esac
