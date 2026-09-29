// Empty loopback mailbox for lifecycle tests. It cannot send mail.
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { writeFileSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
assert.equal(process.platform, 'win32')
assert.equal(process.env.COMPUTERNAME, 'DM-WIN-TEST')
const evidence = process.argv[2]
assert.ok(evidence)
let polls = 0
const server = createServer((req, res) => {
  const match = req.url.match(/^\/v0\/inboxes\/windows-fixture@example\.test\/lists\/(receive|reply|send)\/allow\/proof-user@example\.test$/)
  if (req.method === 'GET' && match) {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ entry: 'proof-user@example.test', list_type: 'allow', entry_type: 'email', inbox_id: 'windows-fixture@example.test', read_only: true, direction: match[1] }))
    return
  }
  if (req.method !== 'GET' || !req.url.startsWith('/v0/inboxes/windows-fixture@example.test/messages?')) {
    res.writeHead(405); res.end('This fixture only lists an empty inbox.'); return
  }
  polls++
  writeFileSync(join(evidence, 'mailbox-polls.json'), JSON.stringify({ pid: process.pid, polls, lastPoll: new Date().toISOString() }))
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ count: 0, messages: [] }))
})
server.listen(58749, '127.0.0.1', () => {
  appendFileSync(join(evidence, 'mailbox-starts.jsonl'), JSON.stringify({ pid: process.pid, started: new Date().toISOString() })+'\n')
})
