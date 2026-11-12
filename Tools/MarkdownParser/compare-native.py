#!/usr/bin/env python3
"""Compare native parser surfaces with the pinned, development-only JS oracle.

Compile the C bridge into a shared library and pass --library. No npm install
is required: the reference bundle is already pinned in this repository.
"""
import argparse
import ctypes
import itertools
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def corpus():
    cases = [
        '', '@target', '😀中文 @target', '\x00 @target', '\ud800 @target',
        '    @target', '    ~~~\n    @target\n    ~~~',
        '    [@target](https://example.invalid)', 'www.example.invalid/@target',
        'someone@target.invalid', 'opening `\n\n@target\n\nclosing `',
        '```\r\n@target\r\n````', '[^id]: @target',
        '[^@target]: elsewhere\n\n[^@target]', '[label](<&commat;target>)',
        'prose\n    ~~~\n    @target', '&#64;target',
        r'@con\<@ignored>tract_target', r'prefix\<@ignored>@target',
        '[label](< @target >)', '[label](<&nbsp;@target&#32;>)',
        '[@target]:', '[@target](please review)',
        '> ```\n> code\n@target', '- ```\n  code\n@target',
        '[x][id]\n\n[id]: <@target> "title"',
        '[x][id]\n\n[id]: <@target>\n[id]: other',
        '![`@target`](<@target>)', '[![x](image)](<@target>)',
        '| before | after |\n| - | - |\n| `@target` | @target |',
        '[x](<&#x40;target>)', '[x](<@ta\\_rget>)',
        # Minimized regressions found by seeded malformed-input mutations.
        '- ```\r\n-@target @target\r\n\n', '> <![alt @target](url)',
        '> a@target.inval(id', '*http://😀example.invalid/@target&amp;x',
        '- `` lang\n  @target\n  ````\n@outside', '- ```\r @target\r',
        '_www.exampl@targete.invalid/@target&amp;x)',
        'a@target.invalid> @between [id][]\n\n[id]: <@target>',
        '\ta@target.invali\\d @outside',
        'a@t@targetarget.invalid @between 😀`@target`中文\n\n[id]: <@target>',
        '*[foo* www.a.com/@target', '**[foo** www.a.com/@target',
        '~~[foo~~ www.a.com/@target', '*[foo* HTTP://a.com/@target',
    ]
    # Deterministic combinations exercise delimiters, containers, Unicode,
    # line endings, malformed syntax, and ordinary prose adjacent to ranges.
    atoms = [
        '@target', '`@target`', '`` @target ` x ``', '[@target](url)',
        '[label](<@target>)', '![alt @target](url)', '<https://e.invalid/@target>',
        '<a@target.invalid>', '[x][id]', '[id]', '[id][]',
        '~~@target~~', '**@target**', r'\`@target\`', '<span>@target</span>',
        '<!-- @target -->', 'www.e.invalid/@target', 'a@target.invalid',
        '[label](<@中文>)', '😀`@target`中文', '[a `@target`](url)',
    ]
    for atom, prefix, suffix in itertools.product(
        atoms, ['', '😀 ', '    ', '> ', '- ', '\t'], ['', ' @outside', '\n@outside', '\r\n@outside']
    ):
        cases.append(prefix + atom + suffix)
    for fence, ending, container in itertools.product(
        ['```', '````', '~~~', '~~~~'], ['\n', '\r\n', '\r'], ['', '> ', '- ']
    ):
        for closing in ['', fence, fence + fence[0], fence[:-1]]:
            continuation = '  ' if container == '- ' else container
            cases.append(container + fence + ' lang' + ending + continuation + '@target' + ending
                         + continuation + closing + ending + '@outside')
    for label, url, title, ending in itertools.product(
        ['id', '@target', '中文', 'a b', 'a\\]b'],
        ['url', '<@target>', '<&commat;target>', 'https://example.invalid/a(b)', '<a&amp;b>'],
        ['', ' "@target"', " 'title'", '\n  "title"'], ['\n', '\r\n']
    ):
        definition = f'[{label}]: {url}{title}'
        cases.extend([f'[{label}] @outside{ending}{ending}{definition}',
                      f'> {definition}{ending}> @outside', definition + ending + '@outside'])
    for a, b in itertools.product(atoms, repeat=2):
        cases.append(a + ' @between ' + b + '\n\n[id]: <@target>')
    # Exercise destination decoding independently of rendered text. Named
    # references are supplied by Python's fixed HTML5 entity table.
    from html.entities import html5
    for name in sorted(html5):
        if name.endswith(';'):
            cases.append('[x](<&' + name + '@target>) @outside')
    for value in list(range(161)) + [0xD800, 0xDFFF, 0xFDD0, 0xFFFF, 0x10FFFF, 0x110000]:
        for entity in [f'&#{value};', f'&#x{value:x};']:
            cases.extend(['[x](<' + entity + '@target>)', '[x](<@target' + entity + '>)'])
    for size in [1, 2, 3, 31, 32, 33, 64, 128]:
        tick = '`' * size
        cases.extend([tick + '@target' + tick + ' @outside',
                      tick + 'lang\n@target\n' + tick + '\n@outside',
                      tick + '\n@target\n' + tick[:-1]])
    for prefix, blank, ending in itertools.product(['', '> ', '- ', '    '], ['', '\n', '\n\n'], ['\n', '\r\n', '\r']):
        cases.append(prefix + '```' + ending + prefix + '@target' + ending + blank)
    for tag in ['div', 'table', 'pre', 'script', 'textarea', 'custom']:
        cases.extend([f'<{tag}></{tag}>\n```\n@target\n```\n@outside',
                      f'<{tag}>\n@target\n</{tag}>\n`@hidden` @outside'])
    for scheme, path, before, after in itertools.product(
        ['www.', 'http://', 'https://'],
        ['example.invalid/@target', 'example.invalid?q=@target', 'example.invalid#@target',
         'example.invalid/a(b)@target', 'example.invalid/@target&amp;x'],
        ['', '<', '(', '[', '*', '_', '中文'], ['', '>', ')', ']', '.', ',', ';', '!', '\n@outside']
    ):
        cases.append(before + scheme + path + after)
    return list(dict.fromkeys(cases))


