# DearMachine guide

DearMachine gives your computer a private email inbox. It receives work through email, runs the agents already installed on your computer, and replies in the same thread while files, credentials, applications, and agent sessions remain local.

## Conversation and local controls

Run `dearmachine` to open the concierge. Type a question or request in ordinary
language, such as “What inbox is configured?” or “Start Dear Machine”. Use
`/help` for local controls and `/quit` to leave the conversation. After a
confirmed native start, the supervisor owns the daemon in the background;
leaving the concierge does not stop it. Login and reboot persistence are
separate settings and must be inspected explicitly.

`dearmachine status` reports the current daemon and supervisor, crash recovery,
the effect of closing this chat, logout uncertainty, and managed startup at login
and after reboot (before login). Each pair has separate `Inbox`, `Authorized
sender`, and `Transport` labels. A service-inspection failure reports `cannot
verify` with its reason; it does not establish that automatic startup is disabled.
Crash recovery can be active without systemd. An intentional stop cancels retries;
failure-limit exhaustion pauses recovery. Startup inspection is read-only and
does not require permission to change configuration.

`dearmachine status --details` adds PIDs, retry counts, service configuration,
saved permissions (not observed state), and a labeled, tab-separated pair table
in this exact order:

| Column | Meaning |
| --- | --- |
| 1 | Pair UUID |
| 2 | Authorized human sender address |
| 3 | Dear Machine inbox address |
| 4 | Email transport |

Read the normal view's explicit labels or the detailed view's header. Older
versions print the table in normal status and may omit the header, but use the
same column order; do not infer address roles from their spelling.

For a question about which addresses are configured, label column 2 as the
authorized sender and column 3 as the inbox. Neither address is a credential.
Do not call the authorized sender Dear Machine's inbox. If more than one pair
is present, identify each pair or clarify which the human means. Read current
status after reopening; do not substitute an address remembered from chat.
`Cannot verify` (or `Persistence: unknown` in older versions) means automatic
startup has not been established, not that it is disabled or saved pairing is
missing. Managed startup claims concern Dear Machine's named systemd user service;
other startup mechanisms are not inspected. Enabled startup is configuration
evidence, not a successful reboot test. Closing the concierge is different from
ending the operating-system login session or rebooting.
For email progress and local session evidence, follow
[live email progress inspection](installation/live-email-progress.md).
To add or configure another agent after installation, follow
[backend management](backend-management.md).

## Prerequisites

- Nix with flakes enabled.
- Credentials for AgentMail, OpenMail, or Sendmux and the paired sender's email
  address.
- `machtiani` and an agent backend such as `codex` installed on `PATH`.

## Install

From the umbrella repository:

```bash
cd dearmachine
nix profile install '.#dearmachine'
command -v dearmachine agent-manager machtiani
dearmachine setup-agents --backend codex
cd ..
```

The backend uses its normal host credentials and is discovered from `PATH`.

## Create and run

```bash
export AGENTMAIL_API_KEY_FILE="$HOME/.config/dearmachine/agentmail-api-key"

dearmachine up --create \
  --email '<your-email-address>' \
  --new-inbox --transport agentmail \
  --project "$HOME/.dearmachine/entrypoint/main" \
  --entry-point-repo "$HOME/.dearmachine/entrypoint/main" \
  --verbose

dearmachine status
```

The first `up --create` initializes Dear Machine's selected workspace for state
and memory management before it mutates the transport. The CLI names this the
entry-point repository. Existing repositories remain unchanged. A custom
`--entry-point-repo <path>` is initialized the same way; `dearmachine init`
remains available for optional preparation.

The example chooses AgentMail, but every transport provisions a new inbox with
the same command shape. Replace only the credential and transport value:

| Adapter | Credential file variable | Inbox flags |
| --- | --- | --- |
| AgentMail | `AGENTMAIL_API_KEY_FILE` | `--new-inbox --transport agentmail` |
| OpenMail | `OPENMAIL_API_KEY_FILE` | `--new-inbox --transport openmail` |
| Sendmux | `SENDMUX_API_KEY_FILE` | `--new-inbox --transport sendmux` |

To share or adopt an existing inbox, replace `--new-inbox` with `--inbox
'<inbox-id-or-address>'` for any adapter. Sendmux uses its Infrastructure key
for mailbox creation and pair policy, then keeps the returned mailbox-scoped
credential in DearMachine's private state for receiving and replying. A
separate Sending key is not required.

Pair creation is the common authorization seam. DearMachine records the exact
sender locally and lets the selected adapter apply provider-side policy when
that provider supports it; there is no DearMachine allow-list environment
variable.

The current alpha backgrounds itself natively; use `dearmachine down` to stop
it and plain `dearmachine up` to restart every registered pair. Systemd and
test containers use `dearmachine up --foreground`.

`dearmachine` supersedes the obsolete `machinemail` command. This release has
no legacy-state import path; new installations use `~/.dearmachine` and create
pairs explicitly.

For more detail, see the [DearMachine README](../dearmachine/README.md), [native installation runbook](../dearmachine/dearmachine/runbooks/native-install.md), [optional container installation](../dearmachine/dearmachine/runbooks/host-install.md), [client operations runbook](../dearmachine/dearmachine/runbooks/operate-entrypoint-client.md), and [runbooks index](../dearmachine/dearmachine/runbooks/README.md).
