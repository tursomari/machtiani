#!/usr/bin/env bash
set -euo pipefail

# Sole host-side transaction owner for the live Installation Procedure
# Evaluation (IPE).

fail() {
  printf 'INSTALLATION PROCEDURE EVALUATION FAILURE: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: tests/e2e-installation-procedure/run.sh [--self-test|--help]' \
    '' \
    'With no arguments, run the credentialed live IPE.' \
    '--self-test exercises source archive, preflight, lock, and empty cleanup paths only.'
}

self_test_mode=false
case "${1:-}" in
  '') ;;
  --self-test) self_test_mode=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
test "$#" -le 1 || { usage >&2; exit 2; }

ipe_sender_transport=${IPE_SENDER_TRANSPORT:-agentmail}
case "$ipe_sender_transport" in
  agentmail|openmail) ;;
  *) fail 'IPE_SENDER_TRANSPORT must be agentmail or openmail' ;;
esac

ipe_llm_profile=${IPE_LLM_PROFILE:-deepseek-v4-flash-high}
case "$ipe_llm_profile" in
  deepseek-v4-flash-high)
    IPE_LLM_CREDENTIAL_ENV=DEEPSEEK_API_KEY
    IPE_MACHTIANI_PROVIDER_ID=deepseek
    IPE_FORGE_PROVIDER_ID=deepseek
    IPE_FORGE_PROVIDER_NAME=Deepseek
    IPE_LLM_MODEL=deepseek-v4-flash
    IPE_LLM_REASONING=high
    ;;
  openrouter-glm-5.3-flash-medium|openrouter-glm-5.3-high)
    IPE_LLM_CREDENTIAL_ENV=OPENROUTER_API_KEY
    IPE_MACHTIANI_PROVIDER_ID=openrouter
    IPE_FORGE_PROVIDER_ID=open_router
    IPE_FORGE_PROVIDER_NAME=OpenRouter
    IPE_LLM_MODEL=z-ai/glm-5.3-flash
    IPE_LLM_REASONING=medium
    if test "$ipe_llm_profile" = openrouter-glm-5.3-high; then
      IPE_LLM_MODEL=z-ai/glm-5.3
      IPE_LLM_REASONING=high
    fi
    ;;
  deepinfra-glm-5.3-flash-high)
    IPE_LLM_CREDENTIAL_ENV=DEEPINFRA_API_KEY
    IPE_MACHTIANI_PROVIDER_ID=custom-openai-remote
    IPE_FORGE_PROVIDER_ID=requesty
    IPE_FORGE_PROVIDER_NAME=Requesty
    IPE_LLM_MODEL=zai-org/GLM-5.3-Flash
    IPE_LLM_REASONING=high
    ;;
  *) fail "unknown IPE_LLM_PROFILE: $ipe_llm_profile" ;;
esac
export IPE_LLM_PROFILE IPE_LLM_CREDENTIAL_ENV IPE_MACHTIANI_PROVIDER_ID
export IPE_FORGE_PROVIDER_ID IPE_FORGE_PROVIDER_NAME IPE_LLM_MODEL IPE_LLM_REASONING

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
secrets_file=$repo_root/.secrets
image_name=machtiani-ipe-agent-e2e:local
run_id=$(python3 - <<'PY'
import secrets
print(secrets.token_hex(6))
PY
)
container_name=machtiani-ipe-$run_id
lock_file=${TMPDIR:-/tmp}/machtiani-ipe-e2e-$(id -u).lock

umask 077
if test ! -e "$lock_file" && test ! -L "$lock_file"; then
  (set -C; : > "$lock_file") 2>/dev/null || true
fi
python3 - "$lock_file" <<'PY'
from pathlib import Path
import os, stat, sys
path=Path(sys.argv[1])
metadata=path.lstat()
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("Installation Procedure lock must be a regular, non-symlink file")
if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("Installation Procedure lock has unsafe ownership or mode")
PY
exec 9<> "$lock_file"
python3 - "$lock_file" <<'PY'
import os,sys
path_stat=os.lstat(sys.argv[1]); descriptor_stat=os.fstat(9)
if (path_stat.st_dev,path_stat.st_ino)!=(descriptor_stat.st_dev,descriptor_stat.st_ino):
    raise SystemExit("Installation Procedure lock changed while it was opened")
PY
flock -n 9 || fail 'another live IPE run holds the private safety lock'

# shellcheck source=lib/txn.sh
source "$script_dir/lib/txn.sh"
# shellcheck source=lib/agentmail.sh
source "$script_dir/lib/agentmail.sh"
# shellcheck source=lib/secrets.sh
source "$script_dir/lib/secrets.sh"

txn_init
TXN_CLEANUP_ENABLED=0
export TXN_CLEANUP_ENABLED
run_root=$TXN_RUNTIME_ROOT
context_dir=$run_root/context
helper_path=$run_root/agentmail-helper
openmail_sender_state=$run_root/openmail-sender.json
run_openmail_sender() {
  python3 "$script_dir/openmail-sender.py" --state "$openmail_sender_state" "$@"
}
run_sender_helper() {
  if test "$ipe_sender_transport" = openmail; then
    run_openmail_sender "$@"
  else
    run_agentmail_helper "$@"
  fi
}
baseline_snapshot=$run_root/agentmail-baseline.json
final_snapshot=$run_root/agentmail-final.json
host_client_snapshot=$run_root/host-client.json
repo_baseline=$run_root/repo-status
container_id=
container_intent_recorded=false
baseline_ready=false
cleanup_active=false
run_complete=false

mkdir "$context_dir"
chmod 0700 "$context_dir"
git -C "$repo_root" status --porcelain=v2 > "$repo_baseline"
chmod 0600 "$repo_baseline"

