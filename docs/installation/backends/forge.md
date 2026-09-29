# Selected backend: Forge

Read this file only after the human selects Forge. The permanent contract and
Stage 4 autonomy rules remain in force.

Health-check permission is required before credential setup or the preparation
helper below. Selecting or installing Forge, or naming its desired provider,
model, and reasoning level, is not permission to run a model request. After a
new installation, inspect local setup state and finish missing configuration
as described in Stage 4. Ask the health-check question from `INSTALL.md` before
the first functional request, and wait for the answer. Skip that question only
if the human already explicitly requested the check. When existing setup is a
plausible candidate, check it without loading a staged key and diagnose the
result before changing authentication. Do not make a predictably failing
request solely to prove a known missing configuration.
The preparation helper itself makes a model request; do not use it to bypass
this gate merely because Forge is new or the desired provider is known.
Runtime context exposes its absolute invocation at
`backendPreparations.forge.invocation`, with `supportedVersion` and
`makesProviderRequest` metadata. It is specific to Forge, not a general backend
installer or credential helper. Use the generic typed helper for secure entry.

- Use `forge` as the Dear Machine backend ID.
- Treat the installed `forge` CLI help, provider list, and observed behavior as
  authoritative; do not assume one provider name or login syntax across
  versions.
- The canonical repository is `https://github.com/tailcallhq/forgecode`; the
  official product and documentation origins are `https://forgecode.dev` and
  `https://forgecode.dev/docs/`. Do not install a lookalike or a fork under
  another GitHub owner.
- Honor the wizard's installation method: for Container build or Standard, use the official
  direct installer below without introducing Nix. For a Nix installation, prefer the
  canonical repository's `github:tailcallhq/forgecode#forge` Nix flake and
  inspect its resolved revision and package metadata before installing it.
  Never use `nixpkgs#forge`: that name does not refer to ForgeCode.
- For Standard, or if the official Nix flake is unavailable on the current platform, the
  upstream fallback installer is served from `https://forgecode.dev/cli`.
  Download and inspect it before executing it rather than piping an unseen
  response into a shell.
- If Forge is already functionally healthy, preserve its existing private
  authentication and do not ask the human to log in again.
- Do not inject the credential staged in
  `~/.config/dearmachine/backends.env` into Forge merely because the provider
  uses an environment variable. Forge 2.13.21 was observed importing such a
  credential into its own private credential store during startup, so an
  installer probe could otherwise mutate authentication state without the
  human's permission. During the consented health check, preserve and probe an
  already configured or subscription-authenticated Forge installation first.
  If none is healthy, report that Forge requires configuration; do not set its
  provider or model merely to make the readiness result green.
- Treat provider-environment forwarding as version-specific compatibility that
  must be established explicitly for the installed Forge CLI. Do not ask the
  human to re-enter a credential and never reveal one in output, standard
  input, or a process argument.
- If Forge needs provider authentication, discover the installed CLI's
  supported providers and authentication paths. Ask the human to choose only
  the provider or method that is genuinely unresolved. If they choose an API
  key, invoke the launcher's typed `backend-provider` credential helper with that provider.
  The helper atomically presents trusted masked input and reports
  `saved` or `already-present`; never invoke `forge provider login` through a
  noninteractive shell to collect a key.
- Only after selection, health-check permission, and a diagnosis that
  authentication is needed, use the chosen authentication path. After a
  successful typed credential response, load the registered private environment into Forge only then,
  accept the documented private-store migration, configure the selected model
  if required, and perform the functional probe. Do not describe a credential
  first introduced during this step as an existing sign-in.
- For the verified Forge 2.13.21 + API-key path, use the maintained installer
  helper instead of reconstructing the migration in shell. Invoke the typed
  `backend-provider` credential helper first, before running the Forge preparation helper:

  The launcher supplies the absolute invocation as `backendPreparations.forge.invocation` in
  runtime context; use that command prefix when the helper is not on `PATH`.
  Append the arguments shown below. The helper's provider ID is `openrouter`,
  even though Forge itself spells it `open_router`; the helper translates it.
  Resolve a shorthand model name against the authenticated provider's model
  list. An empty unauthenticated catalogue is not evidence that the requested
  model is unavailable: do not repeatedly query it or invent an explanation.
  Complete the authorized credential setup first. When the human supplied a
  full provider model ID, preserve it and let configuration readback and the
  functional probe establish whether it works. For example, use
  `z-ai/glm-5.3-flash`, not the shorthand `glm-5.3-flash`.

  ```bash
  machtiani-installer-backend prepare-forge-2.13.21 \
    --home "$HOME" \
    --environment-file "$HOME/.config/dearmachine/backends.env" \
    --provider '<selected-provider-id>' \
    --model '<selected-model-id>'
  ```

  If the human requested a backend reasoning level, append
  `--reasoning-effort '<requested-level>'`. The helper sets it and will
  verify its readback before the functional probe; a provider/model receipt
  alone does not verify reasoning. Do not silently retain a default such as
  medium when high was requested. For an already authenticated healthy Forge,
  apply an explicitly requested change with its documented
  `forge config set reasoning-effort` command and verify with
  `forge config get reasoning-effort --porcelain`; do not repeat credential
  migration just to change reasoning. Preserve independent backend preferences
  when the human has not asked to change them.

  The helper refuses any other Forge version, refuses to replace an existing
  `~/.env`, creates the compatibility link only around Forge's own migration,
  removes it on success or failure, performs the functional probe with
  `FORGE_TERM=false`, and returns a non-secret structured receipt. If the
  installed version differs, inspect its current official authentication flow;
  do not force this version-specific helper.

