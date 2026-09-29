# Testing the Machtiani umbrella

This is the testing entrypoint for the Machtiani umbrella repository. The
umbrella owns cross-repository contracts, pinned-component integration, the
Installation Experience Evaluation (IXE), and the Installation Procedure
Evaluation (IPE). Each submodule owns its own tests and canonical root testing
document.

Run commands from the umbrella repository root.

## Recommended starting checks

For an ordinary umbrella documentation, submodule-maintenance, or installation
contract change, begin with the credential-free checks:

```console
tests/submodule-maintenance-test.sh
tests/submodules-from-local-test.sh
tests/documentation-entrypoint-test.sh
tests/credential-entry-test.sh
scripts/verify-installation-procedure.sh
tests/e2e-installation-experience/run.sh --self-test
tests/e2e-installation-procedure/run.sh --self-test
```

These commands do not constitute a new aggregate suite; they remain separate
entrypoints so a failure retains a clear owner. The IXE self-test includes its
contract test, which in turn includes the installation-prompt contract.

For product-wide release confidence, use the QSE selected and documented by
the [Machtiani Installer testing entrypoint](dearmachine-concierge/TESTING.md).
The QSE exercises the installed Machtiani and DearMachine products together;
the umbrella does not duplicate its command, credentials, or cleanup contract.

## Standard acquisition checks

Run `python3 tests/standard-build-test.py` for native target dispatch, developer
prerequisites, archive traversal protection, checksum/cache handling and launcher
quoting. Keep the existing container-build, Standard runtime and bootstrap tests
passing. The installer method/wizard suites cover the Nix default, automatic NixOS selection, host-specific Standard descriptions, cancellation and compatibility with older manifests.

For native macOS execution, run the real `scripts/build-standard.sh` with an
isolated HOME and output directory inside a macOS guest. Keep the build PATH
free of Nix/Homebrew. Verify product/model-host entrypoints, a local model-host
and installer-agent tool round trip, Git LFS, native library dependencies,
bootstrap, activation, cache reuse and preservation of unrelated launchers.
Run `python3 tests/macos-standard-smoke.py /absolute/path/to/release` for the
credential-free native runtime gate. Use `tests/standard-bootstrap-menu.py`
with `--launcher`, `--source-root`, and a new `--evidence-directory` to verify
the real bootstrap reaches Nix and Standard without credentials. Pass
`--expected-host linux`, `darwin`, or `nixos` to verify the host-specific flow;
NixOS must skip the method menu and reach model setup. `--expect-nix-prerequisite`
checks actionable failure when the test environment disables Nix features.
Pass `--quick-start-method nix` or `--quick-start-method standard` to exercise
the README route through consent directly to model setup without a method menu.
The test uses a clean HOME; pass `NIX_CONFIG='experimental-features = nix-command flakes'`
for the successful Nix route if those features are enabled only in your user configuration.
The Standard variant needs a prepared distribution or performs the real build.
Record Intel and Apple Silicon execution separately. A Linux test of the Python
builder is not native macOS verification.

## Component testing entrypoints

| Working area | Canonical testing document |
| --- | --- |
| DearMachine client, transports, Agent Manager, lifecycle, or LSEs | [DearMachine `TESTING.md`](dearmachine/TESTING.md) |
| Machtiani agent runtime, tools, model transport, terminal, or evaluations | [Machtiani Harness `TESTING.md`](machtiani-harness/TESTING.md) |
| Installer wizard, workflow, TUI, model host, product adapter, IXE/QSE implementation | [Machtiani Installer `TESTING.md`](dearmachine-concierge/TESTING.md) |

Those documents own their commands, prerequisites, artifacts, live-test
warnings, and specialist or historical paths. Do not copy their catalogues
into this file.

## Selecting tests while working

Test the repository that owns the change first, then add only the downstream
path that the change can affect:

