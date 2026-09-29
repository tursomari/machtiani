# Stage 2: LLM provider

The permanent contract in `INSTALL.md` remains in force. Do not begin the email
or backend stage until this stage is complete.

## Goal

Accept the validated shared model profile that the launcher created after consent. That
single provider, authentication method, model, and reasoning level conducts
this installation and later powers Machtiani for Dear Machine. Do not ask the
human to choose them again and do not invoke a second provider setup wizard.

This working installation conversation is the verification of the launcher's
profile at this point. Use its opaque runtime reference and selected values;
there is no additional inspection, command, or human question in this stage.
Do not run standalone CLI auth or config checks in this stage: Machtiani's
product configuration is deliberately not written until Stage 5, so an
unconfigured CLI is not evidence that the shared provider is broken. Do not
guess model-host status commands or environment overrides, read the private
profile, or create early product configuration to satisfy such a check.

The supported surface is the launcher's complete provider catalogue. It
includes its API-key and enabled subscription providers as well as custom
OpenAI-compatible remote and local providers. The launcher has already
validated a custom endpoint's streaming tool-call and tool-result continuation
before retaining the selection. Do not apply a narrower provider allowlist in
this or any later stage.

The installation conversation already runs through the selected model-host
profile. Configure all Machtiani model roles through the same profile, exact
model, and optional reasoning level. The profile—not a provider-specific
fallback, environment default, or later prompt—is the source of truth for all
model usage in this installation.

Treat the profile as an opaque private reference. Never open, read, print,
source, parse, stat, hash, count, or measure its credential file or an official
runtime's token store. If authentication has expired, ask the human to complete
the launcher's official sign-in flow; never copy subscription tokens into
configuration.

Live provider validation follows installation of Machtiani's model-host
transport. That later check does not permit reordering the stages.

## Completion and handoff

The active conversation and launcher's runtime selection satisfy this stage.
Keep that internal handoff silent; a stage-completion report is not useful to
the human. The installed product's separate live check remains mandatory in
Stage 5 after its model-host transport has been configured.

Then read all of `docs/installation/03-email.md`. Do not read any later stage or
backend guide yet.
