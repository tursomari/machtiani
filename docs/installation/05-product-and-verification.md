# Stage 5: product installation and verification

The permanent contract in `INSTALL.md` remains in force. Provider, email,
sender, and selected healthy backend must already be established.

## Goal

Install Machtiani and Dear Machine, configure only the selected backend, start
the native client, and prove the intended installation works.

For `installation.method = container`, read all of
`docs/container-build-installation.md` now. Acquisition is already complete;
use its supplied runtime and shared configuration rules.

For `installation.method = standard`, read all of
`docs/standard-installation.md` now. It specifies which shared configuration
sections of `docs/installation-procedure.md` to use with the supplied products.
Do not run that procedure's Nix acquisition or clone steps for Standard.
For the Nix method: Read `docs/managed-nix-installation.md` for coordinated
software acquisition, source retention, and updates. Execute the exact argv
array in runtime context's `installation.acquisitionCommand`; it invokes this
installer's coordinated `install --source-root` command without assuming an
installer alias is already on PATH. It installs all five
public commands together; do not run the separate component installers or
`nix profile install` over their managed launchers. Then use the shared model,
backend, pairing, and verification sections of `docs/installation-procedure.md`,
skipping its clone and individual software acquisition steps. For the shared
model-host command, use `$HOME/.local/bin/machtiani-model-host` so updates keep
the selected model profile while advancing the runtime. During the initial
`dearmachine up --create`, also pass `--agent-bin "$HOME/.local/bin/machtiani"`
and `--agent-manager "$HOME/.local/bin/agent-manager"`. These stable paths keep
the client on its managed dependencies when it later starts through systemd.

Before the first installation command, send only the canonical product
installation message from `INSTALL.md` as a nonterminal progress update. This
is not a permission question and no human reply is expected. Do not end your
turn after sending it. Immediately make the first installation tool call in
the same turn and continue autonomously until a documented human-only gate or
completion.

Install the pinned `machtiani-model-host` alongside Machtiani for Nix; for
Container build or Standard verify and use `installation.distribution.binaries.modelHost`.
Configure
Machtiani's `model-host` transport with the launcher's private shared profile
path and the exact model and reasoning level already selected. Do not source or
translate its credential, substitute a catalogue default, or ask the human to
choose again. Perform the model host's small live provider check before
installing or configuring Dear Machine.

If this check uses `machtiani run`, perform it in a disposable repository with
at least one commit and a completed `machtiani sync` at its current HEAD, as
required by the canonical procedure. An empty or unsynced repository fails
before provider inference. Do not initialize or modify the umbrella source
checkout just to satisfy that check.

Create each new probe in a uniquely named temporary directory. Do not prepare
it by deleting or emptying a fixed path under the user's home. Clean up only
the exact temporary directory created by this attempt.

For a fresh disposable Git repository, a Git commit alone does not register
the project with Machtiani. After creating its harmless README and first
commit, run these commands inside that disposable repository, in order:

```bash
machtiani init --no-interactive
machtiani sync
printf 'c\n' | machtiani run --mode code -p 'Read README.md and respond with exactly: provider-ready'
```

This initialization is for the disposable provider check, not a separate
`dearmachine init` or a modification to the supplied product source. Reuse a
successfully initialized and synced probe rather than repeating that work.

Keep probe-only Git identity and environment overrides inside the disposable
repository and its probe process. Set repository-local `user`, `author`, and
`committer` names to `machtiani` and their email fields to explicitly empty
values. Disable commit signing only in that disposable repository. Never change
global Git settings or use the human's personal or authorized-sender email for
Git history.
Do not carry probe-only Git environment overrides into Dear Machine startup.

Dear Machine initializes its new workspace with the preset local Git identity
`machtiani` and an empty email address. Bootstrap and later workspace commits
use that identity without requiring the user's Git configuration or signing key.
Do not ask for a Git name, email address, account, or signing setup, and do not
require `git var GIT_AUTHOR_IDENT` to succeed outside the workspace before
`dearmachine up --create --resume`. The native bootstrap owns this configuration,
including resumed setup. Leave existing repositories and global Git settings
unchanged. Git history is an internal implementation detail, not a setup choice.

For a built-in backend, configure the selected private backend ID through the
documented built-in setup. For a custom backend, use the configuration already
created and verified in Stage 4; do not run the built-in-only
`dearmachine setup-agents` flow afterward. Do not narrate internal differences
between those paths to the human.

## Verification

The installer adds its release commands to its own PATH. A child shell, even
a login shell, can inherit that PATH; `command -v` there does not prove that a
new terminal or SSH session can find the commands. Verify the stable installed
launcher directly and include its exact absolute path in the completion report.
On Unix Standard installs, use `$HOME/.local/bin/dearmachine` to reopen the
concierge without relying on PATH. Do not use a temporary bootstrap or
version-specific release path as the reopening command. Installation automatically
configures the supported user shell's PATH, preserving existing settings and
backing up startup files before modification. Verify from a fresh terminal
environment without the installer's injected PATH that `dearmachine` resolves
to the installed launcher. An already-open parent shell needs the printed
environment command or a new login shell. If automatic shell setup reports an
error, repair it with `~/.local/bin/machtiani-installer configure-shell` and
verify again; do not report plain `dearmachine` as ready solely from the
installer's environment.

