#!/usr/bin/env bash
set -euo pipefail

omp_binary=/opt/ixe/agents/omp/bin/omp
case "$(uname -m)" in
  x86_64) omp_loader=/nix/var/nix/profiles/ixe-glibc/lib/ld-linux-x86-64.so.2 ;;
  aarch64) omp_loader=/nix/var/nix/profiles/ixe-glibc/lib/ld-linux-aarch64.so.1 ;;
  *)
    printf 'Unsupported OMP IXE architecture: %s\n' "$(uname -m)" >&2
    exit 1
    ;;
esac

test -x "$omp_binary"
test -x "$omp_loader"
export PI_CODING_AGENT_DIR=/run/ixe/agent-state/omp
export OMP_SKIP_SETUP=1
export OMP_DAEMON_RUNTIME_DIR=/run/ixe/agent-state/omp/run

exec "$omp_loader" \
  --library-path /nix/var/nix/profiles/ixe-glibc/lib \
  "$omp_binary" "$@"
