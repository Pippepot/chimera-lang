import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime_history as history  # noqa: E402


def summary(median: float) -> dict:
    return {"median": median, "min": median * 0.99, "max": median * 1.01, "samples": [median] * 3, "stable": True}


def record(commit: str, day: int, scale: float) -> dict:
    results = {"sieve": summary(0.6 * scale), "key-gen": summary(1.1 * scale)}
    for pattern in history.PATTERNS:
        results[f"sort {pattern} / Chimera static"] = summary(0.03 * scale)
        results[f"sort {pattern} / Chimera runtime"] = summary(0.04 * scale)
    return {"schema": 1, "suite": "x", "commit": commit, "date": f"2026-11-{day:02d}T00:00:00+00:00",
            "subject": f"commit {commit}", "results": results, "environment": {"cpu": "test", "zig": "0"}}


def reference_results() -> dict:
    results = {f"{name} C {optimization}": summary(1) for name in ("sieve", "key-gen") for optimization in ("-O0", "-O3")}
    results.update({f"sort {pattern} / {lane}": summary(1) for pattern in history.PATTERNS for lane in history.SORT_REFERENCES})
    return results


class RuntimeHistoryTest(unittest.TestCase):
    def test_first_parent_runs_newest_first_with_inclusive_since(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            revisions = []
            for index in range(3):
                subprocess.run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
                                "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
                                "-m", f"commit {index}"], cwd=root, check=True)
                revisions.append(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip())
            with patch.object(history, "ROOT", root):
                self.assertEqual(history.first_parent(None), revisions[::-1])
                self.assertEqual(history.first_parent(revisions[1][:12]), revisions[:0:-1])
                self.assertEqual(history.first_parent("HEAD"), [revisions[-1]])

    def test_commit_stops_at_first_compile_or_execution_failure(self) -> None:
        for failed_name in ("sieve", "key-gen", "sort"):
            for stage in ("compile", "execute"):
                with self.subTest(benchmark=failed_name, stage=stage), tempfile.TemporaryDirectory() as directory:
                    work = Path(directory)
                    names = ["sieve", "keygen", "sort-static", "sort-runtime"]
                    failed_compile = {"sieve": 0, "key-gen": 1, "sort": 3}[failed_name]
                    failure = RuntimeError(f"{stage} failed")
                    compiled = [work / name for name in names]
                    if stage == "compile":
                        compiled[failed_compile] = failure
                    measurements = {name: ({name: summary(1)} if name != failed_name or stage != "execute" else failure)
                                    for name in ("sieve", "key-gen", "sort")}
                    with patch.object(history, "build_compiler", return_value=work / "compiler"), \
                            patch.object(history, "compiler_takes_workers", return_value=True), \
                            patch.object(history, "compile_program", side_effect=compiled) as compile_program, \
                            patch.object(history, "measure_sieve", side_effect=[measurements["sieve"]]) as sieve, \
                            patch.object(history, "measure_keygen", side_effect=[measurements["key-gen"]]) as keygen, \
                            patch.object(history, "measure_sort", side_effect=[measurements["sort"]]) as sort:
                        results = history.record_commit(work, work)
                    completed = ["sieve", "key-gen", "sort"].index(failed_name)
                    self.assertEqual(list(results), ["sieve", "key-gen", "sort"][:completed + 1])
                    self.assertEqual(results[failed_name], {"status": "failed", "reason": str(failure)})
                    self.assertEqual(compile_program.call_count, failed_compile + 1)
                    self.assertEqual(sum(measure.call_count for measure in (sieve, keygen, sort)),
                                     completed + (stage == "execute"))

    def test_command_renders_after_first_existing_entry_or_new_failure(self) -> None:
        revisions = ["a" * 40, "b" * 40, "c" * 40]
        failure = {"status": "failed", "reason": "unsupported"}
        for failed_name in ("build", "sieve", "key-gen", "sort"):
            for cache in ("missing", "successful", "failed", "stale"):
                with self.subTest(benchmark=failed_name, cache=cache), tempfile.TemporaryDirectory() as directory:
                    data = Path(directory)
                    results = {"sieve": summary(1), failed_name: failure}
                    if failed_name == "build":
                        results = {"build": failure}
                    latest = {"sieve": summary(1)}
                    path = data / f"{revisions[1][:12]}.json"
                    existing = json.dumps({"suite": "old" if cache == "stale" else "suite",
                                           "results": results if cache == "failed" else latest})
                    if cache != "missing":
                        path.write_text(existing)
                    measured = RuntimeError("unsupported") if failed_name == "build" else results

                    def references():
                        (data / "references.json").write_text(json.dumps({"results": reference_results()}))

                    with patch.object(history.sys, "argv", ["runtime_history.py"]), \
                            patch.object(history, "DATA", data), \
                            patch.object(history, "suite_hash", return_value="suite"), \
                            patch.object(history, "first_parent", return_value=revisions), \
                            patch.object(history, "commit_info", side_effect=lambda rev: {"commit": rev, "subject": "test"}), \
                            patch.object(history, "environment", return_value={}), \
                            patch.object(history.subprocess, "Popen") as archive, \
                            patch.object(history.subprocess, "run"), \
                            patch.object(history, "record_references", side_effect=references) as reference, \
                            patch.object(history, "record_commit", side_effect=[latest, measured]) as measure, \
                            patch.object(history, "render", side_effect=lambda: self.assertTrue(path.exists())) as render:
                        if cache == "missing":
                            with self.assertRaisesRegex(SystemExit, f"{revisions[1][:12]}: stopping at failed {failed_name}: unsupported"):
                                history.main()
                        else:
                            history.main()
                    render.assert_called_once_with()
                    reference.assert_called_once_with()
                    expected_attempts = 2 if cache == "missing" else 1
                    self.assertEqual(measure.call_count, expected_attempts)
                    self.assertEqual([call.args[0][-1] for call in archive.call_args_list], revisions[:expected_attempts])
                    self.assertEqual(json.loads((data / f"{revisions[0][:12]}.json").read_text())["results"], latest)
                    if cache == "missing":
                        self.assertEqual(json.loads(path.read_text())["results"], results)
                    else:
                        self.assertEqual(path.read_text(), existing)
                    self.assertFalse((data / f"{revisions[2][:12]}.json").exists())

    def test_existing_head_only_renders_without_measuring_references(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            revision = "a" * 40
            (data / f"{revision[:12]}.json").write_text(json.dumps(record(revision, 1, 1)))
            with patch.object(history.sys, "argv", ["runtime_history.py"]), \
                    patch.object(history, "DATA", data), \
                    patch.object(history, "suite_hash", return_value="new suite"), \
                    patch.object(history, "first_parent", return_value=[revision, "older"]), \
                    patch.object(history, "record_references") as references, \
                    patch.object(history, "record_commit") as measure, \
                    patch.object(history, "render") as render:
                history.main()
            references.assert_not_called()
            measure.assert_not_called()
            render.assert_called_once_with()

    def test_sort_backfill_preserves_old_results_and_stops_at_failure(self) -> None:
        revisions = ["a" * 40, "b" * 40, "c" * 40]
        patterns = ["adjacent swap", "minimum last"]
        added = {key: summary(0.01) for key in history.sort_keys(patterns)}
        failed = {key: {"status": "failed", "reason": "unsupported sort API"} for key in added}
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            previous = []
            for day, revision in enumerate(revisions, 1):
                entry = record(revision, day, 1)
                entry["results"] = {"sieve": summary(1), "sort": {"status": "failed", "reason": "old failure"}}
                previous.append(entry)
                (data / f"{revision[:12]}.json").write_text(json.dumps(entry))
            arguments = ["runtime_history.py", "--skip-references", "--sort-pattern", patterns[0], "--sort-pattern", patterns[1]]
            with patch.object(history.sys, "argv", arguments), \
                    patch.object(history, "DATA", data), \
                    patch.object(history, "suite_hash", return_value="new suite"), \
                    patch.object(history, "first_parent", return_value=revisions), \
                    patch.object(history, "commit_info", side_effect=lambda rev: {"commit": rev, "subject": "test"}), \
                    patch.object(history, "environment", return_value={"cpu_affinity": [4]}), \
                    patch.object(history.subprocess, "Popen"), \
                    patch.object(history.subprocess, "run"), \
                    patch.object(history, "record_commit", side_effect=[added, failed]) as measure, \
                    patch.object(history, "render") as render:
                with self.assertRaisesRegex(SystemExit, "stopping at failed sort adjacent swap.*unsupported sort API"):
                    history.main()
                self.assertEqual(measure.call_count, 2)
                render.assert_called_once_with()
                for revision, original, additions in zip(revisions, previous, (added, failed, {})):
                    entry = json.loads((data / f"{revision[:12]}.json").read_text())
                    self.assertEqual(entry["results"], {**original["results"], **additions})
                    self.assertEqual(entry["suite"], original["suite"])
                    if additions:
                        self.assertEqual(entry["backfills"][0]["keys"], list(additions))
                        self.assertEqual(entry["backfills"][0]["suite"], "new suite")
                        self.assertEqual(entry["backfills"][0]["environment"], {"cpu_affinity": [4]})
                    else:
                        self.assertEqual(entry, original)
                measure.reset_mock()
                history.main()  # All requested entries at HEAD now exist.
                measure.assert_not_called()

    def test_sort_backfill_measures_only_missing_cases_and_lanes(self) -> None:
        programs = {lane: Mock() for lane in history.SORT_LANES}
        for program in programs.values():
            program.run.return_value = 0.01
        existing = {key: summary(1) for key in history.sort_keys(["adjacent swap", "minimum last"])}
        del existing["sort minimum last / Chimera runtime"]
        with patch.object(history, "sort_expected", return_value=b"answer"), \
                patch.object(history, "SORT_SAMPLES", 2):
            results = history.measure_sort(programs, ["adjacent swap", "minimum last"], existing)
        self.assertEqual(list(results), ["sort minimum last / Chimera runtime"])
        programs["Chimera static"].run.assert_not_called()
        self.assertEqual(programs["Chimera runtime"].run.call_count, 5)
        self.assertTrue(all(call.args[0][0] == 6 for call in programs["Chimera runtime"].run.call_args_list))

    def test_sort_backfill_skips_other_benchmarks_and_records_compile_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            existing = {"sort adjacent swap / Chimera static": summary(1)}
            with patch.object(history, "build_compiler", return_value=work / "compiler"), \
                    patch.object(history, "compiler_takes_workers", return_value=True), \
                    patch.object(history, "compile_program", side_effect=RuntimeError("unsupported")) as compile_program, \
                    patch.object(history, "measure_sieve") as sieve, \
                    patch.object(history, "measure_keygen") as keygen:
                results = history.record_commit(work, work, ["adjacent swap"], existing)
            self.assertEqual(results, {"sort adjacent swap / Chimera runtime": {"status": "failed", "reason": "unsupported"}})
            self.assertEqual(compile_program.call_args.args[-1], "sort-runtime")
            sieve.assert_not_called()
            keygen.assert_not_called()

    def test_command_renders_after_measuring_all_targets(self) -> None:
        for worktree in (False, True):
            with self.subTest(worktree=worktree), tempfile.TemporaryDirectory() as directory:
                data = Path(directory)
                revisions = ["a" * 40, "b" * 40]
                arguments = ["runtime_history.py", "--skip-references"] + (["--worktree"] if worktree else [])
                with patch.object(history.sys, "argv", arguments), \
                        patch.object(history, "DATA", data), \
                        patch.object(history, "suite_hash", return_value="suite"), \
                        patch.object(history, "first_parent", return_value=revisions), \
                        patch.object(history, "commit_info", side_effect=lambda rev: {"commit": rev, "subject": "test"}), \
                        patch.object(history, "environment", return_value={}), \
                        patch.object(history.subprocess, "Popen"), \
                        patch.object(history.subprocess, "run"), \
                        patch.object(history, "archive_worktree") as archive_worktree, \
                        patch.object(history, "record_references") as references, \
                        patch.object(history, "record_commit", return_value={"sieve": summary(1)}) as measure, \
                        patch.object(history, "render") as render:
                    history.main()
                self.assertEqual(measure.call_count, 1 if worktree else 2)
                self.assertEqual(archive_worktree.call_count, int(worktree))
                self.assertEqual(len(list(data.glob("*.json"))), 1 if worktree else 2)
                references.assert_not_called()
                render.assert_called_once_with()

    def test_first_build_failure_still_produces_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            report = data / "report.html"
            with patch.object(history.sys, "argv", ["runtime_history.py", "--worktree", "--skip-references"]), \
                    patch.object(history, "DATA", data), \
                    patch.object(history, "REPORT", report), \
                    patch.object(history, "suite_hash", return_value="suite"), \
                    patch.object(history, "environment", return_value={}), \
                    patch.object(history, "archive_worktree"), \
                    patch.object(history, "record_commit", side_effect=RuntimeError("cannot build")):
                with self.assertRaisesRegex(SystemExit, "worktree: stopping at failed build: cannot build"):
                    history.main()
            self.assertEqual(json.loads((data / "worktree.json").read_text())["results"],
                             {"build": {"status": "failed", "reason": "cannot build"}})
            self.assertIn("No successful measurement.", report.read_text())

    def test_compile_rejects_failed_process_even_when_executable_exists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)

            def compile_failure(*args, **kwargs):
                (kwargs["cwd"] / "prog").touch()
                return subprocess.CompletedProcess(args[0], 1, b"", b"execution failed")

            with patch.object(history.subprocess, "run", side_effect=compile_failure):
                with self.assertRaisesRegex(RuntimeError, "execution failed"):
                    history.compile_program(work / "compiler", True, "source", b"", work, "test")

    def test_sieve_source_is_the_history_driver_program(self) -> None:
        source = history.sieve_source()
        self.assertTrue(source.startswith("import std.io.{stdin, read_bytes}\n"))
        self.assertTrue(source.rstrip().endswith("exit(1)"))
        self.assertIn("List(int).filled(0, limit + 1)", source)

    def test_sort_oracle_checks_an_independent_checksum(self) -> None:
        checksum = 0
        for value in range(history.SORT_SIZE):  # The sorted pattern is already ascending.
            checksum = (checksum * 31 + value) % 1000003
        self.assertEqual(history.sort_expected(1, 1, 0), f"{checksum}\n".encode())
        # The reversed pattern holds the same values, so it sorts to the same answer.
        self.assertEqual(history.sort_expected(2, 1, 0), history.sort_expected(1, 1, 0))
        # Repeated rounds fold more values into the checksum.
        self.assertNotEqual(history.sort_expected(1, 2, 0), history.sort_expected(1, 1, 0))

    def test_nearly_sorted_oracles_preserve_the_sorted_values(self) -> None:
        for pattern in (5, 6):
            with self.subTest(pattern=pattern):
                self.assertEqual(history.sort_expected(pattern, 1, 0), history.sort_expected(1, 1, 0))
                self.assertEqual(history.sort_expected(pattern, 2, 42), history.sort_expected(1, 2, 42))

    def test_reference_cache_refreshes_when_a_workload_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.object(history, "DATA", Path(directory)):
            self.assertFalse(history.references_complete())
            results = reference_results()
            path = history.DATA / "references.json"
            path.write_text(json.dumps({"results": results}))
            self.assertTrue(history.references_complete())
            del results[f"sort {history.PATTERNS[-1]} / {history.SORT_REFERENCES[0]}"]
            path.write_text(json.dumps({"results": results}))
            self.assertFalse(history.references_complete())

    def test_stability_requires_two_close_samples(self) -> None:
        self.assertFalse(history.stable([1.0]))
        self.assertTrue(history.stable([1.0, 1.01]))
        self.assertFalse(history.stable([1.0, 1.2]))

    def test_chart_axis_uses_only_successful_commits_for_its_benchmark(self) -> None:
        records = [record(letter * 40, day, 1) for day, letter in enumerate("abcde", 1)]
        records[0]["results"] = {"build": {"status": "failed", "reason": "old"}}
        records[2]["results"] = {"key-gen": summary(1)}
        records[4]["results"] = {"sieve": {"status": "failed", "reason": "new"}}
        for wide, width in ((False, 520), (True, 1100)):
            with self.subTest(wide=wide):
                figure = ElementTree.fromstring(history.chart(
                    "Sieve", [history.series_for(records, "sieve", "Chimera")], records, [], wide=wide))
                ticks = figure.findall(".//text[@text-anchor='middle']")
                self.assertEqual([tick.text for tick in ticks], ["11-02", "11-04"])
                self.assertEqual([float(tick.get("x")) for tick in ticks], [history.LEFT, width - history.RIGHT])
                points = figure.findall(".//circle")
                self.assertEqual([float(point.get("cx")) for point in points], [history.LEFT, width - history.RIGHT])
                self.assertIn(records[1]["commit"][:10], points[0].find("title").text)
                self.assertIn(records[3]["commit"][:10], points[1].find("title").text)

    def test_chart_lanes_share_positions_for_their_successful_commits(self) -> None:
        records = [record(letter * 40, day, 1) for day, letter in enumerate("abcde", 1)]
        records[0]["results"] = records[4]["results"] = {}
        records[1]["results"] = {"static": summary(1)}
        records[2]["results"] = {"runtime": summary(1)}
        records[3]["results"] = {"static": summary(1), "runtime": summary(1)}
        figure = ElementTree.fromstring(history.chart(
            "Sort", [history.series_for(records, lane, lane) for lane in ("static", "runtime")], records, []))
        ticks = figure.findall(".//text[@text-anchor='middle']")
        self.assertEqual([tick.text for tick in ticks], ["11-02", "11-03", "11-04"])
        center = (history.LEFT + 520 - history.RIGHT) / 2
        self.assertEqual([float(point.get("cx")) for point in figure.findall(".//circle")],
                         [history.LEFT, 520 - history.RIGHT, center, 520 - history.RIGHT])

    def test_chart_single_measurement_is_centered_and_references_add_no_commits(self) -> None:
        records = [record("a" * 40, 1, 1), record("b" * 40, 2, 1)]
        records[0]["results"] = {}
        references = [{"label": "C", "median": 1}]
        figure = ElementTree.fromstring(history.chart(
            "Sieve", [history.series_for(records, "sieve", "Chimera")], records, references))
        self.assertEqual([tick.text for tick in figure.findall(".//text[@text-anchor='middle']")], ["11-02"])
        self.assertEqual(float(figure.find(".//circle").get("cx")), (history.LEFT + 520 - history.RIGHT) / 2)
        records[1]["results"] = {}
        figure = ElementTree.fromstring(history.chart(
            "Sieve", [history.series_for(records, "sieve", "Chimera")], records, references))
        self.assertEqual(figure.findall(".//text[@text-anchor='middle']"), [])
        self.assertEqual(figure.findall(".//circle"), [])

    def test_chart_reports_historical_coverage_and_failure_boundary(self) -> None:
        records = [record(letter * 40, day, 1) for day, letter in enumerate("abc", 1)]
        records.append(record("worktree", 4, 1))
        key = "sort adjacent swap / Chimera static"
        records[0]["results"] = {key: {"status": "failed", "reason": "unsupported"}}
        figure = ElementTree.fromstring(history.chart(
            "Sort", [history.series_for(records, key, "static")], records, []))
        self.assertEqual(len(figure.findall(".//circle")), 3)
        coverage = figure.find("p").text
        self.assertIn("Measured 2 commits + working tree (2026-11-02 to 2026-11-03)", coverage)
        self.assertIn("Unavailable at aaaaaaaaaa: commit", coverage)
        self.assertEqual([tick.text for tick in figure.findall(".//text[@text-anchor='middle']")],
                         ["11-02", "11-03", "11-04"])

    def test_render_reports_every_benchmark_and_skips_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            for name, item in (("a", record("a" * 40, 1, 1.0)), ("b", record("b" * 40, 2, 0.9))):
                (data / f"{name}.json").write_text(json.dumps(item))
            failed = record("c" * 40, 3, 1.0)
            failed["results"] = {"build": {"status": "failed", "reason": "no"}}
            (data / "c.json").write_text(json.dumps(failed))
            (data / "references.json").write_text(json.dumps({"clang": "clang test", "results": {
                "sieve C -O3": summary(0.58), "key-gen C -O3": summary(0.72)}}))
            original = history.DATA, history.REPORT, history.load_records
            history.DATA, history.REPORT = data, data / "out.html"
            history.load_records = lambda: sorted((json.loads(p.read_text()) for p in data.glob("[abc].json")),
                                                  key=lambda item: item["date"])
            try:
                history.render()
            finally:
                history.DATA, history.REPORT, history.load_records = original
            page = (data / "out.html").read_text()
        for expected in ("Sieve of Eratosthenes", "Five-face key search", "Array sort", "Sort: runs", "<circle"):
            self.assertIn(expected, page)
        self.assertIn("1 record(s) could not compile any benchmark", page)


if __name__ == "__main__":
    unittest.main()
