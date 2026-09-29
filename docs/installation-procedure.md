# Detailed scripted installation

This is the canonical, executable installation procedure for a new Machtiani
checkout. The normal user experience is the guided `dearmachine` concierge in
the [Quick Start](../README.md#quick-start); use this document for manual setup,
automation, and release verification.

This procedure uses Nix, with targets for Linux x86-64/ARM64 and macOS
Intel/Apple Silicon. See [installation platforms](README.md#installation-platforms)
for acquisition alternatives and live test coverage. Standard builds without
Nix, using Docker on Linux x86-64 and native developer tools on macOS.

## Prerequisites

- Nix 2.24 or newer with flakes enabled.
- Git.
- `~/.local/bin` before `$HOME/.nix-profile/bin` on `PATH` (the Machtiani installer creates it when needed), or another writable bin directory on `PATH`. The native `dearmachine` must take precedence over the installer's compatibility alias in the Nix profile.
- A private shared model profile created by the Machtiani Installer wizard.
  API-key profiles support OpenRouter, DeepSeek, and the OpenAI API. The
  profile references credentials but never contains their values.
- For DearMachine, credentials for a supported email transport and the email
  address that will send it work.
- A selected backend agent on `PATH`. Use a built-in Dear Machine backend or a
  custom backend that has passed the compatibility checks in
  `dearmachine/docs/custom-backend-guide.md`. An installation agent may install
  a missing backend only after the user explicitly asks it to do so.

## One-time clone

```bash
git clone --recurse-submodules https://github.com/tursomari/machtiani.git
cd machtiani
```

If you already have the checkout, skip the clone, change into its root, and ensure all three submodules are initialized before continuing:

```bash
git submodule update --init --recursive
git status --short --untracked-files=all
```

Use a clean checkout, including the submodules: the source installer refuses
modified or untracked files. Save your work before installing; do not delete
files simply to make the check pass.

## Install Machtiani

```bash
cd machtiani-harness
nix run '.#install'
machtiani --version
cd ..
```

The installer defaults to `~/.local/bin/machtiani`; the command above asks you to confirm that destination. Use `--prefix <dir>` to select another prefix. For an unattended install that accepts the default without reading stdin, run:

```bash
nix run '.#install' -- --no-interactive
```

Install the model-host executable from the same reviewed installer checkout:

```bash
nix profile install 'path:dearmachine-concierge'
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:$PATH"
hash -r
command -v machtiani-model-host
```

The first build can take several minutes. If running through an agent or a
command runner, supervise one long-running job and wait for it to finish;
do not restart the build just because a tool's short timeout expired.

## Configure the shared model

The prerequisite wizard has already written a private version-1 profile at
`$HOME/.config/machtiani/model-profile.json`. Configure Machtiani to use that
profile through the model-host transport. Keep the component selectors below
literally: the model host resolves each saved model and reasoning level on every
request. Fixed model IDs or reasoning parameters here would override later
`/model` changes. Do not start another provider wizard or copy credentials into
this file.

```toml
default_model = "dearmachine"
shell_agent_model = "dearmachine-shell-agent"
answer_model = "dearmachine"
file_discovery_model = "dearmachine"

[providers.dearmachine-host]
transport = "model-host"
profile = "~/.config/machtiani/model-profile.json"
command = "machtiani-model-host"

[models.dearmachine]
provider = "dearmachine-host"
model = "@machtiani/planner"
context_length = 131072

[models.dearmachine-shell-agent]
provider = "dearmachine-host"
model = "@machtiani/shell-agent"
context_length = 131072

[models.dearmachine-sync]
provider = "dearmachine-host"
model = "@machtiani/sync"
context_length = 131072
```

Write this as the owned mode-`0600` global file
`$HOME/.config/machtiani/config.toml` (or `$XDG_CONFIG_HOME/machtiani/config.toml`
when explicitly configured), preserving an existing user configuration
rather than overwriting it. Do not add a reasoning table to these managed
aliases; reasoning comes from the saved component selection. Then validate it
with the standalone path explicitly selected. Setup launched by Dear Machine
may inherit `MACHTIANI_CONFIG` pointing at its private destination before that
file exists. These per-command assignments do not change the global environment:

```bash
MACHTIANI_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/machtiani/config.toml" machtiani config check
MACHTIANI_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/machtiani/config.toml" machtiani auth status --model dearmachine
```

## Use Machtiani

From the machtiani checkout root, run these commands after creating the valid
`~/.config/machtiani/config.toml` above. Initialize the checkout before the
first sync. The checkout must have at least one commit;
`machtiani sync` refreshes its internal README. The model host loads the
private profile and provider-owned authentication itself, so no provider key or
token needs to be exported into this shell.

The subshell selects the standalone configuration for these checks without
changing the caller's environment:

```bash
(
export MACHTIANI_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/machtiani/config.toml"
machtiani init --no-interactive --config-scope global
machtiani sync
printf 'c\n' | machtiani run --mode code -p "<your prompt>"
machtiani project show
)
```

Replace `<your prompt>` with a repository task; `Summarize README.md` is a harmless first check. `--mode <mode>` names a mode from the canonical library under `~/.machtiani/modes/`, such as `code`. The piped `c` completes the parent prompt after the child finishes; interactively, omit `printf` and press `c` at that prompt yourself.

For more detail, see the [Machtiani guide](machtiani-guide.md), [Machtiani README](../machtiani-harness/README.md), and [Machtiani runbook](../machtiani-harness/docs/machtiani-runbook.md).

## Install DearMachine

Backend agents are user-installed prerequisites by default. Dear Machine setup
and its installation agent must not install or upgrade one unless the user
explicitly asks. After that request, inspect the proposed source and command,
perform the installation, and verify the executable. Authentication remains a
human-controlled action; the agent may start a documented login flow, but the
user supplies credentials and completes browser or device authorization.

Verify the selected agent's executable and documented version or help command
before changing Dear Machine. Use its exact executable rather than assuming a
particular built-in backend.

```bash
cd dearmachine
nix run '.#install'
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:$PATH"
hash -r
command -v dearmachine agent-manager machtiani
dearmachine --help
cd ..
```

DearMachine uses its own Machtiani configuration at
`$HOME/.config/dearmachine/machtiani/config.toml`. Before the first
`up --create`, import the configuration above using the native no-overwrite
writer. Both configurations reference the selected shared model profile;
later edits to either TOML file remain independent.

```bash
MACHTIANI_CONFIG="$HOME/.config/dearmachine/machtiani/config.toml" \
  machtiani config import --source "${XDG_CONFIG_HOME:-$HOME/.config}/machtiani/config.toml"
MACHTIANI_CONFIG="$HOME/.config/dearmachine/machtiani/config.toml" \
  machtiani config check
```

If DearMachine already has its configuration, validate that existing file
instead of importing over it.

For a selected built-in backend, configure its internal backend ID. Replace the
placeholder with the ID established during backend selection:

```bash
dearmachine setup-agents --backend '<selected-backend-id>' <<'EOF'

EOF
```

`setup-agents` asks you to confirm the backend order. The empty line in this
scripted example accepts the selected backend; at a terminal, run the command
without the here-document and press Enter at the prompt. It also writes an
initial device config with the plain response tier. The Run section below
intentionally replaces that file with the complete formatted-tier config used
by this Installation Procedure.

For a selected custom backend, follow
`dearmachine/docs/custom-backend-guide.md`: write its stable executable and
invocation to `custom-backends.toml`, approve its ID directly in
`dearmachine.toml`, and pass both the installed Agent Manager health check and a
synthetic ticket. Do not run `setup-agents` afterward; that command discovers
built-in backends. Continue the rest of this procedure with the verified custom
backend ID. In progress messages, say only that you are configuring the
selected backend; do not narrate differences from built-in setup.

`machtiani` comes from the Machtiani installation above.

## Run DearMachine

Provide a private one-line credential file, then create the first pair. That
one command initializes Dear Machine's default workspace, provisions a new
inbox, authorizes the exact sender at the transport seam, creates that pair's
isolated database, and starts all registered pairs in one native background
client. The workspace is used for Dear Machine's state and memory management.
The CLI calls it the entry-point repository; existing repositories are left
unchanged.

DearMachine reads a version-1 TOML device configuration from
`$HOME/.dearmachine/config/dearmachine.toml` by default; pass another location
with `--config`. For a formatted-tier reply, the configuration must set both
`response_tier = "formatted"` and its selected backend list.
The snippet below replaces that config file with the complete minimal config
used by this Installation Procedure; merge those settings instead if you keep other
options there.

The model host reads the selected profile's private credential reference during
workspace initialization and later tasks. No provider API key needs to be
exported into the client launch shell.

```bash
export AGENTMAIL_API_KEY_FILE="$HOME/.config/dearmachine/agentmail-api-key"
install -d -m 0700 "$HOME/.dearmachine/config"
cat >"$HOME/.dearmachine/config/dearmachine.toml" <<'EOF'
version = 1
backends = ["<selected-backend-id>"]
response_tier = "formatted"
EOF
chmod 0600 "$HOME/.dearmachine/config/dearmachine.toml"

dearmachine up --create --resume \
  --email '<your-email-address>' \
  --new-inbox \
  --transport agentmail \
  --project "$HOME/.dearmachine/entrypoint/main" \
  --entry-point-repo "$HOME/.dearmachine/entrypoint/main" \
  --config "$HOME/.dearmachine/config/dearmachine.toml" \
  --poll-interval 5s \
  --magnifica-humanitas=false \
  --verbose

dearmachine status
```

Use the separate `dearmachine init --entry-point-repo <path>` command only when
deliberately preparing a custom state-and-memory workspace before selecting it
with `up --create`.

During the normal installation, do not run `dearmachine init` separately:
`up --create` owns initialization of the default workspace. If initialization
is interrupted, rerun the same command with `--resume`; Dear Machine validates
its private transaction journal and continues completed phases without
provisioning a second inbox. Diagnose the original failure rather than deleting
the journal or Dear Machine's internal bootstrap marker.

If inbox provisioning fails and the human chooses a different email service,
keep the same command and `--resume`, changing `--transport` to that service.
Use the selected service's credential helper first. Native recovery accepts
this change only for a new inbox that has not yet been recorded; it preserves
the initialized workspace and saves the replacement choice before contacting
the new provider. A failed request may have reached the old provider, so this
does not claim that no remote inbox exists or delete any remote resource.
If an inbox or pairing has already been recorded, preserve it and diagnose
that state instead of deleting the journal or silently provisioning a replacement.

This command performs durable model-backed work. Run it as one supervised
background job without a short outer timeout, monitor its progress until it
exits, and never start a second copy while it is alive.

The five-second poll interval makes this first live test respond promptly.
Both settings are remembered for later plain `dearmachine up` launches.

Magnifica Humanitas quotes are optional and off unless the human explicitly
chose them, before pair creation, using the quote question in `INSTALL.md`.
Always pass the value explicitly: `--magnifica-humanitas=true` only for an
explicit opt-in, and `--magnifica-humanitas=false` for “No, thanks,” for no
answer, and for any ambiguous answer. Omitting the flag is not the same as
choosing “No, thanks”: `up` keeps the value already recorded in Dear Machine's
runtime profile, so an existing installation that earlier enabled quotes would
stay enabled. The explicit value is recorded as `magnifica_humanitas` in that
profile, so later plain `dearmachine up` launches keep the choice. The quotes
can appear in email footers and in Machtiani's terminal banner; choosing them
adds no AI request. This procedure documents no separate later settings command.

If an inbox already exists, use `--inbox '<exact-inbox-id-or-address>'
--transport <transport>` in place of `--new-inbox --transport <transport>`.
This deliberately adopts that inbox; pair creation still authorizes the exact
`--email` address.

The executable path above chooses AgentMail, but DearMachine is not coupled to
it. AgentMail, OpenMail, and Sendmux use the same `up --create` seam; only the
adapter credential and inbox selection differ:

| Adapter | Credential file variable | New-inbox selection |
| --- | --- | --- |
| AgentMail | `AGENTMAIL_API_KEY_FILE` | `--new-inbox --transport agentmail` |
| OpenMail | `OPENMAIL_API_KEY_FILE` | `--new-inbox --transport openmail` |
| Sendmux | `SENDMUX_API_KEY_FILE` | `--new-inbox --transport sendmux` |

Each row is a drop-in replacement for the AgentMail row above. Sendmux uses
the Infrastructure key only to create the mailbox and establish pair policy;
DearMachine stores the returned mailbox-scoped credential privately for
receiving and replying. A separate Sending key is not required.

Plain `dearmachine up` starts every registered pair. `dearmachine down` stops
the background client. `dearmachine up --foreground` is reserved for systemd
and container supervision.

To add another pair on the same inbox, first get the inbox address from
`dearmachine status`, then stop and create the pair intentionally:

```bash
dearmachine down
dearmachine up --create \
  --email '<second-email-address>' \
  --inbox '<existing-inbox-address-or-uuid>' \
  --magnifica-humanitas=<true-or-false>
```

Use `--new-inbox --transport <transport>` instead of `--inbox` when the new
pair should get a separate inbox. Both forms restart all registered pairs after
creation.
