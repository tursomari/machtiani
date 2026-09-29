// Exercise the real packaged agent with a loopback-only, credential-free model.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { readFile } from 'node:fs/promises'

const [runtime, source, home, layout] = process.argv.slice(2)
const { DshAgentSession } = await import(pathToFileURL(join(runtime, layout === 'deployed' ? 'node_modules/@dearmachine/machtiani-installer-dsh-adapter/dist/index.mjs' : 'packages/dsh-adapter/dist/index.mjs')).href)
const { saveModelHostProfile } = await import(pathToFileURL(join(runtime, layout === 'deployed' ? 'node_modules/@dearmachine/machtiani-model-host/dist/index.mjs' : 'packages/model-host/dist/index.mjs')).href)
let requests = 0
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.url, '/v1/chat/completions')
    assert.equal(request.headers.authorization, undefined)
    let input = ''
    for await (const chunk of request) input += chunk
    const body = JSON.parse(input)
    assert.equal(body.model, 'fixture-model')
    const system = body.messages.filter(message => message.role === 'system').map(message => message.content).join('\n')
    assert.match(system, /command lookup failure is not proof of absence/)
    assert.match(system, /Do not describe your internal planning/)
    assert.match(system, /backendPreparations\.forge/)
    assert.match(system, requests < 2 ? /one end-to-end Dear Machine installation/ : /column 2 is the authorized sender; column 3 is the inbox/)
    requests += 1
    const toolResult = body.messages.findLast(message => message.role === 'tool')
    const delta = toolResult
      ? { role: 'assistant', content: 'STANDARD_AGENT_READY' }
      : { role: 'assistant', tool_calls: [{ index: 0, id: 'fixture-shell', type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command: "printf 'STANDARD_AGENT_TOOL_READY\\n'", description: 'Print the harmless portability fixture marker' }) } }] }
    if (toolResult) assert.match(JSON.stringify(toolResult.content), /STANDARD_AGENT_TOOL_READY/)
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    for (const chunk of [
      { id: 'fixture', choices: [{ index: 0, delta, finish_reason: null }] },
      { id: 'fixture', choices: [{ index: 0, delta: {}, finish_reason: toolResult ? 'stop' : 'tool_calls' }] },
    ]) response.write(`data: ${JSON.stringify(chunk)}\n\n`)
    response.end('data: [DONE]\n\n')
  } catch (error) {
    process.stderr.write(`Fixture request failed: ${String(error)}\n`)
    response.writeHead(500)
    response.end(String(error))
  }
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
try {
  const profile = join(home, 'profile.json')
  await saveModelHostProfile(profile, {
    version: 1, driver: 'openai-compatible', provider: 'custom-openai-local',
    authMethod: 'optional_api_key', model: 'fixture-model',
    customProvider: { kind: 'openai-compatible', scope: 'local', name: 'Fixture', usesApiKey: false,
      chatCompletionsEndpoint: `http://127.0.0.1:${server.address().port}/v1/chat/completions` },
  })
  for (const mode of ['installer', 'management']) {
    let resolveTurn, rejectTurn
    const completed = new Promise((resolve, reject) => { resolveTurn = resolve; rejectTurn = reject })
    // The completion can fail while start/prompt is still awaiting its reply.
    completed.catch(() => {})
    let answer = false, tool = false
    const session = new DshAgentSession({
      mode, workspace: home, dshHome: join(home, mode), modelProfilePath: profile,
      outcomePath: join(home, 'unused-outcome.json'),
      selection: { provider: 'custom-openai-local', model: 'fixture-model' },
      environment: { MACHTIANI_INSTALLER_CONTRACT: join(source, 'INSTALL.md') },
      onEvent(event) {
        if (event.type === 'assistant' && event.text.includes('STANDARD_AGENT_READY')) answer = true
        if (event.type === 'tool-end' && !event.failed) tool = true
        if (event.type === 'turn-end') {
          if (event.outcome === 'completed' && answer && tool) resolveTurn()
          else rejectTurn(new Error(`${mode}: incomplete tool/answer turn: ${JSON.stringify(event)}`))
        }
      },
    })
    const timer = setTimeout(() => rejectTurn(new Error(`${mode}: agent smoke timed out`)), (process.platform === 'win32' ? 60_000 : 20_000))
    try {
      await session.start()
      session.whenExited().then(code => rejectTurn(new Error(`${mode}: unexpected exit ${code}`)))
      await session.prompt('Run the harmless fixture shell command and confirm its result.')
      await completed
    } catch (error) {
      process.stderr.write(session.privateDiagnostic().stderr)
      throw error
    } finally {
      clearTimeout(timer)
      await session.shutdown()
    }
  }
  assert.equal(requests, 4)
  await assert.rejects(readFile(join(home, 'unused-outcome.json')), { code: 'ENOENT' })
  console.log('STANDARD_AGENT_OK: installer and concierge startup, model-host, shell round trip')
} finally {
  await new Promise(resolve => server.close(resolve))
}
