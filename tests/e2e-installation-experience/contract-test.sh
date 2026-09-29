#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'IXE contract test failure: %s\n' "$*" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)

"$repo_root/tests/install-prompt-test.sh"
python3 "$script_dir/verification-selection-test.py"
python3 "$repo_root/tests/curl-bootstrap-test.py"
python3 "$script_dir/curl-bundle-test.py"
python3 "$script_dir/backend-fixture-test.py"
grep -F 'for tool in nix-store gzip tar' "$script_dir/curl-mode.sh" >/dev/null ||
  fail 'curl mode must expose the existing Nix and archive tools to the SSH user'

help=$($script_dir/run.sh --help)
for required in \
  'Installation Experience Evaluation' \
  '--agent NAME' \
  '--installer-root P' \
  '--curl-bundle P' \
  '--cached-image I' \
  '--backend-fixture B' \
  '--self-test' \
  '--keep-container'; do
  grep -F -- "$required" <<<"$help" >/dev/null || fail "help is missing $required"
done
grep -F -- 'forge 2.13.21' "$script_dir/backend-fixture.py" >/dev/null || \
  fail 'fixture preparation must verify the user-owned Forge version'
grep -F -- '--build-arg "BACKEND_FIXTURE=$backend_fixture"' "$script_dir/run.sh" >/dev/null ||
  fail 'uncached no-backend images must skip the Forge download'
fixture_line=$(grep -nF 'python3 /usr/local/libexec/ixe-backend-fixture.py' "$script_dir/run.sh" | cut -d: -f1)
prepare_line=$(grep -nF 'docker exec "$container_id" /usr/local/libexec/ixe-prepare' "$script_dir/run.sh" | cut -d: -f1)
test "$fixture_line" -lt "$prepare_line" || fail 'backend fixture verification must precede SSH readiness'

adapter=$script_dir/agents/codex.sh
for hook in ixe_agent_validate_host ixe_agent_seed ixe_agent_check_login ixe_agent_collect; do
  grep -F -- "$hook" "$adapter" >/dev/null || fail "Codex adapter is missing $hook"
done

omp_adapter=$script_dir/agents/omp.sh
for hook in ixe_agent_validate_host ixe_agent_seed ixe_agent_check_login ixe_agent_collect; do
  grep -F -- "$hook" "$omp_adapter" >/dev/null || fail "OMP adapter is missing $hook"
done
grep -F -- 'PI_CODING_AGENT_DIR=/run/ixe/agent-state/omp' "$omp_adapter" >/dev/null ||
  fail 'OMP authentication and sessions must use isolated IXE state'
! grep -F -- '/usr/local/bin/omp' "$omp_adapter" >/dev/null ||
  fail 'the OMP conductor must not appear on the simulated user PATH'

forge_adapter=$script_dir/agents/forge.sh
for hook in ixe_agent_validate_host ixe_agent_seed ixe_agent_check_login ixe_agent_collect; do
  grep -F -- "$hook" "$forge_adapter" >/dev/null || fail "Forge adapter is missing $hook"
done
grep -F -- 'IXE_FORGE_OPENROUTER_KEY_FILE' "$forge_adapter" >/dev/null ||
  fail 'Forge IXE must receive its OpenRouter credential through an explicit private file'

installer_adapter=$script_dir/agents/machtiani-installer.sh
for hook in ixe_agent_validate_host ixe_agent_seed ixe_agent_check_login ixe_agent_collect; do
  grep -F -- "$hook" "$installer_adapter" >/dev/null || fail "Machtiani Installer adapter is missing $hook"
done
! grep -F -- 'IXE_INSTALLER_OPENROUTER_KEY_FILE' "$installer_adapter" >/dev/null ||
  fail 'Machtiani Installer IXE must let the wizard own provider authentication'
grep -F -- 'path:/opt/ixe/build/dearmachine-concierge' "$script_dir/Dockerfile" >/dev/null ||
  fail 'the IXE image must build the selected pinned Machtiani Installer runtime'
