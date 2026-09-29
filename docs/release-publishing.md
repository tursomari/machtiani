# Release publishing

The [release workflow](../.github/workflows/release.yml) builds prebuilt Dear
Machine downloads and publishes them as a **draft** GitHub release of this
repository. A maintainer reviews and publishes the draft. Agents never push
tags or publish releases.

## What a release contains

| File | Purpose |
| --- | --- |
| `dearmachine-<tag>-linux-x64.tar.gz` | Unrelocated Linux x86-64 runtime, built with Docker |
| `dearmachine-<tag>-linux-x64.bootstrap.sh` | Activation script that pins the archive's checksum |
| `dearmachine-<tag>-linux-x64.manifest.json` | Component revisions and archive checksum |
| `dearmachine-<tag>-linux-arm64.*` | The same three files for Linux ARM64, built natively on an ARM64 runner |
| `dearmachine-<tag>-darwin-arm64.*`, `dearmachine-<tag>-darwin-x64.*` | The same for macOS Apple Silicon and Intel, built natively; installing needs Apple's Command Line Tools |
| `dearmachine-<tag>-windows-x64.zip` | Windows x64 bundle, installed by `scripts/install-windows.ps1` |
| `install.sh`, `install.ps1` | Installers rendered for this repository, tag, and workflow ref |
| `SHA256SUMS` | Checksums of every other file |
| `attestation.sigstore.json` | Signed attestation bundle, so `gh` can verify without signing in |

When the repository is public, one attestation covers `SHA256SUMS` and every
listed file.

## How the installers verify a release

`install.sh` (Linux and macOS) and `install.ps1` (Windows) use the GitHub CLI:

1. Download `SHA256SUMS` and `attestation.sigstore.json`. A signed-in `gh`
   downloads through the GitHub API; otherwise the public release URL is used.
2. Run `gh attestation verify` on it with the bundle, pinned to this repository, to
   `.github/workflows/release.yml` as the signer, to the ref the release was
   built from, and denying self-hosted runners. A failed check stops the
   installer; nothing is installed and no override is offered.
3. Download this computer's archive, compare it with `SHA256SUMS`, and hand
   it to the existing activation path.

Verification needs `gh` 2.68.0 or newer: older releases lack `--source-ref`
or cannot read the current Sigstore trusted root, and many distribution
packages are older than that. Signing in is needed only for a release without
the bundle. If `gh` is missing or too old, or is signed out and the bundle is
absent, the installer explains why the check matters and how to install or
update `gh` and, if needed, run `gh auth login`. It continues only if
the person types `yes` at a terminal, and then relies on `SHA256SUMS` alone,
which detects a damaged download but not a deliberately altered release.
Without a terminal it stops.

## Building while the repositories are private

GitHub offers artifact attestations only to public repositories unless the
owner uses GitHub Enterprise Cloud. The attestation step is skipped while this
repository is private, and the draft's notes are marked unattested. It
activates automatically on the first run after the repository becomes public.

The default workflow token cannot read the private submodules. Create a
fine-grained token with read-only **Contents** access to the three submodule
repositories and add it as the repository secret `SUBMODULE_READ_TOKEN`.
Delete it once the submodules are public.

A tag push builds every target. While the repository is private it skips the
macOS targets, whose minutes cost ten times Linux minutes; set the repository
variable `RELEASE_TARGETS` (for example `linux-x64,darwin-arm64`) to choose
the targets a tag push builds.

To iterate without a tag, run the workflow manually with a tag such as
`v0.1.0-rc.1` and a comma-separated `targets` list. Delete dry-run drafts when
done. Private repositories spend included Actions minutes, with Windows counted
at twice the Linux rate.

## Publishing a release

1. Confirm the four repositories are public and the submodule pins are
   published.
2. Push a tag such as `v0.1.0` on the umbrella commit to release. The workflow
   verifies the tag exists and attests the files.
3. Review the draft. Check that the attestation step ran, then publish it.
4. Verify on each supported platform, for example:

   ```sh
   gh attestation verify SHA256SUMS --repo <owner>/<repo> \
     --signer-workflow <owner>/<repo>/.github/workflows/release.yml \
     --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
   ```

## Local checks

- `python3 tests/release-install-test.py` runs the rendered installer against
  a stub `gh` and a loopback server, covering verification, checksum and
  attestation failures, and the `yes` confirmation on a real terminal.
- `python3 scripts/release-build.py --target linux-x64 --tag v0.1.0-rc.1
  --repository <owner>/<repo> --output <new-directory>` builds the Linux
  download locally with Docker, relocates and probes a copy, and packages the
  unrelocated runtime.