capture_live_diagnostics() {
  test -n "${container_id:-}" || return 0
  test -f "$run_root/send.json" || return 0
  test "${run_complete:-false}" != true || return 0

  live_diagnostics=$run_root/live-exchange-diagnostics.txt
  live_log_tail=$run_root/live-exchange-client-log.tmp
  live_db_summary=$run_root/live-exchange-sqlite-summary.tmp
  live_attachment_tree=$run_root/live-exchange-attachment-tree.tmp
  live_mode_dir=$run_root/live-exchange-mode-dir.tmp
  retained_diagnostics=/tmp/machtiani-ipe-live-diagnostics-$run_id.txt
  diagnostics_home=${container_home:-}
  if test -z "$diagnostics_home" && test -f "$run_root/home-path"; then
    diagnostics_home=$(sed -n '1p' "$run_root/home-path" 2>/dev/null) || diagnostics_home=
  fi

  if test -n "$diagnostics_home"; then
    docker exec "$container_id" tail -n 80 -- \
      "$diagnostics_home/.dearmachine/log/dearmachine.log" 2>/dev/null | \
      python3 -c '
import os,re,sys

patterns=re.compile(
    r"(?i)(?:\bapi[ _-]?key\b|\b(?:access[ _-]?token|refresh[ _-]?token|token)\b\s*[:=]|"
    r"\bauthorization\s*:|\bbearer\s+|\b(?:sk|am)[-_][A-Za-z0-9_-]{16,}\b|"
    r"\b[0-9a-f]{40,}\b|/home/[^/\s]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})"
)
secrets=[os.environ.get(name, "") for name in ("DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "DEEPINFRA_API_KEY", "AGENTMAIL_API_KEY", "OPENMAIL_API_KEY")]
for line in sys.stdin:
    if patterns.search(line) or any(secret and secret in line for secret in secrets):
        print("[redacted]")
    else:
        print(line, end="")
' > "$live_log_tail" 2>/dev/null || true
    chmod 0600 "$live_log_tail" 2>/dev/null || true

    {
      docker exec "$container_id" find "$diagnostics_home/.dearmachine/entrypoint/main" \
        -maxdepth 4 \( -path '*/.attachments-inbox*' -o -path '*/.attachments-outbox*' \) \
        -printf '%y %p %s\n' 2>/dev/null || \
        docker exec "$container_id" find "$diagnostics_home/.dearmachine/entrypoint/main" \
          -maxdepth 4 \( -path '*/.attachments-inbox*' -o -path '*/.attachments-outbox*' \) \
          -print 2>/dev/null || true
    } | python3 -c '
import os,re,sys

patterns=re.compile(
    r"(?i)(?:\bapi[ _-]?key\b|\b(?:access[ _-]?token|refresh[ _-]?token|token)\b\s*[:=]|"
    r"\bauthorization\s*:|\bbearer\s+|\b(?:sk|am)[-_][A-Za-z0-9_-]{16,}\b|"
    r"\b[0-9a-f]{40,}\b|/home/[^/\s]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})"
)
secrets=[os.environ.get(name, "") for name in ("DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "DEEPINFRA_API_KEY", "AGENTMAIL_API_KEY", "OPENMAIL_API_KEY")]
for line in sys.stdin:
    if patterns.search(line) or any(secret and secret in line for secret in secrets):
        print("[redacted]")
    else:
        print(line, end="")
' > "$live_attachment_tree" 2>/dev/null || true
    test -s "$live_attachment_tree" || \
      printf '%s\n' '(no attachment staging trees found)' > "$live_attachment_tree"
    chmod 0600 "$live_attachment_tree" 2>/dev/null || true

    if ! docker exec "$container_id" ls -la \
      "$diagnostics_home/.machtiani/modes/agent-managed/" 2>/dev/null | \
      python3 -c '
import os,re,sys

patterns=re.compile(
    r"(?i)(?:\bapi[ _-]?key\b|\b(?:access[ _-]?token|refresh[ _-]?token|token)\b\s*[:=]|"
    r"\bauthorization\s*:|\bbearer\s+|\b(?:sk|am)[-_][A-Za-z0-9_-]{16,}\b|"
    r"\b[0-9a-f]{40,}\b|/home/[^/\s]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})"
)
secrets=[os.environ.get(name, "") for name in ("DEEPSEEK_API_KEY", "OPENROUTER_API_KEY", "DEEPINFRA_API_KEY", "AGENTMAIL_API_KEY", "OPENMAIL_API_KEY")]
for line in sys.stdin:
    if patterns.search(line) or any(secret and secret in line for secret in secrets):
        print("[redacted]")
    else:
        print(line, end="")
' > "$live_mode_dir" 2>/dev/null; then
      printf '%s\n' '(agent-managed mode directory missing)' > "$live_mode_dir"
    fi
    chmod 0600 "$live_mode_dir" 2>/dev/null || true

    diagnostics_database=$(docker exec "$container_id" find \
      "$diagnostics_home/.dearmachine/pairs" -type f -path '*/state/dearmachine.db' \
      -print -quit 2>/dev/null) || diagnostics_database=
    docker exec -i "$container_id" nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c python3 - \
      "$diagnostics_database" \
      > "$live_db_summary" 2>/dev/null <<'PY' || true
import hashlib,json,sqlite3,sys

def redact(value):
    return "sha256:"+hashlib.sha256(str(value).encode()).hexdigest()[:12]

connection=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=5)
connection.row_factory=sqlite3.Row
threads=[{
    "thread_id":redact(row["thread_id"]),
    "session_id":redact(row["session_id"]),
    "sequence":row["sequence"],
    "status":row["status"],
} for row in connection.execute(
    "SELECT thread_id,session_id,sequence,status FROM thread_sessions ORDER BY thread_id"
)]
pending=[{
    "message_id":redact(row["message_id"]),
    "thread_id":redact(row["thread_id"]),
    "sequence":row["sequence"],
    "state":row["state"],
} for row in connection.execute(
    "SELECT message_id,thread_id,sequence,state FROM pending_messages ORDER BY message_id"
)]
processed=[{
    "message_id":redact(row["message_id"]),
    "thread_id":redact(row["thread_id"]),
    "outbound_message_id":redact(row["outbound_message_id"]),
    "status":"processed",
} for row in connection.execute(
    "SELECT message_id,thread_id,outbound_message_id FROM processed_messages ORDER BY message_id"
)]
connection.close()
print(json.dumps({
    "counts":{
        "pending_messages":len(pending),
        "processed_messages":len(processed),
        "thread_sessions":len(threads),
    },
    "pending_messages":pending,
    "processed_messages":processed,
    "thread_sessions":threads,
}, sort_keys=True, separators=(",", ":")))
PY
    chmod 0600 "$live_db_summary" 2>/dev/null || true
  fi

  {
    printf '%s\n' 'Installation Procedure live-exchange failure diagnostics'
    printf '%s\n' '==> Client log tail (last 80 lines, sensitive lines redacted)'
    if test -s "$live_log_tail"; then
      sed -n '1,80p' "$live_log_tail"
    else
      printf '%s\n' '[client log unavailable]'
    fi
    printf '%s\n' '==> SQLite metadata summary (identities hashed)'
    if test -s "$live_db_summary"; then
      sed -n '1p' "$live_db_summary"
    else
      printf '%s\n' '[sqlite summary unavailable]'
    fi
    printf '%s\n' '==> Attachment staging tree (types, paths, sizes)'
    if test -s "$live_attachment_tree"; then
      sed -n '1,240p' "$live_attachment_tree"
    else
      printf '%s\n' '(no attachment staging trees found)'
    fi
    printf '%s\n' '==> Installed agent-managed mode files (names+permissions only)'
    if test -s "$live_mode_dir"; then
      sed -n '1,240p' "$live_mode_dir"
    else
      printf '%s\n' '(agent-managed mode directory missing)'
    fi
  } > "$live_diagnostics" 2>/dev/null || true
  chmod 0600 "$live_diagnostics" 2>/dev/null || true
  if declare -F scan_sensitive_artifacts >/dev/null 2>&1; then
    scan_sensitive_artifacts "$live_diagnostics" >/dev/null 2>&1 || true
  fi
  cp -- "$live_diagnostics" "$retained_diagnostics" 2>/dev/null || true
  chmod 0600 "$retained_diagnostics" 2>/dev/null || true
  test ! -f "$retained_diagnostics" || \
    printf 'Live exchange diagnostics retained at %s\n' "$retained_diagnostics" >&2 || true
  return 0
}

cleanup() {
  cleanup_status=$?
  if test "$cleanup_active" = true; then
    exit "$cleanup_status"
  fi
  cleanup_active=true
  trap - EXIT HUP INT TERM
  set +e

  cleanup_safe=true
  # Preserve sanitized evidence even when failure precedes the email exchange.
  # Resource cleanup must not erase the assertion that caused the run to fail.
  if test "$cleanup_status" -ne 0 && test -n "${container_id:-}"; then
    docker logs "$container_id" > "$run_root/docker.log" 2>&1 || true
    for artifact in postconditions.log forge.stdout forge.stderr; do
      docker cp "$container_id:/run/machtiani-ipe-agent/$artifact" "$run_root/$artifact" >/dev/null 2>&1 || true
    done
    retained_directory=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-ipe-failure-$run_id.XXXXXX")
    chmod 0700 "$retained_directory"
    for artifact in docker.log postconditions.log forge.stdout forge.stderr installation-procedure-report.md; do
      if test -f "$run_root/$artifact"; then
        scan_sensitive_artifacts "$run_root/$artifact" || true
        cp -- "$run_root/$artifact" "$retained_directory/$artifact"
        chmod 0600 "$retained_directory/$artifact"
      fi
    done
    printf 'Sanitized failure evidence retained at %s\n' "$retained_directory" >&2
  fi
  container_pids=$run_root/container-pids
  : > "$container_pids"
  chmod 0600 "$container_pids"
  if test "$container_intent_recorded" = true; then
    if reconciled_container_id=$(txn_reconcile_container_from_cidfile "$container_name"); then
      container_id=$reconciled_container_id
    else
      printf 'INCONCLUSIVE CLEANUP: durable container identity could not be reconciled; refusing container deletion.\n' >&2
      cleanup_safe=false
    fi
  fi
  capture_live_diagnostics
  if test "$cleanup_safe" = true && test -n "${container_id:-}" && \
     printf '%s' "$container_id" | grep -Eq '^[0-9a-f]{64}$'; then
    docker top "$container_id" -eo pid 2>/dev/null | sed '1d' > "$container_pids" || true
    if ! docker stop --time 15 "$container_id" >/dev/null 2>&1; then
      printf 'INCONCLUSIVE CLEANUP: could not stop exact container %s.\n' "$container_id" >&2
      cleanup_safe=false
    elif ! docker rm "$container_id" >/dev/null 2>&1; then
      printf 'INCONCLUSIVE CLEANUP: could not remove exact container %s.\n' "$container_id" >&2
      cleanup_safe=false
    fi
    if docker inspect "$container_id" >/dev/null 2>&1; then
      printf 'INCONCLUSIVE CLEANUP: exact container still exists after removal.\n' >&2
      cleanup_safe=false
    fi
    while IFS= read -r cleanup_pid; do
      case "$cleanup_pid" in ''|*[!0-9]*) continue ;; esac
      if test -e "/proc/$cleanup_pid"; then
        printf 'INCONCLUSIVE CLEANUP: recorded container descendant PID %s remains.\n' "$cleanup_pid" >&2
        cleanup_safe=false
      fi
    done < "$container_pids"
    container_id=
  fi
  if test -f "$host_client_snapshot" && ! agentmail_assert_host_client_unchanged "$host_client_snapshot"; then
    printf 'INCONCLUSIVE CLEANUP: stable host DearMachine client changed; refusing remote cleanup.\n' >&2
    cleanup_safe=false
  fi

  if test -f "$openmail_sender_state" && ! run_openmail_sender cleanup; then
    printf 'INCONCLUSIVE CLEANUP: OpenMail sender cleanup or baseline verification failed.\n' >&2
    cleanup_safe=false
  fi

  if test "$cleanup_safe" = true && test -s "$TXN_JOURNAL"; then
    if ! txn_cleanup_all; then
      printf 'INCONCLUSIVE CLEANUP: exact journaled AgentMail cleanup failed.\n' >&2
      cleanup_safe=false
    fi
  fi

  if test "$cleanup_safe" = true && test "$baseline_ready" = true; then
    if ! agentmail_wait_for_baseline "$baseline_snapshot" "$final_snapshot" "$stable_address"; then
      printf 'INCONCLUSIVE CLEANUP: final AgentMail state differs from the exact baseline.\n' >&2
      cleanup_safe=false
    fi
  fi

  if test -f "$host_client_snapshot" && ! agentmail_assert_host_client_unchanged "$host_client_snapshot"; then
    printf 'INCONCLUSIVE CLEANUP: stable host DearMachine client did not survive unchanged.\n' >&2
    cleanup_safe=false
  fi
  if ! git -C "$repo_root" status --porcelain=v2 | cmp -s - "$repo_baseline"; then
    printf 'INSTALLATION PROCEDURE EVALUATION FAILURE: umbrella worktree changed during the live run.\n' >&2
    cleanup_safe=false
  fi

  if declare -F scan_retained_diagnostics >/dev/null 2>&1 && test -d "$run_root"; then
    if ! scan_retained_diagnostics; then
      printf 'INCONCLUSIVE CLEANUP: retained runtime diagnostics contained credential material and were replaced.\n' >&2
      cleanup_safe=false
    fi
  fi
  unset DEEPSEEK_API_KEY DEEPINFRA_API_KEY OPENROUTER_API_KEY AGENTMAIL_API_KEY OPENMAIL_API_KEY
  unset deepseek_api_key openrouter_api_key agentmail_api_key
  secrets_clear
  unset AGENTMAIL_MUTATION_FORBIDDEN_ID AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS

  if test "$cleanup_safe" != true; then
    cleanup_status=1
    printf 'Manual recovery evidence retained at %s\n' "$run_root" >&2
    printf '%s\n' 'Exact transaction journal:' >&2
    sed -n '1,240p' "$TXN_JOURNAL" >&2
  else
    case "$run_root" in
      "${TMPDIR:-/tmp}"/machtiani-agentmail-txn.*) ;;
      *)
        printf 'Refusing to remove unexpected runtime root: %s\n' "$run_root" >&2
        cleanup_status=1
        cleanup_safe=false
        ;;
    esac
    if test "$cleanup_safe" = true && test -d "$run_root" && test ! -L "$run_root" && \
       test "$(stat -c '%u' "$run_root")" = "$(id -u)"; then
      find "$run_root" -depth -delete
    fi
  fi

  flock -u 9 || true
  exec 9>&-
  if test "$cleanup_status" -eq 0 && test "$run_complete" = true && test "$self_test_mode" != true; then
    printf 'INSTALLATION PROCEDURE EVALUATION PASSED\n'
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'failed_status=$?; printf "INSTALLATION PROCEDURE EVALUATION FAILURE: command failed at line %s with status %s\n" "$LINENO" "$failed_status" >&2; exit "$failed_status"' ERR

for command_name in flock git python3 tar; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

assert_source_checkout() {
  test "$(git -C "$repo_root" rev-parse --show-toplevel)" = "$repo_root" || \
    fail 'runner is not inside the expected umbrella worktree'
  for source_submodule in machtiani-harness dearmachine dearmachine-concierge; do
    source_gitlink=$(git -C "$repo_root" ls-tree HEAD "$source_submodule" | awk '{print $3}')
    test -n "$source_gitlink" || fail "umbrella HEAD has no $source_submodule gitlink"
    test "$(git -C "$repo_root/$source_submodule" rev-parse HEAD)" = "$source_gitlink" || \
      fail "$source_submodule checkout is not at the umbrella gitlink"
  done
  if test "$self_test_mode" != true; then
    test -z "$(git -C "$repo_root" status --porcelain=v2 --untracked-files=all --ignore-submodules=none)" || \
      fail 'umbrella or submodule worktree is not clean; refusing a live run'
    for source_submodule in machtiani-harness dearmachine dearmachine-concierge; do
      test -z "$(git -C "$repo_root/$source_submodule" status --porcelain=v2 --untracked-files=all)" || \
        fail "$source_submodule worktree is not clean; refusing a live run"
      ! git -C "$repo_root/$source_submodule" symbolic-ref -q HEAD >/dev/null || \
        fail "$source_submodule must be detached at the umbrella gitlink for a live run"
    done
  fi
}

assert_source_checkout

printf '==> Creating the source-only build context...\n'
git -C "$repo_root" archive HEAD | tar --exclude='.env*' -x -C "$context_dir"
mkdir -p "$context_dir/machtiani-harness" "$context_dir/dearmachine" "$context_dir/dearmachine-concierge" "$context_dir/tests/e2e-installation-procedure"
git -C "$repo_root/machtiani-harness" archive HEAD | tar --exclude='.env*' -x -C "$context_dir/machtiani-harness"
git -C "$repo_root/dearmachine" archive HEAD | tar --exclude='.env*' -x -C "$context_dir/dearmachine"
git -C "$repo_root/dearmachine-concierge" archive HEAD | tar --exclude='.env*' -x -C "$context_dir/dearmachine-concierge"

forbidden_path=$(find "$context_dir" \
  \( -name .git -o -name .ssh -o -name .secrets -o -name '.env*' \
     -o -name .forge -o -name config.toml \
     -o \( -type f \( -iname credentials -o -iname credentials.json -o -name .credentials.json \) \) \
  \) -print -quit)
test -z "$forbidden_path" || fail "source context contains forbidden host state: $forbidden_path"

if test "$self_test_mode" = true; then
  test -f "$context_dir/tests/e2e-installation-procedure/run.sh" || fail 'archive lacks the harness entrypoint'
  test -f "$context_dir/docs/installation-procedure.md" || fail 'archive lacks the Installation Procedure documentation'
  test -f "$context_dir/README.md" || fail 'archive lacks the umbrella README'
  run_complete=true
  printf 'Installation Procedure uncredentialed archive/preflight/cleanup self-test passed\n'
  exit 0
fi

for command_name in docker go; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

printf '==> Building the pinned AgentMail helper and Forge image...\n'
(cd "$script_dir/agentmail-helper" && \
  GOPROXY=off GOFLAGS=-mod=mod go build -o "$helper_path" .)
chmod 0700 "$helper_path"
(cd "$script_dir/agentmail-helper" && \
  go list -m -f '{{.Path}} {{.Version}}' github.com/agentmail-to/agentmail-go) \
  > "$run_root/agentmail-sdk-version"
chmod 0600 "$run_root/agentmail-sdk-version"
printf '==> Resolved %s\n' "$(sed -n '1p' "$run_root/agentmail-sdk-version")"

DOCKER_BUILDKIT=1 docker build --progress plain --file "$context_dir/tests/e2e-installation-procedure/Dockerfile" \
  --tag "$image_name" "$context_dir"
test "$(docker run --rm --entrypoint /usr/local/bin/forge "$image_name" --version)" = 'forge 2.13.21' || \
  fail 'built image does not contain the exact pinned Forge version'
docker run --rm --entrypoint /bin/sh "$image_name" -eu -c '
  bad=$(find /workspace/machtiani \
    \( -name .git -o -name .ssh -o -name .secrets -o -name ".env*" \
       -o -name .forge -o -name config.toml \
       -o \( -type f \( -iname credentials -o -iname credentials.json -o -name .credentials.json \) \) \
    \) -print -quit)
  test -z "$bad"
' || fail 'built image contains forbidden Git, credential, environment, or host configuration state'

# Credentials are loaded only after the source context and image hygiene gates.
secrets_load "$secrets_file"
secrets_get DEEPSEEK_API_KEY deepseek_api_key
secrets_get AGENTMAIL_API_KEY agentmail_api_key
export DEEPSEEK_API_KEY=$deepseek_api_key
export AGENTMAIL_API_KEY=$agentmail_api_key
if test "$IPE_LLM_CREDENTIAL_ENV" = OPENROUTER_API_KEY; then
  test -n "${OPENROUTER_API_KEY:-}" || \
    fail 'OPENROUTER_API_KEY is required for the selected OpenRouter IPE profile'
  openrouter_api_key=$OPENROUTER_API_KEY
fi
test -n "${!IPE_LLM_CREDENTIAL_ENV:-}" || fail "$IPE_LLM_CREDENTIAL_ENV is required for the selected IPE profile"
if test "$ipe_sender_transport" = openmail; then
  test -n "${OPENMAIL_API_KEY:-}" || fail 'OPENMAIL_API_KEY is required for the OpenMail sender'
fi
TXN_AGENTMAIL_HELPER=$helper_path
export TXN_AGENTMAIL_HELPER

run_agentmail_helper() {
  env -u AGENTMAIL_BASE_URL -u AGENTMAIL_CUSTOM_HEADERS "$helper_path" "$@"
}

scan_sensitive_artifacts() {
  IPE_SCAN_DEEPSEEK_API_KEY=${deepseek_api_key:-} \
  IPE_SCAN_DEEPINFRA_API_KEY=${DEEPINFRA_API_KEY:-} \
  IPE_SCAN_OPENROUTER_API_KEY=${openrouter_api_key:-} \
  IPE_SCAN_AGENTMAIL_API_KEY=${agentmail_api_key:-} \
  IPE_SCAN_OPENMAIL_API_KEY=${OPENMAIL_API_KEY:-} \
  IPE_SCAN_RECEIVER_ID=${receiver_id:-} \
  IPE_SCAN_RECEIVER_ADDRESS=${receiver_address:-} \
  IPE_SCAN_SENDER_ID=${sender_id:-} \
  IPE_SCAN_SENDER_ADDRESS=${sender_address:-} \
  IPE_SCAN_JOURNAL=${TXN_JOURNAL:-} \
  python3 - "$@" <<'PY'
from pathlib import Path
import os
import re
import sys

roots=[Path(value) for value in sys.argv[1:]]
paths=[]
for root in roots:
    if root.is_symlink():
        continue
    if root.is_file():
        paths.append(root)
    elif root.is_dir():
        paths.extend(path for path in root.rglob("*") if path.is_file() and not path.is_symlink())

secrets=[
    os.environ.get("IPE_SCAN_DEEPSEEK_API_KEY", ""),
    os.environ.get("IPE_SCAN_OPENROUTER_API_KEY", ""),
    os.environ.get("IPE_SCAN_DEEPINFRA_API_KEY", ""),
    os.environ.get("IPE_SCAN_AGENTMAIL_API_KEY", ""),
    os.environ.get("IPE_SCAN_OPENMAIL_API_KEY", ""),
]
temporary=[
    (os.environ.get("IPE_SCAN_RECEIVER_ID", ""), b"<temporary-inbox-id>"),
    (os.environ.get("IPE_SCAN_RECEIVER_ADDRESS", ""), b"<temporary-inbox-address>"),
    (os.environ.get("IPE_SCAN_SENDER_ID", ""), b"<temporary-inbox-id>"),
    (os.environ.get("IPE_SCAN_SENDER_ADDRESS", ""), b"<temporary-inbox-address>"),
]
journal=Path(os.environ["IPE_SCAN_JOURNAL"]) if os.environ.get("IPE_SCAN_JOURNAL") else None
credential_assignment=re.compile(
    rb"(?i)(?:DEEPSEEK_API_KEY|OPENROUTER_API_KEY|DEEPINFRA_API_KEY|OPENAI_API_KEY|MACHTIANI_CUSTOM_OPENAI_REMOTE_API_KEY|AGENTMAIL_API_KEY|OPENMAIL_API_KEY)\s*[:=]\s*[\"']?[A-Za-z0-9_./+\-=]{12,}"
)
credential_shape=re.compile(rb"(?i)\b(?:sk|am)[-_][A-Za-z0-9_-]{16,}\b")
found=[]
for path in paths:
    try:
        data=path.read_bytes()
    except OSError:
        continue
    sensitive=False
    for value in secrets:
        if not value:
            continue
        encoded=value.encode()
        window=min(16, max(8, len(encoded)//2))
        fragments={encoded[index:index+window] for index in range(max(1, len(encoded)-window+1))}
        if encoded in data or any(fragment and fragment in data for fragment in fragments):
            sensitive=True
    if credential_assignment.search(data) or credential_shape.search(data):
        sensitive=True
    if sensitive:
        path.write_bytes(b"REDACTED: credential-like content removed by Installation Procedure harness.\n")
        os.chmod(path, 0o600)
        found.append(str(path))
        continue
    if path != journal:
        for value,replacement in temporary:
            if value:
                data=data.replace(value.encode(), replacement)
    path.write_bytes(data)
    os.chmod(path, 0o600)
if found:
    print("credential material detected and replaced in: " + ", ".join(found), file=sys.stderr)
    raise SystemExit(1)
PY
}

scan_retained_diagnostics() {
  scan_paths=()
  for scan_candidate in \
    "$run_root/forge.stdout" "$run_root/forge.stderr" \
    "$run_root/forge-diagnostic.txt" "$run_root/installation-procedure-report.md" \
    "$run_root/docker.log" "$run_root/postconditions.log" "$run_root/machtiani-session"; do
    test ! -e "$scan_candidate" || scan_paths+=("$scan_candidate")
  done
  test "${#scan_paths[@]}" -eq 0 || scan_sensitive_artifacts "${scan_paths[@]}"
}

printf '==> Recording the pre-mutation AgentMail and host-client baseline...\n'
stable_address=$(agentmail_discover_host_client_address)
if test -n "$stable_address"; then
  if test -n "${IPE_STABLE_INBOX_ADDRESS:-}"; then
    test "${stable_address,,}" = "${IPE_STABLE_INBOX_ADDRESS,,}" || \
      fail 'IPE_STABLE_INBOX_ADDRESS does not match the running host client'
  fi
  agentmail_snapshot_host_client "$host_client_snapshot" "$stable_address"
else
  stable_address=$(agentmail_discover_stable_inbox_address)
  printf '    No host DearMachine client discovered; protecting verified existing inbox %s.\n' "$stable_address"
fi
agentmail_snapshot "$baseline_snapshot" "$stable_address"
baseline_ready=true
stable_id=$(agentmail_snapshot_stable_id "$baseline_snapshot")
test -n "$stable_id" || fail 'stable inbox has no exact ID'
AGENTMAIL_MUTATION_FORBIDDEN_ID=$stable_id
AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS=$stable_address
export AGENTMAIL_MUTATION_FORBIDDEN_ID AGENTMAIL_MUTATION_FORBIDDEN_ADDRESS

created_inbox_count=0
provision_inbox() {
  provision_role=$1
  provision_output_name=$2
  test "$created_inbox_count" -lt 2 || fail 'refusing to provision a third inbox'
  provision_client_id=machtiani-ipe-$run_id-$provision_role
  provision_display_name="Machtiani Installation Procedure $run_id $provision_role"
  provision_intent=$(python3 - "$provision_client_id" "$provision_display_name" "$run_id" "$provision_role" <<'PY'
import json, sys
print(json.dumps({"client_id":sys.argv[1],"display_name":sys.argv[2],"run_id":sys.argv[3],"role":sys.argv[4]}, sort_keys=True, separators=(",", ":")))
PY
)
  provision_before=$run_root/inbox-before-$provision_role.json
  run_agentmail_helper list-inboxes > "$provision_before"
  chmod 0600 "$provision_before"
  python3 - "$provision_before" "$provision_intent" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))["inboxes"]
intent=json.loads(sys.argv[2])
metadata={"machtiani_ipe_run":intent["run_id"],"machtiani_ipe_role":intent["role"]}
matches=[row for row in rows if row.get("client_id")==intent["client_id"]
         and row.get("display_name")==intent["display_name"] and row.get("metadata")==metadata]
if matches:
    raise SystemExit(f"run-unique inbox tuple already exists ({len(matches)} matches); refusing create")
PY
  txn_record intent inbox-create "$provision_intent"
  provision_intent_key=$TXN_LAST_RESOURCE_KEY
  provision_response=$run_root/inbox-$provision_role.json
  run_agentmail_helper create-inbox \
    --client-id "$provision_client_id" --display-name "$provision_display_name" \
    --metadata-run-id "$run_id" --metadata-role "$provision_role" \
    > "$provision_response"
  chmod 0600 "$provision_response"
  provision_identity=$(python3 - "$provision_response" "$provision_client_id" "$provision_display_name" "$run_id" "$provision_role" "$stable_id" "$stable_address" <<'PY'
import json, sys
row=json.load(open(sys.argv[1], encoding="utf-8"))
if not row.get("inbox_id") or not row.get("email") or not row.get("pod_id"):
    raise SystemExit("created inbox response lacks an exact identity")
if row["inbox_id"] == sys.argv[6] or row["email"].casefold() == sys.argv[7].casefold():
    raise SystemExit("created inbox collided with the protected stable identity")
expected={"machtiani_ipe_run":sys.argv[4],"machtiani_ipe_role":sys.argv[5]}
if row.get("client_id") != sys.argv[2] or row.get("display_name") != sys.argv[3] or row.get("metadata") != expected:
    raise SystemExit("created inbox metadata does not match the run intent")
print(json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
)
  txn_record create inbox "$provision_identity"
  provision_resource_key=$TXN_LAST_RESOURCE_KEY
  txn_mark_done "$provision_resource_key"
  txn_mark_done "$provision_intent_key"
  created_inbox_count=$((created_inbox_count + 1))
  printf -v "$provision_output_name" '%s' "$provision_identity"
}

printf '==> Provisioning an AgentMail receiver and %s sender...\n' "$ipe_sender_transport"
provision_inbox receiver receiver_identity
receiver_id=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["inbox_id"])' <<< "$receiver_identity")
receiver_address=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["email"])' <<< "$receiver_identity")
if test "$ipe_sender_transport" = openmail; then
  sender_identity=$(run_openmail_sender prepare --run-id "$run_id" --receiver "$receiver_address")
  test "$created_inbox_count" -eq 1 || fail 'mixed IPE must create exactly one AgentMail inbox'
