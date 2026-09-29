// Opt-in live installer instruction check; never sends email or contacts an inbox.
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'

const [runtimeArg, sourceArg, credentialArg] = process.argv.slice(2)
assert.ok(runtimeArg && sourceArg && credentialArg,
  'Usage: node tests/test-email-guidance.mjs RUNTIME SOURCE PRIVATE_ENV_FILE (disposable container only)')
const runtime = resolve(runtimeArg), source = resolve(sourceArg), credentials = resolve(credentialArg)
const { DshAgentSession } = await import(join(runtime, 'packages/dsh-adapter/dist/index.mjs'))
const { saveModelHostProfile } = await import(join(runtime, 'packages/model-host/dist/index.mjs'))
const root = await mkdtemp(join(tmpdir(), 'test-email-guidance-'))
const selection = { provider: 'openrouter', model: 'z-ai/glm-5.3-flash', reasoningEffort: 'high' }
try {
  for (const changed of [false, true]) {
    const home = join(root, changed ? 'changed-pairing' : 'confirmed-pairing')
    await mkdir(home)
    const sender = changed ? 'replacement-sender@example.test' : 'paired-sender@example.test'
    const inbox = changed ? 'replacement-inbox@example.test' : 'machine-inbox@example.test'
    const pairing = join(home, 'confirmed-pairing.json')
    await writeFile(pairing, JSON.stringify({ authorizedSender: sender, inboxAddress: inbox }))
    const profile = join(home, 'profile.json')
    await saveModelHostProfile(profile, { version: 1, driver: 'pi-ai', authMethod: 'api_key', ...selection,
      credential: { kind: 'environment-file', path: credentials, variable: 'OPENROUTER_API_KEY' } })
    let finish, output = '', timer
    const ended = new Promise((resolveTurn, reject) => {
      finish = resolveTurn
      timer = setTimeout(() => reject(new Error('Live test-email instruction timed out')), 180_000)
    })
    const session = new DshAgentSession({ dshHome: join(home, 'dsh'), workspace: source,
      modelProfilePath: profile, outcomePath: join(home, 'outcome.json'), selection,
      environment: { HOME: home, XDG_CONFIG_HOME: join(home, '.config'), XDG_STATE_HOME: join(home, '.local/state'),
        XDG_DATA_HOME: join(home, '.local/share'), MACHTIANI_INSTALLER_CONTRACT: join(source, 'INSTALL.md') },
      onEvent(event) {
        if (event.type === 'assistant') output += event.text + '\n'
        if (event.type === 'turn-end') finish(event)
      },
    })
    try {
      await session.start()
      await session.prompt(`We are at the human test-email gate at the end of Stage 5. All product, backend, and running-client checks have already passed. Use INSTALL.md and the Stage 5 guide for the next instruction; do not repeat completed installation or verification. This is a fixture evaluation: no real email service or product is available to contact. ${changed ? 'Earlier I paired old-sender@example.test with old-inbox@example.test, then explicitly changed both addresses; that change has been applied and confirmed.' : ''} The current confirmed authorized sender is ${sender}, and the current machine inbox is ${inbox}. The non-secret active pairing fixture is ${pairing}. I am ready to send the test email; tell me what to do.`)
      assert.equal((await ended).outcome, 'completed')
      console.log(output)
      const visible = output.replace(/[*`]/g, '').replace(/\s+/g, ' ')
      assert.ok(visible.includes(`Please send a short test email from ${sender} to ${inbox}.`), 'Instruction must give both current addresses in the correct roles')
      assert.match(output, /Tell me when you.ve sent it/)
      assert.ok(!output.includes('old-sender@example.test') && !output.includes('old-inbox@example.test'), 'Instruction must not reuse superseded pairing')
      assert.doesNotMatch(output, /(?:what|which) (?:email )?address.*\?/i, 'Do not ask again for a confirmed address')
      console.log(`${changed ? 'changed' : 'confirmed'} pairing: correct from/to addresses PASS`)
    } finally { clearTimeout(timer); await session.shutdown() }
  }
} finally { await rm(root, { recursive: true, force: true }) }
