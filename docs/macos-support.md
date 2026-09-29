# macOS portability preview

macOS is under active verification; declaring Darwin flake targets does not
establish end-to-end installation support. Keep Linux release gates passing
while testing macOS in a separate disposable guest or account.

## Installation paths

The macOS wizard offers Nix and Standard. Standard builds directly using
Apple's Command Line Tools and privately downloaded and built dependencies, with
no Docker, Nix or Homebrew requirement. See [Standard installation](standard-installation.md).
Its Intel and Apple Silicon runtime gates must be recorded separately from
the existing Nix evidence below. Intel macOS Nix uses the
installer's separately pinned Nixpkgs 26.05 input because its newer unstable
input has retired Intel macOS. DearMachine's optional Codex package also
uses the stable input on Intel. Apple Silicon retains the main inputs.

Build the native client, harness, and installer on the target architecture.
Follow the component testing entrypoints before running the normal installer.
Do not interpret successful Darwin derivation evaluation or cross-compilation
on Linux as a successful macOS Nix build.

## First Nix installation

Run the initial Nix installation from Terminal in a logged-in macOS desktop.
macOS can require an administration approval dialog even when the command has
already authenticated with sudo. An SSH session cannot present that dialog
and may fail with `vifs: error creating /etc/fstab`.

If this occurs, retry the official Nix installer from the graphical Terminal
and handle its macOS permission prompt. Do not disable System Integrity
Protection to work around this failure. Nix documents the issue in
[NixOS/nix#13723](https://github.com/NixOS/nix/issues/13723).

## Verified Intel Standard coverage

The native Standard builder completed in a macOS Sonoma 14.8.9 Intel guest
using Apple's Command Line Tools, an isolated home, and an initial PATH
containing only system directories. Nix and Homebrew were excluded from the
build environment and runtime library dependencies.

The resulting release passed `tests/macos-standard-smoke.py`: native product
entrypoints, the bundled provider runtime, Node/Python child processes, GNU
tools, a real installer-agent/model-host shell-tool round trip against a local
HTTP model, and a Git LFS clean-filter commit. The existing Node worker-file
regression probe also passed with the pinned official Node binary.

The standalone installer bootstrap built successfully and reached the real
Nix/Standard menu in a terminal with a fresh home and no credentials. Repeating
both full-release and bootstrap acquisition reused the verified releases
without requesting dependency downloads.

A separate credentialed run exercised the host-aware installer in the same
Intel guest with a fresh home, the newly compiled installer, and the existing
native runtime products and dependencies. This reused runtime coverage is
separate from the cold native build above. The real terminal selected Standard,
configured DeepInfra `zai-org/GLM-5.3-Flash` with high reasoning, installed OMP
from its official installer, and passed both OMP and Agent Manager functional
checks. A live OpenMail-to-AgentMail attachment test returned the expected
attachment line in the original email thread. The installer completed, the
configured concierge reopened without model setup, and `/down`, `/up`, and a
final `/down` passed. The supplied source snapshot remained unchanged.

OMP credential integration required operator clarification through the normal
UI; the backend guide now explains how to map the secure helper's returned
variable name. This establishes functional coverage, not a clean unassisted
IXE pass. Always-on startup was declined. These runs do not establish Apple
Silicon execution, provider browser login, published upgrades, or the lifecycle
operations listed below.

## Verified Intel Nix coverage

A normal user in a fully installed macOS Sonoma 14.8.9 Intel guest completed
native Nix builds and the coordinated installation of DearMachine, Machtiani,
and the installer. This is separate from the earlier recovery-guest checks.
DearMachine's native Nix checks passed. The installer typecheck and all 489
maintained tests passed, including the optional integrations using the built
DearMachine and Machtiani binaries (the last two integrations ran separately).
Linux component checks and builds also passed.

Live OpenRouter calls with GLM 5.3 Flash at high reasoning passed for all four
Machtiani model roles. Agent Manager's functional Forge health probe created
and verified its requested file. The installed release's update check returned
current against its isolated source origin. This does not test a published
upgrade or provider/backend browser login.

The complete mail scenario, resumed configured setup, and configured-client
stop/start remain pending. The mail test could not finish while the account's
remaining inbox capacity was occupied by another test. All inboxes created by
this macOS test were removed, and baseline preservation was verified.

The test run caught and fixed an affected Intel Node worker runtime, Darwin
package-cache hashes, long temporary socket paths in tests, and non-atomic
Agent Manager metadata writes. The metadata regression also reproduced on
Linux before the fix. The Darwin compile gate still passes for both Intel
and Apple Silicon with SQLite enabled. Apple Silicon dependency-cache
prefetching is not an Apple Silicon execution test.

## Current lifecycle limits

The Darwin supervisor uses a private process group for ordinary shutdown.
Linux parent-death signalling remains Linux-specific; abrupt supervisor death
on macOS does not automatically terminate the direct child. A per-user LaunchAgent now supports service management and optional automatic
startup at login. Use `dearmachine launchd on` for service use, then separately
`dearmachine persistence on` for login startup. Stop the current client with
`dearmachine down` before an approved ownership switch, then start it with
`dearmachine up`. Inspect `dearmachine persistence status`; disabling persistence
preserves the currently running client. The concierge exposes `/launchd` on
macOS and explains these choices without Linux service commands.

This agent starts after login, including the next login after reboot. It does
not provide operation after logout or before login. Native Intel verification
uses the real launchd manager and candidate supervisor with an offline child:
startup, singleton ownership, restart, explicit stop, login-plist reload, and
exact cleanup. Reloading the plist simulates the launch boundary; it is not an
actual logout/reboot or credentialed email test. See the maintained
[launchd lifecycle test](../dearmachine/TESTING.md#macos-portability-checks).

Confirmed native macOS uninstall remains unimplemented. Do not offer systemd
setup on macOS or present Linux cleanup instructions as macOS uninstall
instructions.

## Native installation experience evaluation

Use the [macOS IXE adapter](../tests/e2e-installation-experience/macos.md) to
prepare a private home in an existing SSH-accessible Mac/VM, drive the real
installer and concierge, collect verification/evidence, and clean up that run.
Its default mode includes native acquisition; its explicitly labeled cached
mode reuses compatible binaries with refreshed source and guidance. Keep the
adapter's terminal/cleanup checks separate from a complete credentialed IXE
and from the Intel functional installation evidence above.

## Verification levels

1. Run the installer typecheck, maintained tests, and Nix runtime build, plus
   DearMachine's Nix checks, on the build host to catch Linux regressions.
2. Use [DearMachine's Darwin compile gate](../dearmachine/TESTING.md#macos-portability-checks)
   to compile the real SQLite-enabled commands and all tests for Intel and
   Apple Silicon. This gate does not execute macOS code.
3. Run the corresponding binaries and tests inside macOS. A recovery guest can
   check kernel, process, terminal, and SQLite behavior but lacks a normal user
   session and developer tools. Record recovery/root results separately.
4. On a fully installed Mac, test as an ordinary user: native Nix builds, fresh
   installation, provider/backend browser login, email from the paired sender,
   stop/start, resumed setup, updates, and the documented lifecycle limits.
   A Linux container, including one hosted on a Mac, cannot establish these.

Copy only source snapshots and test/build artifacts into the guest. Keep host
Git administration, home directories, credentials, and agent sockets outside
it. Use temporary model/mail credentials only for separately authorized live
checks. Keep VM disks, firmware, operating-system images, host paths, keys,
passwords, and private test evidence outside version control.

Intel guest results do not establish Apple Silicon runtime support. Do not
promote the preview to supported status until the applicable ordinary-user
installation and live verification gates pass.

The [Mac IXE runner](../tests/e2e-installation-experience/macos.md#nix-on-macos) also accepts `--method nix`: it uses preinstalled Nix on macOS, prepares the pinned bootstrap, and leaves product configuration for the real Nix/Standard wizard. This does not provision NixOS or establish a completed credentialed Nix IXE.
