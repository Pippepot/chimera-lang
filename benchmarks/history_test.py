import copy
import csv
import io
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
from xml.etree import ElementTree

import history


def samples(include_runtime=False, include_c=False):
    result = []
    for phase in ("cold", "leaf-edit"):
        for index in range(3):
            result.append({"case": history.COMPILATION_CASE, "lane": "normal", "phase": phase, "sample": index,
                           "nanoseconds": (index + 199) * 10_000, "executable_bytes": 100,
                           "sample_count": 3, "stable": True})
    if include_runtime or include_c:
        for index in range(5):
            result.append({"case": history.RUNTIME_CASE, "lane": "normal", "phase": "runtime", "sample": index,
                           "nanoseconds": (98 + index) * 1_000_000, "executable_bytes": 200,
                           "sample_count": 5, "stable": False})
    if include_c:
        for lane in history.C_LANES:
            level = int(lane.removeprefix("c-O"))
            for index in range(5):
                result.append({"case": history.RUNTIME_CASE, "lane": lane, "phase": "runtime", "sample": index,
                               "nanoseconds": (1602 + index - level) * 1_000_000, "executable_bytes": 300,
                               "sample_count": 5, "stable": True})
    return result


def encode(rows):
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=list(samples()[0]))
    writer.writeheader()
    writer.writerows({key: str(value).lower() if isinstance(value, bool) else value
                     for key, value in row.items()} for row in rows)
    return output.getvalue()


def record():
    return {"schema": 1, "commit": "abc", "commit_date": "2026-10-23T10:00:00Z",
            "snapshot": "tree", "worktree": False, "recorded_at": "2026-10-23T11:00:00Z",
            "loc_policy": "policy", "loc": {"code": 10, "test": 20, "total": 30},
            "suite": "suite", "protocol": history.PROTOCOL, "zig": "0.17.0",
            "compilation_protocol": history.COMPILATION_PROTOCOL,
            "runtime_suite": copy.deepcopy(history.LEGACY_RUNTIME["identity"]),
            "runner": {"host": "test", "cpu": "CPU", "affinity": [0]},
            "benchmarks": [{"mode": "fast", "samples": samples()}]}


