#!/usr/bin/env python3
"""Adaptive OpenRouter user rehearsal through the existing private terminal bridge."""
import argparse
import json
import os
from pathlib import Path
import socket
import time
import urllib.request

from importlib.util import spec_from_file_location, module_from_spec


def bridge(path, action):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(40)
        connection.connect(str(path))
        connection.sendall(json.dumps(action).encode() + b'\n')
        response = b''
        while b'\n' not in response:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError('Operator bridge disconnected; inspect before replaying any action')
            response += chunk
        return json.loads(response.split(b'\n')[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--key-file', required=True, type=Path)
    parser.add_argument('--scenario-file', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--model', required=True)
    parser.add_argument('--reasoning', choices=['low', 'medium', 'high'], required=True)
    parser.add_argument('--max-turns', type=int, default=100)
    args = parser.parse_args()
    spec = spec_from_file_location('terminal_operator', Path(__file__).with_name('operator.py'))
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    key = module.read_credential(args.key_file)
    if args.evidence.exists():
        raise ValueError('Use a new private evidence file')
    args.evidence.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.evidence.parent.stat().st_mode & 0o077:
        raise ValueError('Evidence directory must be private')
    instructions = '''Act as the user testing the actual Dear Machine installer through its rendered terminal.
Read the screen, decide one next action, then observe the result.
Named keys are lowercase: enter, escape, up, down, left, right, tab, ctrl-c, clear. Do not use a canned sequence.
The text action submits Enter immediately. In a model menu, enter the exact full model ID, never a partial name.
Only enter secrets through the secret action and an approved alias, after seeing the masked API-key field.
Never ask for or print a credential value. Do not log in to subscription accounts.
Use the scenario's exact model and reasoning. Respect prompts, choices, and approvals already given.
Use key escape to test interruption only when a message is visibly queued, never during secure entry.
Do not fix failures through out-of-band shell commands or claim an incomplete installation passed.
When waiting for build/model work, use wait. Report concrete failures and stop when human action is needed.
You may type shell commands only in this disposable test terminal. Never access unrelated inboxes.
'''
    messages = [{'role': 'system', 'content': instructions}, {'role': 'user', 'content': args.scenario_file.read_text()}]
    tools = [{'type': 'function', 'function': {'name': 'terminal', 'description': 'Observe or operate the current terminal. Each action is followed by an observation.',
        'parameters': {'type': 'object', 'properties': {'action': {'type': 'string', 'enum': ['screen', 'text', 'key', 'secret', 'wait']},
            'value': {'type': 'string', 'description': 'Text, named key, or registered secret alias. Never a credential value.'}}, 'required': ['action'], 'additionalProperties': False}}}]
    descriptor = os.open(args.evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as evidence:
        for turn in range(args.max_turns):
            body = {'model': args.model, 'reasoning': {'effort': args.reasoning}, 'messages': messages, 'tools': tools, 'max_tokens': 4096}
            request = urllib.request.Request('https://openrouter.ai/api/v1/chat/completions', data=json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=180) as response:
                result = json.load(response)
            if result.get('model') != args.model:
                raise RuntimeError('Provider returned a different model; inspect before continuing')
            answer = result['choices'][0]['message']
            if key in json.dumps(answer):
                raise RuntimeError('Credential exposure detected; response suppressed')
            messages.append({k: v for k, v in answer.items() if k in ('role', 'content', 'tool_calls')})
            calls = answer.get('tool_calls', [])
            evidence.write(json.dumps({'turn': turn, 'answer': messages[-1]}) + '\n')
            evidence.flush()
            if not calls:
                print(answer.get('content') or 'Operator stopped without a result.')
                return
            for call in calls:
                action = json.loads(call['function']['arguments'])
                if action['action'] == 'wait':
                    time.sleep(5)
                    output = bridge(args.socket, {'action': 'screen'})
                else:
                    value = action.get('value', '')
                    if key in value:
                        raise RuntimeError('Refusing credential material in terminal action')
                    payload = {'action': action['action']}
                    if action['action'] == 'text': payload.update(text=value, enter=True)
                    elif action['action'] == 'key': payload['key'] = {'return': 'enter', 'esc': 'escape'}.get(value.lower(), value.lower())
                    elif action['action'] == 'secret': payload['name'] = value
                    output = bridge(args.socket, payload)
                messages.append({'role': 'tool', 'tool_call_id': call['id'], 'content': json.dumps(output)})
                evidence.write(json.dumps({'turn': turn, 'result': output}) + '\n')
                evidence.flush()
            print(f'Operator turn {turn + 1}: {len(calls)} terminal action(s)', flush=True)
        raise RuntimeError('Operator reached its turn limit; installation is not an automatic pass')


if __name__ == '__main__':
    main()
