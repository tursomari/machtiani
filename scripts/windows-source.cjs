// Copy committed, pinned source without Git administration or untracked user files.
const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
function snapshot(source, destination, git = 'git') {
  source = path.resolve(source)
  destination = path.resolve(destination)
  if (destination === source || destination.startsWith(source + path.sep)) throw new Error('Source snapshot must be outside the checkout')
  if (fs.existsSync(destination)) throw new Error('Source snapshot destination already exists')
  const revisions = {}
  function command(directory, args) {
    const result = spawnSync(git, ['-C', directory, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, windowsHide: true })
    if (result.error || result.status !== 0) throw new Error(`Cannot read committed source: ${directory}`)
    return result.stdout
  }
  function copy(checkout, target, name, expected) {
    if (path.resolve(command(checkout, ['rev-parse', '--show-toplevel']).trim()) !== path.resolve(checkout)) throw new Error(`Initialize the pinned submodule: ${name}`)
    const revision = command(checkout, ['rev-parse', 'HEAD']).trim()
    if (expected && revision !== expected) throw new Error(`Submodule ${name} differs from its pin; run git submodule update --init --recursive`)
    if (command(checkout, ['status', '--porcelain', '--untracked-files=no', '--ignore-submodules=all']).trim()) throw new Error(`Commit or restore tracked changes before building: ${name}`)
    revisions[name] = revision
    fs.mkdirSync(target, { recursive: true })
    for (const record of command(checkout, ['ls-files', '--stage', '-z']).split('\0').filter(Boolean)) {
      const match = /^(\d+) ([a-f0-9]+) 0\t([\s\S]+)$/.exec(record)
      if (!match) throw new Error('Unmerged source entry')
      const [, mode, oid, relative] = match
      if (relative.split('/').some(part => part === '..' || part === '.git') || path.isAbsolute(relative)) throw new Error('Unsafe source path')
      const from = path.join(checkout, relative)
      const to = path.join(target, relative)
      if (mode === '160000') {
        copy(from, to, name === '.' ? relative : `${name}/${relative}`, oid)
      } else {
        if (!['100644', '100755'].includes(mode) || !fs.lstatSync(from).isFile()) throw new Error(`Unsupported source file: ${relative}`)
        // Check every ancestor as well: a directory junction must not export host state.
        for (let at = path.dirname(from); at !== checkout; at = path.dirname(at)) {
          if (fs.lstatSync(at).isSymbolicLink()) throw new Error(`Redirected source directory: ${relative}`)
        }
        fs.mkdirSync(path.dirname(to), { recursive: true })
        fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL)
        fs.chmodSync(to, mode === '100755' ? 0o755 : 0o644)
      }
    }
  }
  copy(source, destination, '.')
  fs.writeFileSync(path.join(destination, 'bootstrap-source-revisions.json'), JSON.stringify(revisions, null, 2) + '\n')
  return revisions
}
module.exports = { snapshot }
if (require.main === module) {
  try { snapshot(...process.argv.slice(2)) }
  catch (error) { console.error(error.message); process.exitCode = 1 }
}
