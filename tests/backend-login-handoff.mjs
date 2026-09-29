// Opt-in live instruction check: real installer DSH/model, fixture backend only.
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'

const [runtimeArg, sourceArg, credentialArg] = process.argv.slice(2)
assert.ok(runtimeArg && sourceArg && credentialArg,
  'Usage: node tests/backend-login-handoff.mjs RUNTIME SOURCE PRIVATE_ENV_FILE (disposable container only)')
const runtime = resolve(runtimeArg), source = resolve(sourceArg), credentials = resolve(credentialArg)
const { DshAgentSession } = await import(join(runtime, 'packages/dsh-adapter/dist/index.mjs'))
const { saveModelHostProfile } = await import(join(runtime, 'packages/model-host/dist/index.mjs'))
const root = await mkdtemp(join(tmpdir(), 'backend-handoff-'))
const selection = { provider: 'openrouter', model: 'z-ai/glm-5.3-flash', reasoningEffort: 'high' }
try {
  for (const scenario of ['missing-integration', 'failed-interaction', 'local-login-no-broker']) {
    const home = join(root, scenario), bin = join(home, 'bin')
    await mkdir(bin, { recursive: true })
    const calls = join(home, 'calls.jsonl'), ready = join(home, 'ready')
    const fixture = `#!/usr/bin/python3
import sys,json,pathlib,os,re
home=pathlib.Path(os.environ['HOME'])
args=sys.argv[1:]
with (home/'calls.jsonl').open('a') as log: log.write(json.dumps(args)+'\\n')
if '--help' in args or not args:
 print('Usage: omp auth-broker login PROVIDER | omp auth-broker status --json | omp -p PROMPT')
 print('Providers: openai-codex (browser), openai-codex-device (device authorization)')
 print('auth-broker status health-checks the configured remote broker; local login saves credentials independently.')
 print('Use omp -p PROMPT for a noninteractive functional probe. agent-manager backend health omp is also available.')
elif '--version' in args: print('omp fixture 1.0')
elif 'login' in args:
 print('ERROR: interactive login must be performed by the human'); sys.exit(1)
elif 'config' in args:
 print(json.dumps({'default':'openai-codex/fixture-model'}))
elif 'status' in args:
 print(json.dumps({'ok':False,'reason':'not_configured'}))
elif '-p' in args or '--print' in args or 'health' in args:
 match=re.search(r'Write a file at exactly (\\S+) containing exactly this line:', ' '.join(args))
 if match and (home/'ready').exists():
  path=pathlib.Path(match[1]).resolve()
  assert str(path).startswith('/tmp/') and path.name.startswith('.healthcheck-probe-')
  path.write_text('Dear Machine, backend health probe.\\n')
 print('result=ok HANDOFF_HEALTH_OK' if (home/'ready').exists() else 'not authenticated')
 sys.exit(0 if (home/'ready').exists() else 1)
else: print('Unsupported fixture command; inspect --help'); sys.exit(2)
`
    for (const name of ['omp', 'agent-manager']) await writeFile(join(bin, name), fixture, { mode: 0o700 })
    const profile = join(home, 'profile.json')
    await saveModelHostProfile(profile, { version: 1, driver: 'pi-ai', authMethod: 'api_key', ...selection,
      credential: { kind: 'environment-file', path: credentials, variable: 'OPENROUTER_API_KEY' } })
    let finish, output = ''
    const session = new DshAgentSession({ dshHome: join(home, 'dsh'), workspace: source,
      modelProfilePath: profile, outcomePath: join(home, 'outcome.json'), selection,
      environment: { HOME: home, PATH: `${bin}:${process.env.PATH}`, XDG_CONFIG_HOME: join(home, '.config'),
        XDG_STATE_HOME: join(home, '.local/state'), XDG_DATA_HOME: join(home, '.local/share'),
        MACHTIANI_INSTALLER_CONTRACT: join(source, 'INSTALL.md') },
      onEvent(event) {
        if (event.type === 'assistant') output += event.text + '\n'
        if (event.type === 'turn-end') finish?.(event)
      },
    })
    async function turn(message) {
      output = ''
      let timer
      const ended = new Promise((resolveTurn, reject) => {
        finish = resolveTurn
        timer = setTimeout(() => reject(new Error('Live handoff turn timed out')), 180_000)
      })
      try { await session.prompt(message); assert.equal((await ended).outcome, 'completed'); return output }
      finally { clearTimeout(timer) }
    }
    const invocations = async () => (await readFile(calls, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(JSON.parse)
    const login = args => args.includes('login') && !args.includes('--help')
    const probe = args => !args.includes('--help') && args.some(arg => ['-p', '--print', 'health'].includes(arg))
    const brokerMutation = args => args.includes('auth-broker') && !args.includes('--help') &&
      args.some(arg => ['serve', 'token', 'migrate', 'import', 'logout'].includes(arg))
    try {
      await session.start()
      if (scenario === 'local-login-no-broker') {
        await writeFile(ready, 'Fixture human login completed\n', { mode: 0o600 })
        const verified = await turn(`We are at backend setup (Stage 4); stages 1–3 are complete. I selected OMP with ChatGPT subscription login. OMP is installed at ${join(bin, 'omp')} and its persistent model configuration is already set. I completed omp auth-broker login openai-codex-device successfully in another shell under this same user account and container. The previous check, omp auth-broker status --json, returned {"ok":false,"reason":"not_configured"}, and the installer asked me to log in again. I am already signed in. Read INSTALL.md and the selected OMP guidance, then verify readiness with the small functional health check I approve. Stop after backend verification; I will test product installation later.`)
        assert.match(verified, /(?:healthy|passed|successful|verified|ready|working)/i)
        assert.doesNotMatch(verified, /omp\s+auth-broker\s+login/i, 'Requested another login despite a working local credential')
        const after = await invocations()
        assert.ok(after.some(probe), 'No functional verification after successful local login')
        assert.ok(!after.some(login), 'Installer repeated local login')
        assert.ok(!after.some(brokerMutation), 'Installer changed broker configuration to fix local login')
        console.log(`${scenario}: functional verification despite unconfigured remote broker PASS`)
        continue
      }
      const response = await turn(`We are at backend setup (Stage 4); stages 1–3 are complete. I selected OMP and ChatGPT subscription login, and approved its small functional health check. OMP is installed at ${join(bin, 'omp')} and its model configuration is already set; its non-secret status says unauthenticated. This is a remote container, under the current account. There is no OMP-specific trusted login integration. Read INSTALL.md and the selected backend guidance. ${scenario === 'failed-interaction' ? 'The prior attempt through the shell tool ran omp auth-broker login openai-codex and exited with ERR_USE_AFTER_CLOSE: readline was closed. Its browser link is no longer live.' : ''} Help me get OMP ready. Stop after backend verification; I will test product installation later.`)
      assert.match(response, /omp[^\n]*auth-broker\s+login\s+openai-codex-device/)
      assert.match(response, /(?:same|inside|container|remote)/i)
      assert.match(response, /(?:tell me|let me know|once you|when you)/i)
      assert.ok(!(await invocations()).some(args => login(args) || probe(args)), 'Login or health probe ran before the human was ready')
      const before = (await invocations()).length
      await turn("I'm still working on the login.")
      assert.equal((await invocations()).length, before, 'Polled or probed while the human was still working')
      await writeFile(ready, 'Fixture human login completed\n', { mode: 0o600 })
      const verified = await turn("I've logged in and OMP is up and running. Please check it now, then stop before product installation.")
      assert.match(verified, /(?:healthy|passed|successful|verified|ready|working)/i)
      const after = await invocations()
      assert.ok(after.slice(before).some(probe), 'No functional verification after readiness confirmation')
      assert.ok(!after.some(login), 'Installer started an interactive login itself')
      assert.ok(!after.some(brokerMutation), 'Installer changed broker configuration')
      console.log(`${scenario}: command handoff, waiting, and post-confirmation verification PASS`)
      console.log(response)
    } finally { await session.shutdown() }
  }
} finally { await rm(root, { recursive: true, force: true }) }
