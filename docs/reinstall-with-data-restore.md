# Reinstall a managed Nix release and restore its data

Use this procedure when an installed updater cannot cross a release-layout
change and an in-place migration is unavailable. It is an operator recovery
procedure, not an automatic updater feature or the normal way to update.
It covers the native Linux managed Nix installation; do not apply its service
commands to Standard, Windows, or macOS installations.

First distinguish acquisition failures from compatibility failures. A missing
component commit in a development mirror needs a corrected mirror or Git
redirect, not an uninstall. An older updater expecting `machtiani-installer`
cannot prepare a release containing only `dearmachine-concierge`; starting the
new installer against an old receipt can also fail if it requires the new
component name. A fresh installation avoids that receipt transition, but
preserving user data requires the explicit backup and restore below.

## Prepare before uninstalling

The user must choose to uninstall and reinstall while preserving data. Backing
up data does not authorize deletion. The user runs the interactive
[native uninstall](uninstall.md) and confirms it themselves.

Prepare a clean, committed umbrella checkout with all pinned submodules and a
working Nix toolchain before removing the installed software. For development
releases, configure the umbrella **and every component** using
[local Git mirrors](local-development-updates.md). Retain the intended HTTPS
origin as the recorded source identity; Git redirects its transport to the
mirror. A filesystem path or `file:` origin is rejected by the managed installer.
Record the origin privately before uninstall removes the release receipt.

With those redirects configured, choose a fresh directory for the checkout:

```bash
source_url=https://example.invalid/organization/umbrella.git
checkout=/absolute/path/to/fresh-checkout
git -c protocol.file.allow=always clone --recurse-submodules -- "$source_url" "$checkout"
git -C "$checkout" config --get remote.origin.url
git -C "$checkout" remote get-url origin
git -C "$checkout" submodule status --recursive
git -C "$checkout" status --short
```

Replace the example URL and path. The configured origin should retain the
HTTPS identity; the effective URL should resolve to the intended mirror. Each
submodule must match its recorded pin, with no missing or modified checkouts.
The file-transport permission above applies only to this clone. It does not
persist for later updates. Nix may still need to download build dependencies.

## Stop and make a verified private backup

```bash
dearmachine down
dearmachine status --json
```

Confirm the daemon and supervisor report stopped. Also close active work that
could write the state being copied. Do not proceed if another service, container,
or agent is still modifying those databases or session stores.

Choose a private backup directory outside **every** deletion path listed by the
installed uninstaller. A dedicated directory beneath `$HOME/backups` is a
possible choice after checking the actual paths; a directory inside
`$HOME/.dearmachine` is not. Resolve custom XDG locations and symlinks. Avoid
volatile temporary storage for the only copy. Use directory mode `0700` and
private file permissions: the backup includes credentials and message content.

Inventory and preserve these together:

- The DearMachine pair registry, pair databases, authorization and other active
  state databases, and client configuration under `$HOME/.dearmachine`.
- The entry-point workspace and memory, including its project identity files.
  For each owned workspace's `.machtiani/project.uuid`, preserve the matching
  `$HOME/.machtiani/<uuid>` store. Native uninstall removes these referenced
  stores even though it preserves independent Machtiani configuration.
- Private credentials, model selections, model profiles, and backend settings
  under the installation's DearMachine configuration directory. Include both
  default and selected XDG locations if the installation uses them.
- Required installer-owned workspace/session state, and the previous startup
  preferences. Record those preferences for recreation; do not reuse old units.

Resolve active database paths from the pair registry and configuration, rather
than assuming there is only one `dearmachine.db`. Use SQLite's backup API or
`.backup` to create each database snapshot; a raw copy of a live database can
miss committed WAL data. Verify every snapshot with `PRAGMA integrity_check`.
Normalized SQLite backups do not need the original WAL, SHM, or journal files.

Write a private manifest mapping backup files to their original paths, with
SHA-256 checksums, database integrity results, and any omissions. Verify the
copied files against it. Review symlinks: a link into a directory uninstall will
delete does not preserve its target. Preserve needed data targets separately;
record obsolete executable links for exclusion during restore. Keep receipts
and source references only as diagnostic records, not as restoration inputs.
Do not uninstall until this backup is complete and verified.

## Remove the old installation and install the new release

If native uninstall reports that `dearmachine-stack.service` needs its owning
lifecycle removal, inspect the service and container state. Follow the
[optional container lifecycle runbook](../dearmachine/dearmachine/runbooks/uninstall-reinstall.md)
to remove those artifacts first. From the DearMachine component checkout its
command is `nix run .#container-uninstall`. It preserves mutable data; it is
separate from the destructive native uninstall. Do not delete the unit merely
to bypass the ownership check.

The user then runs `dearmachine uninstall` and confirms the displayed paths.
After it succeeds, install software from the prepared umbrella checkout:

```bash
cd "$checkout"
nix run ./dearmachine-concierge -- install --source-root "$PWD"
```

Keep the client stopped. Do not launch guided configuration or create replacement
pairs before restoring the existing pair registry and data.

## Restore data while retaining the new installation

Verify the new managed receipt and source reference identify the intended
release. Record their checksums before restoring files, then confirm they remain
unchanged afterward. Restore only the reviewed data set, with original private
permissions. Stop and reconcile any unexpected existing destination files
instead of silently overwriting a newly configured installation.

Restore the pair registry, matching pair and authorization databases, client
configuration, entry-point memory and matching UUID session stores together.
Restore needed credentials and model/backend settings. Check their referenced
paths against the new installation and the independent backend installations.
Do not assume every old absolute executable path is still valid.

Do not overlay old release receipts, managed launchers, binaries, Nix roots, or
the new `source-reference.json`. Exclude old PID files, sockets, locks, uninstall
markers, supervisor runtime state, service units, and installer checkpoints.
Do not restore obsolete container runtime configuration as native settings.
Retain diagnostic material in the backup rather than activating it.

Verify restored checksums and database integrity before starting. This procedure
does not make incompatible data schemas compatible or provide a downgrade path;
if the new version rejects restored data, keep it stopped and retain the backup.

Recreate previously authorized service choices using the new CLI. On Linux,
`dearmachine systemd on` selects the managed user service, and
`dearmachine persistence on` enables its startup persistence. Apply only the
choices the user previously enabled or explicitly requests now; do not infer
new consent from reinstalling.

```bash
dearmachine up
dearmachine status --json
dearmachine update --check --json
```

Confirm both supervisor and daemon are running, intended persistence is observed,
all restored pairs begin polling, and fresh logs show no startup or authentication
errors. Old log entries are not evidence of a new failure. A successful update
check confirms only the remote revision, not future build or schema compatibility.
End-to-end message delivery requires a separately authorized test.

The user can now open `dearmachine` to use the new concierge. Retain the verified
backup until restoration is accepted; neither reinstall nor this procedure
automatically deletes it. Keep backup manifests, machine-specific paths,
credentials, and runtime evidence out of version control.