else
  provision_inbox sender sender_identity
  test "$created_inbox_count" -eq 2 || fail 'did not provision exactly two inboxes'
fi
sender_id=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["inbox_id"])' <<< "$sender_identity")
sender_address=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["email"])' <<< "$sender_identity")

create_allow() {
  allow_scope_id=$1
  allow_direction=$2
  allow_entry=$3
  allow_identity=$(python3 - "$allow_scope_id" "$allow_direction" "$allow_entry" <<'PY'
import json,sys
print(json.dumps({"scope":"inbox","scope_id":sys.argv[1],"direction":sys.argv[2],"type":"allow","entry":sys.argv[3]}, sort_keys=True, separators=(",", ":")))
PY
)
  allow_before=$run_root/allow-before-$allow_direction-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' "$allow_scope_id-$allow_entry")
  run_agentmail_helper lists --scope inbox --scope-id "$allow_scope_id" \
    --direction "$allow_direction" --type allow > "$allow_before"
  chmod 0600 "$allow_before"
  python3 - "$allow_before" "$allow_entry" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))["entries"]
if any(row.get("entry")==sys.argv[2] for row in rows):
    raise SystemExit("refusing to modify a pre-existing allowlist composite")
PY
  txn_record create allowlist-entry "$allow_identity"
  allow_key=$TXN_LAST_RESOURCE_KEY
  allow_response=$run_root/allow-created-$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$allow_identity")
  run_agentmail_helper lists-create --scope inbox --scope-id "$allow_scope_id" \
    --direction "$allow_direction" --type allow --entry "$allow_entry" > "$allow_response"
  chmod 0600 "$allow_response"
  python3 - "$allow_response" "$allow_scope_id" "$allow_direction" "$allow_entry" <<'PY'
