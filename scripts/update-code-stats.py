#!/usr/bin/env python3
"""Refresh README and SVG line counts from the four checked-out repositories.

Run `python3 scripts/update-code-stats.py` after updating pinned submodules.
Run with `--check` to verify the committed figures without changing files.
Counts are physical lines in tracked source files, including tests. Markdown,
configuration, data, lockfiles, and nested gitlinks are excluded.
"""

import argparse
from collections import Counter
from html import escape
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
REPOSITORIES = (
    ("machtiani-harness", "machtiani-harness", "the agent harness"),
    ("dearmachine", "Dear Machine", "the email client and service"),
    ("dearmachine-concierge", "dearmachine-concierge", "the cross-platform installer"),
    (".", "machtiani (root repo)", "glue, tests and scripts"),
)
LANGUAGES = ("Go", "TypeScript", "Shell", "Python", "JavaScript", "Nix", "TLA+", "Other")
CLASSES = {"Go": "go", "TypeScript": "ts", "Shell": "sh", "Python": "py",
           "JavaScript": "js", "Nix": "nix", "TLA+": "tla", "Other": "oth"}
SUFFIXES = {
    ".go": "Go", ".ts": "TypeScript", ".tsx": "TypeScript",
    ".sh": "Shell", ".bash": "Shell", ".ps1": "Shell",
    ".py": "Python", ".js": "JavaScript", ".mjs": "JavaScript",
    ".cjs": "JavaScript", ".jsx": "JavaScript", ".nix": "Nix",
    ".tla": "TLA+", ".exp": "Other", ".cs": "Other",
    ".c": "Other", ".h": "Other", ".cc": "Other",
    ".cpp": "Other", ".rs": "Other",
}


def git(repo, *args):
    return subprocess.check_output(("git", "-C", str(repo), *args))


def source_language(repo_name, path, contents):
    if repo_name == "dearmachine" and path.as_posix() == "dearmachine/internal/client/guest_policy.go":
        # The exact production source is also verified with Gobra.
        return "Other"
    if path.name.startswith("Dockerfile"):
        return "Other"
    language = SUFFIXES.get(path.suffix.lower())
    if language:
        return language
    if not path.suffix and contents.startswith(b"#!"):
        first_line = contents.split(b"\n", 1)[0].lower()
        if b"python" in first_line:
            return "Python"
        if b"node" in first_line:
            return "JavaScript"
        if b"sh" in first_line or b"bash" in first_line:
            return "Shell"
    return None


def count_repository(name):
    repo = ROOT / name
    if name != ".":
        # A checkout at a different commit would make the published figures misleading.
        index_line = git(ROOT, "ls-files", "--stage", "--", name).decode().strip()
        pinned = index_line.split()[1] if index_line.startswith("160000 ") else None
        actual = git(repo, "rev-parse", "HEAD").decode().strip()
        if pinned != actual:
            raise RuntimeError(f"{name} is not checked out at its pinned commit")
    paths = [Path(p.decode("utf-8", "surrogateescape"))
             for p in git(repo, "ls-files", "-z").split(b"\0") if p]
    if name == ".":
        # Include this script on its first run, before it has been git-added.
        script = Path("scripts/update-code-stats.py")
        if script not in paths:
            paths.append(script)
    counts = Counter()
    for path in paths:
        file = repo / path
        if not file.is_file() or file.is_symlink():
            continue  # Nested gitlinks and symlinks are not source files.
        contents = file.read_bytes()
        if b"\0" in contents:
            continue
        language = source_language(name, path, contents)
        if language:
            counts[language] += contents.count(b"\n") + bool(contents and not contents.endswith(b"\n"))
    return counts


def fmt(count):
    return f"{count:,}"


def pct(part, whole, digits=1):
    return f"{100 * part / whole:.{digits}f}"


def text_element(css, x, y, value, **attrs):
    extra = "".join(f' {key.replace("_", "-")}="{escape(str(val), quote=True)}"'
                    for key, val in attrs.items())
    return f'<text class="{css}" x="{x}" y="{y}"{extra}>{escape(str(value))}</text>'


