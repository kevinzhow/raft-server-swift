#!/usr/bin/env python3
"""Regression check for rejected literal URLs that formerly caused quadratic work.

Use an optimized native shared library. CPU time excludes scheduler delays;
repetitions reduce timer noise. Growth is checked with generous headroom over
linear scaling, rather than a hardware-specific millisecond deadline.
"""
import argparse
import ctypes
import json
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--repetitions', type=int, default=20)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('--repetitions must be positive')
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
        raise RuntimeError('Native initialization failed')
    report = []
    try:
        for prefix in ['http://_', 'www._']:
            samples = []
            for count in [999, 1999, 3999]:
                source = prefix * count + ' @target'
                units = source.encode('utf-16-le')
                buffer = ctypes.create_string_buffer(units)
                expected = [] if prefix == 'http://_' else [{
                    'kind': 'link', 'start': len(prefix) * (count - 1),
                    'end': len(prefix) * (count - 1) + 3, 'href': 'http://www',
                }]
                start = time.process_time()
                for _ in range(args.repetitions):
                    output = ctypes.c_void_p()
                    size = ctypes.c_size_t()
                    result = lib.raft_markdown_parse(context, buffer, len(units) // 2,
                                                     ctypes.byref(output), ctypes.byref(size))
                    if result:
                        raise RuntimeError(f'Parse failed: {result}')
                    try:
                        if json.loads(ctypes.string_at(output, size.value)) != expected:
                            raise AssertionError('Pathological input differs from the pinned JS result')
                    finally:
                        lib.raft_markdown_free(output)
                elapsed = (time.process_time() - start) / args.repetitions
                samples.append({'units': len(units) // 2, 'cpuSecondsPerParse': elapsed})
            growth = samples[-1]['cpuSecondsPerParse'] / samples[0]['cpuSecondsPerParse']
            # Input grows ~4x. The original regression grew ~16x; permit 8.5x
            # for small timing noise and allocator/compiler differences.
            report.append({'prefix': prefix, 'samples': samples, 'growth': growth,
                           'passed': growth < 8.5})
    finally:
        lib.raft_markdown_destroy(context)
    print(json.dumps(report, indent=2))
    raise SystemExit(not all(item['passed'] for item in report))


if __name__ == '__main__':
    main()
