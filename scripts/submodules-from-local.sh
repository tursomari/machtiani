#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s --source <local-umbrella-checkout>\n' "${0##*/}" >&2
  exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
source_root=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || usage
      source_root=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ -n "$source_root" ] || usage
case "$source_root" in
  /*) ;;
  *)
    printf 'source must be an absolute local path\n' >&2
    exit 2
    ;;
esac
[ -d "$source_root" ] || {
  printf 'source is not a local directory: %s\n' "$source_root" >&2
  exit 2
}
source_root=$(CDPATH= cd -- "$source_root" && pwd -P)

[ "$source_root" != "$repo_root" ] || {
  printf 'source must be a different local umbrella checkout\n' >&2
  exit 2
}
git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null
git -C "$source_root" rev-parse --is-inside-work-tree >/dev/null

while IFS= read -r path; do
  [ -n "$path" ] || continue
  gitlink=$(git -C "$repo_root" rev-parse "HEAD:$path")
  source_submodule=$source_root/$path
  destination=$repo_root/$path

  git -C "$source_submodule" rev-parse --is-inside-work-tree >/dev/null || {
    printf 'source submodule is not initialized: %s\n' "$source_submodule" >&2
    exit 1
  }
  git -C "$source_submodule" cat-file -e "$gitlink^{commit}" || {
    printf 'source submodule does not contain required gitlink %s for %s\n' "$gitlink" "$path" >&2
    exit 1
  }

  git -C "$repo_root" submodule init -- "$path"
  destination_root=$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null || :)
  if [ -n "$destination_root" ] && \
     [ "$(CDPATH= cd -- "$destination_root" && pwd -P)" = "$(CDPATH= cd -- "$destination" && pwd -P)" ]; then
    git -C "$destination" fetch --no-tags "$source_submodule" "$gitlink"
  else
    if [ -e "$destination" ] && [ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      printf 'submodule destination is not an empty Git worktree: %s\n' "$destination" >&2
      exit 1
    fi
    git clone --no-checkout "$source_submodule" "$destination"
  fi
  git -C "$destination" checkout --detach "$gitlink"
  test "$(git -C "$destination" rev-parse HEAD)" = "$gitlink"
done < <(git -C "$repo_root" config --file .gitmodules --get-regexp '^submodule\..*\.path$' | awk '{print $2}')

git -C "$repo_root" submodule status --recursive
