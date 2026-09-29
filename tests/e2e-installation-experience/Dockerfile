# Nix is pinned by release tag and immutable image digest. The image contains
# only the neutral IXE operating environment; agent state and credentials are
# copied into the running disposable container, never into an image layer.
FROM nixos/nix:2.24.5@sha256:4ad79a0ab633944869a37921f096d35a3f2c7a0275d98b7bfa0cd3cba5a6b96e

ENV NIX_CONFIG="experimental-features = nix-command flakes"
ENV PATH="/usr/local/bin:/nix/var/nix/profiles/ixe/bin:/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin"

COPY machtiani-harness /opt/ixe/build/machtiani-harness

RUN nix --extra-experimental-features 'nix-command flakes' \
      profile install --profile /nix/var/nix/profiles/ixe --impure --expr \
      'let f = builtins.getFlake "path:/opt/ixe/build/machtiani-harness"; p = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in p.buildEnv { name = "machtiani-ixe-tools"; paths = [ p.bashInteractive p.cacert p.coreutils p.curl p.expect p.findutils p.gawk p.gnugrep p.gnused p.nodejs_22 p.openssh p.procps p.python3 p.shadow p.util-linux p.which ]; }'

ENV SSL_CERT_FILE="/nix/var/nix/profiles/ixe/etc/ssl/certs/ca-bundle.crt"
ENV NIX_SSL_CERT_FILE="/nix/var/nix/profiles/ixe/etc/ssl/certs/ca-bundle.crt"

# Git is needed to prepare the disposable checkout before the evaluation, but
# this profile is removed before the installation agent starts. The agent's
# PATH therefore begins without Git, just like the intended fixture.
RUN nix --extra-experimental-features 'nix-command flakes' \
      build --out-link /nix/var/nix/profiles/ixe-prep --impure --expr \
      'let f = builtins.getFlake "path:/opt/ixe/build/machtiani-harness"; p = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in p.buildEnv { name = "machtiani-ixe-prep-tools"; paths = [ p.git ]; }'

# Backend agents belong to the user, not the Dear Machine installer. The IXE
# supplies the same pinned Forge build already proven by the IPE to simulate a
# user who installed their chosen backend before starting this evaluation.
ARG TARGETARCH
ARG BACKEND_FIXTURE=forge
RUN set -eu; \
    case "$BACKEND_FIXTURE" in none) exit 0 ;; forge) ;; *) exit 1 ;; esac; \
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
      develop path:/opt/ixe/build/machtiani-harness#smoke -c bash -euo pipefail -c '\
        forge_tmp=$(mktemp -d /tmp/forge-install.XXXXXX); \
        trap '\''rm -rf -- "$forge_tmp"'\'' EXIT; \
        forge_download="$forge_tmp/forge"; \
        curl --fail --location --silent --show-error \
          --retry 3 --retry-delay 2 --retry-all-errors \
          --connect-timeout 15 --max-time 180 \
          --output "$forge_download" \
          "https://github.com/tailcallhq/forgecode/releases/download/v2.13.21/forge-${forge_target}"; \
        printf "%s  %s\n" "$forge_sha256" "$forge_download" | sha256sum -c -; \
        install -d -m 0755 /usr/local/bin; \
        install -m 0755 "$forge_download" /usr/local/bin/forge; \
        test "$(/usr/local/bin/forge --version)" = "forge 2.13.21" \
      '

# OMP's upstream Linux executable expects a conventional glibc loader. Keep a
# direct pinned profile so its lib directory is available without changing the
# simulated user's PATH or creating conventional host loader paths. This stays
# after the shared backend fixture so conductor changes retain that build cache.
RUN nix --extra-experimental-features 'nix-command flakes' \
      build --out-link /nix/var/nix/profiles/ixe-glibc --impure --expr \
      'let f = builtins.getFlake "path:/opt/ixe/build/machtiani-harness"; p = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in p.glibc.out'

# Cache the pinned installer toolchain and package closure from dependency
# manifests alone. Code-only installer revisions therefore do not fetch Node,
# nixpkgs, DSH, Codex, Copilot, or pnpm packages again.
COPY dearmachine-concierge/flake.nix \
     dearmachine-concierge/flake.lock \
     dearmachine-concierge/package.json \
     dearmachine-concierge/pnpm-lock.yaml \
     dearmachine-concierge/pnpm-workspace.yaml \
     /opt/ixe/build/machtiani-installer-dependencies/
