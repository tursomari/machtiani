// Use the pinned, already-downloaded Codex packages; no sign-in or network calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRequire } = require('node:module');
const { test } = require('node:test');
const { checkCodexRuntime } = require('../../scripts/check-codex-runtime.cjs');
assert.equal(process.platform, 'win32', 'Native Windows required');
assert.ok(process.argv[2], 'Pass an installer runtime containing the pinned Codex packages');
const fromFixture = createRequire(path.resolve(process.argv[2], 'packages/model-host/package.json'));
const native = `@openai/codex-win32-${process.arch}`;
const packages = ['@openai/codex', native];
const manifests = packages.map(name => fromFixture.resolve(`${name}/package.json`));
const version = JSON.parse(fs.readFileSync(manifests[0], 'utf8')).version;

test('the downloaded native runtime works at a short path and diagnoses an overlong path', t => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-path-'));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const root = path.join(base, 'short');
  fs.mkdirSync(root);
  for (let i = 0; i < packages.length; i++) {
    fs.cpSync(path.dirname(manifests[i]), path.join(root, 'node_modules', packages[i]), { recursive: true });
  }
  assert.equal(checkCodexRuntime(root), version);
  const long = path.join(base, ...Array(4).fill('long build directory with spaces and Unicode 雪'));
  fs.mkdirSync(path.dirname(long), { recursive: true });
  fs.renameSync(root, long);
  assert.throws(() => checkCodexRuntime(long), error => {
    assert.match(error.message, /executable is present.*path is too long/);
    assert.doesNotMatch(error.message, /network access|finish downloading/);
    return true;
  });
  // Relocation alone repairs launch: the bytes were downloaded correctly.
  fs.renameSync(long, root);
  assert.equal(checkCodexRuntime(root), version);
});
