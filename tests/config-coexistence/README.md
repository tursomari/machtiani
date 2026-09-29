# Configuration coexistence evaluation

This umbrella-owned integration check exercises one packaged Machtiani binary
with independent standalone and DearMachine configurations. It supplements the
Installer's complete installed-product QSE; it does not replace that release gate.

Build the pinned native and installer packages on the host:

```bash
coexistence_machtiani=$(nix build ./machtiani-harness#machtiani --no-link --print-out-paths)
coexistence_installer=$(nix build ./dearmachine-concierge --no-link --print-out-paths)
nix develop ./dearmachine-concierge -c python3 tests/config-coexistence/run.py \
  --machtiani "$coexistence_machtiani/bin/machtiani" \
  --installer-runtime "$coexistence_installer/libexec/machtiani-installer" \
  --model-host "$coexistence_installer/bin/machtiani-model-host"
```

Requires Go, Git, Python 3.12+, and Node 24 (or `--node /absolute/path/to/node`).
The DearMachine probe is built from the local component's committed `HEAD` in a
temporary source-only snapshot. Use component revisions matching the umbrella
pins and pass binaries built from those revisions. No host installation, profile,
configuration, daemon, inbox, or Git checkout is changed.

For each of standalone-first setup, DearMachine-first setup, and legacy migration:

- A disposable home exposes exactly one Machtiani executable to both callers.
- Native configuration uses the real native writer. DearMachine setup uses the
  packaged `NativeProductInstaller`, including configuration checks and real
  verification of all four model roles through the packaged model host.
- The installer stops at the boundary before DearMachine pairing and service
  startup. Those stages belong to the full installer QSE. The supplied release
  and public launcher are fixtures; downloading, binary takeover, activation,
  and rollback belong to the existing managed-installation lifecycle suite.
- Standalone `sync` and production DearMachine `AgentRunner.Sync` run repeatedly
  against fresh projects. The latter must override an inherited personal
  `MACHTIANI_CONFIG`. The provider checks the actual model and credential on
  every HTTP request, rather than asking a model to identify itself.
- Both model choices are changed using the native configuration writer and,
  for managed model-host configurations, the production profile writer, then
  exercised again. Config and credential hashes prove each operation preserves
  the other caller's files. The two callers still resolve to the same binary.
- Legacy migration uses production DearMachine startup migration, retains the
  source, copies only referenced credentials, and preserves subsequent choices
  when repeated. The concierge's equivalent migration also has an existing
  installer native-binary integration test.
- Missing managed credentials fail before HTTP, even with matching environment
  variables supplied. Standalone operation continues to work.

The default provider is loopback-only with synthetic credentials and deterministic
responses. A successful run prints three scenario results and a request count.
Temporary homes and the probe build are removed on success or failure.

## Live model variant

To exercise the same paths with real models, add
`--live-profile /absolute/path/to/private-profile.json`. The profile and referenced
key files must be owned regular non-symlink files with no group/other permissions.
The profile format is:

```json
{
  "personal": {
    "endpoint": "https://provider.example/v1/chat/completions",
    "model": "model-a",
    "key_file": "/private/provider-key"
  },
  "managed": {
    "endpoint": "https://provider.example/v1/chat/completions",
    "model": "model-b",
    "key_file": "/private/provider-key"
  }
}
```

Use two distinct OpenAI-compatible model IDs supported at both endpoints: the
test swaps the model choices midway through each scenario. One provider account
is sufficient. The observation server validates independent synthetic credential
references and substitutes the authorized upstream key only when forwarding over
HTTPS. Actual API keys never enter command arguments, child environments, config
fixtures, or retained logs. Redirects are refused. Upstream error bodies are not
retained.

This live variant makes paid model requests using only disposable fixture source;
it does not send email. It adds real-provider compatibility evidence to the
deterministic isolation assertions. It does not evaluate the installation
conversation, email delivery, or backend delegation.
