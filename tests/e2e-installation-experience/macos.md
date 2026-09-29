# macOS Standard and Nix IXE

This adapter runs the actual installer and concierge through SSH on an existing
Mac or macOS VM. The host can be Linux (including WSL) or macOS. The guest must
have Apple's Command Line Tools, Python 3.9+, and key-based SSH access through
an OpenSSH host alias with a verified host key. Python 3.9+ and Git are required
on the host. No Docker engine is used. Intel and Apple Silicon must be tested
on their respective macOS architectures.

Use a disposable VM/account. A private HOME isolates configuration; it is not a
sandbox for an agent running as that account. This adapter never provisions,
reboots or shuts down the VM, changes SSH settings, mounts host directories,
or seeds credentials. It owns only its journaled temporary directory.

## Prepare and connect

Start from a clean, committed umbrella worktree with its three pinned component
checkouts initialized. The adapter uses the Standard builder's source
snapshot; Git administration, untracked files and host agent state are excluded.
Use a new private state directory for each run:

```sh
run_dir=$(mktemp -d /tmp/macos-ixe.XXXXXX)
tests/e2e-installation-experience/run.sh --macos prepare \
  --ssh-host test-mac \
  --state "$run_dir/state.json"
```

Use `--ssh-config /absolute/private/ssh-config` if the host alias is in a
separate file. The adapter uses normal OpenSSH configuration, including proxy
jumps, but requires batch authentication and strict host-key checking.

Preparation prints a **connect command to run on the same host**. Keep the state
file; it identifies the exact owned guest directory. Connect from a terminal:

```sh
tests/e2e-installation-experience/run.sh --macos connect \
  --state "$run_dir/state.json"
```

The default `native-build` mode builds the installer bootstrap inside the fresh
guest home. In the wizard, verify that Nix is selected by default, then choose
**Standard — Build directly on this Mac.** That runs native product acquisition
before provider configuration. No installation decision or credential is
preselected by the adapter. Downloads/builds may take time; stderr remains
visible in the terminal. The private HOME and short state/socket paths live
under a unique `/private/tmp/dmixe-*` directory.

The SSH terminal is single-use: a disconnect is an interrupted evaluation, not
permission to replay its answers. Inspect/collect what is available, use `stop`,
clean owned external resources, then clean up and prepare a new run. A live
terminal lock prevents collection or cleanup from racing an active session.

## Cached runtime alternative

For a configuration/conversation regression, preparation can clone an existing
native Standard release **on the guest**:

```sh
tests/e2e-installation-experience/run.sh --macos prepare \
  --ssh-host test-mac --state "$run_dir/state.json" \
  --runtime-cache /absolute/mac/path/to/verified-standard-release
```

This mode requires APFS clone support. It copies the latest source/guidance,
creates new launchers, and gives the run its own copy-on-write runtime. The
original cached release is never modified or shared through writable hard
links. Runtime source, package/build inputs and architecture must match;
documentation/test-only changes can reuse binaries. A mismatch requires a new
native build. The mode is recorded as `cached-runtime`: **it does not verify
bootstrap or product acquisition**. No completion marker is fabricated.

## Nix on macOS

