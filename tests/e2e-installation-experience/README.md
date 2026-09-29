# Installation Experience Evaluation (IXE)

The IXE is the human-in-the-loop complement to the Installation Procedure
Evaluation (IPE). The IPE proves that the canonical raw procedure works without
human intervention. The IXE evaluates the conversation, judgment, questions,
and recovery behavior produced when a general installation agent receives
`INSTALL.md`. That initial prompt retains the permanent interaction and safety
contract, then routes the agent through focused files under
`docs/installation/` as each stage becomes relevant. The IXE source snapshot
contains those files, but the agent is explicitly forbidden from preloading
later stages or unselected backend guides.

`run.sh` owns the disposable local environment. It builds a neutral container,
copies source and agent state into the running container, exposes SSH only on a
random localhost port, prints the exact operator command, waits for the agent to
exit, verifies the installation, retains private evidence, and removes the
container. No host repository, agent directory, SSH directory, socket, or Git
administrative path is mounted into the container, and nothing is synchronized
back into the copied agent home.

## macOS Standard IXE

Use `run.sh --macos` with an existing macOS SSH guest. It prepares a fresh home,
launches the real native installer, opens a post-install exploration shell,
verifies installation/source integrity, and provides scanned evidence export
and scoped cleanup. See the [macOS IXE runbook](macos.md) for commands and the
separate native-build and cached-runtime coverage. It does not create, reset,
or stop the VM, and the Linux Docker flags do not apply to this mode.

## Conductor modes

The default test subject is the first-party Machtiani Installer. It runs its
pinned DSH composition and branded TUI inside the disposable container; the
host terminal reaches that TUI over the existing localhost-only SSH boundary.
No provider or credential is preselected for this mode. The human uses the
ordinary installer wizard to choose and authenticate the provider that powers
both the installation agent and installed Machtiani.

Historical conductor comparisons remain selectable with `--agent NAME`.
Agent-specific behavior lives under
`agents/`; the common harness does not know an agent's state layout, executable
bundle, authentication check, launch syntax, or trajectory format.

The `codex` adapter makes a one-way snapshot of the real Codex home (normally
`~/.codex`) after excluding process-local temporary directories, locks,
sockets, and live SQLite journal files. It also copies the exact host Codex
package into the running container. Neither is baked into the image. It runs
`gpt-5.6-luna` with high reasoning effort.

The `omp` adapter copies the exact host OMP executable and makes a consistent
SQLite snapshot of its authentication database. It deliberately does not copy
prior sessions, history, logs, caches, daemon state, or live SQLite journals.
The copied login and new IXE sessions live under `/run/ixe/agent-state/omp`, and
the conductor executable is not added to the simulated user's `PATH`. Thus OMP
can conduct the installation without making the procedure falsely detect OMP
as a user-installed Dear Machine backend. The reviewed OMP conductor
configuration uses `gpt-5.6-luna` with medium reasoning.

The `forge` adapter uses the pinned Forge executable already present in the
neutral image. It imports an explicitly supplied OpenRouter key into isolated,
container-only Forge state, selects `minimax/minimax-m3:free`, then removes the
one-time key file before the installation session begins. The key is absent
from the simulated user's environment, and the private Forge database is never
included in retained evidence.

Additional harness adapters implement the same four host hooks without
changing container lifecycle or evaluation semantics:

- `ixe_agent_validate_host`
- `ixe_agent_seed`
- `ixe_agent_check_login`
- `ixe_agent_collect`

It supplies its own `/usr/local/libexec/ixe-agent-launch` inside the container.

## Credentials and effects

The host runner reads the same ignored, owner-only mode-`0600` `.secrets` file
as the IPE only so it can redact exact credential values from retained evidence.
It does not copy that file into the container or add its values to the
installation agent's environment. The human supplies each requested credential
through the short-lived `micro` helper that the agent prepares, using a second
SSH shell so the editor is not driven through the recorded agent terminal.
Credentials never enter the image, chat, shell history, or process arguments.
The repository-owned helper places all paste/save/exit guidance inside the
private editor form, atomically writes only the captured key to its final file,
and publishes a non-secret completion status. The installation agent watches
that status and continues without asking the human to report completion.