| Change | Start with | Add when applicable |
| --- | --- | --- |
| Umbrella scripts, pins, or installation policy | Umbrella checks in this document | IXE for human interaction; IPE for the published raw procedure; Installer QSE for the complete installed product |
| DearMachine behavior | DearMachine testing entrypoint | The narrowest DearMachine LSE for live behavior; Installer QSE when installation or full-product compatibility changes |
| Harness behavior | Harness testing entrypoint | Harness live/TUI suite for the changed boundary; Installer QSE when the runtime or model-host contract used by the installed product changes |
| Installer behavior | Installer testing entrypoint | IXE for the human conversation and terminal experience; live QSE for a release candidate |

For example, a DearMachine-only change does not require Harness's live agent
suite merely because DearMachine invokes Machtiani. Conversely, a change to a
shared installed interface needs the owning component tests plus the relevant
cross-product gate.

## macOS portability

The [macOS preview guide](docs/macos-support.md) separates cross-compilation,
recovery-guest checks, and ordinary-user installation acceptance. macOS tests
must run on macOS; the Linux IXE is not a substitute. Use the
[macOS IXE adapter](tests/e2e-installation-experience/macos.md) to prepare an
existing SSH guest and run the native Standard experience. Its credential-free
boundary tests, `python3 tests/e2e-installation-experience/macos-test.py`, also
run in the IXE contract/self-test. A passing adapter test is not a live IXE pass.

## Windows Quick start checks

Run `node --test tests/codex-runtime-test.cjs` for the required Codex native
runtime packaging gate. The Windows builder checks the relocated launcher
and exact version before publishing a bundle, because a failed optional npm
download can otherwise leave both subscription sign-in methods unusable.

See the [Quick start validation results](tests/quick-start-results-2026-09-21.md)
for the observed Nix, Linux Standard, native Windows and live IPE gates.

Run `node --test tests/windows-source-test.cjs` for recursive pin validation,
tracked-source isolation, dirty-checkout rejection and missing submodules.
Run `pwsh -NoProfile -File tests/windows-native/bootstrap-offline.ps1` for
checksum rejection, corrupt-cache recovery, offline cache reuse and ZIP traversal
rejection. These checks use fixtures without credentials; the PowerShell helper
checks also run on Linux. Native acquisition and the interactive handoff must
additionally run in the disposable Windows VM described below.

## Native Windows development proof

The [bounded Windows proof](tests/windows-native/README.md) runs only in a
Windows VM using an ordinary account. It separates cross-compilation from
native execution, and documents the primitive gate, relocated runtime, model
file task, and sign-in reboot check. It is not a release or full IXE gate.

## Umbrella-owned test catalogue

### Confirmed uninstall

The [uninstall container acceptance gate](tests/uninstall/README.md) tests the
candidate native CLI and concierge together with real process shutdown, terminal
confirmation, deletion and preservation assertions inside a disposable offline
container. Run it for uninstall changes alongside the owning Go and TypeScript
tests. Its README identifies simulated installation boundaries and the separate
Standard packaging and systemd coverage requirements. Use its `--systemd`
variant for a real isolated user service and the Standard curl smoke gate below
for removal of a fully relocated bundle.

### Independent native and DearMachine configuration

The [configuration coexistence evaluation](tests/config-coexistence/README.md)
uses one packaged Machtiani executable, the real installer configuration stages,
and DearMachine's production invocation code. It covers both setup orders,
legacy migration, independent model changes, credential selection and failure,
and preservation of each caller's configuration. The default uses a deterministic
loopback provider; its opt-in live variant runs the same assertions with two
real models. This targeted integration check supplements the Installer QSE and
managed installation lifecycle checks.

### Container build acquisition

`python3 tests/container-build-test.py` exercises the production source-snapshot
and activation boundary without Docker, credentials or installed products.
Wizard selection, build failure and cancellation are in the installer's existing
app suites. The production builder is `scripts/container-build.py`; see
[Container build installation](docs/container-build-installation.md).