def oracle(cases, bundle):
    result = subprocess.run(['node', str(ROOT / 'Tools/MarkdownParser/reference-oracle.mjs'), str(bundle)],
                            input=json.dumps(cases, ensure_ascii=True), text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--bundle', type=Path,
                        default=ROOT / 'Tools/MarkdownParser/reference/raft-markdown-parser.js')
    parser.add_argument('--spec', type=Path, help='Optional CommonMark spec.json corpus')
    parser.add_argument('--extra-corpus', type=Path, help='Optional JSON array of additional source strings')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    cases = corpus()
    if args.spec:
        examples = json.loads(args.spec.read_text())
        for example in examples:
            text = example['markdown']
            marked = text.replace('foo', '@target').replace('bar', '中文😀@target')
            cases.extend([text, '@before\n\n' + text + '\n\n@after', marked])
    if args.extra_corpus:
        extra = json.loads(args.extra_corpus.read_text())
        if not isinstance(extra, list) or not all(isinstance(value, str) for value in extra):
            raise ValueError('--extra-corpus must contain a JSON array of source strings')
        cases.extend(extra)
    cases = list(dict.fromkeys(cases))
    expected = oracle(cases, args.bundle)
    lib = ctypes.CDLL(str(args.library.resolve()))
    lib.raft_markdown_create.argtypes = [ctypes.POINTER(ctypes.c_int)]
    lib.raft_markdown_create.restype = ctypes.c_void_p
    lib.raft_markdown_parse.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                      ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
    lib.raft_markdown_free.argtypes = [ctypes.c_void_p]
    lib.raft_markdown_destroy.argtypes = [ctypes.c_void_p]
    error = ctypes.c_int()
    context = lib.raft_markdown_create(ctypes.byref(error))
    if not context or error.value:
        raise RuntimeError(f'Native parser initialization failed: {error.value}')
    actual = []
    try:
        for source in cases:
            units = source.encode('utf-16-le', errors='surrogatepass')
            buffer = ctypes.create_string_buffer(units)
            allocation = ctypes.c_void_p()
            size = ctypes.c_size_t()
            result = lib.raft_markdown_parse(context, buffer, len(units) // 2,
                                             ctypes.byref(allocation), ctypes.byref(size))
            if result:
                raise RuntimeError(f'Native parse failed ({result}): {source!r}')
            try:
                ranges = json.loads(ctypes.string_at(allocation, size.value))
            finally:
                lib.raft_markdown_free(allocation)
            actual.append({'source': source, 'ranges': ranges})
    finally:
        lib.raft_markdown_destroy(context)
    normalized = oracle(actual, args.bundle)
    failures = []
    range_differences = 0
    for source, reference, native in zip(cases, expected, normalized):
        if reference['ranges'] != native['ranges']:
            range_differences += 1
        if reference['surface'] != native['surface']:
            failures.append({'source': source, 'reference': reference, 'native': native})
    report = {'cases': len(cases), 'surfaceFailures': len(failures),
              'rawRangeDifferences': range_differences, 'failures': failures}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=True, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'failures'}))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