By default, Forge 2.13.21 is pinned and preinstalled to represent a
backend agent that the user already owns. The Dear Machine installation agent
may validate and select it without installing anything. As with another
backend, installation is allowed only after an explicit user request, while
authentication remains human-controlled.

Use `--backend-fixture none` with the first-party installer to test the
missing-backend installation path. The default is `--backend-fixture forge`.
This is independent of the wizard's model provider: the installer's private
subscription runtimes are not user-installed Dear Machine backends. No backend
authentication is preseeded in either case. The human chooses the backend and
authentication path during installation, then can explore backend management
in the concierge after successful verification.

The `none` case skips the Forge seed/download on new images. On a cached image,
the runner moves only the IXE-owned Forge fixture into a root-only directory
inside the new container; it never changes the image or host binary. Before
SSH opens, it verifies that `codex`, `forge`, and `omp` are absent from the
installer user's PATH. Unexpected additional backends fail preparation rather
than being silently removed. The selected fixture is recorded in `run.txt`.
Historical conductor modes are not supported with `none` because their own
agent exposure/authentication could invalidate an empty-backend experiment.

The neutral IXE environment also includes `curl`, its HTTPS certificate bundle,
and Python as baseline evaluation infrastructure. Python drives the retained
installation-state verifier; these tools are available to the installer user
from the first shell and are not dependencies that the guided Dear Machine
installation asks the human to install. The same IXE-owned certificate bundle
is exposed through conventional Linux certificate paths so tools work even
when an agent command environment does not retain Nix-specific variables.

This is a real installation. It can call model and email providers, incur
charges, create an inbox, and change provider-side authorization policy. The
IXE currently evaluates installation state rather than owning those external
resources transactionally; use an evaluation account or an existing disposable
inbox and review provider-side state afterward. The IPE remains the test that
provisions and exactly removes run-owned AgentMail resources. A transactional
IXE transport fixture should be added before making this a routine unattended
gate.

## Run

For a natural-language, agent-operated user rehearsal before human review, use
the [private operator runbook](operator-runbook.md). It covers masked-key entry,
novice and experienced full-install/concierge passes, and fix/retest evidence.
It does not replace the live installer with a scripted conversation.

### Standard curl IXE without Nix

Use `--standard-bundle` with an existing, smoke-tested Standard download,
`--cached-image machtiani-ixe-standard:local`, and, for the default Forge case,
`--forge-binary` pointing to the existing Linux x86-64 Forge 2.13.21 fixture.
For an empty-backend run, pass `--backend-fixture none` and omit `--forge-binary`.
The runner verifies the archive/bootstrap checksum agreement and, when selected,
the pinned Forge checksum. It permits
documentation/test-only installer follow-ups, but refuses reuse when installer
runtime source or package inputs differ. Changes to `INSTALL.md` or umbrella
`docs/` also require repackaging: the agent reads the downloaded guidance, not
the runner's checkout. Reuse the existing binaries for that source refresh.
The retained curl manifest records
the tested release's exact revisions, separately from the harness revision.

Prepare the small neutral image once using `Dockerfile.standard` and an empty
build context. Its Debian base must already be cached; product binaries and
credentials are never built into this image. SSH host keys are generated per
container. The apt cache mounts and reusable image avoid repeating setup.

```bash
tests/e2e-installation-experience/run.sh \
  --standard-bundle /absolute/cache/standard-download \
  --cached-image machtiani-ixe-standard:local \
  --forge-binary /absolute/cache/forge \
  --secrets-file /absolute/private/path/to/.secrets
```

To exercise installation of a backend, use the same command with
`--backend-fixture none` in place of `--forge-binary ...`. A new backend may
need an upstream download and human authentication; runtime/image cache reuse
does not make that external installation or inference offline.

Credential-free fixture checks:

