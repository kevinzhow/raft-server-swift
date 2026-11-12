#!/usr/bin/env python3
"""Compare memory at the same startup checkpoint in isolated server processes.

Use binaries built with the same compiler and configuration. The checkpoint is
parser self-check + application startup log, before user traffic or database
state. This does not measure steady-state production memory or HTTP throughput.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import time


def memory(pid):
    result = {}
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        key, _, value = line.partition(':')
        if key in {'VmRSS', 'RssAnon', 'RssFile', 'VmSwap', 'Threads'}:
            result[key] = int(value.split()[0])
    maps = Path(f'/proc/{pid}/maps').read_text()
    if 'RaftServer' not in maps or 'r-xp' not in maps:
        raise RuntimeError('Memory-map probe did not return executable mappings')
    result['javascriptCoreMapped'] = 'javascriptcore' in maps.lower()
    return result


def run(binary, artifacts, label, iteration):
    reservations = [socket.socket() for _ in range(3)]
    try:
        for reservation in reservations:
            reservation.bind(('127.0.0.1', 0))
        port, socket_port, daemon_port = [item.getsockname()[1] for item in reservations]
    finally:
        for reservation in reservations:
            reservation.close()
    log = artifacts / f'{label}-{iteration}.log'
    environment = os.environ.copy()
    for key in list(environment):
        if key == 'DATABASE_URL' or 'REDIS' in key or key.startswith(('RAFT_', 'SLOCK_')):
            environment.pop(key)
    environment.update({
        'NODE_ENV': 'test', 'PORT': str(port), 'HTTP_HOST': '127.0.0.1',
        'SOCKET_PORT': str(socket_port), 'DAEMON_CONNECT_PORT': str(daemon_port),
        'SOCKET_HOST': '127.0.0.1', 'DAEMON_CONNECT_HOST': '127.0.0.1',
        'JWT_SECRET': 'isolated-native-memory-comparison',
        'SERVER_URL': f'http://127.0.0.1:{port}',
    })
    with log.open('wb') as output:
        process = subprocess.Popen([str(binary)], env=environment, stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 30
            ready = False
            while time.monotonic() < deadline and process.poll() is None:
                text = log.read_text()
                if 'raft-server ready' in text and 'Server started' in text:
                    ready = True
                    break
                time.sleep(0.05)
            if not ready:
                raise RuntimeError(f'Server did not reach startup checkpoint; inspect {log}')
            result = memory(process.pid)
            if result['javascriptCoreMapped'] != (label == 'reference'):
                raise RuntimeError(f'Unexpected engine mapping for {label}')
            result['binary'] = str(binary)
            return result
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--artifacts', required=True, type=Path)
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    args.artifacts.mkdir(parents=True, exist_ok=True)
    report = {'conditions': 'isolated NODE_ENV=test; no DB; full loopback listener configuration; startup log checkpoint; no traffic',
              'reference': [], 'native': []}
    for iteration in range(args.runs):
        for label in ['reference', 'native']:
            report[label].append(run(getattr(args, label).resolve(strict=True), args.artifacts, label, iteration))
    report['medianRSSKiB'] = {label: statistics.median(item['VmRSS'] for item in report[label])
                              for label in ['reference', 'native']}
    report['medianRSSReductionKiB'] = report['medianRSSKiB']['reference'] - report['medianRSSKiB']['native']
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
