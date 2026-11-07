#!/usr/bin/env python3
"""Record every runtime benchmark across commits and render a standalone report.

Each commit's compiler builds from `git archive` (or the working tree) and compiles the
current benchmark programs unchanged, so a point differs from its neighbours only by the
compiler. Only generated programs are timed. The compiler's own optimization mode cannot
change generated machine code, so historical compilers build in Debug mode.
Commits run newest first, stopping at an existing entry or the first build,
compilation, or execution failure. The report is rendered when recording stops.

    python3 benchmarks/runtime_history.py --cpu 4
    python3 benchmarks/runtime_history.py --cpu 4 --worktree

Records live in `.history/runtime/` and the report is `.history/runtime.html`. Neither
touches the compilation history's records or report.
"""

import argparse
import datetime
import functools
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DATA = ROOT / ".history" / "runtime"
REPORT = ROOT / ".history" / "runtime.html"

SIEVE_LIMIT = 88_000_000
SIEVE_ANSWER = b"5107832\n"
KEYS = (0, 1, 5, 22, 94, 312, 992, 2422, 5624, 12522, 19998, 43258, 79415)
KEY_LAST = 10
PATTERNS = ("random", "sorted", "reversed", "duplicates", "runs")
SORT_SIZE = 65536
SORT_ROUNDS = 8
SORT_SAMPLES = 7
SORT_LANES = ("Chimera static", "Chimera runtime")
SORT_REFERENCES = ("C++ std::sort", "C++ std::stable_sort", "C++ std::sort runtime", "C++ std::stable_sort runtime")

SOURCES = (
    "benchmarks/runtime_history.py",
    "benchmarks/history_benchmark.zig",
    "benchmarks/key-gen-face-five/main.chi",
    "benchmarks/array-sort/main.chi",
)


def sieve_source() -> str:
    """The history benchmark's sieve program, read from its driver rather than copied."""
    text = (HERE / "history_benchmark.zig").read_text()
    start = text.index("const source =", text.index("fn measureRuntime"))
    lines = []
    for line in text[start:].splitlines()[1:]:
        stripped = line.strip()
        if not stripped.startswith("\\\\"):
            break
        lines.append(stripped[2:])
    return "\n".join(lines) + "\n"


def suite_hash() -> str:
    digest = hashlib.sha256()
    for name in SOURCES:
        digest.update((ROOT / name).read_bytes())
    for name in ("benchmarks/key-gen-face-five/main.c", "benchmarks/array-sort/main.cpp",
                 "benchmarks/array-sort/runtime.cpp", "benchmarks/history_runtime.c"):
        digest.update((ROOT / name).read_bytes())
    return digest.hexdigest()[:12]


