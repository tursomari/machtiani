# Native Windows installation

The Windows runtime targets Windows 11 x64 and runs under the signed-in user.
Dear Machine and its workers use ordinary Windows folders visible in File
Explorer. WSL is not required. The release includes Node, Git for Windows
(including Bash and Git LFS), ripgrep, and the native Dear Machine binaries.
Backends and their accounts remain separate, user-owned installations.

## Quick start from source

After cloning the umbrella with `git clone --recurse-submodules` and changing
into it, run this in native x64 PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\quick-start.ps1
```

The bootstrap privately downloads checksum-pinned Node, portable Git (including
Bash and Git LFS), ripgrep, Go, Zig, and pnpm. It copies only clean, tracked
source and exact recursive submodule pins; untracked files and Git
administration never enter the bundle. Commit or restore tracked edits before
building. No global Node, Go, compiler, Nix, Docker, or administrator access is
needed. Downloads and verified builds are reused beneath
`%LOCALAPPDATA%\DearMachineBuild`; builds receive an isolated home and no
inherited provider credentials.
Downloads use Windows 11's system curl with connection and stalled-transfer limits.
If a download fails, rerun Quick start; already verified downloads are retained.

After building and checking the entrypoints, it installs per-user and opens
guided setup in the same terminal using the absolute installed launcher.
Running Quick start again opens that installation, including its existing
recovery controls, without an implicit upgrade. `-Destination` and `-Cache`
accept alternate absolute paths. A failed build does not activate an installation;
retry the same command after correcting the reported problem. Failed build
staging directories remain in the private cache for diagnosis.

The native execution and complete guided-setup verification status is recorded
in the testing results linked below; offline bootstrap checks alone do not
establish a successful Windows installation experience.

## Install a prepared bundle

Extract a trusted Windows bundle, then run its installer from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bundle\source\scripts\install-windows.ps1 -Bundle .\bundle
```

The default destination is `%LOCALAPPDATA%\DearMachine`. `-Destination` accepts
another new absolute directory, including spaces and Unicode. Administrative
rights are unnecessary. `-NoPath` leaves the user's Path setting unchanged;
otherwise reopen the terminal to use `dearmachine` by name.

Run `dearmachine` for guided configuration. Keep workspaces outside the install
folder, for example under Documents. The bundled Bash is a Windows process,
not a Linux environment. Native commands accept quoted `C:\Users\...` paths;
Bash uses `/c/Users/...` paths. Use `cygpath` when converting them.

The current developer workflow prepares bundles with
`scripts/build-windows.ps1`; this repository does not yet publish a Windows
release download channel. A Git-signed source commit is not an Authenticode
signature on a downloaded executable.

## Backends

Use a native Windows installation of the selected backend. The installer
retains existing authentication and asks before a functional provider probe.
Claude Code and OMP user-local binary directories are added to child-process
search paths. Official Codex and Claude npm installations are resolved to
their native payloads; arbitrary `.cmd` wrappers are not executed by the agent
manager. A missing executable, missing authentication, and an unsupported
provider API are separate failures.

Codex needs a Responses-compatible provider. DeepInfra's Chat Completions and
Anthropic-compatible APIs were exercised with the other backends; they do not
establish Codex compatibility. Use the selected backend's own supported
persistent authentication. Credentials typed only into one terminal do not
survive a new sign-in.

## Start, stop, and sign-in startup

```powershell
dearmachine up
dearmachine status --details
dearmachine restart
dearmachine down
dearmachine persistence on
dearmachine persistence off
```

Fresh launches reuse the AgentMail key saved by guided setup at
`~/.config/dearmachine/agentmail-api-key`. The launcher passes that file reference
without reading or exporting its contents. An explicit `AGENTMAIL_API_KEY` or
`AGENTMAIL_API_KEY_FILE` takes precedence.

Persistence is a current-user startup entry pointing to the stable launcher.
It runs after sign-in, including after reboot, and ends on sign-out. It is not
a Windows service. Startup Apps can suppress the entry. Enabling it records
consent and configuration; status cannot prove a reboot occurred. Never change
a user's auto-logon settings to make the client start.

The background supervisor and its workers do not open console windows. Closing
the concierge or its terminal leaves the client running. With Windows OpenSSH,
the supervisor leaves the session job when that job permits explicit breakaway;
ending SSH then leaves it running too. Worker cancellation still stops owned
descendants. A launcher that forbids job breakaway can still end its descendants.

## Update and rollback

```powershell
dearmachine update --check
dearmachine update --bundle C:\Downloads\new-windows-bundle
dearmachine update --recover
```

Updates stage a complete release, check its executable, confirm and stop the
owned client, then atomically replace the current-release pointer. Existing
configuration and persistence choices remain. If the client was running, it
is restarted. Previous releases remain available for rollback, including while
an older concierge session is still open; reopen the concierge after updating.
A refused or incomplete staging operation leaves the active pointer unchanged.
There is no automatic remote release lookup yet; `--check` reports the local
installation and the bundle-update command.

## Uninstall

Run `dearmachine uninstall` in an interactive terminal. It shows owned removal
paths and requires typing `UNINSTALL`; there is no unattended confirmation
bypass. Close other Dear Machine terminals first. Removal stops the owned
client, disables its sign-in entry, removes its Path entry, installed releases,
and Dear Machine private state. External projects, standalone backends, and
remote accounts remain.

Windows holds running executables open. A temporary PowerShell helper waits
for the command and launcher to exit before removing them. Read
`%LOCALAPPDATA%\DearMachine-uninstall.log` for the completed result; scheduling
cleanup alone is not proof of deletion. Redirected removal roots are refused;
links inside owned trees are removed without following their targets.

## Current platform boundaries

The tested target is Windows 11 x64. Windows ARM64 and execution before sign-in
are not supported. AgentMail, OpenMail, and Sendmux are native transport choices.
Sendmux uses Windows SQLite transactions for its durable submission journal.

Development and destructive tests belong only in disposable Windows VMs.
See the [native testing guide](../tests/windows-native/README.md),
[Quick start validation](../tests/quick-start-results-2026-09-21.md), and
[Windows parity results](../tests/windows-native/PARITY-2026-09-21.md) for the
gates, recorded evidence, and remaining validation limits.
