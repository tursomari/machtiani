# Nix is pinned by both release tag and immutable image digest.
FROM nixos/nix:2.24.5@sha256:4ad79a0ab633944869a37921f096d35a3f2c7a0275d98b7bfa0cd3cba5a6b96e

ENV NIX_CONFIG="experimental-features = nix-command flakes"

COPY machtiani-harness /workspace/machtiani/machtiani-harness
WORKDIR /workspace/machtiani

# Realize the Machtiani smoke shell for Git, jq, and Python assertions. Git
# LFS comes from the same locked nixpkgs input and is required by
# `dearmachine up --create` when it creates the default entry-point skeleton.
RUN nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c true \
 && nix --extra-experimental-features 'nix-command flakes' \
      profile install --impure --expr \
      'let f = builtins.getFlake "path:/workspace/machtiani/machtiani-harness"; p = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in p.git-lfs'

# ForgeCode is the DearMachine backend exercised by the agent-driven path.
# TARGETARCH is Docker's automatic platform argument; credential material is
# deliberately absent from both build arguments and image layers.
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) \
        forge_target=x86_64-unknown-linux-musl; \
        forge_sha256=4ae6d86cdd001e649e1b435d99243d7249d169e30b24529e350f9dfec798f29a \
        ;; \
      arm64) \
        forge_target=aarch64-unknown-linux-musl; \
        forge_sha256=983652eb26b1e4900633877bc2a1a0e5af788196969bc4b18e184ad3d50cd254 \
        ;; \
      *) \
        printf 'ERROR: unsupported TARGETARCH for ForgeCode: %s\n' "$TARGETARCH" >&2; \
        exit 1 \
        ;; \
    esac; \
    export forge_target forge_sha256; \
    nix --extra-experimental-features 'nix-command flakes' \
      develop path:/workspace/machtiani/machtiani-harness#smoke -c bash -euo pipefail -c '\
        forge_tmp=$(mktemp -d /tmp/forge-install.XXXXXX); \
        trap '\''rm -rf -- "$forge_tmp"'\'' EXIT; \
        forge_download="$forge_tmp/forge"; \
        curl --fail --location --silent --show-error \
          --retry 3 --retry-delay 2 --retry-all-errors \
          --connect-timeout 15 --max-time 180 \
          --output "$forge_download" \
          "https://github.com/tailcallhq/forgecode/releases/download/v2.13.21/forge-${forge_target}"; \
        printf "%s  %s\n" "$forge_sha256" "$forge_download" | sha256sum -c -; \
        mkdir -p /usr/local/bin; \
        install -m 0755 "$forge_download" /usr/local/bin/forge; \
        test "$(/usr/local/bin/forge --version)" = "forge 2.13.21" \
      '

# Supply ordinary Linux process supervision tools. Keep this separate from
# the expensive smoke-shell layer, and prefer the image's existing coreutils
# where their commands or manual pages overlap.
RUN nix --extra-experimental-features 'nix-command flakes' \
      profile install --priority 6 --impure --expr \
      'let f = builtins.getFlake "path:/workspace/machtiani/machtiani-harness"; p = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in p.buildEnv { name = "ipe-process-tools"; paths = [ p.util-linux p.procps ]; }' \
 && command -v setsid ps >/dev/null

COPY . /workspace/machtiani

CMD ["/workspace/machtiani/tests/e2e-installation-procedure/container-agent.sh"]
