"""Private, stepwise SSH terminal operator. No scripted installation decisions."""
import argparse
import codecs
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import secrets
import socket
import stat
import struct
import sys
import termios
import time

import pyte

LABEL = 'Secure API key — input hidden'
KEYS = {'enter': '\r', 'escape': '\x1b', 'up': '\x1b[A', 'down': '\x1b[B',
        'ctrl-c': '\x03', 'ctrl-d': '\x04', 'clear': '\x15'}


class SecretExposure(Exception):
    pass


def read_credential(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError('credential must be an owner-only regular file')
        data = os.read(fd, 16385)
        if len(data) > 16384:
            raise ValueError('credential file is too large')
        value = data.decode().strip()
        if not value or any(ord(c) < 33 or ord(c) > 126 for c in value):
            raise ValueError('credential must contain exactly one printable token')
        return value
    finally:
        os.close(fd)


def normal_text(value):
    if not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('text must be a nonempty single line without terminal controls')


class OutputGuard:
    """Hold possible secret prefixes across reads; fail closed on any full echo."""
    def __init__(self, values):
        self.values = values
        self.pending = ''

    def feed(self, text):
        data = self.pending + text
        if any(value in data for value in self.values):
            raise SecretExposure('credential echo detected; output suppressed')
        keep = 0
        for value in self.values:
            for size in range(1, min(len(value), len(data) + 1)):
                if data.endswith(value[:size]):
                    keep = max(keep, size)
        self.pending = data[-keep:] if keep else ''
        return data[:-keep] if keep else data


class Screen:
    def __init__(self):
        self.screen = pyte.HistoryScreen(160, 50, history=500)
        self.stream = pyte.Stream(self.screen)

    def feed(self, text):
        self.stream.feed(text)

    def lines(self):
        return [line.rstrip() for line in self.screen.display]

    def secure(self):
        # A past label in scrollback or an ordinary question is not permission.
        lines = self.lines()
        row = self.screen.cursor.y
        return (row > 0 and LABEL in lines[row - 1]
                and lines[row].lstrip().startswith('›'))

    def masked(self, canary):
        lines = self.lines()
        return (self.secure() and canary not in '\n'.join(lines)
                and lines[self.screen.cursor.y].strip() == '› ' + '•' * len(canary))


class Terminal:
    def __init__(self, command, credentials):
        self.values = {name: read_credential(path) for name, path in credentials.items()}
        self.guard = OutputGuard(list(self.values.values()))
        self.screen = Screen()
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.failed = False
        self.alive = True
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.execvp(command[0], command)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 160, 0, 0))

    def drain(self, seconds=0.2):
        until = time.monotonic() + seconds
        while self.alive and time.monotonic() < until:
            if not select.select([self.fd], [], [], min(0.05, max(0, until - time.monotonic())))[0]:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                data = b''
            if not data:
                self.alive = False
                break
            try:
                self.screen.feed(self.guard.feed(self.decoder.decode(data)))
                visible = '\n'.join(self.screen.lines())
                if any(value in visible for value in self.values.values()):
                    raise SecretExposure('credential echo detected; output suppressed')
            except SecretExposure:
                self.failed = True
                raise

    def write(self, text):
        if self.failed or not self.alive:
            raise ValueError('terminal is unavailable')
        data = text.encode()
        while data:
            data = data[os.write(self.fd, data):]

    def block(self):
        self.failed = True
        if self.alive:
            os.close(self.fd)
            self.alive = False

    def act(self, request):
        if self.failed:
            raise SecretExposure('output blocked after credential echo; inspect privately')
        self.drain()
        action = request['action']
        if action == 'text':
            text = request['text']
            normal_text(text)
            if self.screen.secure() or any(value in text for value in self.values.values()):
                raise ValueError('ordinary text is forbidden for credential entry')
            # The terminal decides whether this is a menu filter or conversation.
            self.write(text)
            self.drain(0.15)
            if request.get('enter', True):
                self.write('\r')
        elif action == 'key':
            self.write(KEYS[request['key']])
        elif action == 'secret':
            if request['name'] not in self.values:
                raise ValueError('unknown credential alias')
            if not self.screen.secure():
                raise ValueError('no active masked API-key field at the cursor')
            # Never trust a label alone. Enter a PUBLIC random canary without
            # Enter, verify it renders as bullets, then clear it before the key.
            canary = 'probe' + secrets.token_hex(4)
            self.write(canary)
            self.drain(0.6)
            if not self.screen.masked(canary):
                self.write(KEYS['clear'])
                raise ValueError('mask probe failed; no credential was submitted')
            self.write(KEYS['clear'])
            self.drain(0.3)
            if not self.screen.secure() or self.screen.lines()[self.screen.screen.cursor.y].strip() != '›':
                raise ValueError('secure field did not clear; no credential was submitted')
            self.write(self.values[request['name']])
            self.drain(0.3)
            if not self.screen.masked(self.values[request['name']]):
                raise SecretExposure('secure field changed during entry; output suppressed')
            self.write('\r')
        elif action != 'screen':
            raise ValueError('unknown operator action')
        self.drain(0.3)
        return {'alive': self.alive, 'secure_field': self.screen.secure(),
                'screen': '\n'.join(self.screen.lines()).rstrip()}