import json,sys
row=json.load(open(sys.argv[1], encoding="utf-8"))
expected={"scope":"inbox","scope_id":sys.argv[2],"direction":sys.argv[3],"type":"allow","entry":sys.argv[4]}
if any(row.get(key)!=value for key,value in expected.items()) or row.get("list_type")!="allow" or row.get("read_only"):
    raise SystemExit("created allowlist response does not match the exact mutable composite")
PY
  txn_mark_done "$allow_key"
}

expect_pair_creation_allow() {
  allow_scope_id=$1
  allow_direction=$2
  allow_entry=$3
  allow_identity=$(python3 - "$allow_scope_id" "$allow_direction" "$allow_entry" <<'PY'
import json,sys
print(json.dumps({"scope":"inbox","scope_id":sys.argv[1],"direction":sys.argv[2],"type":"allow","entry":sys.argv[3]}, sort_keys=True, separators=(",", ":")))
PY
)
  allow_before=$run_root/allow-before-create-$allow_direction
  run_agentmail_helper lists --scope inbox --scope-id "$allow_scope_id" \
    --direction "$allow_direction" --type allow > "$allow_before"
  chmod 0600 "$allow_before"
  python3 - "$allow_before" "$allow_entry" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))["entries"]
if any(row.get("entry")==sys.argv[2] for row in rows):
    raise SystemExit("pair authorization entry already exists before up --create")
