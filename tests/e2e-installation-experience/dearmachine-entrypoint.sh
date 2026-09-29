#!/usr/bin/env bash
set -euo pipefail

native_dearmachine=${HOME:-/home/installer}/.local/bin/dearmachine
if test -f /run/ixe/curl-mode && test ! -e /run/ixe/session-running && test "$#" -eq 0; then
  test -x "$native_dearmachine" || { printf 'Run the curl bootstrap shown in the SSH welcome first.\n' >&2; exit 1; }
  exec /usr/local/bin/run-install-evaluation
fi
if test -x "$native_dearmachine"; then
  exec "$native_dearmachine" "$@"
fi

# The IXE wraps only the initial bare invocation so it can record the terminal,
# verify postconditions, and retain private artifacts. Argument-bearing calls
# still exercise the packaged bootstrap command directly.
if test "$#" -gt 0; then
  exec /nix/var/nix/profiles/ixe-installer/bin/dearmachine "$@"
fi
exec /usr/local/bin/run-install-evaluation
