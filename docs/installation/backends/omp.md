# Selected backend: OMP

Read this file only after the human selects OMP. The permanent contract and
Stage 4 autonomy rules remain in force.

- Use `omp` as the Dear Machine backend ID.
- Treat the installed `omp` CLI help and observed behavior as authoritative.
- The canonical repository is `https://github.com/can1357/oh-my-pi`; the
  official product and documentation origins are `https://omp.sh` and
  `https://omp.sh/docs`. Do not install a lookalike or a fork under another
  GitHub owner.
- Honor the wizard's installation method: for Container build or Standard, use the official
  direct installer below without introducing Nix. For a Nix installation, prefer the
  canonical repository's `github:can1357/oh-my-pi#omp` Nix flake and inspect
  its resolved revision and package metadata before installing it.
- For Standard, or if the official Nix flake is unavailable on the current platform, the
  upstream fallback installer is served from `https://omp.sh/install`.
  Download and inspect it before executing it rather than piping an unseen
  response into a shell.
- Reuse a healthy existing ChatGPT subscription login or provider
  configuration. Leave provider, model, reasoning, skills, and rules in the
  human's normal OMP configuration unless they ask to change them.
- If authentication is required, inspect the installed CLI's current login
  help, ask whether the human wants to use an available subscription or another
  supported provider, and follow Stage 4's manual login handoff when no working
  trusted login integration is available. Verify readiness after the human
  confirms completion; do not start a blocking `omp auth-broker login` through
  the ordinary shell tool.
- OMP can make changes on the human's behalf and will exercise common-sense
  care. Dear Machine asks when authorization is needed.

## Native Windows installation

