// Long-path filesystem operations for Windows PowerShell 5.1 lifecycle scripts.
const fs = require('node:fs'); const path = require('node:path');
if (process.platform !== 'win32') throw new Error('Windows required');
const [operation, root] = process.argv.slice(2);
if (!root || !path.isAbsolute(root)) throw new Error('Absolute owned path required');
// A child link belongs to the owned tree, but its target does not. Never accept
// a redirected root or ancestor: even lstat(root) follows intermediate links.
for (let at = path.resolve(root); ; at = path.dirname(at)) {
  try {
    if (fs.lstatSync(at).isSymbolicLink()) throw new Error(`Refusing redirected removal path: ${at}`);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (path.dirname(at) === at) break;
}
if (operation === 'check') {
  const pending = [root];
  while (pending.length) {
    const at = pending.pop(); const info = fs.lstatSync(at);
    // DSH creates package junctions in its generated profile. Inspect the link
    // itself only; this also handles dangling targets and cycles.
    if (info.isSymbolicLink()) continue;
    if (info.isDirectory()) for (const name of fs.readdirSync(at)) pending.push(path.join(at, name));
  }
} else if (operation === 'space') {
  let destination = process.argv[4];
  if (!destination || !path.isAbsolute(destination)) throw new Error('Absolute destination required');
  while (!fs.existsSync(destination)) {
    const parent = path.dirname(destination);
    if (parent === destination) throw new Error('Installation drive is unavailable');
    destination = parent;
  }
  const volume = fs.statfsSync(destination);
  const cluster = Math.max(volume.bsize, 4096);
  // Include per-file allocation and directories, plus room for activation and
  // the running client's state. This is a preflight, not a disk reservation.
  let required = 256 * 1024 * 1024;
  const pending = [root];
  while (pending.length) {
    const at = pending.pop(); const info = fs.lstatSync(at);
    if (info.isSymbolicLink()) continue; // Copy-Bundle uses robocopy /XJ.
    if (info.isDirectory()) {
      required += cluster;
      for (const name of fs.readdirSync(at)) pending.push(path.join(at, name));
    } else required += Math.ceil(info.size / cluster) * cluster;
  }
  const available = volume.bavail * volume.bsize;
  if (available < required) {
    throw new Error(`Not enough disk space for the Windows bundle: need ${Math.ceil(required / 1048576)} MiB, have ${Math.floor(available / 1048576)} MiB. Free space on the installation drive and retry.`);
  }
} else if (operation === 'remove') {
  // Node's recursive removal unlinks child symlinks/junctions without traversing
  // their targets. The native regression gate checks external data survives.
  fs.rmSync(root, { recursive: true, force: true, maxRetries: 3, retryDelay: 200 });
} else throw new Error('Unknown lifecycle filesystem operation');