COPY dearmachine-concierge/patches /opt/ixe/build/machtiani-installer-dependencies/patches
COPY dearmachine-concierge/packages/app/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/app/package.json
COPY dearmachine-concierge/packages/backend-adapter/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/backend-adapter/package.json
COPY dearmachine-concierge/packages/credential-adapter/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/credential-adapter/package.json
COPY dearmachine-concierge/packages/dsh-adapter/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/dsh-adapter/package.json
COPY dearmachine-concierge/packages/environment-adapter/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/environment-adapter/package.json
COPY dearmachine-concierge/packages/model-host/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/model-host/package.json
COPY dearmachine-concierge/packages/product-adapter/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/product-adapter/package.json
COPY dearmachine-concierge/packages/tui/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/tui/package.json
COPY dearmachine-concierge/packages/workflow/package.json /opt/ixe/build/machtiani-installer-dependencies/packages/workflow/package.json
RUN nix --extra-experimental-features 'nix-command flakes' \
      build --out-link /nix/var/nix/profiles/ixe-installer-build-dependencies \
      path:/opt/ixe/build/machtiani-installer-dependencies#build-dependencies

# Copy and build the changing installation conductor only after the expensive
# neutral environment, backend fixture, and installer dependency layers. The
# exact source snapshot still pins and isolates its DSH and Node closure from
# globally installed harnesses.
COPY dearmachine-concierge /opt/ixe/build/dearmachine-concierge
RUN nix --extra-experimental-features 'nix-command flakes' \
      build --out-link /nix/var/nix/profiles/ixe-installer \
      path:/opt/ixe/build/dearmachine-concierge

RUN mkdir -p /bin /etc/ssh /etc/ssl/certs /usr/local/bin /usr/local/libexec /run/sshd /run/ixe \
      /home/installer /var/empty \
 && ln -s "$(readlink -f /root/.nix-profile/bin/nix)" /usr/local/bin/nix \
 && ln -s "$(command -v bash)" /bin/bash \
 && ln -s "$SSL_CERT_FILE" /etc/ssl/cert.pem \
 && ln -s "$SSL_CERT_FILE" /etc/ssl/certs/ca-certificates.crt \
 && cp -L /etc/passwd /tmp/ixe-passwd \
 && cp -L /etc/group /tmp/ixe-group \
 && cp -L /etc/shadow /tmp/ixe-shadow \
 && unlink /etc/passwd && mv /tmp/ixe-passwd /etc/passwd \
 && unlink /etc/group && mv /tmp/ixe-group /etc/group \
 && unlink /etc/shadow && mv /tmp/ixe-shadow /etc/shadow \
 && touch /etc/gshadow \
 && chmod 0644 /etc/passwd /etc/group \
 && chmod 0600 /etc/shadow /etc/gshadow \
 && groupadd --system sshd \
 && useradd --system --gid sshd --home-dir /var/empty --shell /bin/false sshd \
 && groupadd --gid 1000 installer \
 && useradd --uid 1000 --gid 1000 --home-dir /home/installer --shell /bin/bash installer \
 && usermod --password IXE-SSH-KEY-ONLY installer \
 && chown installer:installer /home/installer \
 && rm -rf /opt/ixe/build

COPY tests/e2e-installation-experience/container-entrypoint.sh \
     tests/e2e-installation-experience/container-prepare.sh \
     tests/e2e-installation-experience/dearmachine-entrypoint.sh \
     tests/e2e-installation-experience/run-install-evaluation.sh \
     tests/e2e-installation-experience/verify-installation.sh \
     /opt/ixe/runtime-scripts/

RUN install -m 0755 /opt/ixe/runtime-scripts/container-entrypoint.sh /usr/local/libexec/ixe-entrypoint \
 && install -m 0755 /opt/ixe/runtime-scripts/container-prepare.sh /usr/local/libexec/ixe-prepare \
 && install -m 0755 /opt/ixe/runtime-scripts/dearmachine-entrypoint.sh /usr/local/bin/dearmachine \
 && install -m 0755 /opt/ixe/runtime-scripts/run-install-evaluation.sh /usr/local/bin/run-install-evaluation \
 && install -m 0755 /opt/ixe/runtime-scripts/verify-installation.sh /usr/local/libexec/ixe-verify \
 && rm -rf /opt/ixe/runtime-scripts

EXPOSE 22
ENTRYPOINT ["/usr/local/libexec/ixe-entrypoint"]
