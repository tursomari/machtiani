# Live email progress inspection

The permanent contract in `INSTALL.md` remains in force. Read this file only
after the human has sent the test email during Stage 5, or when they ask how an
email already being processed is doing. This procedure is inspect-only. Do not
start a second client or poller, send a duplicate test email, or restart active
work merely because it is taking time.

## Native Windows inspection

On Windows, the supplied Node runtime provides SQLite through `node:sqlite`.
Use it in place of the `sqlite3`/Nix commands below; do not install another
runtime or search unrelated directories for SQLite. From native PowerShell in the installation runtime context (where the supplied
`node` is on PATH), substitute only the registered pair UUID:

```powershell
$db = Join-Path $env:USERPROFILE '.dearmachine\pairs\<pair-uuid>\state\dearmachine.db'
@'
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[2], { readOnly: true });
  try {
    console.log(JSON.stringify(db.prepare(`
      SELECT p.message_id, p.thread_id, t.session_id, p.sequence, p.state,
             p.result_kind, p.created_at, p.updated_at
        FROM pending_messages AS p
        JOIN thread_sessions AS t USING (thread_id)
       ORDER BY p.created_at DESC
    `).all()));
    console.log(JSON.stringify(db.prepare(`
      SELECT message_id, thread_id, outbound_message_id, processed_at
        FROM processed_messages ORDER BY processed_at DESC LIMIT 5
    `).all()));
  } finally { db.close(); }
'@ | node --disable-warning=ExperimentalWarning - "$db"
```

These are the same read-only, content-free projections used below. Continue
with the session progress and delivery checks; a running client alone still
does not establish delivery.

## Find the session

First confirm the native client and registered pair:

```bash
dearmachine status --details
```

Read only the non-secret project path from the saved runtime configuration.
Use the pair UUID from `dearmachine status --details` to obtain the active session ID from
the private state database without reading the email body. Use SQLite through
Nix only when it is not already installed:

```bash
project=$(sed -n 's/^project = "\(.*\)"$/\1/p' \
  "$HOME/.dearmachine/config/runtime.toml")
test -n "$project"
db="$HOME/.dearmachine/pairs/<pair-uuid>/state/dearmachine.db"
sqlite=(sqlite3)
if ! command -v sqlite3 >/dev/null; then
  case "${MACHTIANI_INSTALL_METHOD:-nix}" in standard|container) false ;; *) true ;; esac || {
    printf 'The Standard release is missing its supplied SQLite executable.\n' >&2
    exit 1
  }
  sqlite=(nix shell nixpkgs#sqlite --command sqlite3)
fi
session_id=$("${sqlite[@]}" -readonly "$db" \
  'SELECT t.session_id FROM pending_messages AS p
     JOIN thread_sessions AS t USING (thread_id)
    ORDER BY p.created_at DESC LIMIT 1;')
test -n "$session_id"
```

Treat the email body and session goal as private user content. Never run an
unfiltered `machtiani session list --json` or `session show --json` because
those commands include that content. Once the exact ID is known, project only
safe high-level fields before their output can enter the installer transcript:

```bash
set -o pipefail
(cd "$project" && machtiani session show "$session_id" --json) |
  node -e '
    const fs = require("node:fs")
    const value = JSON.parse(fs.readFileSync(0, "utf8"))
    const safe = (({ session_id, turns_completed, updated_at,
      shell_agent_resumable, shell_agent_interrupt_step, model_selection }) =>
      ({ session_id, turns_completed, updated_at,
        shell_agent_resumable, shell_agent_interrupt_step,
        model_selection }))(value)
    process.stdout.write(`${JSON.stringify(safe)}\n`)
  '
```

The projection reports completed turns, last update time, resumability, and
model selection. While a session is active, use Machtiani's
display-only attach mode for a short observation window to see its latest
meaningful activity without changing or resuming the work:

```bash
(cd "$project" && \
  timeout 8s machtiani run --attach --resume <session-id> \
    --focused --no-cursor) || test "$?" -eq 124
```

An exit status of 124 only means the observation window ended. Summarize the
current phase in plain language, such as checking the request, working through
the backend agent, or preparing the reply. Do not relay hidden reasoning,
whole prompts, raw commands, or verbose trajectories.

## Confirm Dear Machine delivery state

Inspect recent client events without printing configuration or credentials:

```bash
tail -n 80 "$HOME/.dearmachine/log/dearmachine.log"
```

When the session-to-message mapping or recovery state remains ambiguous, use
the pair UUID shown by `dearmachine status --details` to query that pair's database. Use
the Nix package only when `sqlite3` is not already available:

```bash
db="$HOME/.dearmachine/pairs/<pair-uuid>/state/dearmachine.db"
sqlite=(sqlite3)
if ! command -v sqlite3 >/dev/null; then
  case "${MACHTIANI_INSTALL_METHOD:-nix}" in standard|container) false ;; *) true ;; esac || {
    printf 'The Standard release is missing its supplied SQLite executable.\n' >&2
    exit 1
  }
  sqlite=(nix shell nixpkgs#sqlite --command sqlite3)
fi
"${sqlite[@]}" -readonly "$db" '
  SELECT p.message_id, p.thread_id, t.session_id, p.sequence, p.state,
         p.result_kind, p.created_at, p.updated_at
    FROM pending_messages AS p
    JOIN thread_sessions AS t USING (thread_id)
   ORDER BY p.created_at DESC;
  SELECT message_id, thread_id, outbound_message_id, processed_at
    FROM processed_messages
   ORDER BY processed_at DESC
   LIMIT 5;
'
```

A pending row means Dear Machine retained the email. `running` plus a live,
advancing Machtiani session proves active work; `updated_at` is a state-change
time, not a heartbeat. A client error identifies a provider or backend error,
but recovery is not proven until the same message maps to resumed activity.
Completion requires the pending row to disappear and either a client
`processed message=` event or one processed row with a nonempty outbound ID.
That proves one outbound reply was accepted by the transport.

## Keep the human informed

Report promptly when the email is detected, when meaningful work begins, when
the phase changes, and when the reply is sent. If no state changes, give a
brief update about once a minute rather than going silent or narrating every
poll. State what Dear Machine is doing in ordinary language and mention the
elapsed time. Report a concrete provider or backend error and the recovery
being attempted; do not call a retry successful until the same message is
advancing again.

If activity and trajectory both stop advancing, use a bounded deadline and
report the last proven state. Ask the human only for an action that genuinely
requires them. Never declare the installation successful solely because the
client is running or the inbox became empty.

When one outbound reply is proven accepted, read all of
`docs/installation/06-always-on.md`. Do not ask another question or issue the
completion report before reading it. A provider, backend, or delivery failure
returns to Stage 5 failure handling instead.