class HistoryTests(unittest.TestCase):
    def test_csv_round_trip(self):
        self.assertEqual(history.parse_samples(encode(samples())), samples())

    def test_adaptive_counts_and_independent_phases(self):
        rows = [row for row in samples() if row["phase"] == "leaf-edit" or row["sample"] < 2]
        for row in rows:
            if row["phase"] == "cold":
                row["sample_count"] = 2
        self.assertEqual(history.parse_samples(encode(rows)), rows)

    def test_rejects_premature_or_falsely_stable_measurements(self):
        for count, stable, noisy in ((1, False, False), (2, False, True), (2, True, True), (5, False, False)):
            rows = [{"case": history.RUNTIME_CASE, "lane": "normal", "phase": "runtime", "sample": index,
                     "nanoseconds": 100_000 + (10_000 if noisy and index == 0 else 0),
                     "executable_bytes": 42, "sample_count": count, "stable": stable}
                    for index in range(count)]
            with self.subTest(count=count, stable=stable, noisy=noisy), self.assertRaises(ValueError):
                history.parse_samples(encode(rows), history.RUNTIME_CASE)

    def test_rejects_inconsistent_count_and_stability_metadata(self):
        for field, value in (("sample_count", 2), ("stable", False)):
            rows = samples()
            rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                history.parse_samples(encode(rows))

    def test_rejects_truncated_csv_fields(self):
        with self.assertRaises(ValueError):
            history.parse_samples(encode(samples()).rsplit(",", 2)[0])

    def test_sampling_notes_distinguish_stable_capped_and_legacy_results(self):
        self.assertIn("stable (<=2% range)", history.sampling_note({"stable": True}))
        self.assertIn("unstable at 5-sample cap", history.sampling_note({"stable": False}))
        self.assertIn("unstable at 3-sample cap", history.sampling_note({"case": history.COMPILATION_CASE, "stable": False}))
        self.assertIn("fixed-count", history.sampling_note({}))

    def test_c_reference_accepts_complete_adaptive_and_legacy_samples(self):
        for legacy in (False, True):
            previous = record()
            previous["benchmarks"][0]["samples"] = samples(include_c=True)
            if legacy:
                for lane in history.C_LANES:
                    template = next(sample for sample in previous["benchmarks"][0]["samples"] if sample["lane"] == lane)
                    previous["benchmarks"][0]["samples"].extend(dict(template, sample=index) for index in range(5, 9))
                for sample in previous["benchmarks"][0]["samples"]:
                    del sample["sample_count"]
                    del sample["stable"]
            else:
                previous["benchmarks"][0]["samples"] = [sample for sample in previous["benchmarks"][0]["samples"]
                                                          if sample["lane"] not in history.C_LANES or sample["sample"] < 2]
                for sample in previous["benchmarks"][0]["samples"]:
                    if sample["lane"] in history.C_LANES:
                        sample["sample_count"] = 2
            with self.subTest(legacy=legacy):
                cached, _ = history.cached_c_reference([previous], previous)
                self.assertEqual(len(cached), 18 if legacy else 4)

    def test_eight_worker_compilation_samples(self):
        parallel = [dict(sample, lane="workers-8") for sample in samples()]
        for rows in (parallel, samples() + parallel):
            with self.subTest(lanes={row["lane"] for row in rows}):
                self.assertEqual(history.parse_samples(encode(rows), history.COMPILATION_CASE), rows)
                self.assertEqual(history.parse_samples(encode(rows)), rows)
                with self.assertRaises(ValueError):
                    history.parse_samples(encode(rows[:-1]), history.COMPILATION_CASE)
        with self.assertRaises(ValueError):
            history.parse_samples(encode([dict(sample, lane="workers-4") for sample in samples()]))

    def test_individual_cases_require_exactly_their_own_samples(self):
        for case in history.CORE_CASES:
            rows = [row for row in samples(include_c=True) if row["case"] == case]
            with self.subTest(case=case):
                self.assertEqual(history.parse_samples(encode(rows), case), rows)
                with self.assertRaises(ValueError):
                    history.parse_samples(encode(rows[:-1]), case)

    def test_historical_harness_preserves_compiler_and_std_sources(self):
        for bundled in (False, True):
            with self.subTest(bundled=bundled), tempfile.TemporaryDirectory() as directory:
                snapshot = Path(directory)
                (snapshot / "src").mkdir()
                (snapshot / "src/query").mkdir()
                (snapshot / "src/query/engine.zig").write_text("historical query engine")
                (snapshot / "std").mkdir()
                compiler = snapshot / "src/main.zig"
                library = snapshot / "std/library.zig"
                compiler.write_text("historical compiler")
                library.write_text("historical standard library")
                if bundled:
                    (snapshot / "src/standard_bundle.zig").write_text("historical bundle implementation")
                self.assertEqual(history.prepare(snapshot), bundled)
                self.assertEqual(compiler.read_text(), "historical compiler")
                self.assertEqual(library.read_text(), "historical standard library")
                self.assertEqual("pub const standard_bundle" in (snapshot / "src/.history_compiler.zig").read_text(), bundled)
                self.assertEqual((snapshot / ".history.build.zig").read_bytes(),
                                 (history.ROOT / "benchmarks/history_build.zig").read_bytes())

    def test_failed_workload_preserves_other_results_and_diagnostic_log(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory)
            data = snapshot / "data"
            previous = record()

            def command(arguments, cwd=history.ROOT):
                case = next(argument.removeprefix("--case=") for argument in arguments if argument.startswith("--case="))
                if case == history.COMPILATION_CASE:
                    raise subprocess.CalledProcessError(1, arguments, output="", stderr="unsupported String conversion")
                return encode([row for row in samples(include_c=True) if row["case"] == case])

            with patch.object(history, "command", side_effect=command), \
                    patch.object(history, "prepare", return_value=False), \
                    patch.object(history, "environment", return_value={key: previous[key] for key in ("suite", "protocol", "runtime_suite", "zig", "runner")}), \
                    patch.object(history, "loc", return_value=previous["loc"]):
                measured = history.measure(snapshot, "abc", previous["commit_date"], "tree", False, False, data)
            self.assertEqual({row["case"] for row in measured["benchmarks"][0]["samples"]},
                             {history.RUNTIME_CASE})
            self.assertEqual([failure["workers"] for failure in measured["failures"]], [0, 8])
            self.assertEqual(len({failure["log"] for failure in measured["failures"]}), 2)
            for failure in measured["failures"]:
                self.assertEqual(failure["case"], history.COMPILATION_CASE)
                self.assertIn("unsupported String conversion", (data / failure["log"]).read_text())

    def test_runtime_csv_round_trip_and_incomplete_sample_rejection(self):
        rows = samples(include_runtime=True)
        self.assertEqual(history.parse_samples(encode(rows)), rows)
        for invalid in (rows[:-1], rows + [rows[-1]], rows + [dict(rows[-1], phase="cold")]):
            with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                history.parse_samples(encode(invalid))

    def test_c_reference_csv_requires_all_levels_and_samples(self):
        rows = samples(include_c=True)
        self.assertEqual(history.parse_samples(encode(rows)), rows)
        for invalid in (rows[:-1], rows[:-9], rows + [rows[-1]], rows[9:]):
            with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                history.parse_samples(encode(invalid))

    def test_c_reference_cache_matches_environment_and_preserves_origin(self):
        previous = record()
        previous["benchmarks"][0]["samples"] = samples(include_c=True)
        previous["benchmarks"][0]["samples"].extend(
            dict(sample, lane=lane) for lane in ("c-O1", "c-O2")
            for sample in samples(include_c=True) if sample["lane"] == "c-O3")
        previous["c_compiler"] = {"path": "/usr/bin/cc", "version": "cc 1.0"}
        expected = [sample for sample in previous["benchmarks"][0]["samples"] if sample["lane"] in history.C_LANES]
        cached, origin = history.cached_c_reference([previous], previous)
        self.assertEqual(cached, expected)
        self.assertEqual(origin, {"snapshot": previous["snapshot"], "recorded_at": previous["recorded_at"]})
        reused = copy.deepcopy(previous)
        reused["recorded_at"] = "2026-10-24T10:00:00Z"
        reused["c_reference"] = origin
        self.assertEqual(history.cached_c_reference([previous, reused], previous), (expected, origin))
        for key in ("runtime_suite", "zig", "runner", "c_compiler"):
            current = dict(previous, **{key: "changed"})
            with self.subTest(key=key):
                self.assertIsNone(history.cached_c_reference([previous], current))

    def test_c_reference_cache_rejects_incomplete_and_invalid_samples(self):
        previous = record()
        for invalid in (samples(include_runtime=True), samples(include_c=True)[:-1]):
            previous["benchmarks"][0]["samples"] = invalid
            self.assertIsNone(history.cached_c_reference([previous], previous))
        for field, value in (("nanoseconds", -1), ("executable_bytes", 0), ("phase", "cold")):
            previous["benchmarks"][0]["samples"] = samples(include_c=True)
            previous["benchmarks"][0]["samples"][-1][field] = value
            with self.subTest(field=field):
                self.assertIsNone(history.cached_c_reference([previous], previous))

    def test_c_reference_cache_accepts_valid_subsecond_samples(self):
        previous = record()
        previous["benchmarks"][0]["samples"] = samples(include_c=True)
        previous["benchmarks"][0]["samples"][-1]["nanoseconds"] = 999_999_999
        for sample in previous["benchmarks"][0]["samples"]:
            if sample["lane"] == history.C_LANES[-1]:
                sample["stable"] = False
        cached, _ = history.cached_c_reference([previous], previous)
        self.assertEqual(cached[-1]["nanoseconds"], 999_999_999)

    def test_measure_reuses_c_samples_and_refresh_forces_remeasurement(self):
        for saved, refresh in ((False, False), (True, False), (True, True)):
            with self.subTest(saved=saved, refresh=refresh), tempfile.TemporaryDirectory() as directory:
                snapshot = Path(directory)
                (snapshot / "benchmarks").mkdir()
                driver = snapshot / "benchmarks/history_benchmark.zig"
                reference = snapshot / "benchmarks/history_runtime.c"
                driver.write_text("driver")
                reference.write_text("C reference")
                data = snapshot / "data"
                previous = record()
                previous["suite"] = history.suite_id()
                previous["c_compiler"] = {"path": "/usr/bin/cc", "version": "cc 1.0"}
                previous["benchmarks"][0]["samples"] = samples(include_c=True)
                if saved:
                    history.save(data, previous)
                hit = saved and not refresh

                def command(arguments, cwd=history.ROOT):
                    if arguments == ["cc", "--version"]:
                        return "cc 1.0"
                    if arguments == ["zig", "version"]:
                        return previous["zig"]
                    self.assertEqual(arguments[:2], ["zig", "build"])
                    self.assertEqual("--skip-c" in arguments, hit)
                    self.assertEqual(cwd, snapshot)
                    case = next(argument.removeprefix("--case=") for argument in arguments if argument.startswith("--case="))
                    rows = [row for row in samples(include_runtime=True, include_c=not hit) if row["case"] == case]
                    if "--workers=8" in arguments:
                        self.assertEqual(case, history.COMPILATION_CASE)
                        rows = [dict(row, lane="workers-8") for row in rows]
                    return encode(rows)

                with patch.object(history, "command", side_effect=command), \
                    patch.object(history, "prepare", return_value=True), \
                        patch.object(history, "loc", return_value=previous["loc"]), \
                        patch.object(history, "runner", return_value=previous["runner"]), \
                        patch.object(history.shutil, "which", return_value="/usr/bin/cc"):
                    measured = history.measure(snapshot, "abc", previous["commit_date"], "new-tree", True, False, data, refresh)
                expected = samples() + [dict(sample, lane="workers-8") for sample in samples()]
                expected.extend(sample for sample in samples(include_c=True) if sample["case"] == history.RUNTIME_CASE)
                self.assertEqual(measured["benchmarks"][0]["samples"], expected)
                self.assertEqual(measured["c_reference"]["snapshot"], "tree" if hit else "new-tree")
                if saved:
                    self.assertEqual(history.read_records(data), [previous])

    def test_rejects_incomplete_duplicate_or_changed_suite(self):
        original = samples()
        for rows in (original[:-1], original + [original[-1]], original[9:]):
            with self.subTest(length=len(rows)), self.assertRaises(ValueError):
                history.parse_samples(encode(rows))

    def test_rejects_invalid_measurements(self):
        for field, value in (("nanoseconds", -1), ("executable_bytes", 0)):
            rows = samples()
            rows[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                history.parse_samples(encode(rows))

    def test_loc_uses_existing_code_and_test_classification(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "src/main.zig").write_text('const value = 42;\n// comment\ntest "value" {\n}\n')
            (root / "tests/value_test.zig").write_text('// comment\nconst expected = 42;\n')
            self.assertEqual(history.loc(root), {"code": 1, "test": 3, "total": 4})

    def test_empty_loc(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(history.loc(Path(directory)), {"code": 0, "test": 0, "total": 0})

    def test_historical_root_layout_excludes_build_and_benchmark(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "main.zig").write_text("const value = 42;\n")
            (root / "main_test.zig").write_text("const expected = 42;\n")
            (root / "build.zig").write_text("const ignored = 0;\n")
            (root / "comptime_benchmark.zig").write_text("const ignored = 0;\n")
            self.assertEqual(history.loc(root), {"code": 1, "test": 1, "total": 2})

    def test_chart_preserves_tooltips_and_commit_spacing(self):
        svg = history.chart({"Compile": [(0, 2, "first & <safe>"), (2, 4, "third")]},
                            [("a", "2026-10-21"), ("b", "2026-10-22"), ("c", "2026-10-23")], "ms")
        tree = ElementTree.fromstring(svg)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        self.assertIn("first & <safe>", tree.find(".//svg:title", namespace).text)
        self.assertEqual(len(tree.findall(".//svg:title", namespace)), 2)
        self.assertIn("data:font/ttf;base64,", svg)
        self.assertIn("SIL OPEN FONT LICENSE", svg)

    def test_compilation_series_use_monochrome_line_styles(self):
        svg = history.chart({"Compile": [(0, 3, "first"), (1, 4, "second")],
                             "Compile (8 workers)": [(0, 1, "first"), (1, 2, "second")]},
                            [("a", "2026-10-22"), ("b", "2026-10-23")], "s")
        tree = ElementTree.fromstring(svg)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        styles = []
        for index in range(2):
            series = tree.find(f".//*[@id='series-{index}']")
            self.assertIsNotNone(series)
            paths = [path for path in series.findall("svg:path", namespace)
                     if "stroke: #444444" in path.get("style", "")]
            self.assertTrue(paths)
            styles.append(dict(declaration.strip().split(": ", 1)
                               for declaration in paths[-1].get("style").split(";") if declaration.strip()))
        self.assertNotIn("stroke-dasharray", styles[0])
        self.assertIn("stroke-dasharray", styles[1])
        self.assertGreater(float(styles[1]["stroke-width"]), float(styles[0]["stroke-width"]))
        for color in ("#147d64", "#b43c44", "#3567ad"):
            self.assertNotIn(color, svg)

    def test_runtime_reference_lines_span_the_plot_without_commit_markers(self):
        references = {f"C -O{level}": (level + 1, "median of 9") for level in range(4)}
        svg = history.chart({"Runtime": [(0, 2, "first"), (1, 3, "second")]},
                            [("a", "2026-10-22"), ("b", "2026-10-23")], "ms", references=references)
        tree = ElementTree.fromstring(svg)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        dash_patterns = []
        for level in range(4):
            reference = tree.find(f".//*[@id='reference-{level}']")
            self.assertIsNotNone(reference)
            self.assertTrue(reference.find("svg:title", namespace).text.startswith(f"C -O{level}:"))
            reference_path = reference.find("svg:path", namespace)
            style = dict(declaration.strip().split(": ", 1)
                         for declaration in reference_path.get("style").split(";") if declaration.strip())
            self.assertEqual(style["stroke"], "#444444")
            dash_patterns.append(style["stroke-dasharray"])
            coordinates = reference_path.get("d").split()
            self.assertEqual(coordinates[2], coordinates[5])
            self.assertLess(float(coordinates[1]), float(coordinates[4]))
        self.assertNotEqual(dash_patterns[0], dash_patterns[1])
        self.assertEqual(len(tree.findall(".//svg:title", namespace)), 6)

    def test_compilation_estimates_are_legend_only_and_preserve_the_axis(self):
        series = {"Compile": [(0, 2, "first"), (1, 3, "second")]}
        commits = [("a", "2026-10-22"), ("b", "2026-10-23")]
        estimates = ("C++ -O0 estimate: ~158 s", "C++ -O2 estimate: ~269 s")
        baseline = ElementTree.fromstring(history.chart(series, commits, "s"))
        tree = ElementTree.fromstring(history.chart(series, commits, "s", estimates=estimates))
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        baseline_ticks = baseline.find(".//*[@id='matplotlib.axis_2']")
        ticks = tree.find(".//*[@id='matplotlib.axis_2']")
        self.assertEqual([label.text for label in ticks.findall(".//svg:text", namespace)],
                         [label.text for label in baseline_ticks.findall(".//svg:text", namespace)])
        legend = tree.find(".//*[@id='legend_1']")
        labels = [label.text for label in legend.findall(".//svg:text", namespace)]
        self.assertEqual(labels, ["Compile: 3.000 s", *estimates])
        self.assertIsNone(tree.find(".//*[@id='reference-0']"))
        self.assertEqual(len(tree.findall(".//svg:title", namespace)), 2)

    def test_single_worktree_point_has_visible_date(self):
        svg = history.chart({"Compile": [(0.35, 2, "2026-10-23")]},
                            [("a", "2026-10-23")], "ms")
        tree = ElementTree.fromstring(svg)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        dates = [label for label in tree.findall(".//svg:text", namespace) if label.text == "2026-10-23"]
        self.assertEqual(len(dates), 1)
        self.assertNotIn("uncommitted", svg)
        width = float(tree.get("viewBox").split()[2])
        self.assertGreater(float(dates[0].get("x")), 44)
        self.assertLess(float(dates[0].get("x")), width - 44)

    def test_line_chart_has_no_commit_markers(self):
        svg = history.chart({"Code": [(0, 10, "first"), (1, 20, "second")]},
                            [("a", "2026-10-22"), ("b", "2026-10-23")], "lines", markers=False)
        tree = ElementTree.fromstring(svg)
        self.assertIsNone(tree.find(".//*[@id='point-0-0']"))
        self.assertIsNone(tree.find(".//*[@id='point-0-1']"))
        self.assertIn("stroke: #444444", svg)

    def test_loc_grid_is_dotted_at_ten_thousand_line_intervals(self):
        svg = history.chart({"Code": [(0, 100, "first"), (1, 25_000, "second")]},
                            [("a", "2026-10-22"), ("b", "2026-10-23")], "lines", markers=False)
        tree = ElementTree.fromstring(svg)
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        labels = [label.text for label in tree.findall(".//svg:text", namespace)]
        self.assertIn("10000", labels)
        self.assertIn("20000", labels)
        self.assertNotIn("5000", labels)
        self.assertNotIn("15000", labels)
        dotted = [path for path in tree.findall(".//svg:path", namespace)
                  if "stroke-dasharray:" in path.get("style", "")]
        self.assertGreaterEqual(len(dotted), 3)

    def test_report_separates_machines_and_deduplicates_reruns(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            first = record()
            first["benchmarks"][0]["samples"].extend(
                dict(sample, lane="source", nanoseconds=999_000_000_000) for sample in samples())
            first["benchmarks"].append({"mode": "debug", "samples": samples()})
            history.save(data, first)
            second = copy.deepcopy(first)
            second["recorded_at"] = "2026-10-23T12:00:00Z"
            history.save(data, second)
            other = copy.deepcopy(first)
            other["recorded_at"] = "2026-10-23T13:00:00Z"
            other["runner"]["host"] = "other & host"
            other["worktree"] = True
            history.save(data, other)
            report = history.render(data, [("abc", first["commit_date"])])
            content = report.read_text()
            self.assertEqual(content.count("<section>"), 3)
            for detail in ("other &amp; host", "CPU", "affinity", "suite", "0.17.0", "uncommitted", "Debug", "Shipped", "Source"):
                self.assertNotIn(detail, content)
            self.assertNotIn("<a ", content)
            self.assertNotIn("<nav", content)
            graphs = list((data / "graphs").glob("*.svg"))
            self.assertEqual(len(graphs), 1 + 2 * 2)
            namespace = {"svg": "http://www.w3.org/2000/svg"}
            self.assertEqual(sum(len(ElementTree.parse(path).findall(".//svg:title", namespace))
                                 for path in graphs), 2 * 2)
            loc = ElementTree.parse(data / "graphs/loc.svg")
            labels = [label.text for label in loc.findall(".//svg:text", namespace)]
            self.assertNotIn("Tests", labels)
            self.assertNotIn("Total", labels)
            self.assertIsNone(loc.find(".//*[@id='point-0-0']"))
            for graph in graphs:
                tree = ElementTree.parse(graph)
                text = " ".join("".join(label.itertext()) for tag in ("text", "title")
                                for label in tree.findall(f".//svg:{tag}", namespace))
                for detail in ("other & host", "CPU", "affinity", "suite", "0.17.0", "uncommitted", "Debug", "Shipped", "Source"):
                    self.assertNotIn(detail, text)
                for tooltip in tree.findall(".//svg:title", namespace):
                    self.assertTrue(tooltip.text.startswith("Compile: 0.002 s"))
                self.assertTrue(graph.with_suffix(".png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertTrue((data / "benchmarks.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))
            benchmarks = (data / "benchmarks.html").read_text()
            self.assertNotIn("<h2>Lines of Code</h2>", benchmarks)
            self.assertNotIn("<a ", benchmarks)
            self.assertNotIn("<nav", benchmarks)
            self.assertEqual(benchmarks.count("<object"), 2 * 2)
            self.assertNotIn("Benchmark Overview PNG", benchmarks)
            self.assertEqual(history.read_records(data), [first, second, other])

    def test_report_separates_runtime_from_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            current = record()
            current["benchmarks"][0]["samples"] = samples(include_runtime=True)
            current["benchmarks"][0]["samples"].extend(
                dict(sample, lane="workers-8", nanoseconds=sample["nanoseconds"] // 2) for sample in samples())
            history.save(data, current)
            content = history.render(data, [("abc", current["commit_date"])]).read_text()
            compilation = content.split("<h2>ReleaseFast Compilation</h2>")[1].split("</section>")[0]
            runtime = content.split("<h2>Generated Program Runtime</h2>")[1].split("</section>")[0]
            self.assertEqual(compilation.count("<object"), 2)
            self.assertEqual(runtime.count("<object"), 1)
            self.assertNotIn(history.RUNTIME_CASE, compilation)
            graph, = (data / "graphs").glob(f"*-{history.RUNTIME_CASE}-runtime.svg")
            self.assertIn(graph.name, runtime)
            namespace = {"svg": "http://www.w3.org/2000/svg"}
            for phase in history.CORE_CASES[history.COMPILATION_CASE]:
                compilation_graph, = (data / "graphs").glob(f"*-{history.COMPILATION_CASE}-{phase}.svg")
                tree = ElementTree.parse(compilation_graph)
                legend = tree.find(".//*[@id='legend_1']")
                labels = [label.text for label in legend.findall(".//svg:text", namespace)]
                estimates = history.COMPILATION_ESTIMATES.get(phase, ())
                self.assertEqual(labels, ["Compile: 0.002 s", "Compile (8 workers): 0.001 s", *estimates])
                tooltips = tree.findall(".//svg:title", namespace)
                self.assertEqual(len(tooltips), 2)
                self.assertTrue(tooltips[1].text.startswith("Compile (8 workers): 0.001 s"))
                self.assertIsNone(tree.find(".//*[@id='reference-0']"))
                self.assertNotIn("est.:", compilation_graph.read_text())
                if phase == "leaf-edit":
                    self.assertNotIn("C++", compilation_graph.read_text())
            self.assertNotIn("C++", graph.read_text())
            tooltip, = ElementTree.parse(graph).findall(".//svg:title", namespace)
            self.assertTrue(tooltip.text.startswith("Runtime: 0.100 s"))
            self.assertTrue(graph.with_suffix(".png").exists())
            self.assertIn("<h2>Generated Program Runtime</h2>", (data / "benchmarks.html").read_text())
            self.assertEqual(history.read_records(data), [current])

    def test_worker_series_join_existing_graphs_across_affinities(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            previous = record()
            previous["runner"]["affinity"] = [4]
            previous["benchmarks"][0]["samples"] = samples(include_runtime=True)
            current = copy.deepcopy(previous)
            current["worktree"] = True
            current["recorded_at"] = "2026-10-23T12:00:00Z"
            current["runner"]["affinity"] = list(range(4, 12))
            current["benchmarks"][0]["samples"].extend(
                dict(sample, lane="workers-8") for sample in samples())
            for entry in (previous, current):
                history.save(data, entry)
            with patch.object(history, "graph_artifact", return_value="") as graph, \
                    patch.object(history, "benchmark_overview"):
                history.render(data, [("abc", previous["commit_date"])])
            self.assertEqual(graph.call_count, 4)
            for call in graph.call_args_list:
                series = call.args[2]
                if "Compile" in series:
                    self.assertEqual([point[0] for point in series["Compile"]], [0, 0.35])
                    self.assertEqual([point[0] for point in series["Compile (8 workers)"]], [0.35])
                elif "Runtime" in series:
                    self.assertEqual([point[0] for point in series["Runtime"]], [0, 0.35])
            self.assertEqual(history.read_records(data), [previous, current])

    def test_runtime_report_uses_latest_medians_in_legend(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            current = record()
            current["c_compiler"] = {"version": "hidden compiler version", "path": "/hidden/cc"}
            current["benchmarks"][0]["samples"] = samples(include_c=True)
            current["benchmarks"][0]["samples"].extend(
                dict(sample, lane=lane) for lane in ("c-O1", "c-O2")
                for sample in samples(include_c=True) if sample["lane"] == "c-O3")
            older = copy.deepcopy(current)
            older["commit"] = "older"
            older["recorded_at"] = "2026-10-23T09:00:00Z"
            for sample in older["benchmarks"][0]["samples"]:
                if sample["phase"] == "runtime":
                    sample["nanoseconds"] *= 2
            history.save(data, older)
            history.save(data, current)
            content = history.render(data, [("older", older["commit_date"]), ("abc", current["commit_date"])]).read_text()
            graph, = (data / "graphs").glob(f"*-{history.RUNTIME_CASE}-runtime.svg")
            tree = ElementTree.parse(graph)
            namespace = {"svg": "http://www.w3.org/2000/svg"}
            legend = tree.find(".//*[@id='legend_1']")
            labels = [text.text for text in legend.findall(".//svg:text", namespace)]
            self.assertEqual(labels, ["Runtime: 0.100 s"] +
                             [f"C -O{level}: {(1604 - level) / 1000:.3f} s" for level in (0, 3)])
            for index, level in enumerate((0, 3)):
                reference = tree.find(f".//*[@id='reference-{index}']")
                self.assertTrue(reference.find("svg:title", namespace).text.startswith(f"C -O{level}: {(1604 - level) / 1000:.3f} s"))
            self.assertIsNone(tree.find(".//*[@id='reference-2']"))
            self.assertNotIn("C -O1:", graph.read_text())
            self.assertNotIn("C -O2:", graph.read_text())
            self.assertNotIn("hidden compiler version", content + graph.read_text())
            self.assertNotIn("/hidden/cc", content + graph.read_text())
            self.assertEqual(content.count("<object"), 4)
            self.assertEqual(history.read_records(data), [older, current])

    def test_worktree_status_is_retained_without_displaying_it(self):
        current = record()
        current["worktree"] = True
        self.assertEqual(history.description(current), "2026-10-23")
        self.assertTrue(current["worktree"])
        self.assertEqual(current["snapshot"], "tree")

    def test_new_recording_replaces_temporary_worktree_point(self):
        for commit, worktree, positions in (("new", True, [0, 1.35]),
                                             ("new", False, [0, 1]),
                                             ("abc", False, [0])):
            with self.subTest(commit=commit, worktree=worktree), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                first = record()
                first["benchmarks"][0]["samples"] = samples(include_runtime=True)
                older = copy.deepcopy(first)
                older["worktree"] = True
                older["recorded_at"] = "2026-10-23T12:00:00Z"
                older["runner"]["host"] = "superseded runner"
                other = copy.deepcopy(older)
                other["commit"] = "new"
                other["recorded_at"] = "2026-10-23T12:30:00Z"
                current = copy.deepcopy(first)
                current["commit"] = commit
                current["worktree"] = worktree
                current["recorded_at"] = "2026-10-23T13:00:00Z"
                records = [first, older, other, current]
                for entry in records:
                    history.save(data, entry)
                with patch.object(history, "graph_artifact", return_value="") as graph, \
                        patch.object(history, "benchmark_overview"):
                    history.render(data, [("abc", first["commit_date"]), ("new", current["commit_date"])])
                self.assertEqual(graph.call_count, 4)
                for call in graph.call_args_list:
                    plotted = [point[0] for values in call.args[2].values() for point in values]
                    self.assertEqual(plotted, positions)
                self.assertEqual(history.read_records(data), records)

    def test_report_hides_obsolete_protocol_without_deleting_records(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            older = record()
            older["protocol"] = "fresh-db-shipped-zero-workers-v2"
            history.save(data, older)
            content = history.render(data, [("abc", older["commit_date"])]).read_text()
            self.assertEqual(content.count("<object"), 1)
            self.assertNotIn("ReleaseFast Compilation", content)
            self.assertEqual(history.read_records(data), [older])

    def test_report_keeps_one_compilation_series_across_suite_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            older = record()
            older["suite"] = "previous suite"
            for sample in older["benchmarks"][0]["samples"]:
                sample["nanoseconds"] *= 2
            current = record()
            current["suite"] = "aaa-current"
            current["recorded_at"] = "2026-10-23T12:00:00Z"
            returned = copy.deepcopy(older)
            returned["commit"] = "new"
            returned["recorded_at"] = "2026-10-23T13:00:00Z"
            records = [older, current, returned]
            for entry in records:
                history.save(data, entry)
            content = history.render(data, [("abc", current["commit_date"]), ("new", returned["commit_date"])]).read_text()
            self.assertEqual(content.count("<object"), 3)
            namespace = {"svg": "http://www.w3.org/2000/svg"}
            for phase in ("cold", "leaf-edit"):
                graph, = (data / "graphs").glob(f"*-{history.COMPILATION_CASE}-{phase}.svg")
                tree = ElementTree.parse(graph)
                tooltips = tree.findall(".//svg:title", namespace)
                self.assertEqual(len(tooltips), 2)
                self.assertTrue(tooltips[0].text.startswith("Compile: 0.002 s"))
                self.assertTrue(tooltips[1].text.startswith("Compile: 0.004 s"))
                for point in ("point-0-0", "point-0-1"):
                    self.assertIsNotNone(tree.find(f".//*[@id='{point}']"))
                self.assertIsNone(tree.find(".//*[@id='point-1-0']"))
                legend = tree.find(".//*[@id='legend_1']")
                labels = [label.text for label in legend.findall(".//svg:text", namespace)]
                self.assertEqual(labels, ["Compile: 0.004 s", *history.COMPILATION_ESTIMATES.get(phase, ())])
                self.assertNotIn("Workload", graph.read_text())
                self.assertNotIn("previous suite", graph.read_text())
            self.assertEqual(history.read_records(data), records)

    def test_report_keeps_previous_fixed_sampling_protocol_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            previous = record()
            previous["protocol"] = "core-million-zero-workers-v5"
            previous["compilation_protocol"] = "core-million-modules-one-line-leaf-v1"
            for sample in previous["benchmarks"][0]["samples"]:
                del sample["sample_count"]
                del sample["stable"]
            current = record()
            current["commit"] = "new"
            current["recorded_at"] = "2026-10-23T12:00:00Z"
            for entry in (previous, current):
                history.save(data, entry)
            content = history.render(data, [("abc", previous["commit_date"]), ("new", current["commit_date"])]).read_text()
            self.assertEqual(content.count("<object"), 5)
            self.assertEqual(len(list((data / "graphs").glob("*-cold.svg"))), 2)
            self.assertEqual(history.read_records(data), [previous, current])

    def test_new_compilation_workload_preserves_only_unchanged_runtime_history(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            older = record()
            older["protocol"] = "core-normal-zero-workers-v4"
            older["suite"] = history.LEGACY_RUNTIME["suite"]
            del older["runtime_suite"]
            older["benchmarks"][0]["samples"] = samples(include_c=True)
            for sample in older["benchmarks"][0]["samples"]:
                if sample["phase"] != "runtime":
                    sample["case"] = "collections-text" if sample["phase"] == "cold" else "functions-128"
            current = record()
            current["commit"] = "new"
            current["recorded_at"] = "2026-10-23T12:00:00Z"
            current["benchmarks"][0]["samples"] = samples(include_c=True)
            history.save(data, older)
            history.save(data, current)
            content = history.render(data, [("abc", older["commit_date"]), ("new", current["commit_date"])]).read_text()
            self.assertEqual(content.count("<object"), 4)
            namespace = {"svg": "http://www.w3.org/2000/svg"}
            compilation = list((data / "graphs").glob("*-cold.svg")) + list((data / "graphs").glob("*-leaf-edit.svg"))
            for graph in compilation:
                self.assertEqual(len(ElementTree.parse(graph).findall(".//svg:title", namespace)), 1)
            graph, = (data / "graphs").glob(f"*-{history.RUNTIME_CASE}-runtime.svg")
            self.assertEqual(len(ElementTree.parse(graph).findall(".//svg:title", namespace)), 4)
            self.assertEqual(len(history.read_records(data)), 2)

    def test_requested_failures_raise_after_saving_and_rendering_but_backfill_continues(self):
        for failed, backfill in ((False, False), (True, False), (True, True)):
            with self.subTest(failed=failed, backfill=backfill), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                current = record()
                current["failures"] = [{"case": history.RUNTIME_CASE, "error": "unsupported"}] if failed else []
                arguments = ["history.py", "--data-dir", directory]
                if backfill:
                    arguments.append("--backfill-benchmarks")
                with patch.object(history.sys, "argv", arguments), \
                        patch.object(history, "command", return_value="abc"), \
                        patch.object(history, "commits", return_value=[("abc", current["commit_date"])]), \
                        patch.object(history, "environment", return_value={}), \
                        patch.object(history, "unpack"), \
                        patch.object(history, "measure", return_value=current), \
                        patch.object(history, "render", return_value=data / "index.html") as render:
                    if failed and not backfill:
                        with self.assertRaisesRegex(ValueError, "requested benchmarks failed"):
                            history.main()
                    else:
                        history.main()
                    render.assert_called_once()
                self.assertEqual(history.read_records(data), [current])

    def test_backfill_resumes_matching_attempts_including_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            previous = record()
            previous["failures"] = [{"case": history.RUNTIME_CASE, "error": "unsupported"}]
            history.save(data, previous)
            current = {key: previous[key] for key in ("suite", "protocol", "zig", "runner")}
            with patch.object(history.sys, "argv", ["history.py", "--backfill-benchmarks", "--data-dir", directory]), \
                    patch.object(history, "command", return_value="abc"), \
                    patch.object(history, "commits", return_value=[("abc", previous["commit_date"])]), \
                    patch.object(history, "environment", return_value=current), \
                    patch.object(history, "render", return_value=data / "index.html"), \
                    patch.object(history, "measure") as measure:
                history.main()
            measure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