installer_copy_line=$(grep -nF -- 'COPY dearmachine-concierge ' "$script_dir/Dockerfile" | cut -d: -f1)
installer_dependencies_line=$(grep -nF -- 'path:/opt/ixe/build/machtiani-installer-dependencies#build-dependencies' "$script_dir/Dockerfile" | cut -d: -f1)
forge_fixture_line=$(grep -nF -- 'forge_target=x86_64-unknown-linux-musl' "$script_dir/Dockerfile" | cut -d: -f1)
glibc_fixture_line=$(grep -nF -- 'ixe-glibc' "$script_dir/Dockerfile" | cut -d: -f1)
test "$forge_fixture_line" -lt "$installer_copy_line" && test "$glibc_fixture_line" -lt "$installer_copy_line" ||
  fail 'changing installer source must not invalidate the neutral IXE and backend fixture layers'
test "$installer_dependencies_line" -lt "$installer_copy_line" ||
  fail 'changing installer source must not invalidate the installer dependency layer'
grep -F -- 'COPY dearmachine-concierge/patches ' "$script_dir/Dockerfile" >/dev/null ||
  fail 'the installer dependency layer is missing its pinned pnpm patches'
for installer_manifest in app backend-adapter credential-adapter dsh-adapter environment-adapter model-host product-adapter tui workflow; do
  grep -F -- "dearmachine-concierge/packages/$installer_manifest/package.json" "$script_dir/Dockerfile" >/dev/null ||
    fail "the installer dependency layer is missing the $installer_manifest workspace manifest"
done
runtime_script_copy_count=$(grep -c '^COPY tests/e2e-installation-experience/.*\.sh ' "$script_dir/Dockerfile")
test "$runtime_script_copy_count" -eq 1 ||
  fail 'IXE runtime scripts must share one image layer so the legacy builder stays below its depth limit'
grep -F -- '--build-arg "TARGETARCH=$docker_target_arch"' "$script_dir/run.sh" >/dev/null ||
  fail 'the IXE runner must pass TARGETARCH explicitly for legacy Docker builds'

installer_launcher=$script_dir/agents/machtiani-installer-launch.sh
grep -F -- '/nix/var/nix/profiles/ixe-installer/bin/dearmachine' "$installer_launcher" >/dev/null ||
  fail 'the IXE must launch the unified dearmachine command from its isolated Nix runtime'
grep -F -- 'DEARMACHINE_SOURCE_ROOT="$HOME/machtiani"' "$installer_launcher" >/dev/null ||
  fail 'the unified command must operate on the disposable source snapshot'
! grep -F -- '--install' "$installer_launcher" >/dev/null ||
  fail 'the IXE must exercise bare dearmachine routing rather than force installer mode'
! grep -F -- 'OPENROUTER_API_KEY=' "$installer_launcher" >/dev/null ||
  fail 'the Machtiani Installer launcher must not expose its conductor credential to DSH tools'
! grep -F -- '.credentials.yaml' "$installer_launcher" >/dev/null ||
  fail 'the Machtiani Installer launcher must not require a provider before the wizard'

codex_launcher=$script_dir/agents/codex-launch.sh
grep -F -- '--model gpt-5.6-luna' "$codex_launcher" >/dev/null || \
  fail 'Codex IXE must use gpt-5.6-luna'
grep -F -- '-c '\''model_reasoning_effort="high"'\''' "$codex_launcher" >/dev/null || \
  fail 'Codex IXE must use high reasoning effort'
! grep -F -- 'gpt-5.3-codex-spark' "$codex_launcher" >/dev/null || \
  fail 'Codex IXE still selects the retired Spark fixture model'

omp_launcher=$script_dir/agents/omp-launch.sh
grep -F -- 'export PI_CODING_AGENT_DIR=/run/ixe/agent-state/omp' "$omp_launcher" >/dev/null ||
  fail 'OMP IXE must define its isolated state before reading conductor settings'
