const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { checkCodexRuntime } = require('../scripts/check-codex-runtime.cjs');

function fixture(t, script) {
  const root = mkdtempSync(join(tmpdir(), 'codex-runtime-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const pkg = join(root, 'node_modules/@openai/codex');
  mkdirSync(join(pkg, 'bin'), { recursive: true });
  writeFileSync(join(pkg, 'package.json'), JSON.stringify({ version: '1.2.3' }));
  writeFileSync(join(pkg, 'bin/codex.js'), script);
  return root;
}

test('rejects a launcher whose optional native dependency was silently omitted', t => {
  const root = fixture(t, 'throw Error("Missing optional dependency @openai/codex-win32-x64: private diagnostic");');
  assert.throws(() => checkCodexRuntime(root), error => {
    assert.match(error.message, /runtime could not start/);
    assert.doesNotMatch(error.message, /network access|finish downloading/);
    assert.doesNotMatch(error.message, /private diagnostic/);
    return true;
  });
});

test('rejects a runnable native binary from a different version', t => {
  assert.throws(() => checkCodexRuntime(fixture(t, 'console.log("codex-cli 9.9.9")')), /Rebuild the Windows runtime/);
});

test('accepts the pinned native runtime after relocation', t => {
  const root = fixture(t, 'console.log("codex-cli 1.2.3")');
  assert.equal(checkCodexRuntime(root), '1.2.3');
});
