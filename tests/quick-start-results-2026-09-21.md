# Quick start validation — 21 September 2026 (UTC)

The three README routes now enter guided setup directly. Installer changes were
validated at `fff138e`; DearMachine and harness remain pinned to `c3a429c` and
`2890e61`. Linux Standard and live IPE used umbrella `a7ec1e6`, with the same
installer pin and Linux implementation as the final candidate. Later changes
address Windows bootstrap behavior and test instrumentation.

## Observed gates

| Gate | Result |
| --- | --- |
| Installer typecheck and full test suite | Passed; 518 passed, 8 skipped |
| Installer Nix build | Passed |
| Real packaged Nix Quick start through consent/model selection and Back | Passed |
| Nix feature-disabled prerequisite guidance | Passed |
| Linux Standard bootstrap and full Docker build from the README route | Passed |
| Linux Standard terminal handoff and Back, without configuration/credentials | Passed |
| Built Linux runtime in an ordinary-user container without Nix or network | Passed; product entrypoints, installer/concierge model-host and shell round trips, child processes, Git LFS |
| Recursive Windows source export and pin/dirty/missing-source checks | Passed |
| Windows dependency checksum/cache and ZIP boundary checks | Passed on Linux PowerShell and native Windows PowerShell 5.1 |
| Native Windows gzip archive extraction with drive paths | Passed |
| Native Windows dependency acquisition, build, installation and terminal handoff | Passed |
| Repeated Windows Quick start reuses the installation | Passed |
| Native Windows confirmed uninstall and external-file preservation | Passed |
| Native Windows packaged agent/model-host round trip | Passed; installer and concierge shell calls, plus packaged Git LFS |
| Standard/container runtime and bootstrap contracts, documentation and maintenance gates | Passed |
| IPE, IXE and QSE offline self-tests | Passed |
| Credentialed installation-procedure evaluation | Passed; DeepInfra GLM-5.3-Flash high, OpenMail sender/AgentMail receiver, attachment reply and runtime/session assertions, exact cleanup |

## Native Windows method

The native Windows build used umbrella `3a7ec86`; subsequent changes add test
preflight checks and documentation. The Windows gate ran as an ordinary user
in a disposable Windows 11 x64 VM.
Only Windows system tools were on the bootstrap PATH. A separately prepared
runtime supplied Node and node-pty to the test driver, which launched the real
PowerShell Quick start command through ConPTY. The source fixture contained the
exact committed files and recursive pins, verified against Git objects; no host
Git administration, homes or agent sockets were shared with the guest.

Dependency acquisition started with an empty private cache; verified downloads
were retained across corrections. The bootstrap acquired checksum-pinned
dependencies into its private cache,
built native products, and installed to a destination containing spaces and
Unicode. The terminal gate stops at model selection before entering credentials
or creating DearMachine configuration. The completed build first encountered
legacy Machtiani state retained by an earlier VM proof and correctly selected
recovery. That state was preserved separately, the test installation was
uninstalled, and a fresh installation reused the verified bundle and passed the
terminal gate. A second invocation passed the installed-launcher reuse gate.
The test now rejects legacy state before starting acquisition.

Native execution found and corrected PowerShell parameter-default timing,
process execution-policy loss during environment isolation, Unix tar handling
of Windows drive paths, and PowerShell's long-path limit when copying npm.
The Linux terminal gate also required retaining route evidence across the
progress output of a real first build.

## Scope and cleanup

These checks do not repeat the earlier Windows mail/lifecycle/reboot proof,
full Windows provider onboarding, browser-based authentication, or native macOS
execution. They do not establish a Windows release-download channel or
Authenticode signing. See the existing platform reports for those boundaries.

The live IPE returned success and verified cleanup; its temporary credentials
and test container were removed. The Windows installation was removed through
its
confirmed terminal uninstall; absence of owned software/private state and
preservation of an external file were verified. The earlier VM fixture state
was preserved separately during the fresh-install gate and restored afterward.
Development worktrees and signed commits remain available for review.