grep -F -- 'model=$(<"$PI_CODING_AGENT_DIR/ixe-model")' "$omp_launcher" >/dev/null ||
  fail 'OMP IXE must load its selected conductor model from isolated state'
grep -F -- '--model "$model"' "$omp_launcher" >/dev/null ||
  fail 'OMP IXE must use its selected conductor model'
grep -F -- '--thinking medium' "$omp_launcher" >/dev/null ||
  fail 'OMP IXE must use medium reasoning'
grep -F -- 'IXE_OMP_OPENROUTER_KEY_FILE' "$omp_adapter" >/dev/null ||
  fail 'OMP IXE must accept an explicit private OpenRouter credential file'
grep -F -- 'IXE_OMP_MODEL' "$omp_adapter" >/dev/null ||
  fail 'OMP IXE must accept an explicit conductor model'
! grep -F -- 'OPENROUTER_API_KEY' "$omp_launcher" >/dev/null ||
  fail 'OMP launcher must not expose the conductor credential to installer tools'

forge_launcher=$script_dir/agents/forge-launch.sh
forge_interact=$script_dir/agents/forge-interact.exp
grep -F -- 'minimax/minimax-m3:free' "$script_dir/agents/forge-seed.sh" >/dev/null ||
  fail 'Forge IXE must select the requested OpenRouter MiniMax model'
grep -F -- 'open_router' "$script_dir/agents/forge-seed.sh" >/dev/null ||
  fail 'Forge IXE must select Forge’s OpenRouter provider ID'
grep -F -- 'unset OPENROUTER_API_KEY' "$script_dir/agents/forge-seed.sh" >/dev/null ||
  fail 'Forge IXE must clear its migration credential after private seeding'
grep -F -- 'unlink "$key_file"' "$script_dir/agents/forge-seed.sh" >/dev/null ||
  fail 'Forge IXE must remove its transient credential file before launch'
! grep -F -- 'OPENROUTER_API_KEY' "$forge_launcher" >/dev/null ||
  fail 'Forge launcher must not expose the conductor credential to installer tools'
grep -F -- 'exec expect /usr/local/libexec/ixe-forge-interact' \
  "$forge_launcher" >/dev/null ||
  fail 'Forge IXE must hand one interactive process to the human'
grep -F -- 'spawn -noecho forge --directory "$env(HOME)/machtiani"' \
  "$forge_interact" >/dev/null ||
  fail 'Forge IXE must start in native interactive mode'
grep -F -- 'set install_prompt "Follow @\[$install_name\] exactly."' \
  "$forge_interact" >/dev/null ||
  fail 'Forge IXE must attach INSTALL.md as one initial prompt'
! grep -E -- 'read \$prompt_file|\\033\\\[200~|\\033\\\[201~' \
  "$forge_interact" >/dev/null ||
  fail 'Forge IXE must not paste INSTALL.md into the interactive input queue'
grep -F -- 'interact' "$forge_interact" >/dev/null ||
  fail 'Forge IXE must hand the live Forge terminal to the human'
! grep -E -- '--prompt|conversation (resume|new)|--conversation-id' \
  "$forge_launcher" "$forge_interact" >/dev/null ||
  fail 'Forge IXE must not use a one-shot or resumed conversation'

for path in \
  "$script_dir/Dockerfile" \
  "$script_dir/container-entrypoint.sh" \
  "$script_dir/container-prepare.sh" \
  "$script_dir/dearmachine-entrypoint.sh" \
  "$script_dir/run-install-evaluation.sh" \
  "$script_dir/verify-installation.sh" \
  "$script_dir/agents/codex-launch.sh" \
  "$script_dir/agents/omp-launch.sh" \
  "$script_dir/agents/omp-exec.sh" \
  "$script_dir/agents/machtiani-installer-launch.sh"; do
  test -f "$path" || fail "missing ${path##*/}"
done

