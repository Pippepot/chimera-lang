#!/usr/bin/env python3
"""Compare Chimera Array.sort with C++ std::sort and std::stable_sort."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import struct
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PATTERNS = ("random", "sorted", "reversed", "duplicates", "runs", "adjacent swap", "minimum last")


def expected(size: int, pattern: int, rounds: int, seed: int) -> bytes:
    checksum = 0
    for round_index in range(rounds):
        state = (seed + round_index) % 65536
        values = []
        for index in range(size):
            state = (state * 25173 + 13849) % 65536
            value = state
            if pattern == 1:
                value = index
            elif pattern == 2:
                value = size - 1 - index
            elif pattern == 3:
                value = state % 16
            elif pattern == 4:
                value = ((size - 1) // 256 - index // 256) * 256 + index % 256
            elif pattern == 5:
                value = index
                if size > 1:
                    middle = (size - 1) // 2
                    if index == middle:
                        value += 1
                    elif index == middle + 1:
                        value -= 1
            elif pattern == 6:
                value = index + 1 if index < size - 1 else 0
            values.append(value)
        for value in sorted(values):
            checksum = (checksum * 31 + value) % 1000003
    return f"{checksum}\n".encode()


def checked_run(command: list[str], data: bytes, answer: bytes) -> float:
    started = time.perf_counter_ns()
    result = subprocess.run(command, input=data, capture_output=True, check=True)
    elapsed = (time.perf_counter_ns() - started) / 1e9
    if result.stdout != answer or result.stderr:
        raise RuntimeError(f"incorrect benchmark output: {command}: {result!r}")
    return elapsed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=65536)
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--samples", type=int, default=9)
    parser.add_argument("--cpu", type=int, help="pin runtime samples to this CPU")
    parser.add_argument("--compiler", type=Path, help="use an already built Chimera compiler")
    parser.add_argument("--output", type=Path, help="save metadata and raw samples as JSON")
    arguments = parser.parse_args()
    if not 1 <= arguments.size <= 262144:
        parser.error("--size must be between 1 and 262144 (stack-backed arrays)")
    if not 1 <= arguments.rounds <= 65535:
        parser.error("--rounds must be between 1 and 65535")
    if arguments.samples < 1:
        parser.error("--samples must be positive")
    if arguments.cpu is not None and arguments.cpu not in os.sched_getaffinity(0):
        parser.error("--cpu must be in the allowed CPU set")

    report = {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "worktree_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "size": arguments.size,
        "rounds": arguments.rounds,
        "samples": arguments.samples,
        "seed": 0,
        "machine": platform.platform(),
        "cpu": next((line.split(":", 1)[1].strip() for line in
                     Path("/proc/cpuinfo").read_text().splitlines()
                     if line.startswith("model name")), "unknown"),
        "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
        "cpp": subprocess.check_output(["clang++", "--version"], text=True).splitlines()[0],
        "cpp_flags": ["-std=c++17", "-O3", "-DNDEBUG", "-fno-lto"],
        "sources": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (HERE / "main.chi", HERE / "main.cpp", HERE / "runtime.cpp", HERE / "run.py",
                                 ROOT / "std/array.chi", ROOT / "std/memory/sort.chi")},
        "measurement": "process wall time: startup, fill, sort, verification, cleanup",
        "executable_bytes": {},
        "results": [],
    }
    with tempfile.TemporaryDirectory(prefix="chimera-array-sort-") as directory:
        work = Path(directory)
        prefix = work / "compiler"
        if arguments.compiler:
            compiler = arguments.compiler.resolve()
        else:
            subprocess.run(
                ["zig", "build", "--seed=0", "-Doptimize=fast", "-j1", "--prefix", str(prefix)],
                cwd=ROOT, check=True,
            )
            compiler = prefix / "bin/chimera"
        report["compiler_sha256"] = hashlib.sha256(compiler.read_bytes()).hexdigest()
        macros = subprocess.check_output(
            ["clang++", "-std=c++17", "-dM", "-E", "-x", "c++", "-"],
            input="#include <algorithm>\n", text=True,
        )
        report["cpp_library"] = [line for line in macros.splitlines()
                                 if line.startswith(("#define __GLIBCXX__ ",
                                                     "#define _GLIBCXX_RELEASE ",
                                                     "#define _LIBCPP_VERSION "))]
        source = (HERE / "main.chi").read_text().replace(
            "static SIZE = 65536", f"static SIZE = {arguments.size}")
        probe = struct.pack("<BHH", 0, 1, 0)
        answer = expected(arguments.size, 0, 1, 0)
        commands = {}
        for mode in ("static", "runtime"):
            variant = work / mode
            variant.mkdir()
            variant_source = source.replace("static RUNTIME_COMPARATOR = false",
                                            f"static RUNTIME_COMPARATOR = {str(mode == 'runtime').lower()}")
            (variant / "main.chi").write_text(variant_source)
            compiled = subprocess.run(
                [str(compiler), "--workers=0", str(variant / "main.chi")],
                cwd=variant, input=probe, capture_output=True, check=True,
            )
            if compiled.stdout != answer + b"exit code: 0\n":
                raise RuntimeError(f"Chimera {mode} compilation check failed: {compiled!r}")
            executable = work / f"sort-chimera-{mode}"
            shutil.move(variant / "prog", executable)
            commands[f"Chimera {mode}"] = [str(executable)]
            report["executable_bytes"][f"Chimera {mode}"] = executable.stat().st_size
        cpp = work / "sort-cpp"
        subprocess.run(
            ["clang++", *report["cpp_flags"], "-Wall", "-Wextra", "-Werror",
             f"-DARRAY_SIZE={arguments.size}", str(HERE / "main.cpp"), str(HERE / "runtime.cpp"), "-o", str(cpp)],
            check=True,
        )
        report["executable_bytes"]["C++ combined"] = cpp.stat().st_size
        commands.update({
            "C++ std::sort": [str(cpp), "sort"],
            "C++ std::stable_sort": [str(cpp), "stable_sort"],
            "C++ std::sort runtime": [str(cpp), "sort-runtime"],
            "C++ std::stable_sort runtime": [str(cpp), "stable_sort-runtime"],
        })
        if arguments.cpu is not None:
            os.sched_setaffinity(0, {arguments.cpu})
        report["affinity"] = sorted(os.sched_getaffinity(0))
        print(f"{arguments.size} int32 elements, {arguments.rounds} sorts per process, "
              f"{arguments.samples} samples; CPUs {report['affinity']}", flush=True)
        print(report["measurement"], flush=True)
        print(f"Zig {report['zig']}; {report['cpp']}", flush=True)
        for pattern, name in enumerate(PATTERNS):
            # Oracle construction and correctness probes precede all sample timers.
            for seed in (0, 42, 65535):
                probe_answer = expected(arguments.size, pattern, 1, seed)
                for command in commands.values():
                    checked_run(command, struct.pack("<BHH", pattern, 1, seed), probe_answer)
            data = struct.pack("<BHH", pattern, arguments.rounds, 0)
            answer = expected(arguments.size, pattern, arguments.rounds, 0)
            samples = {name: [] for name in commands}
            for command in commands.values():
                checked_run(command, data, answer)  # One discarded full warm-up.
            names = list(commands)
            for index in range(arguments.samples):
                # Rotate the order to reduce consistent thermal/order bias.
                for offset in range(len(names)):
                    algorithm = names[(index + offset) % len(names)]
                    samples[algorithm].append(checked_run(commands[algorithm], data, answer))
            medians = {algorithm: statistics.median(times) for algorithm, times in samples.items()}
            print(f"\n{name}:", flush=True)
            for algorithm, times in samples.items():
                print(f"  {algorithm}: {medians[algorithm] * 1000:.3f} ms "
                      f"[{min(times) * 1000:.3f}, {max(times) * 1000:.3f}]", flush=True)
                report["results"].append({
                    "pattern": name, "algorithm": algorithm,
                    "seconds": times, "median_seconds": medians[algorithm],
                })
            for mode in ("static", "runtime"):
                for operation in ("std::sort", "std::stable_sort"):
                    algorithm = f"C++ {operation}" + (" runtime" if mode == "runtime" else "")
                    print(f"  Chimera {mode} / {algorithm}: "
                          f"{medians[f'Chimera {mode}'] / medians[algorithm]:.2f}x", flush=True)
    if arguments.output:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
