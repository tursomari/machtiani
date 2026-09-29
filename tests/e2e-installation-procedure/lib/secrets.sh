#!/usr/bin/env bash

# Strict runtime reader for the umbrella repository's unversioned .secrets.
# Source this file, call secrets_load, then retrieve values into a named shell
# variable with secrets_get. Credential values are never written to stdout.

secrets_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

secrets_validate_file() {
  secrets_path=$1

  command -v python3 >/dev/null 2>&1 || {
    secrets_error 'Python 3 is required to validate .secrets safely.'
    return 1
  }
  python3 - "$secrets_path" <<'PY'
import os
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])

try:
    metadata = path.lstat()
except OSError as error:
    raise SystemExit(f"ERROR: cannot lstat {path}: {error}")

if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(f"ERROR: {path} must be a regular, non-symlink file")

if metadata.st_uid != os.geteuid():
    raise SystemExit(f"ERROR: {path} must be owned by the effective user")
if stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit(f"ERROR: {path} must have mode 0600")

try:
    raw = path.read_bytes()
except OSError as error:
    raise SystemExit(f"ERROR: cannot read {path}: {error}")

if b"\x00" in raw:
    raise SystemExit(f"ERROR: {path} contains a NUL byte")
if b"\r" in raw:
    raise SystemExit(f"ERROR: {path} contains a carriage return")
if raw and not raw.endswith(b"\n"):
    raise SystemExit(f"ERROR: {path} must end with LF")
try:
    raw.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(f"ERROR: {path} is not valid UTF-8")
PY
}

secrets_load() {
  secrets_path=${1:-}
  test -n "$secrets_path" || {
    secrets_error 'secrets_load requires the path to .secrets.'
    return 1
  }
  secrets_validate_file "$secrets_path" || return 1

  SECRETS_DEEPSEEK_API_KEY=
  SECRETS_AGENTMAIL_API_KEY=
  secrets_seen_deepseek=false
  secrets_seen_agentmail=false
  secrets_line_number=0

  while IFS= read -r secrets_line || test -n "$secrets_line"; do
    secrets_line_number=$((secrets_line_number + 1))
    case "$secrets_line" in
      *=*) ;;
      *)
        secrets_error "$secrets_path:$secrets_line_number is malformed; expected NAME=value."
        return 1
        ;;
    esac

    secrets_name=${secrets_line%%=*}
    secrets_value=${secrets_line#*=}
    test -n "$secrets_value" || {
      secrets_error "$secrets_path:$secrets_line_number has a blank value."
      return 1
    }

    case "$secrets_name" in
      DEEPSEEK_API_KEY)
        test "$secrets_seen_deepseek" = false || {
          secrets_error "$secrets_path contains duplicate DEEPSEEK_API_KEY entries."
          return 1
        }
        secrets_seen_deepseek=true
        SECRETS_DEEPSEEK_API_KEY=$secrets_value
        ;;
      AGENTMAIL_API_KEY)
        test "$secrets_seen_agentmail" = false || {
          secrets_error "$secrets_path contains duplicate AGENTMAIL_API_KEY entries."
          return 1
        }
        secrets_seen_agentmail=true
        SECRETS_AGENTMAIL_API_KEY=$secrets_value
        ;;
      *)
        secrets_error "$secrets_path:$secrets_line_number contains an unknown name."
        return 1
        ;;
    esac
  done < "$secrets_path"

  test "$secrets_seen_deepseek" = true || {
    secrets_error "$secrets_path is missing DEEPSEEK_API_KEY."
    return 1
  }
  test "$secrets_seen_agentmail" = true || {
    secrets_error "$secrets_path is missing AGENTMAIL_API_KEY."
    return 1
  }
  unset secrets_line secrets_line_number secrets_name secrets_value
  unset secrets_seen_deepseek secrets_seen_agentmail secrets_path
}

