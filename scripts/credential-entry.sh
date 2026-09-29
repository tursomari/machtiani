#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'credential entry error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage:
  credential-entry.sh prepare --name NAME --destination PATH --format raw
  credential-entry.sh prepare --name NAME --destination PATH --format environment --variable NAME
  credential-entry.sh enter --name NAME
  credential-entry.sh status --name NAME
  credential-entry.sh wait --name NAME [--timeout SECONDS]
EOF
}

validate_name() {
  case "$1" in
    enter-llm-key|enter-email-key) ;;
    *) die 'helper name must be enter-llm-key or enter-email-key' ;;
  esac
}

validate_variable() {
  [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die 'invalid environment variable name'
}

require_private_home_path() {
  case "$1" in
    "$HOME"/*) ;;
    *) die 'credential destination must be an absolute path beneath HOME' ;;
  esac
}

state_root() {
  printf '%s/dearmachine/installation\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

spec_path() {
  printf '%s/%s.spec\n' "$(state_root)" "$1"
}

status_path() {
  printf '%s/%s.status\n' "$(state_root)" "$1"
}

draft_path() {
  printf '%s/%s.input\n' "$(state_root)" "$1"
}

write_status() {
  local name=$1 value=$2 root temporary destination
  root=$(state_root)
  destination=$(status_path "$name")
  install -d -m 0700 "$root"
  temporary=$(mktemp "$root/.${name}.status.XXXXXX")
  chmod 0600 "$temporary"
  printf '%s\n' "$value" > "$temporary"
  mv -f -- "$temporary" "$destination"
}

load_spec() {
  local name=$1 path line
  path=$(spec_path "$name")
  test -f "$path" && test ! -L "$path" || die "missing private helper specification for $name"
  # find(1) checks owner and exact mode portably; GNU and BSD stat(1) differ.
  test -n "$(find "$path" -prune -user "$(id -u)")" || die 'helper specification has the wrong owner'
  test -n "$(find "$path" -prune -perm 600)" || die 'helper specification must have mode 0600'
  # macOS ships Bash 3.2, which has no mapfile.
  credential_spec=()
  while IFS= read -r line || test -n "$line"; do
    credential_spec+=("$line")
  done < "$path"
  test "${#credential_spec[@]}" -eq 3 || die 'invalid helper specification'
  [[ ${credential_spec[0]} == destination=* ]] || die 'invalid helper destination specification'
  [[ ${credential_spec[1]} == format=* ]] || die 'invalid helper format specification'
  [[ ${credential_spec[2]} == variable=* ]] || die 'invalid helper variable specification'
  credential_destination=${credential_spec[0]#destination=}
  credential_format=${credential_spec[1]#format=}
  credential_variable=${credential_spec[2]#variable=}
  require_private_home_path "$credential_destination"
  case "$credential_format" in
    raw) test -z "$credential_variable" || die 'raw helper specification must not name a variable' ;;
    environment) validate_variable "$credential_variable" ;;
    *) die 'invalid helper credential format' ;;
  esac
}

prepare_helper() {
  local name= destination= format= variable= root spec temporary
  while test "$#" -gt 0; do
    case "$1" in
      --name) test "$#" -ge 2 || die '--name requires a value'; name=$2; shift 2 ;;
      --destination) test "$#" -ge 2 || die '--destination requires a value'; destination=$2; shift 2 ;;
      --format) test "$#" -ge 2 || die '--format requires a value'; format=$2; shift 2 ;;
      --variable) test "$#" -ge 2 || die '--variable requires a value'; variable=$2; shift 2 ;;
      *) die "unknown prepare option: $1" ;;
    esac
  done

  validate_name "$name"
  require_private_home_path "$destination"
  case "$format" in
    raw) test -z "$variable" || die '--variable is not valid with raw format' ;;
    environment) test -n "$variable" || die 'environment format requires --variable'; validate_variable "$variable" ;;
    *) die '--format must be raw or environment' ;;
  esac
  if test -e "$destination" && test -L "$destination"; then
    die 'credential destination must not be a symbolic link'
  fi

  umask 077
  root=$(state_root)
  spec=$(spec_path "$name")
  install -d -m 0700 "$root" "$HOME/.local/bin" "$HOME/.local/libexec"
  install -m 0700 "$0" "$HOME/.local/libexec/dearmachine-credential-entry"

  temporary=$(mktemp "$root/.${name}.spec.XXXXXX")
  chmod 0600 "$temporary"
  printf 'destination=%s\nformat=%s\nvariable=%s\n' \
    "$destination" "$format" "$variable" > "$temporary"
  mv -f -- "$temporary" "$spec"
  rm -f -- "$(status_path "$name")" "$(draft_path "$name")"

  temporary=$(mktemp "$HOME/.local/bin/.${name}.XXXXXX")
  chmod 0700 "$temporary"
  printf '%s\n' '#!/usr/bin/env bash' \
    "exec \"\$HOME/.local/libexec/dearmachine-credential-entry\" enter --name $name" \
    > "$temporary"
  mv -f -- "$temporary" "$HOME/.local/bin/$name"
}

enter_credential() {
  local name= draft marker editor_status=0 marker_seen=false destination_dir temporary
  local platform paste_instruction
  local enter_finished=false
  local -a entries=()
  while test "$#" -gt 0; do
    case "$1" in
      --name) test "$#" -ge 2 || die '--name requires a value'; name=$2; shift 2 ;;
      *) die "unknown enter option: $1" ;;
    esac
  done
  validate_name "$name"
  load_spec "$name"

  enter_cleanup() {
    local exit_status=$?
    trap - EXIT HUP INT TERM
    if test "$enter_finished" = false; then
      write_status "$name" 'failed:helper'
    fi
    exit "$exit_status"
  }
  trap enter_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  umask 077
  draft=$(draft_path "$name")
  marker='--- DEAR MACHINE CREDENTIAL INSTRUCTIONS ---'
  platform=$(uname -s 2>/dev/null || true)
  case "$platform" in
    Darwin) paste_instruction='Paste with Command+V.' ;;
    Linux) paste_instruction='Paste with Ctrl+Shift+V.' ;;
    *) paste_instruction="Paste using your terminal's Paste command." ;;
  esac
  if command -v micro >/dev/null 2>&1; then
    {
      printf '\n\n%s\n' "$marker"
      printf '%s\n' \
        'Paste your key anywhere above this line.' \
        '' \
        "$paste_instruction" \
        'Save with Ctrl+S.' \
        'Exit with Ctrl+Q.'
    } > "$draft"
    chmod 0600 "$draft"
    write_status "$name" 'started'

    micro "$draft" || editor_status=$?
    if test "$editor_status" -ne 0; then
      write_status "$name" 'failed:editor'
      enter_finished=true
      trap - EXIT HUP INT TERM
      return "$editor_status"
    fi

    while IFS= read -r line || test -n "$line"; do
      line=${line%$'\r'}
      if test "$line" = "$marker"; then
        marker_seen=true
        break
      fi
      test -z "$line" || entries+=("$line")
    done < "$draft"
  else
    # Without micro, read one line with echo disabled; nothing is drafted to disk.
    printf '%s Then press Enter. The key will not be shown.\n' "$paste_instruction" >&2
    write_status "$name" 'started'
    line=
    IFS= read -r -s line || test -n "$line" || true
    printf '\n' >&2
    line=${line%$'\r'}
    test -z "$line" || entries+=("$line")
    marker_seen=true
  fi
  if test "$marker_seen" != true || test "${#entries[@]}" -ne 1; then
    write_status "$name" 'failed:input'
    enter_finished=true
    trap - EXIT HUP INT TERM
    return 1
  fi
  credential_value=${entries[0]}
  if [[ $credential_value =~ [[:space:]] ]]; then
    write_status "$name" 'failed:input'
    enter_finished=true
    trap - EXIT HUP INT TERM
    return 1
  fi

  destination_dir=${credential_destination%/*}
  install -d -m 0700 "$destination_dir"
  temporary=$(mktemp "$destination_dir/.credential.XXXXXX")
  chmod 0600 "$temporary"
  if test "$credential_format" = environment; then
    printf '%s=%s\n' "$credential_variable" "$credential_value" > "$temporary"
  else
    printf '%s\n' "$credential_value" > "$temporary"
  fi
  mv -f -- "$temporary" "$credential_destination"
  rm -f -- "$draft"
  write_status "$name" 'success'
  unset credential_value entries
  enter_finished=true
  trap - EXIT HUP INT TERM
}

cleanup_credential_helper() {
  local name=$1
  rm -f -- \
    "$HOME/.local/bin/$name" \
    "$(spec_path "$name")" \
    "$(status_path "$name")" \
    "$(draft_path "$name")"
}

credential_status() {
  local name= status= status_file helper spec
  while test "$#" -gt 0; do
    case "$1" in
      --name) test "$#" -ge 2 || die '--name requires a value'; name=$2; shift 2 ;;
      *) die "unknown status option: $1" ;;
    esac
  done
  validate_name "$name"
  status_file=$(status_path "$name")
  helper=$HOME/.local/bin/$name
  spec=$(spec_path "$name")
  test -f "$helper" && test -f "$spec" || die "missing prepared credential helper for $name"

  if test -f "$status_file"; then
    IFS= read -r status < "$status_file" || true
  fi
  case "$status" in
    success)
      cleanup_credential_helper "$name"
      printf 'ready\n'
      ;;
    failed:*)
      printf 'Credential entry did not complete (%s).\n' "${status#failed:}" >&2
      return 1
      ;;
    started|'') printf 'pending\n' ;;
    *) die 'invalid credential helper status' ;;
  esac
}

wait_for_credential() {
  local name= timeout=1800 elapsed=0 status= status_file
  while test "$#" -gt 0; do
    case "$1" in
      --name) test "$#" -ge 2 || die '--name requires a value'; name=$2; shift 2 ;;
      --timeout) test "$#" -ge 2 || die '--timeout requires a value'; timeout=$2; shift 2 ;;
      *) die "unknown wait option: $1" ;;
    esac
  done
  validate_name "$name"
  [[ $timeout =~ ^[1-9][0-9]*$ ]] || die 'timeout must be a positive integer'
  status_file=$(status_path "$name")

  while test "$elapsed" -lt "$timeout"; do
    if test -f "$status_file"; then
      IFS= read -r status < "$status_file" || true
      case "$status" in
        success)
          cleanup_credential_helper "$name"
          return 0
          ;;
        failed:*)
          printf 'Credential entry did not complete (%s).\n' "${status#failed:}" >&2
          return 1
          ;;
        started|'') ;;
        *) die 'invalid credential helper status' ;;
      esac
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  printf 'Credential entry timed out.\n' >&2
  return 1
}

test "$#" -gt 0 || { usage >&2; exit 2; }
command_name=$1
shift
case "$command_name" in
  prepare) prepare_helper "$@" ;;
  enter) enter_credential "$@" ;;
  status) credential_status "$@" ;;
  wait) wait_for_credential "$@" ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
