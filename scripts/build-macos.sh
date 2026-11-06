#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_archive="$project_root/third_party/7z2605-src.tar.xz"
source_root="$project_root/.build-7zip/7zip-26.05"
dist_root="$project_root/dist"
app_root="$dist_root/SevenZip.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "错误：必须在 macOS（Apple Silicon）上执行。" >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "错误：请使用 Apple Silicon 原生终端（uname -m 应为 arm64）。" >&2
    exit 1
fi
for executable in xcodebuild xcrun swift make clang tar codesign shasum ditto hdiutil; do
    if ! command -v "$executable" >/dev/null; then
        echo "缺少构建工具：$executable；请安装 Xcode 和 Command Line Tools。" >&2
        exit 1
    fi
done
if [[ ! -f "$source_archive" ]]; then
    echo "缺少官方 7-Zip 26.05 源码：$source_archive" >&2
    exit 1
fi
expected_sha256="0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e"
actual_sha256="$(shasum -a 256 "$source_archive" | awk '{ print $1 }')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "7-Zip 源码校验失败：期望 $expected_sha256，实际 $actual_sha256" >&2
    exit 1
fi

echo "[1/5] 解包 7-Zip 官方源码"
mkdir -p "$source_root" "$dist_root"
if [[ ! -f "$source_root/DOC/readme.txt" ]]; then
    tar -xJf "$source_archive" -C "$source_root"
fi

echo "[2/5] 从源码编译 ARM64 7zz 引擎（官方 cmpl_mac_arm64.mak）"
processor_count="$(sysctl -n hw.ncpu)"
(
    cd "$source_root/CPP/7zip/Bundles/Alone2"
    make -j "$processor_count" -f ../../cmpl_mac_arm64.mak
)
engine="$source_root/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz"
if [[ ! -x "$engine" ]]; then
    echo "编译未找到 7zz: $engine" >&2
    exit 1
fi
bash "$project_root/scripts/check-engine.sh" "$engine"

echo "[3/5] 使用 Swift Package Manager 编译 SwiftUI ARM64 应用"
cd "$project_root"

