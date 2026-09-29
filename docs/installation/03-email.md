# Stage 3: email service and authorized sender

The permanent contract in `INSTALL.md` remains in force. The LLM provider stage
must already be complete.

## Goal

Establish the email transport, its private credential, and the exact sender
address that may give Dear Machine work.

Establish the email transport using the message guidance in `INSTALL.md`.
If the human has not already chosen a service, briefly explain that Dear Machine
needs an email service to receive work and send replies, name AgentMail
(US-based), OpenMail (EU-native), and Sendmux as the supported services without
recommending or ranking any of them, and ask which service they want.
Wait for their answer before offering API-key help or opening credential entry.
Never assume a service because it was listed first or because no other service
was mentioned. Consent to install and the AI-provider choice do not select an
email service.

If the human already chose a service, acknowledge and use that choice without
asking again. Ask only about an unresolved choice. If the human supplies an address
instead of a service choice, acknowledge and retain it, briefly distinguish
Dear Machine's inbox service from an authorized sender, and ask for the missing
service choice. Do not repeat the same question without addressing their reply.
When the address's purpose is ambiguous, confirm its intended role before using
it; never infer sender authorization merely from a bare address.

An explicitly stated address role takes precedence over assumptions about the
service. Preserve "my email address" or "the address I will send from" as the
human's sender address, and "Dear Machine's inbox" as the receiving inbox.
Never infer the role from an address domain or claim a service-owned domain
cannot be the human's sender: both addresses may use the same email service.
An explanation of the two roles must not silently swap or relabel supplied
addresses. Clarify only a genuinely unstated or conflicting role, and confirm
sender authorization separately when the human has not granted it yet.

If the human selects AgentMail, show the canonical AgentMail API-key-help
message as its own question unless they already said their key is ready or
the helper has already reported a saved credential. Having an inbox does not
establish that the human has its API key ready. If they want help, guide
them one step at a time using the official AgentMail documentation at
`https://docs.agentmail.to/knowledge-base/getting-api-key`; never ask them to
put the key in chat. If they do not need help, continue without explaining API
keys.

If the human selects Sendmux, explain before credential entry that Dear Machine
needs a Sendmux **Infrastructure key** so it can create the mailbox and install
the sender policy. A mailbox credential and a Sending key are not sufficient
for provisioning. Direct the human to the official Sendmux console at
`https://app.sendmux.ai/` and ask them to create or copy an Infrastructure
key. Dear Machine will keep the mailbox-scoped credential returned by Sendmux;
it does not need a separate Sending key.

## Private credential entry

Invoke the exact `credentialHelper.email` command array supplied in runtime
context, replacing only the selected-transport placeholder (for example,
`agentmail`). Do not invent helper paths, add a help/status flag, or inspect
its source just to call this documented interface. The helper itself shows
the canonical email-credential message and opens the masked credential field.
Do not duplicate that explanation in chat or describe a separate window:
the secure field appears in this terminal. This field is owned by the local
interaction provider: its value must never enter the ordinary conversation,
model prompt, DSH event stream, transcript, checkpoint, history, diagnostic,
or process arguments.

The local interaction provider passes the submitted value directly to the
credential adapter, which validates one nonempty line without whitespace and
atomically writes only that value to its documented private path. The destination
must be a non-symbolic-link regular file owned by the current user with mode `0600`,
beneath a private directory owned by the current user. The adapter clears the
field, discards the in-memory value, and verifies the private file.
These are adapter responsibilities, not instructions to handle the value yourself.

The credential adapter's success result is the only verification the installer
agent needs. After the adapter succeeds, do not open, read, print, source,
parse, stat, hash, count, or measure the credential file or its contents. Later
commands must receive only the documented credential-file path, never the
credential value.

Once the transport credential is ready, establish the authorized sender.
Reuse an address already explicitly authorized by the human without asking
again. If an earlier address's role is unresolved, ask whether that address
should be authorized rather than requesting it from scratch. Otherwise use
the authorized-sender question from `INSTALL.md`. Never guess an email address
or account identity.

## Optional quote choice

Before this stage ends, ask the Magnifica Humanitas quote question from
`INSTALL.md` once, as its own question, using its exact example quotations.
Retain the answer as `installation.magnificaHumanitas`: true only for an
explicit yes, such as “Yes, please”; otherwise false, including “No, thanks,”
no answer, and any ambiguous reply. If the human already stated a clear choice
earlier, acknowledge it and do not ask again. Do not treat consent to install,
the provider choice, or the authorized sender as an answer.

## Completion and handoff

This stage is complete when the email transport and its credential are
established, the exact authorized sender address is known, and the quote choice
is recorded.

Then read all of `docs/installation/04-backend.md`. Do not read a
backend-specific guide until that stage tells you which one applies.