Reuse `tests/standard-runtime-smoke.py` and `tests/standard-agent-smoke.mjs` for
the Docker-built runtime. They are the shared runtime gate, not separate Standard
and Container build suites. IXE and QSE retain ownership of human interaction
and live email respectively. The VM harness verifies acquisition from the actual
wizard with its own Docker engine; it must not mount a host Docker socket.
Commands, prerequisites and resource limits are in the
[IXE VM acquisition guide](tests/e2e-installation-experience/README.md#container-build-acquisition-in-a-linux-vm).

### Booted NixOS runtime smoke test

The [NixOS gate](tests/nixos-installation/README.md) installs the actual installer
runtime as an ordinary user in a booted guest and verifies entrypoints and a
user-service probe across restart/reboot. It is credential-free; it does not
replace live product, authentication or email verification.

### Standard runtime packaging

`python3 tests/standard-runtime-test.py` runs fast, credential-free relocation
contracts. `python3 tests/standard-bootstrap-test.py` exercises the real curl
bootstrap against a tiny local fixture: checksum rejection, existing-file
preservation, symlink rejection, complete activation, and verified-cache reuse.
`scripts/prepare-standard-runtime.py --help` describes the producer
for a source-only release plus existing, pinned Linux x86-64 runtime outputs.
The producer uses Nix on the build host only; the target-side bootstrap ships
its own Python and ELF loader. A successful producer run is not a portability
gate: all required entrypoints and child processes must also run in a disposable
container without `/nix`, before a Standard installation is offered in IXE.

Copy `tests/standard-runtime-smoke.py` and its sibling
`tests/standard-agent-smoke.mjs` into that disposable container and run
it with `<release>/bin/python3 <copied-smoke.py> <release>`. This checks native
and TypeScript entrypoints, Node/Python child execution, and an actual Git LFS
clean-filter commit, with a temporary home. The agent fixture boots both the
installer and concierge compositions, calls model-host through a credential-free
loopback model, and verifies a real harmless shell-tool round trip. There are no
external provider calls, sign-ins, or installed daemons. Native Node addons use
Node's matching bundled libraries; other runtimes retain their own libc paths.

Use `scripts/standard-runtime-tools.nix` for the checksum-pinned portable Git
LFS binary; ordinary CGO Git LFS packages are not interchangeable in this gate.
Then `scripts/prepare-standard-download.py --runtime <prepared-directory>
--output <new-download-directory> --base-url http://127.0.0.1:8765` produces
`install`, `runtime.tar.gz`, and a provenance/checksum manifest. Serve only that
download directory on loopback. Never serve a checkout, home, or credential
directory. The bootstrap does not launch a TUI through the curl pipe; invoke
`dearmachine` afterward at a terminal.

For the real download-to-runtime gate, reuse that download and an already-cached
Debian image (with curl, tar, gzip, useradd, and Bash):

```console
python3 tests/standard-curl-smoke.py --download /absolute/download-directory --image golang:1.26.8-bookworm
```

This opt-in test creates a fresh user and container without `/nix`, executes
the actual curl pipe, checks the installed runtime including the bundled Claude
executable, and repeats bootstrap with the server stopped to verify cache reuse.
It serves only the three release artifacts on host loopback. The disposable
container uses host networking to reach that loopback server; it has no host
mounts, credentials, or published ports. Only its own container is removed on
exit. It additionally starts a disposable native supervisor, checks declined and
confirmed uninstall, verifies software and private-data removal, bootstraps again
without the old state, and uninstalls again. It does not build or pull an image
or replace the human IXE and live QSE gates.

### Deterministic contracts

| Entrypoint | Coverage |
| --- | --- |
| `tests/submodule-maintenance-test.sh` | Three-submodule discovery, update commits, pinned worktree setup, teardown, and no-change behavior in disposable local repositories |
| `tests/submodules-from-local-test.sh` | Source-local cloning of every exact umbrella gitlink without changing the target checkout's HEAD |
| `tests/install-prompt-test.sh` | Permanent installer-agent contract, staged instruction routing, canonical messages, supported backend sources, credential UI boundary, and stage ordering |
| `tests/documentation-entrypoint-test.sh` | Stable canonical documentation entry point, evidence hierarchy, and required links into the pinned product documentation |
| `python3 tests/backend-guidance-test.py` | Backend discovery, setup ownership, persistent OMP settings, and probe prerequisites; also included in the documentation entrypoint check |
| `tests/credential-entry-test.sh` | Retained legacy `micro` helper behavior and the boundary that prevents the new Installer from packaging that retired credential UI |
| `python3 tests/release-install-test.py` | Rendered release installers: `gh attestation verify` pinning and ordering, checksum and missing-target failures, and the typed `yes` fallback on a real terminal when `gh` is missing or signed out; uses a stub `gh` and a loopback server |
| `python3 tests/curl-bootstrap-test.py` | Local HTTP bootstrap, checksums, cache hits, piped execution, architecture guards, and preservation of existing launchers; uses a fake Nix store |
| `scripts/windows-launcher_test.go` | Native Windows launcher configuration selection and saved AgentMail credential references through stable and release-local entrypoints; compile and run as documented in the [Windows gates](tests/windows-native/README.md#build-and-lifecycle) |
| `node --test tests/windows-native/filesystem.cjs` | Native Windows removal of generated package junctions without following targets, redirected-root refusal, and long Unicode paths; requires native Windows Node |
| `node --test tests/codex-runtime-test.cjs` | Pinned bundled Codex version/startup gate and suppression of dependency stderr |
| `node tests/windows-native/codex-paths.cjs <installer-runtime>` | Native Windows Codex launch, long-path failure diagnosis and relocation using downloaded pinned packages; no sign-in or network |
| `node tests/windows-native/activity.mjs <fixture-runtime> <source-root>` | Native Windows Quick start animation, stdout/stderr, plain redirected output, failure and Ctrl+C cancellation; uses Node/node-pty only |
| `tests/windows-native/reinstall.ps1` | Native Windows confirmed uninstall, fresh setup consent beside preserved independent Machtiani data, and final removal; disposable guest only |
| `powershell -NoProfile -File tests/windows-native/credential-entry.ps1` | BYOC Windows credential helper: replacing an existing private file, repeated prepare, and the private ACL; Windows PowerShell 5.1, no secrets |
| `python3 tests/e2e-installation-experience/curl-bundle-test.py` | Local-only server boundary, artifact allowlist, and source archive isolation; no Docker or credentials |
| `scripts/verify-installation-procedure.sh` | Concise README installation surface, canonical detailed procedure, and required policy assertions |
| `tests/e2e-installation-experience/contract-test.sh` | IXE adapters, pinned fixtures, source isolation, installer wiring, and command-line contract |

All of these are credential-free. They may create disposable files or local Git
repositories beneath `${TMPDIR:-/tmp}` but must leave the source checkout
unchanged.

### Installation Experience Evaluation

The IXE evaluates the human-facing conversation, terminal behavior,
authentication handoffs, judgment, and recovery in a sparse container. Its
detailed contract is in
[`tests/e2e-installation-experience/README.md`](tests/e2e-installation-experience/README.md).
Choose `--backend-fixture forge` (default) for an existing-backend flow or
`--backend-fixture none` for installing a backend, followed by post-install
concierge exploration. The fixture's fast tests are included in the IXE
self-test; its optional cached-container check is documented in that README.
The [agent-operated IXE runbook](tests/e2e-installation-experience/operator-runbook.md)
documents adaptive user rehearsals and the optional `operator-test.py` safety
gate (with pinned dependencies from `operator-requirements.txt`).

| Entrypoint | Safety class |
| --- | --- |
| `tests/e2e-installation-experience/run.sh --self-test` | Credential-free contract and archive checks; no Docker mutation |
| `tests/e2e-installation-experience/run.sh` | Interactive, containerized, credentialed live installation; provider and email effects may incur charges |

The first-party Machtiani Installer is the current default conductor. The
`codex`, `omp`, and `forge` adapters remain available only for historical
comparison and regression diagnosis through `--agent`; they are not alternate
public installers or routine release gates. Scripts beneath the IXE `agents/`
directory and the in-container `run-install-evaluation` command are supporting
parts of the host runner, not independent test suites.

### Installation Procedure Evaluation

The IPE has one primary host entrypoint and is documented in
[`tests/e2e-installation-procedure/README.md`](tests/e2e-installation-procedure/README.md).

| Entrypoint | Safety class |
| --- | --- |
| `tests/e2e-installation-procedure/run.sh --self-test` | Credential-free source archive, preflight, lock, and empty-cleanup checks; no Docker mutation |
| `tests/e2e-installation-procedure/run.sh` | Containerized, credentialed live execution of the canonical procedure with real provider calls, email, disposable inbox creation, and exact cleanup |

The live IPE uses Forge to execute the published raw procedure. It is distinct
from IXE, which judges the human installation experience, and from the
Installer-owned QSE, which is the complete product release scenario.
Its [model configuration](dearmachine-concierge/tests/e2e/README.md) accepts a
provider, model, reasoning level, and private credential-file reference, plus
an endpoint for compatible providers. Forge may use an explicitly separate
selection when its capabilities differ. No provider or reasoning fallback is
implicit; the interactive installer and Linux terminal operator are unchanged.
Container helpers, transaction libraries, and the AgentMail helper beneath the
IPE directory are implementation details of `run.sh`, not separate entrypoints.

### Manual backend login handoff

`python3 tests/backend-guidance-test.py` and `tests/install-prompt-test.sh`
check the shared manual-login rules and selected-backend guidance.
For the opt-in live behavior gate, run inside a disposable source-only container:

```console
node tests/backend-login-handoff.mjs /absolute/installer/runtime /absolute/source /private/provider.env
```

The private, owned mode-0600 environment file must contain the approved
`OPENROUTER_API_KEY`; never put its value in arguments or copy host profiles.
This uses the real installer DSH session and OpenRouter `z-ai/glm-5.3-flash`
with high reasoning. It makes billable model requests, but backend login and
health are fixture commands: no subscription account or inbox is contacted.
Both absent-integration and failed-interaction scenarios must give a manual
command, wait through a still-working reply, and run functional verification
only after readiness confirmation. Broker status remains `not_configured` even
after local login; a recovery scenario must verify the working local login
without requesting another login or configuring a remote broker. The fixture
cannot establish real OMP authentication. Temporary fixture homes are removed
on success or failure.

### Test-email sender and destination

The installer workflow tests cover the initial email instruction, a resumed
question with changed pairing, and rejection of missing address state. The
umbrella prompt contract keeps the human instruction explicit about both roles.
For a focused opt-in live check inside a disposable source-only container:

```console
node tests/test-email-guidance.mjs /absolute/installer/runtime /absolute/source /private/provider.env
```

Use the same private credential setup as the manual-login gate above. This runs
the real installer agent with OpenRouter `z-ai/glm-5.3-flash` on high, checking
both an established pairing and one whose sender and inbox changed. All email
addresses are fixtures; the test sends no email and uses no real inbox.

## Required gates

- Follow `docs/parallel-development-runbook.md` for the minimum check owned by
  a changed submodule.
- Changes to the root README require `scripts/verify-installation-procedure.sh`
  and the IPE self-test. Changes to the canonical installation procedure, its
  verifier, or the IPE harness require the verifier followed by the live IPE.
- Use IXE when the human-facing installation conversation, authentication,
  terminal lifecycle, or recovery experience changes.
- Use the Installer's live QSE before advancing a release candidate that
  changes the installed product path. Documentation-only changes to a component
  testing guide require its deterministic checks and QSE self-test where
  relevant, but not a credentialed QSE by themselves.

Live gates must use disposable resources, private mode-`0600` credential files,
and the cleanup contract documented by their owning harness. They can make paid
requests and must never use or delete the permanent AgentMail inbox.

For the optional OpenMail sender in IPE, run
`python3 tests/e2e-installation-procedure/openmail-sender-test.py` for offline
ownership, response-loss recovery, and cleanup checks. The live mixed-provider
invocation is documented in the [IPE guide](tests/e2e-installation-procedure/README.md).

`python3 tests/e2e-installation-procedure/fixture-test.py` checks the IPE's
private model-profile prerequisite, both model-host configuration assertions,
and reconstruction of clean Git checkouts from source archives.

## Maintaining this entrypoint

Add a new umbrella-owned runnable suite here in the same change that introduces
it. A new submodule suite belongs in that submodule's root `TESTING.md`; update
this file only when its cross-component role changes. Explicitly label a
retired, historical, or supporting path and name its maintained replacement or
parent harness instead of silently removing it from the documentation.