PY
  txn_record create allowlist-entry "$allow_identity"
}

printf '==> Recording pair authorization and sender permissions...\n'
expect_pair_creation_allow "$receiver_id" receive "$sender_address"
expect_pair_creation_allow "$receiver_id" send "$sender_address"
expect_pair_creation_allow "$receiver_id" reply "$sender_address"
if test "$ipe_sender_transport" = agentmail; then
  create_allow "$sender_id" send "$receiver_address"
  create_allow "$sender_id" reply "$receiver_address"
  expected_agentmail_allows=5
else
  expected_agentmail_allows=3
fi
test "$(txn_created_list_composites | wc -l)" -eq "$expected_agentmail_allows" || fail 'transaction has an unexpected number of AgentMail allowlist composites'

printf '==> Running Forge against the published Installation Procedure...\n'
IPE_RECEIVER_INBOX_ID=$receiver_id
IPE_RECEIVER_ADDRESS=$receiver_address
IPE_PAIR_EMAIL=$sender_address
IPE_RUN_ID=$run_id
export IPE_RECEIVER_INBOX_ID IPE_RECEIVER_ADDRESS IPE_PAIR_EMAIL IPE_RUN_ID
container_cid_root=$(mktemp -d "$run_root/container-cid.XXXXXX")
chmod 0700 "$container_cid_root"
container_cidfile=$container_cid_root/container.cid
container_label_name=to.agentmail.machtiani.ipe-run
container_intent=$(python3 - "$container_name" "$container_cidfile" "$container_label_name" "$run_id" <<'PY'
import json,sys
print(json.dumps({"container_name":sys.argv[1],"cidfile":sys.argv[2],"label_name":sys.argv[3],"label_value":sys.argv[4]}, sort_keys=True, separators=(",",":")))
PY
)
txn_record intent container-create "$container_intent"
container_intent_recorded=true
docker run --detach --name "$container_name" --cidfile "$container_cidfile" \
  --label "$container_label_name=$run_id" \
  --env "$IPE_LLM_CREDENTIAL_ENV" --env AGENTMAIL_API_KEY \
  --env IPE_LLM_PROFILE --env IPE_LLM_CREDENTIAL_ENV \
  --env IPE_MACHTIANI_PROVIDER_ID --env IPE_FORGE_PROVIDER_ID \
  --env IPE_FORGE_PROVIDER_NAME --env IPE_LLM_MODEL --env IPE_LLM_REASONING \
  --env IPE_RECEIVER_INBOX_ID --env IPE_RECEIVER_ADDRESS --env IPE_PAIR_EMAIL --env IPE_RUN_ID \
  --entrypoint /workspace/machtiani/tests/e2e-installation-procedure/container-agent.sh \
  "$image_name" >/dev/null
