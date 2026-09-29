#!/bin/sh
set -eu
if [ "$(uname -s)" = Darwin ]; then
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    printf '%s\n' 'Apple Command Line Tools are required. Run `xcode-select --install`, complete installation, then rerun this command.' >&2
    exit 1
  fi
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'Python 3 is required to start the Standard builder. Install Python 3, then rerun this command.' >&2
  exit 1
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/standard-build.py" "$@"