```bash
python3 tests/e2e-installation-experience/backend-fixture-test.py
python3 tests/e2e-installation-experience/backend-fixture-test.py \
  --image machtiani-ixe-standard:local --forge-binary /absolute/cache/forge
```

The optional container check uses an already-cached image, no host mounts,
credentials, or network, and tests Forge present, absent, and removed from a
cached fixture. It removes only its disposable test containers. It is not a
live backend installation, provider health check, or concierge evaluation.

Connect with the printed SSH command, run the printed `curl … | sh` command,
then `dearmachine`. Choose **Standard installation** for this preview; the
portable bundle's Nix alternative remains incomplete. The container starts
without `/nix` and without installed Dear Machine products. Only release
artifacts are served, on container loopback. The normal terminal recording,
post-install exploration, private artifact collection, and cleanup apply.
Source integrity is checked by a content/mode/symlink fingerprint rather than
initializing Git in the downloaded source snapshot. No provider authentication
or backend credentials are copied; the human supplies them in the wizard.

### Local curl preview with existing Nix and cached binaries

This opt-in mode tests `curl … | sh`, followed by `dearmachine`, without a new
image build, package build, or public domain. It is suitable for limited network
connections. Prepare an existing installer package whose packaged runtime source
matches the pinned installer checkout; the bundle builder checks this correspondence.
Work from a clean, committed umbrella worktree with its pinned submodules present.

```bash
python3 scripts/prepare-curl-bundle.py \
  --source-root "$PWD" \
  --installer-store-path /nix/store/EXISTING-INSTALLER-PACKAGE \
  --git-store-path /nix/store/EXISTING-GIT-PACKAGE \
  --output /absolute/local/cache/curl-bundle

tests/e2e-installation-experience/run.sh \
  --curl-bundle /absolute/local/cache/curl-bundle \
  --cached-image machtiani-ixe-environment:local \
  --secrets-file /absolute/private/path/to/.secrets
```

The builder exports existing Nix packages and their runtime dependencies with
streaming compression. It never invokes a build or downloads a package. Reusing
the output directory reuses the compressed closure when its store paths and
checksum match. Additional already-built cache entries can be included with
repeated `--extra-store-path /nix/store/EXISTING-PACKAGE` arguments. Keep generated
artifacts outside the repository and outside a memory-backed temporary directory
when space is limited. Source archives contain committed files, not host Git
metadata or history; a revision manifest identifies the original commits.

The runner resolves the existing image locally, copies the current runtime
scripts into a new stopped container, and explicitly restores executable modes.
It imports the package cache as root without installing anything into the test
user's profile, changing Nix trust policy, or copying credentials. The curl script
then tests the **already-installed Nix / already-cached packages** branch. A
dedicated server exposes only `install`, `manifest.json`, `source.tar.gz`, and
`closure.nar.gz` on container loopback. No HTTP port is published on the host or
the surrounding Wi-Fi network. SSH remains localhost-only.

Use the printed SSH command, then run:

```bash
curl -fsSL http://127.0.0.1:8765/install | sh
dearmachine
```

The bootstrap verifies checksums, creates the matching local source/docs checkout
and a launcher, and stops. The separate `dearmachine` invocation has its normal
terminal input and starts the recorded wizard; the curl pipe is not the TUI's
stdin. Existing non-bootstrap launchers are never overwritten. Repeating the
same bootstrap is supported. The normal IXE verification, transcript collection,
and cleanup continue to apply. Curl mode has a separate per-user lock, so an
ordinary IXE already in progress is left untouched.

Limits: this is not the public release installer. Missing-Nix installation,
uncached imports by untrusted Nix users, signed remote distribution, and other
platforms still need separate validation. Loopback checksums detect corrupted
artifacts; they are not publisher authentication. No dependency or runtime is
recompiled during this preview: the wizard's Nix configuration disables local
builds and remote substitutions, so an uncached product requirement fails
explicitly. Nix evaluation may still need source metadata; model sign-in,
inference, and email verification still need internet and may incur charges.
Do not describe this cached preview as a clean-machine or clean-image build test.

