#!/usr/bin/env python3
"""One packaged Machtiani, real installer setup and DearMachine invocation.

Default: deterministic loopback provider. --live-profile forwards the same
observed requests to explicitly selected real models; it never sends email.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import threading
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]


def private_text(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('live inputs must be owned private regular files')
    return path.read_text()


def run(args, env, cwd, succeeds=True):
    process = subprocess.Popen(list(map(str, args)), env=env, cwd=cwd,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=240)
    except BaseException:
        # The installer and native runner launch children. Own their complete
        # process group so a timeout cannot leave a model-host process behind.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    if (result.returncode == 0) != succeeds:
        # Only disposable fixture credentials reach child processes. The live
        # keys stay in the forwarding server, never argv, env, or transcripts.
        raise AssertionError(f'{Path(args[0]).name} {args[1:3]}: {result.stdout}\n{result.stderr}')
    return result


def digest(paths):
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--machtiani', required=True, type=Path)
    parser.add_argument('--installer-runtime', required=True, type=Path,
                        help='packaged libexec/machtiani-installer directory')
    parser.add_argument('--model-host', required=True, type=Path)
    parser.add_argument('--node', default=shutil.which('node'), type=Path)
    parser.add_argument('--live-profile', type=Path,
                        help='private JSON with personal/managed endpoint, model, key_file')
    args = parser.parse_args()
    if args.node is None:
        parser.error('Node is required; pass --node /absolute/path/to/node')
    for field in ('machtiani', 'installer_runtime', 'model_host', 'node'):
        setattr(args, field, getattr(args, field).resolve(strict=True))
    upstream = {}
    if args.live_profile:
        upstream = json.loads(private_text(args.live_profile))
        for label in ('personal', 'managed'):
            value = upstream[label]
            if not value['endpoint'].startswith('https://'):
                raise ValueError('live endpoints must use HTTPS')
            value['key'] = private_text(value['key_file']).strip()
            if not value['key'] or any(c.isspace() for c in value['key']):
                raise ValueError('invalid live key file')
        if upstream['personal']['model'] == upstream['managed']['model']:
            raise ValueError('the live evaluation requires two different model IDs')
    models = {label: upstream[label]['model'] if upstream else label + '-model'
              for label in ('personal', 'managed')}
    initial_models = models.copy()
    seen, errors = [], []

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *unused):
            return None

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                if self.path != '/v1/chat/completions':
                    raise ValueError('unexpected endpoint')
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                key = self.headers.get('Authorization', '')
                labels = [label for label in models if key == 'Bearer ' + label + '-fixture-key']
                if len(labels) != 1:
                    raise ValueError('wrong credential selected')
                label = labels[0]
                if data.get('model') != models[label]:
                    raise ValueError('model and credential came from different configurations')
                seen.append((label, data['model']))
                if upstream:
                    target = upstream[label]
                    request = urllib.request.Request(target['endpoint'], data=json.dumps(data).encode(),
                        headers={'Authorization': 'Bearer ' + target['key'], 'Content-Type': 'application/json'})
                    # Refuse redirects rather than forwarding credentials elsewhere.
                    with urllib.request.build_opener(NoRedirect).open(request, timeout=180) as reply:
                        body = reply.read()
                        content_type = reply.headers.get('Content-Type', 'application/json')
                else:
                    text = json.dumps(data.get('messages', []))
                    content = ('BEGIN_RELEVANT_FILES[file-discovery]\nREADME.md\nEND_RELEVANT_FILES[file-discovery]\n'
                               if 'BEGIN_RELEVANT_FILES[file-discovery]' in text and 'file_search' in text
                               else '# Internal README\n\nConfiguration coexistence fixture.\n')
                    if 'Reply with the single word READY' in text:
                        content = 'READY'
                    choice = {'index': 0, 'message': {'role': 'assistant', 'content': content}, 'finish_reason': 'stop'}
                    payload = {'id': 'coexistence', 'object': 'chat.completion', 'created': 1,
                               'model': data['model'], 'choices': [choice],
                               'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}}
                    content_type = 'application/json'
                    if data.get('stream'):
                        choice['delta'] = choice.pop('message')
                        payload['object'] = 'chat.completion.chunk'
                        body = ('data: ' + json.dumps(payload) + '\n\ndata: [DONE]\n\n').encode()
                        content_type = 'text/event-stream'
                    else:
                        body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as error:
                # Do not retain upstream response bodies or authorization headers.
                errors.append(type(error).__name__ + (f' HTTP {error.code}' if isinstance(error, urllib.error.HTTPError) else ''))
                self.send_response(502)
                self.end_headers()
                self.wfile.write(b'coexistence provider failed')

    with tempfile.TemporaryDirectory(prefix='machtiani-coexistence-') as tmp:
        root = Path(tmp)
        source = root / 'source'
        source.mkdir()
        archive = root / 'dearmachine.tar'
        subprocess.run(['git', '-C', str(ROOT / 'dearmachine'), 'archive', 'HEAD', '-o', str(archive)], check=True)
        with tarfile.open(archive) as tar:
            tar.extractall(source, filter='data')
        module = source / 'dearmachine'
        probe = module / 'coexistence-probe'
        probe.mkdir()
        shutil.copyfile(Path(__file__).with_name('driver.go'), probe / 'main.go')
        driver = root / 'driver'
        subprocess.run(['go', 'build', '-o', str(driver), './coexistence-probe'], cwd=module, check=True, timeout=180)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        endpoint = f'http://127.0.0.1:{server.server_port}/v1'
        try:
            for scenario in ('standalone-first', 'dearmachine-first', 'legacy-migration'):
                models.update(initial_models)
                home = root / scenario
                home.mkdir()
                env = {'HOME': str(home), 'XDG_CONFIG_HOME': str(home / '.config'),
                       'PATH': os.environ['PATH'], 'MACHTIANI_UPDATE_REEXEC': '1',
                       'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                       'GIT_AUTHOR_NAME': 'Fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                       'GIT_COMMITTER_NAME': 'Fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'}
                public = home / '.local/bin/machtiani'
                public.parent.mkdir(parents=True)
                public.symlink_to(args.machtiani)
                personal = home / '.config/machtiani/config.toml'
                managed = home / '.config/dearmachine/machtiani/config.toml'
                personal_files = [personal, personal.with_name('credentials.env')]
                managed_files = [managed, home / '.config/machtiani/model-profile.json',
                                 home / '.config/dearmachine/backends.env']

                def setup_personal():
                    run([public, 'config', 'add', '--global', '--provider', 'fixture', '--url', endpoint,
                         '--api-key', 'personal-fixture-key', '--model', models['personal'],
                         '--alias', 'fixture', '--no-interactive'], env, home)

                def setup_managed():
                    run([args.node, Path(__file__).with_name('setup.mjs'), args.installer_runtime,
                         public, args.model_host, endpoint + '/chat/completions', models['managed']], env, home)

                if scenario == 'standalone-first':
                    setup_personal()
                    before = digest(personal_files)
                    setup_managed()
                    assert digest(personal_files) == before, 'installer changed native configuration'
                elif scenario == 'dearmachine-first':
                    setup_managed()
                    before = digest(managed_files)
                    setup_personal()
                    assert digest(managed_files) == before, 'native setup changed managed configuration'
                else:
                    # Old DearMachine used a shared TOML plus backend env keys.
                    legacy = home / '.machtiani/config.toml'
                    legacy.parent.mkdir()
                    legacy.write_text(f'default_model = "fixture"\n[providers.fixture]\nbase_url = "{endpoint}"\n'
                                      'api_key = "${LEGACY_API_KEY}"\n[models.fixture]\nprovider = "fixture"\n'
                                      f'model = {json.dumps(models["managed"])}\n')
                    backend = home / '.config/dearmachine/backends.env'
                    backend.parent.mkdir(parents=True)
                    backend.write_text('LEGACY_API_KEY=managed-fixture-key\nUNRELATED_KEY=unused-fixture\n')
                    backend.chmod(0o600)
                    original = digest([legacy, backend])
                    run([driver, 'migrate', public, home], env, home)
                    assert digest([legacy, backend]) == original, 'migration modified the source'
                    assert 'UNRELATED_KEY' not in managed.with_name('credentials.env').read_text()
                    # Explicit native setup after import independently selects a model.
                    setup_personal()
                    assert digest([legacy, backend]) == original, 'native setup modified the legacy source'
                    managed_files = [managed, managed.with_name('credentials.env')]

                configs = personal_files + managed_files
                before = digest(configs)
                def verify(label, phase, succeeds=True, extra_environment=None):
                    repo = home / (label + '-repo-' + phase)
                    selected = {**env, **({'MACHTIANI_CONFIG': str(managed)} if label == 'managed' else {})}
                    if not repo.exists():
                        repo.mkdir()
                        run(['git', 'init', '--initial-branch=main'], env, repo)
                        (repo / 'README.md').write_text('# Coexistence fixture\n')
                        run(['git', 'add', 'README.md'], env, repo)
                        run(['git', '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture'], env, repo)
                        run([public, 'init', '--no-interactive'], selected, repo)
                    start = len(seen)
                    if label == 'personal':
                        run([public, 'sync'], env, repo, succeeds=succeeds)
                    else:
                        # Deliberately inherit the personal selector. Production
                        # DearMachine must replace it before launching Machtiani.
                        run([driver, 'sync', public, repo],
                            {**env, **(extra_environment or {}), 'MACHTIANI_CONFIG': str(personal)}, repo,
                            succeeds=succeeds)
                    if not succeeds:
                        assert len(seen) == start, 'missing managed credentials reached the provider'
                        return
                    assert len(seen) > start, 'sync made no provider request'
                    assert all(row == (label, models[label]) for row in seen[start:]), 'wrong model selected'
                    assert digest(configs) == before, 'execution modified configuration or credentials'
                    assert public.resolve() == args.machtiani, 'the shared executable changed'

                for index, label in enumerate(('personal', 'managed', 'personal', 'managed')):
                    verify(label, str(index))

                # Change both model choices after coexistence is established.
                # Each writer must preserve the other configuration and key.
                managed_before = digest(managed_files)
                run([public, 'config', 'model', 'set', 'fixture', '--global',
                     '--model', initial_models['managed'], '--no-interactive'], env, home)
                assert digest(managed_files) == managed_before, 'native model edit changed DearMachine'
                personal_before = digest(personal_files)
                managed_alias = 'fixture' if scenario == 'legacy-migration' else 'dearmachine'
                run([public, 'config', 'model', 'set', managed_alias,
                     '--model', initial_models['personal'], '--no-interactive'],
                    {**env, 'MACHTIANI_CONFIG': str(managed)}, home)
                if scenario != 'legacy-migration':
                    # Custom model-host profiles advertise their selected model.
                    # Update that selection through the production profile writer.
                    run([args.node, Path(__file__).with_name('setup.mjs'), args.installer_runtime,
                         public, args.model_host, endpoint + '/chat/completions',
                         initial_models['personal'], 'select-model'], env, home)
                assert digest(personal_files) == personal_before, 'managed model edit changed native settings'
                models.update(personal=initial_models['managed'], managed=initial_models['personal'])
                before = digest(configs)
                verify('personal', 'changed-model')
                verify('managed', 'changed-model')

                if scenario == 'legacy-migration':
                    run([driver, 'migrate', public, home], env, home)
                    assert digest(configs) == before, 'repeated migration overwrote configured choices'
                # Deleting only DearMachine credentials must not fall back to
                # personal config or a matching key inherited from the shell.
                missing = managed_files[-1]
                contents = missing.read_bytes()
                variables = {line.split('=', 1)[0]: 'personal-fixture-key'
                             for line in contents.decode().splitlines() if '=' in line}
                missing.unlink()
                start = len(seen)
                verify('managed', 'missing-credentials', succeeds=False, extra_environment=variables)
                assert len(seen) == start, 'missing managed credentials reached the provider'
                configs = personal_files
                before = digest(configs)
                verify('personal', 'missing-managed-credentials')
                assert all(row == ('personal', models['personal']) for row in seen[start:])
                assert len(seen) > start, 'personal config stopped working'
                assert not errors, f'provider errors: {errors}'
                print(f'PASS {scenario}: shared binary, independent models/keys, preservation, fail-closed credentials', flush=True)
            print(f'PASS {"LIVE" if upstream else "LOOPBACK"}: {len(seen)} observed provider requests; models={models}', flush=True)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
