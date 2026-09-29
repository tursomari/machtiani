# Agent-operated IXE: behave as the user

This runbook supplements the [IXE contract](README.md). The installation
assistant remains the real, natural-language product. The operator is a second
agent acting through the same SSH terminal a human uses, reading the rendered
screen and deciding the next answer. This is not QSE, a canned answer script,
an internal RPC shortcut, or permission to bypass a broken UI.

## Authority and isolation

- Use clean temporary worktrees, signed incremental commits, source-only IXE
  snapshots, and cached images/binaries. Never push or alter a running human IXE.
- Each operator test uses a fresh disposable container and home. The fixture
  may be `forge` or `none`; the latter tests installing a backend.
- When a human IXE is already running, give the operator campaign its own
  private `TMPDIR` created with `mktemp -d`. Its runner lock, SSH key, and
  temporary files then remain independent. Do not remove or reuse a live lock.
- Use only API-key providers authorized by the human. No subscription login,
  OAuth, device authorization, or copied host provider session. Select the
  requested model and reasoning level from the actual wizard. Do not silently
  substitute a model. If a supplied name is ambiguous, resolve it against the
  provider list and record the exact choice.
- Register approved owner-only single-line key files by alias. Never read keys
  into model context, paste them into chat, put them in command arguments,
  export them to the installation agent's shell, or include them in screenshots.
- Live tests can make model requests, provision disposable inboxes, and send
  email. Journal run-owned resource identities, protect all preexisting inboxes
  and host daemons, and remove only positively identified run-owned resources.
  Use the existing AgentMail transaction/helper contracts for external test-mail
  actions. Do not use the human's permanent inbox as a disposable sender.

## Prepare the private operator

Install the small pinned Python dependencies into a private tooling directory,
reusing pip's cache. Do not install them into the product or the IXE image:

```bash
python3 -m pip install --target /absolute/private/operator-python \
  -r tests/e2e-installation-experience/operator-requirements.txt
PYTHONPATH=/absolute/private/operator-python \
  python3 tests/e2e-installation-experience/operator-test.py
```

The optional real-TUI test also accepts `IXE_OPERATOR_NODE` pointing to the
existing pinned Node executable and `IXE_OPERATOR_TUI_RUNTIME` pointing to the
existing packaged `packages/tui/dist/index.mjs`. It submits only a fake test key
and proves that ordinary text is rejected while the masked field is active.

Launch a private IXE using the documented host runner. Choose its fixture and
the fresh source-compatible Standard bundle. Keep the runner alive. Do not
present its SSH command as the human review session. Create another private
directory with `mktemp -d` for the operator socket, then start:

```bash
PYTHONPATH=/absolute/private/operator-python python3 \
  tests/e2e-installation-experience/operator.py --socket /private/run/operator.sock \
  serve --port <printed-port> --ssh-key <printed-key-path> \
  --credential model=/approved/provider-key-file \
  --credential email=/approved/email-key-file
```

The bridge connects only to `installer@127.0.0.1` over key-only SSH. It writes
no raw terminal log or credential copy. The normal IXE transcript remains the
product's evidence; it must not contain credentials.

## Observe, decide, act, observe

Use the same Python environment and `--socket` for each separate action:

```bash
python3 .../operator.py --socket /private/run/operator.sock screen
python3 .../operator.py --socket /private/run/operator.sock text 'Yes, use Forge.'
python3 .../operator.py --socket /private/run/operator.sock text --no-enter 'OpenRouter'
python3 .../operator.py --socket /private/run/operator.sock key enter
python3 .../operator.py --socket /private/run/operator.sock key escape
python3 .../operator.py --socket /private/run/operator.sock secret model
```

1. Read the current rendered screen, not an old transcript tail. Start with the
   printed curl bootstrap, then run `dearmachine`, as a human would.
2. Understand the actual question and its authority boundary. Choose a visible
   menu item or answer in ordinary language. Do not encode a fixed sequence of
   answers, prompts, or sleeps. Ask clarification when the chosen persona would.
3. `text` enters one ordinary line; `--no-enter` filters a menu before a separate
   key action. `key` exposes only named navigation/control keys.
4. For a credential, confirm which provider/consumer the screen identifies.
   Submit the matching registered alias through `secret`, never `text`.
   The bridge requires the live secure API-key label next to the cursor. It
   first types a random **non-secret** canary without Enter, verifies that only
   bullets render, clears it, and verifies an empty secure field. Only then can
   it type the key and submit. A stale label or failed mask check is a stop.