@functools.cache
def sort_expected(pattern: int, rounds: int, seed: int) -> bytes:
    checksum = 0
    for round_index in range(rounds):
        state = (seed + round_index) % 65536
        values = []
        for index in range(SORT_SIZE):
            state = (state * 25173 + 13849) % 65536
            value = state
            if pattern == 1:
                value = index
            elif pattern == 2:
                value = SORT_SIZE - 1 - index
            elif pattern == 3:
                value = state % 16
            elif pattern == 4:
                value = ((SORT_SIZE - 1) // 256 - index // 256) * 256 + index % 256
            values.append(value)
        for value in sorted(values):
            checksum = (checksum * 31 + value) % 1000003
    return f"{checksum}\n".encode()


class Program:
    """One executable and how to drive and check it."""

    def __init__(self, command: list[str], size: int):
        self.command = command
        self.size = size

    def run(self, data: bytes, answer: bytes) -> float:
        started = time.perf_counter()
        result = subprocess.run(self.command, input=data, capture_output=True)
        elapsed = time.perf_counter() - started
        if result.returncode != 0 or result.stdout != answer or result.stderr:
            raise RuntimeError(f"{self.command[0]}: incorrect result {result.returncode} {result.stdout[:40]!r}")
        return elapsed


def stable(samples: list[float]) -> bool:
    return len(samples) >= 2 and max(samples) - min(samples) <= 0.02 * statistics.median(samples)


def adaptive(program: Program, data: bytes, answer: bytes) -> list[float]:
    program.run(data, answer)  # Discarded warm-up.
    samples: list[float] = []
    while len(samples) < 5:
        samples.append(program.run(data, answer))
        if stable(samples):
            break
    return samples


def summary(samples: list[float]) -> dict:
    return {"median": statistics.median(samples), "min": min(samples), "max": max(samples),
            "samples": samples, "stable": stable(samples)}


# Benchmarks: name -> (prepare, measure). Prepare returns (program-source files, probe) and
# measure returns the result dictionary for one program.

def sieve_probe(program: Program) -> None:
    for limit, answer in ((2, b"1\n"), (10, b"4\n"), (100, b"25\n"), (1000, b"168\n")):
        program.run(struct.pack("<I", limit), answer)


def measure_sieve(program: Program) -> dict:
    sieve_probe(program)
    return {"sieve": summary(adaptive(program, struct.pack("<I", SIEVE_LIMIT), SIEVE_ANSWER))}


def measure_keygen(program: Program) -> dict:
    for last in (3, 4, 5, 6, 7):
        program.run(bytes([last]), "".join(f"{key}\n" for key in KEYS[: last + 1]).encode())
    answer = "".join(f"{key}\n" for key in KEYS[: KEY_LAST + 1]).encode()
    return {"key-gen": summary(adaptive(program, bytes([KEY_LAST]), answer))}


def sort_input(pattern: int, rounds: int, seed: int) -> bytes:
    return struct.pack("<BHH", pattern, rounds, seed)


def measure_sort(programs: dict[str, Program]) -> dict:
    result: dict = {}
    for pattern, name in enumerate(PATTERNS):
        for seed in (0, 42):
            answer = sort_expected(pattern, 1, seed)
            for program in programs.values():
                program.run(sort_input(pattern, 1, seed), answer)
        data = sort_input(pattern, SORT_ROUNDS, 0)
        answer = sort_expected(pattern, SORT_ROUNDS, 0)
        for program in programs.values():
            program.run(data, answer)
        samples = {lane: [] for lane in programs}
        lanes = list(programs)
        for index in range(SORT_SAMPLES):
            for offset in range(len(lanes)):  # Rotate order against drift.
                lane = lanes[(index + offset) % len(lanes)]
                samples[lane].append(programs[lane].run(data, answer))
        for lane, times in samples.items():
            result[f"sort {name} / {lane}"] = summary(times)
    return result


def sort_input_probe() -> bytes:
    return sort_input(0, 1, 0)


# ---- Building and compiling -----------------------------------------------------------

def build_compiler(source: Path, prefix: Path) -> Path:
    built = subprocess.run(["zig", "build", "--seed=0", "-p", str(prefix)], cwd=source,
                           capture_output=True, text=True)
    if built.returncode != 0:
        raise RuntimeError("compiler build failed: " + (built.stderr.strip().splitlines() or ["?"])[0][:200])
    binaries = sorted((prefix / "bin").glob("*"))
    if not binaries:
        raise RuntimeError("compiler build produced no executable")
    return binaries[0]


def compile_program(compiler: Path, workers: bool, source_text: str, probe: bytes, work: Path, name: str) -> Path:
    directory = work / name
    directory.mkdir()
    (directory / "main.chi").write_text(source_text)
    command = [str(compiler)] + (["--workers=0"] if workers else []) + ["main.chi"]
    compiled = subprocess.run(command, cwd=directory, input=probe, capture_output=True, timeout=300)
    produced = directory / "prog"
    if compiled.returncode != 0 or not produced.exists():
        first = (compiled.stdout + compiled.stderr).decode(errors="replace").strip().splitlines()
        raise RuntimeError("compilation failed: " + (first[0][:200] if first else f"status {compiled.returncode}"))
    target = work / f"{name}-exe"
    shutil.move(produced, target)
    return target


def compiler_takes_workers(compiler: Path) -> bool:
    help_text = subprocess.run([str(compiler), "--help"], capture_output=True, text=True)
    return "--workers" in help_text.stdout + help_text.stderr


def record_commit(source: Path, work: Path) -> dict:
    compiler = build_compiler(source, work / "compiler")
    workers = compiler_takes_workers(compiler)
    results: dict = {}

    def sieve() -> dict:
        exe = compile_program(compiler, workers, sieve_source(), struct.pack("<I", 10), work, "sieve")
        return timed(measure_sieve, Program([str(exe)], 0))

    def keygen() -> dict:
        text = (ROOT / "benchmarks/key-gen-face-five/main.chi").read_text()
        exe = compile_program(compiler, workers, text, b"\x03", work, "keygen")
        return timed(measure_keygen, Program([str(exe)], 0))

    def sort() -> dict:
        base = (ROOT / "benchmarks/array-sort/main.chi").read_text().replace("static SIZE = 65536", f"static SIZE = {SORT_SIZE}")
        programs = {}
        for mode in ("static", "runtime"):
            text = base.replace("static RUNTIME_COMPARATOR = false", f"static RUNTIME_COMPARATOR = {str(mode == 'runtime').lower()}")
            exe = compile_program(compiler, workers, text, sort_input_probe(), work, f"sort-{mode}")
            programs[f"Chimera {mode}"] = Program([str(exe)], 0)
        return timed(measure_sort, programs)

    for label, action in (("sieve", sieve), ("key-gen", keygen), ("sort", sort)):
        try:
            results.update(action())
        except Exception as error:
            results[label] = {"status": "failed", "reason": str(error)[:300]}
            break
    return results


def commit_info(rev: str) -> dict:
    fields = subprocess.check_output(["git", "log", "-1", "--format=%H%n%cI%n%s", rev], cwd=ROOT, text=True).splitlines()
    return {"commit": fields[0], "date": fields[1], "subject": fields[2]}


def first_parent(since: str | None) -> list[str]:
    revs = subprocess.check_output(["git", "rev-list", "--first-parent", "HEAD"], cwd=ROOT, text=True).split()
    if since:
        full = subprocess.check_output(["git", "rev-parse", since], cwd=ROOT, text=True).strip()
        revs = revs[:revs.index(full) + 1]
    return revs


def environment() -> dict:
    cpu = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")), "unknown")
    return {"machine": platform.platform(), "cpu": cpu,
            "zig": subprocess.check_output(["zig", "version"], text=True).strip()}


ORIGINAL_AFFINITY = os.sched_getaffinity(0)
TIMED_CPU: int | None = None


def pin(cpu: int | None, enabled: bool) -> None:
    if cpu is not None:
        os.sched_setaffinity(0, {cpu} if enabled else ORIGINAL_AFFINITY)


def timed(measure, *arguments) -> dict:
    """Run one measurement pinned to the benchmark CPU; builds and compiles stay unpinned."""
    pin(TIMED_CPU, True)
    try:
        return measure(*arguments)
    finally:
        pin(TIMED_CPU, False)


def record_references() -> None:
    """C and C++ lanes, measured once per session on the same machine and protocol."""
    results: dict = {}
    with tempfile.TemporaryDirectory(prefix="chimera-runtime-refs-") as directory:
        work = Path(directory)
        programs: dict[str, Program] = {}
        for optimization in ("-O0", "-O3"):
            for name, source in (("sieve", HERE / "history_runtime.c"), ("key-gen", HERE / "key-gen-face-five/main.c")):
                exe = work / f"{name}{optimization}"
                subprocess.run(["clang", "-std=c11", optimization, str(source), "-o", str(exe)], check=True)
                programs[f"{name} C {optimization}"] = Program([str(exe)], 0)
        cpp = work / "sort-cpp"
        subprocess.run(["clang++", "-std=c++17", "-O3", "-DNDEBUG", "-fno-lto", f"-DARRAY_SIZE={SORT_SIZE}",
                        str(HERE / "array-sort/main.cpp"), str(HERE / "array-sort/runtime.cpp"), "-o", str(cpp)], check=True)
        for optimization in ("-O0", "-O3"):
            results[f"sieve C {optimization}"] = timed(measure_sieve, programs[f"sieve C {optimization}"])["sieve"]
            results[f"key-gen C {optimization}"] = timed(measure_keygen, programs[f"key-gen C {optimization}"])["key-gen"]
        lanes = {"C++ std::sort": [str(cpp), "sort"], "C++ std::stable_sort": [str(cpp), "stable_sort"],
                 "C++ std::sort runtime": [str(cpp), "sort-runtime"],
                 "C++ std::stable_sort runtime": [str(cpp), "stable_sort-runtime"]}
        results.update(timed(measure_sort, {lane: Program(command, 0) for lane, command in lanes.items()}))
    DATA.mkdir(parents=True, exist_ok=True)
    clang = subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]
    (DATA / "references.json").write_text(json.dumps(
        {"recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "clang": clang,
         "results": results}, indent=1) + "\n")


