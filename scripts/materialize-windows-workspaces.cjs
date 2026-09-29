// pnpm's Windows workspace junctions point at the build directory. Publish
// ordinary package directories so the installed runtime can be relocated.
const fs = require('node:fs'); const path = require('node:path');
const root = path.resolve(process.argv[2]);
if (process.platform !== 'win32') throw new Error('Windows bundle preparation only');
if (!/nodeLinker"?\s*:\s*"?hoisted/.test(fs.readFileSync(path.join(root, 'node_modules/.modules.yaml'), 'utf8'))) throw new Error('The relocatable Windows runtime requires hoisted dependencies');
const packages = path.join(root, 'packages');
const scope = path.join(root, 'node_modules/@dearmachine');
fs.mkdirSync(scope, { recursive: true });
for (const entry of fs.readdirSync(packages)) {
  const source = path.join(packages, entry);
  const manifest = path.join(source, 'package.json');
  if (!fs.existsSync(manifest)) continue;
  const { name } = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  if (!/^@dearmachine\/[a-z0-9-]+$/.test(name)) throw new Error('Unexpected workspace name');
  const destination = path.join(root, 'node_modules', name);
  const temporary = destination + '.materializing';
  fs.cpSync(source, temporary, { recursive: true, dereference: true,
    filter: file => path.basename(file) !== 'node_modules' });
  fs.rmSync(destination, { recursive: true, force: true });
  fs.renameSync(temporary, destination);
  // Resolve workspace dependencies through the canonical hoisted copies.
  const local = path.join(source, 'node_modules/@dearmachine');
  if (fs.existsSync(local)) {
    for (const dependency of fs.readdirSync(local)) {
      const link = path.join(local, dependency);
      if (!fs.lstatSync(link).isSymbolicLink()) throw new Error('Unexpected non-junction workspace dependency');
      const relative = path.relative(packages, fs.realpathSync(link));
      if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Unexpected workspace target');
      fs.rmSync(link, { recursive: true });
    }
    fs.rmdirSync(local);
  }
}

// Reject any remaining junction rather than shipping a dependency on staging.
function assertOrdinaryTree(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Non-relocatable dependency: ' + file);
    if (entry.isDirectory()) assertOrdinaryTree(file);
  }
}
assertOrdinaryTree(root);
