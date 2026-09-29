# Installation Procedure Evaluation (IPE) harness

`run.sh` is the sole primary entrypoint for the credentialed Installation
Procedure Evaluation (IPE). Forge is the test subject: it receives the exact
canonical Installation Procedure plus a clearly marked runtime-prerequisites
block, follows the published commands in a fresh source-only container, and
must leave a healthy DearMachine client configured with only the `forge`
backend.

The host-side runner owns the whole transaction. It creates the source-only context, builds the pinned Forge image and typed AgentMail helper, snapshots remote state, provisions temporary infrastructure, observes the live exchange, verifies the container and agent evidence, and performs exact journal-driven cleanup. The container never provisions or deletes AgentMail resources.

## Credentials

Create an ignored `.secrets` file at the umbrella repository root with exactly these names and literal runtime values:

```text
DEEPSEEK_API_KEY=<value>
AGENTMAIL_API_KEY=<value>
```

The file must be a regular, non-symlink file owned by the current user, mode `0600`, with one LF-terminated assignment per line. Blank values, duplicate or unknown names, malformed lines, carriage returns, and NUL bytes are rejected. The file stays in place after a run and must never be committed.

Docker, `flock`, Git, Go with the required module already in its local cache, and
Python 3.11 or newer are required on the host. A live run also requires clean
umbrella and submodule worktrees, with all three submodules detached at the exact
umbrella gitlinks. When a stable host DearMachine client is running, its exact
PID/start time/configuration and inbox identity are snapshotted but never mutated.
Without a discoverable host client, the harness protects the sole existing
AgentMail inbox. If the account has multiple inboxes, set
`IPE_STABLE_INBOX_ADDRESS` to the exact existing inbox address to protect; the
harness verifies that identity before creating any resources. This supports
remote test hosts without installing a host client. An explicit address must
match any discovered host client's inbox. The full account baseline comparison
and journal-driven cleanup remain in force.

The default profile remains DeepSeek V4 Flash at high reasoning. The focused
OpenRouter regression profile takes its credential from the environment and
uses GLM 5.3 Flash at medium reasoning for both the installer agent and the
installed runtime:

```bash
OPENROUTER_API_KEY=... \
IPE_LLM_PROFILE=openrouter-glm-5.3-flash-medium \
tests/e2e-installation-procedure/run.sh
```

The OpenRouter credential is never accepted as an argument or written into the
source snapshot. It receives the same transcript scanning and cleanup treatment
as the two credentials in `.secrets`.

Use `IPE_LLM_PROFILE=openrouter-glm-5.3-high` to run both the installer agent
and installed runtime with OpenRouter `z-ai/glm-5.3` at high reasoning.

Use `IPE_LLM_PROFILE=deepinfra-glm-5.3-flash-high` with `DEEPINFRA_API_KEY`
in the environment for DeepInfra `zai-org/GLM-5.3-Flash` at high reasoning.
Both Forge and the shared model profile use DeepInfra's OpenAI-compatible
endpoint. Forge 2.13.21's generic adapter drops reasoning effort, so the fixture
overrides its `requesty` wire adapter with DeepInfra's endpoint and credential
source; no traffic goes to Requesty. Postconditions verify that override.
The credential stays in private runtime files and receives the same
transcript redaction and cleanup as the other provider keys.

Set `IPE_SENDER_TRANSPORT=openmail` and provide `OPENMAIL_API_KEY` in the
environment to use one temporary OpenMail sender and one temporary AgentMail
receiver. This needs only one free inbox slot on each provider. The installed
client still uses AgentMail, and the same installation, reply/thread, attachment,
database, and backend assertions run. The OpenMail key stays on the host.
The sender helper records its creation intent and exact identity in the private
run directory, creates only inbox-scoped pair permissions, and verifies its
inbox and policy baseline after cleanup. It never deletes pre-existing inboxes.
Run its offline ownership checks with:

```bash
python3 tests/e2e-installation-procedure/openmail-sender-test.py
```

## Fresh local IPE worktree

When the umbrella gitlinks are unavailable from their public remotes, create the
detached IPE worktree from the local umbrella checkout and initialize its
submodules from that same local source. Do not use `git submodule update --init`
first: it may try a public remote that cannot serve the pinned commit.

