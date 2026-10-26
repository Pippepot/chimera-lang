#!/usr/bin/env python3
"""Record exact compiler snapshots and render hand-drawn history graphs."""

from __future__ import annotations

import argparse
import base64
import csv
import fcntl
import hashlib
import html
import io
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parent.parent
PROTOCOL = "core-million-zero-workers-v6"
SAMPLING_PROTOCOL = "one-warmup-range-2pct-min2-compile3-runtime5-v1"
MINIMUM_SAMPLES = 2
MAXIMUM_SAMPLES = 5
COMPILATION_MAXIMUM_SAMPLES = 3
RELATIVE_RANGE_PERCENT = 2
COMPILATION_PROTOCOL = "core-million-modules-one-line-leaf-v2"
RUNTIME_PROTOCOL = "sieve-88000000-i32-wall-v1"
LEGACY_RUNTIME = {
    "suite": "4820879fd6e6ae15a0d1e71b4a070054600c5ea7caecbea87971a75f41f4e509",
    "identity": {"protocol": "sieve-88000000-i32-wall-v1",
                 "source": "6daad48db9d9581f742de5185243d81c1ca139dd5a3029355bd383aa616ad9e4"},
}
C_LANES = ("c-O0", "c-O3")
COMPILATION_CASE = "core-1000000"
RUNTIME_CASE = "sieve-88000000"
COMPILATION_LANES = {"normal": "Compile", "workers-8": "Compile (8 workers)"}
CORE_CASES = {COMPILATION_CASE: ("cold", "leaf-edit"), RUNTIME_CASE: ("runtime",)}
COMPILATION_ESTIMATES = {
    "cold": ("C++ -O0: 160 s", "C++ -O2: 268 s"),
}
COMPILER_BRIDGE = '''pub const optimize_mode = @import("builtin").mode;
pub const query = @import("query/engine.zig");
pub const modules = @import("modules.zig");
pub const queries = @import("queries.zig");
pub const structures = @import("structures.zig");
'''


def prepare(snapshot: Path) -> bool:
    if not (snapshot / "src/query/engine.zig").is_file() or not (snapshot / "std/library.zig").is_file():
        raise FileNotFoundError("revision predates the fixed harness's compiler/module API")
    bundled = (snapshot / "src/standard_bundle.zig").exists()
    (snapshot / "benchmarks").mkdir(exist_ok=True)
    for name in ("history_benchmark.zig", "history_sampling.zig", "history_workload.zig", "history_runtime.c"):
        shutil.copy2(ROOT / "benchmarks" / name, snapshot / "benchmarks" / name)
    shutil.copy2(ROOT / "benchmarks/history_build.zig", snapshot / ".history.build.zig")
    bridge = COMPILER_BRIDGE
    if bundled:
        bridge += 'pub const standard_bundle = @import("standard_bundle.zig");\n'
    (snapshot / "src/.history_compiler.zig").write_text(bridge)
    return bundled


def suite_id() -> str:
    digest = hashlib.sha256(COMPILER_BRIDGE.encode())
    for name in ("history_benchmark.zig", "history_sampling.zig", "history_workload.zig", "history_runtime.c", "history_build.zig"):
        digest.update(b"\0" + (ROOT / "benchmarks" / name).read_bytes())
    return digest.hexdigest()


def command(arguments: list[str], cwd: Path = ROOT) -> str:
    result = subprocess.run(arguments, cwd=cwd, check=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="", flush=True)
    return result.stdout.strip()


def commits(revision: str) -> list[tuple[str, str]]:
    lines = command(["git", "log", "--first-parent", "--reverse", "--format=%H %cI", revision]).splitlines()
    return [tuple(line.split(" ", 1)) for line in lines]


def unpack(commit: str, destination: Path) -> None:
    archive = subprocess.run(["git", "archive", "--format=tar", commit], cwd=ROOT,
                             check=True, stdout=subprocess.PIPE).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(destination, filter="data")