secrets_get() {
  secrets_requested_name=${1:-}
  secrets_output_name=${2:-}
  case "$secrets_output_name" in
    ''|*[!A-Za-z0-9_]*|[0-9]*)
      secrets_error 'secrets_get requires a valid output variable name.'
      return 1
      ;;
  esac

  case "$secrets_requested_name" in
    DEEPSEEK_API_KEY) secrets_requested_value=${SECRETS_DEEPSEEK_API_KEY-} ;;
    AGENTMAIL_API_KEY) secrets_requested_value=${SECRETS_AGENTMAIL_API_KEY-} ;;
    *)
      secrets_error 'secrets_get accepts only DEEPSEEK_API_KEY or AGENTMAIL_API_KEY.'
      return 1
      ;;
  esac
  test -n "$secrets_requested_value" || {
    secrets_error 'secrets_get called before a complete secrets_load.'
    return 1
  }
  printf -v "$secrets_output_name" '%s' "$secrets_requested_value"
  unset secrets_requested_name secrets_requested_value secrets_output_name
}

secrets_clear() {
  unset SECRETS_DEEPSEEK_API_KEY SECRETS_AGENTMAIL_API_KEY
  unset secrets_path secrets_line secrets_line_number secrets_name secrets_value
  unset secrets_seen_deepseek secrets_seen_agentmail
  unset secrets_requested_name secrets_requested_value secrets_output_name
}

secrets_self_test() (
  set -euo pipefail
  umask 077
  secrets_test_root=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-secrets-test.XXXXXX")
  trap 'rm -rf -- "$secrets_test_root"' EXIT HUP INT TERM

  write_case() {
    secrets_case_path=$1
    shift
    printf '%s' "$*" > "$secrets_case_path"
    chmod 0600 "$secrets_case_path"
  }

  valid_file="$secrets_test_root/valid"
  write_case "$valid_file" $'DEEPSEEK_API_KEY=deepseek-test=value\nAGENTMAIL_API_KEY=agentmail-test\n'
  secrets_load "$valid_file"
  secrets_get DEEPSEEK_API_KEY loaded_deepseek
  secrets_get AGENTMAIL_API_KEY loaded_agentmail
  test "$loaded_deepseek" = 'deepseek-test=value'
  test "$loaded_agentmail" = 'agentmail-test'
  test -z "${secrets_value+x}"

  malformed_file="$secrets_test_root/malformed"
  write_case "$malformed_file" $'DEEPSEEK_API_KEY=one\nnot-an-assignment\nAGENTMAIL_API_KEY=two\n'
  ! secrets_load "$malformed_file" 2>/dev/null

  duplicate_file="$secrets_test_root/duplicate"
  write_case "$duplicate_file" $'DEEPSEEK_API_KEY=one\nDEEPSEEK_API_KEY=two\nAGENTMAIL_API_KEY=three\n'
  ! secrets_load "$duplicate_file" 2>/dev/null

  unknown_file="$secrets_test_root/unknown"
  write_case "$unknown_file" $'DEEPSEEK_API_KEY=one\nAGENTMAIL_API_KEY=two\nOTHER_KEY=three\n'
  ! secrets_load "$unknown_file" 2>/dev/null

  blank_file="$secrets_test_root/blank"
  write_case "$blank_file" $'DEEPSEEK_API_KEY=\nAGENTMAIL_API_KEY=two\n'
  ! secrets_load "$blank_file" 2>/dev/null

  cr_file="$secrets_test_root/carriage-return"
  write_case "$cr_file" $'DEEPSEEK_API_KEY=one\r\nAGENTMAIL_API_KEY=two\n'
  ! secrets_load "$cr_file" 2>/dev/null

  nul_file="$secrets_test_root/nul"
  printf 'DEEPSEEK_API_KEY=one\0AGENTMAIL_API_KEY=two\n' > "$nul_file"
  chmod 0600 "$nul_file"
  ! secrets_load "$nul_file" 2>/dev/null

  no_final_lf_file="$secrets_test_root/no-final-lf"
  write_case "$no_final_lf_file" $'DEEPSEEK_API_KEY=one\nAGENTMAIL_API_KEY=two'
  ! secrets_load "$no_final_lf_file" 2>/dev/null

  secrets_clear
  test -z "${SECRETS_DEEPSEEK_API_KEY+x}"
  test -z "${SECRETS_AGENTMAIL_API_KEY+x}"

  printf 'secrets.sh self-test passed\n'
)

if test "${BASH_SOURCE[0]}" = "$0"; then
  case "${1:-}" in
    --self-test) secrets_self_test ;;
    *)
      secrets_error 'usage: secrets.sh --self-test'
      exit 2
      ;;
  esac
fi
