# Uninstall DearMachine

In the installer or concierge, `/uninstall` displays instructions only. In a
separate terminal, run the installed native command:

```sh
dearmachine uninstall
```

Use the absolute installed command if it is not on PATH, normally
`~/.local/bin/dearmachine uninstall`. The command lists the deletion paths and
requires an interactive terminal. Type `UNINSTALL` to confirm. Any other answer,
end of input, or cancellation before confirmation leaves the installation and
running daemon unchanged. There is no `--yes` bypass. A natural-language request
to the concierge must produce these instructions, not execute deletion through
an agent tool.

## Removal scope

After confirmation, the command disables its managed service and stops the
native supervisor, daemon, concierge sessions and owned child processes. It
verifies shutdown before deleting private data. An unconfirmed shutdown aborts
deletion. Once deletion begins it cannot be rolled back; no backup is retained.

Removal includes:

- `~/.dearmachine`, including pair databases and SQLite sidecars, pairing,
  configuration, logs, and the default memory/entry-point workspace;
- UUID-keyed Machtiani session stores referenced by DearMachine-owned
  entry-point and installer workspaces;
- DearMachine's private configuration and credentials under
  `~/.config/dearmachine` and the selected XDG configuration directory;
- DearMachine and installer state, caches, and installer workspace in the
  default and selected XDG locations;
- owned public command links for DearMachine, Agent Manager, Machtiani,
  installer/concierge and model host;
- managed release directories, retained sources and documentation, downloads,
  rollback releases, and installation-local Nix roots.
- its managed service unit and service-specific drop-ins and dependencies.

The native Linux process completes verification after unlinking its own
installation. It creates no cleanup helper. Successful removal exits zero;
failures exit nonzero and identify the blocking operation or remaining path.

Independent Machtiani configuration (`~/.machtiani`, `~/.config/machtiani`),
backend installations and authentication, user-selected external repositories,
remote inboxes/accounts and account-wide user lingering are preserved. The
confirmation describes these boundaries. Shared Nix store contents are not
deleted directly; normal Nix garbage collection reclaims unreferenced packages.
Shared operating-system journals are also preserved. This is local product
removal, not secure erasure or deletion of remote data.

## Installation ownership and recovery

To replace an installation while keeping its user data, prepare a verified
external backup first and follow [reinstall and restore data](reinstall-with-data-restore.md).
Native uninstall itself does not preserve that data or restore the backup.

The command handles coordinated Nix and Standard managed installation layouts,
including partial private state. It rejects substituted roots, unrelated public
commands and concurrent acquisition/update locks. Resolve the reported issue
and rerun; never delete a broad parent directory to bypass a rejection.

If the uninstall process is forcibly interrupted, its `~/.dearmachine/uninstalling`
marker records its PID, and installation-local `update.lock` or `.bootstrap-lock`
directories may remain. Verify that the recorded process and any installer/updater
have exited before removing only those exact stale markers/locks and retrying.
Never clear a lock held by a live operation. Already deleted data is not restored.

Legacy or independently managed installations must be removed through their
owning installation mechanism before final private-state removal. The optional
container stack's [uninstall/reinstall runbook](../dearmachine/dearmachine/runbooks/uninstall-reinstall.md)
describes a separate, state-preserving lifecycle; its `container-uninstall`
command is not this destructive native command.

After a successful removal, a fresh managed installation starts with no old
DearMachine pairing, database, private credentials or concierge model selection.
Personal backend and Machtiani settings, including shared model profiles and
subscription authentication, remain independently usable.

## Verification

See the [container acceptance gate](../tests/uninstall/README.md) for the
credential-free command, fixtures, isolation boundaries and actual coverage.
