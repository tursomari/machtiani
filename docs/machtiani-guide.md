# Machtiani guide

Machtiani is a terminal-first agent toolchain. Its orchestrator drives a local agent loop with embedded file discovery and project-specific sessions. Most users only need the `machtiani` binary; the standalone internal tools are development builds.

## Prerequisites

- Nix 2.24 or newer with flakes enabled.
- A writable binary directory on `PATH`, such as `~/.local/bin`.

## Install

From the umbrella repository:

```bash
cd machtiani-harness
nix run '.#install'
machtiani --version
machtiani update --check
cd ..
```

Quoting `'.#install'` prevents the shell from treating the flake selector as a glob. The installer defaults to `~/.local/bin/machtiani`; `--prefix <dir>` selects another prefix, and `--no-interactive` uses the default without prompting.

## Managed and development installations

`machtiani` is the managed installation and follows the remote default branch through its built-in updater. `machtiani-dev` is a development build from a checkout that you advance and rebuild manually. It shares Machtiani configuration and project data with the managed command, but it neither replaces `machtiani` nor uses `machtiani update`.

## Core usage

Initialize a project to create its identity and install or refresh the canonical modes:

```bash
machtiani init
```

Run a mode and inspect the resolved project store:

```bash
machtiani run --mode <mode> -p "<prompt>"
machtiani project show
```

For configuration, modes, sessions, and troubleshooting, see the [Machtiani README](../machtiani-harness/README.md). For the repository-specific operating workflow, see the [Machtiani runbook](../machtiani-harness/docs/machtiani-runbook.md).


## Changing a provider credential through Concierge

Name the component explicitly: “Make Machtiani use its saved DeepSeek key,” or
“Replace Machtiani's DeepSeek key.” Concierge's `machtianiProvider` helper
connects the exact existing global provider alias to its saved environment
variable. `replaceMachtianiProvider` opens masked entry even when a key is
already saved, then makes the same connection. No credential value enters the
conversation or the configuration command. Other provider settings and model
choices remain intact. Model-host providers use their own profile instead.

First inspect the project's active config scope and the provider with
`machtiani config provider show <alias> --global`; do not read a config file
containing literal keys into the conversation. This helper targets global
configuration; an active project override requires separate scoped handling.
Confirm that the actual runtime loads the reference's environment file. A
service's `EnvironmentFile` does not supply variables to a separate terminal.

The helper and `machtiani config check` establish configuration, not successful
authentication or task execution. Choose verification for the configured transport:

- When all configured model roles use `model-host`, `machtiani verify --json`
  makes provider requests through those roles in the intended runtime environment.
- For direct HTTP providers, verify an authorized small task through Machtiani
  using its actual provider, model, and credential environment, or observe an
  already-authorized email task through completion. `machtiani verify` rejects
  these configurations before making a provider request. Its “does not use the
  shared model host” error is a command limitation, not a rejected credential.
  Do not change the provider transport just to satisfy that command.

A successful provider models-list request establishes authentication to that
endpoint; it does not prove model generation or email delivery. Keep provider
error bodies out of the conversation because they can contain key fragments.
Start or restart the client only when included in the request, then confirm it
stays healthy and distinguish task completion from a momentary running status.
The credential helper itself does not restart services or make provider requests.

`/model` changes only the Concierge assistant. Backend-agent credentials use the
separate [backend management](backend-management.md) flow. Replacing a shared
saved credential affects every component referencing it; the masked prompt
explains that effect. See the [credential operations and security contract](../dearmachine-concierge/docs/credential-security.md).
