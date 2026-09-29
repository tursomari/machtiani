// Validate the native dependency behind the packaged OpenAI sign-in launcher.
const { createRequire } = require('node:module');
const { existsSync, readFileSync } = require('node:fs');
const { join, dirname, resolve, toNamespacedPath } = require('node:path');
const { spawnSync } = require('node:child_process');

function checkCodexRuntime(installer) {
  const root = resolve(installer);
  let message = 'The bundled OpenAI sign-in runtime could not start. Rebuild the Windows runtime; inspect the retained build directory if it fails again.';
  try {
    const fromModelHost = createRequire(join(root, 'packages/model-host/package.json'));
    const manifest = fromModelHost.resolve('@openai/codex/package.json');
    const { version } = JSON.parse(readFileSync(manifest, 'utf8'));
    const result = spawnSync(process.execPath, [join(dirname(manifest), 'bin/codex.js'), '--version'], {
      encoding: 'utf8', timeout: 30000, windowsHide: true,
    });
    if (result.error || result.status !== 0 || result.stdout.trim() !== `codex-cli ${version}`) {
      if (process.platform === 'win32' && result.stderr?.includes('ENOENT')) {
        const target = { x64: 'x86_64', arm64: 'aarch64' }[process.arch];
        if (target) {
          const nativePackage = fromModelHost.resolve(`@openai/codex-win32-${process.arch}/package.json`);
          const executable = join(dirname(nativePackage), 'vendor', `${target}-pc-windows-msvc`, 'bin/codex.exe');
          if (executable.length >= 260 && existsSync(executable)) {
            // Diagnose the path limit without treating a direct native probe as
            // proof that the packaged JS launcher works. The build still fails.
            const probe = spawnSync(toNamespacedPath(executable), ['--version'], {
              encoding: 'utf8', timeout: 30000, windowsHide: true,
            });
            if (!probe.error && probe.status === 0 && probe.stdout.trim() === `codex-cli ${version}`) {
              message = 'The bundled OpenAI sign-in executable is present, but its Windows path is too long. Use a shorter build cache or installation path and retry.';
            }
          }
        }
      }
      throw new Error(message);
    }
    return version;
  } catch {
    // Do not forward dependency stderr: this boundary needs only a repair action.
    throw new Error(message);
  }
}

module.exports = { checkCodexRuntime };
if (require.main === module) {
  try {
    if (!process.argv[2]) throw new Error('An installer runtime directory is required.');
    console.log(`Verified bundled Codex ${checkCodexRuntime(process.argv[2])}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