# 自 macOS 27 SDK 起，@State 由 SwiftUIMacros 编译器宏插件实现，该插件仅随完整 Xcode
# 分发，Command Line Tools 不含此插件。若当前工具链缺失，自动回退到仍将 State 声明为
# @propertyWrapper 的最新 SDK，保证纯 CLT 环境可构建。
swift_sdk_args=()
swift_frontend="$(xcrun --find swift-frontend)"
host_plugins_dir="$(cd "$(dirname "$swift_frontend")/../lib/swift/host/plugins" 2>/dev/null && pwd || true)"
if [[ -z "$host_plugins_dir" ]] || ! ls "$host_plugins_dir" 2>/dev/null | grep -qi "SwiftUIMacros"; then
    chosen_sdk=""
    while IFS= read -r sdk_path; do
        interfaces_dir="$sdk_path/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule"
        if compgen -G "$interfaces_dir/*-apple-macos.swiftinterface" >/dev/null && \
           ! grep -q "macro State" "$interfaces_dir"/*-apple-macos.swiftinterface; then
            chosen_sdk="$sdk_path"
            break
        fi
    done < <(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name "MacOSX[0-9]*.sdk" | sort -rV)
    if [[ -n "$chosen_sdk" ]]; then
        echo "工具链缺少 SwiftUIMacros 宏插件，回退 SDK：$chosen_sdk"
        swift_sdk_args=(--sdk "$chosen_sdk")
    else
        echo "错误：工具链缺少 SwiftUIMacros 宏插件且无可回退的旧版 SDK；请安装完整 Xcode。" >&2
        exit 1
    fi
fi

swift build -c release --arch arm64 "${swift_sdk_args[@]}" --product SevenZip
swift build -c release --arch arm64 "${swift_sdk_args[@]}" --product SevenZipCLI

# XCTest 仅随完整 Xcode 分发；纯 Command Line Tools 环境跳过单元测试并给出警告。
developer_dir="$(xcode-select -p)"
xctest_available=false
for fw_dir in "$developer_dir/Library/Developer/Frameworks" \
              "$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
    if [[ -d "$fw_dir/XCTest.framework" ]]; then
        xctest_available=true
        break
    fi
done
if $xctest_available; then
    swift test -c release --arch arm64 "${swift_sdk_args[@]}"
else
    echo "警告：未找到 XCTest.framework（仅完整 Xcode 提供），跳过 swift test。"
fi

swift_bin_dir="$(swift build -c release --arch arm64 "${swift_sdk_args[@]}" --show-bin-path)"
gui_binary="$swift_bin_dir/SevenZip"
cli_binary="$swift_bin_dir/SevenZipCLI"
if [[ ! -x "$gui_binary" ]]; then
    echo "未找到 SwiftUI 可执行文件: $gui_binary" >&2
    exit 1
fi
if [[ ! -x "$cli_binary" ]]; then
    echo "未找到命令行工具: $cli_binary" >&2
    exit 1
fi

echo "[4/5] 组装并签署可运行的 .app"
if [[ -d "$app_root" ]]; then
    # Only the script-owned app bundle is replaced; no other dist items are deleted.
    mv "$app_root" "$dist_root/SevenZip.app.previous.$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources/bin" \
    "$app_root/Contents/Resources/licenses"
cp "$gui_binary" "$app_root/Contents/MacOS/SevenZip"
cp "$cli_binary" "$app_root/Contents/MacOS/SevenZipCLI"
cp "$engine" "$app_root/Contents/Resources/bin/7zz"
cp "$project_root/Resources/Info.plist" "$app_root/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_root/Contents/Resources/AppIcon.icns"
# 各归档类型的 Finder 文档图标（由 scripts/make-type-icons.swift 预生成并提交）
if [[ -d "$project_root/Resources/TypeIcons" ]]; then
    cp "$project_root"/Resources/TypeIcons/*.icns "$app_root/Contents/Resources/"
fi
# 本地化应用名：英文 SevenZip / 中文 七压（Dock、菜单栏、Finder 显示）
for lproj in "$project_root"/Resources/*.lproj; do
    lproj_name="$(basename "$lproj")"
    mkdir -p "$app_root/Contents/Resources/$lproj_name"
    cp "$lproj"/InfoPlist.strings "$app_root/Contents/Resources/$lproj_name/InfoPlist.strings"
done
cp "$source_root/DOC/License.txt" "$app_root/Contents/Resources/licenses/7zip-License.txt"
cp "$source_root/DOC/copying.txt" "$app_root/Contents/Resources/licenses/7zip-LGPL.txt"
chmod 755 "$app_root/Contents/MacOS/SevenZip" \
          "$app_root/Contents/MacOS/SevenZipCLI" \
          "$app_root/Contents/Resources/bin/7zz"
# 应用扩展（Quick Look 预览 + Finder 右键菜单）：在整体签名前打包进 Contents/PlugIns。
bash "$project_root/scripts/build-extensions.sh" "$app_root"
signing_identity="${APP_SIGN_IDENTITY:--}"
for signed_binary in "$app_root/Contents/Resources/bin/7zz" \
                     "$app_root/Contents/MacOS/SevenZipCLI" \
                     "$app_root/Contents/MacOS/SevenZip"; do
    if [[ "$signing_identity" == "-" ]]; then
        codesign --force --sign - "$signed_binary"
    else
        codesign --force --sign "$signing_identity" --options runtime --timestamp "$signed_binary"
    fi
done
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - "$app_root"
else
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$app_root"
fi

echo "[5/5] 输出 app、ZIP 和 DMG 发行包"
archive="$dist_root/SevenZip-macOS-arm64.zip"
if [[ -e "$archive" ]]; then
    mv "$archive" "$archive.previous.$(date +%Y%m%d%H%M%S)"
fi
ditto -c -k --sequesterRsrc --keepParent "$app_root" "$archive"
file "$app_root/Contents/MacOS/SevenZip" "$app_root/Contents/Resources/bin/7zz"
file "$app_root/Contents/MacOS/SevenZipCLI"
codesign --verify --deep --verbose=2 "$app_root"
bash "$project_root/scripts/package-dmg.sh" "$app_root" "$dist_root/SevenZip-macOS-arm64.dmg"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    bash "$project_root/scripts/notarize-release.sh" "$dist_root/SevenZip-macOS-arm64.dmg"
fi
echo "构建成功：$app_root"
echo "可分发压缩包：$archive"
echo "可拖拽安装的磁盘镜像：$dist_root/SevenZip-macOS-arm64.dmg"
echo "本地运行：open '$app_root'"
echo "提示：此为 ad-hoc 签名；分发给其他 Mac 用户时需 Developer ID 签名与 notarization。"
