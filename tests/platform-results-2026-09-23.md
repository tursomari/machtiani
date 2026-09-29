# macOS and Windows installation investigation — 23 September 2026

This investigation develops changes in the primary `main` worktrees.
Guests use disposable disk overlays and ordinary user accounts. Local commits
are signed; nothing has been pushed. Linux regression gates remain required.

## Candidates and scope

- DearMachine: `ec5a6515b2ca5982cb0a8ea1cfabd9effbcb1d89`.
- Installer: `abb6dc27d6f6f28a008c70e710e734603dd896cd`.
- Harness: `08f0341099c3e9a4e85762eb19cc9d6a54ad9f2f`.
- Windows initial native installation: umbrella `b485aaf`.
- Final macOS package: umbrella `9a284c2`.

Model A is DeepInfra `zai-org/GLM-5.3-Flash`; model B is
`deepseek-ai/DeepSeek-V4.1-Flash`. Both use the requested high reasoning
setting. Credentials enter through the real masked fields. Live email checks
use only a disposable receiver/sender pair, with cleanup journals.

Intel macOS Sonoma 14.8.9 and Windows 11 x64 build 26100 run under QEMU.
Apple Silicon execution is unverified. The available Vulkan device is
CPU llvmpipe with a 2 GiB heap; it does not satisfy the experimental ARM macOS
emulator's documented GPU-memory requirement. Compilation alone is not runtime
acceptance. Windows ARM64 is outside the current Windows x64 target.

## Reproduced defects and changes

### macOS foreground ownership

The baseline accepted `launchd on` while an independently started foreground
daemon still owned the installation, and saved launchd consent. The CLI now
checks for that owner before switching. The regression fails on the baseline
and passes on native macOS and Linux. The maintained macOS lifecycle fixture
also exercises an actual foreground daemon, checks refusal, and preserves the
existing owner and consent.

### macOS inherited supervision-choice lock

The actual installation could not enable launchd after stopping the daemon:
it reported that another supervision choice or startup was in progress.
Native descriptor inspection showed that the idle background supervisor had
inherited `supervision-consent.lock`. The lock was opened without close-on-exec.

The CLI now opens it atomically with `O_CLOEXEC`. A regression keeps an exec'd
child alive while the parent releases its shared lock and obtains an exclusive
lock. It fails before the change on both Linux and native macOS, and passes
afterward. Native launchd lifecycle checks pass with the fixed binary and with
the complete final package.

### Interrupted custom-provider setup

Reopening incomplete setup previously repeated custom-provider details and
API-key entry despite a saved private credential reference. Setup now offers
**Use saved settings** or **Change settings**, verifies the saved provider,
and supports retry or editing after failure. Management `/model` behavior
is unchanged.

Real interrupted-setup flows on macOS and Windows passed the saved-settings
verification without re-entering the model key. The installer suite passed
572 enabled tests, with 17 skipped, and typechecking passed.

### Windows dependency download stalls

The first fresh Quick start left the Zig transfer at zero bytes for several
minutes. Cancelling the UI released the preparation lock and did not activate
an installation. System curl downloaded the identical pinned archive in
91.67 seconds with the expected checksum. A later Invoke-WebRequest retry also
succeeded in 75.7 seconds: the evidence establishes a transient stall, not
universal Invoke-WebRequest failure.

Bootstrap now uses system curl with connection, idle-transfer and overall
deadlines, bounded retries, HTTPS-only redirects, and the existing checksum
validation and private partial-file cleanup. The error explains how to retry
while retaining verified downloads. Native offline tests cover failed-transfer
cleanup/retry and a real closed-port transport failure. A subsequent real
Quick start downloaded Zig, reused verified dependencies, built the native
products, and installed successfully.

### Installation guidance and test corrections

Probe directories must be freshly and uniquely created rather than deleting
fixed paths in the user's home. Completion must provide the stable absolute
reopening command; an inherited login-shell PATH does not establish that a
new terminal can find the command.

The macOS crash fixture now tests one status snapshot per assertion, avoiding
a race between two status calls. Stale README assertions were aligned with the
existing README. These changes do not weaken lifecycle assertions.

## macOS observed acceptance

