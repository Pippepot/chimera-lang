#!/usr/bin/env python3
"""Measure optimized Chimera scoped services with runtime-selected work counts."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import struct
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MODES = ('explicit lifecycle', 'contextual lifecycle', 'spare append', 'growing append',
         'disabled log', 'enabled counter backend', 'enabled pure no-op backend',
         'explicit destruction', 'contextual destruction',
         'element lifecycle without hook', 'element lifecycle with drop hook',
         'enabled root stderr pipe')


def expected(mode, rounds):
    answer = rounds * (rounds - 1) // 2 if mode < 2 or 7 <= mode <= 10 else rounds
    if mode < 2 or 7 <= mode <= 10:
        answer = (answer + 2 ** 31) % 2 ** 32 - 2 ** 31
    output = f'{answer}\n'
    if 4 <= mode <= 6:
        output += f'{rounds if mode == 5 else 0}\n'
    if mode in (9, 10):
        output = f'{rounds if mode == 10 else 0}\n' + output
    return output.encode()


def expected_stderr(mode, rounds):
    return b'info: event\n' * rounds if mode == 11 else b''


def run(command, data, answer, errors=b''):
    start = time.perf_counter_ns()
    result = subprocess.run(command, input=data, capture_output=True, check=True)
    elapsed = (time.perf_counter_ns() - start) / 1e9
    if result.stdout != answer or result.stderr != errors:
        raise RuntimeError(f'incorrect benchmark output: stdout={result.stdout!r}, '
                           f'stderr={result.stderr[:200]!r} ({len(result.stderr)} bytes)')
    return elapsed


def run_destruction(command, data, answer):
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE) as child:
        child.stdin.write(data)
        child.stdin.flush()
        if child.stdout.readline() != b'ready\n':
            raise RuntimeError('destruction benchmark failed before timing')
        start = time.perf_counter_ns()
        output, errors = child.communicate(b'x')
        elapsed = (time.perf_counter_ns() - start) / 1e9
        if child.returncode or output != answer or errors:
            raise RuntimeError(f'incorrect destruction output: {output!r} {errors!r}')
        return elapsed


def measure(key, command, data, answer):
    if key[0] in (7, 8):
        return run_destruction(command, data, answer)
    return run(command, data, answer, expected_stderr(key[0], struct.unpack('<I', data)[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', type=Path)
    parser.add_argument('--rounds', type=int, default=200000)
    parser.add_argument('--samples', type=int, default=7)
    parser.add_argument('--cpu', type=int)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 16777215 or args.samples < 1:
        parser.error('rounds must fit 24 bits and samples must be positive')
    if args.cpu is not None:
        if args.cpu not in os.sched_getaffinity(0):
            parser.error('CPU must be allowed by the current affinity')
        os.sched_setaffinity(0, {args.cpu})
    report = {
        'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
        'machine': platform.platform(), 'affinity': sorted(os.sched_getaffinity(0)),
        'zig': subprocess.check_output(['zig', 'version'], text=True).strip(),
        'rounds': args.rounds, 'sample_count': args.samples, 'seed': 0,
        'repeatability_range_fraction_limit': 0.02,
        'measurement': 'whole process: startup, input, work, checksum output, cleanup',
        'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in (HERE / 'main.chi', HERE / 'run.py', ROOT / 'std/logging.chi',
                                    ROOT / 'std/memory/allocation.chi', ROOT / 'src/backend/codegen.zig')},
        'results': [],
    }
    with tempfile.TemporaryDirectory(prefix='chimera-shared-context-') as directory:
        work = Path(directory)
        compiler = args.compiler.resolve() if args.compiler else work / 'compiler/bin/chimera'
        if args.compiler is None:
            subprocess.run(['zig', 'build', '--seed=0', '-Doptimize=fast', '-j1', '--prefix',
                            str(work / 'compiler')], cwd=ROOT, check=True)
        report['compiler_sha256'] = hashlib.sha256(compiler.read_bytes()).hexdigest()
        commands = {}
        original = (HERE / 'main.chi').read_text()
        for mode, name in enumerate(MODES):
            for depth in (0, 1, 4):
                source = original.replace('static MODE = 0', f'static MODE = {mode}').replace(
                    'static DEPTH = 0', f'static DEPTH = {depth}')
                variant = work / f'{mode}-{depth}'
                variant.mkdir()
                (variant / 'main.chi').write_text(source)
                result = subprocess.run([str(compiler), '--workers=0', 'main.chi'], cwd=variant,
                                        input=struct.pack('<I', 19) + (b'x' if mode in (7, 8) else b''), capture_output=True, check=True)
                if (result.stdout != (b'ready\n' if mode in (7, 8) else b'') + expected(mode, 19) + b'exit code: 0\n'
                        or result.stderr != expected_stderr(mode, 19)):
                    raise RuntimeError(f'compilation probe failed: {result!r}')
                commands[mode, depth] = [str(variant / 'prog')]
                if mode == 0 and depth == 0:
                    layouts = subprocess.run(commands[mode, depth], input=b'\x01\x00\x00\x01',
                                             capture_output=True, check=True)
                    report['layout_bytes'] = dict(zip(('callable', 'Allocator', 'Logger',
                                                      'Allocation(int)', 'List(int)',
                                                      'PlainItem', 'TrackedItem'),
                                                     map(int, layouts.stdout.splitlines()), strict=True))
                    if report['layout_bytes']['PlainItem'] != report['layout_bytes']['TrackedItem']:
                        raise RuntimeError('element-hook baselines have different layouts')
        # Warm and qualify all generated binaries before any timed samples.
        for (mode, depth), command in commands.items():
            measure((mode, depth), command, struct.pack('<I', 42), expected(mode, 42))
        observations = {key: [] for key in commands}
        data = struct.pack('<I', args.rounds)
        for sample in range(args.samples):
            order = list(commands)
            if sample % 2:
                order.reverse()
            for key in order:
                observations[key].append(measure(key, commands[key], data, expected(key[0], args.rounds)))
        for (mode, depth), samples in observations.items():
            record = {'mode': MODES[mode],
                      'measurement': ('ready/signal handshake, removal, destruction, checksum output, exit'
                                      if mode in (7, 8) else
                                      report['measurement'] + ', stderr pipe drained by parent'
                                      if mode == 11 else report['measurement']), 'wrappers': depth, 'seconds': samples,
                      'median_seconds': statistics.median(samples),
                      'min_seconds': min(samples), 'max_seconds': max(samples),
                      'executable_bytes': Path(commands[mode, depth][0]).stat().st_size}
            record['full_range_fraction'] = (record['max_seconds'] - record['min_seconds']) / record['median_seconds']
            record['unstable'] = len(samples) < 2 or record['full_range_fraction'] > 0.02
            report['results'].append(record)
            print(f'{record["mode"]}, {depth} wrappers: {record["median_seconds"]:.6f}s'
                  + (' [unstable]' if record['unstable'] else ''), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    else:
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
