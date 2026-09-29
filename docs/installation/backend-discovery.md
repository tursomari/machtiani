# Finding an installed backend

Use this local inspection during installation and after reopening the concierge.
No provider request or sign-in is part of discovery.

Start with `command -v` for the selected command (or catalogue commands during
initial discovery). A lookup failure means the command is not visible in this
shell, not that its installation disappeared. Before declaring it missing,
check executable files at known locations: `$HOME/.local/bin`,
`$HOME/.nix-profile/bin`, and any exact location recorded during setup or
documented by the selected backend's official installer. Do not search
credential stores or recursively scan the entire home. A dangling link or
non-executable file is a broken installation, not a healthy command.

The product launchers include the user-local bin directory and preserve the
inherited `PATH` order. If a tool shell or service has a different PATH, preserve
existing entries and add the verified installation directory for that process.
Use the resolved absolute executable for local diagnosis. Do not reinstall a
backend solely because a new shell cannot find it, and do not silently rewrite
shell startup files or account-wide service settings.

After an authorized installation, verify the executable from a fresh child
process. A one-command export does not change a running supervisor's environment.
For activation, check how the native backend will resolve that path; follow the
backend-management restart/consent boundary if needed. An installed file proves
presence only, not authentication or functional health.