### Standard IXE

First validate the local contracts without reading credentials or mutating
Docker:

```bash
tests/e2e-installation-experience/run.sh --self-test
```

To evaluate an unlanded clean installer worktree, start the container host
runner directly:

```bash
tests/e2e-installation-experience/run.sh \
  --installer-root /absolute/path/to/clean/machtiani-installer-worktree
```

The runner prints the run-specific SSH command. Open it in another terminal,
then run `dearmachine` there.

To run a historical Codex comparison instead:

```bash
tests/e2e-installation-experience/run.sh --agent codex
```

Or conduct the same evaluation with the host's existing OMP ChatGPT login:

```bash
tests/e2e-installation-experience/run.sh --agent omp
```

Or use the pinned Forge fixture with the requested OpenRouter model:

```bash
IXE_FORGE_OPENROUTER_KEY_FILE=/absolute/private/path/to/openrouter-key \
  tests/e2e-installation-experience/run.sh --agent forge
```

Leave that process running. It prints a localhost-only SSH command containing
the path to a run-unique private key. Connect from another terminal and run:

```bash
dearmachine
```

The IXE records that command's terminal session and retains
`run-install-evaluation` only as internal evaluation scaffolding. When the
installer or concierge exits, the container verifies
the installed commands, credential reference, Dear Machine configuration,
client health, and unchanged source tree. The host then collects the transcript,
verification result, and any new file-based agent trajectory beneath
`${XDG_STATE_HOME:-$HOME/.local/state}/machtiani/ixe/`.

Raw evidence is private because it can contain operator-supplied personal
information. Exact install credential values are replaced before the host
runner reports success. The default cleanup destroys the container and its
copied authentication. `--keep-container` stops and retains it only for explicit
diagnosis; remove that container promptly after inspection.

## Container build acquisition in a Linux VM

This credential-free acquisition gate drives the real wizard through **Container
build**, stops at provider selection, then reuses the shared runtime smoke gate.
It complements the human IXE and live QSE; it does not repeat provider sign-in,
backend setup, or email verification.

Prerequisites are Python 3, SSH, QEMU with usable `/dev/kvm`, `qemu-img`,
`genisoimage`, and a downloaded Ubuntu 24.04 amd64 cloud image. Verify the image
against its publisher's SHA256SUMS and retain it for subsequent runs. The runner
requires the expected SHA-256 explicitly and never modifies the base image.

```sh
python3 tests/e2e-installation-experience/container-build-vm.py \
  --base-image /absolute/path/to/noble-server-cloudimg-amd64.img \
  --base-sha256 "$CLOUD_IMAGE_SHA256" \
  --artifacts /absolute/path/to/new-evidence-directory
```

Use `--installer-root` for a paired installer worktree. Defaults are four virtual
CPUs, 6144 MiB RAM and a sparse 48 GiB disposable disk; `--cpus` and `--memory-mib`
can adjust compute limits. Expect several GiB of temporary disk use and a cold
Docker/dependency download inside each fresh VM. Run the fast contracts and
cached host builds first on metered connections. The guest has its own Docker
engine and ephemeral SSH key, no provider credentials, host mounts, forwarded
agent, or shared Docker socket. Guest console, build and wizard evidence remain
in the requested directory; the overlay disk and temporary private key are
removed on exit.

For runtime-only packaging edits, reuse an already-built raw runtime image and
the cached Debian base without provisioning another VM:

```sh
python3 tests/standard-runtime-smoke.py --image "$RUNTIME_IMAGE_ID" debian:bookworm-slim
```

This runner refuses to pull the base image, disables container networking, and
copies the raw runtime and current shared test files into a disposable target.
It verifies relocation and execution as an unprivileged user without Nix, Node,
Python, Go, or Docker preinstalled. It does not exercise the wizard's Docker
handoff; that is the VM gate above.

The [macOS IXE adapter](macos.md) supports separate Standard and Nix evaluations on a macOS host/VM. Use `--method nix` to prepare the Nix path with a private checkout and profile.
