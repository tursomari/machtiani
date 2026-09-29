# Stage 6: optional always-on operation

Read this file only after the live email reply has succeeded. The permanent contract in `INSTALL.md` remains in force. This stage owns the final human
question and optional host-specific startup setup.

## Ask the final question

Address automatic startup before finishing every successful installation.
Enabling it is optional; explaining whether it is available is not. Crash
recovery while a supervisor is alive is different from starting after reboot.
Closing the chat, account logout, and restarting the computer are also different
events; do not promise survival across one based on observing another.

On native Windows, explain that automatic startup happens after this user
signs in, including after a reboot. It does not run before sign-in or survive
sign-out. Ask whether the human wants that behavior. If authorized, use
`dearmachine down`, `dearmachine persistence on`, then `dearmachine up` and
`dearmachine status --details`. Explain the brief restart first: the existing
client must stop before starting with the changed persistence option. If the
transition fails, restore the ordinary background client when possible and
report automatic startup as unverified. The saved startup entry uses the stable
native launcher. `persistence off` disables future startup without deleting data.
Task Manager's Startup Apps settings can disable the entry; report the observed
configuration rather than claiming an actual reboot test. Never change Windows
services, auto-logon, or the user's sign-in settings. Continue to the completion
report without Linux or macOS service probes.

On macOS, follow the macOS section below and then the completion report.
Do not run the Linux service probes or promise operation before login.

On Linux, first check capability without changing service configuration: a working systemd
user manager and `loginctl` are required, not merely executables on PATH. Use
`systemctl --user show-environment >/dev/null` to probe the manager without
displaying its environment, and `loginctl show-user "$USER" -p Linger --value`
to inspect login-independent startup support. A failed probe means unavailable
or unverified, not permission to install a service manager or alter the account.

When supported and not already established, explain the benefit and ask the
canonical automatic-startup choice from `INSTALL.md`. This is the last question in the
installation. Wait for an explicit yes before service or lingering changes.
Use ordinary language: automatic startup, restarting the computer, and signing
in. Explain systemd or lingering only if asked; permission includes running in
the background before sign-in. Remind the user that the computer must remain
powered on, awake, and connected to the internet to receive and process work.

Reuse an explicit answer already supplied for this choice; do not ask twice.
If an existing startup configuration already provides the requested behavior,
verify and preserve it rather than reinstalling it. Do not change or disable
an existing service merely because the user declines additional setup.

If systemd-user operation is unavailable, do not ask an inapplicable question
or silently skip the explanation. Keep the verified background client running.
For a no-systemd environment such as the IXE container, explain simply:

> Dear Machine is running now, but I can't set up automatic startup in this environment. Don't rely on it starting after the computer or environment restarts. Once it is available again, run `dearmachine up` to start Dear Machine if needed.

Report the observed limitation, not that all restart protection is disabled.
The native supervisor may still provide crash recovery. Account logout survival
remains unverified unless independently established; the no-systemd IXE cannot
prove host reboot behavior.

If the human declines, preserve the verified background client. Where no
automatic startup is configured, explain:

> Dear Machine will keep running for now. I won't set up automatic startup. After restarting your computer, run `dearmachine up` to start it again.

Do not ask why or try to persuade them again. If existing startup behavior is
unknown, say it is unverified rather than claiming it is disabled. In either
case, proceed to the completion report with the relevant manual-start guidance.

## macOS startup at login

Inspect `dearmachine launchd status` and `dearmachine persistence status` first.
A working graphical login session is required. If it is unavailable, preserve
the working client and explain that login startup could not be configured in
this session. Do not install a system LaunchDaemon or request root access.

Explain that Dear Machine can start when the user logs in, including after a
reboot, but stops at logout and does not run before login. Ask the macOS
startup choice from `INSTALL.md`; retain any explicit answer already given.
Declining changes nothing. Do not infer the current startup state from consent.

After explicit approval, explain the brief restart and run:

```bash
dearmachine down
dearmachine launchd on
dearmachine persistence on
dearmachine up
dearmachine status
dearmachine persistence status
```

The native CLI retires only an idle supervisor during the approved ownership
switch. It stores a private service definition and installs its own LaunchAgent
under `~/Library/LaunchAgents` for the login choice. Both Standard and Nix use
the stable installed launcher. Credentials remain in their private files;
never put keys in a plist or capture the shell environment.

Verify the client is running and status reports `Managed startup at login:
enabled`. Explain that this verifies configuration, not an actual logout or
reboot test. Never log out, reboot, or alter unrelated launchd jobs to test it.
If any step fails, report the observed state and use the native status commands
before retrying; do not bypass their ownership or consent checks.

To disable future login startup while preserving the current client, use
`dearmachine persistence off`. To return to ordinary native supervision:

```bash
dearmachine down
dearmachine persistence off
dearmachine launchd off
dearmachine up
```

Report login startup separately from before-login availability, which this
LaunchAgent does not provide. Finish the installation without entering the
Linux section below.

## Enable always-on operation on Linux

A yes answer authorizes the installer to stop the verified background client,
install the persistent native systemd user unit, enable user lingering, start
the unit, and verify it. It does not authorize a container deployment or any
other system service.

Use the native lifecycle commands for both Standard and Nix. They manage the
same supervisor endpoint that the concierge and native status commands inspect.
Do not create a second unit or invoke the legacy native-service helper.
Explain the brief restart, then run:

```bash
dearmachine down
dearmachine systemd on
dearmachine persistence on
dearmachine up
dearmachine status --details
dearmachine persistence status
```

The approved service choice retires the stopped background supervisor before
configuring `dearmachine-concierge.service`. It uses the stable installed launcher
and private saved configuration; credentials must never be copied into the unit.
Do not kill a supervisor or delete lock files to switch ownership.

Verify persistent service enablement (`enabled`, not `enabled-runtime`), an
active service, the same supervisor PID reported by native status, and
`Linger=yes`:

```bash
systemctl --user is-enabled --quiet dearmachine-concierge.service
systemctl --user is-active --quiet dearmachine-concierge.service
systemctl --user show dearmachine-concierge.service -p MainPID -p NRestarts
loginctl show-user "$USER" -p Linger --value
dearmachine status --details
```

A saved yes answer, running PID, or successful command submission alone is not
verification. Do not reboot the computer or log the user out without separate
permission. Distinguish configured persistence from an actual reboot test.

If an earlier installation uses `dearmachine-native.service` or another owner,
inspect that service before changing ownership. Do not install a competing unit
or claim that the concierge controls a foreground daemon it does not own.

If this optional transition fails, inspect the actual state before retrying.
Restore ordinary background operation when possible, report automatic startup
as unconfirmed, and give the exact failed step and recovery action. Preserve the
working pairing, model settings, and credentials. Do not repeat the live email
test or silently declare installation success after a failed service transition.

## Completion

Issue the completion report from `INSTALL.md`. State whether Dear Machine is
running under the persistent user service or as the ordinary background client.
Include the automatic-startup outcome even when the user declined or the
environment cannot support it. When all checks pass, explain simply:

> Dear Machine is set to start when your computer turns on, even before you sign in. I verified that it is running and that automatic startup is configured; I haven't tested a reboot. Keep the computer powered on, awake, and online when you want it to work.

When always-on operation is enabled, include this exact reversible control and
explain that it both stops Dear Machine now and disables its automatic startup:

```text
dearmachine down
dearmachine persistence off
```
