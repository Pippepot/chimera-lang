import json
import sys
import tempfile
import unittest
from pathlib import Path

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


class RuntimeHistoryTest(unittest.TestCase):
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

    def test_stability_requires_two_close_samples(self) -> None:
        self.assertFalse(history.stable([1.0]))
        self.assertTrue(history.stable([1.0, 1.01]))
        self.assertFalse(history.stable([1.0, 1.2]))

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
                history.render(None)
            finally:
                history.DATA, history.REPORT, history.load_records = original
            page = (data / "out.html").read_text()
        for expected in ("Sieve of Eratosthenes", "Five-face key search", "Array sort", "Sort: runs", "<circle"):
            self.assertIn(expected, page)
        self.assertIn("1 record(s) could not compile any benchmark", page)


if __name__ == "__main__":
    unittest.main()
