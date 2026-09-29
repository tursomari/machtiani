# Windows Quick start build-path regression — 21 September 2026

The reported OpenAI sign-in packaging failure was a Windows process-launch path
limit, not a missing download. The Codex wrapper and pinned native payload were
both present. The native executable's path in the failed build stage was 262
characters: ordinary launch returned `ENOENT`, while launching the same file
with the Windows extended-path prefix returned `codex-cli 0.153.2`.

The builder appended a GUID to an already content-addressed bundle name under
`%LOCALAPPDATA%\DearMachineBuild`. It now uses a short, unique sibling staging
directory and retains the same final rename. The packaging gate still requires
the actual JavaScript launcher to work. If that launcher fails with `ENOENT`,
the executable exists at an overlong path, and an extended-path probe succeeds,
it reports the path limit. A generic launch failure no longer asserts that
network access or a missing download caused it.

## Candidate and checks

The runtime candidate is umbrella `a7c5f93a8a31c4ae63f67e0bed4dd9bc0c921b18`;
component revisions are unchanged from its parent. All new commits are signed.

- `node --test tests/codex-runtime-test.cjs tests/windows-source-test.cjs`:
  five tests passed.
- `tests/documentation-entrypoint-test.sh`: passed, including twelve backend
  guidance tests.
- Native `codex-paths.cjs`: passed using the real downloaded Windows Codex
  packages. Short-path launch succeeds, overlong-path launch gets the specific
  diagnostic, and moving those same files back restores launch without network
  access or sign-in.
- Native `quick-start.mjs`, fresh mode: passed. The documented PowerShell
  entrypoint ran with only Windows on PATH, compiled the native products,
  installed and built the JavaScript runtime, printed `Verified bundled Codex
  0.153.2`, installed the bundle, and reached provider selection through consent.
- Native `quick-start.mjs`, repeat mode: passed. It reopened provider selection
  through the installed launcher without preparing the toolchain again.
- The six public tool archives were seeded only after checksum verification;
  the production downloader rechecked them. Go and pnpm used a fresh isolated
  build home. The driver used a separate prepared Node/node-pty runtime solely
  for terminal instrumentation. Source was reconstructed from exact recursive
  commit/tree exports and verified against every committed blob.
- The production Codex gate passed again after the build stage was renamed to
  the cached bundle and after installation into the active release.
- Native `removal.ps1`: passed. Terminal cancellation preserved the installation;
  confirmed uninstall completed asynchronous cleanup, removed owned state, and
  preserved the external junction target. The disposable account's pre-existing
  independent project data was restored afterward. The human IXE account was
  left uninstalled for its own fresh setup.

## Coverage and limits

Earlier prepared-runtime checks exercised Codex in shorter directories and did
not cover the content-addressed Quick start cache plus its staging suffix. The
new native regression exercises that process-launch boundary directly; the
full Quick start run uses the default per-user cache and installation layout in
a disposable ordinary account with a longer profile name than the reproducer.

The existing ConPTY Quick start driver and Linux installation driver are
unchanged. This packaging regression needs no LLM, provider credentials or
mailbox. It does not claim a new completed OAuth sign-in or full provider/mail
onboarding evaluation; those boundaries are recorded separately in the
[native guided-installation results](OMP-CREDENTIALS-2026-09-21.md).