def bar(counts, x, y, width, height, total, order, labels=()):
    present = [(lang, counts[lang]) for lang in order if counts[lang]]
    gap = 2
    available = width - gap * (len(present) - 1)
    raw = [available * count / total for _, count in present]
    widths = [max(4.0, amount) for amount in raw]
    overflow = sum(widths) - available
    if overflow:
        adjustable = sum(amount - 4 for amount in widths if amount > 4)
        widths = [amount - overflow * (amount - 4) / adjustable if amount > 4 else amount
                  for amount in widths]
    elements = []
    cursor = float(x)
    for index, ((language, _), segment_width) in enumerate(zip(present, widths)):
        right = cursor + segment_width
        if len(present) == 1:
            shape = f'M{cursor + 4:.1f} {y}H{right - 4:.1f}a4 4 0 0 1 4 4V{y + height - 4}a4 4 0 0 1 -4 4H{cursor + 4:.1f}a4 4 0 0 1 -4 -4V{y + 4}a4 4 0 0 1 4 -4Z'
        elif index == 0:
            shape = f'M{cursor + 4:.1f} {y}H{right:.1f}V{y + height}H{cursor + 4:.1f}a4 4 0 0 1 -4 -4V{y + 4}a4 4 0 0 1 4 -4Z'
        elif index == len(present) - 1:
            shape = f'M{cursor:.1f} {y}H{right - 4:.1f}a4 4 0 0 1 4 4V{y + height - 4}a4 4 0 0 1 -4 4H{cursor:.1f}Z'
        else:
            shape = f'M{cursor:.1f} {y}H{right:.1f}V{y + height}H{cursor:.1f}Z'
        cls = CLASSES[language]
        elements.append(f'<path class="f-{cls}" d="{shape}"/>')
        if language in labels and segment_width >= 23:
            label = language
            if segment_width >= 75:
                label += f' {pct(counts[language], total)}%'
            elif language == "Python" and segment_width < 35:
                label = f'{pct(counts[language], total, 0)}%'
            elements.append(text_element(f'in i-{cls}', f'{(cursor + right) / 2:.1f}',
                                         f'{y + height / 2:.1f}', label,
                                         text_anchor="middle", dominant_baseline="central"))
        cursor = right + gap
    return "\n".join(elements)


def render_svg(style, by_repo):
    total_counts = sum(by_repo.values(), Counter())
    order = sorted(LANGUAGES, key=lambda language: total_counts[language], reverse=True)
    total = total_counts.total()
    root_counts = by_repo["."]
    root = root_counts.total()
    share = pct(root, total, 0)
    description = (f"The umbrella repository contains {fmt(root)} of the {fmt(total)} lines of source "
                   f"in the four repositories. Together they contain {pct(total_counts['Go'], total, 0)} percent Go, "
                   f"{pct(total_counts['TypeScript'], total, 0)} percent TypeScript, "
                   f"{pct(total_counts['Shell'], total, 0)} percent Shell, and "
                   f"{pct(total_counts['Python'], total, 0)} percent Python. "
                   + "; ".join(f"{title}: {fmt(by_repo[name].total())} lines"
                               for name, title, _ in REPOSITORIES) + ".")
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="-24 -16 928 643" width="928" height="643" role="img" aria-labelledby="t d">',
           '<title id="t">Machtiani code statistics by repository</title>',
           f'<desc id="d">{escape(description)}</desc>', style,
           text_element('title', 0, 26, 'Where the code actually lives'),
           text_element('sub', 0, 50, f'GitHub’s language bar reads one repository. Machtiani is four — {fmt(total)} lines of code in all.'),
           '<line class="rule" x1="0" y1="72" x2="880" y2="72"/>',
           text_element('h', 0, 92, 'Umbrella repository alone'),
           text_element('note', 880, 92, f'{fmt(root)} lines · {share}% of the project', text_anchor='end'),
           bar(root_counts, 0, 106, 880, 30, root, order, ('Python', 'Shell', 'Go')),
           text_element('note', 0, 156, f'The root repo holds glue, tests and scripts. GitHub’s language bar misses the product submodules and {pct(total-root, total, 0)}% of the code.'),
           '<line class="rule" x1="0" y1="192" x2="880" y2="192"/>',
           text_element('h', 0, 214, 'What the four repositories contain'),
           text_element('note', 880, 214, f'{fmt(total)} lines of code', text_anchor='end'),
           bar(total_counts, 0, 228, 880, 30, total, order, ('Go', 'TypeScript', 'Shell', 'Python')),
           text_element('h2', 0, 292, 'By repository')]
    for index, (name, title, subtitle) in enumerate(REPOSITORIES):
        y = 308 + 42 * index
        counts = by_repo[name]
        count = counts.total()
        out += [text_element('rl', 0, y + 9, title, dominant_baseline='central'),
                text_element('rs', 0, y + 23, subtitle, dominant_baseline='central'),
                text_element('rv', 192, y + 13, fmt(count), text_anchor='end', dominant_baseline='central'),
                bar(counts, 208, y, 672, 26, count, order,
                    ('Go',) if name in ('machtiani-harness', 'dearmachine') else
                    ('TypeScript',) if name == 'dearmachine-concierge' else ('Shell', 'Python', 'Go'))]
    out.append('<line class="rule" x1="0" y1="484" x2="880" y2="484"/>')
    for index, language in enumerate(order):
        col, row = index % 5, index // 5
        x, y = col * 176, 502 + row * 22
        cls = CLASSES[language]
        out += [f'<rect class="f-{cls}" x="{x}" y="{y}" width="10" height="10" rx="2"/>',
                text_element('lg', x + 16, y + 8, language),
                text_element('lgv', x + 16 + max(28, len(language) * 7), y + 8,
                             fmt(total_counts[language]))]
    out += [text_element('foot', 0, 566, 'Lines in git-tracked source files, including tests; prose, config, data and lockfiles are excluded, as are nested third-party submodules.'),
            text_element('foot', 0, 581, 'PowerShell counts as Shell. Other includes Dockerfile, Expect, C# and the 37-line Go policy file verified by Gobra.'),
            text_element('foot', 0, 596, 'Tiny segments have a minimum width for visibility. Counts use the checked-out umbrella repo and its pinned submodule commits.'),
            '</svg>']
    return '\n'.join(out) + '\n'