The actual-account baseline installation needed assistance to recover the
inherited lock. It is therefore **not an unassisted final-candidate installation
pass**. The latest complete candidate was built and tested separately.

- Live OMP 18.2.11 model A/high call, session model/reasoning metadata,
  Agent Manager health checks, and Machtiani provider/sync checks passed.
- A real email request created its requested proof file and received a reply
  in the original sender thread, with matching reply linkage.
- Closing chat retained the running supervisor and daemon.
- Killing the owned daemon changed its PID while retaining the supervisor.
- Concierge, planner, shell-agent and sync were independently changed through
  the real model menu to model B/high, retaining the model A default.
- OMP's persistent backend choice was changed to B/high and verified with a
  fresh process and matching session metadata. Machtiani role verification
  and sync also passed.
- Reopened chat retained all four overrides.
- Actual GUI logout stopped the launchd client; login started it again.
  After reboot it remained stopped before login and started after login
  completed, without a manual `up`.
- After reboot, all overrides remained saved, a fresh OMP probe reported B/high,
  and a second real email produced its requested file and linked reply.
- The final native package passed standard-package smoke tests and the
  maintained real launchd lifecycle fixture.
- The client was stopped, persistence disabled, and both test inboxes deleted.

The VM's OpenCore boot selection and a macOS reopen-apps dialog required
operator interaction. An early post-login status sample preceded completion of
that dialog; it is not the final startup result.

## Windows observed acceptance

Native Quick start built the exact recursive source pins and installed into
the default ordinary-user location. OMP 18.2.11 was installed through its
documented native installer. Interrupted setup reused its saved provider;
the live model A/high OMP probe and Agent Manager health check passed.

Completed native gates include private ACLs, locks, embedded workspaces,
supervisor startup/crash recovery and SSH-job breakaway, worker cancellation,
SQLite and Sendmux recovery, and 50 concurrent journal-creation repetitions.
Agent Manager Windows tests passed. Installer native integration passed
12 tests with one POSIX-only skip. Packaged Codex invocation and actual
installer/management shell-console isolation passed.

Actual setup completed and opened the concierge with sign-in startup enabled.
A real request sent at 22:53:06 UTC produced the exact requested proof file
and a linked reply in the sender inbox at 22:55:45 UTC (about 2m39s).
The native file check verified the marker plus one newline. An intentional
daemon termination recovered under the same supervisor (1744), changing daemon
PID 5628 to 532.

All four component overrides were independently selected as model B/high through
the real model menu, preserving the model A/high default. Reopening the stable
launcher retained every override. Live Machtiani role verification and a fresh
sync probe passed. OMP's persistent default was changed separately; a fresh
probe returned READY with matching B/high metadata and no fallback, and Agent
Manager health passed. The concierge needed a conversational reminder to stop
rechecking its working credential reference. The resulting management-guidance
change is committed separately as `cfe144d`; its 12 existing guidance tests
pass. That later documentation change was not part of the installed bundle.

Closing the actual chat and SSH session retained the same supervisor and daemon.
With the concierge open, a manual update using the same candidate bundle
activated a fresh release and restarted the client; rollback restored the
original release and a healthy client. Hashes of the shared model profile,
DearMachine device config and Machtiani config remained identical. This tests
activation and Windows binary-lock handling, not a version migration between
different compiled candidates.

A real foreground client survived a second `up` and concierge startup, both
with an existing idle supervisor and with no supervisor endpoint. The second
`up` refused ownership and left the process set unchanged. Concierge startup
created no competing supervisor. The fixture stopped only its verified idle
test supervisor to establish the endpoint-absent case; this is test preparation,
not recommended recovery guidance. Stopping the foreground client through its
own terminal and returning to ordinary background supervision succeeded.

After actual reboot, the client was stopped before GUI sign-in. Sign-in
automatically started supervisor and daemon in desktop session 1, without
`up`. Signing out that desktop stopped both. All model overrides survived
reboot. A second sign-in automatically started both processes in desktop session
2. The second email, queued while signed out, produced its exact proof file and
a linked reply in the sender's original thread at 23:23:15 UTC. The four model
overrides and GLM default were independently checked again. A separate fresh
OMP process after reboot returned its expected marker and recorded B/high with
no fallback in metadata matched to that probe's directory and timestamp.

