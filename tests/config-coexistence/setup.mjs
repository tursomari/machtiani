// Exercise the actual product installer's configuration and model verification
// stages. Stop before pairing: this evaluation owns no inboxes or daemons.
import assert from 'node:assert/strict'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const [runtime, binary, modelHost, endpoint, model, action = 'setup'] = process.argv.slice(2)
const { NativeProductInstaller, SpawnCommandRunner } = await import(join(runtime, 'packages/product-adapter/dist/index.mjs'))
const { saveModelHostProfile, writeApiKeyCredential } = await import(join(runtime, 'packages/model-host/dist/index.mjs'))
const home = process.env.HOME
const configRoot = join(home, '.config/dearmachine')
const credentials = join(configRoot, 'backends.env')
const profile = join(home, '.config/machtiani/model-profile.json')
if (action === 'select-model') {
  await saveModelHostProfile(profile, { ...JSON.parse(await readFile(profile, 'utf8')), model })
  process.exit(0)
}
assert.equal(action, 'setup')
await mkdir(configRoot, { recursive: true })
await writeApiKeyCredential(credentials, 'custom-openai-local', 'managed-fixture-key')
await saveModelHostProfile(profile, {
  version: 1, driver: 'openai-compatible', provider: 'custom-openai-local',
  authMethod: 'optional_api_key', model,
  credential: { kind: 'environment-file', path: credentials, variable: 'MACHTIANI_CUSTOM_OPENAI_LOCAL_API_KEY' },
  customProvider: { kind: 'openai-compatible', scope: 'local', name: 'Coexistence fixture',
    chatCompletionsEndpoint: endpoint, usesApiKey: true },
})
await writeFile(join(configRoot, 'agentmail-api-key'), 'unused-fixture\n', { mode: 0o600 })
const sourceRoot = join(home, 'source')
await mkdir(sourceRoot, { recursive: true })
await writeFile(join(sourceRoot, 'README.md'), '# Disposable source fixture\n')
const stopped = new Error('configuration stages complete')
const executed = []
const commands = new SpawnCommandRunner()
const installer = new NativeProductInstaller({
  home, sourceRoot, workspace: home, journalPath: join(home, 'installation.json'),
  distribution: { sourceRoot, manifestPath: join(home, 'fixture-distribution.json'),
    binaries: { machtiani: binary, modelHost, dearmachine: '/unused', agentManager: '/unused' } },
  runner: { async run(request) {
    if (request.label === 'Verify supplied Dear Machine') throw stopped
    // No mocked command outputs: every preceding command runs the real binary.
    executed.push(request.label)
    return commands.run(request)
  } },
})
try {
  await installer.install({ provider: 'custom-openai-local', model, transport: 'agentmail',
    authorizedSender: 'owner@example.invalid', detectedBackends: ['forge'],
    backend: { id: 'forge', name: 'Forge', executable: '/unused', status: 'ready', summary: 'fixture' } })
  throw new Error('installer crossed the configuration-only boundary')
} catch (error) {
  if (error !== stopped) {
    if (typeof error.privateDiagnostic === 'function') process.stderr.write(JSON.stringify(error.privateDiagnostic()) + '\n')
    throw error
  }
}
assert(executed.includes('Check Machtiani configuration'))
assert(executed.includes('Verify Machtiani model roles'))
assert.equal(JSON.parse(await readFile(join(home, 'installation.json'), 'utf8')).stage, 'provider-verified')
