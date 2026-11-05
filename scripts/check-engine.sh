#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -x "$1" ]]; then
    echo "用法：bash scripts/check-engine.sh /path/to/7zz" >&2
    exit 2
fi

engine="$1"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/src" "$test_dir/out"
printf '7-Zip engine smoke test\n' > "$test_dir/src/hello.txt"

(
    cd "$test_dir"
    "$engine" a -t7z test.7z ./src >/dev/null
    "$engine" a -tzip -mx=5 test.zip ./src >/dev/null
)
"$engine" l -slt "$test_dir/test.7z" > "$test_dir/listing.txt"
if ! grep -q 'Path = src/hello.txt' "$test_dir/listing.txt"; then
    echo "失败：归档条目列表不包含 src/hello.txt" >&2
    exit 1
fi
"$engine" t "$test_dir/test.7z" >/dev/null
"$engine" t "$test_dir/test.zip" >/dev/null
"$engine" x -y "-o$test_dir/out" "$test_dir/test.7z" >/dev/null
if [[ ! -f "$test_dir/out/src/hello.txt" ]]; then
    echo "失败：解压文件不存在" >&2
    exit 1
fi
if ! cmp -s "$test_dir/src/hello.txt" "$test_dir/out/src/hello.txt"; then
    echo "失败：解压文件内容不一致" >&2
    exit 1
fi
echo "7zz 自检通过：7z/ZIP 创建 / 列表 / 校验 / 解压 / 内容比较"
