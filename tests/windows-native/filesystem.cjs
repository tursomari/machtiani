// Native Windows lifecycle removal: generated junctions must not expose their targets.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const helper = path.resolve(__dirname, '../../scripts/windows-files.cjs');
assert.equal(process.platform, 'win32', 'Run with native Windows Node');
function run(operation, root) {
  return spawnSync(process.execPath, [helper, operation, root], { encoding: 'utf8' });
}
function success(operation, root) {
  const result = run(operation, root);
  assert.equal(result.status, 0, result.stderr);
}
function fixture(t) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'dearmachine-removal-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const owned = path.join(base, 'owned');
  const external = path.join(base, 'external');
  fs.mkdirSync(owned); fs.mkdirSync(external);
  const sentinel = path.join(external, 'keep.txt');
  fs.writeFileSync(sentinel, 'external data');
  return { base, owned, external, sentinel };
}
test('generated profile junction passes preflight and removal preserves the external target', t => {
  const { owned, external, sentinel } = fixture(t);
  const modules = path.join(owned, 'dsh/profiles/node_modules');
  fs.mkdirSync(modules, { recursive: true });
  fs.symlinkSync(external, path.join(modules, 'zod-to-json-schema'), 'junction');
  success('check', owned);
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'external data');
  assert.ok(fs.existsSync(modules), 'preflight must not remove anything');
  success('remove', owned);
  assert.ok(!fs.existsSync(owned));
  assert.equal(fs.readFileSync(sentinel, 'utf8'), 'external data');
});
test('dangling and cyclic child junctions are removed without traversal', t => {
  const { base, owned } = fixture(t);
  fs.symlinkSync(path.join(base, 'absent'), path.join(owned, 'dangling'), 'junction');
  fs.symlinkSync(owned, path.join(owned, 'cycle'), 'junction');
  success('check', owned);
  success('remove', owned);
  assert.ok(!fs.existsSync(owned));
});
for (const kind of ['root', 'ancestor']) {
  test(`a redirected ${kind} is refused for both operations`, t => {
    const { base, external, sentinel } = fixture(t);
    const link = path.join(base, 'redirected');
    fs.symlinkSync(external, link, 'junction');
    const root = kind === 'root' ? link : path.join(link, 'child');
    if (kind === 'ancestor') fs.mkdirSync(root);
    for (const operation of ['check', 'remove']) {
      const result = run(operation, root);
      assert.notEqual(result.status, 0, `${operation} must refuse a redirected ${kind}`);
      assert.match(result.stderr, /redirected removal path/i);
      assert.equal(fs.readFileSync(sentinel, 'utf8'), 'external data');
      assert.ok(fs.existsSync(root));
    }
  });
}
test('long Unicode paths are removed and repeat removal is harmless', t => {
  const { owned } = fixture(t);
  const nested = path.join(owned, ...Array(12).fill('long directory with spaces 雪'));
  fs.mkdirSync(nested, { recursive: true });
  fs.writeFileSync(path.join(nested, 'data.txt'), 'owned data');
  success('check', owned);
  success('remove', owned);
  success('remove', owned);
  assert.ok(!fs.existsSync(owned));
});

test('bundle space preflight refuses insufficient capacity without modifying files', t => {
  const { base, owned, external, sentinel } = fixture(t);
  const nested = path.join(owned, ...Array(12).fill('bundle directory with spaces 雪'));
  fs.mkdirSync(nested, { recursive: true });
  fs.writeFileSync(path.join(nested, 'bundle.bin'), Buffer.alloc(8193));
  fs.symlinkSync(owned, path.join(owned, 'cycle'), 'junction');
  const preload = path.join(base, 'capacity.cjs');
  const minimum = 256 * 1024 * 1024 + 13 * 4096 + 12288;
  for (const available of [minimum - 4096, minimum]) {
    fs.writeFileSync(preload, `require('node:fs').statfsSync = () => ({bsize:4096,bavail:${available / 4096}});`);
    const result = spawnSync(process.execPath, ['--require', preload, helper, 'space', owned, external], { encoding: 'utf8', timeout: 15000 });
    assert.equal(result.error, undefined, 'junction cycles must not hang preflight');
    if (available < minimum) {
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Not enough disk space.*Free space/s);
    } else assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(sentinel, 'utf8'), 'external data');
    assert.equal(fs.statSync(path.join(nested, 'bundle.bin')).size, 8193);
    assert.deepEqual(fs.readdirSync(external), ['keep.txt']);
  }
});
