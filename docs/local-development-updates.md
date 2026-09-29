# Development updates from local Git mirrors

A managed Nix installation can use `dearmachine update` with committed local
development revisions, without publishing those revisions to GitHub. Keep bare
Git mirrors on a local or removable drive and use Git's `url.*.insteadOf`
configuration to redirect the recorded source URLs to them. Source code,
`.gitmodules`, and installed release receipts stay unchanged.

This applies to the [coordinated Nix updater](managed-nix-installation.md),
including updates requested through the concierge. Standard installations use
a different update path. The commands below require Git and Python 3 and are
maintainer operations: an agent needs explicit authorization to push commits or
update an installation, as described in the [umbrella runbook](umbrella-runbook.md).

## How the updater chooses its source

At installation, the updater records the umbrella checkout's
`remote.origin.url` in `current/release.json`. Subsequent checks read that
receipt and run `git ls-remote --symref <recorded-url> HEAD`. Updates clone the
same URL, check out the returned commit, and initialize its pinned submodules
recursively. They follow the remote's default branch, not the current branch
of a development checkout.

A remote name such as `passport` or `local-update` in a working checkout does
not change an existing installation's source. Git's `insteadOf` rewrites the
transport destination while preserving the recorded HTTPS or SSH identity.
The updater rejects a filesystem path or `file:` URL as the recorded identity;
use the Git rewrite rather than editing `release.json`.

## Prepare and publish a local candidate

Choose an initialized umbrella checkout and an absolute mirror directory.
Replace these example paths with your own; mount a removable drive first.

```bash
source_root=/absolute/path/to/umbrella-checkout
mirror_root=/absolute/path/to/local-mirrors
```

For a new mirror directory, create the four empty repositories once. Existing
mirrors can be reused; their symbolic `HEAD` must select `refs/heads/main`.

```bash
mkdir -p "$mirror_root"
for repository in machtiani dearmachine machtiani-harness dearmachine-concierge; do
  git init --bare --initial-branch=main "$mirror_root/$repository.git"
done
```

Commit and verify the component changes, then commit their exact umbrella
pins using the normal development workflow. Publish the pinned component
commits first and the umbrella last:

```bash
(
  set -e
  for component in dearmachine machtiani-harness dearmachine-concierge; do
    candidate=$(git -C "$source_root" rev-parse "HEAD:$component")
    git -C "$source_root/$component" push \
      "$mirror_root/$component.git" "$candidate:refs/heads/main"
  done
  git -C "$source_root" push "$mirror_root/machtiani.git" HEAD:refs/heads/main
)
```

These pushes target only the explicit local paths. A rejected non-fast-forward
push requires inspecting the differing histories; this workflow does not force
updates. Only committed content is available to the updater. Every gitlink,
including any nested submodule, must be obtainable from its corresponding
mirror before publishing the umbrella candidate.

## Configure persistent URL redirects

Read the installed source URL from the active receipt. If the managed launcher
records a different data directory, use that directory for `managed_data_home`.

```bash
managed_data_home="${DEARMACHINE_MANAGED_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
receipt="$managed_data_home/dearmachine/current/release.json"
installed_remote=$(python3 -c \
  'import json, sys; print(json.load(open(sys.argv[1]))["remote"])' "$receipt")
mirror_url=$(python3 -c \
  'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().as_uri())' \
  "$mirror_root/machtiani.git")
git config --global --add "url.$mirror_url.insteadOf" "$installed_remote"
```

The setting persists in this user's Git configuration until removed. It applies
to Git operations using that URL, including future update checks and clones.
`insteadOf` uses prefix matching, so use complete repository URLs rather than
broad host-wide prefixes. Inspect existing entries before adding duplicates:

```bash
git config --global --get-regexp '^url\..*\.insteadof$'
```

An umbrella redirect is enough for `--check`. An actual update also needs
redirects for the URLs in the candidate's committed `.gitmodules`:

```bash
for component in dearmachine machtiani-harness dearmachine-concierge; do
  component_remote=$(git -C "$source_root" config --blob HEAD:.gitmodules \
    --get "submodule.$component.url")
  component_url=$(python3 -c \
    'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().as_uri())' \
    "$mirror_root/$component.git")
  git config --global --add "url.$component_url.insteadOf" "$component_remote"
done
```

For a candidate with nested submodules, mirror and redirect those URLs too.
After a source URL changes, inspect the new candidate and refresh the mappings.
Keep the exact mapping list in private development notes for later removal;
machine-specific paths and installation receipts do not belong in source control.

## Check and update

With the drive mounted, a normal check now queries the local umbrella:

```bash
dearmachine update --check --json
```

Compare `available` with the candidate you published. Checking does not build
or activate software, and does not prove that all submodules are accessible or
that the installed updater supports the target layout. In particular, older
updaters expecting `machtiani-installer` cannot prepare an umbrella that replaces
it with `dearmachine-concierge`; that requires a separate updater migration.
URL rewriting does not resolve component-layout compatibility.

If no in-place migration is available, an explicitly chosen
[reinstall with verified data restoration](reinstall-with-data-restore.md)
can bypass the old receipt transition. Back up outside uninstall's deletion
paths and prepare the replacement checkout before removing the installation.

When the candidate and installed updater are compatible, permit local-file
transport for this update and its recursive submodule clones:

```bash
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=protocol.file.allow \
GIT_CONFIG_VALUE_0=always \
dearmachine update
```

Run this from a shell without other `GIT_CONFIG_COUNT` overrides, or append the
entry to the existing override set. The file-protocol permission lasts only
for this command and its children; the URL redirects remain persistent.
Ordinary recursive submodule clones can reject file transport without it.
For a concierge-driven update, launch the concierge with the same environment.

Updating builds and activates the local candidate and may restart a running
client. Nix can still download build dependencies; this is a local release-source
workflow, not a guarantee of an entirely offline build. An unavailable mirror
causes Git to fail rather than fall back to GitHub.

## Return to public updates on release day

Remove each exact mapping you added, using the saved URLs. For the umbrella,
with the variables above still set:

```bash
git config --global --fixed-value --unset-all \
  "url.$mirror_url.insteadOf" "$installed_remote"
```

Repeat for every component mapping, replacing the key with
`url.<component-file-url>.insteadOf` and the value with its original repository
URL. Exact-value removal preserves unrelated mappings. Inspect the remaining
entries with `git config --global --get-regexp '^url\..*\.insteadof$'`; no entries
produces no output and exit status 1.

Confirm that the release installation records the intended public source, then
run `dearmachine update --check` without temporary Git overrides. Removing a
rewrite restores access to the recorded remote; it does not replace a legacy
repository identity with a newly named public repository. Add this cleanup to
the release issue when enabling development redirects.
