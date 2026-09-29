// Credential-free Windows ConPTY coverage for Quick start's preparation activity.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'
assert.equal(process.platform, 'win32')
const [fixtureRuntime, source, mode, requestFile] = process.argv.slice(2)
const request = mode === '--terminal' ? JSON.parse(readFileSync(requestFile, 'utf8')) : undefined
const require = createRequire(join(resolve(fixtureRuntime), 'installer/package.json'))
const pty = request ? require('node-pty') : undefined
const powershell = join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
const root = request?.root ?? mkdtempSync(join(tmpdir(), "activity 雪 ' "))
const quote = value => "'" + value.replaceAll("'", "''") + "'"
const frames = ['⢆⡰', '⢎⡠', '⢎⡁', '⢎⠑', '⠎⠱', '⠊⡱', '⢈⡱', '⢄⡱']
const plain = text => text.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
const script = (name, body) => { const file = join(root, name + '.ps1'); writeFileSync(file, '\ufeff' + body); return file }
const invoke = worker => `$ErrorActionPreference='Stop'; $encoding=[Console]::OutputEncoding.CodePage; . ${quote(join(resolve(source), 'scripts/windows-activity.ps1'))}; Invoke-WindowsActivity -Label 'Preparing fixture' -ScriptPath ${quote(worker)} -Arguments @{Marker=${quote(join(root, 'child.pid'))}}; if([Console]::OutputEncoding.CodePage -ne $encoding){throw 'Console encoding was not restored'}; Write-Host 'AFTER_ACTIVITY'`
const args = body => ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script('invoke', body)]
// Each ConPTY host exits in onExit, like terminal.mjs. Assertions and process
// inspection run in the separate parent after the terminal host has exited.
if (request) {
  await new Promise(() => {
    const child = pty.spawn(powershell, args(request.body), { name: 'xterm-256color', cols: 90, rows: 24, cwd: root, env: { ...process.env, TERM: 'xterm-256color' } })
    let output = '', cancelled = false
    const timer = setTimeout(() => { child.kill(); process.stderr.write('Activity test timed out: ' + plain(output).slice(-1500)); process.exit(1) }, 30000)
    child.onData(chunk => {
      output += chunk
      if (request.cancel && !cancelled && existsSync(join(root, 'child.pid')) && frames.some(frame => output.includes(frame))) {
        cancelled = true
        child.write('\x03')
      }
    })
    child.onExit(({ exitCode }) => {
      clearTimeout(timer)
      writeFileSync(request.result, JSON.stringify({ output, exitCode, cancelled }))
      process.exit(0)
    })
  })
}
function terminal(body, cancel = false) {
  const requestPath = join(root, 'terminal-request.json'), result = join(root, 'terminal-result.json')
  rmSync(result, { force: true })
  writeFileSync(requestPath, JSON.stringify({ root, body, cancel, result }))
  const host = spawnSync(process.execPath, [fileURLToPath(import.meta.url), fixtureRuntime, source, '--terminal', requestPath], { encoding: 'utf8', timeout: 35000 })
  assert.equal(host.status, 0, host.stdout + host.stderr)
  return JSON.parse(readFileSync(result, 'utf8'))
}

function assertChildStopped() {
  const descendant = Number(readFileSync(join(root, 'child.pid'), 'utf8'))
  const probe = spawnSync(powershell, args(`if (Get-Process -Id ${descendant} -ErrorAction SilentlyContinue) { exit 1 }; exit 0`), { encoding: 'utf8', timeout: 10000 })
  assert.equal(probe.status, 0, 'Preparation must stop the worker descendant')
}

let passed = false
try {
  const success = script('quiet worker', `param([string]$Marker)\nStart-Sleep -Milliseconds 1400\n[Console]::Out.WriteLine('stdout readable')\n[Console]::Error.WriteLine('stderr readable')\nWrite-Host $Marker\n`)
  const ok = await terminal(invoke(success))
  assert.equal(ok.exitCode, 0, plain(ok.output))
  assert.equal(ok.output.includes('CLIXML'), false, 'Worker output must remain readable')
  assert.ok(frames.filter(frame => ok.output.includes(frame)).length > 2, 'Quiet work must visibly animate: ' + JSON.stringify(ok.output))
  for (const value of ['stdout readable', 'stderr readable', "activity 雪 ' ", 'AFTER_ACTIVITY']) assert.ok(plain(ok.output).includes(value), value)
  assert.equal(frames.some(frame => ok.output.slice(ok.output.indexOf('AFTER_ACTIVITY')).includes(frame)), false, 'Activity must end before terminal handoff')
  const redirected = spawnSync(powershell, args(invoke(success)), { encoding: 'utf8', timeout: 30000 })
  assert.equal(redirected.status, 0, redirected.stderr)
  assert.equal(frames.some(frame => redirected.stdout.includes(frame)), false)
  assert.equal(redirected.stdout.includes('\x1b'), false, 'Redirected output must stay plain')
  assert.ok(redirected.stdout.includes('stdout readable'))
  assert.ok(redirected.stdout.includes('stderr readable'))
  assert.equal((redirected.stdout + redirected.stderr).includes('CLIXML'), false)
  const noisy = script('noisy worker', `param([string]$Marker)\nfor($i=0;$i -lt 1000;$i++){[Console]::Out.WriteLine('output-'+$i+('x'*100));[Console]::Error.WriteLine('error-'+$i+('y'*100))}\n`)
  const drained = spawnSync(powershell, args(invoke(noisy)), { encoding: 'utf8', timeout: 30000 })
  assert.equal(drained.status, 0, drained.stderr)
  for (const value of ['output-0x', 'output-999x', 'error-0y', 'error-999y']) assert.ok(drained.stdout.includes(value), value)
  const failure = script('failure', `param([string]$Marker)\n$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $PSHOME 'powershell.exe';$info.Arguments='-NoProfile -NonInteractive -Command Start-Sleep -Seconds 120';$info.UseShellExecute=$false;$info.CreateNoWindow=$true\n$p=[Diagnostics.Process]::Start($info)\n[IO.File]::WriteAllText($Marker,[string]$p.Id)\n[Console]::Error.WriteLine('specific failure detail')\nexit 7\n`)
  const failed = await terminal(invoke(failure))
  assert.notEqual(failed.exitCode, 0)
  assert.ok(plain(failed.output).includes('specific failure detail'))
  assert.ok(plain(failed.output).includes('exit 7'))
  assert.equal(failed.output.includes('AFTER_ACTIVITY'), false)
  assertChildStopped()
  rmSync(join(root, 'child.pid'))
  const blocked = script('cancel worker', `param([string]$Marker)\n$p=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden\n[IO.File]::WriteAllText($Marker,[string]$p.Id)\n$p.WaitForExit()\n`)
  const cancelled = await terminal(invoke(blocked), true)
  assert.ok(cancelled.cancelled)
  assert.equal(cancelled.output.includes('AFTER_ACTIVITY'), false)
  assertChildStopped()
  passed = true
  console.log('WINDOWS_ACTIVITY_OK: animated quiet work, output, quoted Unicode paths, redirected output, failure, cancellation, and handoff')
} finally {
  if (passed) rmSync(root, { recursive: true, force: true })
  else console.error('Failed activity fixture retained at ' + root)
}
// ConPTY can retain an internal handle after its onExit event.
process.exit(0)
