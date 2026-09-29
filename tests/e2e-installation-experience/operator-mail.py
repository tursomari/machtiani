"""Run-owned external email fixture for adaptive IXE users; never configures the product."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


def private_write(path, value):
    temporary = path.with_suffix('.writing')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def owned(row, state, role):
    return (row.get('inbox_id') not in state['baseline']
            and row.get('client_id') == f"ixe-operator-{state['run_id']}-{role}"
            and row.get('metadata') == {'machtiani_ipe_run': state['run_id'], 'machtiani_ipe_role': role}
            and bool(row.get('inbox_id')) and bool(row.get('email')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--key-file', required=True, type=Path)
    parser.add_argument('--scan-key-file', action='append', default=[], type=Path)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('init')
    commands.add_parser('status')
    send = commands.add_parser('send')
    send.add_argument('--text', required=True)
    messages = commands.add_parser('messages')
    messages.add_argument('--content', action='store_true', help='Read message bodies from run-owned inboxes')
    commands.add_parser('cleanup')
    args = parser.parse_args()
    if args.state.parent.stat().st_mode & 0o077:
        raise ValueError('state directory must be private')
    # Import the same reviewed file policy without copying keys into arguments.
    import importlib.util
    spec = importlib.util.spec_from_file_location('bridge', Path(__file__).with_name('operator.py'))
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    key = bridge.read_credential(args.key_file)
    values = [key, *[bridge.read_credential(path) for path in args.scan_key_file]]
    environment = {k: v for k, v in os.environ.items() if k not in ('AGENTMAIL_BASE_URL', 'AGENTMAIL_CUSTOM_HEADERS')}
    environment['AGENTMAIL_API_KEY'] = key

    def call(*command):
        result = subprocess.run([str(args.helper), *command], env=environment,
                                text=True, capture_output=True, timeout=60)
        if any(value in result.stdout or value in result.stderr for value in values):
            raise RuntimeError('credential detected in provider output; output suppressed')
        if result.returncode:
            # The helper already redacts its key; retain errors privately.
            private_write(args.state.with_suffix('.error.json'), {'command': command[0], 'error': result.stderr})
            raise RuntimeError('email helper failed; private diagnostic retained')
        return json.loads(result.stdout)

    if args.action == 'init':
        if args.state.exists():
            raise ValueError('refusing to replace an existing email journal')
        state = {'run_id': uuid.uuid4().hex, 'baseline': [r['inbox_id'] for r in call('list-inboxes')['inboxes']],
                 'inboxes': {}, 'intents': [], 'sent': []}
        private_write(args.state, state)
        for role in ('receiver', 'sender'):
            # Journal the run-unique idempotency identity before creation.
            state['intents'].append(role)
            private_write(args.state, state)
            row = call('create-inbox', '--client-id', f"ixe-operator-{state['run_id']}-{role}",
                       '--display-name', f"IXE operator {state['run_id']} {role}",
                       '--metadata-run-id', state['run_id'], '--metadata-role', role)
            if not owned(row, state, role):
                raise ValueError('created inbox did not match its journaled identity')
            state['inboxes'][role] = row
            private_write(args.state, state)
        sender, receiver = state['inboxes']['sender'], state['inboxes']['receiver']
        # Only the sender is configured here. The real installer must configure
        # its receiver and authorization via the normal user conversation.
        for direction in ('send', 'reply'):
            call('lists-create', '--scope', 'inbox', '--scope-id', sender['inbox_id'],
                 '--direction', direction, '--type', 'allow', '--entry', receiver['email'])
    else:
        state = json.loads(args.state.read_text())
    if args.action == 'send':
        sender, receiver = state['inboxes']['sender'], state['inboxes']['receiver']
        for role in ('sender', 'receiver'):
            if not owned(call('get-inbox', '--id', state['inboxes'][role]['inbox_id']), state, role):
                raise ValueError('email resource ownership changed')
        nonce = uuid.uuid4().hex
        state['sent'].append({'nonce': nonce, 'status': 'intent'})
        private_write(args.state, state)
        receipt = call('send', '--inbox-id', sender['inbox_id'], '--to', receiver['email'],
                       '--subject', f'IXE user check {nonce}', '--text', args.text, '--idempotency', nonce)
        state['sent'][-1].update(status='sent', receipt=receipt)
        private_write(args.state, state)
        print(json.dumps({'sent': True, 'receipt': receipt}))
    elif args.action == 'messages':
        for role, row in state['inboxes'].items():
            if not owned(call('get-inbox', '--id', row['inbox_id']), state, role):
                raise ValueError('email resource ownership changed')
            result = call('list-messages', '--inbox-id', row['inbox_id'])
            if args.content:
                result = {'messages': [call('get-message', '--inbox-id', row['inbox_id'], '--id', message['message_id'])
                                       for message in result['messages']]}
            print(json.dumps({'role': role, 'messages': result}))
    elif args.action == 'cleanup':
        rows = call('list-inboxes')['inboxes']
        for role in state['intents']:
            matches = [row for row in rows if owned(row, state, role)]
            if len(matches) > 1:
                raise ValueError('ambiguous journaled inbox identity')
            if not matches:
                continue
            row = matches[0]
            for direction in ('send', 'receive', 'reply'):
                for kind in ('allow', 'block'):
                    entries = call('lists', '--scope', 'inbox', '--scope-id', row['inbox_id'],
                                   '--direction', direction, '--type', kind)['entries']
                    for entry in entries:
                        call('lists-delete-by-composite', '--scope', 'inbox', '--scope-id', row['inbox_id'],
                             '--direction', direction, '--type', kind, '--entry', entry['entry'])
            call('delete-inbox', '--id', row['inbox_id'])
        remaining = call('list-inboxes')['inboxes']
        if any(owned(row, state, role) for row in remaining for role in state['intents']):
            raise ValueError('journaled inbox remains after cleanup')
        if not set(state['baseline']).issubset({row['inbox_id'] for row in remaining}):
            raise ValueError('preexisting inbox baseline changed; investigate without mutating it')
        state['cleaned'] = True
        private_write(args.state, state)
        print('Run-owned inboxes and scoped policies removed; preexisting inboxes preserved.')
    else:
        print(json.dumps({'run_id': state['run_id'], 'inboxes': {
            role: row['email'] for role, row in state['inboxes'].items()}}))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never render arbitrary provider/SDK exceptions or credential buffers.
        print(f'Operator email action failed ({type(error).__name__}); inspect private state.', file=sys.stderr)
        sys.exit(1)
