#!/usr/bin/env bash
# Run this on an ARM64 Mac with a representative user-supplied test directory.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$project_root/dist/SevenZip.app/Contents/Resources/bin/7zz"
test_input="${1:-}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "基准测试必须在 Apple Silicon Mac 上运行。" >&2
    exit 1
fi
if [[ -z "$test_input" || ! -e "$test_input" || ! -x "$engine" ]]; then
    echo "用法：bash scripts/benchmark-macos.sh /path/to/representative-dataset" >&2
    exit 2
fi

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
report="$project_root/dist/benchmark-$(date +%Y%m%d-%H%M%S).txt"

{
    echo "SevenZip 26.05 ARM64 benchmark"
    date
    sw_vers
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
    echo "输入：$test_input"
    du -sh "$test_input"
    for format in 7z zip; do
        echo "==================== $format ===================="
        /usr/bin/time -l "$engine" a "-t$format" -mx5 "$test_dir/benchmark.$format" "$test_input"
        du -sh "$test_dir/benchmark.$format"
        /usr/bin/time -l "$engine" t "$test_dir/benchmark.$format"
    done
} > "$report" 2>&1

echo "基准测试结果：$report"