def send_reply(connection, result):
    """A client timeout must not dispose the terminal or replay its action."""
    try:
        connection.sendall(json.dumps(result).encode() + b'\n')
    except (BrokenPipeError, ConnectionResetError, TimeoutError):
        return False
    return True


def serve(args):
    directory = args.socket.parent
    info = directory.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('socket directory must be private and owned by the operator')
    credentials = {}
    for entry in args.credential:
        name, path = entry.split('=', 1)
        if not name or name in credentials:
            raise ValueError('credential aliases must be unique')
        credentials[name] = Path(path)
    command = ['ssh', '-tt', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
               '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
               '-o', 'ConnectTimeout=10', '-i', str(args.ssh_key), '-p', str(args.port),
               'installer@127.0.0.1']
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(args.socket))
    args.socket.chmod(0o600)
    listener.listen(1)
    terminal = Terminal(command, credentials)
    print('Private operator ready; no terminal or credential log is written.', flush=True)
    try:
        while True:
            ready = select.select([listener, terminal.fd] if terminal.alive else [listener], [], [], 0.2)[0]
            if terminal.fd in ready and not terminal.failed:
                try:
                    terminal.drain()
                except SecretExposure:
                    terminal.block()
            if listener not in ready:
                continue
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(5)
                try:
                    data = b''
                    while b'\n' not in data:
                        part = connection.recv(65536)
                        if not part or len(data) > 65536:
                            raise ValueError('invalid operator request')
                        data += part
                    request = json.loads(data)
                    if request['action'] == 'close':
                        if terminal.alive:
                            raise ValueError('exit the SSH shell before closing the operator')
                        send_reply(connection, {'closed': True})
                        break
                    result = terminal.act(request)
                except Exception as error:
                    if isinstance(error, SecretExposure):
                        terminal.block()
                    # Never stringify exceptions carrying a command, key, or buffer.
                    result = {'error': type(error).__name__, 'message':
                              'Action refused. Check the current field, credential alias, and private-file permissions.'}
                send_reply(connection, result)
    finally:
        listener.close()
        args.socket.unlink(missing_ok=True)
        if not terminal.failed:
            os.close(terminal.fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True, type=Path)
    commands = parser.add_subparsers(dest='action', required=True)
    start = commands.add_parser('serve')
    start.add_argument('--port', required=True, type=int)
    start.add_argument('--ssh-key', required=True, type=Path)
    start.add_argument('--credential', action='append', default=[], help='alias=/private/single-line-key-file')
    commands.add_parser('screen')
    commands.add_parser('close')
    text = commands.add_parser('text')
    text.add_argument('text')
    text.add_argument('--no-enter', dest='enter', action='store_false')
    key = commands.add_parser('key')
    key.add_argument('key', choices=KEYS)
    secret = commands.add_parser('secret')
    secret.add_argument('name', help='Previously registered alias, never the key value')
    args = parser.parse_args()
    if args.action == 'serve':
        serve(args)
        return
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(10)
        client.connect(str(args.socket))
        client.sendall(json.dumps({k: v for k, v in vars(args).items() if k != 'socket'}).encode() + b'\n')
        data = b''
        while not data.endswith(b'\n'):
            part = client.recv(65536)
            if not part:
                raise SystemExit('operator connection closed')
            data += part
        print(data.decode().rstrip())


if __name__ == '__main__':
    main()
