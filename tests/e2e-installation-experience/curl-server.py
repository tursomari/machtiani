#!/usr/bin/env python3
"""Serve only release artifacts, on container loopback, without listings."""
import argparse
import http.server
from pathlib import Path

PUBLIC = {'/install', '/manifest.json', '/closure.nar.gz', '/source.tar.gz', '/runtime.tar.gz'}


class Handler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        if self.path not in PUBLIC or (Path(self.directory) / self.path[1:]).is_symlink():
            self.send_error(404)
            return None
        return super().send_head()

    def log_message(self, format, *args):
        # Do not log arbitrary URLs/query strings from an accidental request.
        pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--port', required=True, type=int)
    args = parser.parse_args()
    http.server.ThreadingHTTPServer(('127.0.0.1', args.port),
        lambda *a, **kw: Handler(*a, directory=args.directory, **kw)).serve_forever()