for path in \
  "$script_dir/agents/forge.sh" \
  "$script_dir/agents/forge-seed.sh" \
  "$script_dir/agents/forge-launch.sh" \
  "$script_dir/agents/forge-interact.exp"; do
  test -f "$path" || fail "missing ${path##*/}"
done

! grep -Ei 'COPY .*\.(codex|ssh|secrets)|ADD .*\.(codex|ssh|secrets)' \
  "$script_dir/Dockerfile" >/dev/null || \
  fail 'Dockerfile may not bake credentials or agent state into an image layer'
! grep -E -- '--volume|--mount[= ]type=bind' "$script_dir/run.sh" >/dev/null || \
  fail 'IXE must copy disposable snapshots, not bind-mount host state'
main_tools=$(grep 'name = "machtiani-ixe-tools"' "$script_dir/Dockerfile")
! grep -E -- 'p\.git([[:space:]]|-[^[:space:]]+)|p\.micro([[:space:]]|$)' <<<"$main_tools" >/dev/null || \
  fail 'the IXE installer PATH must begin without Git or micro'
for baseline_tool in 'p.cacert' 'p.curl' 'p.expect' 'p.python3'; do
  grep -F -- "$baseline_tool" <<<"$main_tools" >/dev/null || \
    fail "the IXE installer profile is missing $baseline_tool"
done
grep -F -- '/nix/var/nix/profiles/ixe-glibc' "$script_dir/Dockerfile" >/dev/null ||
  fail 'the IXE is missing its direct glibc runtime profile'
grep -F -- 'in p.glibc.out' "$script_dir/Dockerfile" >/dev/null ||
  fail 'the IXE glibc runtime must come from the pinned harness nixpkgs input'
grep -F -- 'ENV SSL_CERT_FILE="/nix/var/nix/profiles/ixe/etc/ssl/certs/ca-bundle.crt"' \
  "$script_dir/Dockerfile" >/dev/null || \
  fail 'the IXE must select its own HTTPS certificate bundle'
grep -F -- 'test -r "$SSL_CERT_FILE"' "$script_dir/container-prepare.sh" >/dev/null || \
  fail 'container preparation must verify the IXE-owned HTTPS certificate bundle'
grep -F -- 'curl --version' "$script_dir/container-prepare.sh" >/dev/null || \
  fail 'container preparation must verify curl in the installer environment'
for system_ca_path in \
  '/etc/ssl/cert.pem' \
  '/etc/ssl/certs/ca-certificates.crt'; do
  grep -F -- "$system_ca_path" "$script_dir/Dockerfile" >/dev/null || \
    fail "the IXE is missing conventional CA path $system_ca_path"
  grep -F -- "$system_ca_path" "$script_dir/container-prepare.sh" >/dev/null || \
    fail "container preparation does not verify $system_ca_path"
done
grep -F -- '/nix/var/nix/profiles/ixe-prep' "$script_dir/Dockerfile" >/dev/null || \
  fail 'the IXE fixture needs a private preparation-only Git profile'
grep -F -- 'IXE_PREP_GIT' "$script_dir/container-prepare.sh" >/dev/null || \
  fail 'container preparation must use the private Git executable'
grep -F -- 'install -d -o installer -g installer -m 0755 /opt/ixe/agents' \
  "$script_dir/container-prepare.sh" >/dev/null || \
  fail 'shared preparation must create the adapter executable directory'
for forge_contract in \
  'https://github.com/tailcallhq/forgecode/releases/download/v2.13.21/' \
  '4ae6d86cdd001e649e1b435d99243d7249d169e30b24529e350f9dfec798f29a' \
  '983652eb26b1e4900633877bc2a1a0e5af788196969bc4b18e184ad3d50cd254' \
  'forge 2.13.21'; do
  grep -F -- "$forge_contract" "$script_dir/Dockerfile" >/dev/null || \
    fail "the IXE fixture is missing pinned Forge contract: $forge_contract"
