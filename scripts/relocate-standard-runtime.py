#!/usr/bin/env python3
"""Relocate a producer-verified Linux runtime into its final private release.

Invoked by bootstrap-runtime.sh using the Python and ELF loader in the bundle.
No target-side Nix, compiler, system Python, or package manager is used.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def member(root, name):
    path = Path(name)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('runtime member escapes the release')
    return root / path


def relocated(value, root, prefix='/nix/store/'):
    return value.replace(prefix, str(root / 'runtime') + '/')


def portable_shell_literals(data):
    """Keep ELF offsets intact while selecting the platform's POSIX shell.

    Git's SHELL_PATH is compiled into its binary, not configurable with PATH.
    Padding with leading slashes preserves the string length;
    Linux resolves this to /bin/sh without requiring any Nix store path.
    """
    pattern = rb'/nix/store/[a-z0-9]{32}-bash[^/\x00]*/bin/(?:ba)?sh(?=\x00)'
    return re.sub(pattern, lambda match: b'/' * (len(match[0]) - len(b'/bin/sh')) + b'/bin/sh', data)


def origin_node_library(entry, plan):
    return (not entry['interpreter'] and plan.get('node_addon_root')
            and entry['path'].startswith(plan['node_addon_root'])
            and entry['rpath'] in ('$ORIGIN', '$ORIGIN/'))


def supply_origin_libraries(root, entry, plan):
    """Preserve vendor ELFs: satisfy their existing origin search with links.

    Rewriting the prebuilt libvips dynamic layout can crash its initializer.
    Supply only missing dependencies from this Node build's own closure.
    """
    if not origin_node_library(entry, plan):
        return
    prefix = plan.get('runtime_prefix', '/nix/store/')
    parent = member(root, entry['path']).parent
    for needed in entry['needed']:
        if not needed or Path(needed).name != needed or needed in ('.', '..'):
            continue
        alias = parent / needed
        if alias.exists() or alias.is_symlink():
            continue
        for directory in plan['node_libraries'].split(':'):
            if not directory.startswith(prefix):
                continue
            target = Path(relocated(directory, root, prefix)) / needed
            if not target.resolve().is_relative_to(root.resolve()):
                raise ValueError('native library dependency escapes the release')
            if target.is_file():
                alias.symlink_to(os.path.relpath(target, parent))
                break


def elf_rpath(entry, plan):
    if origin_node_library(entry, plan):
        return entry['rpath']
    paths = [entry['rpath']]
    if entry['interpreter']:
        # CGO executables may have no RPATH. Use their own loader's libc.
        paths.append(str(Path(entry['interpreter']).parent))
    elif (entry['needed'] and plan.get('node_addon_root')
          and entry['path'].startswith(plan['node_addon_root'])):
        # npm's prebuilt addons (and libraries such as libvips) assume a
        # conventional system loader. RUNPATH is not transitive: Node finding
        # its libc does not let libvips find libresolv. Append Node's own
        # dependency directories only to libraries inside its package tree.
        # Never export a global LD_LIBRARY_PATH across different libc builds.
        paths.append(plan['node_libraries'])
    return ':'.join(dict.fromkeys(part for path in paths for part in path.split(':') if part))


def relocate(root):
    root = root.resolve()
    if any(char in '\0:\n\r\"\'$`\\' for char in str(root)):
        raise ValueError('this Linux preview requires a release path without shell metacharacters, newlines or colon')
    if any(char.isspace() for char in str(root)) and not (root / 'relocation.json').is_file():
        raise ValueError('this Linux preview requires a release path without whitespace')
    plan = json.loads((root / 'relocation.json').read_text())
    if any(char.isspace() for char in str(root)) and 'runtime_prefix' not in plan:
        raise ValueError('the Standard runtime requires a release path without whitespace')
    prefix = plan.get('runtime_prefix', '/nix/store/')
    def translate(value):
        return relocated(value, root, prefix)
    if (root / '.relocated').exists():
        if (root / '.relocated').read_text() != str(root):
            raise ValueError('an activated release cannot be moved')
        return
    for name, target in plan['symlinks'].items():
        path = member(root, name)
        path.unlink()
        path.symlink_to(translate(target))
    patcher = [str(member(root, plan['patcher_loader'])), '--library-path',
               translate(plan['patcher_libraries']), str(member(root, plan['patcher']))]
    for entry in plan['elfs']:
        path = member(root, entry['path'])
        supply_origin_libraries(root, entry, plan)
        arguments = []
        if entry['interpreter']:
            arguments += ['--set-interpreter', translate(entry['interpreter'])]
        rpath = elf_rpath(entry, plan)
        if rpath and translate(rpath) != entry['rpath']:
            arguments += ['--set-rpath', translate(rpath)]
        for needed in entry['needed']:
            if prefix in needed:
                arguments += ['--replace-needed', needed, translate(needed)]
        original = path.read_bytes()
        rewritten = portable_shell_literals(original)
        if not arguments and rewritten == original:
            continue
        # Never modify an inode mapped by this Python process or its loader.
        temporary = path.with_name(path.name + '.relocating')
        temporary.write_bytes(rewritten)
        temporary.chmod(path.stat().st_mode | 0o200)
        if arguments:
            subprocess.run([*patcher, *arguments, str(temporary)], check=True, capture_output=True)
        temporary.replace(path)
    for name in plan['texts']:
        path = member(root, name)
        path.write_bytes(path.read_bytes().replace(prefix.encode(), os.fsencode(root / 'runtime') + b'/'))
    environment = {key: translate(value) for key, value in plan['environment'].items()}
    environment['DEARMACHINE_SOURCE_ROOT'] = str(root / 'source')
    if not plan.get('bootstrap_only'):
        environment['MACHTIANI_DISTRIBUTION'] = str(root / 'distribution.json')
    environment['DEARMACHINE_CONCIERGE_BIN'] = str(root / 'bin/machtiani-installer')
    if not plan.get('bootstrap_only'):
        environment['DEARMACHINE_NATIVE_BIN'] = translate(plan['commands']['dearmachine'])
    (root / 'bin').mkdir(exist_ok=True)
    for name, command in plan['commands'].items():
        script = '#!/bin/sh\nset -eu\n'
        command_environment = {**environment, **{key: translate(value) for key, value in plan.get('command_environments', {}).get(name, {}).items()}}
        for key, value in command_environment.items():
            script += f'export {key}={shlex.quote(value)}\n'
        script += f'export PATH={shlex.quote(str(root / "bin"))}:"${{PATH:-/usr/bin:/bin}}"\n'
        # Backend installers commonly use this directory. Preserve the caller's
        # precedence and avoid relying on an interactive shell's startup files.
        script += '''case "${HOME:-}" in
  /*) case "$HOME" in
    *:*) ;;
    *) case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) export PATH="$PATH:$HOME/.local/bin" ;;
    esac ;;
  esac ;;
esac
'''
        script += f'exec {shlex.quote(translate(command))} "$@"\n'
        path = root / 'bin' / name
        path.write_text(script)
        path.chmod(0o755)
    (root / '.relocated').write_text(str(root))


if __name__ == '__main__':
    relocate(Path(sys.argv[1]))