def copy_worktree(destination: Path, data: Path) -> str:
    paths = command(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(paths) - {""}):
        source = ROOT / name
        if source.is_relative_to(data) or not os.path.lexists(source):
            continue
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            contents = os.fsencode(os.readlink(source))
            target.symlink_to(os.readlink(source))
            kind = b"symlink"
        else:
            contents = source.read_bytes()
            shutil.copy2(source, target)
            kind = b"executable" if source.stat().st_mode & 0o111 else b"file"
        for value in (os.fsencode(name), kind, contents):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


def loc(snapshot: Path) -> dict[str, int]:
    paths = [path.relative_to(snapshot).as_posix() for pattern in
             ("test_sources.zig", "src/**/*.zig", "tests/**/*.zig")
             for path in sorted(snapshot.glob(pattern)) if path.is_file()]
    if not (snapshot / "src").is_dir():
        paths = [path.name for path in sorted(snapshot.glob("*.zig"))
                 if path.name != "build.zig" and not path.name.endswith("_benchmark.zig")]
    if not paths:
        return {"code": 0, "test": 0, "total": 0}
    return json.loads(command(["bash", str(ROOT / "loc.sh"), "--json", *paths], snapshot))


def loc_policy() -> str:
    return hashlib.sha256(b"root-or-src-layout-v2\0" + (ROOT / "loc.sh").read_bytes()).hexdigest()


def validate_measurement(samples: list[dict], *, legacy: bool = False) -> None:
    count = samples[0].get("sample_count")
    maximum = COMPILATION_MAXIMUM_SAMPLES if samples[0]["case"] == COMPILATION_CASE else MAXIMUM_SAMPLES
    if count is None and legacy:
        count = 9
        if any("sample_count" in sample or "stable" in sample for sample in samples):
            raise ValueError("mixed sampling protocols")
    else:
        if not isinstance(count, int) or not MINIMUM_SAMPLES <= count <= maximum:
            raise ValueError("invalid declared sample count")
        if any(sample.get("sample_count") != count for sample in samples):
            raise ValueError("inconsistent declared sample count")
        values = sorted(sample["nanoseconds"] for sample in samples)
        middle = len(values) // 2
        median = (values[middle - 1] + (values[middle] - values[middle - 1]) // 2
                  if len(values) % 2 == 0 else values[middle])
        stable = median > 0 and (values[-1] - values[0]) * 100 <= median * RELATIVE_RANGE_PERCENT
        if any(sample.get("stable") is not stable for sample in samples):
            raise ValueError("incorrect stability declaration")
        if not stable and count != maximum:
            raise ValueError("unstable measurement ended before the sample cap")
    if sorted(sample["sample"] for sample in samples) != list(range(count)):
        raise ValueError("incomplete or duplicate benchmark samples")
    if any(sample["nanoseconds"] < 0 or sample["executable_bytes"] <= 0 for sample in samples):
        raise ValueError("invalid benchmark measurement")


def parse_samples(text: str, case: str | None = None) -> list[dict]:
    samples = list(csv.DictReader(io.StringIO(text)))
    if not samples:
        raise ValueError("benchmark produced no samples")
    groups = defaultdict(list)
    for sample in samples:
        try:
            for field in ("sample", "nanoseconds", "executable_bytes", "sample_count"):
                sample[field] = int(sample[field])
            if sample["stable"] not in ("true", "false"):
                raise ValueError("invalid stability declaration")
            sample["stable"] = sample["stable"] == "true"
            groups[(sample["case"], sample["lane"], sample["phase"])].append(sample)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError("invalid benchmark sample") from error
    for measurement in groups.values():
        validate_measurement(measurement)
    compilation = [{(COMPILATION_CASE, lane, phase) for phase in CORE_CASES[COMPILATION_CASE]}
                   for lane in COMPILATION_LANES]
    compilation.append(set.union(*compilation))
    runtime = {(RUNTIME_CASE, "normal", "runtime")}
    references = {(RUNTIME_CASE, lane, "runtime") for lane in C_LANES}
    allowed = tuple(expected | extra for expected in compilation
                    for extra in (set(), runtime, runtime | references))
    if case == COMPILATION_CASE:
        allowed = tuple(compilation)
    elif case == RUNTIME_CASE:
        allowed = (runtime, runtime | references)
    if set(groups) not in allowed:
        raise ValueError("benchmark workload set changed; update the recording protocol")
    return samples


