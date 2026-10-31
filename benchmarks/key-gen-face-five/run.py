#!/usr/bin/env python3
"""Build, validate, and time matching five-face key searches."""

import argparse
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
KEYS = (0, 1, 5, 22, 94, 312, 992, 2422, 5624, 12522, 19998, 43258, 79415)


def checked_run(executable: Path, last: int) -> float:
    started = time.perf_counter()
    result = subprocess.run(
        [str(executable)], input=bytes([last]), capture_output=True, check=True
    )
    elapsed = time.perf_counter() - started
    expected = "".join(f"{key}\n" for key in KEYS[: last + 1]).encode()
    if result.stdout != expected or result.stderr:
        raise RuntimeError(
            f"{executable.name}: incorrect output for index {last}: {result!r}"
        )
    return elapsed


def validate(executable: Path) -> None:
    for last in (3, 4, 5, 6, 7):
        checked_run(executable, last)
    for data in (b"", b"\x00", b"\x02", b"\x0d", b"\xff"):
        result = subprocess.run([str(executable)], input=data, capture_output=True)
        if result.returncode != 1 or result.stdout or result.stderr:
            raise RuntimeError(f"{executable.name}: invalid input accepted: {result!r}")


def stable(samples: list[float]) -> bool:
    return len(samples) >= 2 and max(samples) - min(samples) <= 0.02 * statistics.median(samples)


def measure(executable: Path, last: int) -> list[float]:
    checked_run(executable, last)
    samples: list[float] = []
    while len(samples) < 5:
        samples.append(checked_run(executable, last))
        if stable(samples):
            break
    return samples


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last", type=int, choices=range(3, 13), default=10,
                        help="last key index, inclusive (default: 10, matching upstream)")
    parser.add_argument("--cpu", type=int, help="pin runtime checks and samples to this CPU")
    parser.add_argument("--check-only", action="store_true", help="validate without timing")
    arguments = parser.parse_args()
    if arguments.cpu is not None and arguments.cpu not in os.sched_getaffinity(0):
        parser.error("--cpu must be in the process's allowed CPU set")

    with tempfile.TemporaryDirectory(prefix="chimera-key-gen-") as directory:
        work = Path(directory)
        prefix = work / "compiler"
        subprocess.run(
            ["zig", "build", "--seed=0", "-Doptimize=fast", "-j1", "--prefix", str(prefix)],
            cwd=ROOT, check=True,
        )
        compiled = subprocess.run(
            [str(prefix / "bin" / "chimera"), "--workers=0", str(HERE / "main.chi")],
            cwd=work, input=b"\x03", capture_output=True, check=True,
        )
        if compiled.stdout != b"0\n1\n5\n22\nexit code: 0\n":
            raise RuntimeError(f"Chimera compilation check failed: {compiled!r}")
        chimera = work / "key-gen-chimera"
        shutil.move(work / "prog", chimera)
        executables = {"Chimera": chimera}
        for optimization in ("-O0", "-O3"):
            executable = work / f"key-gen-c{optimization}"
            subprocess.run(
                ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", optimization,
                 str(HERE / "main.c"), "-o", str(executable)],
                check=True,
            )
            executables[f"Clang {optimization}"] = executable

        if arguments.cpu is not None:
            os.sched_setaffinity(0, {arguments.cpu})
        print(f"Five-face key search, last index {arguments.last}; CPUs {sorted(os.sched_getaffinity(0))}",
              flush=True)
        print(f"Zig: {subprocess.check_output(['zig', 'version'], text=True).strip()}")
        print(f"C: {subprocess.check_output(['clang', '--version'], text=True).splitlines()[0]}", flush=True)
        results: dict[str, list[float]] = {}
        for name, executable in executables.items():
            validate(executable)
            if arguments.check_only:
                checked_run(executable, arguments.last)
                print(f"{name}: correctness checks passed", flush=True)
                continue
            samples = measure(executable, arguments.last)
            results[name] = samples
            status = "stable" if stable(samples) else "unstable at five-sample cap"
            print(f"{name}: median {statistics.median(samples):.6f} s ({status})", flush=True)
            print("  samples (s): " + ", ".join(f"{sample:.9f}" for sample in samples), flush=True)
        if results:
            ratio = statistics.median(results["Chimera"]) / statistics.median(results["Clang -O3"])
            print(f"Chimera / Clang -O3 wall-time ratio: {ratio:.3f}x")


if __name__ == "__main__":
    main()
