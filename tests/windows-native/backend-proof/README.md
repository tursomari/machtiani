# Native external backend proof

Historical backend tranche. The subsequent minimal OpenAI-backed Codex task and native installation gates are recorded in [20 September validation](../RESULTS-2026-09-20.md).

Run only in the disposable `DM-WIN-TEST` Windows guest created for the parent
Windows proof. The scripts expect the ordinary account's `windows-proof`
directory, its portable Git/Node, and the installed Dear Machine bundle under
`%LOCALAPPDATA%\Dear Machine Ω`. Never execute these scripts on the physical
Windows host. Fixtures create files beneath the guest user's Documents folder.

The tested versions are Codex 0.155.1, Claude Code 2.1.278, OMP 18.2.6, and Forge
2.13.21. Codex and Claude were installed using their exact npm package versions
into `windows-proof\backend-proof\npm`, then the native executable directories
were placed on PATH. OMP used the upstream PowerShell binary installer (pin
`-Ref v18.2.6` for replay). Forge used the previously hash-verified Windows
release executable. Forge also required Microsoft's signed x64 Visual C++
redistributable; its installation used the guest administrator, while all
agent tasks ran as the ordinary user. Backend bootstrapping is manual in this
proof, not yet part of the Dear Machine distribution builder.

Copy these fixture scripts into `windows-proof\backend-proof` in the guest.
Provide the authorized DeepInfra key in a private `deepinfra-key` file there;
do not put it in source, arguments, or logs. `common.ps1` reads it into the test
process environment. Configure OMP's `models.yml` with a custom provider
`deepinfra-proof`, API `openai-completions`, base URL
`https://api.deepinfra.com/v1/openai`, API-key reference `DEEPINFRA_API_KEY`, and
model `zai-org/GLM-5.3`. Its model compatibility `extraBody.reasoning_effort` is
`high`. Set `modelRoles.default` to `deepinfra-proof/zai-org/GLM-5.3:high`,
`defaultThinkingLevel` to `high`, and disable `retry.modelFallback`.

Claude's test environment uses DeepInfra's Anthropic endpoint, GLM-5.3 for
its primary/background model slots, and `CLAUDE_CODE_EFFORT_LEVEL=high`.
Forge uses a custom `deepinfra_proof` provider with `response_type=Anthropic`,
URL `https://api.deepinfra.com/anthropic/v1/messages`, and the GLM-5.3 model.
Its isolated configuration lives in `backend-proof\forge-config`, with a
private `.credentials.json`. Run `forge config set model deepinfra_proof
zai-org/GLM-5.3` and `forge config set reasoning-effort high`. The installer’s
existing Chat Completions custom-provider preparation path still rejects high
reasoning; this proof does not change that preparation API.

For each of `claude`, `omp`, and `forge`, run `run-ticket.ps1 -Backend <id>
-Label verified`, then `cancel-ticket.ps1 -Backend <id>`, then `run-ticket.ps1
-Backend <id> -Label recovery`. The file task checks the exact output path,
three independently expected totals, and unchanged input. Cancellation waits
for an actual Node descendant launched by the agent, cancels the ticket, and
requires both worker and child to exit. Recovery means a fresh supervised task
after cancellation, not resuming a cancelled conversation or reboot recovery.

`audited-tasks.ps1` repeats file tasks through a loopback proxy that forwards
requests unchanged to DeepInfra and logs only model, reasoning settings,
protocol, tool count, and HTTP status. It also probes Codex's Responses route.
It does not translate APIs or provide fake model responses. Codex's live task
was blocked by DeepInfra HTTP 404 on `/v1/openai/responses`.

`installer-health.mjs` checks installed discovery and live readiness. Its
`providers.env` requires private Windows ACLs and contains the DeepInfra key
under `DEEPINFRA_API_KEY` and `ANTHROPIC_AUTH_TOKEN`; only the three compatible
backends receive those entries. Run with the environment from `common.ps1`.

Preserve only synthetic inputs/results, ticket metadata, non-secret logs, and
binary hashes. Remove `deepinfra-key`, `providers.env`, and the isolated backend
credential/configuration stores after testing. Shut down the guest. This gate
does not establish production packaging, browser sign-in, full IXE, native
Codex sandbox behavior, or incoming-email-to-backend execution.
