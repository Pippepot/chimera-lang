#!/usr/bin/env bash
# Emit a non-recursive Fibonacci program: one function per sequence step.
# Usage: gen_fib.sh <depth> [output-file]   (output defaults to stdout)
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <depth> [output-file]" >&2
    exit 1
fi

depth=$1
if [[ ! $depth =~ ^[0-9]+$ ]]; then
    echo "depth must be a non-negative integer" >&2
    exit 1
fi

if [[ $# -eq 2 ]]; then
    exec >"$2"
fi

echo "# Fibonacci up to index $depth, one function per step."
echo

for ((i = 2; i <= depth; i++)); do
    echo "func fib_step_$i(a: int, b: int) int"
    echo "    const sum = a + b"
    echo "    return sum"
    echo
done

echo "const fib_0 = 0"
if ((depth >= 1)); then
    echo "const fib_1 = 1"
fi
for ((i = 2; i <= depth; i++)); do
    echo "const fib_$i = fib_step_$i(fib_$((i - 2)), fib_$((i - 1)))"
done

echo
# int wraps modulo 2^32 and the exit status keeps only the low 8 bits.
echo "exit(fib_$depth)"
