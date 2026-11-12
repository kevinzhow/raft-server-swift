#!/usr/bin/env python3
"""Measure isolated parser memory with identical input, outside the server.

Each invocation must run in a fresh process. RSS includes this Python driver;
compare stages and fresh-process native/reference results, not production totals.
"""
import argparse
import ctypes
import importlib.util
import json
from pathlib import Path
import time


def snapshot():
    fields = {}
    for line in Path('/proc/self/smaps_rollup').read_text().splitlines():
        name, _, rest = line.partition(':')
        if name in {'Rss', 'Pss', 'Anonymous', 'Private_Dirty'}:
            fields[name + 'KiB'] = int(rest.split()[0])
    fields['javascriptCoreMapped'] = 'libjavascriptcore' in Path('/proc/self/maps').read_text().lower()
    return fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--reference-bundle', type=Path)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('compare-native.py'))
    comparison = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(comparison)
    cases = comparison.corpus()
    inputs = [(ctypes.create_string_buffer(source.encode('utf-16-le', errors='surrogatepass')),
               len(source.encode('utf-16-le', errors='surrogatepass')) // 2) for source in cases]
    lib = ctypes.CDLL(str(args.library.resolve()))
    lib.raft_markdown_create.restype = ctypes.c_void_p
    lib.raft_markdown_parse.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                                      ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
    lib.raft_markdown_free.argtypes = [ctypes.c_void_p]
    lib.raft_markdown_destroy.argtypes = [ctypes.c_void_p]
    measurements = {'beforeInitialization': snapshot()}
    error = ctypes.c_int()
    if args.reference_bundle:
        lib.raft_markdown_create.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
        bundle = args.reference_bundle.read_bytes()
        context = lib.raft_markdown_create(bundle, len(bundle), ctypes.byref(error))
    else:
        lib.raft_markdown_create.argtypes = [ctypes.POINTER(ctypes.c_int)]
        context = lib.raft_markdown_create(ctypes.byref(error))
    if not context or error.value:
        raise RuntimeError(f'Parser initialization failed: {error.value}')
    measurements['afterInitialization'] = snapshot()
    start = time.perf_counter()
    try:
        for _ in range(args.rounds):
            for buffer, length in inputs:
                allocation = ctypes.c_void_p()
                size = ctypes.c_size_t()
                result = lib.raft_markdown_parse(context, buffer, length, ctypes.byref(allocation), ctypes.byref(size))
                if result:
                    raise RuntimeError(f'Parse failed: {result}')
                lib.raft_markdown_free(allocation)
        measurements['elapsedSeconds'] = time.perf_counter() - start
        measurements['afterParsing'] = snapshot()
    finally:
        lib.raft_markdown_destroy(context)
    measurements['afterDestroy'] = snapshot()
    measurements['parses'] = len(cases) * args.rounds
    measurements['backend'] = 'reference-javascriptcore' if args.reference_bundle else 'native'
    print(json.dumps(measurements, indent=2))


if __name__ == '__main__':
    main()