def sampling_note(sample: dict) -> str:
    if "stable" not in sample:
        return "; fixed-count sampling"
    maximum = COMPILATION_MAXIMUM_SAMPLES if sample.get("case") == COMPILATION_CASE else MAXIMUM_SAMPLES
    return "; stable (<=2% range)" if sample["stable"] else f"; unstable at {maximum}-sample cap"


def runner() -> dict:
    model = next((line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                  if line.startswith("model name")), platform.processor())
    return {"host": platform.node(), "cpu": model, "kernel": platform.release(),
            "architecture": platform.machine(), "affinity": sorted(os.sched_getaffinity(0))}


def save(data: Path, record: dict) -> None:
    directory = data / "records"
    directory.mkdir(parents=True, exist_ok=True)
    filename = record["recorded_at"].replace(":", "-") + "-" + record["snapshot"][:12] + ".json"
    temporary = directory / (filename + ".tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(directory / filename)


def read_records(data: Path) -> list[dict]:
    return [json.loads(path.read_text()) for path in sorted((data / "records").glob("*.json"))]


def runtime_identity(record: dict) -> dict | None:
    if "runtime_suite" in record:
        return record["runtime_suite"]
    if record.get("protocol") == "core-normal-zero-workers-v4" and record.get("suite") == LEGACY_RUNTIME["suite"]:
        return LEGACY_RUNTIME["identity"]
    return None


def cached_c_reference(records: list[dict], current: dict) -> tuple[list[dict], dict] | None:
    keys = ("zig", "runner", "c_compiler")
    for previous in sorted(records, key=lambda record: record["recorded_at"], reverse=True):
        if any(previous.get(key) != current.get(key) for key in keys):
            continue
        if runtime_identity(current) is None or runtime_identity(previous) != runtime_identity(current):
            continue
        for benchmark in previous["benchmarks"]:
            if benchmark["mode"] != "fast":
                continue
            samples = [sample for sample in benchmark["samples"] if sample["lane"] in C_LANES]
            if {sample["lane"] for sample in samples} != set(C_LANES):
                continue
            if any(sample["case"] != RUNTIME_CASE or sample["phase"] != "runtime" for sample in samples):
                continue
            try:
                for lane in C_LANES:
                    validate_measurement([sample for sample in samples if sample["lane"] == lane], legacy=True)
            except (KeyError, TypeError, ValueError):
                continue
            origin = previous.get("c_reference", {"snapshot": previous["snapshot"], "recorded_at": previous["recorded_at"]})
            return [dict(sample) for sample in samples], dict(origin)
    return None


def environment() -> dict:
    return {"suite": suite_id(), "protocol": PROTOCOL, "compilation_protocol": COMPILATION_PROTOCOL,
            "sampling_protocol": SAMPLING_PROTOCOL,
            "runtime_suite": {"protocol": RUNTIME_PROTOCOL,
                              "source": hashlib.sha256((ROOT / "benchmarks/history_runtime.c").read_bytes()).hexdigest()},
            "zig": command(["zig", "version"]),
            "runner": runner(), "c_compiler": {"path": shutil.which("cc"), "version": command(["cc", "--version"])}}


def measure(snapshot: Path, commit: str, date: str, identity: str, worktree: bool,
            only_loc: bool, data: Path, refresh_c: bool = False) -> dict:
    record = {"schema": 1, "commit": commit, "commit_date": date, "snapshot": identity,
              "worktree": worktree, "recorded_at": datetime.now(timezone.utc).isoformat(),
              "loc_policy": loc_policy(),
              "loc": loc(snapshot), "benchmarks": []}
    if only_loc:
        return record
    record.update(environment())
    bundled = prepare(snapshot)
    record["standard_library"] = "bundled" if bundled else "source"
    record["failures"] = []
    cached = cached_c_reference(read_records(data), record) if not refresh_c else None
    arguments = ["zig", "build", "--build-file", ".history.build.zig", "history-benchmark", "--seed=0", "-j1",
                 f"-Dbundled-std={'true' if bundled else 'false'}", "--"]
    if cached is not None:
        arguments.append("--skip-c")
        print("Reusing cached C reference (-O0 and -O3)", flush=True)
    print(f"Benchmarking {identity[:12]} (ReleaseFast)", flush=True)
    measured = []
    for case, workers in ((COMPILATION_CASE, 0), (COMPILATION_CASE, 8), (RUNTIME_CASE, 0)):
        try:
            worker_arguments = ["--workers=8"] if workers else []
            rows = parse_samples(command([*arguments, f"--case={case}", *worker_arguments], snapshot), case)
            if case == COMPILATION_CASE:
                expected_lane = "workers-8" if workers else "normal"
                if {sample["lane"] for sample in rows} != {expected_lane}:
                    raise ValueError(f"compilation benchmark must supply the {expected_lane} lane")
            measured.extend(rows)
        except (subprocess.CalledProcessError, ValueError) as error:
            details = str(error)
            if isinstance(error, subprocess.CalledProcessError):
                details += "\n" + (error.stdout or "") + "\n" + (error.stderr or "")
            logs = data / "failures"
            logs.mkdir(parents=True, exist_ok=True)
            suffix = "-workers-8" if workers else ""
            filename = f"{record['recorded_at'].replace(':', '-')}-{commit[:12]}-{case}{suffix}.log"
            (logs / filename).write_text(details + "\n")
            record["failures"].append({"case": case, "workers": workers, "log": f"failures/{filename}"})
            print(f"  {case}{suffix}: unavailable (see failures/{filename})", flush=True)
    if cached is not None:
        if any(sample["lane"] in C_LANES for sample in measured):
            raise ValueError("benchmark did not skip cached C measurements")
        measured.extend(cached[0])
        record["c_reference"] = cached[1]
    elif any(sample["lane"] in C_LANES for sample in measured):
        record["c_reference"] = {"snapshot": identity, "recorded_at": record["recorded_at"]}
    record["benchmarks"].append({"mode": "fast", "samples": measured})
    return record


def chart(series: dict[str, list[tuple[float, float, str]]], history: list[tuple[str, str]],
    unit: str, png: Path | None = None, title: str | None = None, markers: bool = True,
    references: dict[str, tuple[float, str]] | None = None, estimates: tuple[str, ...] = ()) -> str:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib import font_manager, pyplot, ticker
    from matplotlib.lines import Line2D

    references = references or {}
    points = [point for values in series.values() for point in values]
    maximum = max([point[1] for point in points] + [value for value, _ in references.values()], default=1) * 1.12 or 1
    first = min((point[0] for point in points), default=0)
    last = max((point[0] for point in points), default=1)
    ticks = sorted({max(first, min(last, round(first + (last - first) * step / 5)))
                    for step in range(6)})
    if first == last:
        first -= 0.5
        last += 0.5
    font = ROOT / "benchmarks/fonts/ComicNeue-Regular.ttf"
    if not any(Path(entry.fname) == font for entry in font_manager.fontManager.ttflist):
        font_manager.fontManager.addfont(font)
    settings = {"font.family": ["Comic Neue"], "svg.fonttype": "none", "font.size": 10,
                "axes.spines.top": False, "axes.spines.right": False}
    with pyplot.xkcd(scale=0.7, length=120, randomness=1.5), matplotlib.rc_context(settings):
        figure, axis = pyplot.subplots(figsize=(9, 3.8), layout="constrained")
        try:
            for index, (name, values) in enumerate(series.items()):
                color = "#444444"
                line_style, line_width = (("-", 1.8), (":", 2.6), ("--", 1.5), ("-.", 2.2))[index % 4]
                label = name
                if (name.startswith("Compile") or name == "Runtime" or estimates) and values:
                    label = f"{name}: {max(values, key=lambda point: point[0])[1]:.3f} {unit}"
                line, = axis.plot([point[0] for point in values], [point[1] for point in values],
                                  color=color, linestyle=line_style, linewidth=line_width, label=label,
                                  gid=f"series-{index}")
                if line_style != "-":
                    line.set_path_effects([])
                    line.set_sketch_params(None)
                if markers:
                    for point_index, (position, value, _) in enumerate(values):
                        axis.plot(position, value, "o", color=color, markersize=3.5, path_effects=[],
                                  markerfacecolor=color if index == 0 else "white",
                                  gid=f"point-{index}-{point_index}")
            reference_color = next((line.get_color() for line in axis.lines
                                    if line.get_label().startswith("Runtime")), "#444444")
            for index, (name, (value, _)) in enumerate(references.items()):
                line = axis.axhline(value, color=reference_color,
                                    linestyle=(":", "--", "-.", ":")[index % 4], linewidth=1.2,
                                    label=f"{name}: {value:.3f} {unit}", path_effects=[], gid=f"reference-{index}")
                line.set_sketch_params(None)
            padding = (last - first) * 0.025
            axis.set_xlim(first - padding, last + padding)
            axis.set_ylim(0, maximum)
            axis.set_xticks(ticks, [history[min(int(position), len(history) - 1)][1][:10]
                                   for position in ticks], fontsize=8)
            axis.set_xlabel("Commit")
            axis.set_ylabel(unit)
            axis.ticklabel_format(axis="y", style="plain", useOffset=False)
            if unit == "lines":
                axis.yaxis.set_major_locator(ticker.MultipleLocator(10_000))
                axis.grid(axis="y", linestyle=":", linewidth=0.8, alpha=0.35)
                for gridline in axis.get_ygridlines():
                    gridline.set_path_effects([])
                    gridline.set_sketch_params(None)
            else:
                axis.grid(axis="y", alpha=0.2)
            if title:
                axis.set_title(title, fontsize=12, pad=14)
            compilation = any(name.startswith("Compile") for name in series)
            if len(series) > 1 or references or estimates or compilation:
                handles, labels = axis.get_legend_handles_labels()
                handles.extend(Line2D([], [], linestyle="none") for _ in estimates)
                labels.extend(estimates)
                side_legend = bool(estimates) or compilation
                axis.legend(handles, labels, frameon=False, loc="upper left" if side_legend else "upper right",
                            bbox_to_anchor=(1.02, 1) if side_legend else (1, 1))
            for text in figure.findobj(matplotlib.text.Text):
                text.set_path_effects([])
            output = io.StringIO()
            figure.savefig(output, format="svg", metadata={"Date": None})
            if png is not None:
                figure.savefig(png, format="png", dpi=160)
        finally:
            pyplot.close(figure)
    svg = ElementTree.fromstring(output.getvalue())
    svg.set("role", "img")
    svg.set("aria-label", title or f"{unit} over commits")
    namespace = "http://www.w3.org/2000/svg"
    encoded_font = base64.b64encode(font.read_bytes()).decode("ascii")
    ElementTree.SubElement(svg, f"{{{namespace}}}style").text = (
        "@font-face{font-family:'Comic Neue';src:url(data:font/ttf;base64," + encoded_font + ")}")
    ElementTree.SubElement(svg, f"{{{namespace}}}metadata").text = font.with_name("OFL.txt").read_text()
    if markers:
        for index, (name, values) in enumerate(series.items()):
            for point_index, (_, value, description) in enumerate(values):
                dot = svg.find(f".//*[@id='point-{index}-{point_index}']")
                ElementTree.SubElement(dot, f"{{{namespace}}}title").text = f"{name}: {value:,.3f} {unit}\n{description}"
    for index, (name, (value, description)) in enumerate(references.items()):
        line = svg.find(f".//*[@id='reference-{index}']")
        ElementTree.SubElement(line, f"{{{namespace}}}title").text = f"{name}: {value:,.3f} {unit}\n{description}"
    ElementTree.register_namespace("", namespace)
    return ElementTree.tostring(svg, encoding="unicode")


def graph_artifact(data: Path, name: str, series: dict, history: list[tuple[str, str]],
                   unit: str, title: str, markers: bool = True,
                   references: dict[str, tuple[float, str]] | None = None,
                   estimates: tuple[str, ...] = ()) -> str:
    directory = data / "graphs"
    directory.mkdir(parents=True, exist_ok=True)
    svg = chart(series, history, unit, png=directory / f"{name}.png", title=title, markers=markers,
                references=references, estimates=estimates)
    (directory / f"{name}.svg").write_text(svg + "\n")
    label = html.escape(title, quote=True)
    return (f"<object type='image/svg+xml' data='graphs/{name}.svg' aria-label='{label}'>"
            f"<img src='graphs/{name}.png' alt='{label}'></object>")


def benchmark_overview(images: list[Path], destination: Path) -> None:
    from matplotlib import pyplot

    columns = min(3, len(images))
    rows = (len(images) + columns - 1) // columns
    figure, axes = pyplot.subplots(rows, columns, figsize=(columns * 7.5, rows * 3.2),
                                   squeeze=False, layout="constrained")
    try:
        for axis in axes.flat:
            axis.set_axis_off()
        for axis, image in zip(axes.flat, images):
            axis.imshow(pyplot.imread(image))
        figure.savefig(destination, dpi=160)
    finally:
        pyplot.close(figure)


def report(data: Path, name: str, title: str, sections: list[str]) -> Path:
    content = ["<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width'>",
               f"<title>{html.escape(title)}</title><style>body{{font-family:'DejaVu Sans',sans-serif;margin:32px auto;padding:0 20px;max-width:1500px;color:#202722;background:#f7f8f6}}h1{{font-size:28px}}h2{{font-size:19px;margin-top:36px}}p{{line-height:1.5}}small{{overflow-wrap:anywhere;color:#59635b}}object,img{{width:100%;display:block;aspect-ratio:45/19}}section{{border-top:1px solid #d5dad5;padding-top:12px}}.plots{{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,480px),1fr));gap:24px}}article{{min-width:0}}</style>",
               f"<h1>{html.escape(title)}</h1>", *sections, "</html>"]
    path = data / name
    temporary = data / (name + ".tmp")
    temporary.write_text("\n".join(content) + "\n")
    temporary.replace(path)
    return path


def render(data: Path, history: list[tuple[str, str]]) -> Path:
    records = read_records(data)
    positions = {commit: index for index, (commit, _) in enumerate(history)}
    newest_record = max(records, key=lambda record: record["recorded_at"], default=None)
    records = [record for record in records if record["commit"] in positions
               and (not record["worktree"] or record is newest_record)]
    records.sort(key=lambda record: record["recorded_at"])
    loc_sections = []
    if records:
        policy = records[-1]["loc_policy"]
        latest = {}
        for record in records:
            if record["loc_policy"] == policy:
                latest[(record["commit"], "worktree" if record["worktree"] else "commit")] = record
        series = {"Code": sorted((positions[record["commit"]] + (0.35 if record["worktree"] else 0),
                                  record["loc"]["code"], description(record)) for record in latest.values())}
        loc_sections.append("<section><h2>Lines of Code</h2>" + graph_artifact(
            data, "loc", series, history, "lines", "Lines of Code", markers=False) + "</section>")
    groups = defaultdict(dict)
    runtime_suite = next((runtime_identity(record) for record in reversed(records) if runtime_identity(record) is not None), None)
    for record in records:
        current = record.get("protocol") in (PROTOCOL, "core-million-zero-workers-v5")
        runtime_compatible = runtime_identity(record) is not None and runtime_identity(record) == runtime_suite
        if not current and not runtime_compatible:
            continue
        for benchmark in record["benchmarks"]:
            if benchmark["mode"] != "fast":
                continue
            for runtime in (False, True):
                if (runtime and not runtime_compatible) or (not runtime and not current):
                    continue
                selected = [sample for sample in benchmark["samples"]
                            if (sample["phase"] == "runtime") == runtime
                            and sample["phase"] in CORE_CASES.get(sample["case"], ())]
                lanes = ("normal",) if runtime else COMPILATION_LANES
                if not any(sample["lane"] in lanes for sample in selected):
                    continue
                provenance = {"zig": record["zig"],
                              "runner": {key: value for key, value in record["runner"].items() if key != "affinity"}}
                if runtime:
                    provenance["runtime_suite"] = runtime_identity(record)
                    if "c_compiler" in record:
                        provenance["c_compiler"] = record["c_compiler"]
                else:
                    provenance["compilation_protocol"] = record.get("compilation_protocol", "core-million-modules-one-line-leaf-v1")
                configuration = json.dumps(provenance, sort_keys=True)
                key = (configuration, benchmark["mode"])
                point = (record["commit"], "worktree" if record["worktree"] else "commit")
                groups[key][point] = (record, {"mode": benchmark["mode"], "samples": selected})
    benchmark_sections = []
    benchmark_images = []
    for (configuration, mode), entries in groups.items():
        measurements = defaultdict(list)
        reference_record, reference_benchmark = max(entries.values(), key=lambda entry: entry[0]["recorded_at"])
        reference_samples = defaultdict(list)
        for sample in reference_benchmark["samples"]:
            if sample["phase"] == "runtime" and sample["lane"] in C_LANES:
                reference_samples[(sample["case"], sample["lane"])].append(sample["nanoseconds"] / 1_000_000_000)
        references = defaultdict(dict)
        for (case, lane), values in sorted(reference_samples.items()):
            spread = f"median of {len(values)}; min {min(values):.3f}, max {max(values):.3f} s"
            metadata = next(sample for sample in reference_benchmark["samples"]
                            if sample["case"] == case and sample["lane"] == lane and sample["phase"] == "runtime")
            spread += sampling_note(metadata)
            reference_date = reference_record.get("c_reference", reference_record)["recorded_at"][:10]
            references[case][f"C {lane[1:]}"] = (statistics.median(values), reference_date + "\n" + spread)
        for record, benchmark in entries.values():
            samples = defaultdict(list)
            for sample in benchmark["samples"]:
                lanes = COMPILATION_LANES if sample["case"] == COMPILATION_CASE else ("normal",)
                if sample["lane"] not in lanes or sample["phase"] not in CORE_CASES.get(sample["case"], ()):
                    continue
                divisor = 1_000_000_000 if sample["phase"] == "runtime" or sample["case"] == COMPILATION_CASE else 1_000_000
                samples[(sample["case"], sample["lane"], sample["phase"])].append(sample["nanoseconds"] / divisor)
            for key, values in samples.items():
                unit = "s" if key[2] == "runtime" or key[0] == COMPILATION_CASE else "ms"
                spread = f"median of {len(values)}; min {min(values):.3f}, max {max(values):.3f} {unit}"
                metadata = next(sample for sample in benchmark["samples"]
                                if (sample["case"], sample["lane"], sample["phase"]) == key)
                spread += sampling_note(metadata)
                measurements[key].append((positions[record["commit"]] + (0.35 if record["worktree"] else 0),
                                          statistics.median(values), description(record) + "\n" + spread))
        plots = defaultdict(dict)
        for (case, lane, phase), values in sorted(measurements.items()):
            label = "Runtime" if phase == "runtime" else COMPILATION_LANES[lane]
            plots[(case, phase)][label] = sorted(values)
        configuration_id = hashlib.sha256((configuration + mode).encode()).hexdigest()[:12]
        for heading, runtime in (("ReleaseFast Compilation", False), ("Generated Program Runtime", True)):
            selected = {key: series for key, series in plots.items() if (key[1] == "runtime") == runtime}
            if not selected:
                continue
            benchmark_sections.append(f"<section><h2>{html.escape(heading)}</h2><div class='plots'>")
            for (case, phase), series in sorted(selected.items()):
                name = f"{mode}-{configuration_id}-{case}-{phase}"
                graph = graph_artifact(data, name, series, history, "s", f"{case} / {phase}",
                                       references=references.get(case) if runtime else None,
                                       estimates=COMPILATION_ESTIMATES.get(phase, ()) if case == COMPILATION_CASE else ())
                benchmark_sections.append("<article>" + graph + "</article>")
                benchmark_images.append(data / "graphs" / f"{name}.png")
            benchmark_sections.append("</div></section>")
    if benchmark_images:
        benchmark_overview(benchmark_images, data / "benchmarks.png")
    else:
        benchmark_sections.append("<p>No benchmark measurements recorded.</p>")
    report(data, "benchmarks.html", "Chimera Compiler Benchmarks", benchmark_sections)
    return report(data, "index.html", "Chimera Compiler History", loc_sections + benchmark_sections)


def description(record: dict) -> str:
    return record["commit_date"][:10]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit", nargs="?", help="commit to measure, default HEAD")
    parser.add_argument("--worktree", action="store_true", help="measure tracked and nonignored untracked files before committing")
    parser.add_argument("--loc-only", action="store_true", help="record LOC without building the compiler")
    parser.add_argument("--backfill-loc", action="store_true", help="record missing LOC for every first-parent ancestor")
    parser.add_argument("--backfill-benchmarks", action="store_true", help="measure missing first-parent revisions, newest first; retain per-workload failure logs")
    parser.add_argument("--cpu", type=int, help="pin this run to a Linux CPU")
    parser.add_argument("--refresh-c", action="store_true", help="remeasure C reference timings instead of reusing matching records")
    parser.add_argument("--data-dir", type=Path, default=ROOT / ".history", help="result directory, default .history")
    parser.add_argument("--render-only", action="store_true", help="regenerate graphs without measuring")
    args = parser.parse_args()
    failed = False
    if args.worktree and (args.commit or args.backfill_loc or args.backfill_benchmarks):
        parser.error("--worktree cannot be combined with a commit or backfill")
    if args.backfill_benchmarks and (args.backfill_loc or args.loc_only):
        parser.error("--backfill-benchmarks cannot be combined with LOC-only recording")
    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})
    data = args.data_dir.resolve()
    data.mkdir(parents=True, exist_ok=True)
    with (data / "lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("another history recorder is using this result directory") from None
        revision = command(["git", "rev-parse", "--verify", (args.commit or "HEAD") + "^{commit}"])
        history = commits(revision)
        if not args.render_only:
            selected = list(reversed(history)) if args.backfill_benchmarks else history if args.backfill_loc else [history[-1]]
            policy = loc_policy()
            previous = [record for record in read_records(data) if not record["worktree"]]
            existing = {(record["commit"], record["loc_policy"]) for record in previous}
            current = environment() if args.backfill_benchmarks else {}
            attempted = {record["commit"] for record in previous
                         if "failures" in record and all(record.get(key) == value for key, value in current.items())}
            for commit, date in selected:
                if args.backfill_loc and (commit, policy) in existing:
                    continue
                if args.backfill_benchmarks and commit in attempted and not args.refresh_c:
                    continue
                with tempfile.TemporaryDirectory(prefix="chimera-history-") as directory:
                    snapshot = Path(directory)
                    if args.worktree:
                        identity = copy_worktree(snapshot, data)
                    else:
                        unpack(commit, snapshot)
                        identity = command(["git", "rev-parse", commit + "^{tree}"])
                    try:
                        record = measure(snapshot, commit, date, identity, args.worktree,
                                         args.loc_only or args.backfill_loc, data, args.refresh_c)
                    except OSError as error:
                        if not args.backfill_benchmarks:
                            raise
                        record = measure(snapshot, commit, date, identity, False, True, data)
                        record.update(current)
                        record["failures"] = [{"case": case, "error": str(error)} for case in CORE_CASES]
                    save(data, record)
                    if record.get("failures") and not args.backfill_benchmarks:
                        failed = True
                    count = sum(sample["lane"] in COMPILATION_LANES for benchmark in record["benchmarks"] for sample in benchmark["samples"])
                    print(f"Recorded {commit[:12]}: {record['loc']['code']:,} production lines, {count} benchmark samples", flush=True)
        report = render(data, history)
        print(f"Report: {report}")
        print(f"Benchmarks: {data / 'benchmarks.html'}")
        if (data / "benchmarks.png").exists():
            print(f"Benchmark image: {data / 'benchmarks.png'}")
        if failed:
            raise ValueError("requested benchmarks failed; see recorded failure logs")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"history: {error}", file=sys.stderr)
        sys.exit(1)