done
grep -F -- 'install -d -m 0755 /usr/local/bin' "$script_dir/Dockerfile" >/dev/null || \
  fail 'the minimal IXE base must create the Forge installation directory'
for runtime_path in \
  "$script_dir/container-entrypoint.sh" \
  "$script_dir/container-prepare.sh" \
  "$script_dir/run-install-evaluation.sh" \
  "$script_dir/verify-installation.sh" \
  "$script_dir/agents/codex-launch.sh" \
  "$script_dir/agents/codex.sh" \
  "$script_dir/agents/omp-launch.sh" \
  "$script_dir/agents/omp-exec.sh" \
  "$script_dir/agents/omp.sh" \
  "$script_dir/agents/forge-launch.sh" \
  "$script_dir/agents/forge-interact.exp" \
  "$script_dir/agents/forge-seed.sh" \
  "$script_dir/agents/forge.sh" \
  "$script_dir/agents/machtiani-installer-launch.sh" \
  "$script_dir/agents/machtiani-installer.sh"; do
  ! grep -F -- '/nix/var/nix/profiles/default/bin' "$runtime_path" >/dev/null || \
    fail "the installer runtime leaks base-profile tools through ${runtime_path##*/}"
done

grep -F -- 'agent-manager backend list' "$script_dir/verify-installation.sh" >/dev/null || \
  fail 'IXE verification must resolve the backend selected during installation'
grep -F -- 'agent-manager backend health "$selected_backend"' \
  "$script_dir/verify-installation.sh" >/dev/null || \
  fail 'IXE verification must health-check the selected backend'
! grep -F -- 'backends = ["forge"]' "$script_dir/verify-installation.sh" >/dev/null || \
  fail 'IXE verification must not require the Forge backend'
grep -F -- 'expected_dearmachine="$HOME/.local/bin/dearmachine"' \
  "$script_dir/verify-installation.sh" >/dev/null || \
  fail 'IXE verification must require the installed native dearmachine command'

grep -F -- 'runtime-scripts/dearmachine-entrypoint.sh /usr/local/bin/dearmachine' \
  "$script_dir/Dockerfile" >/dev/null || \
  fail 'the IXE must expose dearmachine as its human-facing entry command'
grep -F -- 'Run: dearmachine' "$script_dir/run.sh" >/dev/null || \
  fail 'the host runner must tell the human to launch dearmachine'
grep -F -- '  dearmachine' "$script_dir/container-entrypoint.sh" >/dev/null || \
  fail 'the IXE MOTD must tell the human to launch dearmachine'

! grep -F -- 'ixe-credential-exec /usr/local/libexec/ixe-agent-launch' \
  "$script_dir/run-install-evaluation.sh" >/dev/null || \
  fail 'the installation agent must not inherit the IXE live-install credentials'
! grep -F -- '/run/ixe/install.env' "$script_dir/run-install-evaluation.sh" >/dev/null || \
  fail 'the interactive installation session must not receive an ambient credential file'
! grep -F -- '/run/ixe/install.env' "$script_dir/run.sh" >/dev/null || \
  fail 'the host runner must not copy live-install credentials into the IXE container'
! grep -F -- 'credential-exec.sh' "$script_dir/Dockerfile" >/dev/null || \
  fail 'the IXE image must not include an ambient installation credential loader'

# Exercise the session lifecycle with isolated command stubs and a real TTY.
# Never run the installer, verification, or host shell startup files here.
python3 "$script_dir/session-contract-test.py"
for path in "$script_dir/run.sh" "$script_dir/container-entrypoint.sh"; do
  grep -F -- 'post-install' "$path" >/dev/null ||
    fail "${path##*/} must describe post-install exploration"
  grep -F -- 'Ctrl+D' "$path" >/dev/null ||
    fail "${path##*/} must explain how the operator finishes the evaluation"
done

python3 "$script_dir/macos-test.py"

printf 'IXE contract test passed\n'
