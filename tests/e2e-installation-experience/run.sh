#!/usr/bin/env bash
set -euo pipefail

# macOS uses an existing SSH guest; it must never enter the Linux Docker path.
if test "${1:-}" = --macos; then
  shift
  exec python3 "$(dirname "$0")/macos.py" "$@"
fi

fail() {
  printf 'INSTALLATION EXPERIENCE EVALUATION FAILURE: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Machtiani Installation Experience Evaluation (IXE)

usage: tests/e2e-installation-experience/run.sh [options]
       tests/e2e-installation-experience/run.sh --macos {prepare,connect,collect,scan,stop,cleanup} --help

  --agent NAME       Agent adapter to evaluate (default: machtiani-installer)
  --installer-root P Clean installer worktree to evaluate before landing
  --curl-bundle P    Local distribution bundle; use the curl bootstrap entry
  --standard-bundle P Portable Standard download; use a cached no-Nix IXE image
  --forge-binary P   Existing pinned Forge fixture for Standard IXE
  --backend-fixture B Preinstalled backend: forge (default) or none
  --cached-image I   Existing neutral IXE image (required with --curl-bundle)
  --secrets-file P   Private install credentials (default: .secrets)
  --keep-container   Keep the stopped container for manual diagnosis
  --self-test        Validate the harness without credentials or Docker mutation
  --help             Show this help

The live run creates an isolated container, copies disposable source and agent
state snapshots into it, then prints the localhost SSH command for the human
operator. After the installation agent exits and verification passes, a
post-install exploration shell opens: run dearmachine to try the concierge.
Type exit (or Ctrl+D) in that shell to finish the evaluation and collect artifacts.
If installation or verification fails, the evaluation finishes immediately.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
agent_name=machtiani-installer
installer_source_root=
curl_bundle=
standard_bundle=false
forge_binary=
backend_fixture=forge
cached_image=
secrets_file=$repo_root/.secrets
keep_container=false
self_test=false

while test "$#" -gt 0; do
  case "$1" in
    --agent)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      agent_name=$2
      shift 2
      ;;
    --installer-root)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      installer_source_root=$2
      shift 2
      ;;
    --secrets-file)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      secrets_file=$2
      shift 2
      ;;
    --curl-bundle|--standard-bundle)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      test "$1" != --standard-bundle || standard_bundle=true
      curl_bundle=$(realpath "$2")
      shift 2
      ;;
    --forge-binary)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      forge_binary=$(realpath "$2")
      shift 2
      ;;
    --backend-fixture)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      backend_fixture=$2
      shift 2
      ;;
    --cached-image)
      test "$#" -ge 2 || { usage >&2; exit 2; }
      cached_image=$2
      shift 2
      ;;
    --keep-container) keep_container=true; shift ;;
    --self-test) self_test=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$backend_fixture" in forge|none) ;; *) fail '--backend-fixture must be forge or none' ;; esac
if test "$backend_fixture" = none; then
  test "$agent_name" = machtiani-installer || fail '--backend-fixture none requires the first-party installer'
  test -z "$forge_binary" || fail '--forge-binary conflicts with --backend-fixture none'
fi

if test -n "$curl_bundle$cached_image"; then
  test -n "$curl_bundle" && test -n "$cached_image" || fail '--curl-bundle and --cached-image must be supplied together'
  test "$agent_name" = machtiani-installer || fail 'curl mode evaluates only the first-party installer'
  source "$script_dir/curl-mode.sh"
  if test "$standard_bundle" = true; then source "$script_dir/standard-mode.sh"; fi
fi

if test -z "$installer_source_root"; then
  installer_source_root=$repo_root/dearmachine-concierge
