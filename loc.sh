#!/usr/bin/env bash
# Count Zig source and embedded test code.
set -euo pipefail
shopt -s nullglob

if (($#)); then
    zig_files=("$@")
else
    zig_files=( src/*.zig )
fi

python3 - "${zig_files[@]}" <<'PY'
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass


@dataclass
class Counts:
    code: int = 0
    test: int = 0

    def add(self, other: "Counts") -> None:
        self.code += other.code
        self.test += other.test


def syntax_view(line: str) -> str:
    """Remove strings and line comments so braces and test keywords are visible."""
    if line.lstrip().startswith("\\\\"):
        return ""

    out: list[str] = []
    i = 0
    while i < len(line):
        ch = line[i]
        nxt = line[i + 1] if i + 1 < len(line) else ""

        if ch == "/" and nxt == "/":
            break

        if ch == '"' or ch == "'":
            quote = ch
            out.append(" ")
            i += 1
            while i < len(line):
                out.append(" ")
                if line[i] == "\\":
                    i += 2
                    continue
                if line[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        out.append(ch)
        i += 1

    return "".join(out)


def count_braces(view: str) -> int:
    return view.count("{") - view.count("}")


def is_test_file(path: str) -> bool:
    name = os.path.basename(path)
    return name == "test.zig" or name.endswith("_test.zig")


def starts_test_decl(view: str) -> bool:
    if re.match(r"^\s*test\b", view) is not None:
        return True
    if re.match(r"^\s*(pub\s+)?fn\s+test", view) is not None:
        return True
    return re.match(r"^\s*(pub\s+)?const\s+[Tt]est\w*\s*=\s*struct\b", view) is not None


def count_file(path: str) -> Counts:
    counts = Counts()
    all_test_file = is_test_file(path)
    in_test = False
    test_depth = 0
    test_seen_open = False

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            view = syntax_view(line)
            starts_test = (
                not all_test_file
                and not in_test
                and starts_test_decl(view)
            )

            if stripped == "":
                pass
            elif stripped.startswith("//"):
                pass
            elif all_test_file or in_test or starts_test:
                counts.test += 1
            else:
                counts.code += 1

            if all_test_file:
                continue

            delta = count_braces(view)
            if in_test or starts_test:
                if starts_test and not in_test:
                    in_test = True
                    test_depth = 0
                    test_seen_open = False
                if "{" in view:
                    test_seen_open = True
                test_depth += delta
                if test_seen_open and test_depth <= 0:
                    in_test = False
                    test_depth = 0
                    test_seen_open = False

    return counts


paths = sys.argv[1:]
if not paths:
    print("No Zig files found.")
    raise SystemExit(0)

rows = [(path, count_file(path)) for path in paths]
total = Counts()
for _, counts in rows:
    total.add(counts)

name_width = max(4, *(len(path) for path, _ in rows), len("total"))
line = "-" * (name_width + 27)

print(f"{'File':<{name_width}} {'Code':>8} {'Test':>8} {'Total':>8}")
print(line)
for path, counts in rows:
    print(f"{path:<{name_width}} {counts.code:>8} {counts.test:>8} {counts.code + counts.test:>8}")
print(line)
print(f"{'total':<{name_width}} {total.code:>8} {total.test:>8} {total.code + total.test:>8}")
PY
