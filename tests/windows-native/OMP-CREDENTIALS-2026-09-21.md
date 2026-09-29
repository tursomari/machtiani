# Windows guided-installation regressions, 21 September 2026

An agent-operated installation with no preinstalled backend reproduced a gap
in the Windows OMP instructions. The unchanged Linux terminal operator drove
the real Windows installer over SSH as an ordinary user. Credentials entered
only through the operator's guarded masked-input action. The provider was
DeepInfra, `zai-org/GLM-5.3-Flash`, with high reasoning.

OMP 18.2.7 installed successfully, and the credential-result guard accepted the
installation result. When an unprivileged symlink failed, the installation
assistant copied `backends.env` into OMP's `.env` and ran `chmod 600`. It then
reported the file as private. The live backend probe succeeded, but a separate
read-only call to `hasPrivatePermissions` returned false. The test was stopped;
its backend probe was not treated as a successful installation. This run did
not reproduce or establish the original transient credential-result validation
failure.

Installer commit `7ffc212` adds `--omp` to the secure helper. Its trusted adapter
copies only the selected saved provider into the default OMP environment file,
protects the temporary file before writing credential bytes, atomically replaces
the destination, and verifies native privacy before returning a reference.
Other supported environment entries are preserved. Non-private files, symlinks
and unsupported existing dotenv content are refused. Replacing the provider key
requires `--omp --replace` to update both stores. Custom OMP profiles require a
separate supported integration.

Validation completed before the live retest:

- Pinned-toolchain installer suite: 526 passed, nine platform-specific skips.
- Repository type checking and the Linux test machine Nix runtime build passed.
- The real credential-boundary integration passed in installer and concierge
  modes with a loopback provider and counterfeit credentials.
- Native Windows tests: four files passed, six tests passed, one Unix-only case
  skipped. These include the copied-file/chmod reproduction, broadened ACL
  rejection, secure CLI/bridge receipt, key replacement and entry preservation.
- The README installation contract and IPE archive/preflight/cleanup self-test
  passed. The Linux operator and installation-driver behavior were unchanged.

The native development dependency installation initially failed to fetch three
optional agent payloads concurrently. A retry with one download at a time
completed; the test workspace built normally before the native suite ran.
This was test-tool preparation, not the guided installation subject.

The next fresh-account rehearsal used umbrella `bf40ade3` with installer
`7ffc212`, DearMachine `fd3f67a` and harness `2890e6181`. It installed OMP 18.2.7,
selected the new helper without operator coaching, and passed an independent
native ACL check. Direct OMP, Agent Manager and Machtiani live probes passed.
Workspace extraction and model-backed synchronization completed, the daemon
started, and an actual AgentMail reply arrived in the authorized sender's
original thread. All 1,254 installed source files matched the prepared snapshot.
Optional sign-in startup was declined. This used a prepared runtime, not a new
Windows toolchain acquisition run.

That rehearsal found a separate concierge defect after successful installation:
its banner and `/status` reported that detailed native status was unavailable,
although the native CLI reported startup as not configured. Native fallback
guards compared the Windows named pipe to a Unix socket filename. Installer
`deea0d7` compares against the platform's actual default endpoint, preserving
rejection of a different owner. The same correction permits native bootstrap
when the supervisor endpoint is absent. Existing socket-based stop/start worked
before this fix; that alone did not cover bootstrap or detailed status.

Five Windows regression cases failed against the old guards. With the fix,
12 native cases passed with one Unix-only skip, including a real native CLI
query in an isolated fresh home with no supervisor. The full installer suite
passed 526 tests with 15 platform-specific skips; type checking and the Linux test machine
Nix runtime build passed. The installation-composition self-test also passed.
The rehearsal was stopped cleanly and its disposable mailboxes were removed
before preparing another fresh account; the human's account was preserved.

The existing-backend rehearsal on umbrella `d59d64ba` passed OMP's live probe
and native credential ACL check. It then reproduced a third Windows defect:
the release launcher unconditionally reset `MACHTIANI_CONFIG` to DearMachine's
not-yet-created config. Removing the variable or selecting the global config
could not take effect, so the installation assistant repeated diagnostics.
The rehearsal was stopped before product setup completed. The Windows launcher
now preserves the caller's selection, including an absent variable. DearMachine
continues to select its private config in its existing native and installer
code. A native executable fixture tests stable and release-local launchers with
absent, global and DearMachine selectors: four cases failed before the fix;
all six passed afterward. Linux launchers and the Linux operator are unchanged.

A fresh existing-backend run on umbrella `1b4e76c3` completed installation with
DeepInfra GLM-5.3-Flash at high reasoning. OMP's native ACL, direct live probe,
effective model/reasoning metadata and Agent Manager file-writing probe passed.
Global configuration validation, model-backed synchronization, the Machtiani
live probe, private configuration import and both workspace seed trees passed.
An authorized external email caused a real OMP ticket to create a proof file;
its contents matched, and a reply arrived in the sender's original thread.
All 1,258 source files remained identical to the prepared snapshot.

The concierge banner and `/status` showed native Windows startup observations.
`/down` and `/up` worked, `/quit` left the daemon running, and reopening with a
minimal Windows PATH returned directly to the concierge without setup or login.
Decoded installer transcripts contained none of the registered test credentials.
The launcher configuration cases also passed after rebuilding with Go 1.26.5,
the Windows acquisition toolchain.

A separate cold-start check then shut down the supervisor through the native
updater control. Concierge bootstrap reached the native command, but the new
daemon failed because it lacked `AGENTMAIL_API_KEY_FILE`: initial setup had
supplied that reference only in its temporary shell. The previous successful
stop/start operations reused the existing supervisor's environment. The Windows
launcher now discovers the secure helper's saved AgentMail file when neither an
explicit key nor file reference was supplied. It passes only the path and does
not read or export the key. Explicit caller credentials retain precedence;
absent files and non-regular paths are not adopted. This is Windows-only.

Both saved-credential cases failed against the prior launcher. With the fix,
all 14 native launcher cases passed using the pinned Go 1.26.5 build. The earlier
run was closed before preparing a separate managed-update and cold-start test;
its successful installation was not treated as proof of cold-start behavior.

The managed update to umbrella `ae510dff` completed with the previous release
retained for rollback. In a new SSH terminal with both AgentMail environment
variables cleared and only Windows system directories on PATH, the concierge
observed the installed but stopped state. `/up` created a new supervisor and
daemon, with zero failures and no startup-at-sign-in configuration. A second
external email produced another real OMP ticket and a distinct proof file with
the requested contents. `/quit` left this work running. The ticket closed with
a native reply, and the actual reply arrived in the sender's original thread.
This second round trip took about 13 minutes, including roughly seven minutes
inside OMP; it was not counted as passing merely when the file appeared.
All 1,258 updated source files matched their snapshot, and another decoded
transcript scan found none of the registered credentials.

The latest documentation, installation-guidance, IPE self-test and installation-
composition self-test gates passed. These live tests used prepared runtimes;
they do not replace the separately recorded native Quick start acquisition
gate. They exercised DeepInfra/OMP and AgentMail, not completion of a human's
ChatGPT subscription authorization or a new Windows sign-out/reboot test.
