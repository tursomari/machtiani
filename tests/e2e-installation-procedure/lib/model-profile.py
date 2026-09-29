#!/usr/bin/env python3
"""Supply the wizard-owned IPE prerequisite and verify model-host consumers."""
import json
import os
from pathlib import Path
import stat
import sys
import tomllib


def paths():
    home = Path.home()
    return (home / '.config/machtiani/model-profile.json',
            home / '.config/dearmachine/backends.env')


# The managed model aliases and roles documented in docs/installation-procedure.md.
MANAGED_ALIASES = {'dearmachine': '@machtiani/planner', 'dearmachine-shell-agent': '@machtiani/shell-agent',
                   'dearmachine-sync': '@machtiani/sync'}
MANAGED_ROLES = dict(default_model='dearmachine', shell_agent_model='dearmachine-shell-agent',
                     answer_model='dearmachine', file_discovery_model='dearmachine')


def expected_profile():
    _, credentials = paths()
    profile = dict(version=1, driver='pi-ai', authMethod='api_key',
                provider=os.environ['IPE_MACHTIANI_PROVIDER_ID'],
                model=os.environ['IPE_LLM_MODEL'],
                reasoningEffort=os.environ['IPE_LLM_REASONING'],
                credential=dict(kind='environment-file', path=str(credentials),
                                variable=credential_variable()))
    if os.environ['IPE_MACHTIANI_PROVIDER_ID'] == 'custom-openai-remote':
        profile.update(driver='openai-compatible', authMethod='optional_api_key',
                       customProvider=dict(kind='openai-compatible', scope='remote',
                                           name='DeepInfra', usesApiKey=True,
                                           chatCompletionsEndpoint='https://api.deepinfra.com/v1/openai/chat/completions'))
    return profile


def credential_variable():
    if os.environ['IPE_MACHTIANI_PROVIDER_ID'] == 'custom-openai-remote':
        return 'MACHTIANI_CUSTOM_OPENAI_REMOTE_API_KEY'
    return os.environ['IPE_LLM_CREDENTIAL_ENV']


def forge_provider():
    # This pinned Forge adapter serializes reasoning_effort for GLM.
    return [dict(id='requesty', api_key_vars='DEEPINFRA_API_KEY',
                 url_param_vars=[], response_type='OpenAI', auth_methods=[],
                 url='https://api.deepinfra.com/v1/openai/chat/completions',
                 models='https://api.deepinfra.com/v1/openai/models')]


def seed_forge():
    private_write(Path.home() / '.forge/provider.json', json.dumps(forge_provider()) + '\n')


def check_forge():
    if json.loads(private_read(Path.home() / '.forge/provider.json')) != forge_provider():
        raise ValueError('The Forge DeepInfra endpoint or credential source changed')


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(value)


def private_read(path):
    metadata = path.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600):
        raise ValueError(f'Expected owned mode-0600 regular file: {path}')
    return path.read_text()


def seed():
    profile, credentials = paths()
    variable = os.environ['IPE_LLM_CREDENTIAL_ENV']
    key = os.environ[variable]
    if not key or any(character.isspace() for character in key):
        raise ValueError('The selected model credential must be nonempty and single-line')
    private_write(credentials, credential_variable() + '=' + key + '\n')
    private_write(profile, json.dumps(expected_profile(), indent=2) + '\n')


def check():
    profile, credentials = paths()
    if json.loads(private_read(profile)) != expected_profile():
        raise ValueError('The prerequisite shared model profile changed')
    variable = os.environ['IPE_LLM_CREDENTIAL_ENV']
    if private_read(credentials) != credential_variable() + '=' + os.environ[variable] + '\n':
        raise ValueError('The prerequisite model credential file changed')
    # Both consumers have independent configurations referencing the one
    # selected profile. Neither may silently fall back to a direct provider.
    for relative in ('.config/machtiani/config.toml', '.config/dearmachine/machtiani/config.toml'):
        path = Path.home() / relative
        text = private_read(path)
        if os.environ[variable] in text:
            raise ValueError(f'Literal provider credential in {relative}')
        config = tomllib.loads(text)
        provider = config.get('providers', {}).get('dearmachine-host', {})
        if (provider.get('transport') != 'model-host'
                or Path(provider.get('profile', '')).expanduser() != profile
                or provider.get('command') != 'machtiani-model-host'
                or 'api_key' in provider):
            raise ValueError(f'{relative} does not use the documented model-host profile')
        # The selected model and reasoning live in the shared profile checked
        # above. These managed aliases must not pin either: fixed values here
        # would override later /model changes.
        models = config.get('models', {})
        for name, alias in MANAGED_ALIASES.items():
            model = models.get(name, {})
            if (model.get('provider') != 'dearmachine-host' or model.get('model') != alias
                    or 'reasoning' in model.get('params', {})):
                raise ValueError(f'{relative} does not use the documented {name} alias without a reasoning table')
        for role, name in MANAGED_ROLES.items():
            if config.get(role) != name:
                raise ValueError(f'{relative} has the wrong {role}')


if __name__ == '__main__':
    try:
        {'seed': seed, 'check': check, 'seed-forge': seed_forge, 'check-forge': check_forge}[sys.argv[1]]()
    except (ValueError, OSError, KeyError, IndexError) as error:
        # Never include malformed private file contents in diagnostics.
        if isinstance(error, (json.JSONDecodeError, tomllib.TOMLDecodeError)):
            raise SystemExit('Invalid model profile or configuration syntax')
        raise SystemExit(str(error))