## Custom Chat Completions providers

A missing provider in Forge's built-in list is not a reason to reject the
human's choice or steer them to OpenRouter. Forge 2.13.21 supports custom
Chat Completions providers. Ask only for unresolved endpoint and model choices;
consult the selected service's official API documentation where appropriate.
Keep the wizard's shared model profile unchanged.

The secure `backend-provider` helper accepts an arbitrary plain provider label,
including services absent from its built-in catalogue. A successful response
returns a **non-secret credential reference**: destination file and variable
name. Reuse that reference exactly; never inspect the file or copy its value.
For separate endpoints/accounts, use distinct labels to avoid reusing a key
intended for another service. Existing named providers retain their established
references; custom labels get isolated application-owned variables.

After the required setup and functional-check consent, invoke the maintained
Forge preparation command with these additional arguments:

```bash
machtiani-installer-backend prepare-forge-2.13.21 \
  --home "$HOME" \
  --environment-file '<destination from credential receipt>' \
  --provider '<unique_lowercase_provider_id>' \
  --endpoint '<full Chat Completions URL>' \
  --credential-variable '<variable from credential receipt>' \
  --model '<exact provider model ID>'
```

Forge 2.13.21 drops explicit reasoning effort from custom-provider requests,
even when its configuration readback says `high`. If the human requested a
reasoning level, explain this pinned-version limitation and ask whether to use
provider-default reasoning or another backend. Do not silently downgrade,
pretend the level is honored, or steer them to a different provider without
their choice. The helper rejects `--reasoning-effort` for custom providers
before making changes. Continue without it only if defaults were acceptable
from the start or the human explicitly approves that choice.

The endpoint is the
complete request URL, not just a base URL; it must not embed credentials,
query parameters or fragments. Remote endpoints require HTTPS; loopback HTTP
is supported for local servers. Do not disguise a custom endpoint as a built-in
provider or overwrite the shared OpenAI credential to get past a restriction.

The helper uses the pinned CLI's `~/.forge/provider.json` format, preserves
other provider entries, registers a `machtiani_`-prefixed provider ID to avoid
overriding built-ins, imports only the selected key through Forge's own
private-store migration, and removes its temporary credential surface.
Different existing definitions under that ID are preserved and cause an
actionable error; choose a distinct ID rather than overwriting them.
It sets and reads back the selected model, then performs a real model probe.
Its receipt reports the actual Forge provider ID. The installed backend can
subsequently use Forge's private store without adding a daemon environment file.

Current upstream [custom-provider documentation](https://forgecode.dev/docs/custom-providers/)
may use a different TOML field spelling than the pinned CLI. Use the maintained
version-checked helper here, not an unverified rewrite based on latest docs.

- Confirm the resulting authentication with a functional probe; do not infer
  readiness merely from a successful credential migration or login command.
- Forge can make changes on the human's behalf and will exercise common-sense
  care. Dear Machine asks when authorization is needed.

After Forge is healthy, return to the completion and handoff section of
`docs/installation/04-backend.md`.

## Native Windows

Use the upstream native Windows executable. Forge 2.13.21 in the Windows VM
required the Microsoft Visual C++ x64 redistributable before it could start.
A missing runtime DLL is a dependency failure, not an authentication failure.
Inspect the installed release's prerequisites; obtain permission before a
machine-wide runtime installation or elevation. Git Bash comes with Dear
Machine's runtime. Never introduce WSL solely to run this native backend.

The Chat Completions preparation helper's provider/reasoning restrictions
still apply. A manually verified Anthropic-compatible DeepInfra configuration
is not evidence that the Chat Completions helper supports that same route.
