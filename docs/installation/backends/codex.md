# Selected backend: Codex

Read this file only after the human selects Codex. The permanent contract and
Stage 4 autonomy rules remain in force.

- Present the agent as `Codex`; keep `codex-yolo` as the private Dear Machine
  backend ID.
- Treat the installed `codex` CLI help and observed behavior as authoritative.
- The canonical repository is `https://github.com/openai/codex`; the official
  CLI documentation entry point is
  `https://developers.openai.com/codex/cli/`. Do not install a lookalike or a
  fork under another GitHub owner.
- Honor the wizard's installation method: for Container build or Standard, consult the canonical
  repository and official documentation for a supported direct binary or
  installer, without introducing Nix. For a Nix installation, prefer the
  reviewed `codex-tool` package exposed by the `dearmachine` flake in the
  current umbrella checkout. Resolve the umbrella and submodule paths first,
  then install that absolute local flake path with Nix. This keeps the Codex
  package on the exact `nixpkgs-codex` revision recorded in
  `dearmachine/flake.lock`.
- If that Nix output is unavailable on the current platform, consult only the
  canonical repository and official documentation above for the current
  fallback. The official installer is under the `chatgpt.com` domain. Download
  and inspect an installer before executing it rather than piping an unseen
  response into a shell.
- Reuse a healthy existing ChatGPT subscription login. Do not ask for an API
  key when the functional readiness check already passed through that login.
- If authentication is required, inspect the installed CLI's current login
  help, ask the human about the supported subscription or credential path they
  want, and use a working trusted login integration or Stage 4's manual login
  handoff. Wait for the human to report completion before the functional probe;
  do not start an interactive login through the ordinary shell tool.
- Codex can make changes on the human's behalf and will exercise common-sense
  care. Dear Machine asks when authorization is needed.

## Functional probe

Read `codex exec --help`, not just top-level help, before composing the
noninteractive check. Official [noninteractive documentation](https://developers.openai.com/codex/noninteractive)
uses `codex exec` for a task that finishes without opening the TUI.
In a disposable Git repository, request a harmless short reply with the
configured provider/model. Keep stdin closed and bound the probe duration.
Do not append interactive-only flags such as `--no-alt-screen`, or assume
`--ask-for-approval` is accepted after `exec`; those failed with CLI 0.154.0.
Use only options shown by the installed subcommand. A parse error occurs
before inference and does not establish that authentication is missing.

After Codex is healthy, return to the completion and handoff section of
`docs/installation/04-backend.md` during installation. For a concierge change,
return to `docs/backend-management.md` without restarting installation stages.
