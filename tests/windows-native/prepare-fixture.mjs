// Run only in a disposable Windows guest with a fresh ordinary-user profile.
import assert from 'node:assert/strict'
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
assert.equal(process.platform, 'win32')
assert.equal(process.env.COMPUTERNAME, 'DM-WIN-TEST')
const [release, backend = 'forge'] = process.argv.slice(2)
assert.ok(['forge', 'omp'].includes(backend))
assert.ok(release)
const { protectPrivatePath } = await import(pathToFileURL(join(release, 'runtime/installer/packages/credential-adapter/dist/index.mjs')))
const home = process.env.USERPROFILE
const state = join(home, '.dearmachine')
const config = join(state, 'config')
const modelDir = join(home, '.config/dearmachine/machtiani')
const project = join(home, 'Documents/Dear Machine proof Ω')
for (const p of [state, config, modelDir]) { await mkdir(p, { recursive: true }); await protectPrivatePath(p, 0o700) }
await mkdir(project, { recursive: true })
const q = value => JSON.stringify(value.replaceAll('\\', '/'))
async function put(p, text) { await writeFile(p, text, { flag: 'wx' }) }
await put(join(project, 'expenses.csv'), 'category,amount\ntravel,12.50\nfood,8.25\ntravel,7.50\nfood,4.75\n')
await put(join(state, 'pairs.toml'), `version = 2
[[inboxes]]
id = "318c831e-52a5-4ee1-afec-b811435f6068"
transport = "agentmail"
provider_id = "windows-fixture@example.test"
address = "windows-fixture@example.test"
[[pairs]]
id = "4ab832dc-f9bd-4fdb-a369-175145b06b86"
user_email = "proof-user@example.test"
inbox_id = "318c831e-52a5-4ee1-afec-b811435f6068"
`)
await put(join(config, 'dearmachine.toml'), `version = 1\nbackends = [${JSON.stringify(backend)}]\nresponse_tier = "plain"\n`)
await put(join(config, 'runtime.toml'), `version = 1
project = ${q(project)}
model = "windows-proof"
agent_binary = ${q('machtiani.exe')}
manager_path = ""
poll_interval = "3s"
concurrency = 1
entry_point_repo = ""
verbose = true
`)
await put(join(modelDir, 'config.toml'), `default_model = "windows-proof"
credentials_file = "credentials.env"
[planner]
max_turns = 12
[shell-agent]
max_steps = 12
finalize_remaining_steps = 2
command_supervisor_timeout = 5
command_supervisor_deadline_buffer = 10
[model_defaults]
context_length = 128000
[providers.deepinfra]
base_url = "https://api.deepinfra.com/v1/openai"
api_key_ref = "DEEPINFRA_API_KEY"
[models.windows-proof]
provider = "deepinfra"
model = "zai-org/GLM-5.3"
[models.windows-proof.params]
reasoning_effort = "high"
max_tokens = 8192
[environment]
type = "local"
command_timeout = 60
[ui]
theme = "none"
`)
console.log(JSON.stringify({ project, state, modelDir }))
