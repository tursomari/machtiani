# AgentMail Installation Procedure helper

This standalone Go 1.26.8 module provides the narrow AgentMail operations needed by the Installation Procedure transaction harness. It uses `github.com/agentmail-to/agentmail-go` v0.16.0, validates `AGENTMAIL_API_KEY` from the environment, and passes both that key and the trusted production API URL as explicit final client options. Ambient `AGENTMAIL_BASE_URL` and `AGENTMAIL_CUSTOM_HEADERS` settings are cleared and rejected before client construction. The key is never accepted as a command-line argument.

Build and inspect commands with:

```bash
go build ./...
go vet ./...
go run . --help
AGENTMAIL_BASE_URL=http://127.0.0.1:1 AGENTMAIL_CUSTOM_HEADERS='X-Probe: blocked' go run . --self-check-trust-boundary
```

The subcommands are `list-inboxes`, `get-inbox`, `get-organization`, `list-pods`, `create-inbox`, `delete-inbox`, `list-messages`, `list-threads`, `get-message`, `send`, `send-with-attachment`, `get-attachment`, `lists`, `lists-create`, `lists-delete`, and `lists-delete-by-composite`. Run `agentmail-helper --help` for the required flags. Every list operation follows all `next_page_token` values and rejects a repeated token. Inbox creation requires a run-unique client ID, display name, run metadata ID, and receiver/sender role.

Successful commands write exactly one compact JSON value followed by a newline:

- Inbox records include exact ID, address, pod ID, client ID, display name, metadata, and creation time.
- Inbox list: `{"inboxes":[<inbox>,...]}`
- Message records include IDs, addresses, subject, labels, reply linkage, timestamp, text, and attachments for `get-message`.
- Message list: `{"messages":[<message>,...]}` (list entries omit `text`)
- Thread list: `{"threads":[{"thread_id":"...","last_message_id":"...","senders":["..."],"recipients":["..."],"subject":"...","message_count":1},...]}`
- Send: `{"message_id":"...","thread_id":"..."}`
- Send with attachment: `{"message_id":"...","thread_id":"..."}`
- get-attachment emits raw attachment bytes directly to stdout (no JSON).
- List entries include scope, exact scope ID, direction, type, entry, entry type, API list type, read-only state, reason, and creation time.
- List entries: `{"entries":[<list entry>,...]}`
- Delete confirmations contain `"deleted":true` plus the exact inbox ID or exact list composite.

`lists-delete-by-composite` always requires the full `--scope`, `--scope-id`, `--direction`, `--type`, and `--entry` identity. It performs no name lookup or inference. When the harness exports its protected stable inbox ID and address, every mutation command hard-denies those values. Errors are written only to stderr and credential values are redacted.