chmod 0600 "$container_cidfile"
container_id=$(txn_reconcile_container_from_cidfile "$container_name")
printf '%s' "$container_id" | grep -Eq '^[0-9a-f]{64}$' || fail 'docker returned an invalid container ID'

outer_deadline=$(( $(date +%s) + 3900 ))
while ! docker exec "$container_id" test -f /run/machtiani-ipe-agent/forge-complete 2>/dev/null; do
  test "$(date +%s)" -lt "$outer_deadline" || fail 'container exceeded the 65-minute outer deadline'
  test "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null)" = true || \
    fail 'container exited before writing the Forge completion sentinel'
  sleep 2
done

for artifact in forge.stdout forge.stderr forge-status postcondition-status postconditions.log forge-complete home-path; do
  if ! docker cp "$container_id:/run/machtiani-ipe-agent/$artifact" "$run_root/$artifact" >/dev/null 2>&1; then
    docker_log=$run_root/docker.log
    docker logs "$container_id" > "$docker_log" 2>&1 || true
    chmod 0600 "$docker_log"
    if scan_sensitive_artifacts "$docker_log"; then
      sed -n '1,160p' "$docker_log" >&2
    else
      sed -n '1,20p' "$docker_log" >&2
      fail 'container log contained credential material and was replaced before display'
    fi
    fail "container did not produce required artifact $artifact"
  fi
  chmod 0600 "$run_root/$artifact"
done
scan_sensitive_artifacts "$run_root/forge.stdout" "$run_root/forge.stderr" || \
  fail 'Forge transcript contained exact or partial credential material and was replaced'

report_file=$run_root/installation-procedure-report.md
diagnostic_file=$run_root/forge-diagnostic.txt
parse_error=$run_root/forge-report-parse-error.txt
: > "$parse_error"
chmod 0600 "$parse_error"
if ! python3 - "$run_root/forge.stdout" "$report_file" "$diagnostic_file" "$parse_error" <<'PY'
from pathlib import Path
import os, re, sys
source_path, report_path, diagnostic_path = map(Path, sys.argv[1:4])
parse_error_path = Path(sys.argv[4])

def reject(message):
    parse_error_path.write_text(message, encoding="utf-8")
    raise SystemExit(message)

text=source_path.read_text(encoding="utf-8", errors="replace")
text=re.sub(r"\x1b(?:[@-_][0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))", "", text)
text="".join(character for character in text if character in "\n\t" or ord(character)>=32)
descriptor=os.open(diagnostic_path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
try:
    os.write(descriptor, text.encode()); os.fsync(descriptor)
finally:
    os.close(descriptor)
begin_matches=list(re.finditer(r"(?m)^BEGIN_INSTALLATION_PROCEDURE_REPORT\r?$", text))
end_matches=list(re.finditer(r"(?m)^END_INSTALLATION_PROCEDURE_REPORT\r?$", text))
if not begin_matches or not end_matches:
    reject(f"Forge stdout lacks a complete Installation Procedure report; starts={len(begin_matches)}, ends={len(end_matches)}")
report_begin=begin_matches[-1]
ordered_ends=[match for match in end_matches if match.start() >= report_begin.end()]
if not ordered_ends:
    reject(f"Forge stdout lacks an end delimiter after its final report start; starts={len(begin_matches)}, ends={len(end_matches)}")
report_end=ordered_ends[0]
report=text[report_begin.start():report_end.end()].rstrip("\r\n")+"\n"
outcome_headings=list(re.finditer(r"(?m)^## Outcome\r?$", report))
if len(outcome_headings) != 1:
    reject("Installation Procedure report must contain exactly one Outcome heading")
following=report[outcome_headings[0].end():].splitlines()
outcome=next((line.strip() for line in following if line.strip()), "")
if not re.match(r"^`?SUCCESS`?(?:\s|$)", outcome):
    reject(f"Installation Procedure report Outcome must be SUCCESS; actual line after Outcome: {outcome[:160]!r}")
descriptor=os.open(report_path, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
try:
    os.write(descriptor, report.encode()); os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
then
  parse_reason=$(head -c 600 -- "$parse_error" 2>/dev/null || true)
  python3 - "$diagnostic_file" <<'PY' >&2
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
tail="\n".join(lines[-120:]).encode()
print(tail[-16384:].decode("utf-8", errors="ignore"))
PY
  test -n "$parse_reason" || parse_reason='Forge stdout does not contain exactly one delimited Installation Procedure report'
  fail "Installation Procedure report rejected: $parse_reason"
fi
printf '%s\n' '==> Sanitized Installation Procedure report:'
sed -n '1,80p' "$report_file"

forge_status=$(sed -n '1p' "$run_root/forge-status")
postcondition_status=$(sed -n '1p' "$run_root/postcondition-status")
sentinel_status=$(sed -n 's/^forge_exit_status=//p' "$run_root/forge-complete")
test "$forge_status" = 0 || fail "Forge follow process returned status $forge_status"
if test "$postcondition_status" != 0; then
  scan_sensitive_artifacts "$run_root/postconditions.log" || true
  tail -n 80 "$run_root/postconditions.log" >&2
  fail 'deterministic postcondition checks failed'
fi
test "$sentinel_status" = 0 || fail "PID 1 recorded worker status $sentinel_status"

printf '==> Verifying up --create established the inbox-scoped pair authorization...\n'
for pair_direction in receive send reply; do
  pair_allow_snapshot=$run_root/pair-allow-$pair_direction.json
  run_agentmail_helper lists --scope inbox --scope-id "$receiver_id" \
    --direction "$pair_direction" --type allow > "$pair_allow_snapshot"
  chmod 0600 "$pair_allow_snapshot"
  python3 - "$pair_allow_snapshot" "$sender_address" "$pair_direction" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf-8"))["entries"]
matches=[row for row in rows if row.get("entry","").casefold()==sys.argv[2].casefold()]
if len(matches)!=1:
    raise SystemExit(f"up --create did not establish exactly one {sys.argv[3]} allow entry")
PY
done

container_home=$(sed -n '1p' "$run_root/home-path")
case "$container_home" in /tmp/machtiani-agent-home.*) ;; *) fail 'container reported an unsafe runtime home' ;; esac
container_databases=$(docker exec "$container_id" find \
  "$container_home/.dearmachine/pairs" -type f -path '*/state/dearmachine.db' -print)
