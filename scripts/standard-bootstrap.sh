#!/bin/sh
# Rendered by prepare-standard-download.py. The checksum is part of this script.
# An optional argument names an already downloaded archive, which must still
# match the pinned checksum; otherwise the archive is downloaded from base_url.
set -eu
umask 077
base_url=@BASE_URL@
archive_name=@ARCHIVE_NAME@
archive_sha=@ARCHIVE_SHA@
release_id=@RELEASE_ID@
expected_platform=@PLATFORM@
local_archive=${1:-}
fail() { printf '%s\n' "$*" >&2; exit 1; }
test "$(uname -sm)" = "$expected_platform" || fail "This download is for $expected_platform computers."
if test "$(uname -s)" = Darwin; then
  # Apple's Git and Python come with the Command Line Tools.
  /usr/bin/xcode-select -p >/dev/null 2>&1 ||
    fail 'Apple Command Line Tools are required. Run xcode-select --install, complete the installation, then run this again.'
fi
test "$(id -u)" != 0 || fail 'Run the installer as your normal user, without sudo.'
: "${HOME:?HOME must be set}"
case "$HOME" in /*) ;; *) fail 'HOME must be an absolute path.' ;; esac
data_root=${XDG_DATA_HOME:-"$HOME/.local/share"}/dearmachine
case "$data_root" in /*) ;; *) fail 'XDG_DATA_HOME must be absolute.' ;; esac
case "$data_root" in *[[:space:]:]*) fail 'This preview needs an installation path without whitespace or colon.' ;; esac
for tool in curl tar gzip find readlink; do
  command -v "$tool" >/dev/null || fail "The bootstrap requires $tool."
done
if command -v sha256sum >/dev/null; then
  digest() { sha256sum -- "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null; then
  digest() { shasum -a 256 -- "$1" | cut -d ' ' -f 1; }
else
  fail 'The bootstrap requires sha256sum or shasum.'
fi
# POSIX find keeps these checks identical on Linux and macOS.
private_directory() {
  test ! -L "$1" || fail "Refusing a symbolic-link installation directory: $1"
  mkdir -p "$1"
  test -n "$(find "$1" -prune -user "$(id -u)")" || fail "Installation directory is not owned by you: $1"
  test -z "$(find "$1" -prune \( -perm -0020 -o -perm -0002 \))" || fail "Installation directory is writable by others: $1"
}
private_directory "$data_root"
private_directory "$data_root/releases"
private_directory "$data_root/downloads"
private_directory "$HOME/.local/bin"
release=$data_root/releases/$release_id
public_commands='dearmachine machtiani machtiani-installer machtiani-model-host agent-manager'
# Check every destination before downloading or activating anything.
for name in $public_commands; do
  link=$HOME/.local/bin/$name
  if test -e "$link" || test -L "$link"; then
    test -L "$link" && test "$(readlink "$link")" = "$release/bin/$name" ||
      fail "Existing $link was left unchanged. Automatic migration is not supported."
  fi
done
lock=$data_root/.bootstrap-lock
mkdir "$lock" 2>/dev/null || fail "Another bootstrap may be running; inspect $lock before retrying."
trap 'rmdir "$lock"' EXIT
archive=$data_root/downloads/$archive_sha.tar.gz
test ! -L "$archive" || fail 'Refusing a symbolic-link download cache.'
verified_archive() {
  test -f "$archive" && test "$(digest "$archive")" = "$archive_sha"
}
if ! verified_archive; then
  partial=$archive.part.$$
  # Never replace an existing partial file, including a symlink.
  (set -C; : > "$partial") || fail 'The temporary download path already exists.'
  if test -n "$local_archive"; then
    test -f "$local_archive" && test ! -L "$local_archive" || fail "The supplied archive is not a regular file: $local_archive"
    cat -- "$local_archive" > "$partial"
  else
    curl -fSL --retry 2 "$base_url/$archive_name" -o "$partial"
  fi
  test "$(digest "$partial")" = "$archive_sha" || fail 'Download checksum failed; nothing was activated.'
  mv "$partial" "$archive"
fi
if test -e "$release" || test -L "$release"; then
  test ! -L "$release" && test -f "$release/.activated" || fail "Incomplete release retained at $release; inspect it before retrying."
  IFS= read -r installed_sha < "$release/.activated"
  test "$installed_sha" = "$archive_sha" || fail 'Existing release does not match this download.'
else
  mkdir "$release"
  # The pinned digest authenticates the complete producer-generated archive.
  tar -xzf "$archive" --no-same-owner -C "$release"
  sh "$release/bootstrap-runtime.sh"
fi
for name in $public_commands; do test -x "$release/bin/$name" || fail "Release is missing $name."; done
"$release/bin/dearmachine" --help >/dev/null
"$release/bin/machtiani-installer" --help >/dev/null
"$release/bin/machtiani" --version >/dev/null
"$release/bin/agent-manager" --help >/dev/null
"$release/bin/git-lfs" version >/dev/null
"$release/bin/python3" --version >/dev/null
printf '%s\n' "$archive_sha" > "$release/.activated"
for name in $public_commands; do
  link=$HOME/.local/bin/$name
  test -L "$link" || ln -s "$release/bin/$name" "$link"
done
"$release/bin/machtiani-installer" configure-shell
"$release/bin/machtiani-installer" _launcher-check
printf '\nDear Machine software is ready. No Nix was installed.\n'
printf 'Run %s/.local/bin/dearmachine to configure it or open the concierge.\n' "$HOME"
