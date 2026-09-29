#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

git submodule update --init --recursive

mapfile -t submodules < <(
  git config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
    awk '{print $2}'
)
(( ${#submodules[@]} > 0 )) || {
  printf 'Refusing to update: .gitmodules declares no submodules.\n' >&2
  exit 1
}

for sub in "${submodules[@]}"; do
  git -C "$sub" fetch origin
done

for sub in "${submodules[@]}"; do
  if [[ -n "$(git -C "$sub" status --porcelain --untracked-files=no)" ]]; then
    printf 'Refusing to update %s: the submodule has uncommitted tracked changes.\n' "$sub" >&2
    exit 1
  fi
done

changed=()
for sub in "${submodules[@]}"; do
  if tip="$(git -C "$sub" rev-parse --verify refs/remotes/origin/main 2>/dev/null)"; then
    :
  elif tip="$(git -C "$sub" rev-parse --verify refs/remotes/origin/master 2>/dev/null)"; then
    :
  else
    printf 'Refusing to update %s: origin has neither a main nor master branch.\n' "$sub" >&2
    exit 1
  fi

  head="$(git -C "$sub" rev-parse HEAD)"
  if [[ "$head" != "$tip" ]]; then
    git -C "$sub" checkout --detach "$tip"
    git add -- "$sub"
    changed+=("$sub")
  fi
done

if (( ${#changed[@]} == 0 )); then
  printf 'No submodule pins changed; no commit created.\n'
  exit 0
fi

if git diff --cached --quiet; then
  printf 'Submodule checkouts changed, but no pointer updates are staged.\n' >&2
  exit 1
fi

printf -v changed_list '%s, ' "${changed[@]}"
changed_list=${changed_list%, }
git commit -m "Update submodule pins: $changed_list"
printf 'Updated submodule pins in a commit. Review and push when ready.\n'