Agent Manager's standalone CLI requires the installed backend selection in
`DEARMACHINE_BACKENDS`. Read the `backends` array from
`$HOME/.dearmachine/config/dearmachine.toml` and encode it as a JSON array for
`agent-manager backend list` and `agent-manager backend health <backend-id>`.
Do not infer the configured selection from the agents detected on `PATH`.
Run the Agent Manager health check inside a disposable Git repository, not
the supplied source snapshot or Dear Machine's state-and-memory workspace.
The probe may create a file in its working directory. Keep that work scoped
to the disposable repository and clean only that repository afterward.
After deriving `selected_backends_json` and `selected_backend_id` from the
actual non-secret configuration, keep the selection on both commands:

```bash
DEARMACHINE_BACKENDS="$selected_backends_json" agent-manager backend list
DEARMACHINE_BACKENDS="$selected_backends_json" agent-manager backend health "$selected_backend_id"
```

Check these prerequisites before the first probe, not just after a failure:
the Machtiani probe is initialized, committed, and synced; Agent Manager has
the complete backend selection and a disposable working directory. Follow the
installed subcommand's help for optional flags instead of guessing them.

Status separates crash recovery, logout survival, and managed startup at login
and after reboot. `Cannot verify` for startup (or `Persistence: unknown` in older
versions) is not a failed installation or permission to change supervision.
Preserve the stated reason and scope in the report. Startup configuration is
separate from whether the pairing database or workspace has been saved; do not
inspect databases to explain a service-status field. Saved permission to configure
a service is not evidence of its actual configuration. Crash recovery can be
active under the native supervisor without systemd.
Do not guess additional status flags or try to repair persistence here; the
optional always-on stage handles service availability after the live email.

Maintain a private checklist. Preserve unrelated user configuration and keep
credential files private. If a command fails, inspect the failure, repair safe
in-scope causes, and retry; involve the human only when their authority or an
external action is required.

During the normal installation, let `dearmachine up --create` own initialization
of the default state-and-memory workspace. Do not split that path by running
`dearmachine init` separately. If workspace initialization fails, do not delete
Dear Machine's internal bootstrap marker to force progress; preserve the
evidence and diagnose the underlying failure.

Always pass `--magnifica-humanitas=true` to `dearmachine up --create --resume`
when the human explicitly chose quotes in Stage 3, and
`--magnifica-humanitas=false` otherwise. Never omit it: an omitted flag keeps the
value an earlier installation recorded. Never enable it on your own or from the
launcher's defaults.

Run `dearmachine up --create --resume` as a supervised background operation.
It performs durable model-backed synchronization and may pause its output for
several minutes. Do not wrap it in a short timeout, do not kill it merely
because output pauses, and do not start a second copy while the first remains
alive. Monitor the same job to completion and translate its phase messages into
short ordinary-language progress updates.

If inbox provisioning fails, keep helping in this session. If the human
chooses another email service, revisit the email guide for that service and
invoke its typed credential helper. Resume the native creation command with
the newly selected `--transport`; retain the sender, workspace, backend, and
model choices. Native recovery permits this before an inbox is recorded.
Do not describe a failed provider as an irreversible setup choice, delete
the transaction journal, or ask the human to abandon installation merely
because the first provider failed. If native recovery reports an existing
inbox or pairing, inspect and preserve that state before proposing recovery.

Before declaring success, verify at least that:

- the Machtiani, Dear Machine, Agent Manager, and selected backend commands are
  available in a new shell environment;
- Machtiani has a valid provider configuration containing a credential
  reference rather than a literal secret;
- Dear Machine has the intended backend, response tier, transport, inbox, and
  exact authorized sender;
- the selected backend passes the installed Agent Manager health check;
- the Dear Machine client is running and `dearmachine status` is healthy; and
- the source checkout and its submodules contain no installation-generated
  tracked changes or credentials.

If a safe end-to-end email check requires the human, show only the canonical
test-email message from `INSTALL.md`, including both the exact authorized sender
address to send from and the machine inbox address to send to. Reuse the current
confirmed pairing, including any sender or inbox changes made during setup;
do not substitute an earlier address or ask again when both are already known.
If either address is missing, ambiguous, or inconsistent with the active
non-secret pairing configuration, resolve that before giving the instruction.
Never guess an address. Wait for the human to say they sent it.
After they do, read all of `docs/installation/live-email-progress.md` and
follow it until the message reaches a terminal result or a concrete blocker.
Do not make the human repeatedly ask whether the message is moving. Otherwise
perform every available check yourself.

After the live reply succeeds, do not issue the completion report yet. The
live-email guide routes to the final optional always-on stage. End with the
completion report required by `INSTALL.md` only after that stage finishes.
