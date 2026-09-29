#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'submodule maintenance test failure: %s\n' "$*" >&2
  exit 1
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/machtiani-submodule-maintenance-test.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

configure_repository() {
  git -C "$1" config user.name 'Submodule Test'
  git -C "$1" config user.email 'submodule-test@example.invalid'
  git -C "$1" config commit.gpgsign false
}

components=(dearmachine dearmachine-concierge machtiani-harness)
mapfile -t configured_components < <(
  git -C "$repo_root" config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
    awk '{print $2}' | sort
)
test "${configured_components[*]}" = "${components[*]}" || fail 'umbrella does not declare the expected three-component layout'

for component in "${components[@]}"; do
  repository=$test_root/source-$component
  origin=$test_root/origin-$component.git
  git init --quiet --initial-branch=main "$repository"
  configure_repository "$repository"
  printf 'initial\n' > "$repository/value.txt"
  git -C "$repository" add -- value.txt
  git -C "$repository" commit --quiet -m 'test: initial component'
  git init --quiet --bare --initial-branch=main "$origin"
  git -C "$repository" remote add origin "$origin"
  git -C "$repository" push --quiet --set-upstream origin main
done

umbrella=$test_root/umbrella
git init --quiet --initial-branch=main "$umbrella"
configure_repository "$umbrella"
for component in "${components[@]}"; do
  env GIT_ALLOW_PROTOCOL=file git -C "$umbrella" submodule add --quiet "$test_root/origin-$component.git" "$component"
done
install -D -m 0755 "$repo_root/scripts/update-submodules.sh" "$umbrella/scripts/update-submodules.sh"
install -m 0755 "$repo_root/scripts/worktree-setup" "$umbrella/scripts/worktree-setup"
install -m 0755 "$repo_root/scripts/worktree-teardown" "$umbrella/scripts/worktree-teardown"
git -C "$umbrella" add -- .gitmodules scripts/update-submodules.sh scripts/worktree-setup scripts/worktree-teardown "${components[@]}"
git -C "$umbrella" commit --quiet -m 'test: seed umbrella'

for component in "${components[@]}"; do
  repository=$test_root/source-$component
  printf 'advanced\n' >> "$repository/value.txt"
  git -C "$repository" add -- value.txt
  git -C "$repository" commit --quiet -m 'test: advance component'
  git -C "$repository" push --quiet origin main
done

env GIT_ALLOW_PROTOCOL=file "$umbrella/scripts/update-submodules.sh" >/dev/null
expected_subject='Update submodule pins: dearmachine, dearmachine-concierge, machtiani-harness'
test "$(git -C "$umbrella" log -1 --format=%s)" = "$expected_subject" || fail 'pointer commit does not name all changed components'
for component in "${components[@]}"; do
  expected=$(git --git-dir="$test_root/origin-$component.git" rev-parse main)
  actual=$(git -C "$umbrella" rev-parse "HEAD:$component")
  test "$actual" = "$expected" || fail "$component was not advanced to its local origin tip"
done

before=$(git -C "$umbrella" rev-parse HEAD)
env GIT_ALLOW_PROTOCOL=file "$umbrella/scripts/update-submodules.sh" >/dev/null
test "$(git -C "$umbrella" rev-parse HEAD)" = "$before" || fail 'no-change update created a commit'

mkdir "$test_root/worktrees"
TMPDIR=$test_root/worktrees "$umbrella/scripts/worktree-setup" "$umbrella/dearmachine-concierge" installer-helper >/dev/null
worktree=$test_root/worktrees/wt-dearmachine-concierge-installer-helper
test "$(git -C "$worktree" rev-parse HEAD)" = "$(git -C "$umbrella" rev-parse HEAD:dearmachine-concierge)" || fail 'worktree helper ignored the installer gitlink'
"$umbrella/scripts/worktree-teardown" "$worktree" >/dev/null

printf 'submodule maintenance test passed\n'
