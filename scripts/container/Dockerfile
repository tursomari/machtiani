# syntax=docker/dockerfile:1
# Dependencies precede source so ordinary edits reuse network-heavy layers.
FROM node:24.19.0-bookworm-slim AS node
FROM golang:1.26.8-alpine AS go-toolchain
FROM debian:bookworm-slim AS tools
RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,id=dearmachine-apt-bookworm,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=dearmachine-apt-lists-bookworm,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl diffutils findutils gawk git git-lfs grep \
      musl patchelf procps python3 ripgrep sed sqlite3 zsh libatomic1 libstdc++6
COPY --from=node /usr/local/bin/node /usr/local/bin/node

FROM tools AS compiler
RUN --mount=type=cache,id=dearmachine-apt-bookworm,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=dearmachine-apt-lists-bookworm,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends g++ make
WORKDIR /build

FROM compiler AS installer-deps
# Installs are explicit and frozen below. Source changes must not cause pnpm's
# script runner to silently reinstall dependencies from a different store.
ENV CI=true PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN=false
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN --mount=type=cache,id=dearmachine-npm,target=/root/.npm \
    node /usr/local/lib/node_modules/npm/bin/npm-cli.js install -g pnpm@11.7.0
COPY dearmachine-concierge/package.json dearmachine-concierge/pnpm-lock.yaml dearmachine-concierge/pnpm-workspace.yaml ./
COPY dearmachine-concierge/patches ./patches
COPY dearmachine-concierge/packages/app/package.json ./packages/app/
COPY dearmachine-concierge/packages/backend-adapter/package.json ./packages/backend-adapter/
COPY dearmachine-concierge/packages/credential-adapter/package.json ./packages/credential-adapter/
COPY dearmachine-concierge/packages/dsh-adapter/package.json ./packages/dsh-adapter/
COPY dearmachine-concierge/packages/environment-adapter/package.json ./packages/environment-adapter/
COPY dearmachine-concierge/packages/model-host/package.json ./packages/model-host/
COPY dearmachine-concierge/packages/product-adapter/package.json ./packages/product-adapter/
COPY dearmachine-concierge/packages/tui/package.json ./packages/tui/
COPY dearmachine-concierge/packages/workflow/package.json ./packages/workflow/
RUN --mount=type=cache,id=dearmachine-pnpm-v11,target=/pnpm/store,sharing=locked \
    pnpm install --frozen-lockfile --store-dir=/pnpm/store --network-concurrency=4 --child-concurrency=2 --fetch-timeout=600000
FROM installer-deps AS installer
COPY dearmachine-concierge/ ./
RUN --network=none --mount=type=cache,id=dearmachine-pnpm-v11,target=/pnpm/store,sharing=locked \
    pnpm build && rm -rf node_modules packages/*/node_modules \
    && CI=true pnpm install --prod --offline --frozen-lockfile --store-dir=/pnpm/store \
    && mkdir -p /out/installer/packages && cp -a package.json node_modules /out/installer/ \
    && for package in packages/*; do \
      destination="/out/installer/$package"; mkdir -p "$destination"; \
      cp -a "$package/package.json" "$package/dist" "$destination/"; \
      if test -d "$package/node_modules"; then cp -a "$package/node_modules" "$destination/"; fi; \
    done

FROM compiler AS native-deps
COPY --from=go-toolchain /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin"
ENV GOTOOLCHAIN=local GOMAXPROCS=4
COPY dearmachine/dearmachine/go.mod dearmachine/dearmachine/go.sum ./dearmachine/
COPY machtiani-harness/agent/go.mod machtiani-harness/agent/go.sum ./harness/
RUN --mount=type=cache,id=dearmachine-go-modules,target=/go/pkg/mod \
    cd /build/dearmachine && go mod download && cd /build/harness && go mod download
FROM native-deps AS native
COPY dearmachine/dearmachine/ ./dearmachine/
RUN --mount=type=cache,id=dearmachine-go-modules,target=/go/pkg/mod \
    --mount=type=cache,id=dearmachine-go-build,target=/root/.cache/go-build \
    cd /build/dearmachine && CGO_ENABLED=1 go build -trimpath -buildvcs=false -ldflags='-s -w' -o /out/ ./cmd/dearmachine ./cmd/agent-manager
COPY machtiani-harness/agent/ ./harness/
# The snapshot records the harness revision; stamp it into `machtiani --version`.
COPY scripts/machtiani-version-ldflags.py bootstrap-source-*.json ./stamp/
RUN --mount=type=cache,id=dearmachine-go-modules,target=/go/pkg/mod \
    --mount=type=cache,id=dearmachine-go-build,target=/root/.cache/go-build \
    stamp=$(python3 /build/stamp/machtiani-version-ldflags.py /build/stamp) \
    && cd /build/harness && CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="-s -w $stamp" -o /out/machtiani ./cmd/machtiani

FROM tools AS runtime
COPY --from=installer /out/installer /payload/installer
COPY scripts/container/prepare-runtime.py scripts/relocate-standard-runtime.py /packaging/
# Select only runtime tools, their shared libraries, and language data. No SDKs,
# compilers, package-manager caches, development dependencies, or host state.
RUN python3 /packaging/prepare-runtime.py
COPY . /release/source
FROM runtime AS bootstrap-files
RUN touch /release/.bootstrap-only
FROM runtime AS release-files
COPY --from=native /out/ /release/runtime/native/
RUN python3 /packaging/prepare-runtime.py --products

# Separate large stable dependencies from compiled packages and source metadata.
# This also avoids duplicating those bytes when exporting successive images.
FROM scratch AS runtime-image
COPY --from=runtime /release/runtime/sysroot /release/runtime/sysroot
COPY --from=runtime /release/runtime/installer/node_modules /release/runtime/installer/node_modules
COPY --from=runtime /release/runtime/installer/packages /release/runtime/installer/packages
COPY --from=runtime /release/runtime/installer/package.json /release/runtime/installer/package.json
COPY --from=runtime /release/runtime/launchers /release/runtime/launchers
COPY --from=runtime /release/bootstrap-runtime.sh /release/relocate-standard-runtime.py /release/
COPY --from=runtime /release/source /release/source
FROM runtime-image AS bootstrap
COPY --from=bootstrap-files /release/.bootstrap-only /release/relocation.json /release/
FROM runtime-image AS release
COPY --from=release-files /release/runtime/native /release/runtime/native
COPY --from=release-files /release/relocation.json /release/distribution.json /release/