Use the same macOS VM, with Nix already installed. This is the Nix package
manager on macOS, not NixOS. First-time system-wide Nix provisioning is outside
this adapter; see [macOS support](../../docs/macos-support.md#first-nix-installation)
for its desktop approval requirement.

```sh
run_dir=$(mktemp -d /tmp/macos-nix-ixe.XXXXXX)
tests/e2e-installation-experience/run.sh --macos prepare \
  --method nix --ssh-host test-mac --state "$run_dir/state.json"
tests/e2e-installation-experience/run.sh --macos connect \
  --state "$run_dir/state.json"
```

Preparation requires clean, initialized recursive submodules. It transfers only
the exact current Git commits and their trees, without history, developer Git
configuration, hooks, untracked files or credentials. It reconstructs private
shallow checkouts and an isolated local source origin for unpublished revisions.
Published updates and fetching from the public origin are not covered.

The private environment exposes the system Nix daemon tools, enables
`nix-command` and `flakes`, and builds the pinned installer bootstrap and
Git/Git LFS/Node tools before marking the session ready. These are declared
prerequisites, not product configuration. Builds may reuse the VM's shared Nix
store. This mode does not measure a cold Nix installation or empty-store build.
No user-wide Nix profile or system configuration is changed.

The real Mac wizard still offers **Nix** and **Standard**. For this evaluation,
keep the default **Nix** choice. Credentials, model, email, backend and product
installation remain for the actual interaction. To evaluate Standard, prepare
a separate Standard session; mixing paths does not satisfy this mode's receipt
and source checks. `--runtime-cache` is incompatible with `--method nix`.

Use the same `collect`, `scan`, `stop` and `cleanup` commands below. Nix evidence
validates the managed receipt, exact recursive source revisions, installed
source content, public launchers and per-release store roots. Cleanup addresses
the test HOME's private supervisor socket through the product's shutdown
protocol; it never kills processes by their shared Nix store binary. Removing
the private root removes this run's profile/release links. Shared store objects
and stale indirect GC registrations are left for ordinary Nix maintenance;
the adapter never runs global garbage collection or removes shared profiles.

## Evaluate the experience

Follow the [operator runbook](operator-runbook.md)'s behavioral checks using the
Mac terminal. Its container provisioning and fixed-user terminal bridge are
Linux-specific; they are not used by this adapter. For an agent-operated
campaign, retain the separate novice and experienced passes and fix/retest
requirements before a fresh human review. A functional email result alone is
not an unassisted IXE pass.

Enter model and email credentials only through the actual masked fields.
Honor the chosen provider, exact model and reasoning level. Use temporary
mailboxes whose ownership is recorded separately, and preserve all pre-existing
mailboxes. The adapter does not guess which provider resources it owns.
The existing AgentMail and OpenMail fixture helpers can manage external test
mail from the host, using their ownership journals.

Verify Back/cancellation, command visibility, useful progress, selected-backend
setup/health, and a real delivered email reply (preferably an attachment with a
unique line). Do not repair configuration from another shell and call the UX a
pass. Apply fixes in source and prepare a new run so the new guidance is tested.

After installation, the adapter records native status and opens an exploration
shell. Run `dearmachine`, check `/status`, `/down`, `/up`, and `/quit`; confirm
closing the concierge leaves the client running and reopening does not repeat
model or credential setup. Decline optional persistence unless specifically in
scope. Actual macOS logout/reboot survival, browser login and uninstall have
separate verification limits. Use `/down` before final exit, then `exit` or
Ctrl+D in the exploration shell.

## Collect, stop, and clean up

After the SSH terminal exits:

```sh
tests/e2e-installation-experience/run.sh --macos collect \
  --state "$run_dir/state.json"
```

`verification.json` records the mode/architecture, installer exit, native
installation/running state, source integrity, pending message count and accepted
outbound replies. This is a **basic functional postcondition**, not a verdict
on conversation quality or proof of delivery to the sender. Record those
observations and the actual sender-side reply separately. A missing reply,
modified source, incomplete installation or active session does not pass.

For optional private conversation/log export, supply all approved API key files
on the **host**, never literal keys:

```sh
tests/e2e-installation-experience/run.sh --macos collect \
  --state "$run_dir/state.json" \
  --key-file /private/approved/model-key \
  --key-file /private/approved/email-key
```

The files must be owner-only. The keys are passed privately on SSH stdin to a
scanner, never put in command arguments, the product environment or evidence.
The scanner checks retained logs and session trajectories, decoding Zstandard
first. Export is refused on any known-key match or if no evidence exists.
The optional `private-trajectories-*.tar.gz` is mode 0600 and contains only the
scanned records, not credential stores. It can still contain private user
content; keep it outside version control. `scan --state ... --key-file ...`
performs the same check without exporting. This detects the supplied values;
it is not a universal secret detector.

If the client was left running, stop it before cleaning external resources:

```sh
tests/e2e-installation-experience/run.sh --macos stop \
  --state "$run_dir/state.json"
```

Clean only external inboxes/policies identified by the fixture's ownership
journal. Then remove the run's guest home, state, temporary credentials and
runtime clone:

```sh
tests/e2e-installation-experience/run.sh --macos cleanup \
  --state "$run_dir/state.json" --external-resources-cleaned
```

That flag asserts that journaled external cleanup is complete (or none were
created); it does not delete mailboxes. Cleanup checks the guest directory's
owner and token, stops only this run's client/idle supervisor, refuses active
sessions or remaining test processes, and preserves the shared VM and other
runs. Partial preparation can be cleaned with the same state file. Private
host metadata/export stays in `run_dir` for review; remove it yourself when no
longer needed. Guest conversations and credential files are gone after cleanup.

If a session explicitly enables native launchd startup, cleanup first disables
that private home's login startup and service through its candidate native CLI.
The CLI checks the exact job and plist ownership; a failure retains the private
home for recovery. Cleanup does not unload any other login agent or log out the
Mac user. A missing service choice on older candidates does not invoke the new
commands. The native service boundary has its own maintained
[launchd lifecycle test](../../dearmachine/tests/macos/launchd-lifecycle.py).