def archive_worktree(destination: Path) -> None:
    files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                    cwd=ROOT).split(b"\0")
    for raw in files:
        if not raw:
            continue
        path = ROOT / raw.decode()
        if not path.exists():
            continue
        target = destination / raw.decode()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target, follow_symlinks=False)


def record(arguments: argparse.Namespace) -> str | None:
    if arguments.cpu is not None and arguments.cpu not in ORIGINAL_AFFINITY:
        sys.exit("--cpu must be in the allowed CPU set")
    global TIMED_CPU
    TIMED_CPU = arguments.cpu
    DATA.mkdir(parents=True, exist_ok=True)
    suite = suite_hash()
    targets = [None] if arguments.worktree else first_parent(arguments.since)
    for rev in targets:
        stem = "worktree" if rev is None else rev[:12]
        path = DATA / f"{stem}.json"
        if path.exists():
            print(f"{stem}: entry already exists; stopping", flush=True)
            break
        if not arguments.skip_references and not (DATA / "references.json").exists():
            print("measuring C/C++ references", flush=True)
            record_references()
        info = {"commit": "worktree", "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "subject": "working tree (uncommitted)"} if rev is None else commit_info(rev)
        print(f"{stem}: {info['subject'][:60]}", flush=True)
        with tempfile.TemporaryDirectory(prefix="chimera-runtime-history-") as directory:
            work = Path(directory)
            source = work / "source"
            source.mkdir()
            if rev is None:
                archive_worktree(source)
            else:
                archived = subprocess.Popen(["git", "archive", rev], cwd=ROOT, stdout=subprocess.PIPE)
                subprocess.run(["tar", "-x", "-C", str(source)], stdin=archived.stdout, check=True)
                archived.wait()
            try:
                results = record_commit(source, work)
            except Exception as error:
                results = {"build": {"status": "failed", "reason": str(error)[:300]}}
        path.write_text(json.dumps({"schema": 1, "suite": suite, **info, "recorded_at":
                                    datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                    "environment": environment(), "results": results}, indent=1) + "\n")
        shown = {key: (f"{value['median']:.4g}s" if "median" in value else value["status"])
                 for key, value in results.items() if key in ("sieve", "key-gen", "build") or key.startswith("sort random")}
        print("  " + ", ".join(f"{key}={value}" for key, value in shown.items()), flush=True)
        for name, result in results.items():
            if result.get("status") == "failed":
                return f"{stem}: stopping at failed {name}: {result['reason']}"
    return None


# ---- Rendering ------------------------------------------------------------------------

def load_records() -> list[dict]:
    records = [json.loads(path.read_text()) for path in DATA.glob("*.json") if path.name != "references.json"]
    order = {rev: index for index, rev in enumerate(
        subprocess.check_output(["git", "rev-list", "--first-parent", "--reverse", "HEAD"], cwd=ROOT, text=True).split())}
    tail = len(order)
    return sorted(records, key=lambda record: (order.get(record["commit"], tail), record["date"]))


def load_references() -> dict:
    path = DATA / "references.json"
    return json.loads(path.read_text()) if path.exists() else {"results": {}}


def format_seconds(value: float) -> str:
    return f"{value * 1000:.2f} ms" if value < 1 else f"{value:.3f} s"


LEFT, RIGHT, TOP, BOTTOM = 62, 14, 14, 28


def nice_ceiling(value: float) -> tuple[float, float]:
    """A round axis top and step covering `value` with four intervals."""
    magnitude = 10 ** math.floor(math.log10(value / 4))
    for factor in (1, 2, 2.5, 5, 10):
        step = factor * magnitude
        if step * 4 >= value:
            return step * 4, step
    return value, value / 4


def chart(title: str, series: list[dict], records: list[dict], references: list[dict], note: str = "", wide: bool = False) -> str:
    """One line chart: series are Chimera lanes over commits, references are flat lines."""
    measured_indices = sorted({index for line in series for index in line["points"]})
    positions = {index: position for position, index in enumerate(measured_indices)}
    values = [point["median"] for line in series for point in line["points"].values()]
    values += [reference["median"] for reference in references]
    if not values:
        return f'<figure><figcaption>{html.escape(title)}</figcaption><p class="muted">No successful measurement.</p></figure>'
    W, H = (1100, 300) if wide else (520, 250)
    top, step_size = nice_ceiling(max(values) * 1.06)
    count = max(len(measured_indices) - 1, 1)

    def x(index: int) -> float:
        position = positions[index] if len(measured_indices) > 1 else 0.5
        return LEFT + (W - LEFT - RIGHT) * position / count

    def y(value: float) -> float:
        return TOP + (H - TOP - BOTTOM) * (1 - value / top)

    parts = [f'<svg viewBox="0 0 {W} {H}" class="{'wide' if wide else ''}" role="img" aria-label="{html.escape(title)}">']
    for step in range(5):
        value = step_size * step
        parts.append(f'<line class="grid" x1="{LEFT}" x2="{W - RIGHT}" y1="{y(value):.1f}" y2="{y(value):.1f}"/>')
        parts.append(f'<text class="axis" x="{LEFT - 6}" y="{y(value) + 4:.1f}" text-anchor="end">{html.escape(format_seconds(value))}</text>')
    stride = max(1, math.ceil(len(measured_indices) / ((W - LEFT - RIGHT) / 64)))
    last = len(measured_indices) - 1
    for position, index in enumerate(measured_indices):
        if position == last or (position % stride == 0 and last - position >= stride):
            parts.append(f'<text class="axis" x="{x(index):.1f}" y="{H - BOTTOM + 16}" text-anchor="middle">{records[index]["date"][5:10]}</text>')
    for number, reference in enumerate(references):
        parts.append(f'<line class="ref ref{number % 3}" x1="{LEFT}" x2="{W - RIGHT}" y1="{y(reference["median"]):.1f}" y2="{y(reference["median"]):.1f}"/>')
        parts.append(f'<text class="axis ref{number % 3}t" x="{W - RIGHT}" y="{y(reference["median"]) - 4:.1f}" text-anchor="end">{html.escape(reference["label"])} {html.escape(format_seconds(reference["median"]))}</text>')
    for number, line in enumerate(series):
        indices = sorted(line["points"])
        path = " ".join(f'{"M" if k == 0 else "L"}{x(i):.1f},{y(line["points"][i]["median"]):.1f}' for k, i in enumerate(indices))
        parts.append(f'<path class="line s{number}" d="{path}"/>')
        for i in indices:
            point = line["points"][i]
            record = records[i]
            tip = (f'{line["label"]}\n{record["commit"][:10]}  {record["date"][:10]}\n{record["subject"]}\n'
                   f'median {format_seconds(point["median"])}  range {format_seconds(point["min"])} to {format_seconds(point["max"])}'
                   f'\n{len(point["samples"])} samples{"" if point.get("stable") else ", unstable"}')
            parts.append(f'<circle class="dot s{number}" cx="{x(i):.1f}" cy="{y(point["median"]):.1f}" r="3.4"><title>{html.escape(tip)}</title></circle>')
    parts.append("</svg>")
    legend = "".join(f'<span class="key k{n}">{html.escape(line["label"])}</span>' for n, line in enumerate(series))
    return f'<figure><figcaption>{html.escape(title)}</figcaption>{"".join(parts)}<div class="legend">{legend}</div>{f"<p class=muted>{html.escape(note)}</p>" if note else ""}</figure>'


def series_for(records: list[dict], key: str, label: str) -> dict:
    points = {index: record["results"][key] for index, record in enumerate(records)
              if "median" in record["results"].get(key, {})}
    return {"label": label, "points": points}


def reference_list(references: dict, keys: list[tuple[str, str]]) -> list[dict]:
    found = []
    for key, label in keys:
        value = references["results"].get(key)
        if value:
            found.append({"label": label, "median": value["median"]})
    return found


CSS = """
:root{--bg:#fbfbfa;--fg:#1c1d1f;--muted:#6b6f76;--grid:#e3e4e6;--card:#fff;--line:#d9dadd;
--s0:#2f6fdb;--s1:#d9822b;--r0:#7b7f87;--r1:#9a6bd1;--r2:#2f9e75}
@media(prefers-color-scheme:dark){:root{--bg:#141517;--fg:#e8e9eb;--muted:#9a9ea6;--grid:#2a2c30;--card:#1b1c1f;--line:#34363b;
--s0:#6ea2ff;--s1:#f0a65a;--r0:#9aa0a8;--r1:#b794e8;--r2:#58c79d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
main{max-width:1180px;margin:0 auto;padding:28px 16px 60px}h1{font-size:26px;margin:0 0 4px}h2{font-size:19px;margin:34px 0 6px}
.muted{color:var(--muted);margin:2px 0 10px;font-size:13.5px}
table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--line);font-size:14px}
th,td{padding:7px 11px;border-bottom:1px solid var(--line);text-align:right}th:first-child,td:first-child{text-align:left}
th{color:var(--muted);font-weight:600}.good{color:var(--r2)}.bad{color:#d1483f}
.grid-charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:14px}
figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}
figcaption{font-weight:600;margin-bottom:4px}svg{width:100%;height:auto;display:block}
.grid{stroke:var(--grid);stroke-width:1}.axis{fill:var(--muted);font-size:10.5px}svg.wide .axis{font-size:12px}.axis.ref0t,.axis.ref1t,.axis.ref2t{paint-order:stroke;stroke:var(--card);stroke-width:3px}svg.wide{max-height:340px}
.line{fill:none;stroke-width:2}.dot{stroke:var(--card);stroke-width:1.2}
.s0{stroke:var(--s0)}.s1{stroke:var(--s1)}circle.s0{fill:var(--s0)}circle.s1{fill:var(--s1)}
.ref{stroke-width:1.2;stroke-dasharray:5 4}.ref0{stroke:var(--r0)}.ref1{stroke:var(--r1)}.ref2{stroke:var(--r2)}
.ref0t{fill:var(--r0)}.ref1t{fill:var(--r1)}.ref2t{fill:var(--r2)}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12.5px;color:var(--muted)}
.key::before{content:"";display:inline-block;width:14px;height:3px;margin-right:6px;vertical-align:middle;background:currentColor}
.key.k0{color:var(--s0)}.key.k1{color:var(--s1)}
"""


def render() -> None:
    records = load_records()
    references = load_references()
    if not records:
        sys.exit(f"no records in {DATA}")
    sections = []
    rows = []

    def ratio_cell(chimera: float | None, reference: float | None) -> str:
        if not chimera or not reference:
            return "<td>-</td>"
        value = chimera / reference
        return f'<td class="{"good" if value <= 1.25 else "bad" if value > 2 else ""}">{value:.2f}x</td>'

    latest = records[-1]["results"]

    def row(name: str, key: str, ref_key: str) -> None:
        now = latest.get(key, {}).get("median")
        reference = references["results"].get(ref_key, {}).get("median")
        cell_now = html.escape(format_seconds(now)) if now else "-"
        rows.append(f"<tr><td>{html.escape(name)}</td><td>{cell_now}</td>{ratio_cell(now, reference)}"
                    f"<td>{html.escape(format_seconds(reference)) if reference else '-'}</td></tr>")

    row("Sieve (88M)", "sieve", "sieve C -O3")
    row("Five-face key search", "key-gen", "key-gen C -O3")
    for pattern in PATTERNS:
        row(f"Sort {pattern}, static", f"sort {pattern} / Chimera static", f"sort {pattern} / C++ std::sort")
        row(f"Sort {pattern}, runtime comparator", f"sort {pattern} / Chimera runtime", f"sort {pattern} / C++ std::sort runtime")
    commits = [record for record in records if record["commit"] != "worktree"]
    unsupported = sum(1 for record in records if all("median" not in value for value in record["results"].values()))
    sections.append(f"""<h2>Latest ({html.escape(records[-1]['subject'][:70])})</h2>
<p class="muted">Ratios compare the latest record with the C/C++ reference (-O3, std::sort for the static comparator) measured on this machine.</p>
<table><tr><th>Benchmark</th><th>Chimera</th><th>vs reference</th><th>Reference</th></tr>{''.join(rows)}</table>""")
    sections.append("<h2>Sieve of Eratosthenes, limit 88,000,000</h2><p class=\"muted\">Process wall time. Dashed line: Clang C -O3.</p><div class=\"grid-charts\">" + chart(
        "Sieve", [series_for(records, "sieve", "Chimera")], records,
        reference_list(references, [("sieve C -O3", "C -O3")]), wide=True) + "</div>")
    sections.append("<h2>Five-face key search</h2><p class=\"muted\">Process wall time, last key index 10. Dashed line: Clang C -O3.</p><div class=\"grid-charts\">" + chart(
        "Key search", [series_for(records, "key-gen", "Chimera")], records,
        reference_list(references, [("key-gen C -O3", "C -O3")]), wide=True) + "</div>")
    charts = []
    for pattern in PATTERNS:
        charts.append(chart(f"Sort: {pattern}", [
            series_for(records, f"sort {pattern} / Chimera static", "Chimera static comparator"),
            series_for(records, f"sort {pattern} / Chimera runtime", "Chimera runtime comparator")], records,
            reference_list(references, [(f"sort {pattern} / C++ std::sort", "std::sort"),
                                        (f"sort {pattern} / C++ std::stable_sort", "std::stable_sort"),
                                        (f"sort {pattern} / C++ std::sort runtime", "std::sort via pointer")])))
    sections.append(f"<h2>Array sort, {SORT_SIZE} int32 elements, {SORT_ROUNDS} sorts per process</h2>"
                    "<p class=\"muted\">Process wall time for fill, sort, verification. Dashed lines: Clang C++17 -O3.</p>"
                    f"<div class=\"grid-charts\">{''.join(charts)}</div>")
    environment = records[-1].get("environment", {})
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Chimera runtime benchmarks</title><style>{CSS}</style></head><body><main>
<h1>Chimera runtime benchmarks</h1>
<p class="muted">{len(commits)} commits{f", plus the working tree" if len(commits) != len(records) else ""}; each point is the current benchmark program compiled by that commit's compiler.
{f"{unsupported} record(s) could not compile any benchmark. " if unsupported else ""}{html.escape(environment.get('cpu', ''))}; Zig {html.escape(environment.get('zig', ''))};
{html.escape(references.get('clang', ''))}. Hover a point for commit, range and sample count.</p>
{''.join(sections)}
</main></body></html>
"""
    REPORT.write_text(page)
    print(f"wrote {REPORT}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--since", help="oldest commit to include (default: every first-parent commit)")
    parser.add_argument("--worktree", action="store_true", help="measure the working tree instead of commits")
    parser.add_argument("--cpu", type=int, help="pin timed runs to this CPU")
    parser.add_argument("--skip-references", action="store_true")
    arguments = parser.parse_args()
    failure = record(arguments)
    render()
    if failure:
        sys.exit(failure)


if __name__ == "__main__":
    main()