fi
case "$installer_source_root" in /*) ;; *) fail '--installer-root must be an absolute path' ;; esac
installer_source_root=$(realpath "$installer_source_root")
test "$(git -C "$installer_source_root" rev-parse --show-toplevel)" = "$installer_source_root" || \
  fail '--installer-root must name a Git worktree root'
test -z "$(git -C "$installer_source_root" status --porcelain=v2 --untracked-files=all)" || \
  fail 'installer source worktree is not clean'
IXE_INSTALLER_SOURCE_ROOT=$installer_source_root
export IXE_INSTALLER_SOURCE_ROOT

case "$agent_name" in
  ''|*[!a-z0-9_-]*) fail 'agent name may contain only lowercase letters, digits, underscore, and hyphen' ;;
esac
agent_adapter=$script_dir/agents/$agent_name.sh
test -f "$agent_adapter" || fail "unknown agent adapter: $agent_name"
# shellcheck disable=SC1090
source "$agent_adapter"

for hook in ixe_agent_validate_host ixe_agent_seed ixe_agent_check_login ixe_agent_collect; do
  declare -F "$hook" >/dev/null || fail "$agent_name adapter is missing $hook"
done

for command_name in git python3 tar; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

assert_source_checkout() {
  test "$(git -C "$repo_root" rev-parse --show-toplevel)" = "$repo_root" || \
    fail 'runner is not inside the expected umbrella worktree'
  for component in machtiani-harness dearmachine dearmachine-concierge; do
    expected=$(git -C "$repo_root" rev-parse "HEAD:$component")
    actual=$(git -C "$repo_root/$component" rev-parse HEAD)
    test "$actual" = "$expected" || fail "$component is not at the recorded umbrella gitlink"
  done
}

assert_source_checkout
test -f "$repo_root/INSTALL.md" || fail 'INSTALL.md is missing'
test -f "$repo_root/docs/installation-procedure.md" || fail 'canonical Installation Procedure is missing'

if test "$self_test" = true; then
  test -z "$(git -C "$repo_root" ls-files INSTALL.md docs/installation-procedure.md --deleted)" || \
    fail 'required install documents are deleted from the index'
  ixe_agent_validate_host
  "$script_dir/contract-test.sh"
  printf 'Installation Experience Evaluation self-test passed for %s\n' "$IXE_AGENT_LABEL"
  exit 0
fi

for command_name in docker flock ssh ssh-keygen; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
test -z "$(git -C "$repo_root" status --porcelain=v2 --untracked-files=all --ignore-submodules=none)" || \
  fail 'umbrella or submodule worktree is not clean; refusing a live IXE'

# shellcheck source=../e2e-installation-procedure/lib/secrets.sh
source "$repo_root/tests/e2e-installation-procedure/lib/secrets.sh"
secrets_load "$secrets_file"
ixe_agent_validate_host

if test -n "$curl_bundle"; then
  ixe_curl_validate
  # Resolve locally and pin the image ID; never pull or rebuild this mode.
  cached_image=$(docker image inspect --format '{{.Id}}' "$cached_image")
fi

run_id=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(6))
PY
)
container_name=machtiani-ixe-$agent_name-$run_id
image_name=machtiani-ixe-environment:local
runtime_root=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-ixe-$run_id.XXXXXX")
artifacts_parent=${XDG_STATE_HOME:-$HOME/.local/state}/machtiani/ixe
artifact_dir=$artifacts_parent/$run_id-$agent_name
lock_file=${TMPDIR:-/tmp}/machtiani-ixe-$(id -u).lock
test -z "$curl_bundle" || lock_file=${TMPDIR:-/tmp}/machtiani-ixe-curl-$(id -u).lock
container_id=
completion_seen=false

umask 077
install -d -m 0700 "$artifacts_parent" "$artifact_dir"
: > "$lock_file"
chmod 0600 "$lock_file"
exec 9<> "$lock_file"
flock -n 9 || fail 'another live IXE is already running for this user'

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if test -n "${container_id:-}"; then
    if test "$keep_container" = true; then
      docker stop "$container_id" >/dev/null 2>&1 || true
      printf 'Stopped diagnostic container retained: %s\n' "$container_name" >&2
    else
      docker rm -f "$container_id" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf -- "$runtime_root"
  secrets_clear
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

context_dir=$runtime_root/context
install -d -m 0700 "$context_dir" "$context_dir/machtiani-harness" "$context_dir/dearmachine" "$context_dir/dearmachine-concierge"
git -C "$repo_root" archive HEAD | tar -x -C "$context_dir"
git -C "$repo_root/machtiani-harness" archive HEAD | tar -x -C "$context_dir/machtiani-harness"
git -C "$repo_root/dearmachine" archive HEAD | tar -x -C "$context_dir/dearmachine"
git -C "$installer_source_root" archive HEAD | tar -x -C "$context_dir/dearmachine-concierge"

forbidden=$(find "$context_dir" \
  \( -name .git -o -name .ssh -o -name .secrets -o -name '.env*' -o -name .codex -o -name .omp \) \
  -print -quit)
test -z "$forbidden" || fail "source snapshot contains forbidden host state: $forbidden"

printf '==> Preparing the neutral IXE environment...\n'
if test -n "$curl_bundle"; then
  image_name=$cached_image
  printf 'Reusing the existing IXE image and local runtime cache; no build or pull.\n'
else
case "$(docker version --format '{{.Server.Arch}}')" in
  amd64|x86_64) docker_target_arch=amd64 ;;
  arm64|aarch64) docker_target_arch=arm64 ;;
  *) fail 'Docker server architecture is not supported by the IXE image' ;;
esac
docker build --file "$context_dir/tests/e2e-installation-experience/Dockerfile" \
  --build-arg "TARGETARCH=$docker_target_arch" \
  --build-arg "BACKEND_FIXTURE=$backend_fixture" \
  --tag "$image_name" "$context_dir"
fi

ssh_key=$runtime_root/operator-key
ssh-keygen -q -t ed25519 -N '' -C "machtiani-ixe-$run_id" -f "$ssh_key"

container_id=$(docker create \
  --name "$container_name" \
  --label "to.machtiani.ixe.run=$run_id" \
  --publish 127.0.0.1::22 \
  "$image_name")
test -n "$container_id" || fail 'Docker did not return a container ID'

# Refresh the small runtime scripts in the stopped container, preserving the
# cached base without adding image layers. Explicit modes match the Dockerfile.
for mapping in 'container-entrypoint.sh:libexec/ixe-entrypoint' 'container-prepare.sh:libexec/ixe-prepare' \
  'dearmachine-entrypoint.sh:bin/dearmachine' 'run-install-evaluation.sh:bin/run-install-evaluation' \
  'verify-installation.sh:libexec/ixe-verify'; do
  docker cp "$context_dir/tests/e2e-installation-experience/${mapping%%:*}" "$container_id:/usr/local/${mapping#*:}"
done
if test "$standard_bundle" = true; then
  docker cp "$context_dir/tests/e2e-installation-experience/standard-source.py" "$container_id:/usr/local/libexec/ixe-standard-source.py"
fi
docker start "$container_id" >/dev/null
docker exec "$container_id" chmod 0755 /usr/local/libexec/ixe-entrypoint /usr/local/libexec/ixe-prepare \
  /usr/local/bin/dearmachine /usr/local/bin/run-install-evaluation /usr/local/libexec/ixe-verify

for attempt in $(seq 1 30); do
  docker exec "$container_id" test -d /run/ixe && break
  test "$attempt" -lt 30 || fail 'container runtime directory did not become ready'
  sleep 1
done
docker cp "$ssh_key.pub" "$container_id:/run/ixe/authorized_keys"

docker exec "$container_id" mkdir -p /home/installer/machtiani
tar -C "$context_dir" -cf - . | \
  docker exec -i "$container_id" tar -xf - -C /home/installer/machtiani

ixe_agent_seed "$container_id" "$script_dir/agents" "$runtime_root"
if test -n "$curl_bundle"; then ixe_curl_seed; fi

docker cp "$context_dir/tests/e2e-installation-experience/backend-fixture.py" "$container_id:/usr/local/libexec/ixe-backend-fixture.py"
docker exec "$container_id" python3 /usr/local/libexec/ixe-backend-fixture.py "$backend_fixture"
docker exec "$container_id" /usr/local/libexec/ixe-prepare
if test -n "$curl_bundle"; then ixe_curl_start_server; fi

for attempt in $(seq 1 120); do
  docker exec "$container_id" test -f /run/ixe/ssh-ready && break
  test "$attempt" -lt 120 || fail 'SSH did not become ready'
  sleep 1
done

ssh_port=$(docker port "$container_id" 22/tcp | sed -n 's/.*://p')
case "$ssh_port" in ''|*[!0-9]*) fail 'could not determine the localhost SSH port' ;; esac

login_note='Copied agent authentication is valid.'
if test "$agent_name" = machtiani-installer; then login_note='Choose and authenticate a provider in the installer wizard.'; fi
if ! ixe_agent_check_login "$container_id"; then
  login_note="Copied authentication is not valid in the container; run '$IXE_AGENT_LOGIN_COMMAND' before starting the evaluation."
fi

cp "$repo_root/INSTALL.md" "$artifact_dir/INSTALL.md"
chmod 0600 "$artifact_dir/INSTALL.md"
cat > "$artifact_dir/run.txt" <<EOF
run_id=$run_id
agent=$agent_name
backend_fixture=$backend_fixture
container=$container_name
source_commit=$(git -C "$repo_root" rev-parse HEAD)
installer_commit=$(git -C "$installer_source_root" rev-parse HEAD)
started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
chmod 0600 "$artifact_dir/run.txt"

printf '\nIXE is ready for its human operator.\n\n'
printf 'Preinstalled backend fixture: %s\n\n' "$backend_fixture"
printf '1. Open another terminal and connect:\n\n'
printf "   ssh -tt -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i '%s' -p %s installer@127.0.0.1\n\n" "$ssh_key" "$ssh_port"
if test -n "$curl_bundle"; then
  printf '2. Run: curl -fsSL %s/install | sh\n' "$curl_base_url"
  printf '   Then run: dearmachine\n'
  printf '3. %s\n' "$login_note"
elif test "$agent_name" = machtiani-installer; then
  printf '2. Run: dearmachine\n'
  printf '3. %s\n' "$login_note"
else
  printf '2. %s\n' "$login_note"
  printf '3. Run: dearmachine\n'
fi
printf '4. Interact with the installation agent until it exits; IXE then verifies the install.\n'
printf '5. On success, explore the product in the post-install shell: run dearmachine for the concierge.\n'
printf '6. Type exit (or Ctrl+D) in that shell to finish the evaluation and collect artifacts.\n'
printf '   If installation or verification fails, the evaluation finishes immediately.\n\n'
printf 'Private evaluation artifacts will be retained at: %s\n' "$artifact_dir"

while docker exec "$container_id" test ! -f /run/ixe/completed; do
  docker inspect --format '{{.State.Running}}' "$container_id" | grep -Fx true >/dev/null || \
    fail 'the IXE container stopped before the evaluation completed'
  sleep 2
done
completion_seen=true

docker cp "$container_id:/run/ixe/artifacts/." "$artifact_dir/"
ixe_agent_collect "$container_id" "$artifact_dir"
chmod -R go-rwx "$artifact_dir"

secrets_get DEEPSEEK_API_KEY deepseek_api_key
secrets_get AGENTMAIL_API_KEY agentmail_api_key
IXE_SCAN_DEEPSEEK_API_KEY=$deepseek_api_key \
IXE_SCAN_AGENTMAIL_API_KEY=$agentmail_api_key \
python3 - "$artifact_dir" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
secrets = [os.environ.get("IXE_SCAN_DEEPSEEK_API_KEY", ""), os.environ.get("IXE_SCAN_AGENTMAIL_API_KEY", "")]
found = []
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    data = path.read_bytes()
    for secret in secrets:
        if secret and secret.encode() in data:
            data = data.replace(secret.encode(), b"[REDACTED]")
            found.append(str(path.relative_to(root)))
    path.write_bytes(data)
    path.chmod(0o600)
if found:
    print("IXE redacted an exact credential from: " + ", ".join(sorted(set(found))), file=sys.stderr)
PY

agent_status=$(sed -n '1p' "$artifact_dir/agent-exit-status")
verification_status=$(sed -n '1p' "$artifact_dir/verification-exit-status")
if test "$agent_status" -ne 0 || test "$verification_status" -ne 0; then
  fail "agent status=$agent_status, verification status=$verification_status; review $artifact_dir"
fi

printf 'INSTALLATION EXPERIENCE EVALUATION PASSED\n'
printf 'Review the transcript and trajectory at: %s\n' "$artifact_dir"
