# Add or configure a backend

Dear Machine can use more than one backend. Ask the concierge in ordinary
language to add one, configure its provider, or change the preferred order.
Adding a backend is a scoped change to an existing installation, not a reason
to reinstall Dear Machine or provision another inbox.

## Establish the requested change

Inspect the native status and non-secret device configuration first. Record
the current pairing, running state, backend order, and the requested change.
Preserve the existing backend order unless the human asks to change priority.
Adding an alternative normally appends it; replacing the preferred backend
requires an explicit choice. Do not probe or reauthenticate unrelated agents.

The shared model profile remains unchanged when adding a backend. A backend
has its own provider, model, and reasoning settings. Use explicit preferences;
ask only about unresolved choices rather than silently changing them to match
the concierge's model. A shared sign-in or API key may be reused when compatible,
but its existence does not prove that this backend is configured or healthy.

## Change only the model or reasoning

When the selected backend already works with the requested provider, a model or
reasoning change does not require authentication setup. Read its current
non-secret model selection, preserve the rest of its settings, and change only
the requested fields through its documented persistent controls. For OMP, merge
the requested default into the existing `modelRoles` map as described in its
[guide](installation/backends/omp.md#persistent-provider-model-and-reasoning).

Reuse the working credential integration. Do not inspect credential files or
repeatedly inspect reference syntax, invoke the credential helper, or require a
catalogue lookup when the human supplied an exact model ID. Verify the new
selection with the requested fresh-process functional probe and non-secret
model/reasoning metadata. Investigate authentication only if that probe reports
an authentication failure; distinguish model access and network errors from it.

## Prepare only the chosen backend

Use the [backend catalogue](installation/backend-catalogue.md) to locate the
selected agent's canonical project and guide. Inspect actual executable/help
behavior when those references are incomplete or stale. For an unfamiliar
agent, consult the [custom backend guide](../dearmachine/docs/custom-backend-guide.md).
Do not restart the installation procedure or follow its stage handoff links
for this management request; reuse only the relevant technical instructions.
Use [backend discovery](installation/backend-discovery.md) before saying an
agent is missing or offering to install it. A configured backend disappearing
from PATH after reopening is a discovery problem until inspection shows otherwise.

Install missing software only when requested. Preserve the existing Standard
(Nix-free) or Nix acquisition method; do not introduce Nix silently. Before a
functional probe, obtain the meaningful health-check consent described in the
selected guide unless the human already requested that verification. Run small
probes in a disposable repository, never the product source or memory workspace.
For a backend you just installed, inspect its local version/help and non-secret
setup state first. If provider/model configuration is known to be missing,
finish that authorized setup instead of making a predictably failing request.
Reuse explicit choices and verification permission; ask only for unresolved
choices or new authority. Inspect the exact subcommand's help before using it.

## Credentials stay outside the conversation

The concierge supplies the same typed credential helper as the installer.
Its exact invocation is in runtime context; it need not be on `PATH`. Invoke
the backend-provider helper for the selected provider only when authentication
is needed and the human has requested that setup. It opens a masked field or
reports that a compatible saved credential is already available. For an explicit
replacement request, use `credentialHelper.replaceBackendProvider`; it opens
masked entry even when a key exists, preserves other provider entries, and
explains that all consumers of this reference share the replacement. This is
backend credential storage, not Machtiani provider configuration; follow the
[Machtiani credential flow](machtiani-guide.md#changing-a-provider-credential-through-concierge)
for the harness. Do not repeat
its prompt, ask for a key in chat, print credential contents, or read the file
after the helper has verified it. Cancellation means stop that credential step,
not fall back to chat or an interactive CLI login prompt.

The installer/concierge runtime also enforces a
[credential tool and model boundary](../dearmachine-concierge/docs/credential-security.md).
If credential inspection or output is blocked, use the helper's receipt and
the backend's documented integration; do not retry through another reader or
shell command. This does not block ordinary inbox, backend, or lifecycle settings.

The shared private provider environment file is
`~/.config/dearmachine/backends.env`. The credential adapter preserves other
provider entries. This is a credential reference, not a shell task for the
model to parse or display. Use the backend's documented environment or private
credential-store integration. `backendPreparations.forge` supplies the absolute
invocation only for Forge 2.13.21 and makes a provider request; it is not an OMP
or general preparation helper. Other backends use their own linked guide.
Prefer backend-specific private configuration that the backend loads
itself, so a fresh child can resolve its credential without copying secrets
into the conversation or changing the daemon's launch environment. Inspect
the selected backend's documentation and preserve any existing private files.

The optional native **systemd service helpers** support `--environment-file`;
this is not a flag of ordinary `dearmachine up`. Do not introduce systemd,
persistence, or a replacement supervisor just to deliver a backend key.
A running process does not automatically inherit variables newly added to a
file. Restarting alone cannot fix an environment file that no component loads;
verify the actual credential-consumption path before proposing activation.

Configure the selected backend's normal provider/model/reasoning settings
using its supported controls. See the [native backend configuration reference](../dearmachine/dearmachine/runbooks/native-install.md).
Staging an API key alone is not completed backend setup. If the installed
version has no safe supported credential path, explain that specific blocker;
`/help` supplies lifecycle controls, not an alternative credential-entry flow.

## Verify and activate without replacing the working setup

Verify the new backend's actual model/reasoning selection and functional
health. Add its native backend ID to the device configuration while preserving
all other fields, the existing agents, and their priority. Avoid setup commands
that replace the complete backend list unless the full preserved list is
explicitly supplied and the command's behavior has been checked.

Use the configured complete backend list for Agent Manager, including its
`DEARMACHINE_BACKENDS` environment contract. After deriving
`selected_backends_json` from the device's non-secret `backends` array and
choosing the actual `selected_backend_id`, run from a disposable Git repository:

```bash
DEARMACHINE_BACKENDS="$selected_backends_json" agent-manager backend list
DEARMACHINE_BACKENDS="$selected_backends_json" agent-manager backend health "$selected_backend_id"
```

Keep the complete JSON array on both invocations; standalone Agent Manager
does not infer it from Dear Machine's config file. A list/configuration error
is not a failed provider login. If a native restart is required
to adopt the configuration or credential reference, explain the interruption
and obtain permission unless already authorized. Restart only through the
native Dear Machine command. Inspect status afterward, preserve inbox pairing,
and verify the newly added backend through Agent Manager in a disposable repo.
If the daemon was stopped, do not silently start it just to activate a change.

Report separately what was installed, configured, verified, and activated.
If activation is deferred, say so instead of claiming the running daemon is
already using the change. Explain `/quit` safety after any confirmed start or
restart; background ownership and reboot persistence remain separate.
