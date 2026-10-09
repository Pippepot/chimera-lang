#!/usr/bin/env python3
"""Measure worker scaling and executable and query cache reuse."""

import argparse
import pathlib
import shutil
import statistics
import subprocess
import tempfile
import time


def run(
    compiler: pathlib.Path,
    project: pathlib.Path,
    workers: int,
    expected_exit: int = 56,
    cache_enabled: bool = True,
) -> float:
    started = time.perf_counter()
    result = subprocess.run(
        [str(compiler), f"--workers={workers}", *(["--disk-cache"] if cache_enabled else []), "main.chi"],
        cwd=project,
        capture_output=True,
        text=True,
        check=True,
    )
    elapsed = time.perf_counter() - started
    if result.stdout.strip() != f"exit code: {expected_exit}" or result.stderr:
        raise RuntimeError(f"unexpected compiler result: {result.stdout!r} {result.stderr!r}")
    return elapsed


def clear_query_snapshot(project: pathlib.Path) -> None:
    for path in (project / ".chi-cache").iterdir():
        if not path.is_file():
            continue
        with path.open("rb") as cached:
            cached.seek(80)  # CHICACHE header
            if cached.read(6) == b"CHIQRY":
                path.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=pathlib.Path, help="path to a chi binary built with -Doptimize=fast")
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--temp-dir", type=pathlib.Path, help="filesystem on which to create the benchmark fixture")
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    if args.samples < 1:
        parser.error("--samples must be positive")

    with tempfile.TemporaryDirectory(prefix="chi-parallel-", dir=args.temp_dir) as dirname:
        fixture_root = pathlib.Path(dirname)
        project = fixture_root / "big"
        project.mkdir()
        small = fixture_root / "small"
        small.mkdir()
        (small / "main.chi").write_text("exit(0)\n")
        small_cold = []
        small_warm = []
        small_uncached = []
        for _ in range(args.samples):
            shutil.rmtree(small / ".chi-cache", ignore_errors=True)
            small_cold.append(run(compiler, small, 2, expected_exit=0))
            small_warm.append(run(compiler, small, 2, expected_exit=0))
            small_uncached.append(run(compiler, small, 2, expected_exit=0, cache_enabled=False))
        print(
            f"small cold_median={statistics.median(small_cold):.6f}s "
            f"warm_median={statistics.median(small_warm):.6f}s "
            f"uncached_median={statistics.median(small_uncached):.6f}s"
        )

        for index in range(120):
            body = "  x = x + 1\n" * 1000
            (project / f"f{index:03}.chi").write_text(
                f"static f{index:03} = func(value: int) int\n"
                f"  var x = value\n{body}  return x\n"
            )
        entry = (
            "var total = 0\n"
            + "".join(f"total = total + f{index:03}(1)\n" for index in range(120))
            + "exit(total)\n"
        )
        (project / "main.chi").write_text(entry)

        for workers in (1, 2, 4, 8):
            cold = []
            warm = []
            uncached = []
            for _ in range(args.samples):
                shutil.rmtree(project / ".chi-cache", ignore_errors=True)
                cold.append(run(compiler, project, workers))
                warm.append(run(compiler, project, workers))
                uncached.append(run(compiler, project, workers, cache_enabled=False))
            print(
                f"workers={workers} cold_median={statistics.median(cold):.6f}s "
                f"warm_median={statistics.median(warm):.6f}s "
                f"uncached_median={statistics.median(uncached):.6f}s"
            )

        for use_queries, cache_enabled in (
            (True, True),
            (False, True),
            (False, False),
        ):
            shutil.rmtree(project / ".chi-cache", ignore_errors=True)
            (project / "main.chi").write_text(entry)
            if cache_enabled:
                run(compiler, project, 2)
            edited = []
            for value in range(2, 2 + args.samples):
                (project / "main.chi").write_text(entry.replace("f000(1)", f"f000({value})"))
                if cache_enabled and not use_queries:
                    clear_query_snapshot(project)
                edited.append(run(compiler, project, 2, (55 + value) % 256, cache_enabled=cache_enabled))
            if not cache_enabled and (project / ".chi-cache").exists():
                raise RuntimeError("default run created a disk cache")
            print(
                f"edited_cache={cache_enabled} queries={use_queries} "
                f"median={statistics.median(edited):.6f}s"
            )


if __name__ == "__main__":
    main()