test "$(printf '%s\n' "$container_databases" | sed '/^$/d' | wc -l)" -eq 1 || \
  fail 'container does not contain exactly one registry-owned pair database'
container_database=$(printf '%s\n' "$container_databases" | sed -n '1p')
docker exec "$container_id" git -C /workspace/machtiani status --porcelain=v2 > "$run_root/container-status-before-mail"
chmod 0600 "$run_root/container-status-before-mail"

nonce=QS$(printf '%s' "$run_id" | tr '[:lower:]' '[:upper:]')$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16).upper())
PY
)
subject="Machtiani read-only request $run_id"
input_file=$run_root/input.txt
expected_file=$run_root/expected.txt
printf 'qs-attachment-%s\n' "$run_id" > "$input_file"
chmod 0600 "$input_file"
LC_ALL=C tr '[:lower:]' '[:upper:]' < "$input_file" > "$expected_file"
chmod 0600 "$expected_file"
message_body="Please convert the attached input.txt to uppercase and send the result back as result.txt. Include the exact uppercase marker $nonce in your reply."
idempotency_key=machtiani-ipe-$run_id-single-message
send_response=$run_root/send.json
live_exchange_timeout=1200
printf '==> Sending the single run-scoped attachment email...\n'
run_sender_helper send-with-attachment --inbox-id "$sender_id" --to "$receiver_address" \
  --subject "$subject" --text "$message_body" \
  --attachment "$input_file" --idempotency "$idempotency_key" \
  > "$send_response"
chmod 0600 "$send_response"
send_identity=$(python3 - "$send_response" "$idempotency_key" <<'PY'
import json,sys
row=json.load(open(sys.argv[1], encoding="utf-8"))
if not row.get("message_id") or not row.get("thread_id"):
    raise SystemExit("send response lacks exact message and thread IDs")
row["idempotency_key"]=sys.argv[2]
print(json.dumps(row, sort_keys=True, separators=(",", ":")))
PY
)
txn_record observe sent-message "$send_identity"
txn_mark_done "$TXN_LAST_RESOURCE_KEY"
sender_message_id=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["message_id"])' <<< "$send_identity")
sender_thread_id=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["thread_id"])' <<< "$send_identity")

backend_probe=$run_root/dearmachine-backends-child
backend_probe_unavailable=$run_root/dearmachine-backends-child-unavailable
observe_deadline=$(( $(date +%s) + live_exchange_timeout ))
transport_deadline=0
receiver_message_id=
receiver_thread_id=
reply_message_id=
db_ready=false
printf '==> Observing the email, database, child environment, session, and reply...\n'
while test "$(date +%s)" -lt "$observe_deadline"; do
  test "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null)" = true || \
    fail 'container stopped during the live exchange'

  client_pidfile=$container_home/.dearmachine/run/dearmachine.pid
  if docker exec "$container_id" test -f "$client_pidfile" 2>/dev/null; then
    client_pid=$(docker exec "$container_id" cat -- "$client_pidfile" 2>/dev/null) || client_pid=
    case "$client_pid" in
      ''|*[!0-9]*)
        capture_live_diagnostics
        fail 'containerized DearMachine client pidfile was invalid during the live exchange (diagnostics retained)'
        ;;
      *)
        if test "$client_pid" -le 0; then
          capture_live_diagnostics
          fail 'containerized DearMachine client pidfile was invalid during the live exchange (diagnostics retained)'
        fi
        if ! docker exec "$container_id" test -d "/proc/$client_pid" 2>/dev/null; then
          capture_live_diagnostics
          fail 'containerized DearMachine client exited during the live exchange (diagnostics retained)'
        fi
        ;;
    esac
  fi

  if test ! -f "$backend_probe"; then
    probe_candidate=$run_root/dearmachine-backends-child.tmp
    if docker exec -i "$container_id" nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c python3 - > "$probe_candidate" <<'PY'
from pathlib import Path
import json
for cmdline_path in Path("/proc").glob("[0-9]*/cmdline"):
    try:
        argv=[part.decode("utf-8", errors="replace") for part in cmdline_path.read_bytes().split(b"\0") if part]
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
    if not any("machtiani" in part for part in argv) or "agent-managed" not in argv:
        continue
    try:
        raw=(cmdline_path.parent/"environ").read_bytes().split(b"\0")
    except (FileNotFoundError, ProcessLookupError):
        continue
    except PermissionError:
        raise SystemExit(77)
    matches=[item.split(b"=",1)[1] for item in raw if item.startswith(b"DEARMACHINE_BACKENDS=")]
    if len(matches)!=1 or matches[0].decode("utf-8")!='["forge"]':
        raise SystemExit("active Machtiani child environment is not forge-only")
    print(json.dumps({"pid":int(cmdline_path.parent.name),"value":"[\"forge\"]"}, separators=(",",":")))
    raise SystemExit(0)
raise SystemExit(75)
PY
    then
      chmod 0600 "$probe_candidate"
      mv -- "$probe_candidate" "$backend_probe"
    else
      probe_status=$?
      rm -f -- "$probe_candidate"
      case "$probe_status" in
        75) ;;
        77) : > "$backend_probe_unavailable"; chmod 0600 "$backend_probe_unavailable" ;;
        *) fail "active child environment probe failed with status $probe_status" ;;
      esac
    fi
  fi


  run_agentmail_helper list-messages --inbox-id "$receiver_id" > "$run_root/receiver-messages.json"
  run_sender_helper list-messages --inbox-id "$sender_id" > "$run_root/sender-messages.json"
  chmod 0600 "$run_root/receiver-messages.json" "$run_root/sender-messages.json"
  observation=$(python3 - "$run_root/receiver-messages.json" "$run_root/sender-messages.json" \
    "$sender_address" "$receiver_address" "$subject" "$sender_message_id" "$sender_thread_id" <<'PY'
from email.utils import parseaddr
import json,sys
receiver=json.load(open(sys.argv[1], encoding="utf-8"))["messages"]
sender=json.load(open(sys.argv[2], encoding="utf-8"))["messages"]
sender_address,receiver_address,subject,sent_id,sent_thread=sys.argv[3:]
def address(value): return parseaddr(value)[1].casefold()
inbound=[row for row in receiver if address(row.get("from",""))==sender_address.casefold() and row.get("subject")==subject]
replies=[row for row in sender if row.get("message_id")!=sent_id and row.get("thread_id")==sent_thread and address(row.get("from",""))==receiver_address.casefold()]
if len(inbound)>1 or len(replies)>1:
    raise SystemExit("live exchange created duplicate inbound messages or replies")
print("|".join([
    inbound[0]["message_id"] if inbound else "",
    inbound[0]["thread_id"] if inbound else "",
    ",".join(inbound[0].get("labels",[])) if inbound else "",
    replies[0]["message_id"] if replies else "",
]))
PY
) || fail 'AgentMail observation became ambiguous'
  IFS='|' read -r receiver_message_id receiver_thread_id receiver_labels reply_message_id <<< "$observation"

  if test -n "$receiver_message_id"; then
    docker exec -i "$container_id" nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c python3 - \
      "$container_database" "$receiver_message_id" "$receiver_thread_id" \
      > "$run_root/db-evidence.json" <<'PY'
