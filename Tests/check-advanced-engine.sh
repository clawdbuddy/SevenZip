#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -x "$1" ]]; then
    echo "用法：bash tests/check-advanced-engine.sh /absolute/path/to/7zz" >&2
    exit 2
fi
engine="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/src" "$test_dir/selected"
printf 'hello seven zip\n' > "$test_dir/src/hello.txt"
printf 'second item\n' > "$test_dir/src/second.txt"

(
    cd "$test_dir"
    "$engine" a -t7z -mx5 normal.7z -- ./src >/dev/null
    "$engine" a -t7z -bsp1 -y -sse -mx5 -xr!__MACOSX -xr!.DS_Store full-options.7z -- ./src >/dev/null
    "$engine" a -t7z -v1m volume.7z -- ./src >/dev/null
    printf 'demo-password\n' | "$engine" a -t7z -p -mhe=on secret.7z ./src >/dev/null
    printf 'demo-password\n' | "$engine" a -tzip -p -mem=AES256 secret.zip ./src >/dev/null
)

"$engine" x -aos -y -spd "-o$test_dir/selected" "$test_dir/normal.7z" -- src/hello.txt >/dev/null
"$engine" t "$test_dir/full-options.7z" >/dev/null
[[ -f "$test_dir/selected/src/hello.txt" ]]
[[ ! -f "$test_dir/selected/src/second.txt" ]]
printf 'demo-password\n' | "$engine" t "$test_dir/secret.7z" >/dev/null
printf 'demo-password\n' | "$engine" t "$test_dir/secret.zip" >/dev/null
printf 'demo-password\n' | "$engine" l -slt "$test_dir/secret.7z" > "$test_dir/encrypted-list.txt"
grep -q 'Path = src/hello.txt' "$test_dir/encrypted-list.txt"

cp "$test_dir/normal.7z" "$test_dir/edit.7z"
"$engine" rn -y "$test_dir/edit.7z" -- src/hello.txt src/renamed.txt >/dev/null
"$engine" l -slt "$test_dir/edit.7z" > "$test_dir/renamed-list.txt"
grep -q 'Path = src/renamed.txt' "$test_dir/renamed-list.txt"
"$engine" d -y -spd "$test_dir/edit.7z" -- src/renamed.txt >/dev/null
"$engine" l -slt "$test_dir/edit.7z" > "$test_dir/deleted-list.txt"
if grep -q 'Path = src/renamed.txt' "$test_dir/deleted-list.txt"; then
    echo "失败：删除后条目仍存在" >&2
    exit 1
fi
echo "高级引擎测试通过：选择性解压 / 分卷 / 7z与ZIP加密 / 列表 / 重命名 / 删除"
