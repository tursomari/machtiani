# Standard installation

On Linux other than NixOS and on macOS, the installer offers **Nix** (the recommended default) and **Standard**. NixOS automatically uses Nix. Standard builds the
software without Nix and installs it for direct execution on the host:

- Linux x86-64: the build runs inside Docker.
- macOS Intel and Apple Silicon: the build runs directly with Apple's Command
  Line Tools. Docker and Homebrew are not required.

These are implementations of one Standard choice, not additional wizard
options. Each release also publishes prebuilt Standard downloads, installed
by `install.sh` and `install.ps1`; see [Release publishing](release-publishing.md).

## Acquisition and ownership

Start from an umbrella checkout with its pinned submodules initialized:

```sh
installer=$(sh scripts/build-standard.sh --bootstrap) &&
  "$installer" quick-start --method standard --source-root "$PWD"
```

The bootstrap builds the installer first. Quick start selects **Standard** and,
after consent, acquires the products before model configuration. Setup continues
in the same terminal; no separate `dearmachine` invocation is required. Linux requires Git, Python 3 and an
accessible Docker engine with Buildx; the script diagnoses a missing engine or Buildx plugin.
On macOS, install Apple's Command Line Tools with `xcode-select --install` if
the script reports they are missing. These provide Git, Python 3 and the native
compiler. The script then downloads checksum-pinned Node, Go, pnpm and runtime
tools. It compiles GNU Bash, coreutils and sed privately, with no global package
manager changes. Go and pnpm are build tools; the runtime retains Node and the
required tools. Apple Git remains a Command Line Tools dependency.

On Linux, Docker must also be able to pull the public base images from Docker
Hub. `docker ps` proves daemon access, not registry access. A missing
`docker-credential-*` executable during a pull means the user's Docker client
configuration refers to an unavailable credential helper. The Standard builder
uses a temporary anonymous-pull config in that case and leaves the saved Docker
configuration untouched. A Docker Hub login is not required for its public images.

Source snapshots contain tracked project files only. Credentials and user
state never enter a build. Downloads are cached under the user's cache directory;
macOS releases live under the user's data directory in
`dearmachine/standard-releases/<platform-and-source-hash>`. Public launchers in
`~/.local/bin` point into the verified release. Existing unrelated launchers
are never overwritten. Failed builds expose no new public launchers. Repeated
acquisition reuses a verified identical release. Cancelled builds can be retried.
See [Linux build details](container-build-installation.md) for its existing
release layout and Docker cache behavior.

Neither acquisition nor bootstrap chooses credentials, creates an inbox, or
starts Dear Machine. All Standard runtimes use the shared guided configuration.
Backend agents such as Forge, Codex, and OMP remain separately selected
prerequisites. Building the products does not authorize installing all backends.

Paths are recorded in the release's `distribution.json`, supplied through
`MACHTIANI_DISTRIBUTION`. Use those absolute paths from the launcher's validated
runtime context. Never replace them with `~/.nix-profile` paths or copy a
different version over a supplied executable. Do not run `machtiani install`
or its Nix-managed updater on this installation. Automatic Standard upgrades
are not implemented yet; installation does not silently replace an existing
release.

Source and documentation are shipped together at their recorded revisions,
without Git history or host state. The documentation entrypoint is
`source/docs/README.md` inside the release. Consult documentation first and
source when clarification is needed. Do not initialize Git or write runtime
state into this snapshot.

## Configuration and verification

Acquisition is already complete. Verify `dearmachine --help`,
`agent-manager --help`, `machtiani --version`, `git --version`, and
`git lfs version`. Verify that the supplied model-host is executable (it
requires a private profile to serve requests; `--help` is not a success probe).

For fresh-process verification on Windows, use native PowerShell with
`-NoProfile` and retain Windows' `USERPROFILE`, `LOCALAPPDATA`, `APPDATA`,
`SystemRoot`, and native `PATH`. The Windows launchers resolve the user home
through `USERPROFILE`; supplying only the Unix `HOME` variable creates an
invalid test environment.

Use the existing canonical `docs/installation-procedure.md` for these shared
sections only: **Configure the shared model**, **Use Machtiani**, the selected
backend configuration paragraphs under **Install DearMachine**, and **Run DearMachine**.
Skip its Nix prerequisites, clone, `nix run`, `nix profile install`, and product
acquisition commands. This guide changes acquisition, not product configuration.

In `~/.config/machtiani/config.toml`, use the exact shared profile and the
component selectors from the canonical configuration example. Keep
`@machtiani/planner`, `@machtiani/shell-agent`, and `@machtiani/sync` literally;
do not substitute the initially selected model or pin a reasoning parameter.
The shared profile supplies those choices on every request, including later
`/model` changes. Use the absolute supplied model-host path. Do not re-ask saved
choices or translate subscription tokens into API keys. Preserve all existing
user configuration and credential files. Backend credentials continue to use
the secure credential bridge.

On any platform, setup launched by Dear Machine can inherit `MACHTIANI_CONFIG`
pointing at its private configuration. When validating the standalone file just
written above, select that file explicitly for the command. Then perform the
documented import into `~/.config/dearmachine/machtiani/config.toml` and validate
that destination explicitly before starting Dear Machine. Preserve existing
standalone settings and do not change the user's global environment.

Run model-backed sync/checks in a disposable committed Git repository, never
the source snapshot. Let `dearmachine up --create --resume` own the initial
state-and-memory workspace and wait for its durable synchronization. Continue
with the backend, daemon, and live-email verification in
`docs/installation/05-product-and-verification.md` and its subsequent stages.
Do not declare success merely because the binaries start.

## Optional systemd operation

Follow `docs/installation/06-always-on.md`. After explicit approval, use
`dearmachine down`, `dearmachine systemd on`, `dearmachine persistence on`,
and `dearmachine up`, then verify native status and persistence. Standard and
Nix use the same `dearmachine-concierge.service` and stable installed launcher.
Do not create a separate `dearmachine-native.service`, replace supplied product
binaries, or install systemd merely because the portable bundle is present.

Public commands are installed in `~/.local/bin`. Installation automatically adds
that directory to the user's shell startup files for zsh, bash, fish, and POSIX
login shells. Existing PATH entries retain their order, existing startup content
is backed up before editing, and repeated setup does not duplicate the block.
New terminals pick up the change automatically; the installer prints a command
for terminals that were already open. Linked, read-only, or customized managed
blocks are left unchanged with an actionable error. To retry shell setup, run
`~/.local/bin/machtiani-installer configure-shell`. The printed absolute launcher
remains usable if shell setup cannot complete. The bootstrap also reports PATH
conflicts.
Remove an older competing installation through its owning package manager rather
than creating shell-specific overrides. Nix profile cleanup through
`migrate-profile` currently requires a coordinated Nix installation; Standard
migration remains explicit and separate.

## Verification status

Build targets are not a claim of complete live verification. Keep Intel and
Apple Silicon results separate, and test macOS builds and native runtime
behavior in macOS guests or on Macs. Linux ARM64 is not yet a Standard target.
See [macOS status](macos-support.md) and [testing](../TESTING.md). The historical
Linux prebuilt archive/bootstrap tests remain separate from the source-build
and live installation gates.
