# Claude Code backend

Use this guide only after the human selects Claude Code. Follow the shared
[discovery procedure](../backend-discovery.md) and
[backend management boundary](../../backend-management.md).

The executable is `claude`; Dear Machine's backend ID is `claude`. Detection
and approval are separate: the native catalog requires explicit selection.
The adapter runs headless with `bypassPermissions`, so approved workers can
make changes with the current user's permissions without interactive prompts.

## Inspect and install

Use `claude --version` and `claude --help` to inspect the actual installed
version. For a requested installation, follow the
[official setup guide](https://code.claude.com/docs/en/setup). Its native
installer on Unix is `curl -fsSL https://claude.ai/install.sh | bash`.
On native Windows, download and inspect `https://claude.ai/install.ps1`, then
run it in PowerShell under the ordinary user. Use the supplied Git Bash and
verify `claude.exe` from a fresh process. The normal native installation under
`%USERPROFILE%\.local\bin` is included in Dear Machine's backend search path. Preserve the
selected Container build, Standard or Nix installation method; do not introduce Nix merely to
install this backend. Verify the executable in a fresh child process afterward.

## Authentication and model

In the interactive installer, after the user chooses Claude Code subscription
sign-in, call `authenticate_backend` with `backend: "claude"`. If discovery found
a non-PATH executable, supply its absolute path as `executable`. This displays
the browser link and collects the authorization code in a masked field, using
the backend's own Claude profile. Do not run `claude auth login` through the
ordinary shell tool or ask the human to paste its code into conversation.
Cancellation leaves sign-in incomplete; retry only when the human is ready.
If this integration is unavailable or cannot handle the interaction, follow
Stage 4's manual login handoff using the installed CLI's verified instructions.
Wait for the human to report readiness, then verify; do not fall back to a
blocking shell-tool login or reuse a link from an exited login process.
After sign-in, run the functional probe below. The installer's model is unchanged.

Outside the interactive installer, use the installed CLI's supported
authentication flow and retain its private
credential store. The [CLI reference](https://code.claude.com/docs/en/cli-reference)
documents `claude auth status` and `claude auth login`; inspect the exact
subcommand's help before using it. Login requires the human's authorization.
Never read or print token files, collect a key in chat, or use the Forge-specific
preparation helper for Claude.

The adapter chooses `DEARMACHINE_CLAUDE_MODEL`, then `ANTHROPIC_MODEL`, then
`sonnet`, and passes the selected name verbatim to `--model`. A shared
installer model profile does not automatically configure this backend.
For an API-provider route, use its supported private credential integration
and ensure the worker can resolve it after restart. A one-shell environment
assignment is not persistent setup. Avoid inventing provider compatibility;
verify the intended route with the installed CLI.

## Verify the selected backend

A functional probe makes a provider request. Reuse existing health-check
permission or obtain it through Stage 4, then run in a disposable Git repository:

```bash
DEARMACHINE_BACKENDS='["claude"]' agent-manager backend health claude
```

Require `result=ok` before reporting readiness. Add `claude` to the native
backend configuration while preserving the human's existing choices. Follow
backend management for activation and the actual credential-consumption path.

The [adapter test runbook](../../../dearmachine/dearmachine/runbooks/testing/claude-adapter.md)
describes the stream parser, per-ticket resume, offline tests, and the separate
opt-in container probe. An interrupted stream or provider error must fail the
ticket; assistant progress text alone is not a completed reply.
