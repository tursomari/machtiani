#!/bin/sh
# Dear Machine release installer for Linux and macOS, rendered for one GitHub
# release by render-release-installers.py. Do not publish it unrendered.
set -eu

main() {
  repository=@REPOSITORY@
  tag=@TAG@
  source_ref=@SOURCE_REF@
  signer_workflow=@SIGNER_WORKFLOW@
  download_url=@DOWNLOAD_URL@

  say() { printf '%s\n' "$*" >&2; }
  fail() { printf 'Dear Machine installer: %s\n' "$*" >&2; exit 1; }

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64) target=linux-x64 ;;
    Linux:aarch64|Linux:arm64) target=linux-arm64 ;;
    Darwin:arm64) target=darwin-arm64 ;;
    Darwin:x86_64) target=darwin-x64 ;;
    *) fail 'This operating system or processor is not supported.' ;;
  esac
  test "$(id -u)" != 0 || fail 'Run the installer as your normal user, without sudo.'
  : "${HOME:?HOME must be set}"
  if command -v sha256sum >/dev/null 2>&1; then
    digest() { sha256sum -- "$1" | cut -d ' ' -f 1; }
  elif command -v shasum >/dev/null 2>&1; then
    digest() { shasum -a 256 -- "$1" | cut -d ' ' -f 1; }
  else
    fail 'The installer needs sha256sum or shasum to check downloads.'
  fi

  prefix="dearmachine-$tag-$target"
  archive="$prefix.tar.gz"
  bootstrap="$prefix.bootstrap.sh"
  umask 077
  work=$(mktemp -d "${TMPDIR:-/tmp}/dearmachine-install.XXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP

  # Print the expected checksum of one file named in SHA256SUMS.
  expected() {
    awk -v name="$1" '($2 == name || $2 == "*" name) && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1; found = 1; exit }
      END { if (!found) exit 1 }' "$work/SHA256SUMS"
  }

  # Signed-in gh downloads through the GitHub API, which also works while the
  # repository is private. Otherwise files come from the public release URL.
  if ! command -v gh >/dev/null 2>&1; then
    confirm_unverified missing
    source=web verify=false
  elif ! github_cli; then
    confirm_unverified other
    source=web verify=false
  elif ! gh_supported; then
    confirm_unverified outdated
    source=web verify=false
  elif gh auth status >/dev/null 2>&1; then
    source=gh verify=true
  else
    source=web verify=true
  fi

  say "Downloading the checksums for Dear Machine $tag..."
  get SHA256SUMS
  if [ "$verify" = true ]; then
    # The published bundle lets gh verify without signing in; it is signed,
    # so obtaining it from the release does not weaken the check.
    if get_optional attestation.sigstore.json; then
      set -- --bundle "$work/attestation.sigstore.json"
    elif [ "$source" = gh ]; then
      set --
    else
      confirm_unverified signed-out
      verify=false
    fi
  fi
  if [ "$verify" = true ]; then
    say 'Checking that this release was built by the official release workflow...'
    if ! gh attestation verify "$work/SHA256SUMS" "$@" --repo "$repository" \
        --signer-workflow "$signer_workflow" --source-ref "$source_ref" \
        --deny-self-hosted-runners >"$work/verification.log" 2>&1; then
      cat "$work/verification.log" >&2
      fail 'This release could not be verified, so nothing was installed. Please report this to the Dear Machine maintainers.'
    fi
    say 'Release verified.'
  fi
  if ! expected "$archive" >/dev/null || ! expected "$bootstrap" >/dev/null; then
    fail "Release $tag has no download for $target yet. Nothing was installed."
  fi

  say "Downloading Dear Machine $tag for $target..."
  get "$bootstrap"
  get "$archive"
  for name in "$bootstrap" "$archive"; do
    test "$(digest "$work/$name")" = "$(expected "$name")" ||
      fail "$name does not match the release checksums, so nothing was installed."
  done
  sh "$work/$bootstrap" "$work/$archive"
}

# gh 2.68.0 is the oldest release with --source-ref that also reads the
# current Sigstore trusted root.
# Other programs, such as some Python packages, also install a gh command.
github_cli() {
  gh --version 2>/dev/null | awk 'NR == 1 && /^gh version [0-9]/ { found = 1 } END { exit !found }'
}

gh_supported() {
  gh --version 2>/dev/null | awk 'NR == 1 && /^gh version [0-9]/ {
    split($3, v, ".")
    supported = v[1] > 2 || (v[1] == 2 && v[2] >= 68)
  } END { exit !supported }'
}

# Download one release file into $work; get_optional reports absence quietly.
get_optional() {
  if [ "$source" = gh ]; then
    gh release download "$tag" --repo "$repository" --pattern "$1" --dir "$work" >/dev/null 2>&1
  else
    # Check the status explicitly: some curl releases exit 0 on an HTTP error
    # when --fail is combined with --retry.
    status=$(curl --silent --location --proto-redir '=https' --connect-timeout 30 \
      --write-out '%{http_code}' --output "$work/$1" "$download_url/$1") && [ "$status" = 200 ] ||
      { rm -f -- "$work/$1"; return 1; }
  fi
}

get() {
  get_optional "$1" || fail "Could not download $1. Check your connection and try again."
}

confirm_unverified() {
  if [ "$1" = missing ]; then
    reason="It uses GitHub's free gh tool for that check, and gh isn't installed on this computer."
    steps="  1. Install gh by following https://cli.github.com
       (on a Mac with Homebrew: brew install gh)
  2. Run this installer again. If it asks you to sign in, run: gh auth login"
  elif [ "$1" = other ]; then
    reason="It uses GitHub's gh tool for that check, but the gh command on this computer is a different program with the same name."
    steps="  1. Install GitHub's gh by following https://cli.github.com
  2. Make sure typing gh runs it: gh --version should print \"gh version ...\".
     If the other gh comes from a Python or conda environment, leave that
     environment first (for example: conda deactivate).
  3. Run this installer again. If it asks you to sign in, run: gh auth login"
  elif [ "$1" = outdated ]; then
    reason="It uses GitHub's gh tool for that check, and the gh on this computer is too old to do it. Version 2.68.0 or newer is needed."
    steps="  1. Update gh by following https://cli.github.com
       (on a Mac with Homebrew: brew upgrade gh)
  2. Run this installer again. If it asks you to sign in, run: gh auth login"
  else
    reason="It uses GitHub's gh tool for that check. gh is installed, but this release can only be checked while gh is signed in to GitHub."
    steps="  1. Sign in with: gh auth login
  2. Run this installer again."
  fi
  cat >&2 <<EOF

Before installing, this installer normally checks that Dear Machine really
came from its official release process and wasn't changed along the way.
$reason

The safest choice is to stop here and set up gh. It only takes a minute:

$steps

If you'd rather continue now, the installer will still compare each file with
the release's published checksums. That catches a damaged download, but it
can't tell whether someone changed the files on purpose.

EOF
  if ! (: </dev/tty) 2>/dev/null; then
    fail 'There is no terminal to confirm with, so nothing was installed.'
  fi
  printf 'Type yes to continue without the check, or press Enter to stop: ' >&2
  answer=
  IFS= read -r answer </dev/tty || answer=
  if [ "$answer" != yes ]; then
    say 'Stopped. Nothing was installed.'
    exit 1
  fi
  say 'Continuing without the release check.'
}

# Keep all work inside functions so piping this file to sh cannot start
# anything until the complete script has arrived.
main "$@"
