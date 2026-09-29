# Stage 4: backend discovery, choice, health check, and configuration

The permanent contract in `INSTALL.md` remains in force. Provider and email
configuration must already be complete. Read all of
`docs/installation/backend-catalogue.md` now; it is an advisory index, not a
replacement for inspecting the selected command.

## Goal

Help the human choose a backend, then establish that their choice actually
works. Reuse healthy existing software and authentication. Choosing the
installer's shared model does not select Dear Machine's backend agent.
Track installed, configured, verified, and activated as separate facts;
reuse explicit choices and health-check permission instead of asking again.

## Discover and let the human choose first

Refresh the preliminary executable results from Stage 1. Detection proves only
that a command resolves; it does not prove authentication or functional health.
Follow [backend discovery](backend-discovery.md), including known installation
locations, before offering installation. Detection comes before a readiness
question; do not suggest that an undetected agent is already installed.
Use the canonical installed-backend choice message in `INSTALL.md`, listing
the exact detected user-facing names. Ask even when only one is detected.
Explain that more backends can be added or changed later. In the choice prompt,
explicitly invite the human to name another agent they prefer and offer to help
configure it; do not present the detected or built-in agents as the only choices.
For already-installed candidates not yet selected for setup, do not run help,
status, authentication, or functional probes until the human agrees to the
selected agent's health check. Do not inspect every installed candidate first.

Accept natural-language answers. If the human has already explicitly
named a candidate to use, that is selection consent;
do not ask them to select it again.
A yes to the single-agent offer selects that agent, but a yes to a list of
several agents is ambiguous: ask which one. A no or maybe is not consent;
answer questions, explain the choices, or offer alternatives without probing,
installing, or configuring anything.
Do not silently select or fall back to a different backend.

If none is installed, or the human declines the detected agents, use the
canonical installation offer. Offer the supported backends (Codex, Forge,
OMP, and Claude Code), not just an instruction to install something themselves. The human
may instead name another agent or prefer to handle installation themselves.
Say this in the offer itself, for example: "I can also help configure another
agent you prefer. Let me know." Do not wait for the human to ask whether other
agents are allowed. For an unfamiliar choice, establish compatibility using
the guidance below before promising that it will work.
An explicit answer such as “install Codex” authorizes that installation; an
ambiguous preference does not. Resolve that one consent boundary before acting.

## Check only the selected agent

Selection is not health-check permission. Once the human chooses an installed
agent, use the canonical selected-backend health-check question. Explain that
the check may make a minimal model-provider request. If the human already
explicitly requested that check as part of their choice, do not ask again.
If they decline, leave the backend alone and explain that verification is
required before installation can be reported successful.

After permission, read its one catalogue-linked guide before the first probe,
so authentication side effects and safe probe constraints are known. Then:

1. Inspect the resolved executable, version, and built-in help.
2. Discover safe status, authentication, noninteractive, provider, and model
   controls from its CLI where available.
3. Check existing authentication without printing credential contents.
4. Create a new uniquely named temporary directory; never remove an existing
   directory to make room for a probe. Run a small, time-bounded functional
   probe in its disposable Git repository. The permission to check readiness covers an ordinary minimal
   provider call, but not a login, installation, destructive action, or
   meaningful workspace change. Use a harmless task, not real user work.
5. Report the selected agent's result in plain language.

Do not infer readiness from a config file, credential file, or executable alone.
Resolve ordinary CLI differences yourself rather than asking the human to
interpret help output. If it works, preserve existing authentication; do not
ask for another credential or another selection.
Do not pipe a live CLI into `head` to shorten help or catalogue output: closing
the pipe early can produce SIGPIPE under pipefail and make healthy software
look broken. Read the complete bounded help, use a filter that consumes its
input fully, or capture non-secret output before displaying an excerpt.
Apply any remaining selection-specific configuration from its guide within
the human's authorization.

A compatible credential may already occupy its registered private destination,
but this is not proof that the backend is configured. Some CLIs import
environment credentials into private stores at startup. During the initial
health check, do not invoke the typed `backend-provider` credential helper,
load a staged credential into a backend, configure its provider or model,
or trigger credential migration. For a guide-established side-effect-free
environment path, the health-check permission covers one minimal provider
call. Never pipe a key to the backend, place it in command arguments,
allocate or emulate a terminal, or invoke an interactive login flow during
the health check.

## Diagnose failure and configure the chosen agent

Do not treat every failed health check as missing authentication. Distinguish
missing or expired authentication from connectivity, rate limits, an invalid
model, unsupported CLI behavior, and a broken executable. Explain the actual
failure and recover within scope. Do not ask for a replacement key to fix an
unrelated failure, or silently switch the human's backend or provider.

When authentication is actually needed:

- Reuse a healthy existing sign-in; do not duplicate login or credential entry.
- If the guide or current CLI establishes subscription login support, suggest
  it when the human already has that subscription and offer the supported
  API-key alternative. Use the canonical authentication question when both
  are available. Do not invent subscription support or require a subscription.
- If only an API-key path is known, ask only for an unresolved supported
  provider choice. When the provider is already known, proceed to secure entry.
- For an API key, invoke the launcher's typed `backend-provider` credential helper
  for the chosen provider. The helper itself presents the canonical message
  and immediately opens masked input; do not ask for a secret in chat first.
  Treat `saved` or `already-present` as complete private credential verification.
  Preserve independent provider assignments and the shared model profile.
- After consent, use the selected backend's trusted login integration when
  available and working; the human supplies secrets and completes browser or
  device authorization. Otherwise use the manual login handoff below.
  Never run an interactive CLI login or key prompt through a noninteractive
  shell tool, including browser and device-code flows that wait for the human.
  Configure only the selected backend and the chosen provider/model.
