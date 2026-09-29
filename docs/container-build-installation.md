# Container build installation

The wizard offers **Nix** and **Standard**. Standard on Linux uses Docker
and standard Go, C/C++, Node and pnpm tooling to compile the pinned project
sources. The exported software runs on the host; Docker is needed for builds,
not for normal operation. No Nix is used by this acquisition path.

The initial supported target is Linux x86-64, with a matching Linux Docker
engine and BuildKit. ARM and macOS host executables are not produced by this
Linux build. On macOS, Standard instead uses the [native build](standard-installation.md).
Docker must already be installed and usable by the current user, with Buildx
available and network access to public Docker Hub images. `docker ps` alone does
not test registry access. If the Docker Hub credential helper configured in the
user's Docker client is missing, the builder uses a temporary anonymous-pull
config for this public-image build. It keeps the selected Docker context and
Buildx state, removes registry credentials from the temporary config, and never
edits the user's saved config. Other registry or network errors still fail the
build and retain Docker's diagnostic.
A missing or inaccessible Docker engine is a recoverable wizard error; the
installer does not install Docker or silently select Nix.

## Starting without Nix or a system Node installation

Start in an initialized umbrella checkout with its pinned submodules present.
The bootstrap needs Docker, Git, Python 3 and a POSIX shell on the host. It
builds only the installer/concierge and its runtime, without configuring any
provider or starting Dear Machine:

```sh
installer=$(sh scripts/build-standard.sh --bootstrap) &&
  "$installer" --source-root "$PWD"
```

Choose **Standard** in the wizard. It builds the native products and
verifies the exported commands before opening provider/model setup. Ctrl+C
cancels a build; the method picker remains available. A failed build retains
its diagnostic in the installer's private state directory and does not replace
existing launchers. Resume by selecting the method again. Successful build
layers and downloaded dependencies are reused.

An existing Nix-launched installer can use the same Standard option.
The selected acquisition method does not change the shared model, credential,
backend, pairing, or email verification procedure.

## Installed files and ownership

Complete releases live under
`${XDG_DATA_HOME:-$HOME/.local/share}/dearmachine/container-releases/<source-hash>`.
Bootstrap runtimes use the adjacent `bootstrap/` directory. The source hash
covers the exported working source and file modes. Only tracked checkout files
are copied; Git administration, credentials, build outputs and host product
state are excluded. Source-only releases retain revision metadata and the
canonical documentation at `source/docs/README.md`.

The installed `distribution.json` has `method: container` and supplies absolute
validated paths through the launcher's `MACHTIANI_DISTRIBUTION` environment.
Public launchers are exposed in `~/.local/bin`. Existing unrelated files or
links are never overwritten. Repeating acquisition of the same verified release
reuses it without downloading dependencies. Switching an existing installation
to another method or source revision is not an implicit upgrade; remove its
launchers through the owning installation workflow first.

The release includes Node, the compiled installer and model host, their
production dependencies, native product executables, Git/Git LFS, Python and
basic command-line tools. Their runtime libraries are relocated into the private
release. The embedded Claude executable remains byte-for-byte intact and runs
through the bundled loader, since changing its ELF layout can break startup.
Backend agents are separately selected prerequisites and are not all
installed by acquiring this bundle. Installation configures the supported user shell's
PATH automatically, backing up existing startup files and preserving their
settings. Open a new terminal or apply the printed command in an existing shell.

## Concierge and installation-agent instructions

For `installation.method = standard` (or legacy `container`), acquisition has already completed in the
wizard. Use `installation.distribution` and its supplied commands. Never invoke
Nix, the individual component installers, or the Nix updater on this release.
Automatic Container build upgrades are not implemented in this change.

Follow the shared configuration and verification instructions in
[the Standard runtime configuration guide](standard-installation.md), beginning
at **Configuration and verification**. Its Nix-free runtime rules also apply
here; its curl acquisition section describes a different, historical producer.
Preserve the wizard's model/profile and credential receipts. Complete backend,
native daemon and live-email checks before declaring installation success.
Use the source snapshot for documentation and inspection, not as a writable
project or a place for Git initialization. Optional systemd operation continues
to require the choices in [Stage 6](installation/06-always-on.md).

## Build caching and bandwidth

The Dockerfile copies dependency manifests before application source, keeps Go
module/compiler and pnpm caches between builds, and exports a separate runtime
stage. The export keeps runtime libraries and large provider dependencies in
separate layers from compiled application packages and source documentation.
Production Node dependencies are reinstalled offline from the cached store;
unused development packages are excluded. Compilation and production packaging
run with networking disabled after the explicit dependency install. Runtime dependencies and their peers
remain included. C/C++ and Go toolchains, apt caches,
and Git history do not enter the exported runtime.

An initial build downloads base images, toolchains and provider runtimes and can
be substantial. Subsequent source edits should reuse those downloads. The
builder does not force image pulls, disable caches, or prune Docker storage.
Avoid clearing Docker caches on a metered connection. Changing pinned versions
may require new downloads. A cached build is not a promise that provider sign-in,
backend installation, or live verification works offline.

## Verification

Managed builds, including bootstrap, hold `dearmachine/update.lock` beneath the
selected data directory throughout snapshotting, compilation and activation.
This is the same lock used by native update/uninstall; an active uninstall also
blocks acquisition. A failed or cancelled build releases only its own lock.
After a forced interruption, verify no build/updater/uninstaller remains before
removing that exact stale lock. Export-only `--output` builds do not activate a
managed installation and do not take this installation lock.

For destructive removal use [the confirmed uninstall command](uninstall.md).
The [Docker-built uninstall gate](../tests/uninstall/README.md#docker-built-installation)
proves active-build refusal and removal of the exported runtime in isolation.

The canonical test map is [TESTING.md](../TESTING.md). Fast contracts cover
source isolation and safe activation. The existing runtime smoke gate verifies
the exported native/TypeScript programs, child execution, Git LFS, and a local
model-host/tool round trip. IXE owns interactive installation evaluation; QSE
owns live product/email verification. A disposable Linux VM is used to verify
the real wizard-to-Docker-build handoff without exposing the host Docker socket
to the installer under test.