5. The bridge buffers potential secret prefixes and suppresses output on an
   echoed registered key. Treat any exposure as a failed security test. Stop,
   protect private evidence, assess credential rotation, and fix the cause;
   do not continue or print the offending transcript.
6. Observe the result. Allow real tool/model work to finish, but investigate
   repeated questions, misleading success, unexplained waits, or stalled tools.
   Keep the human informed without publishing private run credentials.

If a bridge request times out or disconnects, its action may already have been
submitted. Request `screen` after the connection is available; do not replay
text, keys, or credentials automatically. A lost reply does not close the
operator's SSH terminal. If SSH or the container itself has ended, retain the
failure evidence and start a fresh evaluation rather than claiming recovery.

Do not send repeated answers while a turn is still working: the installation
assistant may queue them and answer both later. Read the next rendered question
before deciding whether another answer is needed. If testing a deliberate pause
or change of mind, state that boundary naturally and check that the assistant
does not install, authenticate, or provision something after permission was
withheld. A backend recommendation can be tested without authorizing its
installation; a setup helper is not evidence that its backend binary is present.

Do not fix the installation from an out-of-band shell while calling the UX a
pass. Read-only diagnostics can establish the cause; product/guidance fixes go
in the owning worktree with regression tests. Restart a fresh test when a fix
changes the tested runtime or guidance. Repackage existing binaries for
guidance-only updates; do not claim an older bundle tested the new instructions.

## Two complete experience passes

For external email, `operator-mail.py` wraps the existing reviewed Go
`agentmail-helper` using a private `--key-file` reference, never a key argument.
Supply `--state <private-run-directory>/mail.json` and `--helper <existing-helper>`.
Use `init` to journal and provision a sender/receiver pair, `status` for their
non-secret addresses, `send --text 'Please reply briefly to confirm this works.'`
when the installer asks for a human test email, and `messages --content` to verify
the actual reply, including its body rather than only transport acceptance.
Use `--scan-key-file` for any other approved model key so unexpected
echoes are suppressed. The real installer must still select/configure its
receiver and authorization through conversation; do not inject product config.
When finished and the test daemon is stopped, `cleanup` verifies exact run
metadata/client identities and absence from the pre-run baseline before
removing these inboxes and their scoped policies. A partial provisioning intent
is recoverable by the same journal; do not discard that file before cleanup.
This tests an existing disposable mailbox, not creation of a mailbox by the
installation agent; record that distinction in the evidence.
Keep email fixture pairs sequential when the account has limited inbox capacity.
If creation is refused, clean that journal's partial intent before changing the
baseline, finish and clean the previous run, then initialize a new journal. Never
delete an unrelated inbox or upgrade the account to make room.

Use distinct fresh runs and record observations, not just exit codes:

- **Novice, no backend:** follow the welcome and wizard, ask what a backend is
  or ask for a recommendation, accept or decline proposals naturally, install
  the selected supported backend, consent to its functional check, authenticate
  with the authorized API-key provider, and continue through live email.
- **Experienced, backend present:** give concise explicit preferences; expect
  no redundant selection, credential, or consent loops. Choose the existing
  backend, authorize a health check, configure only what is missing, and
  continue through live email with the requested provider/model/reasoning.

In both runs verify secure entry, Escape/back behavior, optional command
visibility, selected-backend-only checks, useful failure explanations, and
clear progress. Healthy state should be reused, not rebuilt or reauthenticated.

Exercise conversational flexibility: in one pass, supply an email address
before choosing a transport; expect acknowledgment and later confirmation of
its intended role, not a silently inferred authorization. In another, provide
several explicit choices naturally in one reply and expect established answers
to be reused. These are behavioral scenarios, not required literal dialogue.
Choose Show commands in one run and summary-only display in the other. Verify
the chosen display survives the installer-to-concierge handoff and reopening;
credential-bearing commands must stay redacted even when commands are shown.
For custom Forge providers, use the documented generic secure credential path
and full Chat Completions endpoint. Test cancellation before retrying. Respect
the pinned Forge custom-reasoning limitation: do not silently relax an approved
external model's reasoning level to obtain a passing live probe.