- Repeat the small functional check after fixing the diagnosed problem. The
  original health-check permission covers this ordinary verification retry;
  a materially different operation requires fresh consent.

## Manual login handoff

When there is no working trusted integration for the selected login, or it
fails because interactive input/output cannot be handled, hand control to the
human. This applies to built-in and unfamiliar backends. Do not retry the same
login through `bash`, emulate a terminal, or hide it in a background process.
A link or device code from an exited or timed-out login is not a usable pending
login; do not present it as one or claim that authorization is still waiting.

1. Explain the specific limitation briefly. Inspect the installed CLI's help
   or its official instructions to establish the exact supported login command;
   do not guess flags or provider IDs. This inspection does not start a login.
2. Give a copyable command or the verified interactive instructions for a
   separate terminal on the same machine and under the same user account and
   backend profile used by the installer. For a container or SSH installation,
   explicitly say to use a shell inside that same container or remote machine,
   not the browser computer's local shell. Login should not use `sudo` or `su`.
   Prefer device authorization for a remote/headless context only when the
   installed CLI supports it. The human completes the browser/code interaction
   with the backend itself; never ask them to paste tokens or codes into chat.
3. Ask: "Tell me when you have logged in or otherwise have {agent} up and
   running, and I'll check it and continue." End the turn and wait for the
   human's confirmation. Do not poll, probe, or advance installation while
   waiting. Questions or "still working" are not completion confirmations;
   help as needed and keep the handoff pending.
4. Once the human reports readiness, inspect supported non-secret status and
   run the small functional health check. Reuse existing health-check permission;
   ask for it first if none was given. The human's report alone is not proof of
   authentication or functional readiness.
5. Continue only after verification succeeds. If it fails, explain the actual
   remaining problem and help resolve it, preserving the selected backend and
   completed setup. Do not restart all choices or automatically repeat login.

## Install a missing selected backend

Install it only after the human explicitly asks. This authorizes the ordinary
changes needed for installation, not replacing unrelated configuration or
starting authentication. For a built-in, read its selected-agent guide. Use
the exact canonical repository identity listed in the catalogue. Never
substitute a similarly named package, fork, search result, or advertisement.

Honor the installation method already selected in the wizard. Container build and Standard
installation is Nix-free: use the canonical project's supported direct binary
or official installer route, inspect any downloaded installer before executing
it, and never introduce Nix as a hidden backend dependency. If the only verified
route needs Nix, explain the limitation and ask whether the human wants to
change approach or choose another backend; do not silently change methods.
Prefer the documented Nix source when the human chose Nix and the platform is
supported. Inspect the source, resolved revision, package metadata, and command
before running it. If that source is genuinely unavailable or fails for a
source-specific reason, consult the canonical repository and official
documentation for its current recommended fallback. Explain that fallback and
inspect any downloaded installer. Stop on broad, destructive, or unverifiable
behavior rather than using an unofficial package.

The installation permission covers local version/help inspection and verifying
that the expected executable resolves. Own the remaining setup: a newly
installed executable may have usable preexisting authentication, but it may
also have no provider/model configuration at all. Inspect non-secret setup
state using its documented controls; do not read credential contents.
Do not run a provider request merely to demonstrate a configuration you already
know is missing. Resolve remaining provider/model choices and the supported
login or secure API-key path, then obtain health-check consent before the first
functional request. Explain that you are finishing the setup you just installed,
not asking whether the human has independently configured it.

If existing setup is a plausible candidate, ask for the selected agent's health
check unless already authorized, and preserve it when it works. Compatible
existing shared authentication may be reused with the human's direction;
installation alone never implies a new sign-in or permission to copy auth.
The same meaningful consent boundaries apply to a preparation helper that
makes its own provider request. Do not repeat resolved questions on retries.

## Built-in and unfamiliar agents

Read only the selected built-in's guide:

- `docs/installation/backends/codex.md` for Codex;
- `docs/installation/backends/forge.md` for Forge;
- `docs/installation/backends/omp.md` for OMP; or
- `docs/installation/backends/claude.md` for Claude Code.

Do not read guides for unselected built-ins. The catalogue gives useful hints;
the installed version, official documentation, and observed behavior take
precedence over stale hints. Do not assume an undocumented agent supports the
same authentication or noninteractive controls as another.

If the human names another favorite, explain that you can check whether it can
work with Dear Machine and offer to create an adapter. If they accept, read all
of `dearmachine/docs/custom-backend-guide.md` and investigate its CLI and
official documentation. Establish noninteractive execution, input/output,
exit/error behavior, and supported authentication before claiming compatibility.
Create the smallest stable adapter or wrapper within that guide's contract;
do not modify core product source to invent support. If the CLI is missing,
establish its canonical repository and documentation from official, mutually
consistent sources and obtain installation consent. For a Nix installation,
prefer an official Nix flake or package published by that project; otherwise
use its current recommended direct method. Do not invent an unofficial Nix
package merely to satisfy a preference.

Apply the same choice, health-check permission, diagnosis, subscription/API-key,
and secure-entry boundaries to unfamiliar agents. Never guess a login command
or collect secrets through chat or shell prompts. If the typed credential
helper does not support the selected provider, explain that integration limit
rather than bypassing secure entry. Acceptance of the adapter offer includes
adapter work; do not ask a separate conceptual development-versus-configuration
question. Perform the guide's direct compatibility test after health-check
consent. If Agent Manager verification needs tooling not yet installed,
retain that verification as a Stage 5 completion condition rather than
reordering product installation.

## Completion and handoff

This stage is complete only when the human has selected a backend, its
executable and authentication are established, and a functional health check
passes. Configure only that selected backend. Then read all of
`docs/installation/05-product-and-verification.md`.
