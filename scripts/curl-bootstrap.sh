#!/bin/sh
# Local distribution template. Render with prepare-curl-bundle.py; do not
# publish the unrendered template or treat loopback HTTP as release signing.
set -eu

main() {
  base_url=@BASE_URL@
  installer_path=@INSTALLER_PATH@
  git_path=@GIT_PATH@
  source_sha=@SOURCE_SHA@
  closure_sha=@CLOSURE_SHA@
  expected_system=@SYSTEM@
  release=@RELEASE@
  fail() { printf 'Machtiani bootstrap: %s\n' "$*" >&2; exit 1; }
  case "$(uname -s):$(uname -m)" in
    Linux:x86_64) system=x86_64-linux ;;
    Linux:aarch64|Linux:arm64) system=aarch64-linux ;;
    Darwin:x86_64) system=x86_64-darwin ;;
    Darwin:arm64) system=aarch64-darwin ;;
    *) fail 'Unsupported operating system or architecture.' ;;
  esac
  test "$system" = "$expected_system" || fail 'This bundle is for a different architecture.'
  command -v nix >/dev/null 2>&1 && command -v nix-store >/dev/null 2>&1 ||
    fail 'Nix is required for this local preview. Automatic Nix installation is deferred.'
  for tool in curl sha256sum gzip tar; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing bootstrap prerequisite: $tool"
  done
  : "${HOME:?HOME is required}"
  launch="$HOME/.local/bin/dearmachine"
  if test -L "$launch" || { test -e "$launch" && ! grep -qx '# Machtiani local bootstrap v1' "$launch"; }; then
    fail 'An existing dearmachine launcher would be overwritten; leaving it untouched.'
  fi
  umask 077
  release_root="$HOME/.local/share/machtiani/bootstrap/$release"
  mkdir -p "$release_root" "$HOME/.local/bin"
  scratch=$(mktemp -d "$release_root/download.XXXXXX")
  trap 'rm -rf -- "$scratch"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  fetch() { curl --fail --silent --show-error --connect-timeout 15 --max-time 600 --output "$2" "$base_url/$1"; }
  verify() { printf '%s  %s\n' "$1" "$2" | sha256sum --check --status || fail 'Artifact checksum verification failed.'; }

  # Validate both downloads before any import. A populated store does not need
  # to fetch the large closure at all. No nix build/run/profile evaluation here.
  fetch source.tar.gz "$scratch/source.tar.gz"
  verify "$source_sha" "$scratch/source.tar.gz"
  if ! nix-store --check-validity "$installer_path" "$git_path" >/dev/null 2>&1; then
    printf 'Downloading the prebuilt runtime from the local server...\n'
    fetch closure.nar.gz "$scratch/closure.nar.gz"
    verify "$closure_sha" "$scratch/closure.nar.gz"
    gzip -t "$scratch/closure.nar.gz"
    gzip -dc "$scratch/closure.nar.gz" | nix-store --import >/dev/null
  else
    printf 'Reusing the existing Nix runtime cache.\n'
  fi
  test -x "$installer_path/bin/dearmachine" || fail 'The imported installer is not executable.'
  nix-store --add-root "$release_root/installer-root" --indirect --realise "$installer_path" >/dev/null
  nix-store --add-root "$release_root/git-root" --indirect --realise "$git_path" >/dev/null

  if test -e "$release_root/source"; then
    test "$(cat "$release_root/source.sha256" 2>/dev/null)" = "$source_sha" ||
      fail 'An existing source directory does not match this bundle; leaving it untouched.'
  else
    mkdir "$scratch/source"
    tar -xzf "$scratch/source.tar.gz" -C "$scratch/source"
    # Only source files are distributed. Create new local Git metadata, never
    # copy host administrative paths, history, hooks, remotes, or credentials.
    for component in dearmachine machtiani-harness dearmachine-concierge .; do
      directory="$scratch/source/$component"
      "$git_path/bin/git" -C "$directory" init -q --initial-branch=main
      "$git_path/bin/git" -C "$directory" -c core.hooksPath=/dev/null -c advice.addEmbeddedRepo=false add --all
      "$git_path/bin/git" -C "$directory" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name='Machtiani Source Snapshot' -c user.email=snapshot@example.invalid \
        commit -q -m 'Snapshot of versioned installation sources'
    done
    mv "$scratch/source" "$release_root/source"
    printf '%s\n' "$source_sha" > "$release_root/source.sha256"
  fi
  # Store paths and release identifiers are validated by the bundle builder.
  cat > "$scratch/dearmachine" <<EOF
#!/bin/sh
# Machtiani local bootstrap v1
export DEARMACHINE_SOURCE_ROOT="\$HOME/.local/share/machtiani/bootstrap/$release/source"
exec "$installer_path/bin/dearmachine" "\$@"
EOF
  chmod 0755 "$scratch/dearmachine"
  mv "$scratch/dearmachine" "$launch"
  "$installer_path/bin/dearmachine" _launcher-check
  printf 'Installed the prebuilt Machtiani launcher. Run %s/.local/bin/dearmachine to open the wizard.\n' "$HOME"

}

# Keep all work inside one function so piping this file to sh cannot launch
# anything until the complete bootstrap body has arrived. The wizard is a
# separate command and therefore reads the terminal, not the curl pipe.
main "$@"