Finally, sign-in startup was disabled, the client stopped, both test inboxes
deleted, and the guest shut down. The original unrelated inbox was preserved.

The installer ran one Agent Manager health probe in its source directory,
contrary to existing guidance, then removed the resulting probe file.
This observed behavior remains distinct from the passing backend result.
The installer also exposed internal planning prose and named the machine inbox
instead of the sender inbox in part of its completion guidance. Actual pairing,
delivery linkage and the independently verified sender receipt were correct;
the narration should not be treated as authoritative evidence. During the
foreground-owner test, the concierge rendered generic unknown/unreachable
status, while the native CLI supplied the explicit ownership diagnostic.
The ownership safeguards passed. The generic concierge wording was subsequently
addressed in the Linux-verified follow-up below.

## Evidence and boundaries

Private run artifacts are retained outside Git under
`/var/tmp/machtiani-platform-repro-20260923`. They include guarded
terminal screens, native test logs, lifecycle snapshots and mail journals.
Credentials and raw terminal input are not included in this report.
Both disposable guest disks and temporary API/account credential copies were
removed after cleanup; original guest disks and host credentials were preserved.
A scan of 111 retained logs, guarded screen snapshots, metadata, mail journals
and this report found none of the registered API keys or tested encoded forms.
This is not a claim that every decoded guest trajectory was audited.

Linux full Go tests, vet, race checks and all 21 Nix flake checks passed after
the native fixes. Native macOS tests and vet passed. An initial PTY timing
failure under build load passed unchanged in three isolated repetitions and
the full rerun; the original log is retained.

Fixture mistakes are recorded separately from product failures: omitted
recursive Windows source snapshots, missing macOS packaging metadata, an
incorrect PowerShell test-flag invocation, and a bare native binary invoked
without its packaged runtime PATH. Each was corrected before the corresponding
acceptance result. The foreground operator initially refused a fixture directory
with non-private permissions; correcting that directory allowed the test to run.
The post-reboot OMP evidence reader initially assumed the first JSONL record
was the session header. OMP had prepended a title; scanning for the actual session
record verified the original successful call without repeating inference.

Mac package snapshots include the compiled runtime and
top-level pins; optional nested Skyvern integration execution was not tested.

## Ownership recovery follow-up

DearMachine `19991848d6ecd5b90a8887cbc8483c9cc379110e` and installer
`81cf55af537beaa4b1cf6ee2e25af2011ba8d9f6`, both signed on main.

The native CLI already recognized an independent foreground or service owner,
but its nonzero plain-text status result caused the concierge to discard the
report. The safe fallback lacked the ownership observation and displayed only
unknown/unreachable state.

Native JSON status now includes an optional boolean `externalOwner` when that
owner is positively observed. Uncertain or malformed ownership state does not
set the flag. The concierge preserves this observation without exposing raw
subprocess errors and gives this recovery instruction:

> Inspect the existing process or service. To switch supervision, stop that
> owner, then run dearmachine up.

This applies even when the original terminal is gone. It does not claim that
the other owner is healthy or authorize taking it over. Local `/up`, `/down`
and `/restart` explain the conflict without sending a mutation to a different
supervisor or bootstrapping another one.

The initial regressions failed before implementation. The corrected Go tests
cover a foreground owner, a stale supervisor record, and a responding idle
supervisor alongside another owner. Tests also distinguish absent, stopped,
invalid and unresponsive ownership from a positively observed external owner.

The actual Linux native CLI and built concierge were exercised through a PTY
with a separate process holding the daemon lock, both with and without a stale
supervisor record. Status and all three lifecycle slash commands explained
recovery, preserved the same owner and lock, and created no supervisor state.

Validation: full Go suite and vet, lifecycle/supervisor race checks, all 21
Linux Nix flake checks, installer build and typecheck, 578 installer tests
passed with 19 skipped, and all six native-to-concierge terminal integration
tests passed separately. This follow-up
has not yet been run in native macOS or Windows guests; earlier platform
acceptance above applies to the preceding candidates. Apple Silicon remains
unverified. No live provider or email credentials were needed for these checks.
Private follow-up logs are under
`/var/tmp/machtiani-recovery-followup-20260923`.
