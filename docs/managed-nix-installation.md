# Coordinated Nix installation and updates

The guided Nix installer manages Dear Machine, Agent Manager, Machtiani,
the installer/concierge, and the model host as one release. Backend agents such
as Forge, Codex, OMP, and Claude Code retain their own installation and update
mechanisms. Standard builds have separate acquisition and ownership rules;
Nix updates do not modify them.

Nix targets Linux x86-64 and ARM64, and macOS on Intel and Apple Silicon.
See [installation platforms](README.md#installation-platforms) for the limits
of the other acquisition routes and the recorded live test coverage.

## Acquisition

From a committed umbrella checkout with all pinned submodules available:

```bash
nix run ./dearmachine-concierge -- install --source-root "$PWD"
```

This command installs software only. It does not choose models, provision
inboxes, pair senders, or start the client. Run `dearmachine` to continue guided
configuration. The normal guided installer performs this acquisition itself
at the product installation stage.

Rerunning this command with a newer committed checkout from the same `origin`
updates an existing managed installation in place, using the same build,
activation and rollback steps as `dearmachine update`. It preserves configuration.

The checkout's `origin` identifies the update channel. HTTPS remotes must not
contain credentials; SSH remotes use the user's normal Git authentication.
The selected umbrella commit and its exact submodule commits are exported,
including nested submodules. Untracked files, Git administration and history,
and `.env` files are not included. Unsafe paths and escaping symlinks are
rejected. Builds use this snapshot, not working-tree modifications.

Installation data lives under `$XDG_DATA_HOME/dearmachine` when set, otherwise
`~/.local/share/dearmachine`. Missing parent directories are created:

- `sources/<umbrella-revision>/`: source, component revision metadata and docs.
- `releases/<umbrella-revision>/`: executable launchers, Nix garbage collection
  roots, and a versioned `release.json` with source and executable provenance.
- `current`: the active release, switched atomically.

Public commands in `~/.local/bin` point through `current`. Existing unrelated
commands are left untouched: this installer does not automatically adopt an
unrelated Nix profile installation, a development launcher, or a Standard release.
A managed Machtiani launcher's `update` command delegates to the coordinated
updater so its version does not move independently. Its standalone automatic
updater is disabled inside this release.

Installing Machtiani first and DearMachine afterward is supported. DearMachine
recognizes the default standalone Machtiani launcher and switches it to the
combined release after preparing the new packages. Existing Machtiani settings
and project data are retained. If activation fails, the standalone launcher is
restored. Subsequent standalone Machtiani install or update requests defer to
DearMachine while it owns the public launcher. Use `machtiani-dev` for separate
development builds.

No shell startup files are created or edited. Commands live in `~/.local/bin`;
that directory must be in the user's PATH. The installer reports missing commands
or a competing installation and always supplies the absolute launch path. Already
open shells may need a command-cache refresh after package changes.

PATH guidance runs during installation and explicit migration. The native
`dearmachine update` handoff adds package runtime paths internally, so the updater
does not use that PATH to diagnose the user's shell command selection.

For an already-managed installation with a superseded entry in the user's Nix
profile, inspect the exact named entry and then remove it explicitly:

```bash
~/.local/bin/machtiani-installer migrate-profile dearmachine --check
~/.local/bin/machtiani-installer migrate-profile dearmachine
```

Substitute the actual entry name from `nix profile list`. This command requires
working managed launchers, checks that the selected active package provides only
coordinated public commands, and preserves every other profile entry. It does not
edit binaries in the Nix store or configure any shell. It retains a private
`profile-migration-*/migration.json` and a Nix root for the previous profile.
The record includes the exact profile path and previous generation for explicit
`nix profile rollback --profile <path> --to <generation>` recovery. Inspect later
profile changes before rolling back, since that restores the whole generation.
A named version-3 Nix profile is required; older or mixed-purpose packages require
manual migration. Ordinary install/update never silently removes profile entries.

The concierge source reference at
`~/.config/dearmachine/source-reference.json` points to the retained snapshot's
`docs/README.md` and revision. The original checkout can be moved or removed
without losing the concierge's documentation or ability to update.

## Updating

When an installed Concierge opens, it checks for updates and reports the result.
If a release is available, it asks whether to install it; the default is
**Not now**. Declining leaves the current release usable. Check failures or an
unsupported installation channel are reported without installing anything.

Use `/update` in Concierge to check again and choose whether to install.
Natural-language update requests use the same explicit confirmation flow.
After a successful update, Concierge offers to close its old process and
relaunch through the updated managed launcher.

From a terminal:

```bash
dearmachine update --check
dearmachine update
```

`--check` reads the installation receipt and queries the remote default branch.
It reports installed and available revisions without building, changing
configuration, starting the client, or switching the snapshot.

For development candidates held on a local or removable drive, see
[Development updates from local mirrors](local-development-updates.md).
That workflow redirects the recorded Git URLs through user configuration and
covers component mirrors, recursive clones, and release-day cleanup.

An update fetches the selected umbrella revision and its submodules, exports a
new source snapshot, builds the three packages, and checks their executables.
Only then does it stop the managed supervisor, switch the release and source
reference, refresh an already-consented systemd unit, and restart the client
if it was running. A stopped client remains stopped. It preserves model and
provider settings, authentication, inboxes, pairs, client databases, and the
user's service/persistence choices. Reopen an existing concierge session to
use its new runtime and source context.

## Recovery and ownership

When an updater cannot cross a release-layout change and no in-place migration
is available, see [reinstall and restore data](reinstall-with-data-restore.md).
That separate operator procedure requires a verified backup before uninstall;
it is not part of automatic update recovery.

The previous release and its Nix roots are retained. Failed activation restores
the previous release and source reference, and restarts the previous client
when needed. A build failure leaves the active installation running.

An interrupted activation retains `transaction.json`. Restore its previous
release with:

```bash
dearmachine update --recover
```

If the process died while holding `update.lock`, inspect its `owner.json` and
confirm that process is no longer running before removing that stale lock.
Never remove a lock belonging to an active update. If public launchers were
not yet created during interrupted initial acquisition, invoke the retained
installer executable recorded in the transaction to run `update --recover`.
Recovery errors keep the transaction for diagnosis; they are not reported as
a successful update.

An unmanaged installation receives an explicit diagnostic instead of an
implicit migration. Do not rerun guided configuration or overwrite existing
launchers to turn that diagnostic into a fresh installation.
