# Dear Machine and Machtiani documentation

This is the canonical documentation entry point for the composite Dear Machine
product pinned by this umbrella source revision. It is a map into ordinary,
versioned documentation in this repository and its pinned components; it is not
a separate concierge manual or generated documentation bundle.

## How to use this documentation

Documentation describes intended and supported behavior. Observed runtime state
is authoritative for facts about what is currently installed, configured,
paired, or running on a particular machine. Source code and tests are the
fallback when documentation is incomplete or ambiguous, observed behavior
conflicts with it, or a likely defect needs diagnosis.

Start here, follow the narrowest relevant link, and distinguish those three
kinds of evidence when they disagree. The umbrella revision identifies the
exact component revisions to which these documents apply.

## Installation platforms

| Installation route | Linux | macOS |
| --- | --- | --- |
| Nix | x86-64 and ARM64 targets | Intel and Apple Silicon targets |
| Standard | x86-64, built with Docker | Intel and Apple Silicon, built directly |

The installer automatically uses Nix on NixOS. Other Linux hosts and macOS offer Nix (the recommended default) and Standard. Standard uses Docker on Linux
and Apple's native developer tools on macOS; all installed products run on the
host. Each release also publishes verified prebuilt downloads; see
[Release publishing](release-publishing.md). The native macOS Standard path
is under verification; see [macOS status](macos-support.md).

Target availability is separate from live verification. The full IPE for the
context-overflow fixes at umbrella revision `8860694c` passed on Linux x86-64
in containers on a WSL host, using DeepInfra GLM-5.3-Flash with high reasoning.
That run did not verify macOS or Linux ARM64. See the [testing entrypoint](../TESTING.md)
for the platform and live checks to run when validating a release.

## Product orientation and installation

- [Coordinated Nix installation and updates](managed-nix-installation.md) describes
  retained source snapshots, release ownership, and `dearmachine update`.

- [Reinstall and restore data](reinstall-with-data-restore.md) covers recovery
  when a managed Nix updater cannot cross a release-layout change.

- [Container build installation](container-build-installation.md) describes the Linux
  build implementation used by Standard, including Docker caching and the host runtime.

- [Standard installation](standard-installation.md) describes Nix-free
  builds on Linux and macOS and their shared configuration with the Nix path.

- [Release publishing](release-publishing.md) describes the attested GitHub
  release workflow, its prebuilt downloads, and the verifying installers.

- [Umbrella overview](../README.md) introduces the composite project and its
  component boundaries.
- [Bring your own concierge](../BYOC.md) lets an agent the user already has
  install and manage Dear Machine directly, reusing the guided installer's
  contract and stages without the first-party launcher or concierge.
- [Installer operating contract](../INSTALL.md) defines the complete guided
  installation, permanent safety rules, stage map, and canonical user messages.
- [Staged installation guide](installation/README.md) routes through the
  just-in-time instructions used by the guided installer.
- [Published installation procedure](installation-procedure.md) is the
  reproducible lower-level procedure used to install the integrated stack.

## Operating the installed product

- [Uninstall DearMachine](uninstall.md) covers terminal confirmation, shutdown,
  permanent local removal, preserved independent data, and recovery.
- [Backend management](backend-management.md) covers adding or configuring an
  agent, secure credential entry, and preserving the current working setup.
- [Dear Machine guide](dearmachine-guide.md) covers the user-facing client,
  inbox pairing, backend work, and normal operation.
- [Machtiani guide](machtiani-guide.md) covers the local agent harness and its
  role in Dear Machine.
- [Dear Machine component overview](../dearmachine/README.md) describes the
  client, Agent Manager, transports, and component-level entry points.
- [Dear Machine runbooks](../dearmachine/dearmachine/runbooks/README.md) index
  operational diagnosis and recovery material.
- [Machtiani Harness overview](../machtiani-harness/README.md) describes the
  runtime, tool boundary, and source layout.
- [Machtiani configuration reference](../machtiani-harness/docs/configuration.md)
  defines supported configuration and model roles.

## Installer and concierge behavior

- [Machtiani Installer overview](../dearmachine-concierge/README.md) describes the
  wizard, shared model host, installation agent, and management concierge.
- [Concierge user stories](../dearmachine-concierge/docs/concierge-user-stories.md)
  define the supported local-management experience and authority boundaries.
- [Installer testing guide](../dearmachine-concierge/TESTING.md) identifies the
  maintained deterministic, terminal, IXE, and QSE evidence for installer and
  concierge behavior.

## Architecture, development, and verification

- [Umbrella testing entry point](../TESTING.md) maps changes to their owning
  component checks and cross-product evaluations.
- [Umbrella maintenance runbook](umbrella-runbook.md) defines component pins,
  local landing, and release responsibilities.
- [Parallel development runbook](parallel-development-runbook.md) defines the
  isolated-worktree, testing, review, and signing workflow.
- [Development updates from local mirrors](local-development-updates.md) explains
  how to use `dearmachine update` with a local drive instead of publishing to
  GitHub, and how to remove the Git URL redirects on release day.
- [Umbrella architecture decisions](adr/) record durable cross-component
  decisions. Each component also retains its own decisions and development
  documentation beneath its versioned source tree.
