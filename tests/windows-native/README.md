# Native Windows development gates

See [Windows parity validation](PARITY-2026-09-21.md) for background consoles,
SSH detachment, Sendmux journal recovery and the current guided-installation status.
See [20 September validation results](RESULTS-2026-09-20.md) for the observed gates and remaining release boundaries.
See [guided-installation regressions](OMP-CREDENTIALS-2026-09-21.md) for the live
OMP, credential, configuration and concierge findings and their native gates.
See [uninstall and fresh-setup results](UNINSTALL-2026-09-21.md) for generated
profile junction removal and reinstall beside preserved independent projects.
See [build-path regression results](BUILD-PATHS-2026-09-21.md) for the native
Codex path-limit reproduction and default-layout Quick start verification.
See [activity validation](ACTIVITY-2026-09-21.md) for the concierge glyph
animation, output handling, cancellation and full native Quick start proof.
The [Quick start validation](../quick-start-results-2026-09-21.md) additionally
records native dependency acquisition, compilation, terminal handoff and reuse.

Run `node tests/windows-native/codex-paths.cjs <installer-runtime>` with the
pinned native Windows Node and an already-downloaded installer runtime. It
verifies the actual Codex launcher at a short path, reproduces Windows process
launch failure at an overlong path, checks the specific diagnostic, and verifies
relocation restores launch without downloading or signing in. Build staging
must not append another identifier to the content-addressed cache bundle name.

Run these fixtures only in a disposable Windows 11 x64 VM named `DM-WIN-TEST`.
They create a test pairing and private configuration in the current user's home.
Install and run the application as an ordinary Windows user. Administrative
access is only for VM provisioning, the loopback mail fixture's certificate and
DNS setup, and rebooting the guest.

## Native primitives

Cross-compile `dearmachine` and `agent-manager` from `dearmachine/dearmachine`
with CGO and a Windows C compiler. Compile `machtiani` from
`machtiani-harness/agent`. Compile these Go test executables for Windows:

| Output | Module | Package |
| --- | --- | --- |
| `hostos.test.exe` | DearMachine | `./internal/hostos` |
| `entrypoint.test.exe` | DearMachine | `./internal/entrypoint` |
| `supervisor.test.exe` | DearMachine | `./internal/supervisor` |
| `client.test.exe` | DearMachine, CGO enabled | `./internal/client` |
| `agentmanager.test.exe` | DearMachine, CGO enabled | `./internal/agentmanager` |
| `shellenv.test.exe` | Machtiani Harness | `./internal/shell-agent/internal/environments` |

Transfer source snapshots, binaries, and test inputs into the guest. Do not
expose development Git administration, host homes, or agent sockets. Inside the
guest, run:

```powershell
.\tests\windows-native\primitives.ps1 -Products C:\proof\bin -GitDirectory C:\proof\git
```

These cases cover embedded workspace extraction (including hidden files and
nested directories in paths with spaces and Unicode), private ACLs, file sharing and locks, SQLite, supervisor
readiness/recovery, shell quoting and Unicode paths, and descendant cancellation.
The worker handoff regression verifies that an asynchronous worker survives its
temporary shell while remaining owned by the enclosing client job. The console
regression requires no console window at every generation, including an ordinary
grandchild. The supervisor regression closes a launcher job with Windows
OpenSSH's kill-on-close and explicit-breakaway flags and verifies survival.
This is not a claim that every historical Unix-oriented Go test runs on Windows.

Run the installer's `tests/windows-console.mjs` against the relocated installer
runtime with native Node and Git Bash on PATH. Its loopback model launches
PowerShell through the real installer and concierge agents and checks that tool
output remains captured without a console handle. This catches native progress
output that would otherwise paint over the conversation.

The client gate includes Sendmux recovery after lost responses, stale reads,
concurrent sends, and forced writer termination. It checks private Windows ACLs,
legacy journal migration, and rejection of corrupt or changed-envelope state.
It repeats concurrent first-use journal creation 50 times. These process-level
checks do not establish physical power-loss behavior or live delivery.

