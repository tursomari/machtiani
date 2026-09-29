# Stage 1: environment and basic dependencies

Read and apply this file only after the human accepts the welcome invitation.
The permanent contract in `INSTALL.md` remains in force.

## Goal

Understand the existing machine and leave the basic installation tools ready,
without yet asking configuration questions or configuring a backend agent.

## Inspect first

Inspect the operating system, architecture, current checkout, initialized
submodules, installed commands, existing Dear Machine and Machtiani
configuration, and relevant running services. Do not print secrets or read
credential values. Continue from healthy existing state.
Do not open the shared model profile during environment discovery, even to
inspect its shape or print selected fields. The launcher already supplied the
non-secret provider/model/reasoning selection and opaque profile reference.
Use those values; do not rediscover them by reading private configuration.
Do not open credential files even to redact their contents, check their shape,
or confirm that setup worked. Do not enumerate variable names from
`~/.config/dearmachine/backends.env`, other `.env` files, API-key files, or
provider auth/token stores. Ordinary configuration inspection means known
non-secret product settings and native status, not dumping a directory's files.
The supplied profile metadata and credential-helper receipts cover credential
readiness; missing runtime functionality is diagnosed through the selected
consumer, not by parsing secrets in shell.

Apply the permanent contract's public-conversation guidance here: describe
relevant outcomes in user terms, without narrating each inspection or the
internal stage handoff. Do not announce that you will ask a question; ask it.

As part of this inspection, perform a preliminary catalogue check for the
user-facing built-in backends Codex, Forge, and OMP. At this stage, detection
means only resolving the `codex`, `forge`, and `omp` executables on the
effective `PATH`. Record their user-facing names privately for Stage 4. Do not
choose, configure, authenticate, or health-probe a backend yet.
Use [backend discovery](backend-discovery.md) before reporting a command absent;
a shell lookup alone may miss an existing user-local installation.

## Prepare missing basic tools

Use `installation.method` from the launcher's runtime context. For `container`,
read `docs/container-build-installation.md`: the wizard has built and verified
the supplied runtime. The same supplied-command rules below apply. For `standard`,
the complete runtime has already been acquired by the platform-specific builder
or a prebuilt release. Verify its commands (including Git and Git LFS) and continue with
configuration. Do not install Nix, invoke Nix, or rebuild a missing product.
If a required supplied command fails, diagnose the release and report the
concrete blocker; do not silently switch installation methods. Its source is a
versioned snapshot, not a Git checkout: read `bootstrap-source-revisions.json`
for provenance and do not create `.git` or initialize submodules there.

On native Windows, use the supplied Standard runtime. Read
`docs/windows-native.md` for Windows paths, backend installation, and lifecycle
commands. Do not introduce WSL, a Linux VM, Nix, or systemd. Git Bash is a native
Windows shell; its commands operate on the same files shown in File Explorer.
Use quoted Windows paths with native executables and `cygpath` when crossing
into Bash path syntax. Prefer a normal user-owned Documents folder for the
workspace. Do not place user work inside the immutable release directory.

Use `git --version` and `git lfs version` for the basic executable checks.
`git lfs env` can create `lfs/tmp` and `lfs/objects` in the current directory
when no Git repository is present; it is not a read-only substitute for the
version check. If a deeper tool probe is actually needed, run it in an explicitly
created disposable directory, not the supplied release or another user project.
Keep the source snapshot unchanged, including generated cache directories;
do not delete unexpected source files just to make verification pass.

The dependency installation instructions below apply only to `nix`. The wizard
automatically uses Nix on NixOS; other Linux hosts and macOS offer Nix (the recommended default) and Standard. Standard builds natively on
macOS; for Nix, use native Darwin packages. A Linux runtime built by Docker cannot serve as the native
client, even when Docker runs on a Mac.

Handle missing dependencies before configuration questions. Introduce only the
next missing tool in plain language. Say briefly what it does, why Dear Machine
needs it, and that it is a widely used project. Do not present a dependency
checklist, package-manager details, or an installation command to the human.

Ask permission before installing Nix because it changes the machine-level
environment. After authorization, install it yourself using the canonical
official installer at `https://nixos.org/nix/install` and verify it. Do not
substitute another installer URI.

The launcher offers to save the required `nix-command` and `flakes` settings
in the user's Nix configuration before guided setup, including when Nix is
not installed yet. After installing Nix and loading its shell environment,
verify both features with a fresh `nix show-config --json` process without
feature-enabling flags or environment overrides. Inspect only the
`experimental-features` value; do not print the full configuration.
If either feature is still disabled, diagnose the effective configuration and
help the human repair it, preserving existing settings. Do not use per-command
feature flags as a substitute for saved configuration: the next launch must
work too.

Once Nix is available, use the canonical Nix package references `nixpkgs#git`
and `nixpkgs#git-lfs` for missing Git and Git LFS. Git provides the
source-control foundation. Git LFS provides the large-file support required by
Dear Machine's workspace for state and memory management. Tell the human which
of these tools are missing and that you will install them together through Nix,
then perform and verify the installation yourself. Do not ask separate
permission to install Git or Git LFS after Nix is available.

Backend agents are user-owned prerequisites, not part of this dependency stage.
Do not install or upgrade one merely because it is detected or missing.

## Completion and handoff

This stage is complete when the environment is understood, the selected
method's tools are available (Nix only for the Nix method), Git and Git LFS
are available, and the preliminary backend executable results
have been recorded privately.

Then read all of `docs/installation/02-provider.md`. Do not read any later stage
or backend guide yet.
