#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'submodules-from-local test failure: %s\n' "$*" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
source_root=${SUBMODULE_SOURCE_ROOT:-$repo_root}

case "$source_root" in
  /*) ;;
  *) fail 'SUBMODULE_SOURCE_ROOT must be absolute' ;;
esac

test_root=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-submodules-local-test.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
target=$test_root/target

git clone --quiet --no-recurse-submodules "$source_root" "$target"
install -m 0755 "$repo_root/scripts/submodules-from-local.sh" \
  "$target/scripts/submodules-from-local.sh"
before=$(git -C "$target" rev-parse HEAD)

"$target/scripts/submodules-from-local.sh" --source "$source_root" >/dev/null

test "$(git -C "$target" rev-parse HEAD)" = "$before" || \
  fail 'helper changed the umbrella checkout HEAD'

while IFS= read -r path; do
  test -n "$path" || continue
  expected=$(git -C "$target" rev-parse "HEAD:$path")
  actual=$(git -C "$target/$path" rev-parse HEAD)
  test "$actual" = "$expected" || \
    fail "$path is not checked out at the recorded gitlink"
  test "$(git -C "$target/$path" rev-parse --show-toplevel)" = "$target/$path" || \
    fail "$path resolved to the parent umbrella worktree"
done < <(git -C "$target" config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

printf 'submodules-from-local test passed\n'
