#!/usr/bin/env python3
"""Run-owned OpenMail sender for the AgentMail receiver IPE."""
import argparse
from email.utils import parseaddr
import json
import os
from pathlib import Path
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('OpenMail API redirect refused')


class AttachmentLocation(Exception):
    def __init__(self, url):
        self.url = url


class AttachmentRedirect(NoRedirect):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if code != 302:
            raise RuntimeError('Unexpected OpenMail attachment redirect')
        raise AttachmentLocation(newurl)


def identity(row):
    keys = ('id', 'address', 'podId', 'displayName', 'createdAt')
    result = {key: row.get(key) for key in keys}
    if not all(isinstance(result[key], str) and result[key] for key in ('id', 'address', 'podId', 'createdAt')):
        raise ValueError('OpenMail inbox response lacks a complete identity')
    return result


class Sender:
    def __init__(self, state):
        self.path = Path(state)
        self.key = os.environ.get('OPENMAIL_API_KEY', '').strip()
        if not self.key:
            raise ValueError('OPENMAIL_API_KEY is required for the OpenMail sender')

    def request(self, method, path, value=None, *, body=None, content_type=None, idempotency=None, raw=False):
        if not path.startswith('/v1/') or '\r' in path or '\n' in path:
            raise ValueError('Invalid OpenMail API path')
        headers = {'Authorization': 'Bearer ' + self.key}
        if value is not None:
            body, content_type = json.dumps(value).encode(), 'application/json'
        if content_type:
            headers['Content-Type'] = content_type
        if idempotency:
            headers['Idempotency-Key'] = idempotency
        request = urllib.request.Request('https://api.openmail.sh' + path, data=body, headers=headers, method=method)
        try:
            handler = AttachmentRedirect() if raw and path.startswith('/v1/attachments/') else NoRedirect()
            with urllib.request.build_opener(handler).open(request, timeout=60) as response:
                data = response.read()
        except AttachmentLocation as location:
            # The attachment API returns a signed storage URL. Start a new,
            # unauthenticated request; never forward the OpenMail bearer key.
            parsed = urllib.parse.urlsplit(location.url)
            if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
                raise RuntimeError('Unsafe OpenMail attachment URL') from None
            try:
                download = urllib.request.Request(location.url)
                with urllib.request.build_opener(NoRedirect()).open(download, timeout=60) as response:
                    data = response.read()
            except (urllib.error.URLError, OSError):
                raise RuntimeError('OpenMail attachment download failed') from None
        except urllib.error.HTTPError as error:
            # Response bodies and request headers are not diagnostic output.
            raise RuntimeError(f'OpenMail {method} failed with HTTP {error.code}') from None
        except urllib.error.URLError:
            raise RuntimeError('OpenMail API connection failed') from None
        return data if raw else json.loads(data) if data else None

    def pages(self, path):
        rows, offset = [], 0
        while True:
            page = self.request('GET', path + ('&' if '?' in path else '?') + f'limit=100&offset={offset}')
            batch = page['data']
            if not isinstance(batch, list) or not isinstance(page['total'], int):
                raise ValueError('Invalid OpenMail pagination response')
            rows.extend(batch)
            offset += len(batch)
            if offset >= page['total']:
                return rows
            if not batch:
                raise ValueError('OpenMail pagination ended before total')

    def snapshot(self):
        inboxes = sorted((identity(row) for row in self.pages('/v1/inboxes')), key=lambda row: row['id'])
        policies = {'account': self.request('GET', '/v1/policy')}
        for pod in sorted({row['podId'] for row in inboxes}):
            policies['pod:' + pod] = self.request('GET', '/v1/policy?podId=' + urllib.parse.quote(pod, safe=''))
        for row in inboxes:
            policies['inbox:' + row['id']] = self.request('GET', '/v1/policy?inboxId=' + urllib.parse.quote(row['id'], safe=''))
        return {'inboxes': inboxes, 'policies': policies}

    def save(self, state):
        temporary = self.path.with_name(self.path.name + '.' + secrets.token_hex(6))
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(state, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)
        descriptor = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def load(self):
        return json.loads(self.path.read_text())

    def prepare(self, run_id, receiver):
        if not re.fullmatch('[0-9a-f]{12}', run_id) or parseaddr(receiver)[1] != receiver or '@' not in receiver:
            raise ValueError('Invalid OpenMail sender run or recipient')
        if self.path.exists():
            raise ValueError('OpenMail sender state already exists; clean up the previous attempt')
        name, display = 'ipe-' + run_id + '-sender', 'Machtiani IPE ' + run_id + ' sender'
        baseline = self.snapshot()
        if any(row['address'].split('@')[0] == name or row['displayName'] == display for row in baseline['inboxes']):
            raise ValueError('OpenMail sender identity already exists')
        state = {'baseline': baseline, 'mailbox_name': name, 'display_name': display, 'receiver': receiver}
        self.save(state)  # Durable intent precedes the only create request.
        created = identity(self.request('POST', '/v1/inboxes', {'mailboxName': name, 'displayName': display}))
        if created['address'].split('@')[0] != name or created['displayName'] != display:
            raise ValueError('OpenMail created inbox does not match the recorded intent')
        state['inbox'] = created
        self.save(state)
        for direction in ('inbound', 'outbound'):
            self.request('POST', '/v1/policy/rules?inboxId=' + urllib.parse.quote(created['id'], safe=''),
                         {'direction': direction, 'type': 'allow', 'value': receiver})
        return {'inbox_id': created['id'], 'email': created['address']}

    def cleanup(self):
        state = self.load()
        current = [identity(row) for row in self.pages('/v1/inboxes')]
        owned = state.get('inbox')
        if owned is None:
            matches = [row for row in current if row['address'].split('@')[0] == state['mailbox_name']
                       and row['displayName'] == state['display_name']]
            if len(matches) != 1:
                raise ValueError('Ambiguous OpenMail create intent; refusing deletion')
            if matches:
                owned = state['inbox'] = matches[0]
                self.save(state)
        if owned:
            if owned['id'] in {row['id'] for row in state['baseline']['inboxes']}:
                raise ValueError('Refusing to delete an OpenMail baseline inbox')
            matches = [row for row in current if row['id'] == owned['id']]
            if matches:
                actual = identity(self.request('GET', '/v1/inboxes/' + urllib.parse.quote(owned['id'], safe='')))
                if len(matches) != 1 or actual != owned or actual != matches[0]:
                    raise ValueError('OpenMail sender identity changed; refusing deletion')
                self.request('DELETE', '/v1/inboxes/' + urllib.parse.quote(owned['id'], safe=''))
        if self.snapshot() != state['baseline']:
            raise ValueError('OpenMail baseline was not restored')
        state['cleaned'] = True
        self.save(state)
        return {'cleaned': True}

    def owned(self, inbox_id):
        state = self.load()
        if state.get('cleaned') or state.get('inbox', {}).get('id') != inbox_id:
            raise ValueError('Command does not target this run\'s OpenMail sender')
        return state

    def messages(self, inbox_id):
        self.owned(inbox_id)
        rows = self.pages('/v1/inboxes/' + urllib.parse.quote(inbox_id, safe='') + '/messages')
        return [{'message_id': row['id'], 'thread_id': row['threadId'], 'from': row['fromAddr'],
                 'subject': row.get('subject', ''), 'text': row.get('bodyText', ''),
                 'attachments': [{'filename': item['filename'], 'content_type': item['contentType'],
                                  'attachment_id': item['filename']} for item in row.get('attachments', [])]}
                for row in rows]

    def message(self, inbox_id, message_id):
        matches = [row for row in self.messages(inbox_id) if row['message_id'] == message_id]
        if len(matches) != 1:
            raise ValueError('Expected one exact OpenMail sender message')
        return matches[0]

    def send(self, args):
        state = self.owned(args.inbox_id)
        if args.to != state['receiver']:
            raise ValueError('Refusing to send outside the recorded test pair')
        boundary = 'ipe-' + secrets.token_hex(16)
        body = bytearray()
        for name, value in [('to', args.to), ('subject', args.subject), ('body', args.text)]:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="attachments"; filename="input.txt"\r\nContent-Type: text/plain\r\n\r\n'.encode())
        body.extend(Path(args.attachment).read_bytes())
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        row = self.request('POST', '/v1/inboxes/' + urllib.parse.quote(args.inbox_id, safe='') + '/send',
                           body=bytes(body), content_type='multipart/form-data; boundary=' + boundary, idempotency=args.idempotency)
        if row.get('status') == 'failed' or not row.get('messageId') or not row.get('threadId'):
            raise ValueError('OpenMail send did not return a successful message identity')
        return {'message_id': row['messageId'], 'thread_id': row['threadId']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('prepare')
    prepare.add_argument('--run-id', required=True)
    prepare.add_argument('--receiver', required=True)
    commands.add_parser('cleanup')
    for name in ('send-with-attachment', 'list-messages', 'get-message', 'get-attachment'):
        command = commands.add_parser(name)
        command.add_argument('--inbox-id', required=True)
        if name == 'send-with-attachment':
            for flag in ('to', 'subject', 'text', 'attachment', 'idempotency'):
                command.add_argument('--' + flag, required=True)
        elif name == 'get-message':
            command.add_argument('--id', required=True)
        elif name == 'get-attachment':
            command.add_argument('--message-id', required=True)
            command.add_argument('--attachment-id', required=True)
    args = parser.parse_args()
    sender = Sender(args.state)
    if args.command == 'prepare':
        result = sender.prepare(args.run_id, args.receiver)
    elif args.command == 'cleanup':
        result = sender.cleanup()
    elif args.command == 'send-with-attachment':
        result = sender.send(args)
    elif args.command == 'list-messages':
        result = {'messages': sender.messages(args.inbox_id)}
    elif args.command == 'get-message':
        result = sender.message(args.inbox_id, args.id)
    else:
        message = sender.message(args.inbox_id, args.message_id)
        if sum(item['filename'] == args.attachment_id for item in message['attachments']) != 1:
            raise ValueError('Attachment does not belong to this sender message')
        data = sender.request('GET', '/v1/attachments/' + urllib.parse.quote(args.message_id, safe='') + '/' + urllib.parse.quote(args.attachment_id, safe=''), raw=True)
        sys.stdout.buffer.write(data)
        return
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