For abrupt VM termination, use the opt-in two-phase
`TestWindowsSendmuxPowerCycleFixture` documented in
[DearMachine's testing guide](../../dearmachine/TESTING.md#native-windows-development-proof).
Run it in its own disposable VM, then verify the same disk after terminating
and restarting only that VM's hypervisor. Keep the human IXE running elsewhere.

## Build and lifecycle

Run `node tests/windows-native/activity.mjs <fixture-runtime> <source-root>`
with the pinned Windows Node. It verifies the Quick start activity animation
during quiet work, readable stdout/stderr under load, plain redirected output,
quoted Unicode paths, failure propagation, Ctrl+C descendant cancellation, and
clean terminal handoff. The fixture runtime supplies only Node and node-pty;
no build, provider, credentials, or installed configuration is needed.

The Windows launcher must preserve Machtiani's configuration selection. Compile
its native regression from the umbrella root with `GOOS=windows go test -c -o
launcher.test.exe scripts/windows-launcher.go scripts/windows-launcher_test.go`.
In the guest, set `IXE_TEST_WINDOWS_LAUNCHER` to the compiled production launcher
and run `launcher.test.exe '-test.v'`. It creates a disposable release and product
fixture, checking both stable and release-local entrypoints with no selector,
an explicit global config, and an explicit DearMachine config. It also checks
saved AgentMail credential-file discovery and explicit file/value precedence
using counterfeit credentials; key values are never returned by the fixture. No provider,
credentials, installed configuration, or running service is used.

For the Windows Quick start, begin with a clean recursive checkout in the guest
and no installation or DearMachine configuration. Run the ConPTY acquisition
gate with a previously prepared runtime supplying only the test driver's Node
and node-pty:

```powershell
& "$fixtureRuntime\node\node.exe" .\tests\windows-native\quick-start.mjs $fixtureRuntime $PWD $cache $destination $evidence
```

Use absolute paths for the runtime, cache, destination, and evidence. Include
spaces and Unicode in the destination. The driver starts the documented
PowerShell command with only Windows on PATH, observes dependency acquisition,
native compilation, installation, consent and model selection, then exits before
credentials or configuration. Run it again with a new evidence directory and
`repeat` as the final argument to verify the installed launcher is reused.
The fixture runtime is test instrumentation; it is not a bootstrap dependency.

Run `scripts/build-windows.ps1` with pinned Windows Node, portable Git, and
ripgrep directories, cross-compiled products, and `windows-launcher.exe`.
Source archives must include `bootstrap-source-revisions.json`. Use a fresh
ordinary-user profile without Node or Git on PATH to detect ambient dependencies.

`lifecycle.ps1` installs in a path with spaces and Unicode, updates, rolls back,
rejects a broken bundle without changing the active release, toggles sign-in
startup, and cancels a terminal uninstall. `activation-recovery.ps1` uses the
VM-only `fail-activation.go` executable to check that a release which passes
preflight but fails startup restores the previous release and running client.
It requires a configured client and the empty mailbox fixture below.

`removal.ps1` confirms uninstall through ConPTY and waits for actual asynchronous
removal. It first cancels with a generated-profile junction present, then verifies
that private application state is removed and the external junction target and
its file survive. Preserve separately installed backend executables.
Keep the controlling SSH session open until asynchronous cleanup completes:
the temporary PowerShell removal helper is still owned by that session.

`reinstall.ps1` extends removal to a full uninstall/reinstall/uninstall cycle.
It preserves an independent Machtiani project store, observes the real fresh
setup consent in ConPTY, declines setup without credentials, and waits for final
cleanup. Preserved `.machtiani` data must not be mistaken for a partial Windows
DearMachine installation; actual `.dearmachine` partial state still requires
recovery.

The filesystem gate also checks bundle capacity preflight, including allocation
rounding, long paths and junction exclusion, without filling the guest disk.

Run `node --test tests/windows-native/filesystem.cjs` with the pinned native
Windows Node. This credential-free gate checks generated package junctions,
dangling and cyclic child junctions, long Unicode paths, and refusal of redirected
roots and ancestors for both preflight and removal. Child links must be unlinked
without inspecting or deleting their targets. An empty installation that never
started guided setup cannot establish removal of generated DSH profile state.

Run the installer credential adapter and bridge Windows tests, native npm backend
payload/argument tests, and `tests/standard-agent-smoke.mjs` against the installed
runtime. The smoke test uses a loopback model and sends no provider requests.

After building the installer test workspace with its pinned Node and pnpm, run
the credential regressions as the ordinary Windows user:

```powershell
pnpm exec vitest run packages/credential-adapter/tests/windows.spec.ts packages/credential-adapter/tests/omp.spec.ts packages/app/tests/credential-bridge-windows.spec.ts packages/app/tests/credential-omp.spec.ts
```

These use counterfeit keys in disposable homes. They reproduce the insufficient
permissions of a copied OMP `.env` after `chmod`, verify the trusted `--omp`
helper's native ACLs and transcript-free bridge response, and check replacement,
preservation of unrelated entries, and refusal of unsafe existing files. A live
OMP response alone does not establish credential-file privacy.

Also run `packages/app/tests/concierge-control-windows.spec.ts` and
`packages/app/tests/concierge-native-windows.spec.ts`. Set
`IXE_TEST_DEARMACHINE_NATIVE` to the built native `dearmachine.exe` for the latter;
it queries an isolated fresh home without a supervisor. These gates distinguish
the account's Windows named pipe from another owner's endpoint and verify native
status/bootstrap routing. Linux socket-only fixtures cannot establish this.

## Signed mail and Windows file task

`prepare-fixture.mjs <release> omp` creates the test pairing, configuration, and
`Documents/Dear Machine proof Ω/expenses.csv`. Initialize Git and commit the CSV,
then initialize the project with installed Machtiani. Configure the explicitly
authorized DeepInfra GLM-5.3 model with high reasoning for Machtiani and OMP.
Credentials belong in protected guest files; never put them in command arguments,
transcripts, source archives, or Git.

Build `mail-task-fixture/main.go` from the DearMachine Go module. It serves a
signed message and captures replies on guest loopback; it cannot send external
mail. Run it with an evidence directory and a UTF-8 task file requesting an OMP
summary of `expenses.csv` into `windows summary.txt`. It writes a temporary CA
certificate and serves DKIM DNS on loopback. Trust only that certificate in the
disposable guest, point guest DNS at the fixture, and clear the DNS cache.
Set `AGENTMAIL_BASE_URL=http://127.0.0.1:58749` and a dummy fixture API key file.

Start the installed client, then create `deliver` in the fixture evidence
directory. Wait for the captured reply and verify the actual Windows file:
travel 20.00, food 13.00, grand total 33.00, and an unchanged input CSV. Check
that the Agent Manager ticket actually started and completed. Remove `deliver`
and stop the client before other lifecycle tests.

## Reboot and cleanup

`mailbox-fixture.mjs <evidence-directory>` serves an empty inbox on loopback
58749 with read-only permission metadata. It rejects writes and cannot send mail.
Arrange its startup separately from the application's startup entry. Restore
normal guest DNS and remove the signed-mail fixture CA before rebooting.

Enable the application's real `persistence on`, reboot, and verify the daemon
and fixture polling after the ordinary user signs in. Query from a new session
and exercise restart/down. Test closing a desktop terminal and ending an SSH
session separately; neither establishes sign-in startup. The sign-in startup
entry must launch the reboot test's client.
Disable persistence, remove fixture startup and environment settings, and remove
all temporary provider credentials. Preserve output files and non-secret evidence.

## Distribution limits

The Quick start builds a private Windows x64 bundle from the pinned checkout;
updates currently use manually prepared bundles. Authenticode signing, an automatic Windows download/update channel,
ARM64, pre-sign-in startup, every external backend/provider combination, and
physical power-loss durability are outside these gates. Windows Sendmux uses a
private SQLite PERSIST journal with EXTRA synchronization; Unix retains its
existing atomic-file and directory-sync protocol.
