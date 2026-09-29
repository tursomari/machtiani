// ConPTY test driver. Run only inside the disposable native Windows VM.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { writeFileSync } from 'node:fs'
assert.equal(process.platform, 'win32')
assert.equal(process.env.COMPUTERNAME, 'DM-WIN-TEST')
const [release, executable, mode, evidence] = process.argv.slice(2)
const require = createRequire(join(release, 'runtime/installer/package.json'))
const pty = require('node-pty')
const args = mode === 'uninstall' || mode === 'cancel-uninstall' ? ['uninstall'] : []
let output = '', answered = false
const child = pty.spawn(executable, args, { name: 'xterm-256color', cols: 100, rows: 32, cwd: process.env.USERPROFILE, env: { ...process.env, TERM: 'xterm-256color' } })
const timeout = setTimeout(() => { writeFileSync(evidence, output); child.kill(); process.stderr.write('Product did not exit before terminal deadline\n'); process.exit(1) }, 90_000)
child.onData(chunk => {
  output += chunk
  const plain = output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
  if (!answered && (mode === 'uninstall' || mode === 'cancel-uninstall') && plain.includes('Type UNINSTALL')) {
    answered = true
    child.write(mode === 'uninstall' ? 'UNINSTALL\r' : 'cancel\r')
  } else if (!answered && mode === 'decline' && plain.includes('Would you like to continue')) {
    answered = true
    child.write('not now\r')
  } else if (!answered && mode === 'quit' && (plain.includes('What would you like') || plain.includes('/help'))) {
    answered = true
    child.write('/quit\r')
  }
})
child.onExit(({ exitCode, signal }) => {
  clearTimeout(timeout)
  writeFileSync(evidence, output)
  console.log(JSON.stringify({ answered, exitCode, signal, mode }))
  // node-pty's ConPTY worker may retain a Node handle after the product exits.
  // The product's onExit event is the assertion; explicitly end this test host.
  process.exit(answered && exitCode === 0 ? 0 : 1)
})
