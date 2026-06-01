#!/usr/bin/env bash
# Count Zig lines by category: core, test, debug (incl. disasm)
set -euo pipefail

debug_files=(debug.zig disasm.zig)
test_files=(test.zig)

zig_files=( *.zig )
debug_list=()
test_list=()
core_list=()

for f in "${zig_files[@]}"; do
    case "$f" in
        debug.zig|disasm.zig) debug_list+=("$f") ;;
        test.zig)             test_list+=("$f")  ;;
        *)                    core_list+=("$f")  ;;
    esac
done

core_json=$(cloc --json "${core_list[@]}" 2>/dev/null)
debug_json=$(cloc --json "${debug_list[@]}" 2>/dev/null)
test_json=$(cloc --json "${test_list[@]}" 2>/dev/null)
all_json=$(cloc --json "${zig_files[@]}" 2>/dev/null)

core_n=${#core_list[@]}
debug_n=${#debug_list[@]}
test_n=${#test_list[@]}
total_n=${#zig_files[@]}

python3 - <<EOF
import json

def get(d):
    try:
        v = json.loads(d)['Zig']
        return v['code'], v['blank'], v['comment']
    except:
        return 0, 0, 0

core  = get('''$core_json''')
debug = get('''$debug_json''')
test  = get('''$test_json''')
total = get('''$all_json''')

print(f"{'Category':<8} {'Files':>5} {'Code':>7} {'Blank':>7} {'Comment':>8}")
print('-' * 40)
print(f"{'core':<8} {$core_n:>5} {core[0]:>7} {core[1]:>7} {core[2]:>8}")
print(f"{'debug':<8} {$debug_n:>5} {debug[0]:>7} {debug[1]:>7} {debug[2]:>8}")
print(f"{'test':<8} {$test_n:>5} {test[0]:>7} {test[1]:>7} {test[2]:>8}")
print('-' * 40)
print(f"{'total':<8} {$total_n:>5} {total[0]:>7} {total[1]:>7} {total[2]:>8}")
EOF