```bash
git -C <local-umbrella-checkout> worktree add --detach <ipe-worktree> <revision>
cd <ipe-worktree>
scripts/submodules-from-local.sh --source <local-umbrella-checkout>
git submodule status --recursive
```

The helper accepts only an absolute local source path, reads its initialized
submodule object stores without changing them, and checks out every submodule
at the exact gitlink recorded by the IPE worktree. It does not fetch from public
remotes.

## Run

Run the gates in this order from the umbrella repository:

```bash
scripts/verify-installation-procedure.sh
tests/e2e-installation-procedure/run.sh
```

The uncredentialed local smoke path exercises checkout/gitlink validation, archive-only context construction, forbidden-state checks, the stable lock, and empty cleanup without reading `.secrets`, contacting AgentMail, or starting Docker:

```bash
tests/e2e-installation-procedure/run.sh --self-test
```

The live gate takes a private per-user `flock`, creates a unique run ID, and then:

1. Builds the AgentMail helper with the local module cache and builds the pinned source-only image. Container preflight verifies Forge, the selected exact provider/model/reasoning profile, health connectivity, and snapshot hygiene.
2. Records a normalized, paginated baseline of every inbox and all available inbox, organization, and pod policy scopes, plus the stable host client identity.
3. Proves each complete run-unique inbox tuple is absent, then creates exactly two run-tagged inboxes and five temporary inbox-scoped allow entries. Every intent and exact returned identity/composite is fsync-journaled. In mixed-provider mode, one inbox and two allows belong to the OpenMail sender; its separate durable state owns their cleanup.
4. Gives Forge the published Installation Procedure and the temporary receiver/key-file runtime facts and the prerequisite private shared model profile. Deterministic postconditions verify the forge-only config, both native and DearMachine model-host configurations, unchanged private model/credential selection, entry-point skeleton, pidfile, short poll interval, private log, and live client. The harness then stops the client, changes to an unrelated directory, and invokes plain `dearmachine up`; the second postcondition pass requires an argument-free lifecycle child and the persisted project, entry-point, configuration, poll, and behavior settings.
5. Sends one natural, nonce-bearing attachment request from the temporary sender. The mode—not the email—must direct the shell-agent to use the staged attachment paths and leave reply delivery to Dear Machine.
6. Verifies the same-thread reply and exact attachment, read label, single processed message, SQLite thread/session mapping, empty pending queue, outbound ID, active-child `DEARMACHINE_BACKENDS`, and the Machtiani session trajectory.
7. Rechecks all Installation Procedure postconditions and confirms that the repository status is unchanged.

The Forge stage has a 65-minute outer deadline. Mail observation has a 10-minute deadline, polls every two seconds, and allows 60 seconds of transport grace after local processing completes. A successful run prints `INSTALLATION PROCEDURE EVALUATION PASSED` and exits zero.

This is a real live test. It calls the selected LLM provider, Forge, and AgentMail, creates temporary remote resources, sends email, and can incur provider charges.

## Cleanup and recovery

Cleanup runs on every exit path and preserves the original status. It reconciles the exact owned container from a private durable CID file plus its journaled name and run label, stops and removes only that container, verifies its descendants are gone and the snapshotted host client is unchanged, deletes only journaled policy composites, verifies each journaled inbox's exact run metadata before deletion, and then requires the normalized final snapshot to match the baseline exactly. An unfinished inbox create intent must resolve to exactly one complete run-unique tuple before any deletion begins. The two temporary inboxes and five temporary policies must all be absent.

If exact identity or absence cannot be proven, cleanup stops before further deletion and reports an inconclusive result with the non-secret journal for manual recovery. It never restores remote state, selects targets by name/address/diff, or deletes by inference. Private runtime artifacts are removed only after cleanup and baseline comparison succeed; `.secrets` remains.

Exercise the fake-transport interruption/cleanup safety path independently with:

```bash
tests/e2e-installation-procedure/lib/txn.sh --self-test
```

Run `python3 tests/e2e-installation-procedure/fixture-test.py` for the offline model-profile and clean-checkout regressions. Installation failures retain sanitized transcripts and exact postcondition diagnostics under `/tmp/machtiani-ipe-failure-<run-id>.*`, independently of resource cleanup.