import json,sqlite3,sys
path,message_id,thread_id=sys.argv[1:]
connection=sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
connection.row_factory=sqlite3.Row
data={
 "threads":[dict(row) for row in connection.execute("SELECT thread_id,session_id,sequence,status FROM thread_sessions ORDER BY thread_id")],
 "processed":[dict(row) for row in connection.execute("SELECT message_id,thread_id,outbound_message_id FROM processed_messages ORDER BY message_id")],
 "pending":[dict(row) for row in connection.execute("SELECT message_id,thread_id,state FROM pending_messages ORDER BY message_id")],
}
connection.close()
matching=[row for row in data["processed"] if row["message_id"]==message_id and row["thread_id"]==thread_id and row["outbound_message_id"]]
data["ready"]=len(data["processed"])==1 and len(matching)==1 and not data["pending"] and len(data["threads"])==1 and data["threads"][0]["thread_id"]==thread_id
print(json.dumps(data, sort_keys=True, separators=(",", ":")))
PY
    chmod 0600 "$run_root/db-evidence.json"
    if python3 - "$run_root/db-evidence.json" <<'PY'
import json,sys
raise SystemExit(0 if json.load(open(sys.argv[1], encoding="utf-8"))["ready"] else 1)
PY
    then
      db_ready=true
      if test "$transport_deadline" -eq 0; then
        transport_deadline=$(( $(date +%s) + 60 ))
      fi
    fi
  fi

  if test "$db_ready" = true && test -n "$reply_message_id"; then
    reply_validation_attempt=1
    while test "$reply_validation_attempt" -le 6; do
      run_sender_helper get-message --inbox-id "$sender_id" --id "$reply_message_id" > "$run_root/reply.json"
      chmod 0600 "$run_root/reply.json"
      reply_validator_status=0
      reply_attachment_id=$(
        python3 - "$run_root/reply.json" "$sender_thread_id" "$receiver_address" "$nonce" \
          2> "$run_root/reply-validator.err" <<'PY'
from email.utils import parseaddr
import json,sys
path, expected_thread_id, expected_from, nonce = sys.argv[1:]
row=json.load(open(path, encoding="utf-8"))
if row.get("thread_id") != expected_thread_id or parseaddr(row.get("from",""))[1].casefold() != expected_from.casefold():
    raise SystemExit("reply is not from the receiver on the original sender thread")
if nonce not in row.get("text",""):
    raise SystemExit("reply validation failed: nonce marker not present in body")
attachments=row.get("attachments", [])
if len(attachments)!=1:
    raise SystemExit(f"reply attachment validation failed: attachments={len(attachments)}")
attachment=attachments[0]
if attachment.get("filename")!="result.txt":
    raise SystemExit(f"reply attachment validation failed: filename={attachment.get('filename')!r}")
if attachment.get("content_type")!="text/plain":
    raise SystemExit(f"reply attachment validation failed: content_type={attachment.get('content_type')!r}")
attachment_id=attachment.get("attachment_id") or attachment.get("id")
if not attachment_id:
    raise SystemExit("reply attachment validation failed: missing attachment id")
print(attachment_id)
PY
      ) || reply_validator_status=$?
      chmod 0600 "$run_root/reply-validator.err"
      if test "$reply_validator_status" -ne 0; then
        if grep -Fq 'reply attachment validation failed: attachments=0' \
          "$run_root/reply-validator.err"; then
          if test "$reply_validation_attempt" -lt 6; then
            reply_validation_attempt=$((reply_validation_attempt + 1))
            sleep 5
            continue
          fi
          fail "reply attachment validation failed: attachments=0 after retries"
        fi
        sed -n '1,240p' "$run_root/reply-validator.err" >&2
        (exit "$reply_validator_status")
      fi
      if test -z "$reply_attachment_id"; then
        fail "reply attachment id not parsed"
      fi
      run_sender_helper get-attachment --inbox-id "$sender_id" --message-id "$reply_message_id" \
        --attachment-id "$reply_attachment_id" > "$run_root/reply-result.txt"
      if ! cmp -s "$run_root/reply-result.txt" "$expected_file"; then
        fail "reply attachment content does not match the expected uppercase transform"
      fi
      chmod 0600 "$run_root/reply-result.txt"
      case ",$receiver_labels," in *,read,*) ;; *) fail 'receiver inbound message is not labeled read' ;; esac
      break 2
    done
  fi
  if test "$transport_deadline" -gt 0 && test "$(date +%s)" -ge "$transport_deadline"; then
    fail 'reply did not arrive within the 60-second transport grace after processing'
  fi
  sleep 2
done
test "$db_ready" = true && test -n "$reply_message_id" || fail 'live exchange exceeded the 20-minute observation deadline'
if test ! -f "$backend_probe"; then
  test -f "$backend_probe_unavailable" || \
    fail 'best-effort active child environment probe did not observe an agent-managed child'
  printf 'WARNING: child /proc environment was permission-restricted; relying on session and reply evidence.\n' >&2
fi

session_id=$(python3 - "$run_root/db-evidence.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["threads"][0]["session_id"])
PY
)
docker exec --env HOME="$container_home" "$container_id" sh -c \
  'cd "$HOME/.dearmachine/entrypoint/main" && exec "$HOME/.local/bin/machtiani" project show --json' \
  > "$run_root/machtiani-project-live.json"
chmod 0600 "$run_root/machtiani-project-live.json"
project_store=$(python3 - "$run_root/machtiani-project-live.json" "$container_home" <<'PY'
from pathlib import Path
import json,sys
data=json.load(open(sys.argv[1], encoding="utf-8"))
store=Path(data.get("store", ""))
if data.get("status")!="initialized" or not store.is_absolute() or Path(sys.argv[2]) not in store.parents:
    raise SystemExit("Machtiani project show returned an unsafe or uninitialized store")
print(store)
PY
)
docker cp "$container_id:$project_store/sessions/$session_id" "$run_root/machtiani-session" >/dev/null
chmod -R go-rwx "$run_root/machtiani-session"
scan_sensitive_artifacts "$run_root/machtiani-session" || \
  fail 'copied Machtiani session contained credential material and was replaced'

python3 - "$run_root/machtiani-session" <<'PY'
from pathlib import Path
import sys
session_root=Path(sys.argv[1])
trajectory=session_root/"trajectory"/"agent.jsonl"
if not trajectory.is_file() or not trajectory.read_text(encoding="utf-8").strip():
    raise SystemExit("Machtiani session has no non-empty agent trajectory")
print("Machtiani session trajectory verified")
PY

docker exec "$container_id" /workspace/machtiani/tests/e2e-installation-procedure/container-agent.sh --postconditions
docker exec "$container_id" git -C /workspace/machtiani status --porcelain=v2 > "$run_root/container-status-after-mail"
chmod 0600 "$run_root/container-status-after-mail"
cmp -s "$run_root/container-status-before-mail" "$run_root/container-status-after-mail" || \
  fail 'read-only email changed the container project worktree'

unset nonce message_body idempotency_key
run_complete=true