Use the canonical [PowerShell installer](https://github.com/can1357/oh-my-pi/blob/main/scripts/install.ps1),
with its binary option, for native Windows. Download and inspect it before
execution. Do not run the Unix installer through Git Bash: that selects a
different platform workflow. The normal native executable is
`%LOCALAPPDATA%\omp\omp.exe`; the Dear Machine launcher adds this location
for child processes. Confirm the installed version and inspect its help.
Use the bundled Git Bash when the backend requests Bash.

Check that an existing OMP `shellPath` still exists before the functional probe.
OMP survives Dear Machine uninstall, so it can retain a path into a removed
release. Preserve a working user-selected shell. If its saved path is missing,
resolve Bash from the current installed distribution, update OMP's shell setting,
and repeat the probe from a fresh process. Do not reuse a release path from an
earlier transcript or mistake a missing shell for a provider authentication error.

Windows does not normally allow an ordinary user to create file symlinks.
Do not enable Developer Mode or elevate just to link `.env` files. For the
default OMP agent directory, use the supplied secure credential helper:

```text
machtiani-installer-credential backend-provider <provider> --omp
```

Substitute the chosen provider label. If the helper already saved that provider,
add `--use-existing` to avoid asking for its key again. This trusted operation
copies only the selected credential into `~/.omp/agent/.env`, applies and verifies
native Windows ACLs before reporting success, and returns a non-secret reference.
Use that receipt's variable in the `models.yml` provider `apiKey` override below.
When replacing the key, use `--omp --replace` to update both stores.

Do not copy credential files with `cp`, `Copy-Item`, or `copy`, or treat Git Bash
`chmod 600` as Windows privacy verification. The helper refuses non-private,
symlinked or unsupported existing `.env` files; preserve those files and resolve
the existing setup with the human instead of overwriting them. It preserves
unrelated simple environment assignments in a private file. Check `omp config
path` first: custom profiles/directories require their supported integration,
not a write to the default directory. Verify from a fresh process; a shell-local
API key assignment is insufficient for startup after sign-in.

## Subscription login handoff

Inspect `omp auth-broker --help` and the installed login help before giving
instructions. If that version advertises `openai-codex-device`, its supported
command may be `omp auth-broker login openai-codex-device`; use the discovered
executable path and verify the provider ID first. Give this command to the
human for their separate shell in the same environment, not to a shell tool.
Browser login can fail with `readline was closed` when stdin is closed. Device
login also waits for the human: capturing its output until the command ends
hides the URL/code until too late. Neither is a reason to keep retrying via
noninteractive tools. Follow the shared handoff and wait for readiness before
verification. Do not copy the installer's ChatGPT credentials into OMP.

Local device login saves credentials for OMP; it does not require a remote
credential broker. `omp auth-broker status --json` checks a configured remote
broker, not local subscription authentication. Its `not_configured` result
does not mean the local login failed. Do not use that result to request another
login, start a broker, or change credential configuration.

After the human confirms login, proceed to the consented functional OMP probe
described below, using the same user account and persistent OMP configuration.
A model listing alone is not proof of authentication. Request another login
only when functional verification reports an authentication failure; distinguish
model-access, networking, rate-limit, and configuration errors before choosing
a remedy. Do not inspect credential files or database contents to prove login.

## API-key configuration references

Consult upstream's [environment reference](https://github.com/can1357/oh-my-pi/blob/main/docs/environment-variables.md)
and [provider reference](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md),
then validate against the installed version. OMP supports `OPENROUTER_API_KEY`.
Its documented environment loading includes the active agent's private `.env`
(normally `~/.omp/agent/.env`); profiles can change that location. Existing
process values take precedence. This can deliver credentials to OMP without
changing Dear Machine's supervisor or enabling systemd.

Use the supplied secure credential helper first. On Windows use `--omp` as
described above. On Linux and macOS, when OMP's private `.env`
does not already exist, a symlink to the helper-owned
`~/.config/dearmachine/backends.env` can reference the saved provider credentials
without reading or copying their values. Do not overwrite an existing file or
symlink, or replace the account-wide `~/.env`. If an existing setup needs a
different integration, preserve it and establish a supported safe path first.
Use the environment-variable name in the credential helper's receipt. Some
providers receive a namespaced variable; loading that variable through `.env`
does not rename it to the variable OMP normally expects. If the names differ,
use the installed version's documented `models.yml` provider `apiKey` override
to reference the receipt's variable name, preserving existing provider/model
settings. A built-in provider can need this override too. Never put the key
value in `models.yml`, guess the helper's variable name, or inspect
`backends.env` to discover it. The reference must resolve through the private
environment integration before starting a fresh OMP process.

Verify with a small live OMP probe from the same kind of working directory
Agent Manager uses; do not assume credential staging proves configuration.

## Persistent provider, model, and reasoning

Finish the private credential-reference integration before querying
provider-specific model catalogues: OMP may hide providers whose credentials
it cannot yet load. An empty catalogue before that setup is not evidence
that the requested provider or model is unsupported. When the human supplies
an exact provider/model ID, a catalogue search is optional; configure that
choice and use the consented functional probe to verify it. Consult the
catalogue or current documentation when resolving an actual ambiguity or error,
not as a mandatory extra setup gate.

This setup was verified with OMP 18.1.16. Check installed `omp config` help
against upstream's [settings reference](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md)
when behavior differs. Do not guess keys such as `defaultModel` or `thinking`.
A model catalogue is not a credential health check: it may be cached or public.
Say that the requested model is listed, not that the API key works, until the
consented functional request succeeds.

Use `omp config path` to identify the active agent directory. Query only the
non-secret setting needed here: `omp config get modelRoles --json`. Merge the
requested default into its existing value and preserve other roles and unrelated
settings. Write the merged JSON object using `omp config set modelRoles`.
Each role value has the form `<provider>/<model-id>:<reasoning-level>`; the
provider model ID may itself contain a slash. For an otherwise empty role map:

```bash
omp config set modelRoles '{"default":"<provider>/<model-id>:<reasoning-level>"}'
omp config get modelRoles --json
```

Substitute the human's exact choices, not literal placeholders. Do not replace
an existing role map with this one-entry example. Omit a reasoning suffix only
when no level was requested and provider defaults are acceptable. If the
chosen model does not support the requested level, explain the limitation;
do not silently downgrade. Do not change the installer's shared model profile.

These controls persist in the active agent's configuration, instead of setting
a one-shot `--model` flag that Dear Machine will not reuse. The Forge-only
`backendPreparations.forge` helper is not used for OMP. Use OMP's private
environment reference above; never print or parse the key.

After health-check consent, run a small `omp --print` functional probe from a
disposable repository in a fresh process, without temporary model/thinking
overrides. Verify the effective provider, model, and reasoning from non-secret
session metadata as well as a successful reply. Configuration readback alone
does not prove what was used. If project settings or environment overrides
disagree, diagnose them without printing secrets before activation. Then
verify OMP through Agent Manager with the complete configured backend list
and a disposable working directory.

For the verified OMP version, the probe's JSONL session under the active agent's
`sessions/` directory records `model_change` and `thinking_level_change` events.
Inspect only those non-secret metadata fields, including `thinkingLevel`, and
the reply's provider/model identifiers. Match the session to the disposable
probe directory and time, rather than assuming the newest unrelated session is
the probe. This establishes the effective client configuration; it is not a
claim about the provider's undisclosed internal computation.
Absence of visible reasoning text is not evidence that high reasoning was
ignored. Do not request or print private reasoning, add arithmetic challenges,
or repeat successful provider calls merely to make reasoning text appear.
Use the original successful probe's metadata. If the installed version differs,
inspect its supported metadata format before considering another bounded probe.

After OMP is healthy, return to the completion and handoff section of
`docs/installation/04-backend.md` during installation. For a concierge change,
return to `docs/backend-management.md`, preserving existing backends and their
priority and obtaining permission before any necessary native restart.