Then exercise the concierge as that persona: ask what it can do, ask which
inbox is paired, verify status against the actual container, ask it to stop and
restart Dear Machine, and confirm its answer reflects real state. Check that
startup is independently owned and `/quit` is explained as safe. Close and
reopen the concierge; verify the daemon remains running. Decline optional
persistence unless it is specifically in scope. Do not call merely reaching
the concierge a complete pass.

After the first `/quit`, distinguish product exit from IXE postcondition
verification. Both must pass before the post-install exploration shell opens.
Record native status and the daemon PID before quitting and again from that
shell, then invoke `dearmachine` and verify it opens the concierge without a
new installation or authentication wizard. Record this observation separately:
the original installation transcript does not cover the exploration shell.
This proves survival across closing the chat, not SSH logout or reboot; the
IXE deliberately stops its container after exploration ends.

For changes to post-install backend management, add a distinct regression after
reopening: ask to add another backend while preserving the existing one and
its priority. Use an approved provider whose credential is not already staged
to exercise a genuinely new masked entry, cancel once, then retry naturally.
Do not remove a working credential behind the product's back to force that
case. Verify the added backend's provider/model/reasoning and live health;
check that pairing, original backend, shared model profile, and daemon state
remain correct. Reopen once more and confirm the saved credential can be reused
without another key prompt. Preserve private evidence before exiting a
management session, since its temporary DSH workspace is removed on closure.

For backend discovery/setup regressions, include OMP as a newly installed
alternative. Verify it is detected before the readiness question, and that
the assistant owns missing configuration without a deliberately doomed probe.
Use concise combined choices in the experienced pass and ask ordinary setup
questions in the novice pass. Confirm OMP's persistent default model role and
reasoning in a fresh process; the Forge-specific preparation command must not
be used for OMP. Keep the preexisting backend order and shared model untouched.

Exercise the PATH boundary from the post-install shell with a deliberately
minimal inherited PATH: invoke the installed absolute `dearmachine` launcher
with `PATH=/usr/bin:/bin`. This is a test launch condition, not a repair to the
product. Ask whether OMP is installed; it should find the original user-local
binary without reinstallation. Quit and reopen under the same condition.
Check the inbox and authorized sender separately against native status, and
ask whether closing the chat implies logout/reboot survival. Unknown persistence
must remain unknown, not be reported as disabled or guaranteed. Record any
internal planning prose separately from the functional result.

## Evidence, cleanup, and human handoff

Record exact source/runtime revisions, fixture, chosen provider/model/reasoning,
persona, meaningful prompts/responses, live-email proof, observed native state,
failures and fixes, and any untested areas. Keep transient evidence private,
outside version history. Scan retained evidence against approved keys without
printing matches or the keys. Do not commit transcripts, account identifiers,
credential references specific to the operator machine, or disposable URLs.

Scan archived trajectories after decoding compression, not just the bytes of
the tar or compressed file. Inspect regular archive members in memory without
extracting arbitrary paths. Check live-session evidence and final collected
artifacts; a clean visible terminal alone does not establish that internal
model events contain no credentials. Record residual presentation problems
separately from functional passes instead of describing a successful email
round trip as proof that every interaction was polished.

Finish the product UI and its exploration shell normally, then exit SSH. Use
the bridge's `close` action after SSH exits. Let the IXE collect evidence and
stop/remove its own container. Clean up positively journaled external test
resources after stopping the test daemon; preserve the baseline and live human
session. Retained diagnostic containers must be explicitly identified.

Only after both full passes and required fix/retest loops pass, launch a
**fresh** IXE for the human's review using the verified bundle and agreed
fixture. Never hand over the operator's authenticated test session as a clean
review installation. Report genuine blockers instead of claiming a seamless
experience without evidence.

## Adaptive OpenRouter operator

`model-operator.py` drives the existing private terminal bridge by observing
screens and choosing text, key, wait or registered-secret actions. Supply
`--socket`, `--key-file`, `--scenario-file`, `--evidence`, `--model` and
`--reasoning`. For example, choose `--model z-ai/glm-5.3-flash --reasoning high`.
It verifies the returned model ID and retains owner-only evidence. The scenario
should specify the choices and behavioral checks, including changing an earlier
choice through conversation. No installer state or credentials are prefilled.

The operator's final prose is not a passing result: independently verify the
runtime, actual backend work and delivered email, and follow the cleanup and
credential-scan requirements above. Provider failures or the turn limit stop
the run for investigation; do not blindly replay an uncertain action.
