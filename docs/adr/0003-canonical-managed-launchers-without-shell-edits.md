# ADR: Canonical Managed Launchers Without Shell Edits

## Date

2026-09-11

## Status

Accepted

## Context

An older Nix profile installation can shadow an updated DearMachine launcher.
Editing bash and zsh startup files to change PATH precedence adds shell-specific
ordering, backup, and recovery behavior while leaving the competing installation
in place.

## Decision

Install managed public commands in `~/.local/bin`. Reinstalling from a newer
committed checkout of the same source updates the existing coordinated Nix
installation through the same activation and rollback path as `dearmachine update`.

Neither the Nix installer nor the curl bootstrap edits shell startup files.
Report missing PATH entries or competing commands with read-only guidance and
an absolute launch path.

Retire superseded installations explicitly through their owning package manager.
For coordinated Nix installations, `migrate-profile <entry> --check` previews
removal; omitting `--check` removes only the validated named entry and retains
its previous profile generation and manifest for recovery. Ordinary install and
update do not remove profile entries automatically. Never modify Nix store binaries.

## Consequences

- Command ownership and replacement work independently of shell startup syntax.
- User startup files and unrelated profile packages remain under user control.
- Users must have `~/.local/bin` in PATH or use the absolute command; existing
  shells may need their command cache refreshed after migration.
- Older or mixed-purpose Nix profile entries require manual migration. Restoring
  a saved profile generation also restores its other entries, so recovery must
  account for subsequent profile changes.

Operational details: [managed Nix installation](../managed-nix-installation.md)
and [Standard installation](../standard-installation.md).
