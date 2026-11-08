#!/usr/bin/env bash
# Package an already-built native ARM64 .app into a drag-to-Applications DMG.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="${1:-$project_root/dist/SevenZip.app}"
dmg_path="${2:-$(ls -t "$project_root"/dist/SevenZip-*-macOS-arm64.dmg 2>/dev/null | head -1)}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "错误：生成 macOS DMG 需要在 Mac 上运行 hdiutil。" >&2
    exit 1
fi
for executable in hdiutil ditto lipo codesign mktemp; do
    if ! command -v "$executable" >/dev/null; then
        echo "缺少必要命令：$executable" >&2
        exit 1
    fi
done
if [[ ! -d "$app_path/Contents" || ! -x "$app_path/Contents/MacOS/SevenZip" ]]; then
    echo "错误：找不到已构建的 SevenZip.app，请先运行 bash scripts/build-macos.sh。" >&2
    exit 1
fi
if [[ ! -x "$app_path/Contents/Resources/bin/7zz" ]]; then
    echo "错误：应用程序未包含 7zz 引擎。" >&2
    exit 1
fi
if [[ ! -x "$app_path/Contents/MacOS/SevenZipCLI" ]]; then
    echo "错误：缺少与 GUI 共享引擎的命令行程序。" >&2
    exit 1
fi

for binary in "$app_path/Contents/MacOS/SevenZip" \
              "$app_path/Contents/MacOS/SevenZipCLI" \
              "$app_path/Contents/Resources/bin/7zz"; do
    if [[ " $(lipo -archs "$binary") " != *" arm64 "* ]]; then
        echo "错误：非 arm64 可执行文件：$binary" >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$app_path"

stage_dir="$(mktemp -d)"
trap 'rm -rf -- "$stage_dir"' EXIT

# ditto preserves the app bundle structure, metadata and code-signing layout.
ditto "$app_path" "$stage_dir/SevenZip.app"
ln -s /Applications "$stage_dir/Applications"

mkdir -p "$(dirname "$dmg_path")"
if [[ -e "$dmg_path" ]]; then
    mv "$dmg_path" "$dmg_path.previous.$(date +%Y%m%d%H%M%S)"
fi

hdiutil create \
    -volname "SevenZip" \
    -srcfolder "$stage_dir" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$dmg_path"

hdiutil verify "$dmg_path"
echo "DMG 已生成并校验：$dmg_path"
echo "安装方法：双击 DMG，拖动 SevenZip.app 到 Applications。"