def render_readme(original, by_repo):
    counts = sum(by_repo.values(), Counter())
    total = counts.total()
    root_share = pct(by_repo['.'].total(), total, 0)
    result, n = re.subn(r'\*\*[\d,]+ lines of code\*\*',
                        f'**{fmt(total)} lines of code**', original, count=1)
    if n != 1:
        raise RuntimeError('README total was not found')
    result, n = re.subn(r'about \d+% of the project', f'about {root_share}% of the project', result, count=1)
    if n != 1:
        raise RuntimeError('README root percentage was not found')
    alt = (f'Code breakdown across the four repositories: '
           f'{pct(counts["Go"], total, 0)}% Go, '
           f'{pct(counts["TypeScript"], total, 0)}% TypeScript, '
           f'{pct(counts["Shell"], total, 0)}% Shell and '
           f'{pct(counts["Python"], total, 0)}% Python, plus {fmt(counts["TLA+"])} lines of TLA+ specifications and other source')
    result, n = re.subn(r'Code breakdown across the four repositories: [^"\n]+', alt, result, count=1)
    if n != 1:
        raise RuntimeError('README chart description was not found')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail if published figures differ from source')
    args = parser.parse_args()
    by_repo = {name: count_repository(name) for name, _, _ in REPOSITORIES}
    svg_file = ROOT / 'assets/code-stats-current.svg'
    readme_file = ROOT / 'README.md'
    svg = svg_file.read_text()
    style_match = re.search(r'<style>.*?</style>', svg, re.DOTALL)
    if not style_match:
        raise RuntimeError('SVG style block was not found')
    updated = {svg_file: render_svg(style_match.group(), by_repo),
               readme_file: render_readme(readme_file.read_text(), by_repo)}
    stale = [path for path, content in updated.items() if path.read_text() != content]
    if args.check:
        if stale:
            parser.error('stale code stats: ' + ', '.join(str(p.relative_to(ROOT)) for p in stale))
    else:
        for path in stale:
            path.write_text(updated[path])
    for name, _, _ in REPOSITORIES:
        print(f'{name}: {fmt(by_repo[name].total())} lines')
    print(f'total: {fmt(sum(by_repo.values(), Counter()).total())} lines')
    if not args.check:
        print('updated: ' + (', '.join(str(p.relative_to(ROOT)) for p in stale) if stale else 'nothing'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        sys.exit(str(error))
