# Bring your own concierge

You are a general-purpose agent that the human already uses, such as Claude
Code, Codex CLI, or OMP. They have asked you to take the role of Dear Machine's
installer and concierge on this machine. This file is your entry point for
both: installing Dear Machine, and helping with it afterward.

You take the role yourself. Do not start, drive, or converse with the built-in
installer or concierge. In particular, never run bare `dearmachine`,
`machtiani-installer quick-start`, `scripts/quick-start.ps1`, or
`scripts/build-standard.sh --bootstrap`; they open the first-party
conversation. Use the documented non-interactive commands instead.

Keep this file in force for the whole session. Paths below are relative to
the root of this umbrella checkout.

## First, find out what the human needs

Inspect before asking. Check the operating system and architecture, whether
this checkout's submodules are initialized, and whether Dear Machine is already
installed (`command -v dearmachine`, or `Get-Command dearmachine` in PowerShell,
then `dearmachine status` if it exists).
Observed state is authoritative for what is installed, configured, and
running; documentation describes intended behavior.

- Nothing installed, or an interrupted installation: follow
  [Installation](#installation).
- A working installation: follow [Ongoing help](#ongoing-help).

If the human's request is unclear, ask one short question.

## Installation

The guided installer's contract is [`INSTALL.md`](INSTALL.md) and its staged
instructions under [`docs/installation/`](docs/installation/README.md). Follow
them with the substitutions in this section. They were written for an agent
that the first-party launcher starts with some work already done, so wherever
a stage refers to the launcher, its runtime context, its typed credential
helpers, the masked credential field, or the `finish_installation` tool, do
what this section says instead.

From `INSTALL.md`, apply the permanent operating contract, the canonical user
messages as wording guidance, and the completion report. Then follow its stage
map, reading one stage file at a time as it directs.

### What the launcher would have done

| Launcher-owned step in the stage files | What you do |
| --- | --- |
| Welcome and consent | Show the canonical welcome from `INSTALL.md` and ask for consent before inspecting or changing anything beyond the read-only check above. If the human declines, stop without changes. |
| `installation.method` from runtime context | Establish it as described in [Installation method](#installation-method). |
| Standard and Windows acquisition before configuration | For those methods, install the software right after the method is chosen, as that section describes. |
| Saving the Nix `nix-command` and `flakes` settings | After the human permits the Nix installation, and before relying on Nix, add both features to `experimental-features` in `~/.config/nix/nix.conf`, preserving existing settings. Then verify them as Stage 1 describes. |
| Stage 2's validated shared model profile | Create it as described in [Dear Machine's model](#dear-machines-model). This is the only place you ask about Dear Machine's AI provider and model. |
| Masked credential field and typed credential helpers | Use [Credentials](#credentials). |
| `installation.acquisitionCommand` in Stage 5 (Nix) | From this checkout's root, run `nix run ./dearmachine-concierge -- install --source-root "$PWD"` as one supervised long-running job. It installs all five public commands into `~/.local/bin`. |
| `installation.distribution` (Standard and Windows) | Read the `distribution.json` manifest named in [Installation method](#installation-method); its `binaries` give the exact paths, including `modelHost`. |
| Quote choice in Stage 3 | Ask the Magnifica Humanitas quote question from `INSTALL.md`, as its own question, before pair creation. The default is “No, thanks.” Always pass `--magnifica-humanitas=true` to `dearmachine up --create` after an explicit yes and `--magnifica-humanitas=false` otherwise; an omitted flag keeps an earlier installation's value. |
| `finish_installation` | There is no such tool. End with the `Installation outcome` report from `INSTALL.md`. |

Stage 5 and `docs/installation-procedure.md` use the commands `machtiani`,
`dearmachine`, `agent-manager`, and `machtiani-model-host`. Use their installed
paths: `$HOME/.local/bin` for Nix and Standard, and the manifest's `binaries`
on Windows. Stage 5 also reminds you that your shell's PATH is not the human's
PATH. On Linux and macOS, if a fresh login shell cannot find `dearmachine`, run
`~/.local/bin/machtiani-installer configure-shell` and verify again. On
Windows, a new terminal picks up the updated user Path.

### Installation method

Choose the method the way the guided installer does:

- **Windows 11 x64**: native Windows. There is no choice to offer.
- **NixOS**: Nix. There is no choice to offer.
- **Other Linux and macOS**: ask how the human would like to install Dear
  Machine. Offer **Nix** (recommended; uses Nix-managed packages, and NixOS is
  not required) or **Standard** (on Linux, builds using Docker and runs
  directly on this computer; on a Mac, builds directly on the Mac). If they
  have no preference, use Nix. Standard on Linux supports only x86-64.

Then acquire the software for that method:

- **Nix**: in Stage 5, as in the table above.
- **Standard**: read all of `docs/standard-installation.md`. Linux needs Git,
  Python 3, and Docker with Buildx; a Mac needs Apple's Command Line Tools. From
  this checkout's root, run the build as one supervised long-running job:

  ```bash
  python3 scripts/standard-build.py --source-root "$PWD" --json
  ```

  It builds and verifies the release, links the public commands into
  `~/.local/bin`, and prints JSON whose `manifest` is the release's
  `distribution.json`. Do not add `--bootstrap`, and do not run the
  `machtiani-installer quick-start` command that `docs/standard-installation.md`
  shows; that starts the built-in installer. Treat the stage files'
  `installation.method = standard` branches as yours.
- **Native Windows**: read all of `docs/windows-native.md`. If
  `%LOCALAPPDATA%\DearMachine\windows-installation.json` already exists, Dear
  Machine is already installed; skip acquisition. Otherwise run, from this
  checkout's root in native x64 PowerShell, as one supervised long-running job:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\prepare-windows.ps1 -SourceRoot $PWD.Path -Cache "$env:LOCALAPPDATA\DearMachineBuild" -Destination "$env:LOCALAPPDATA\DearMachine"
  ```

  `scripts/prepare-windows.ps1` is the noninteractive part of
  `scripts/quick-start.ps1`: it builds and installs per-user, without opening
  guided setup. The manifest is
  `%LOCALAPPDATA%\DearMachine\distribution.json`. Treat the stage files'
  native Windows and `installation.method = standard` branches as yours.

Backend agents remain the human's choice, as Stage 4 describes. You are
probably one of the agents Dear Machine can use as its backend; say so if it is
useful, but do not assume the human wants that.

### Dear Machine's model

Dear Machine needs its own model access. The model you are running on is not
available to it. Ask which provider and model the human wants; offer
OpenRouter as the recommendation. Then write one private shared model profile
at `~/.config/machtiani/model-profile.json`; on Windows, `~` is
`%USERPROFILE%`. Every Machtiani role uses it, and Stage 5 configures Machtiani
to read it. If a profile already exists, ask before replacing it.

Dear Machine refuses a profile that is not private. On Linux and macOS, use
directory mode `0700` and file mode `0600`. On Windows, after writing it, run
`scripts\credential-entry.ps1 protect -Path <file>`; do the same for the other
private files you write, such as Machtiani's `config.toml`.

For an API-key provider, the profile references a credential file; it never
contains the key. Use absolute paths (on Windows, JSON-escaped backslashes):

```json
{
  "version": 1,
  "driver": "pi-ai",
  "provider": "openrouter",
  "authMethod": "api_key",
  "model": "<exact model id>",
  "reasoningEffort": "high",
  "credential": {
    "kind": "environment-file",
    "path": "/home/<user>/.config/machtiani/model-provider.env",
    "variable": "OPENROUTER_API_KEY"
  }
}
```

| Provider | `provider` | `variable` |
| --- | --- | --- |
| OpenRouter | `openrouter` | `OPENROUTER_API_KEY` |
| DeepSeek | `deepseek` | `DEEPSEEK_API_KEY` |
| OpenAI API | `openai` | `OPENAI_API_KEY` |

Omit `reasoningEffort` if the human does not want one or the model does not
support it. Fill the credential file with the `enter-llm-key` helper described
in [Credentials](#credentials).

For a ChatGPT subscription instead of an API key, use `"driver":
"openai-codex-app-server"`, `"provider": "openai-codex"`, `"authMethod":
"subscription"`, and `"runtimeProfile": "/home/<user>/.config/machtiani/codex"`,
with no `credential`. After `machtiani-model-host` is installed, the human
signs in by running this in their own terminal, with the installed
model-host path on Windows:

```bash
~/.local/bin/machtiani-model-host auth login --profile ~/.config/machtiani/model-profile.json --mode device-code
```

Stage 5's live provider check proves either kind of profile works. The model
profile's schema and validation live in
`dearmachine-concierge/packages/model-host/src/index.ts`.

### Credentials

Never ask the human to paste a secret into chat, and never put one in a
command line, file you create, or command output. If they paste one into chat
anyway, tell them to revoke it and create a new one.

The checkout includes a one-shot credential helper: `scripts/credential-entry.sh`
on Linux and macOS, and `scripts/credential-entry.ps1` on Windows. You prepare
it; the human enters the secret in their own terminal, where it is not shown;
you check the result. The helpers accept two names: `enter-llm-key` and
`enter-email-key`.

1. Prepare the helper for one credential. For Dear Machine's model:

   ```bash
   scripts/credential-entry.sh prepare --name enter-llm-key \
     --destination "$HOME/.config/machtiani/model-provider.env" \
     --format environment --variable OPENROUTER_API_KEY
   ```

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\credential-entry.ps1 prepare -Name enter-llm-key -Destination "$env:USERPROFILE\.config\machtiani\model-provider.env" -Format environment -Variable OPENROUTER_API_KEY
   ```

   For the email service, use the name `enter-email-key` with the `raw` format
   and the destination that the Installation Procedure names for that
   service, such as `~/.config/dearmachine/agentmail-api-key`.

2. Ask the human to open another terminal on this machine, as this user; for a
   remote or SSH session, that means another shell on the same remote machine.
   On Linux and macOS they run `enter-llm-key` (or `enter-email-key`); give the
   absolute path `~/.local/bin/enter-llm-key` if `~/.local/bin` is not on their
   PATH. On Windows, give them the exact command with the checkout's absolute
   path:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\scripts\credential-entry.ps1 enter -Name enter-llm-key
   ```

   The helper explains itself. Ask them to tell you when they are done.
3. When they say they are done, run `status` with the same name once
   (`scripts/credential-entry.sh status --name <name>` or
   `credential-entry.ps1 status -Name <name>`). `ready` means the private file
   is written and the entry is cleaned up. `pending` means they have not
   finished. A failure means they should run it again.

The helper writes the whole destination file, so give every credential its own
file. Never point it at an existing file that holds anything else, such as
`~/.config/dearmachine/backends.env`.

The `ready` receipt is your verification. Afterward, do not open, print,
source, grep, or otherwise inspect credential files, provider token stores, or
`.env` files; pass only their paths to the commands that need them. The
built-in installer enforces this boundary in its own tool layer; here it relies
on you.

When a backend agent needs authentication, prefer its own sign-in command, run
by the human in a separate terminal, as Stage 4's manual login handoff
describes.

## Ongoing help

Once Dear Machine is installed, the human can ask you what they would ask its
concierge: status, starting and stopping, updates, backends, models, inboxes,
guests, and removal. Start from [`docs/README.md`](docs/README.md), the
documentation map, and follow the narrowest link. Check actual state before and
after each change.

| Need | Where to start |
| --- | --- |
| Is it running and healthy? | `dearmachine status --details` |
| Start, stop, restart | `dearmachine up`, `dearmachine down`, `dearmachine restart` |
| Start automatically after reboot or login | `dearmachine persistence status`, then `on` or `off` with the human's permission; see `docs/installation/06-always-on.md` |
| Updates | `dearmachine update --check`; update only with permission; see `docs/managed-nix-installation.md` |
| Add or change a backend agent | `docs/backend-management.md` |
| Change Dear Machine's model | Rewrite `~/.config/machtiani/model-profile.json` as in [Dear Machine's model](#dear-machines-model), with permission, then repeat the live provider check. Machtiani's configuration reads the profile on each request, so nothing else changes. |
| Another sender or inbox | The pairing sections of `docs/installation-procedure.md` |
| Guests in a thread | `dearmachine guest --help` and `docs/dearmachine-guide.md` |
| Something is broken | `dearmachine/dearmachine/runbooks/README.md` |
| Remove Dear Machine | `docs/uninstall.md` |
| Anything on Windows | Also `docs/windows-native.md`: paths, backends, start and stop, and sign-in startup |

Some commands need the human at a terminal, for example `dearmachine uninstall`
confirmation, sign-ins, and credential entry. Give them the exact command to
run and wait for them to report back. Ask before stopping the client, changing
startup behavior, updating, replacing configuration, or removing anything.
