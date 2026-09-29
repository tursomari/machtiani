// Run only in the disposable VM, with an ordinary unconfigured Windows account.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { appendFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

assert.equal(process.platform, 'win32')
assert.equal(process.env.COMPUTERNAME, 'DM-WIN-TEST')
const [fixtureRuntime, source, cache, destination, evidence, mode = 'fresh'] = process.argv.slice(2)
assert.ok(evidence, 'Expected fixture runtime, source, cache, destination, evidence, and optional repeat mode')
assert.ok(['fresh', 'repeat'].includes(mode))
assert.equal(existsSync(destination), mode === 'repeat')
assert.equal(existsSync(join(process.env.USERPROFILE, '.dearmachine')), false)
assert.equal(existsSync(join(process.env.USERPROFILE, '.machtiani')), false, 'Existing Machtiani state selects recovery; use a fresh account')
mkdirSync(evidence, { recursive: true })
const require = createRequire(join(resolve(fixtureRuntime), 'installer/package.json'))
const pty = require('node-pty')
const env = {}
for (const name of ['SystemRoot', 'WINDIR', 'SystemDrive', 'COMSPEC', 'TEMP', 'TMP', 'OS', 'PATHEXT', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'USERNAME', 'USERDOMAIN']) {
  if (process.env[name]) env[name] = process.env[name]
}
env.PATH = `${env.SystemRoot}\\System32;${env.SystemRoot}\\System32\\WindowsPowerShell\\v1.0`
env.TERM = 'xterm-256color'
const executable = join(env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
const child = pty.spawn(executable, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(resolve(source), 'scripts/quick-start.ps1'), '-Cache', resolve(cache), '-Destination', resolve(destination)], {
  name: 'xterm-256color', cols: 120, rows: 40, cwd: resolve(source), env,
})
let output = '', stage = 0, verified = false
const transcript = join(evidence, 'quick-start.ansi')
writeFileSync(transcript, '')
const timeout = setTimeout(() => finish('Quick start did not reach model setup before the deadline'), mode === 'repeat' ? 120_000 : 45 * 60_000)
function finish(error) {
  clearTimeout(timeout)
  child.kill()
  console.log(JSON.stringify({ mode, verified, error }))
  process.exit(error ? 1 : 0)
}
child.onData(chunk => {
  output += chunk
  appendFileSync(transcript, chunk)
  const plain = output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
  if (stage === 0 && plain.includes('Welcome to Dear Machine')) {
    stage = 1
    child.write('\r')
  } else if (stage === 1 && plain.includes('Would you like to see the shell commands')) {
    stage = 2
    child.write('\r')
  } else if (stage === 2 && plain.includes('First, choose the AI service')) {
    try {
      assert.equal(plain.includes('How would you like to install Dear Machine?'), false)
      assert.ok(existsSync(join(destination, 'windows-installation.json')))
      assert.ok(existsSync(join(destination, 'bin/dearmachine.exe')))
      assert.equal(existsSync(join(env.USERPROFILE, '.dearmachine')), false)
      if (mode === 'repeat') assert.equal(plain.includes('Prepare node'), false)
      else {
        const handoff = plain.indexOf('Continue with guided setup')
        assert.ok(handoff >= 0)
        const frames = new Set(plain.slice(0, handoff).match(/⢆⡰|⢎⡠|⢎⡁|⢎⠑|⠎⠱|⠊⡱|⢈⡱|⢄⡱/g))
        assert.ok(frames.size > 2, 'Preparation must animate during quiet work')
        assert.equal(plain.slice(handoff).includes('Preparing Dear Machine'), false)
      }
      verified = true
      finish()
    } catch (error) { finish(error.message) }
  }
})
child.onExit(({ exitCode }) => {
  if (!verified) finish(`Quick start exited before model setup: ${exitCode}`)
})
